$your_tag = "yourtag"
$containerRegistryName = "cragentssgvhe4aipy37o.azurecr.io"

docker build --tag "azsh-linux-agent:${your_tag}" `
    --tag "${containerRegistryName}/azsh-linux-agent:${your_tag}" `
    --tag "${containerRegistryName}/azsh-linux-agent:latest" `
    --file "./azsh-linux-agent.dockerfile" .

# Push to your registry in azure
docker push "${containerRegistryName}/azsh-linux-agent:${your_tag}"
docker push "${containerRegistryName}/azsh-linux-agent:latest"