#https://medium.com/@muppedaanvesh/azure-devops-self-hosted-agents-on-kubernetes-part-3-6658d741b369

$kubeContext = "my-workload-windows-cluster-001-admin@my-workload-windows-cluster-001"
$namespaceKeda = "keda"
$clusterName = "my-workload-windows-cluster-001"
$nodePoolName = "win-pool-002"

kubectl config use-context $kubeContext

kubectl get nodes -o wide

#Set-AksHciNodePool -clusterName $clusterName -name $nodePoolName -count 0

helm repo add kedacore https://kedacore.github.io/charts

helm repo update

helm install keda kedacore/keda --namespace $namespaceKeda --create-namespace

kubectl get all -n $namespaceKeda


