#https://medium.com/@muppedaanvesh/azure-devops-self-hosted-agents-on-kubernetes-part-3-6658d741b369

$kubeContext = "my-workload-cluster-008-admin@my-workload-cluster-008"
$your_tag = "ubuntu-18.04"
$containerRegistryName = "cragentssgvhe4aipy37o.azurecr.io"
$repositoryName = "linux-sh-agent-dind"
$dockerFileName = "./Dockerfile"

kubectl config use-context $kubeContext

kubectl get nodes -o wide

# loop through the nodes and install sysbox - powershell
kubectl get nodes -o wide | ForEach-Object {
    $node = $_.split(" ")[0]
    Write-Host "Found potential node $node"
    # check if $node not equal to NAME
    if ($node -ne "NAME") {
        Write-Output "Installing sysbox on node $node"        
        #Add labels to the target worker nodes
        #kubectl label nodes $node sysbox-install=yes
        # delete the label
        kubectl label nodes $node sysbox-install-
    }
    else {
        Write-Output "Skipping node $node"
    }
}

#kubectl apply -f sysbox-daemon.yaml
#Make sure the sysbox-deploy-k8s daemonset pods are up and runing without any errors.

Write-Output "Verify the newly created pods and secrets status using below command."
kubectl get pods -n kube-system -l sysbox-install=yes
Write-Output "Verify the nodes with sysbox installed"
kubectl get nodes -l sysbox-install=yes

# ERROR: Sysbox is not supported on this host's distro (mariner-2.0).

