# Windows DinD Failure in AKS - Root Cause and Solution

## Issue Summary

Windows DinD agents are failing in AKS with the error:
```
Docker engine pipe '\\.\pipe\docker_engine' not found. This Windows DinD agent should have the host Docker pipe mounted.
```

## Root Cause

**AKS uses containerd, not Docker Engine on Windows nodes**

- **AKS**: Windows nodes use `containerd://1.7.20+azure` as the container runtime
- **AKS-HCI**: Had Docker Engine installed by default, which provided the `\\.\pipe\docker_engine` named pipe
- **Impact**: The DinD agent containers can't access a Docker daemon because it doesn't exist

Verified via:
```powershell
kubectl get nodes -o wide
# Shows: Container Runtime Version: containerd://1.7.20+azure
```

## Solutions

### ⚠️ IMPORTANT DISCOVERY

**Docker Engine cannot be installed on managed AKS Windows nodes.** AKS uses immutable, managed node images and does not allow installing additional Windows services like Docker Engine. This is by design for security and supportability.

### Option 1: Use Regular Windows Agents (NOT DinD) ⭐ **RECOMMENDED FOR AKS**

Since Docker Engine cannot be installed on AKS Windows nodes, the simplest solution is to use regular Windows agent images without DinD.

**How to disable DinD:**

In your pipeline parameters:

```yaml
parameters:
  - name: windowsImageVariant
    type: string
    default: "docker"  # Use "docker" instead of "dind"
```

Or update Helm deployment values:

```yaml
windows:
  dind:
    enabled: false
```

Then redeploy:

```powershell
kubectl rollout restart deployment -n az-devops-windows-002
```

### Option 2: Use Azure Container Instances for DinD

For workloads that absolutely need Docker-in-Docker, use Azure Container Instances which support privileged containers.

### Option 3: Continue Using AKS-HCI for DinD

Keep DinD workloads on AKS-HCI (where Docker is pre-installed) and use standard AKS for regular agents.

### Option 4: Use Containerd Directly (COMPLEX)

Modify agent images to use `nerdctl` or `ctr` commands instead of `docker`. Requires:

- Installing nerdctl in the agent image
- Updating all scripts that call `docker` to use `nerdctl`
- Mounting containerd socket instead: `\\.\pipe\containerd-containerd`

## Current Status

- **AKS Cluster**: Windows node `akswinp000000` is running with containerd
- **Windows Agent Pods**: 5 pods running in namespace `az-devops-windows-002`
- **Docker Status**: Not installed on Windows nodes
- **DinD Tests**: Failing with "pipe not found" error

## Next Steps

1. **Immediate**: Deploy the Docker installer DaemonSet (Option 1, Method B above)
2. **Wait**: For Docker installation to complete (~5-10 minutes)
3. **Verify**: Docker service is running on Windows nodes
4. **Restart**: Windows agent pods to pick up the new Docker socket:
   ```powershell
   kubectl rollout restart deployment/azsh-windows-agent -n az-devops-windows-002
   ```
5. **Test**: Run the pipeline again with DinD smoke tests

## Additional Notes

### Why AKS-HCI worked
AKS-HCI (Azure Stack HCI) deploys Windows nodes with Docker Engine pre-installed for container management, which is why your DinD agents worked there without modifications.

### Why standard AKS doesn't have Docker
Microsoft moved to containerd as the standard container runtime across all AKS node pools for better performance, security, and Kubernetes alignment. Docker Engine is considered an optional component.

### Alternative: Use AKS with Docker pre-installed
You could create a custom AKS Windows node pool with Docker pre-installed using a custom VHD, but this is complex and not recommended for standard deployments.

## Files Referenced

- Pipeline: `.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml`
- Docker installer script: `scripts/Install-DockerOnWindowsNodes.ps1`
- Helm chart values: `helm-charts-v2/azdevops-agent/values.yaml`

## Verification Commands

```powershell
# Check node runtime
kubectl get nodes -o wide

# Check Windows agent pods
kubectl get pods -n az-devops-windows-002 -o wide

# Check Docker service on Windows node
kubectl debug node/akswinp000000 -it --image=mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022 -- pwsh -Command "Get-Service docker"

# Check agent deployment volumes
kubectl get deployment -n az-devops-windows-002 azsh-windows-agent -o yaml | Select-String -Pattern "volumeMount|hostPath|docker" -Context 3
```
