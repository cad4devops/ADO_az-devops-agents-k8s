# Windows Agent Download Congestion Issue

## Problem Summary

4 out of 5 Windows agent pods were stuck at "Downloading and installing Azure Pipelines agent..." for extended periods. Eventually they all completed, but the delay was significant.

## Root Cause

**Network bandwidth saturation on a single Windows node:**
- All 5 Windows pods scheduled on the same node: `akswinp000000` (Standard_D2s_v3)
- Each pod downloads ~150MB Azure Pipelines agent package simultaneously on startup
- Single node bandwidth (limited egress) cannot handle 5 concurrent large downloads efficiently
- Downloads complete eventually but take 5-10+ minutes instead of <1 minute

## Evidence

```
kubectl get pods -n az-devops-windows-002 -o wide
```

All pods on same node:
- azsh-windows-agent-5fb5d5f886-sk2nl → akswinp000000 (started first, completed quickly)
- azsh-windows-agent-5fb5d5f886-fqtmj → akswinp000000 (stuck downloading)
- azsh-windows-agent-5fb5d5f886-4p8gn → akswinp000000 (stuck downloading)
- azsh-windows-agent-5fb5d5f886-6gz4l → akswinp000000 (stuck downloading)
- azsh-windows-agent-5fb5d5f886-vhth8 → akswinp000000 (stuck downloading)

## Solutions (Ranked by Effectiveness)

### ✅ Solution 1: Add Random Startup Delay (Immediate Fix)

**Impact:** Low complexity, immediate relief
**Downside:** Doesn't solve the fundamental issue, just spreads it out

**Implementation:** Add random delay (0-30 seconds) before download to stagger requests

I've created an improved start script at:
- `azsh-windows-agent/start-improved.ps1`

Key improvements:
- Random 0-30 second delay before download
- Retry logic with exponential backoff (5 attempts)
- Better error handling
- Progress reporting

**To use:** Replace `start.ps1` with `start-improved.ps1` and rebuild Windows images.

### 🎯 Solution 2: Pre-download Agent in Docker Image (Best Long-term)

**Impact:** Eliminates download at runtime entirely
**Downside:** Larger image size, must rebuild when agent version changes

**Implementation:**

Create new Dockerfile that pre-downloads agent:

```dockerfile
FROM mcr.microsoft.com/windows/servercore:ltsc2022

WORKDIR /azp/

# Pre-download the Azure Pipelines agent during build
RUN powershell -Command " \
    $ProgressPreference = 'SilentlyContinue'; \
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':YOUR_PAT')); \
    $package = Invoke-RestMethod -Headers @{Authorization = (\"Basic $base64AuthInfo\") } 'https://dev.azure.com/YOUR_ORG/_apis/distributedtask/packages/agent?platform=win-x64&$top=1'; \
    $packageUrl = $package[0].Value.downloadUrl; \
    Invoke-WebRequest -Uri $packageUrl -OutFile agent.zip; \
    Expand-Archive -Path agent.zip -DestinationPath C:\azp\agent; \
    Remove-Item agent.zip"

COPY ./start.ps1 ./

CMD powershell .\start.ps1
```

Then modify `start.ps1` to skip download if agent already exists.

### 🔧 Solution 3: Scale Windows Node Pool

**Impact:** Distributes pods across multiple nodes
**Downside:** Increased cost (~$70/month per additional node)

**Implementation:**

```powershell
# Scale to 2 Windows nodes
az aks nodepool scale \
  --resource-group rg-aks-ado-agents-002 \
  --cluster-name aks-ado-agents-002 \
  --name winp \
  --node-count 2
```

Or update via Bicep by changing `windowsNodeCount` parameter to 2 or more.

### 🛠️ Solution 4: Use Larger Windows VM Size

**Impact:** More bandwidth per node
**Downside:** Higher cost

Current: `Standard_D2s_v3` (2 vCPUs)
Recommended: `Standard_D4s_v3` (4 vCPUs) - Better network performance

## Recommended Action Plan

### Immediate (Today):
1. ✅ **Option 1:** Deploy improved start script with random delay
   - Copy `start-improved.ps1` → `start.ps1`
   - Rebuild Windows images
   - Redeploy

### Short-term (This Week):
2. **Scale Windows nodes to 2** (if budget allows)
   - Distributes load across 2 nodes
   - Cost: +$70/month

### Long-term (Next Sprint):
3. **Pre-bake agent into image**
   - Eliminates runtime downloads
   - Faster pod startup
   - More reliable

## Quick Fix Commands

### Option 1: Deploy improved start script

```powershell
# Backup original
Copy-Item azsh-windows-agent\start.ps1 azsh-windows-agent\start.ps1.bak

# Use improved version
Copy-Item azsh-windows-agent\start-improved.ps1 azsh-windows-agent\start.ps1

# Rebuild and push Windows images
cd azsh-windows-agent
pwsh -File .\01-build-and-push.ps1 -WindowsVersions "2022"

# Restart deployment to pick up new image
kubectl rollout restart deployment/azsh-windows-agent -n az-devops-windows-002
```

### Option 2: Scale Windows nodes

```powershell
# Scale to 2 nodes
az aks nodepool scale \
  --resource-group rg-aks-ado-agents-002 \
  --cluster-name aks-ado-agents-002 \
  --name winp \
  --node-count 2

# Verify
kubectl get nodes -l kubernetes.io/os=windows
```

### Option 3: Increase Windows VM size

```powershell
# Update Bicep deployment
cd infra\bicep
pwsh -File .\deploy.ps1 \
  -InstanceNumber 002 \
  -Location canadacentral \
  -WindowsVmSize Standard_D4s_v3 \
  -LinuxVmSize Standard_D4s_v3
```

## Monitoring

Check if pods are stuck:

```powershell
# Watch pod status
kubectl get pods -n az-devops-windows-002 -w

# Check logs for download progress
kubectl logs -n az-devops-windows-002 <pod-name> --follow

# Check agent registration in Azure DevOps
# Go to: Organization Settings → Agent Pools → <your-pool> → Agents
```

## Cost Impact

| Solution | Monthly Cost Change | Effectiveness |
|----------|---------------------|---------------|
| Random delay | $0 | Low-Medium |
| Pre-bake agent | $0 | High |
| +1 Windows node | +$70 | Medium-High |
| Upgrade to D4s_v3 | +$70 | Medium |
| +1 node + D4s_v3 | +$210 | High |

## Notes

- The first pod always completes quickly because it has full bandwidth
- Subsequent pods compete for the same node's network egress
- KEDA autoscaling will make this worse as it scales up more pods on the same node
- Consider implementing Solution 2 (pre-bake) for production environments

