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
    $windowsNamespace = "az-devops-windows-$instanceNumber"
)

Write-Output "Linux Namespace: $linuxNamespace"
Write-Output "Windows Namespace: $windowsNamespace"

kubectl create namespace $linuxNamespace --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $windowsNamespace --dry-run=client -o yaml | kubectl apply -f -

helm install az-selfhosted-agents ./az-selfhosted-agents `
    --set windows.enabled=true `
    --set linux.enabled=true `
    --create-namespace `
    --namespace $linuxNamespace

# to uninstall
# helm uninstall az-selfhosted-agents --namespace $linuxNamespace
