$yamlSecretFile = "linux-sh-agent-secret.yaml"
$yamlSecretFileTemplate = "linux-sh-agent-secret.template.yaml"
$yamlDeploymentFile = "linux-sh-agent-deployment.yaml"
$yamlDeploymentFileTemplate = "linux-sh-agent-deployment.template.yaml"
$kubeContext = "workload-cluster-009-admin@workload-cluster-009"
$namespace = "az-devops-linux"
$poolName = if ($PSBoundParameters.ContainsKey('UseAzureLocal') -and $UseAzureLocal) { "KubernetesPoolOnPremLinux" } else { "KubernetesPoolLinux" }
$azureDevOpsUrl = "https://dev.azure.com/cad4devops"

# Parameters: allow overriding registry, user and image via parameters or env vars
param(
    [string]$DockerRegistryServer = $env:ACR_NAME,
    [string]$DockerUser = $env:ACR_USER,
    [string]$ImageName = $env:LINUX_IMAGE_NAME,
    # Default ACR short name (no .azurecr.io). Can be overridden by passing this parameter
    # or by setting the DEFAULT_ACR environment variable in CI.
    [string]$DefaultAcr = 'cragents003c66i4n7btfksg'
)

# Resolve Docker registry server: prefer explicit param/env, then DEFAULT_ACR, then built-in fallback
if (-not $DockerRegistryServer) {
    if ($env:DEFAULT_ACR) {
        $DockerRegistryServer = $env:DEFAULT_ACR
    } elseif ($DefaultAcr) {
        $DockerRegistryServer = $DefaultAcr
    } else {
        $DockerRegistryServer = 'cragents003c66i4n7btfksg'
    }
}

# If unqualified short name provided, append azurecr.io
if ($DockerRegistryServer -and ($DockerRegistryServer -notmatch '\.')) {
    Write-Host "DockerRegistryServer '$DockerRegistryServer' appears unqualified; appending '.azurecr.io' to form FQDN"
    $DockerRegistryServer = "$DockerRegistryServer.azurecr.io"
}

# Derive ACR short name for az CLI (az acr expects the short name)
$dockerAcrShort = if ($DockerRegistryServer -match '\.') { $DockerRegistryServer.Split('.')[0] } else { $DockerRegistryServer }

# Docker user defaults to the ACR short name when not provided
if (-not $DockerUser) { $DockerUser = $dockerAcrShort }

# Compose image name if not provided
if (-not $ImageName) { $ImageName = "$DockerRegistryServer/linux-sh-agent-docker:latest" }

# Replace the placeholder with the actual value
$template = Get-Content $yamlSecretFileTemplate
$template = $template -replace "__NAMESPACE__", $namespace
# get environment variable
$patToken = ${env:DevOps-Shield-ADO-PAT-TOKEN-TENANT-e21f4f7c-edfd-4ab7-88ae-a4acdf139685}
$patTokenBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($patToken))
$template = $template -replace "__PAT_TOKEN__", $patTokenBase64
$poolNameBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($poolName))
$template = $template -replace "__POOL_NAME__", $poolNameBase64
$azureDevOpsUrlBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($azureDevOpsUrl))
$template = $template -replace "__AZURE_DEVOPS_URL__", $azureDevOpsUrlBase64

# Write the updated content to the yaml file
$template | Set-Content $yamlSecretFile

# Replace the placeholder with the actual value
$template = Get-Content $yamlDeploymentFileTemplate
$template = $template -replace "__NAMESPACE__", $namespace
$template = $template -replace "__IMAGE_NAME__", $imageName

# Write the updated content to the yaml file
$template | Set-Content $yamlDeploymentFile

kubectl config use-context $kubeContext

kubectl get nodes -o wide

# create namespace if not exists
kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f -

# get namespace
kubectl get namespace $namespace

# Create a secret for the docker registry
# Use the ACR short name when calling az acr credential show (az expects the registry short name)
$dockerPassword = az acr credential show --name $dockerAcrShort --query "passwords[0].value" -o tsv

kubectl create secret docker-registry regsecret `
    --docker-server=$dockerRegistryServer `
    --docker-username=$dockerUser `
    --docker-password=$dockerPassword `
    --namespace=$namespace

# # double check the secret
# kubectl get secret regsecret -n $namespace -o jsonpath="{.data.\.dockerconfigjson}" # | base64 --decode > config.json
# #cat config.json

kubectl apply -f $yamlDeploymentFile
kubectl apply -f $yamlSecretFile

# Verify the newly created pods and secrets status using below command.
kubectl get pods -n $namespace
kubectl get secrets -n $namespace