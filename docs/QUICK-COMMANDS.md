# Quick Commands - Pre-baked Agent Deployment

## 🚀 Deploy Windows Agents (3 Commands)

```powershell
# 1. Build Windows images with latest agent
cd c:\src\MngEnvMCAP675646\AKS_agents\ADO_az-devops-agents-k8s\azsh-windows-agent
.\01-build-and-push.ps1

# 2. Restart Windows pods
kubectl rollout restart deployment -n az-devops-windows-002

# 3. Watch Windows pods
kubectl get pods -n az-devops-windows-002 --watch
```

## 🚀 Deploy Linux Agents (3 Commands)

```powershell
# 1. Build Linux image with latest agent
cd c:\src\MngEnvMCAP675646\AKS_agents\ADO_az-devops-agents-k8s\azsh-linux-agent
.\01-build-and-push.ps1

# 2. Restart Linux pods
kubectl rollout restart deployment -n az-devops-linux-002

# 3. Watch Linux pods
kubectl get pods -n az-devops-linux-002 --watch
```

## What Changed

✅ **Prebaked is now DEFAULT** - no flag needed
✅ **Latest version AUTO-DETECTED** from GitHub
✅ **Correct URLs** in all Dockerfiles

## Build Options

### Windows
```powershell
# Default: Prebaked with latest version
.\01-build-and-push.ps1

# Specific version
.\01-build-and-push.ps1 -AgentVersion "4.260.0"

# Standard images (runtime download)
.\01-build-and-push.ps1 -UseStandard

# Single Windows version
.\01-build-and-push.ps1 -WindowsVersions @("2022")
```

### Linux
```powershell
# Default: Prebaked with latest version
.\01-build-and-push.ps1

# Specific version
.\01-build-and-push.ps1 -AgentVersion "4.260.0"

# Standard image (runtime download)
.\01-build-and-push.ps1 -UseStandard
```

## Verify Success

### Windows
```powershell
# Check latest version
cd azsh-windows-agent
.\Get-LatestAzureDevOpsAgent.ps1 -Platform windows

# Check pod logs
kubectl logs -n az-devops-windows-002 <pod-name> | Select-String "pre-baked"
# Expected: "Using pre-baked Azure Pipelines agent (no download required)"

# Check startup time (should be <1 min)
kubectl get events -n az-devops-windows-002 --sort-by='.lastTimestamp' | Select-Object -Last 20
```

### Linux
```powershell
# Check latest version
cd azsh-windows-agent
.\Get-LatestAzureDevOpsAgent.ps1 -Platform linux

# Check pod logs
kubectl logs -n az-devops-linux-002 <pod-name> | Select-String "pre-baked"
# Expected: "Using pre-baked Azure Pipelines agent (no download required)"

# Check startup time (should be <30 sec)
kubectl get events -n az-devops-linux-002 --sort-by='.lastTimestamp' | Select-Object -Last 20
```

## Expected Results

### Windows
- **Build time:** ~8 min per version (~25 min total for 3 versions)
- **Pod startup:** <1 minute (down from 5-10+ minutes!)
- **Network:** No downloads during startup
- **KEDA:** Fast scale-up (<1 min vs 10+ min)

### Linux
- **Build time:** ~5 minutes
- **Pod startup:** <30 seconds (down from 1-2 minutes)
- **Network:** No downloads during startup
- **KEDA:** Fast scale-up

---

**Ready?** Run command #1 to start! 🎯
