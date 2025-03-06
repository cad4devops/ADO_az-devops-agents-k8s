$yamlSecretFile = "windows-sh-agent-secret.yaml"
$yamlSecretFileTemplate = "windows-sh-agent-secret.template.yaml"
$yamlDeploymentFile = "windows-sh-agent-deployment.yaml"
$yamlDeploymentFileTemplate = "windows-sh-agent-deployment.template.yaml"
$kubeContext = "my-workload-cluster-008-admin@my-workload-cluster-008"
$namespace = "az-devops-windows"
$poolName = "KubernetesPoolWindows"
$azureDevOpsUrl = "https://dev.azure.com/cad4devops"
$dockerRegistryServer = "cragentssgvhe4aipy37o.azurecr.io"
$dockerUser = "cragentssgvhe4aipy37o"
$imageName = "cragentssgvhe4aipy37o.azurecr.io/windows-sh-agent:latest"

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
$dockerPassword = az acr credential show --name $dockerRegistryServer --query "passwords[0].value" -o tsv

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