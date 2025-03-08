# Ensure you have the Azure DevOps CLI installed and authenticated
# You can install it using: az extension add --name azure-devops

# Set your Azure DevOps organization URL
$organizationUrl = "https://dev.azure.com/cad4devops"

# List all agent pools
az devops configure --defaults organization=$organizationUrl
$agentPools = az pipelines pool list --output json | ConvertFrom-Json

# Display the agent pools
foreach ($pool in $agentPools) {
    Write-Output "Agent Pool Name: $($pool.name)"
    Write-Output "Agent Pool ID: $($pool.id)"
    Write-Output "Is Hosted: $($pool.isHosted)"
    Write-Output "-----------------------------"
}
# Create a new agent pool