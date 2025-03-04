$your_tag = "windows-2025"
$containerRegistryName = "cragentssgvhe4aipy37o.azurecr.io"
$repositoryName = "windows-sh-agent"

docker build --tag "${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:latest" `
    --file "./Dockerfile.${repositoryName}" .

# login to azure container registry
az acr login --name $containerRegistryName

# Push to your registry in azure
docker push "${containerRegistryName}/${repositoryName}:${your_tag}"
docker push "${containerRegistryName}/${repositoryName}:latest"