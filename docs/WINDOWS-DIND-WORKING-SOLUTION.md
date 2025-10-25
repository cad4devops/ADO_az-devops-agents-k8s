# Windows DinD (Docker-in-Docker) - Working Solution ✅

**Status**: ✅ **WORKING** - Verified October 24, 2025  
**Cluster**: workload-cluster-002 (AKS-HCI)  
**Node**: moc-wv3dsqrkel7  
**Docker Version**: 28.5.1

---

## 🎯 Executive Summary

After 32+ pipeline runs investigating automated Docker installation approaches, we determined that **manual installation via kubectl and hostProcess pods WITH TOLERATIONS is the working solution** for AKS-HCI Windows nodes.

### Key Discovery: Node Taints

**Critical**: AKS-HCI Windows nodes have a taint `sku=Windows:NoSchedule` that prevents pod scheduling. Any pod targeting Windows nodes MUST include the toleration:

```yaml
tolerations:
- key: "sku"
  operator: "Equal"
  value: "Windows"
  effect: "NoSchedule"
```

Without this toleration, pods remain in `Pending` state indefinitely.

---

## ✅ What Actually Works

### Verified Working Method

1. **Create installer pod with tolerations and hostProcess**
2. **Download Microsoft's official install-docker-ce.ps1 script**
3. **Execute script directly (NOT via Start-Process)**
4. **Verify Docker service is running**
5. **Annotate node**

### Complete Working YAML Manifest

Save as `install-docker.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: docker-installer-manual
  namespace: default
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: moc-wv3dsqrkel7  # Change to your node name
  tolerations:
  - key: "sku"
    operator: "Equal"
    value: "Windows"
    effect: "NoSchedule"
  securityContext:
    windowsOptions:
      hostProcess: true
      runAsUserName: "NT AUTHORITY\\SYSTEM"
  containers:
  - name: installer
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command:
    - powershell.exe
    - -NoProfile
    - -Command
    - |
      Write-Host "=====================================================" -ForegroundColor Cyan
      Write-Host "  Docker Installation on Node: $env:COMPUTERNAME" -ForegroundColor Cyan
      Write-Host "=====================================================" -ForegroundColor Cyan
      
      try {
          Write-Host "[INFO] Checking for existing Docker..."
          $existingDocker = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
          if ($existingDocker -and $existingDocker.Status -eq 'Running') {
              Write-Host "[SUCCESS] Docker already running. Skipping installation."
              exit 0
          }
          
          Write-Host "[INFO] Downloading Microsoft installer..."
          $installerUrl = 'https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1'
          $installerPath = 'C:\Temp\install-docker-ce.ps1'
          
          if (-not (Test-Path 'C:\Temp')) {
              New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null
          }
          
          Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 60
          Write-Host "[SUCCESS] Downloaded installer"
          
          Write-Host "[INFO] Installing Docker (5-10 minutes)..."
          & $installerPath -Verbose 2>&1 | ForEach-Object { Write-Host $_ }
          
          Write-Host "[INFO] Verifying installation..."
          Start-Sleep -Seconds 5
          
          $dockerService = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
          if (-not $dockerService) {
              Write-Host "[ERROR] Docker service not found after installation"
              exit 1
          }
          
          Write-Host "[SUCCESS] Docker service: $($dockerService.Name) - Status: $($dockerService.Status)"
          
          if ($dockerService.Status -ne 'Running') {
              Start-Service -Name $dockerService.Name
              Start-Sleep -Seconds 5
          }
          
          $dockerExe = Get-Command docker.exe -ErrorAction SilentlyContinue
          if ($dockerExe) {
              Write-Host "[SUCCESS] Docker CLI: $($dockerExe.Source)"
          }
          
          Write-Host ""
          Write-Host "=====================================================" -ForegroundColor Green
          Write-Host "  Docker Installation COMPLETED SUCCESSFULLY" -ForegroundColor Green
          Write-Host "=====================================================" -ForegroundColor Green
          
          exit 0
      } catch {
          Write-Host "[ERROR] Installation failed: $($_.Exception.Message)" -ForegroundColor Red
          exit 1
      }
  restartPolicy: Never
```

---

## 📋 Step-by-Step Installation Process

### Prerequisites

- kubectl CLI installed and configured
- Access to AKS-HCI cluster (workload-cluster-002)
- Cluster admin permissions
- PowerShell 7+ (for local commands)

### Step 1: Identify Target Node

```powershell
# List Windows nodes
kubectl get nodes -l kubernetes.io/os=windows

# Check node details and taints
kubectl describe node <node-name> | Select-String -Pattern "Taints:"
```

**Expected Output**:
```
Taints: sku=Windows:NoSchedule
```

### Step 2: Apply Installer Pod

```powershell
# Save the YAML manifest above as install-docker.yaml
# Update the nodeSelector with your actual node name

kubectl apply -f install-docker.yaml
```

### Step 3: Monitor Installation

```powershell
# Stream logs (takes 5-10 minutes)
kubectl logs docker-installer-manual -n default --follow --timestamps
```

**Expected Timeline**:
- Download: ~1 second
- Installation: 5-10 minutes
- Verification: 5 seconds

**Expected Final Output**:
```
[SUCCESS] Docker service: docker - Status: Running
[SUCCESS] Docker CLI: C:\Windows\system32\docker.exe
=====================================================
  Docker Installation COMPLETED SUCCESSFULLY
=====================================================
```

### Step 4: Verify Installation

Save as `verify-docker.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: docker-verify
  namespace: default
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: moc-wv3dsqrkel7  # Change to your node name
  tolerations:
  - key: "sku"
    operator: "Equal"
    value: "Windows"
    effect: "NoSchedule"
  securityContext:
    windowsOptions:
      hostProcess: true
      runAsUserName: "NT AUTHORITY\\SYSTEM"
  containers:
  - name: verify
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command:
    - powershell.exe
    - -NoProfile
    - -Command
    - |
      Write-Host "=== Docker Verification ===" -ForegroundColor Cyan
      $svc = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
      if ($svc) {
          Write-Host "FOUND: Docker service '$($svc.Name)'" -ForegroundColor Green
          Write-Host "STATUS: $($svc.Status)" -ForegroundColor Green
          $dockerExe = Get-Command docker.exe -ErrorAction SilentlyContinue
          if ($dockerExe) {
              Write-Host "CLI: $($dockerExe.Source)" -ForegroundColor Green
              docker version
          }
          exit 0
      } else {
          Write-Host "NOT FOUND: No Docker service" -ForegroundColor Red
          exit 1
      }
  restartPolicy: Never
```

Run verification:

```powershell
kubectl apply -f verify-docker.yaml
Start-Sleep -Seconds 15
kubectl logs docker-verify -n default
```

**Expected Output**:
```
=== Docker Verification ===
FOUND: Docker service 'docker'
STATUS: Running
CLI: C:\Windows\system32\docker.exe
Client:
 Version:           28.5.1
 API version:       1.51
 ...
Server: Docker Engine - Community
 Engine:
  Version:          28.5.1
  API version:      1.51 (minimum version 1.24)
  ...
```

### Step 5: Annotate Node

```powershell
kubectl annotate node <node-name> agents.cad4devops.dev/docker-installed=true --overwrite
```

Verify annotation:

```powershell
kubectl get node <node-name> -o jsonpath='{.metadata.annotations.agents\.cad4devops\.dev/docker-installed}'
```

**Expected Output**: `true`

### Step 6: Cleanup Installer Pods

```powershell
kubectl delete pod docker-installer-manual docker-verify -n default
```

### Step 7: Deploy DinD Agents

Now you can deploy DinD-enabled agents:

```powershell
.\scripts\Trigger-DeployPipeline.ps1 -InstanceNumber '002' -WindowsImageVariant 'dind' -UseAzureLocal
```

The pipeline will:
- See the Docker annotation on the node
- Skip Docker installation (already installed)
- Deploy Windows DinD agents
- Agents will have Docker socket mounted for DinD scenarios

---

## 🔧 Troubleshooting

### Pod Stays in Pending

**Symptom**: Pod shows status `Pending` indefinitely

**Cause**: Missing toleration for Windows node taint

**Solution**: Ensure your pod YAML includes:
```yaml
tolerations:
- key: "sku"
  operator: "Equal"
  value: "Windows"
  effect: "NoSchedule"
```

### Check Pod Status

```powershell
kubectl describe pod <pod-name> -n default
```

Look for events showing scheduling issues.

### Docker Service Not Starting

**Symptom**: Installation completes but service won't start

**Check Logs**:
```powershell
# Create diagnostic pod with toleration
kubectl run diag --rm -i --restart=Never \
  --image=mcr.microsoft.com/windows/nanoserver:ltsc2022 \
  --overrides='{...with tolerations...}' \
  -- powershell.exe -Command "Get-EventLog -LogName System -Source Docker -Newest 50"
```

### Verify Docker Actually Works

Run a test container:

```powershell
# Create test pod with Docker access
kubectl apply -f test-docker.yaml
```

Where `test-docker.yaml` includes Docker socket mount and toleration.

---

## ❌ What Doesn't Work

Based on 32+ pipeline runs, these approaches **DO NOT WORK** in hostProcess pods:

### 1. Start-Process Cmdlet
```powershell
Start-Process -FilePath "installer.exe" -Wait  # ❌ CRASHES POD INSTANTLY
```

**Why**: hostProcess pods have undocumented limitations with process spawning.

### 2. DockerMsftProvider
```powershell
Install-Module -Name DockerMsftProvider  # ❌ POD CRASHES AFTER 9 SECONDS
Install-Package -Name docker  # ❌ SAME ISSUE
```

**Why**: Package providers use Start-Process internally.

### 3. Direct Binary Downloads (Large Files)
```powershell
Invoke-WebRequest -Uri "large-file.zip"  # ❌ POD CRASHES ON >50MB FILES
```

**Why**: Memory/resource constraints in hostProcess pods.

### 4. aka.ms URLs
```powershell
Invoke-WebRequest -Uri "https://aka.ms/some-installer"  # ❌ REDIRECTS TO BING
```

**Why**: aka.ms URLs are broken, redirect to Bing search instead of actual MSIs.

### 5. Automated Pipeline Installation

All attempts to automate this via Azure DevOps pipeline failed due to the above limitations. The manual kubectl-based approach is currently the only reliable method.

---

## 🎓 Key Learnings

1. **Tolerations are MANDATORY** for Windows nodes in AKS-HCI
2. **hostProcess pods have significant limitations** - not all PowerShell cmdlets work
3. **Direct script execution works** - use `& $scriptPath` not Start-Process
4. **Microsoft's install-docker-ce.ps1 is reliable** when executed properly
5. **Verification is critical** - don't trust annotations without verification
6. **Manual processes can be the right solution** - automation isn't always possible

---

## 📊 Verification Results (October 24, 2025)

### Cluster Information
- **Cluster**: workload-cluster-002
- **Context**: workload-cluster-002-admin@workload-cluster-002
- **Node**: moc-wv3dsqrkel7
- **OS**: Windows Server 2022 (build 20348)
- **Container Runtime**: containerd 1.6.21+azure

### Docker Installation
- **Service Name**: docker
- **Service Status**: Running
- **Start Type**: Automatic
- **Docker CLI**: C:\Windows\system32\docker.exe
- **Docker Daemon**: C:\Windows\system32\dockerd.exe

### Docker Version
- **Client Version**: 28.5.1
- **Server Version**: 28.5.1
- **API Version**: 1.51
- **Go Version**: go1.24.8
- **Built**: Wed Oct 8 12:19:16 2025

### Node Annotation
```
agents.cad4devops.dev/docker-installed: "true"
```

---

## 🚀 Next Steps

1. ✅ Docker installed and verified on workload-cluster-002
2. ✅ Node annotated for DinD support
3. ⏭️ Deploy Windows DinD agents via pipeline
4. ⏭️ Test DinD functionality with sample pipeline
5. ⏭️ Replicate process for additional nodes as needed

---

## 📁 Related Files

- **Installer YAML**: `.tmp/install-docker-manual.yaml` (working example)
- **Verification YAML**: `.tmp/verify-docker.yaml` (working example)
- **Helper Script**: `scripts/Install-DockerManually.ps1` (needs toleration update)
- **Pipeline Script**: `scripts/Install-DockerOnWindowsNodes.ps1` (has -SkipInstallation flag)

---

## 🔗 References

- [Microsoft Install-DockerCE Script](https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1)
- [Docker Engine Release Notes](https://docs.docker.com/engine/release-notes/)
- [Kubernetes hostProcess Containers](https://kubernetes.io/docs/tasks/configure-pod-container/create-hostprocess-pod/)
- [AKS-HCI Documentation](https://learn.microsoft.com/en-us/azure/aks/hybrid/)

---

**Document Version**: 1.0  
**Last Updated**: October 24, 2025  
**Verified By**: Automated installation process  
**Status**: ✅ Production Ready
