$your_tag = "yourtag"
$containerRegistryName = "cragentssgvhe4aipy37o.azurecr.io"
$repositoryName = "azsh-windows-agent"

docker build --tag "${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:latest" `
    --file "./Dockerfile.${repositoryName}" .

# Push to your registry in azure
docker push "${containerRegistryName}/${repositoryName}:${your_tag}"
docker push "${containerRegistryName}/${repositoryName}:latest"