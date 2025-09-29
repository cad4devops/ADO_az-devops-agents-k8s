$yamlSecretFile = "windows-sh-agent-secret.yaml"
$yamlSecretFileTemplate = "windows-sh-agent-secret.template.yaml"
$yamlDeploymentFile = "windows-sh-agent-deployment.yaml"
$yamlDeploymentFileTemplate = "windows-sh-agent-deployment.template.yaml"
$kubeContext = "workload-cluster-009-admin@workload-cluster-009"
$namespace = "az-devops-windows"
$poolName = if ($PSBoundParameters.ContainsKey('UseAzureLocal') -and $UseAzureLocal) { "KubernetesPoolOnPremWindows" } else { "KubernetesPoolWindows" }
$azureDevOpsUrl = "https://dev.azure.com/cad4devops"

# Parameters to allow overriding registry, user and image
param(
    [string]$DockerRegistryServer = $env:ACR_NAME,
    [string]$DockerUser = $env:ACR_USER,
    [string]$ImageName = $env:WINDOWS_IMAGE_NAME,
    [string]$WindowsVersion = '2022',
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

# Derive ACR short name for az CLI
$dockerAcrShort = if ($DockerRegistryServer -match '\.') { $DockerRegistryServer.Split('.')[0] } else { $DockerRegistryServer }

# Docker user defaults to the ACR short name when not provided
if (-not $DockerUser) { $DockerUser = $dockerAcrShort }

# Compose image name if not provided
if (-not $ImageName) { $ImageName = "$DockerRegistryServer/windows-sh-agent-${WindowsVersion}:latest" }

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
# Use the ACR short name when calling az acr credential show
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