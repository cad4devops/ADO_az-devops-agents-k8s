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

        # Ensure there is a sku=Windows:NoSchedule taint (case-sensitive)
        $needsTaint = $true
        if ($taints) {
            foreach ($taint in $taints) {
                Write-Output "  Key: $($taint.key), Value: $($taint.value), Effect: $($taint.effect)"
                if ($taint.key -eq 'sku') {
                    # exact match required: key='sku', value='Windows', effect='NoSchedule'
                    if ($taint.value -ceq 'Windows' -and $taint.effect -ceq 'NoSchedule') {
                        $needsTaint = $false
                    }
                    else {
                        Write-Output "  sku taint present but does not match required value/effect (found value='$($taint.value)', effect='$($taint.effect)')"
                        $needsTaint = $true
                    }
                    break
                }
            }
        }
        else {
            Write-Output "  No taints present on node"
        }

        if ($needsTaint) {
            $desired = 'sku=Windows:NoSchedule'
            Write-Output "  Applying desired taint: $desired"
            # Run kubectl taint and capture output. kubectl returns non-zero exit codes but does not throw,
            # so check $LASTEXITCODE to detect failures.
            $taintCmd = "kubectl taint nodes {0} {1} --overwrite" -f $nodeName, $desired
            Write-Output "  Executing: $taintCmd"
            $taintOutput = & kubectl taint nodes $nodeName $desired --overwrite 2>&1
            if ($LASTEXITCODE -ne 0) {
                $msg = ($taintOutput -join ' ; ')
                Write-Warning ("  Failed to apply taint to {0}: ExitCode={1}; Output={2}" -f $nodeName, $LASTEXITCODE, $msg)
            }
            else {
                Write-Output ("  Applied taint to {0}; kubectl output: {1}" -f $nodeName, ($taintOutput -join ' '))
                # Re-query this node to show the updated taints immediately for verification
                try {
                    $singleNode = kubectl get node $nodeName -o json | ConvertFrom-Json
                    $singleTaints = $singleNode.spec.taints
                    if ($singleTaints) {
                        foreach ($st in $singleTaints) {
                            Write-Output "    Now: Key: $($st.key), Value: $($st.value), Effect: $($st.effect)"
                        }
                    }
                    else { Write-Output "    Now: node has no taints" }
                }
                catch {
                    Write-Warning ("    Failed to re-query taints for {0}: {1}" -f $nodeName, $_.Exception.Message)
                }
            }
        }
    }
    else {
        Write-Output "Node: $nodeName is a Linux node"
        if ($taints) {
            foreach ($taint in $taints) {
                Write-Output "  Key: $($taint.key), Value: $($taint.value), Effect: $($taint.effect)"
            }
        }
        else { Write-Output "Node: $nodeName has no taints" }
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
