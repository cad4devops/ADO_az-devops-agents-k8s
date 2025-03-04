$resourceGroupName = "rg-aks-demo"
$location = "canadacentral"
$deploymentName = "deployContainerRegistry"
$subscriptionName = "Production"

# login to azure
az login
az account set --subscription "$subscriptionName"

# create resource group
az group create --name $resourceGroupName `
    --location $location

# create container registry
az deployment group create --resource-group $resourceGroupName `
    --template-file main.bicep `
    --name "$deploymentName"

# get the container registry name from the output
$containerRegistryName = az deployment group show --resource-group $resourceGroupName `
    --name $deploymentName `
    --query "properties.outputs.containerRegistryName.value" -o tsv

Write-Output "Container Registry Name: $containerRegistryName"

# get the container registry login server from the output
$containerRegistryLoginServer = az deployment group show  --resource-group $resourceGroupName `
    --name $deploymentName `
    --query "properties.outputs.containerRegistryLoginServer.value" -o tsv

Write-Output "Container Registry Login Server: $containerRegistryLoginServer"

# login to the container registry
Write-Output "Logging in to the container registry"
az acr login --name $containerRegistryName `
    --resource-group $resourceGroupName