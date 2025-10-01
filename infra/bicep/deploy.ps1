<#
deploy.ps1 - deploy the Bicep AKS + ACR template in this folder

Usage examples:
  pwsh ./deploy.ps1 -ResourceGroupName rg-aks-ado-agents-003 -InstanceNumber 003

This script validates prerequisites, runs an ARM "what-if" and then deploys the Bicep.
It prints outputs (ACR name/loginServer, AKS name/resourceId) on success.

Security: do not pass secrets on the command line in CI; use pipeline-secure variables or Azure Key Vault.
#>
[CmdletBinding()]
param(    
    [Parameter(Mandatory = $true)] [string] $InstanceNumber, #'003'
    [Parameter(Mandatory = $false)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $Location, #'canadacentral'
    [Parameter(Mandatory = $false)] [string] $ContainerRegistryName,
    [Parameter(Mandatory = $false)] [switch] $SkipContainerRegistry,
    [Parameter(Mandatory = $false)] [bool] $EnableWindows = $true,
    [Parameter(Mandatory = $false)] [int] $WindowsNodeCount = 1,
    [Parameter(Mandatory = $false)] [int] $LinuxNodeCount = 1,
    [Parameter(Mandatory = $false)] [string] $WindowsAdminUsername,
    [Parameter(Mandatory = $false)] [SecureString] $WindowsAdminPassword,
    [Parameter(Mandatory = $false)] [string] $KeyVaultName,
    [Parameter(Mandatory = $false)] [switch] $RequireDeletionConfirmation,
    [Parameter(Mandatory = $false)] [string] $ConfirmDeletionToken,
    [Parameter(Mandatory = $false)] [switch] $DeleteResourceGroup,
    [Parameter(Mandatory = $false)] [switch] $DeleteAksOnly
)

function Fail($msg) { Write-Error $msg; exit 1 }

# Generate a random, AZ-acceptable Windows admin password that meets complexity
function New-RandomPassword([int]$length = 16) {
    if ($length -lt 12) { $length = 12 }
    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $lower = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $digits = '0123456789'.ToCharArray()
    # A conservative set of special chars that are safe to pass on CLI and in ARM parameters
    $special = '!@#%&*()-_=+[]{}.,?'.ToCharArray()

    $rnd = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param($arr)
        $b = New-Object 'byte[]' 4
        $rnd.GetBytes($b)
        $idx = [BitConverter]::ToUInt32($b, 0) % $arr.Length
        return $arr[$idx]
    }

    # Ensure at least one of each category
    $chars = @()
    $chars += $pick.Invoke($upper)
    $chars += $pick.Invoke($lower)
    $chars += $pick.Invoke($digits)
    $chars += $pick.Invoke($special)

    $all = $upper + $lower + $digits + $special
    while ($chars.Count -lt $length) { $chars += $pick.Invoke($all) }

    # Shuffle
    $chars = $chars | Sort-Object { Get-Random }
    return -join $chars
}

# Convert a SecureString to plain text safely
function SecureString-ToPlainText($ss) {
    if (-not $ss) { return $null }
    if ($ss -is [System.Security.SecureString]) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return [string]$ss
}

# Validate az is present
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Fail 'Azure CLI "az" not found on PATH. Install Azure CLI and retry.' }

# Ensure resource group exists
if (-not $ResourceGroupName -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = "rg-aks-ado-agents-$InstanceNumber"
    Write-Host "No ResourceGroupName provided; defaulting to: $ResourceGroupName"
}

$rg = az group show -n $ResourceGroupName --only-show-errors | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Creating resource group $ResourceGroupName in $Location"
    az group create -n $ResourceGroupName -l $Location --only-show-errors | Out-Null
}

# Do not generate or pass a containerRegistryName here. Let the Bicep template compute the default
# containerRegistryName (it uses uniqueString(resourceGroup().id) by default). The script will
# read the actual created registry name from deployment outputs after create.

$bicepFile = Join-Path $PSScriptRoot 'main.bicep'

# Compute AKS name (must match Bicep naming)
$aksName = "aks-ado-agents-$InstanceNumber".ToLower()

# If requested, perform deletion actions and exit early
if ($DeleteResourceGroup -and $DeleteAksOnly) {
    Fail 'Only one of -DeleteResourceGroup or -DeleteAksOnly may be specified.'
}

function Require-DeleteConfirmation() {
    if (-not $RequireDeletionConfirmation) { return }
    $expected = "DELETE-$InstanceNumber"
    if (-not $ConfirmDeletionToken) {
        Fail ("Destructive operation requested but no ConfirmDeletionToken provided. To proceed, pass -RequireDeletionConfirmation and -ConfirmDeletionToken '{0}'" -f $expected)
    }
    if ($ConfirmDeletionToken -ne $expected) {
        Fail ("ConfirmDeletionToken did not match expected token. To avoid accidental deletion, provide the token: {0}" -f $expected)
    }
}

if ($DeleteResourceGroup) {
    Require-DeleteConfirmation
    Write-Host "Request received: delete entire resource group '$ResourceGroupName' and all contained resources (AKS, ACR, etc)."
    # Check existence
    $rgCheck = az group show -n $ResourceGroupName --only-show-errors | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $rgCheck) {
        Write-Warning "Resource group '$ResourceGroupName' does not exist or is not accessible. Nothing to delete."
        exit 0
    }
    Write-Host "Deleting resource group '$ResourceGroupName'... This may take several minutes."
    try {
        az group delete -n $ResourceGroupName --yes --only-show-errors
        Write-Host "Delete initiated for resource group '$ResourceGroupName'."
        exit 0
    }
    catch {
        Fail ("Failed to delete resource group '{0}': {1}" -f $ResourceGroupName, $_.Exception.Message)
    }
}

if ($DeleteAksOnly) {
    Require-DeleteConfirmation
    Write-Host "Request received: delete AKS cluster '$aksName' in resource group '$ResourceGroupName'."
    # Check whether the cluster exists
    $aksCheck = az aks show -n $aksName -g $ResourceGroupName --only-show-errors | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $aksCheck) {
        Write-Warning "AKS cluster '$aksName' not found in resource group '$ResourceGroupName'. Nothing to delete."
        exit 0
    }
    Write-Host "Deleting AKS cluster '$aksName'... This may take several minutes."
    try {
        az aks delete -n $aksName -g $ResourceGroupName --yes --only-show-errors
        Write-Host "Delete initiated for AKS cluster '$aksName'."
        exit 0
    }
    catch {
        Fail ("Failed to delete AKS cluster '{0}': {1}" -f $aksName, $_.Exception.Message)
    }
}
# Detect whether an AKS with that name already exists in the target RG. If it does,
# we must avoid attempting to add agent pools through the managedCluster resource
# in Bicep. Instead, we'll set skipAks=true and perform per-pool operations later.
Write-Host "Checking for existing AKS cluster '$aksName' in resource group '$ResourceGroupName'..."
$aks = az aks show -n $aksName -g $ResourceGroupName --only-show-errors | ConvertFrom-Json -ErrorAction SilentlyContinue
$aksExists = $false
if ($aks) {
    $aksExists = $true
    Write-Host "Found existing AKS cluster: $aksName"
}
else {
    Write-Host "No existing AKS cluster found; deployment will create a new AKS resource named: $aksName"
}

# Build CLI parameter arguments for az (key=value pairs). Booleans must be lowercase.
$enableWindowsStr = $EnableWindows.ToString().ToLower()
$skipAksStr = ($aksExists).ToString().ToLower()
$paramArgs = @(
    '--parameters'
    "location=$Location"
    "instanceNumber=$InstanceNumber"
    "enableWindows=$enableWindowsStr"
    "windowsNodeCount=$WindowsNodeCount"
    "linuxNodeCount=$LinuxNodeCount"
    "skipAks=$skipAksStr"
)

# If the caller explicitly provided a ContainerRegistryName, pass it through to the template and
# ensure the template does not attempt to create a new registry.
if ($ContainerRegistryName -and -not [string]::IsNullOrWhiteSpace($ContainerRegistryName)) {
    $paramArgs += "containerRegistryName=$ContainerRegistryName"
}

# Determine whether the Bicep should skip creating an ACR. Caller can request this via the
# -SkipContainerRegistry switch, or it will be implied when a ContainerRegistryName is provided.
$effectiveSkipCr = ($SkipContainerRegistry.IsPresent -or ($ContainerRegistryName -and -not [string]::IsNullOrWhiteSpace($ContainerRegistryName)))
$paramArgs += "skipContainerRegistry=$($effectiveSkipCr.ToString().ToLower())"

# If Windows is enabled, ensure we have admin username/password values and pass them as secure parameters
if ($EnableWindows) {
    if (-not $WindowsAdminUsername -or [string]::IsNullOrWhiteSpace($WindowsAdminUsername)) {
        $WindowsAdminUsername = 'azureuser'
        Write-Host "No WindowsAdminUsername provided; defaulting to: $WindowsAdminUsername"
    }

    # Convert SecureString to plain text if necessary or generate a new secure password if none provided
    $plainWindowsAdminPassword = SecureString-ToPlainText $WindowsAdminPassword
    $generatedPassword = $false
    if (-not $plainWindowsAdminPassword -or [string]::IsNullOrWhiteSpace($plainWindowsAdminPassword)) {
        $plainWindowsAdminPassword = New-RandomPassword 16
        $generatedPassword = $true
        Write-Host "No WindowsAdminPassword provided; generated a compliant random password to satisfy AKS preflight validation."
    }

    # Append Windows admin credentials to the parameter list. Use the ARM parameter names expected by the Bicep template.
    $paramArgs += "windowsAdminUsername=$WindowsAdminUsername"
    # For passwords, ensure proper quoting so special chars are preserved when passed to az CLI
    $paramArgs += "windowsAdminPassword=$plainWindowsAdminPassword"
}

# If we generated a Windows admin password and the caller provided a KeyVaultName, store it there
if ($EnableWindows -and $generatedPassword -and $KeyVaultName) {
    try {
        $secretName = "WinAdminPassword-$InstanceNumber"
        Write-Host "Storing generated Windows admin password into Key Vault '$KeyVaultName' as secret '$secretName' (value will not be printed)."
        # Use az keyvault secret set to store the secret
        $kvArgs = @('keyvault', 'secret', 'set', '--vault-name', $KeyVaultName, '--name', $secretName, '--value', $plainWindowsAdminPassword, '--only-show-errors')
        $out = & az @kvArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to store Windows admin password in Key Vault: $out"
        }
        else {
            Write-Host "Password stored to Key Vault secret: $secretName"
        }
    }
    catch {
        Write-Warning "Exception while storing secret to Key Vault: $($_.Exception.Message)"
    }
}

Write-Host "Running what-if preview for deployment to resource group $ResourceGroupName (this will not make changes)"
az deployment group what-if --resource-group $ResourceGroupName --template-file $bicepFile @paramArgs --only-show-errors

Write-Host "Creating deployment..."
# Execute the deployment and capture outputs so we can reference the ACR name created by Bicep
$deployResult = az deployment group create --resource-group $ResourceGroupName --template-file $bicepFile @paramArgs --only-show-errors | ConvertFrom-Json
if ($deployResult.properties.outputs) {
    Write-Host "Deployment outputs:"
    $deployResult.properties.outputs | ConvertTo-Json -Depth 5 | Write-Host
}

# Determine the deployed container registry name. Prefer the template output if present.
$deployedRegistryName = $null
if ($deployResult.properties.outputs.containerRegistryName) {
    $deployedRegistryName = $deployResult.properties.outputs.containerRegistryName.value
}
elseif ($ContainerRegistryName) {
    # fallback if the user explicitly provided a name earlier (not recommended)
    $deployedRegistryName = $ContainerRegistryName
}
Write-Host 'Deployment finished.'

# Post-deploy: ensure AKS (existing or newly-created) has AcrPull on the ACR and
# add Windows nodepool via az CLI when appropriate. For existing clusters we
# perform per-pool operations since the Bicep did not modify the cluster.

# Resolve the ACR resource id using the deployed registry name
if ($deployedRegistryName) {
    $acrId = az acr show -n $deployedRegistryName -g $ResourceGroupName --query id -o tsv 2>$null
}
else {
    $acrId = $null
}
if (-not $acrId) {
    Write-Warning "Unable to locate ACR resource '$deployedRegistryName' in resource group '$ResourceGroupName'. Skipping role assignment."
}
else {
    # Get AKS principalId. If the cluster was created by this deployment, query it now.
    if (-not $aksExists) {
        $aks = az aks show -n $aksName -g $ResourceGroupName --only-show-errors | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($aks) { $aksExists = $true }
    }

    if ($aksExists -and $aks.identity -and $aks.identity.principalId) {
        $principalId = $aks.identity.principalId
        Write-Host "Granting AcrPull role on $acrId to AKS principal (object id): $principalId"
        try {
            az role assignment create --assignee-object-id $principalId --role AcrPull --scope $acrId --only-show-errors | Out-Null
            Write-Host "Role assignment created (or already exists)."
        }
        catch {
            Write-Warning "Role assignment command failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "AKS principalId not available; cannot grant AcrPull role. AKS exists: $aksExists"
    }
}

# If the cluster existed before deploy and Windows pools are requested, add them using
# per-pool CLI since Bicep did not touch the managed cluster. Also handle the case
# where the cluster was created by this deployment and we still need to add user pools.
if ($EnableWindows) {
    if (-not $aks) {
        Write-Warning "Unable to query AKS cluster '$aksName'; skipping nodepool add."
    }
    else {
        # Determine a valid Windows nodepool name. Azure enforces short names for Windows pools
        # (error observed: "Windows agent pool name can not be longer than 6 characters").
        # Use 'winp' which is <= 6 chars and matches the Bicep template.
        $desiredNodePoolName = 'winp'
        $maxPoolNameLen = 6
        if ($desiredNodePoolName.Length -gt $maxPoolNameLen) {
            $nodepoolName = $desiredNodePoolName.Substring(0, $maxPoolNameLen).ToLower()
            Write-Host "Nodepool name '$desiredNodePoolName' truncated to '$nodepoolName' to meet Windows limit ($maxPoolNameLen chars)."
        }
        else {
            $nodepoolName = $desiredNodePoolName.ToLower()
        }

        # Check whether the nodepool already exists using the computed name
        $existingPools = az aks nodepool list --cluster-name $aksName --resource-group $ResourceGroupName -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $nodepoolExists = $false
        if ($existingPools) {
            $nodepoolExists = ($existingPools | Where-Object { $_.name -eq $nodepoolName }) -ne $null
        }

        if ($nodepoolExists) {
            Write-Host "Windows nodepool '$nodepoolName' already exists on cluster $aksName; skipping nodepool add."
        }
        else {
            Write-Host "Adding Windows nodepool '$nodepoolName' to cluster $aksName (node count: $WindowsNodeCount)"
            # Capture output and exit code to detect real failures (az may print errors to stderr)
            $addOutput = az aks nodepool add --cluster-name $aksName --resource-group $ResourceGroupName --name $nodepoolName --os-type Windows --node-count $WindowsNodeCount --only-show-errors 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                Write-Warning "Failed to add Windows nodepool '$nodepoolName' (exit code $exitCode):`n$addOutput"
            }
            else {
                Write-Host "Windows nodepool '$nodepoolName' added."
            }
        }
    }
}
