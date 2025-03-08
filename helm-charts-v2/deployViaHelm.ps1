# create namespaces if not exists


param (
    [Parameter()]
    [string]
    $instanceNumber = "001",
    [Parameter()]
    [string]
    $linuxNamespace = "az-devops-linux-$instanceNumber",
    [Parameter()]
    [string]
    $windowsNamespace = "az-devops-windows-$instanceNumber",
    [Parameter()]
    [string]
    $linuxPoolName = "KubernetesPoolLinux",
    [Parameter()]
    [string]        
    $windowsPoolName = "KubernetesPoolWindows"
)

Write-Output "Linux Namespace: $linuxNamespace"
Write-Output "Windows Namespace: $windowsNamespace"
Write-Output "Linux Pool Name: $linuxPoolName"
Write-Output "Windows Pool Name: $windowsPoolName"

# convert the pool name to base64
$linuxPoolNameBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($linuxPoolName))
$windowsPoolNameBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($windowsPoolName))

Write-Output "Linux Pool Name Base64: $linuxPoolNameBase64"
Write-Output "Windows Pool Name Base64: $windowsPoolNameBase64"

kubectl create namespace $linuxNamespace --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $windowsNamespace --dry-run=client -o yaml | kubectl apply -f -

helm install az-selfhosted-agents ./az-selfhosted-agents `
    --set windows.enabled=true `
    --set linux.enabled=true `
    --create-namespace `
    --namespace $linuxNamespace

# to uninstall
# helm uninstall az-selfhosted-agents --namespace $linuxNamespace
