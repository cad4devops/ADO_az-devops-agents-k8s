#https://medium.com/@muppedaanvesh/azure-devops-self-hosted-agents-on-kubernetes-part-3-6658d741b369

$kubeContext = "my-workload-cluster-007-admin@my-workload-cluster-007"
$namespaceKeda = "keda"
$namespacePrometheus = "prometheus-stack"
$yamlSecretFileTemplate = "keda-secret.template.yaml"
$yamlSecretFile = "keda-secret.yaml"
$namespace = "az-devops-linux"
$triggerAuthTemplateFile = "trigger-auth.template.yaml"
$triggerAuthFile = "trigger-auth.yaml"
$kedaScaledObjectTemplateFile = "azure-pipelines-scaledobject.template.yaml"
$kedaScaledObjectFile = "azure-pipelines-scaledobject.yaml"

# Replace the placeholder with the actual value
$template = Get-Content $yamlSecretFileTemplate
$template = $template -replace "__NAMESPACE__", $namespace
# get environment variable
$patToken = ${env:DevOps-Shield-ADO-PAT-TOKEN-TENANT-e21f4f7c-edfd-4ab7-88ae-a4acdf139685}
$patTokenBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($patToken))
$template = $template -replace "__PAT_TOKEN__", $patTokenBase64

# Write the updated content to the yaml file
$template | Set-Content $yamlSecretFile

# Replace the placeholder with the actual value
$template = Get-Content $triggerAuthTemplateFile
$template = $template -replace "__NAMESPACE__", $namespace

# Write the updated content to the yaml file
$template | Set-Content $triggerAuthFile

# Replace the placeholder with the actual value
$template = Get-Content $kedaScaledObjectTemplateFile
$template = $template -replace "__NAMESPACE__", $namespace

# Write the updated content to the yaml file
$template | Set-Content $kedaScaledObjectFile

kubectl config use-context $kubeContext
kubectl apply -f $yamlSecretFile
kubectl apply -f $triggerAuthFile
kubectl apply -f $kedaScaledObjectFile