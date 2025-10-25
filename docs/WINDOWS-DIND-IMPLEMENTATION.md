# Windows Docker-in-Docker (DinD) Implementation

## Summary

This document describes the implementation of Windows Docker-in-Docker (DinD) support for Azure DevOps self-hosted agents running in Kubernetes.

## Platform Support

| Platform | Linux DinD | Windows DinD |
|----------|------------|--------------|
| **Azure AKS** | ✅ Supported | ✅ Supported (Manual Installation) |
| **AKS on Azure Stack HCI (Azure Local)** | ✅ Supported | ✅ Supported (Manual Installation) |

### Windows DinD Support Details

- **Azure AKS**: Windows DinD is **supported** via manual Docker Engine installation using hostProcess pods. See `docs/WINDOWS-DIND-AZURE-AKS-MANUAL-INSTALLATION.md` for step-by-step guide.
- **AKS-HCI (Azure Local)**: Windows DinD is **supported** using the same manual installation process. See `docs/WINDOWS-DIND-WORKING-SOLUTION.md` for AKS-HCI specific guide.
- **Linux DinD**: Works on **both platforms** because Linux containers support privileged mode and can run dockerd internally without host dependencies.

**Key Finding**: Both Azure AKS and AKS-HCI use containerd as the Kubernetes container runtime. Docker Engine can be manually installed on both platforms using identical procedures, and coexists with containerd without conflicts.

## Problem Statement

Windows DinD agents were failing with the error:
```
failed to load vmcompute.dll, ensure that the Containers feature is installed
```

This occurred because:
1. Windows containers cannot run `dockerd` without the Windows Containers feature installed on the host
2. Unlike Linux, Windows doesn't support privileged containers that can install kernel features
3. The Helm chart was mounting a Linux Docker socket path (`/var/run/docker.sock`) instead of the Windows named pipe
4. Azure AKS Windows nodes have additional restrictions preventing Docker Engine installation

## Solution Architecture

Windows DinD requires a different approach than Linux:

### 1. Host-Level Docker Installation
- Docker Engine must be installed directly on Windows nodes using **hostProcess pods**
- The existing `scripts/Install-DockerOnWindowsNodes.ps1` handles this by:
  - Creating a hostProcess pod that runs with `NT AUTHORITY\SYSTEM` privileges
  - Installing the Windows Containers feature
  - Installing and configuring Docker Engine
  - Creating the named pipe `\\.\pipe\docker_engine`

### 2. Helm Chart Support
- Windows deployment template now conditionally mounts the Docker pipe when DinD is enabled
- Volume mount: `\\.\pipe\docker_engine` (Windows named pipe path)
- New `windows.dind.enabled` values configuration

### 3. Pipeline Integration

- Deploy pipeline can run Docker installation when `windowsImageVariant: 'dind'`
- Installation happens before Helm deployment to ensure Docker is available
- **Supported on both Azure AKS and AKS-HCI** via manual installation process

## Implementation Changes

### 1. Pipeline: `.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml`

Added a new conditional step that runs when deploying Windows DinD agents:

```yaml
- ${{ if and(eq(parameters.deployWindows, true), eq(parameters.windowsImageVariant, 'dind')) }}:
    - task: PowerShell@2
      displayName: Install Docker Engine on Windows nodes (DinD requirement)
      # Calls Install-DockerOnWindowsNodes.ps1 to ensure Docker is present
```

This step:
- Runs only when `windowsImageVariant` parameter is set to `'dind'`
- Can be used for both Azure AKS and AKS-HCI deployments
- Invokes `scripts/Install-DockerOnWindowsNodes.ps1` with appropriate namespace
- Fails the pipeline if Docker installation fails
- Runs before Helm deployment to ensure prerequisites are met
- **Note**: For production use, manual Docker installation is recommended (see platform-specific guides)

### 2. Helm Chart Template: `helm-charts-v2/az-selfhosted-agents/templates/windows-deploy.yaml`

Modified to conditionally mount the Windows Docker pipe:

**Before:**
```yaml
volumeMounts:
- mountPath: /var/run/docker.sock  # Linux path - doesn't work on Windows
  name: docker-volume
volumes:
- name: docker-volume
  hostPath:
    path: /var/run/docker.sock
```

**After:**
```yaml
{{- if .Values.windows.dind }}
{{- if .Values.windows.dind.enabled }}
volumeMounts:
- mountPath: \\.\pipe\docker_engine  # Windows named pipe
  name: docker-pipe
{{- end }}
{{- end }}
volumes:
{{- if .Values.windows.dind }}
{{- if .Values.windows.dind.enabled }}
- name: docker-pipe
  hostPath:
    path: \\.\pipe\docker_engine
{{- end }}
{{- end }}
```

Also added environment variable:
```yaml
- name: ENABLE_DIND
  value: "false"  # Don't start internal dockerd, use host pipe
```

### 3. Helm Values: `helm-charts-v2/az-selfhosted-agents/values.yaml`

Added Windows DinD configuration section:

```yaml
windows:
  enabled: false
  dind:
    enabled: false  # Set true to mount host Docker pipe
  deploy:
    # ... existing deployment config
```

### 4. Deploy Script: `deploy-selfhosted-agents-helm.ps1`

Modified to emit Windows DinD values when variant is `'dind'`:

```powershell
$yamlLines += 'windows:'
$yamlLines += ('  enabled: ' + $enabledWindows)
if ($WindowsImageVariant -eq 'dind') {
    $yamlLines += '  dind:'
    $yamlLines += '    enabled: true'
}
```

### 5. Smoke Test: `.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml`

Enhanced Windows DinD smoke test to:
- Check if Docker named pipe `\\.\pipe\docker_engine` exists (confirms host Docker mount)
- Verify `docker version` works (confirms client-server communication)
- Pull and run test container (validates full Docker functionality)
- **No longer attempts to start Docker service inside container** (correct for DinD architecture)

## Usage

### Prerequisites
1. **For AKS-HCI (Azure Local):**
   - Windows nodes in Kubernetes cluster with `sku=Windows:NoSchedule` taint
   - Full control over Windows nodes to allow Docker Engine installation
   - Azure DevOps PAT token with agent pool management permissions
   - Access to ACR or container registry for agent images

2. **For Azure AKS:**
   - **Windows DinD is not supported** - use standard Windows agents with host Docker socket mount
   - Linux DinD is fully supported

### Deployment for AKS-HCI (Azure Local)
1. Set pipeline parameters:
   - `windowsImageVariant: 'dind'`
   - `useAzureLocal: true`
2. Pipeline automatically:
   - Verifies Windows nodes and taints
   - Installs Docker Engine on Windows nodes via hostProcess pods
   - Deploys Helm chart with DinD configuration
   - Runs validation smoke tests

### Deployment for Azure AKS
1. For **Linux agents**: Set `linuxImageVariant: 'dind'` (fully supported)
2. For **Windows agents**: Use `windowsImageVariant: 'docker'` (standard mode, not DinD)

### Manual Installation (if needed)
```powershell
# Install Docker on Windows nodes
.\scripts\Install-DockerOnWindowsNodes.ps1 -Namespace az-devops-windows-001 -TimeoutSeconds 600 -Verbose

# Deploy agents with DinD
.\deploy-selfhosted-agents-helm.ps1 `
  -AcrName "your-acr" `
  -WindowsImageVariant "dind" `
  -DeployWindows `
  -WindowsVersion "2022" `
  -AzureDevOpsOrgUrl "https://dev.azure.com/your-org" `
  -InstanceNumber "001"
```

## Verification

> **Note**: These verification steps apply to both Azure AKS and AKS-HCI (Azure Local) deployments after manual Docker installation.

1. **Check Docker installation on nodes:**
   ```powershell
   kubectl get nodes -l kubernetes.io/os=windows -o name | ForEach-Object {
     kubectl debug $_ -it --image=mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022 -- pwsh -Command "docker version"
   }
   ```

2. **Check agent pod logs:**
   ```powershell
   kubectl logs -n az-devops-windows-001 -l app=azsh-windows-agent --tail=50
   ```

3. **Run validation pipeline:**
   - Trigger `.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml`
   - Check "Docker DinD smoke test (Windows)" task output

## Differences from Linux DinD

| Aspect | Linux DinD | Windows DinD |
|--------|-----------|--------------|
| **Platform support** | Azure AKS ✅, AKS-HCI ✅ | Azure AKS ✅ (Manual), AKS-HCI ✅ (Manual) |
| Container privilege | `privileged: true` | Not supported |
| Docker daemon | Runs inside container | Runs on host node |
| Access method | Unix socket `/var/run/docker.sock` | Named pipe `\\.\pipe\docker_engine` |
| Installation | Part of container image | Requires hostProcess pod installation |
| Storage | Container volume (`emptyDir`, `hostPath`, `pvc`) | Host filesystem managed by node Docker |

## Limitations

1. **Manual installation required**: Windows DinD requires manual Docker Engine installation on Windows nodes for both Azure AKS and AKS-HCI (see platform-specific guides)
2. **Shared Docker daemon**: All Windows DinD agents on a node share the same Docker daemon
3. **Host dependency**: Requires Docker Engine installed on Windows nodes
4. **No isolation**: Unlike Linux DinD, containers don't get their own Docker daemon
5. **Windows Server only**: Requires Windows Server containers (not Hyper-V isolation)

## Troubleshooting

### Deployment fails with "Windows DinD requested but not supported on Azure AKS"

**Cause**: Outdated deployment script or documentation  
**Fix**: Windows DinD is now supported on both Azure AKS and AKS-HCI via manual Docker installation. Follow the appropriate installation guide:
- Azure AKS: `docs/WINDOWS-DIND-AZURE-AKS-MANUAL-INSTALLATION.md`
- AKS-HCI: `docs/WINDOWS-DIND-WORKING-SOLUTION.md`

### Agent fails with "failed to load vmcompute.dll"

**Cause**: Docker Engine not installed on Windows node  
**Fix**: Follow the manual Docker installation guide for your platform:

- Azure AKS: `docs/WINDOWS-DIND-AZURE-AKS-MANUAL-INSTALLATION.md`
- AKS-HCI: `docs/WINDOWS-DIND-WORKING-SOLUTION.md`

### Smoke test fails with "Docker engine pipe not available"

**Cause**: Docker service not running on host  
**Fix**: Check Docker service status on node:

```powershell
kubectl debug node/<node-name> -it --image=mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022 -- pwsh -Command "Get-Service docker"
```

### Build jobs fail with "Cannot connect to the Docker daemon"

**Cause**: Docker pipe not mounted or wrong path  
**Fix**: Verify Helm values have `windows.dind.enabled: true` and redeploy

## References

- Docker Engine installation script: `scripts/Install-DockerOnWindowsNodes.ps1`
- Linux DinD implementation: `helm-charts-v2/az-selfhosted-agents/templates/linux-deploy.yaml`
- Windows Server containers: <https://learn.microsoft.com/en-us/virtualization/windowscontainers/>
- Kubernetes hostProcess containers: <https://kubernetes.io/docs/tasks/configure-pod-container/create-hostprocess-pod/>

## Future Improvements

1. **Automate Docker installation**: Create automated installation process for both platforms
2. Add health checks for Docker daemon availability
3. Implement Docker version detection and upgrade automation
4. Add metrics/monitoring for Windows DinD agent Docker usage
5. Consider node affinity rules to distribute DinD load
6. Evaluate support for Windows containerd runtime as alternative to Docker Engine
7. **Enhance documentation**: Continue improving platform-specific installation guides and troubleshooting
