# Windows Docker-in-Docker (DinD) Implementation

## Summary

This document describes the implementation of Windows Docker-in-Docker (DinD) support for Azure DevOps self-hosted agents running in Kubernetes.

## Problem Statement

Windows DinD agents were failing with the error:
```
failed to load vmcompute.dll, ensure that the Containers feature is installed
```

This occurred because:
1. Windows containers cannot run `dockerd` without the Windows Containers feature installed on the host
2. Unlike Linux, Windows doesn't support privileged containers that can install kernel features
3. The Helm chart was mounting a Linux Docker socket path (`/var/run/docker.sock`) instead of the Windows named pipe

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
- Deploy pipeline automatically runs Docker installation when `windowsImageVariant: 'dind'`
- Installation happens before Helm deployment ensures Docker is available

## Implementation Changes

### 1. Pipeline: `.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml`

Added a new conditional step that runs when deploying Windows DinD agents:

```yaml
- ${{ if eq(parameters.windowsImageVariant, 'dind') }}:
    - task: PowerShell@2
      displayName: Install Docker Engine on Windows nodes (DinD requirement)
      # Calls Install-DockerOnWindowsNodes.ps1 to ensure Docker is present
```

This step:
- Runs only when `windowsImageVariant` parameter is set to `'dind'`
- Invokes `scripts/Install-DockerOnWindowsNodes.ps1` with appropriate namespace
- Fails the pipeline if Docker installation fails
- Runs before Helm deployment to ensure prerequisites are met

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
- Attempt to start Docker service if present
- Launch `dockerd` manually if service not found
- Capture and display stderr output for diagnostics
- Clean up background dockerd process after test

## Usage

### Prerequisites
1. Windows nodes in Kubernetes cluster with `sku=Windows:NoSchedule` taint
2. Azure DevOps PAT token with agent pool management permissions
3. Access to ACR or container registry for agent images

### Deployment
1. Set pipeline parameter `windowsImageVariant: 'dind'`
2. Pipeline automatically:
   - Verifies Windows nodes and taints
   - Installs Docker Engine on Windows nodes via hostProcess pods
   - Deploys Helm chart with DinD configuration
   - Runs validation smoke tests

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

After deployment, verify Windows DinD functionality:

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
| Container privilege | `privileged: true` | Not supported |
| Docker daemon | Runs inside container | Runs on host node |
| Access method | Unix socket `/var/run/docker.sock` | Named pipe `\\.\pipe\docker_engine` |
| Installation | Part of container image | Requires hostProcess pod installation |
| Storage | Container volume (`emptyDir`, `hostPath`, `pvc`) | Host filesystem managed by node Docker |

## Limitations

1. **Shared Docker daemon**: All Windows DinD agents on a node share the same Docker daemon
2. **Host dependency**: Requires Docker Engine installed on Windows nodes (automated by pipeline)
3. **No isolation**: Unlike Linux DinD, containers don't get their own Docker daemon
4. **Windows Server only**: Requires Windows Server containers (not Hyper-V isolation)

## Troubleshooting

### Agent fails with "failed to load vmcompute.dll"
**Cause**: Docker Engine not installed on Windows node  
**Fix**: Run `Install-DockerOnWindowsNodes.ps1` or re-run deploy pipeline

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
- Windows Server containers: https://learn.microsoft.com/en-us/virtualization/windowscontainers/
- Kubernetes hostProcess containers: https://kubernetes.io/docs/tasks/configure-pod-container/create-hostprocess-pod/

## Future Improvements

1. Add health checks for Docker daemon availability
2. Implement Docker version detection and upgrade automation
3. Add metrics/monitoring for Windows DinD agent Docker usage
4. Consider node affinity rules to distribute DinD load
5. Evaluate support for Windows containerd runtime as alternative to Docker Engine
