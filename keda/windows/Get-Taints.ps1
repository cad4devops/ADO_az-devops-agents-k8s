# Get all nodes
$nodes = kubectl get nodes -o json | ConvertFrom-Json

# Loop through each node and display its taints
foreach ($node in $nodes.items) {
    $nodeName = $node.metadata.name
    $taints = $node.spec.taints
    # determine if the node is windows or linux
    $os = $node.metadata.labels."kubernetes.io/os"
    if ($os -eq "windows") {
        Write-Output "Node: $nodeName is a Windows node"
        # # # if node is windows, add taint
        # Write-Host "  Adding taint os=windows:NoSchedule"
        # kubectl taint nodes $nodeName os=windows:NoSchedule
    }
    else {
        Write-Output "Node: $nodeName is a Linux node"
    }
    # Display taints if they exist
    if ($taints) {
        Write-Output "Node: $nodeName"
        foreach ($taint in $taints) {
            Write-Output "  Key: $($taint.key), Value: $($taint.value), Effect: $($taint.effect)"
            # # if node is windows, remove the taint
            # if ($os -eq "windows") {
            #     Write-Output "  Removing taint $($taint.key)"
            #     kubectl taint nodes $nodeName sku:NoSchedule-
            # } 
            # if key is sku, remove the taint
            if ($taint.key -eq "sku") {
                Write-Output "  Removing taint $($taint.key)"
                kubectl taint nodes $nodeName sku:NoSchedule-
            }
            else {
                Write-Host "  No taints to remove"
            }          
        }        
    }
    else {
        Write-Output "Node: $nodeName has no taints"
    }
}

# Display all nodes
kubectl get nodes -o wide

# Display all taints
# Get all nodes
$nodes = kubectl get nodes -o json | ConvertFrom-Json

# Loop through each node and display its taints
foreach ($node in $nodes.items) {
    $nodeName = $node.metadata.name
    $taints = $node.spec.taints
    if ($taints) {
        Write-Output "Node: $nodeName"
        foreach ($taint in $taints) {
            Write-Output "  Key: $($taint.key), Value: $($taint.value), Effect: $($taint.effect)"
        }
    }
    else {
        Write-Output "Node: $nodeName has no taints"
    }
}
