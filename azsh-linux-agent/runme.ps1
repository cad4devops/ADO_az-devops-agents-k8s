$your_tag = "yourtag"

docker build --tag "azsh-linux-agent:${your_tag}" --file "./azsh-linux-agent.dockerfile" .

# Push to your registry in azure
docker tag