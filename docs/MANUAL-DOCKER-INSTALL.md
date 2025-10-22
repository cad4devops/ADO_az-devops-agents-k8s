# Manual Docker Installation on Windows Nodes

If you need to install Docker Engine on Windows nodes without re-running the full deploy pipeline, follow these steps.

## Prerequisites

- `kubectl` configured with access to your cluster
- PowerShell 7 (pwsh)
- Cluster has Windows nodes with `kubernetes.io/os=windows` label

## Install Docker on All Windows Nodes

```powershell
# Navigate to repository root
cd F:\src\cad4devops\Cad4devops\ADO_az-devops-agents-k8s

# Set your instance number (should match your deployment)
$instance = "001"
$namespace = "az-devops-windows-$instance"

# Run the Docker installer script
.\scripts\Install-DockerOnWindowsNodes.ps1 `
  -Namespace $namespace `
  -TimeoutSeconds 600 `
  -Verbose
```

## What This Does

The script will:

1. Query all Windows nodes in the cluster
2. For each node, create a **hostProcess pod** that:
   - Runs with `NT AUTHORITY\SYSTEM` privileges
   - Installs the Windows Containers feature
   - Downloads and installs Docker Engine
   - Configures the Docker service to auto-start
   - Creates the named pipe `\\.\pipe\docker_engine`
3. Annotate nodes with `agents.cad4devops.dev/docker-installed: true`
4. Clean up installer pods after completion

## Verify Installation

Check Docker is running on each node:

```powershell
# List Windows nodes
kubectl get nodes -l kubernetes.io/os=windows

# For each node, check Docker service status (example for node 'akswin000000')
kubectl debug node/akswin000000 `
  -it `
  --image=mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022 `
  -- pwsh -Command "Get-Service docker; Test-Path '\\.\pipe\docker_engine'"
```

Expected output:
```
Status   Name               DisplayName
------   ----               -----------
Running  docker             Docker Engine

True
```

## Check Installation Logs

If installation failed, check the installer pod logs:

```powershell
# List installer pods
kubectl get pods -n az-devops-windows-001 -l app=docker-installer

# View logs from a specific installer pod
kubectl logs -n az-devops-windows-001 docker-installer-<pod-suffix>
```

## Re-run Validation

After Docker is installed, trigger the validation pipeline manually or re-run the deploy pipeline (which will skip installation if Docker is already present).

## Troubleshooting

### "No Windows nodes found"
- Ensure your cluster has Windows nodes: `kubectl get nodes -l kubernetes.io/os=windows`
- Check node taints allow scheduling: `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints`

### "Installer pod Failed"
- Check pod logs: `kubectl logs -n <namespace> <pod-name>`
- Common issues:
  - Insufficient disk space on node
  - Network connectivity issues downloading Docker
  - Node doesn't support required Windows features

### "Docker service not starting"
- The script includes retry logic and service start commands
- If service still won't start, may need manual intervention on the node
- Check Windows Event Logs on the node for detailed errors

## Clean Up Failed Installations

If you need to remove failed installer pods:

```powershell
kubectl delete pods -n az-devops-windows-001 -l app=docker-installer
```

To uninstall Docker from nodes (requires manual intervention):

```powershell
# Create a cleanup hostProcess pod (replace <node-name>)
kubectl debug node/<node-name> `
  -it `
  --image=mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022 `
  -- pwsh -Command "Stop-Service docker; Remove-Item -Path 'C:\Program Files\Docker' -Recurse -Force"
```
