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
    [Parameter(Mandatory = $false)] [string] $InstanceNumber = '003',
    [Parameter(Mandatory = $false)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $false)] [string] $Location = 'canadacentral',
    [Parameter(Mandatory = $false)] [string] $ContainerRegistryName,
    [Parameter(Mandatory = $false)] [bool] $EnableWindows = $true,
    [Parameter(Mandatory = $false)] [int] $WindowsNodeCount = 1,
    [Parameter(Mandatory = $false)] [int] $LinuxNodeCount = 1,
    [Parameter(Mandatory = $false)] [string] $WindowsAdminUsername,
    [Parameter(Mandatory = $false)] [SecureString] $WindowsAdminPassword
)

function Fail($msg) { Write-Error $msg; exit 1 }

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

# Detect whether an AKS with that name already exists in the target RG. If it does,
# we must avoid attempting to add agent pools through the managedCluster resource
# in Bicep. Instead, we'll set skipAks=true and perform per-pool operations later.
Write-Host "Checking for existing AKS cluster '$aksName' in resource group '$ResourceGroupName'..."
$aks = az aks show -n $aksName -g $ResourceGroupName --only-show-errors | ConvertFrom-Json -ErrorAction SilentlyContinue
$aksExists = $false
if ($aks) {
    $aksExists = $true
    Write-Host "Found existing AKS cluster: $aksName"
} else {
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
} elseif ($ContainerRegistryName) {
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
} else {
    $acrId = $null
}
if (-not $acrId) {
    Write-Warning "Unable to locate ACR resource '$deployedRegistryName' in resource group '$ResourceGroupName'. Skipping role assignment."
} else {
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
        } catch {
            Write-Warning "Role assignment command failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "AKS principalId not available; cannot grant AcrPull role. AKS exists: $aksExists"
    }
}

# If the cluster existed before deploy and Windows pools are requested, add them using
# per-pool CLI since Bicep did not touch the managed cluster. Also handle the case
# where the cluster was created by this deployment and we still need to add user pools.
if ($EnableWindows) {
    if (-not $aks) {
        Write-Warning "Unable to query AKS cluster '$aksName'; skipping nodepool add."
    } else {
        # Determine a valid Windows nodepool name. Azure enforces short names for Windows pools
        # (error observed: "Windows agent pool name can not be longer than 6 characters").
        $desiredNodePoolName = 'winpool'
        $maxPoolNameLen = 6
        if ($desiredNodePoolName.Length -gt $maxPoolNameLen) {
            $nodepoolName = $desiredNodePoolName.Substring(0, $maxPoolNameLen).ToLower()
            Write-Host "Nodepool name '$desiredNodePoolName' truncated to '$nodepoolName' to meet Windows limit ($maxPoolNameLen chars)."
        } else {
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
        } else {
            Write-Host "Adding Windows nodepool '$nodepoolName' to cluster $aksName (node count: $WindowsNodeCount)"
            # Capture output and exit code to detect real failures (az may print errors to stderr)
            $addOutput = az aks nodepool add --cluster-name $aksName --resource-group $ResourceGroupName --name $nodepoolName --os-type Windows --node-count $WindowsNodeCount --only-show-errors 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                Write-Warning "Failed to add Windows nodepool '$nodepoolName' (exit code $exitCode):`n$addOutput"
            } else {
                Write-Host "Windows nodepool '$nodepoolName' added."
            }
        }
    }
}
