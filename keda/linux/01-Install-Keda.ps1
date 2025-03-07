#https://medium.com/@muppedaanvesh/azure-devops-self-hosted-agents-on-kubernetes-part-3-6658d741b369

$kubeContext = "workload-cluster-009-admin@workload-cluster-009"
$namespaceKeda = "keda"
$namespacePrometheus = "prometheus-stack"

kubectl config use-context $kubeContext

kubectl get nodes -o wide

helm repo add kedacore https://kedacore.github.io/charts

helm repo update

helm install keda kedacore/keda --namespace $namespaceKeda --create-namespace

kubectl get all -n $namespaceKeda

# # Get the Prometheus server URL by running these commands in the same shell:
# kubectl port-forward -n $namespacePrometheus service/prometheus-stack-grafana 3000:80
