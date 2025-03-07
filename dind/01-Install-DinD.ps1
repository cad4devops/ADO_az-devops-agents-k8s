#https://medium.com/@muppedaanvesh/azure-devops-self-hosted-agents-on-kubernetes-part-3-6658d741b369

#$kubeContext = "workload-cluster-009-admin@workload-cluster-009"
$your_tag = "ubuntu-18.04"
$containerRegistryName = "cragentssgvhe4aipy37o.azurecr.io"
$repositoryName = "linux-sh-agent-dind"
$dockerFileName = "./Dockerfile"

docker build --tag "${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:${your_tag}" `
    --tag "${containerRegistryName}/${repositoryName}:latest" `
    --file "$dockerFileName" .

# login to azure container registry
az acr login --name $containerRegistryName

# Push to your registry in azure
docker push "${containerRegistryName}/${repositoryName}:${your_tag}"
docker push "${containerRegistryName}/${repositoryName}:latest"
