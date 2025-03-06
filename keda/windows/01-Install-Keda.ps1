#https://medium.com/@muppedaanvesh/azure-devops-self-hosted-agents-on-kubernetes-part-3-6658d741b369

$kubeContext = "my-workload-cluster-008-admin@my-workload-cluster-008"
$namespaceKeda = "keda"

kubectl config use-context $kubeContext

kubectl get nodes -o wide

#Set-AksHciNodePool -clusterName $clusterName -name $nodePoolName -count 0

helm repo add kedacore https://kedacore.github.io/charts

helm repo update

helm install keda kedacore/keda --namespace $namespaceKeda --create-namespace

kubectl get all -n $namespaceKeda


