param (
    [Parameter()]
    [string] $namespaceKeda = "keda",
    [Parameter()]
    [string] $releaseName = "keda"
)

kubectl get nodes -o wide

helm repo add kedacore https://kedacore.github.io/charts

helm repo update

# check if keda is already installed
$kedaInstalled = helm list -n $namespaceKeda | Select-String -Pattern $releaseName
if ($kedaInstalled) {
    Write-Output "Keda is already installed. Skipping..."
    #helm uninstall $releaseName -n $namespaceKeda
}
else {
    Write-Output "Keda is not installed. Installing..."
    helm install $releaseName kedacore/keda `
        --namespace $namespaceKeda `
        --create-namespace
}
kubectl get all -n $namespaceKeda


