# create namespaces if not exists
$linuxNamespace = "az-devops-linux"
$windowsNamespace = "az-devops-windows"

kubectl create namespace $linuxNamespace --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $windowsNamespace --dry-run=client -o yaml | kubectl apply -f -

helm install az-selfhosted-agents ./az-selfhosted-agents `
    --set windows.enabled=true `
    --set linux.enabled=true `
    --create-namespace `
    --namespace $linuxNamespace

# to uninstall
# helm uninstall az-selfhosted-agents --namespace $linuxNamespace
