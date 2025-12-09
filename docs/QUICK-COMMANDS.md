# Quick Commands Reference

## 🚀 Bootstrap (Recommended - One Command Setup)

For new deployments, use the orchestrator script:

```powershell
# Set PAT
$env:AZDO_PAT = 'your-pat-token-here'

# Run bootstrap (defers builds to pipeline)
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -InstanceNumber 003 `
  -Location canadacentral `
  -ADOCollectionName <org> `
  -AzureDevOpsProject <project> `
  -AzureDevOpsRepo <repo> `
  -BuildInPipeline
```

See `docs/bootstrap-and-build.md` for detailed options.

## 🔄 Manual Build & Deploy

### Build Windows Agents

```powershell
# Navigate to Windows agent directory
cd azsh-windows-agent

# Build with latest agent (prebaked is default)
.\01-build-and-push.ps1
```

### Build Linux Agents

```powershell
# Navigate to Linux agent directory
cd azsh-linux-agent

# Build with latest agent (prebaked is default)
.\01-build-and-push.ps1
```

### Restart Deployments

```powershell
# Restart Windows pods (replace <instance> with your instance number)
kubectl rollout restart deployment -n az-devops-windows-<instance>

# Restart Linux pods
kubectl rollout restart deployment -n az-devops-linux-<instance>
```

### Watch Pod Status

```powershell
# Watch Windows pods
kubectl get pods -n az-devops-windows-<instance> --watch

# Watch Linux pods
kubectl get pods -n az-devops-linux-<instance> --watch
```


## Build Options

### Windows Build Options

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

### Linux Build Options

```powershell
# Default: Prebaked with latest version
.\01-build-and-push.ps1

# Specific version
.\01-build-and-push.ps1 -AgentVersion "4.260.0"

# Standard image (runtime download)
.\01-build-and-push.ps1 -UseStandard
```

## Verify Success

### Verify Windows Deployment

```powershell
# Check latest version
cd azsh-windows-agent
.\Get-LatestAzureDevOpsAgent.ps1 -Platform windows

# Check pod logs
kubectl logs -n az-devops-windows-<instance> <pod-name> | Select-String "pre-baked"
# Expected: "Using pre-baked Azure Pipelines agent (no download required)"

# Check startup time (should be <1 min)
kubectl get events -n az-devops-windows-<instance> --sort-by='.lastTimestamp' | Select-Object -Last 20
```

### Verify Linux Deployment

```powershell
# Check latest version
cd azsh-windows-agent
.\Get-LatestAzureDevOpsAgent.ps1 -Platform linux

# Check pod logs
kubectl logs -n az-devops-linux-<instance> <pod-name> | Select-String "pre-baked"
# Expected: "Using pre-baked Azure Pipelines agent (no download required)"

# Check startup time (should be <30 sec)
kubectl get events -n az-devops-linux-<instance> --sort-by='.lastTimestamp' | Select-Object -Last 20
```

## Expected Performance

### Windows Agents

- **Build time:** ~8 min per version (~25 min total for 3 versions)
- **Pod startup:** <1 minute (down from 5-10+ minutes!)
- **Network:** No downloads during startup
- **KEDA:** Fast scale-up (<1 min vs 10+ min)

### Linux Agents

- **Build time:** ~5 minutes
- **Pod startup:** <30 seconds (down from 1-2 minutes)
- **Network:** No downloads during startup
- **KEDA:** Fast scale-up

---

**For complete setup guidance**, see `docs/bootstrap-and-build.md`

