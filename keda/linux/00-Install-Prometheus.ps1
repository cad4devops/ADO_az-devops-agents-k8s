# as per https://www.youtube.com/watch?v=3AINqaBwOYs&t

# Install Prometheus and Grafana using helm
$releaseName = "prometheus-stack"
$namespace = "prometheus-stack"

# Install Prometheus and Grafana using helm
Write-Output "Install Prometheus and Grafana using helm"

$kubeContext = "workload-cluster-009-admin@workload-cluster-009"

kubectl config use-context $kubeContext

kubectl get nodes -o wide

# Install Prometheus
#https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install $releaseName prometheus-community/kube-prometheus-stack --namespace $namespace --create-namespace

# to uninstall: helm uninstall $releaseName --namespace prometheus-stack

kubectl get all -n $namespace


# Open a browser and go to http://localhost:3000
# Log in with the username admin and the password prom-operator
helm show values prometheus-community/kube-prometheus-stack > prometheus-default-values.yaml

# Get the Prometheus server URL by running these commands in the same shell:
kubectl port-forward -n $namespace service/prometheus-stack-grafana 3000:80
