# Ensure you have the Azure DevOps CLI installed and authenticated
# You can install it using: az extension add --name azure-devops

[CmdletBinding()]
param (
    [Parameter()]
    [string] $organizationUrl = "https://dev.azure.com/cad4devops",
    [Parameter(Mandatory = $false)]
    [string]$instanceName = "001"    
)

# get pat from environment variable
$pat = $env:AZURE_DEVOPS_EXT_PAT
if (-not $pat) {
    Write-Error "Please set the AZURE_DEVOPS_EXT_PAT environment variable."
    exit 1
}

# ech parameters
Write-Output "Organization URL: $organizationUrl"
Write-Output "Instance Name: $instanceName"
# Set the Azure DevOps organization URL and personal access token (PAT)
Write-Output "Using PAT: $($pat.Substring(0, 4))... (truncated for security)"
# Set the Azure DevOps organization URL and personal access token (PAT)
Write-Output "Using Organization URL: $organizationUrl"

# List all agent pools
az devops configure --defaults organization=$organizationUrl
$agentPools = az pipelines pool list --output json | ConvertFrom-Json

Write-Output "Listing all agent pools:" 

# Display the agent pools
foreach ($pool in $agentPools) {
    Write-Output "Agent Pool Name: $($pool.name)"
    Write-Output "Agent Pool ID: $($pool.id)"
    Write-Output "Is Hosted: $($pool.isHosted)"
    Write-Output "-----------------------------"
}
# Create a new agent pool
$poolName = "KubernetesLinuxPool${instanceName}"
$poolDescription = "Kubernetes Linux Pool for $instanceName"

$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")))"
}

$body = @{
    "name"        = $poolName
    "description" = $poolDescription
    "isHosted"    = $false
} | ConvertTo-Json

$url = "$organizationUrl/_apis/distributedtask/pools?api-version=7.1"

Write-Output "Creating agent pool: $poolName"
Write-Output "Request URL: $url"
Write-Output "Request Body: $body"
# Make the API call to create the agent pool
try {
    $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body
    Write-Output "Agent pool created successfully."
}
catch {
    Write-Error "Failed to create agent pool: $_"
    exit 1
}