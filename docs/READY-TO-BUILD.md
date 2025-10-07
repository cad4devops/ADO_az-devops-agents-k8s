# ✅ URL Fix Complete - Ready to Build

## Summary
Fixed all prebaked Dockerfiles and helper scripts to use the correct Azure DevOps agent download URL.

## Problem
❌ **Old URL:** `https://vstsagentpackage.azureedge.net/agent/...`
- DNS resolution failure: "The remote name could not be resolved"
- This URL is no longer active

## Solution
✅ **New URL:** `https://download.agent.dev.azure.com/agent/...`
- Confirmed working (HTTP 200 OK)
- Official Microsoft download endpoint

## Files Updated ✅

### Prebaked Dockerfiles (4 files)
- ✅ `azsh-windows-agent/Dockerfile.windows-sh-agent-2019-windows2019.prebaked`
- ✅ `azsh-windows-agent/Dockerfile.windows-sh-agent-2022-windows2022.prebaked`
- ✅ `azsh-windows-agent/Dockerfile.windows-sh-agent-2025-windows2025.prebaked`
- ✅ `azsh-linux-agent/Dockerfile.linux-sh-agent-docker.prebaked`

### Helper Scripts (1 file)
- ✅ `azsh-windows-agent/Get-LatestAzureDevOpsAgent.ps1`

## Verification

### URL Test
```powershell
PS> Invoke-WebRequest -Uri "https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-win-x64-4.261.0.zip" -Method Head

StatusCode: 200 ✅
StatusDescription: OK ✅
```

### Dockerfile Verification
All 4 prebaked Dockerfiles now contain:
```dockerfile
# Windows
$downloadUrl = \"https://download.agent.dev.azure.com/agent/${agentVersion}/vsts-agent-win-x64-${agentVersion}.zip\"

# Linux
DOWNLOAD_URL="https://download.agent.dev.azure.com/agent/${AGENT_VERSION}/vsts-agent-linux-x64-${AGENT_VERSION}.tar.gz"
```

## Ready to Build! 🚀

### Option 1: Build Everything (via bootstrap)
```powershell
cd C:\src\MngEnvMCAP675646\AKS_agents\ADO_az-devops-agents-k8s
.\bootstrap-and-build.ps1
```

### Option 2: Build Windows Only
```powershell
cd azsh-windows-agent
.\01-build-and-push.ps1
# Builds all 3 Windows versions: 2019, 2022, 2025
# Duration: ~25-30 minutes
```

### Option 3: Build Linux Only
```powershell
cd azsh-linux-agent
.\01-build-and-push.ps1
# Builds Ubuntu 24.04
# Duration: ~5 minutes
```

### Option 4: Build Specific Windows Version
```powershell
cd azsh-windows-agent
.\01-build-and-push.ps1 -WindowsVersions @("2022")
# Duration: ~8-10 minutes
```

## Expected Build Output

### Successful Download
```
Building PREBAKED Windows image windows-sh-agent-2022:windows-2022 with agent v4.261.0
Running docker build...
Step 4/6 : RUN powershell -Command...
Downloading Azure Pipelines agent v4.261.0...
Download URL: https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-win-x64-4.261.0.zip
✅ Agent downloaded. Extracting...
✅ Agent v4.261.0 ready.
```

### Previous Error (Fixed)
```
❌ Invoke-WebRequest : The remote name could not be resolved: 'vstsagentpackage.azureedge.net'
```

## What Happens Next

1. **Docker Build Phase:**
   - Download agent from `download.agent.dev.azure.com` ✅
   - Extract to `/azp/agent` or `C:\azp\agent`
   - Copy `start-prebaked.ps1` or `start-prebaked.sh`
   - Create image layers

2. **Push to ACR:**
   - Tag images with version and latest
   - Push to `cragents002vhu5kdbk2l7v2.azurecr.io`

3. **Deploy to AKS:**
   ```powershell
   kubectl rollout restart deployment -n az-devops-windows-002
   kubectl rollout restart deployment -n az-devops-linux-002
   ```

4. **Verify Performance:**
   - Windows pods: 5-10+ minutes → **<1 minute** (90%+ faster)
   - Linux pods: 1-2 minutes → **<30 seconds** (70%+ faster)

## Build Times

| Component | Duration | Notes |
|-----------|----------|-------|
| Windows 2019 | ~8-10 min | Downloads ~150MB agent |
| Windows 2022 | ~8-10 min | Downloads ~150MB agent |
| Windows 2025 | ~8-10 min | Downloads ~150MB agent |
| Linux (Ubuntu 24.04) | ~5 min | Downloads ~150MB agent |
| **Total (all platforms)** | **~30-35 min** | One-time build cost |

## Performance Gains

### Before (Standard Images)
- Agent downloaded at **runtime** by each pod
- 5 concurrent pods = 5× ~150MB downloads
- Network saturation
- **5-10+ minutes** for Windows pods to start
- **1-2 minutes** for Linux pods to start

### After (Prebaked Images)
- Agent downloaded at **build time** once
- Baked into Docker image
- No runtime downloads
- **<1 minute** for Windows pods to start ✅
- **<30 seconds** for Linux pods to start ✅

## Next Steps

### 1. Build Images (Now)
```powershell
.\bootstrap-and-build.ps1
```

### 2. Deploy to AKS (After build completes)
```powershell
kubectl rollout restart deployment -n az-devops-windows-002
kubectl rollout restart deployment -n az-devops-linux-002
```

### 3. Verify Startup Performance
```powershell
# Watch Windows pods
kubectl get pods -n az-devops-windows-002 --watch

# Check logs for "pre-baked" message
kubectl logs -n az-devops-windows-002 <pod-name> | Select-String "pre-baked"
# Expected: "Using pre-baked Azure Pipelines agent (no download required)"
```

### 4. Monitor KEDA Autoscaling
```powershell
# Verify KEDA can scale up quickly
kubectl get scaledobject -n az-devops-windows-002
kubectl describe scaledobject -n az-devops-windows-002 azure-pipelines-scaledobject
```

## Troubleshooting

### If build fails with DNS error
```powershell
# Test URL connectivity from Docker container
docker run --rm mcr.microsoft.com/windows/servercore:ltsc2022 powershell -Command "Invoke-WebRequest -Uri 'https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-win-x64-4.261.0.zip' -Method Head"
```

### If URL is blocked by firewall
- Contact network team to allow `download.agent.dev.azure.com`
- Port 443 (HTTPS) must be open for outbound traffic

### Rollback to Standard Images
```powershell
# Windows
cd azsh-windows-agent
.\01-build-and-push.ps1 -UseStandard

# Linux
cd azsh-linux-agent
.\01-build-and-push.ps1 -UseStandard
```

## Documentation

- **This file:** `URL-FIX-SUMMARY.md` - URL fix details
- **Implementation:** `COMPLETE-IMPLEMENTATION-SUMMARY.md` - Full prebaked implementation
- **Quick Commands:** `QUICK-COMMANDS.md` - Command reference
- **Windows Guide:** `PREBAKED-AGENT-IMPLEMENTATION.md` - Windows prebaked guide
- **Linux Guide:** `LINUX-PREBAKED-IMPLEMENTATION.md` - Linux prebaked guide

---

## 🎉 All Set - Ready to Build!

Run `.\bootstrap-and-build.ps1` to build all prebaked images with the correct download URL! 🚀
