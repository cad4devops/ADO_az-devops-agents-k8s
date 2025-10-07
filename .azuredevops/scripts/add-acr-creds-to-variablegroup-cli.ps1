<#
.SYNOPSIS
  Fetch ACR admin credentials and add them to an Azure DevOps variable group using Azure CLI.

.DESCRIPTION
  This script uses only Azure CLI commands (no REST API) to add ACR credentials to a variable group.
  It retrieves ACR admin credentials and adds ACR_USERNAME and ACR_PASSWORD to the specified variable group.

.USAGE
  pwsh .\.azuredevops\scripts\add-acr-creds-to-variablegroup-cli.ps1 `
    -AcrName cragents003c66i4n7btfksg `
    -OrgUrl https://dev.azure.com/yourorg `
    -Project YourProject `
    -VariableGroupName YourVariableGroup

.NOTES
  - Requires Azure CLI logged in (az account show)
  - Requires AZDO_PAT environment variable or az devops configured
  - Uses ACR admin credentials (ACR must have admin user enabled)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AcrName,
    [Parameter(Mandatory = $true)][string]$OrgUrl,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$VariableGroupName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure az CLI is available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error 'Azure CLI (az) not found on PATH. Please install Azure CLI.'; exit 1
}

# Get ACR credentials using Azure CLI
Write-Host "Fetching ACR admin credentials for '$AcrName'..."
try {
    $acrUsername = az acr credential show -n $AcrName --query username -o tsv
    $acrPassword = az acr credential show -n $AcrName --query "passwords[0].value" -o tsv
    
    if ([string]::IsNullOrWhiteSpace($acrUsername) -or [string]::IsNullOrWhiteSpace($acrPassword)) {
        Write-Error "Failed to retrieve ACR credentials. Ensure ACR admin user is enabled."
        exit 1
    }
    
    Write-Host "Successfully retrieved ACR credentials (username: $acrUsername)"
}
catch {
    Write-Error "Failed to fetch ACR credentials: $($_.Exception.Message)"
    exit 1
}

# Find the variable group
Write-Host "Locating variable group '$VariableGroupName' in project '$Project'..."
try {
    $groupId = az pipelines variable-group list `
        --org $OrgUrl `
        --project $Project `
        --query "[?name=='$VariableGroupName'].id | [0]" `
        -o tsv
    
    if ([string]::IsNullOrWhiteSpace($groupId)) {
        Write-Error "Variable group '$VariableGroupName' not found. Please create it first."
        exit 1
    }
    
    Write-Host "Found variable group (id: $groupId)"
}
catch {
    Write-Error "Failed to locate variable group: $($_.Exception.Message)"
    exit 1
}

# Function to create or update a variable in the group
function Set-VariableGroupVariable {
    param(
        [string]$GroupId,
        [string]$VarName,
        [string]$VarValue,
        [bool]$IsSecret
    )
    
    Write-Host "Setting variable '$VarName' (secret: $IsSecret) in group $GroupId..."
    
    # Check if variable exists
    $exists = az pipelines variable-group variable list `
        --group-id $GroupId `
        --org $OrgUrl `
        --project $Project `
        --query "contains(keys(@), '$VarName')" `
        -o tsv 2>$null
    
    if ($exists -eq 'true') {
        Write-Host "  Variable '$VarName' exists, updating..."
        $secretFlag = if ($IsSecret) { '--secret', 'true' } else { @() }
        az pipelines variable-group variable update `
            --group-id $GroupId `
            --name $VarName `
            --value $VarValue `
            --org $OrgUrl `
            --project $Project `
            @secretFlag `
            --output none 2>&1 | Out-Null
    }
    else {
        Write-Host "  Variable '$VarName' does not exist, creating..."
        $secretFlag = if ($IsSecret) { '--secret', 'true' } else { @() }
        az pipelines variable-group variable create `
            --group-id $GroupId `
            --name $VarName `
            --value $VarValue `
            --org $OrgUrl `
            --project $Project `
            @secretFlag `
            --output none 2>&1 | Out-Null
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Successfully set '$VarName'"
    }
    else {
        Write-Warning "  Failed to set '$VarName'"
    }
}

# Add ACR_USERNAME (non-secret)
Set-VariableGroupVariable -GroupId $groupId -VarName 'ACR_USERNAME' -VarValue $acrUsername -IsSecret $false

# Add ACR_PASSWORD (secret)
Set-VariableGroupVariable -GroupId $groupId -VarName 'ACR_PASSWORD' -VarValue $acrPassword -IsSecret $true

Write-Host ""
Write-Host "✅ Successfully added ACR credentials to variable group '$VariableGroupName'"
Write-Host "   - ACR_USERNAME: $acrUsername"
Write-Host "   - ACR_PASSWORD: ******** (secret)"
