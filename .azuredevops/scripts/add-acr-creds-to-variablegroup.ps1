<#
.SYNOPSIS
  Fetch ACR credentials (admin or service-principal) and store them into an Azure DevOps variable group.

USAGE
  pwsh .\.azuredevops\scripts\add-acr-creds-to-variablegroup.ps1 -AcrName cragents003c66i4n7btfksg -OrgUrl https://dev.azure.com/cad4devops -Project MyProject -VariableGroupName ADO_az-devops-agents-k8s

NOTES
  - Requires Azure CLI logged in (az account show) and 'az ad' permissions when creating a service principal.
  - Requires AZDO_PAT set in environment or passed via -AzDoPat parameter to authenticate to the Azure DevOps REST API.
  - The script will attempt to retrieve ACR admin credentials. If admin user is not enabled, it will create
    a service principal with AcrPull role scoped to the ACR and use its appId/password as credentials.
  - The variable group will be updated (created if missing). ACR_USERNAME is stored non-secret; ACR_PASSWORD is stored secret.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $AcrName,
    [Parameter(Mandatory = $true)] [string] $OrgUrl,
    [Parameter(Mandatory = $true)] [string] $Project,
    [Parameter(Mandatory = $true)] [string] $VariableGroupName,
    [Parameter(Mandatory = $false)] [string] $AzDoPat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function MaskString([string]$s) {
    if (-not $s) { return '' }
    if ($s.Length -le 4) { return '****' }
    $mid = -join (1..($s.Length - 4) | ForEach-Object { '*' })
    return $s.Substring(0, 2) + $mid + $s.Substring($s.Length - 2)
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error 'az CLI not found on PATH. Install Azure CLI before running this script.'; exit 1
}
# Ensure az devops extension available (best-effort)
try { az extension show --name azure-devops | Out-Null } catch { try { az extension add --name azure-devops | Out-Null } catch { Write-Verbose 'azure-devops extension not installed; proceeding without it (REST API used).' } }

# Validate AZDO PAT
if (-not $AzDoPat) { $AzDoPat = $env:AZDO_PAT }
if (-not $AzDoPat) { Write-Error 'AZDO_PAT not set in environment and not supplied via -AzDoPat. Provide a PAT with Variable Groups Read & Write scope.'; exit 1 }

# Determine whether ACR admin user credentials are available
Write-Host "Querying ACR '$AcrName' for admin credentials (az acr credential show)"
$useAdmin = $false
try {
    $acrCred = az acr credential show -n $AcrName -o json | ConvertFrom-Json
    if ($acrCred -and $acrCred.username -and $acrCred.passwords -and $acrCred.passwords.Count -gt 0) {
        $acrUsername = $acrCred.username
        $acrPassword = $acrCred.passwords[0].value
        $useAdmin = $true
        Write-Host 'Using ACR admin credential retrieved via az acr credential show'
    }
}
catch {
    Write-Verbose "az acr credential show failed or admin disabled: $($_.Exception.Message)"
}

if (-not $useAdmin) {
    Write-Host 'ACR admin user not available or disabled; creating a service principal with AcrPull on the registry.'
    # Get ACR resource id
    try { $acrId = az acr show -n $AcrName --query id -o tsv } catch { Write-Error "Failed to resolve ACR resource id for '$AcrName'"; exit 1 }
    if (-not $acrId) { Write-Error "Could not determine ACR resource id for '$AcrName'"; exit 1 }

    $spName = "cad4devops-pipeline-sp-$AcrName"
    Write-Host "Creating service principal '$spName' and assigning AcrPull role on $acrId"
    try {
        $sp = az ad sp create-for-rbac --name $spName --role AcrPull --scopes $acrId -o json | ConvertFrom-Json
        $acrUsername = $sp.appId
        $acrPassword = $sp.password
        Write-Host "Created service principal appId: $acrUsername"
    }
    catch {
        Write-Error "Failed to create service principal: $($_.Exception.Message)"; exit 1
    }
}

# Prepare REST auth header for Azure DevOps (use PAT)
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $AzDoPat))
$headers = @{ Authorization = "Basic $base64Auth"; 'Content-Type' = 'application/json' }

# Get variable groups for the project and search by name
$api = "$OrgUrl/$Project/_apis/distributedtask/variablegroups?api-version=6.0-preview.2"
Write-Host "Locating variable group '$VariableGroupName' in project '$Project'..."
try {
    $groupsResp = Invoke-RestMethod -Method Get -Uri $api -Headers $headers -ErrorAction Stop
}
catch {
    Write-Error "Failed to list variable groups: $($_.Exception.Message)"; exit 1
}

$group = $null
if ($groupsResp -and $groupsResp.value) {
    $group = $groupsResp.value | Where-Object { $_.name -eq $VariableGroupName } | Select-Object -First 1
}

if (-not $group) {
    Write-Host "Variable group '$VariableGroupName' not found; creating it."
    $createBody = @{ name = $VariableGroupName; variables = @{ } } | ConvertTo-Json -Depth 10
    try {
        $created = Invoke-RestMethod -Method Post -Uri "$OrgUrl/$Project/_apis/distributedtask/variablegroups?api-version=6.0-preview.2" -Headers $headers -Body $createBody -ErrorAction Stop
        $group = $created
        Write-Host "Created variable group id=$($group.id)"
    }
    catch {
        Write-Error "Failed to create variable group: $($_.Exception.Message)"; exit 1
    }
}
else {
    Write-Host "Found variable group id=$($group.id)"
}

# Update variables using Azure DevOps CLI to handle secret values correctly.
Write-Host "Updating variable group variables using Azure DevOps CLI (az pipelines)"

# Ensure az devops extension present (best-effort done earlier, but confirm az is available)
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error 'az CLI not found; cannot update variable group via az pipelines commands.'; exit 1 }

# Helper to run az cli commands and capture failures
function Run-AzCli([string[]]$azArgs) {
    $display = 'az ' + ($azArgs -join ' ')
    Write-Host $display
    try {
        $out = & az @azArgs 2>&1
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            Write-Error "az command failed (rc=$rc): $display`n$out"
            return $false
        }
        return $true
    }
    catch {
        Write-Error "az invocation exception for: $display - $($_.Exception.Message)"
        return $false
    }
}

# Update or create non-secret ACR_USERNAME
$groupId = $group.id
try {
    # Try update first
    $argsUpdate = @('pipelines', 'variable-group', 'variable', 'update', '--id', [string]$groupId, '--name', 'ACR_USERNAME', '--value', $acrUsername, '--org', $OrgUrl, '--project', $Project, '--output', 'none')
    if (-not (Run-AzCli -azArgs $argsUpdate)) {
        # Fallback to create if update fails
    $argsCreate = @('pipelines', 'variable-group', 'variable', 'create', '--id', [string]$groupId, '--name', 'ACR_USERNAME', '--value', $acrUsername, '--org', $OrgUrl, '--project', $Project, '--output', 'none')
    if (-not (Run-AzCli -azArgs $argsCreate)) {
            Write-Error 'Failed to set ACR_USERNAME via az cli.'; exit 1
        }
    }
}
catch {
    Write-Error "Failed to set ACR_USERNAME: $($_.Exception.Message)"; exit 1
}

# Update secret ACR_PASSWORD using environment variable and --prompt-value
try {
    $envName = 'AZURE_DEVOPS_EXT_PIPELINE_VAR_ACR_PASSWORD'
    # Set environment variable for az CLI to pick up for secret variable creation (az will read AZURE_DEVOPS_EXT_PIPELINE_VAR_ACR_PASSWORD)
    Set-Item -Path "Env:$envName" -Value $acrPassword -Force
    $argsUpdateSec = @('pipelines', 'variable-group', 'variable', 'update', '--id', [string]$groupId, '--name', 'ACR_PASSWORD', '--secret', 'true', '--org', $OrgUrl, '--project', $Project, '--output', 'none')
    if (-not (Run-AzCli -azArgs $argsUpdateSec)) {
        # If update failed attempt create
    $argsCreateSec = @('pipelines', 'variable-group', 'variable', 'create', '--id', [string]$groupId, '--name', 'ACR_PASSWORD', '--secret', 'true', '--org', $OrgUrl, '--project', $Project, '--output', 'none')
    if (-not (Run-AzCli -azArgs $argsCreateSec)) {
            Write-Error 'Failed to set ACR_PASSWORD via az cli.'; exit 1
        }
    }
    # Remove env var after use
    Remove-Item -Path "Env:$envName" -ErrorAction SilentlyContinue
}
catch {
    Write-Error "Failed to set ACR_PASSWORD: $($_.Exception.Message)"; exit 1
}

Write-Host "Variable group variables updated via az CLI (group id=$groupId)."

# Output masked results to console
Write-Host "ACR credentials stored into variable group '$VariableGroupName' (project: $Project)."
Write-Host "ACR_USERNAME: $acrUsername"
Write-Host "ACR_PASSWORD (masked): $(MaskString $acrPassword)"

Write-Host 'Done.'