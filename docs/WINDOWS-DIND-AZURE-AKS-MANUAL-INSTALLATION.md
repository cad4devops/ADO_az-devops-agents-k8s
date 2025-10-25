# Windows Docker-in-Docker (DinD) Manual Installation on Azure AKS

## Overview

This document provides step-by-step manual installation instructions for Docker Engine on Azure AKS Windows nodes, enabling Windows Docker-in-Docker (DinD) agent functionality.

**Tested Configuration:**
- **Cluster Type**: Azure AKS (Standard managed Kubernetes)
- **Kubernetes Version**: v1.32.7
- **Windows Node OS**: Windows Server 2022 Datacenter (Build 10.0.20348.4171)
- **Container Runtime**: containerd 1.7.20+azure
- **Docker Version Installed**: Docker 28.0.2
- **Installation Date**: October 25, 2025

## Key Differences from AKS-HCI

| Aspect | Azure AKS | AKS-HCI |
|--------|-----------|---------|
| **Container Runtime** | containerd 1.7.20+azure | containerd 1.7.x |
| **Node Management** | Fully managed by Azure | Managed by AKS-HCI |
| **Docker Pre-installed** | ❌ No | ❌ No |
| **Installation Method** | Manual via hostProcess pod | Manual via hostProcess pod |
| **Named Pipe** | `\\.\pipe\docker_engine` | `\\.\pipe\docker_engine` |
| **Service Auto-start** | ✅ Automatic | ✅ Automatic |

## Prerequisites

- Azure AKS cluster with Windows node pool
- kubectl configured to access the cluster
- Windows node pool with taint: `sku=Windows:NoSchedule`
- Cluster admin access

## Current Cluster State

```powershell
kubectl get nodes -o wide
```

**Output:**
```
NAME                                STATUS   ROLES    AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION      CONTAINER-RUNTIME
aks-agentpool-22682668-vmss000001   Ready    <none>   2h    v1.32.7   10.224.0.66   <none>        Ubuntu 22.04.5 LTS               5.15.0-1096-azure   containerd://1.7.28-1
akswinp000001                       Ready    <none>   2h    v1.32.7   10.224.0.35   <none>        Windows Server 2022 Datacenter   10.0.20348.4171     containerd://1.7.20+azure
```

## Manual Installation Steps

### Step 1: Create hostProcess Installer Pod

Create a privileged pod with hostProcess enabled to access the Windows node:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: win-docker-install
  namespace: default
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/os: windows
  tolerations:
  - effect: NoSchedule
    key: sku
    value: Windows
  containers:
  - name: installer
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command:
    - powershell.exe
    - -Command
    - "while(1){Start-Sleep 60}"
    securityContext:
      windowsOptions:
        hostProcess: true
        runAsUserName: "NT AUTHORITY\\SYSTEM"
  restartPolicy: Never
```

**Apply the pod:**
```powershell
kubectl apply -f win-docker-install-pod.yaml
```

**Wait for pod to be ready:**
```powershell
kubectl get pod win-docker-install
# Should show: STATUS=Running
```

### Step 2: Verify Docker Not Installed

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Get-Service docker -ErrorAction SilentlyContinue"
```

**Expected:** Exit code 1 (service doesn't exist)

### Step 3: Download Docker 28.0.2

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Write-Host 'Downloading Docker 28.0.2...'; Invoke-WebRequest -Uri 'https://download.docker.com/win/static/stable/x86_64/docker-28.0.2.zip' -OutFile 'C:\docker.zip' -UseBasicParsing; Write-Host 'Download complete'; (Get-Item C:\docker.zip).Length"
```

**Expected Output:**
```
Downloading Docker 28.0.2...
Download complete
41852340
```

**File size:** ~41.8 MB

### Step 4: Extract Docker Archive

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Expand-Archive -Path C:\docker.zip -DestinationPath C:\ProgramFiles -Force; Test-Path C:\ProgramFiles\docker\dockerd.exe"
```

**Expected Output:**
```
True
```

### Step 5: Add Docker to System PATH

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','Machine') + ';C:\ProgramFiles\docker', 'Machine'); Write-Host 'PATH updated'"
```

**Expected Output:**
```
PATH updated
```

### Step 6: Verify Docker Binary

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "C:\ProgramFiles\docker\dockerd.exe --version"
```

**Expected Output:**
```
Docker version 28.0.2, build bea4de2
```

### Step 7: Register Docker as Windows Service

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "C:\ProgramFiles\docker\dockerd.exe --register-service; Write-Host 'Docker service registered'"
```

**Expected Output:**
```
Docker service registered
```

### Step 8: Start Docker Service

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Start-Service docker; Get-Service docker | Select-Object Name,Status,StartType"
```

**Expected Output:**
```
Name    Status StartType
----    ------ ---------
docker Running Automatic
```

✅ **Docker service is now running with Automatic startup type!**

### Step 9: Verify Docker Client Connection

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "C:\ProgramFiles\docker\docker.exe version"
```

**Expected Output:**
```
Client:
 Version:           28.0.2
 API version:       1.48
 Go version:        go1.23.7
 Git commit:        0442a73
 Built:             Wed Mar 19 14:37:25 2025
 OS/Arch:           windows/amd64
 Context:           default

Server: Docker Engine - Community
 Engine:
  Version:          28.0.2
  API version:      1.48 (minimum version 1.24)
  Go version:       go1.23.7
  Git commit:       bea4de2
  Built:            Wed Mar 19 14:36:19 2025
  OS/Arch:          windows/amd64
  Experimental:     false
```

### Step 10: Test Docker with Container

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "C:\ProgramFiles\docker\docker.exe run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo Docker works on Azure AKS!"
```

**Expected Output:**
```
Unable to find image 'mcr.microsoft.com/windows/nanoserver:ltsc2022' locally
ltsc2022: Pulling from windows/nanoserver
938281fc4602: Pull complete
Digest: sha256:307874138e4dc064d0538b58c6f028419ab82fb15fcabaf6d5378ba32c235266
Status: Downloaded newer image for mcr.microsoft.com/windows/nanoserver:ltsc2022
Docker works on Azure AKS!
```

### Step 11: Verify Named Pipe for DinD

```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Test-Path \\.\pipe\docker_engine"
```

**Expected Output:**
```
True
```

✅ **The Docker named pipe is available for DinD mounting!**

## Installation Complete! 🎉

Docker Engine is now fully installed and operational on the Azure AKS Windows node.

## Key Points About PowerShell

**Important:** Azure AKS Windows nodes have **Windows PowerShell 5.1** (`powershell.exe`), not PowerShell Core (`pwsh.exe`).

- ✅ Use: `powershell.exe`
- ❌ Don't use: `pwsh.exe` (not installed)
- ⚠️ Avoid `2>&1` redirection in PowerShell 5.1 (can cause issues)

## Post-Installation Verification

### Check Docker Service Status
```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Get-Service docker"
```

### Check Docker Process
```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Get-Process dockerd"
```

### List Docker Images
```powershell
kubectl exec win-docker-install -- powershell.exe -Command "C:\ProgramFiles\docker\docker.exe images"
```

## Testing Windows DinD Agents

Now that Docker is installed, you can deploy Windows DinD agents that mount the Docker socket:

### Example DinD Agent Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: windows-dind-agent-test
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/os: windows
  tolerations:
  - effect: NoSchedule
    key: sku
    value: Windows
  containers:
  - name: agent
    image: <your-acr>.azurecr.io/windows-sh-agent-2022-dind:latest
    volumeMounts:
    - name: docker-pipe
      mountPath: \\.\pipe\docker_engine
  volumes:
  - name: docker-pipe
    hostPath:
      path: \\.\pipe\docker_engine
      type: ""
```

## Automation Script

For automated installation across all Windows nodes, use:

```powershell
.\scripts\Install-DockerOnWindowsNodes.ps1 -Namespace default -TimeoutSeconds 600
```

This script:
- Creates a DaemonSet targeting all Windows nodes
- Downloads and installs Docker 28.0.2
- Registers Docker as a Windows service
- Starts the service with Automatic startup
- Verifies installation success

## Cleanup

To remove the installer pod after Docker is installed:

```powershell
kubectl delete pod win-docker-install
```

**Note:** The Docker service will continue running even after deleting the installer pod.

## Troubleshooting

### Docker Service Won't Start

Check Windows Event Logs:
```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Get-EventLog -LogName Application -Source Docker -Newest 10"
```

### Named Pipe Not Available

Restart Docker service:
```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Restart-Service docker; Start-Sleep 5; Test-Path \\.\pipe\docker_engine"
```

### Container Runtime Conflicts

Check if containerd is interfering:
```powershell
kubectl exec win-docker-install -- powershell.exe -Command "Get-Process containerd"
```

**Note:** Docker and containerd can coexist on the same node. The Kubernetes runtime uses containerd, while DinD agents use Docker Engine.

## Comparison: Azure AKS vs AKS-HCI

Both environments successfully support Windows DinD with the same installation method:

| Feature | Azure AKS | AKS-HCI |
|---------|-----------|---------|
| **Docker Installation** | ✅ Manual | ✅ Manual |
| **Named Pipe** | ✅ Available | ✅ Available |
| **Container Runtime** | containerd | containerd |
| **DinD Support** | ✅ Working | ✅ Working |
| **Service Persistence** | ✅ Survives reboots | ✅ Survives reboots |

## Conclusion

Windows Docker-in-Docker is **fully functional on Azure AKS** with manual Docker Engine installation. The same DinD agent images work on both Azure AKS and AKS-HCI, making this a portable solution across both platforms.

**Next Steps:**
1. Deploy Windows DinD agent pools using the `windowsImageVariant: dind` parameter
2. Run DinD smoke tests to verify pipeline functionality
3. Use the automated installation script for production deployments

---

**Documentation Version:** 1.0  
**Last Updated:** October 25, 2025  
**Tested By:** Azure DevOps Self-Hosted Agents Team
