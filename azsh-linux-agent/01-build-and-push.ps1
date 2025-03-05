$your_tag = "ubuntu-24.04"
$containerRegistryName = "cragentssgvhe4aipy37o.azurecr.io"
$repositoryName = "linux-sh-agent-docker"
$dockerFileName = "./Dockerfile.${repositoryName}"

docker build --tag "${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:latest" `
    --file "$dockerFileName" .

# login to azure container registry
az acr login --name $containerRegistryName

# Push to your registry in azure
docker push "${containerRegistryName}/${repositoryName}:${your_tag}"
docker push "${containerRegistryName}/${repositoryName}:latest"