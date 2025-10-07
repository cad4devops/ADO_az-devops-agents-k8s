# Next Steps: Deploy Pre-baked Windows Agents

## Quick Command Reference

### 1. Build Pre-baked Images
```powershell
# Navigate to Windows agent directory
cd c:\src\MngEnvMCAP675646\AKS_agents\ADO_az-devops-agents-k8s\azsh-windows-agent

# Build all three Windows versions with pre-baked agent
.\01-build-and-push.ps1 -UsePrebaked -WindowsVersions @("2019", "2022", "2025")

# Alternative: Build single version for testing
.\01-build-and-push.ps1 -UsePrebaked -WindowsVersions @("2022")
```

### 2. Verify Images Pushed to ACR
```powershell
# List Windows agent images in ACR
az acr repository list --name cragents002vhu5kdbk2l7v2 --output table | Select-String "windows"

# Show tags for Windows 2022 agent
az acr repository show-tags --name cragents002vhu5kdbk2l7v2 --repository windows-sh-agent-2022 --output table
```

### 3. Redeploy Windows Agents to AKS
```powershell
# Navigate to repository root
cd c:\src\MngEnvMCAP675646\AKS_agents\ADO_az-devops-agents-k8s

# Option A: Force rollout restart (fastest)
kubectl rollout restart deployment -n az-devops-windows-002

# Option B: Re-run full Helm deployment
.\deploy-selfhosted-agents-helm.ps1 `
    -InstanceNumber 002 `
    -AksResourceGroup "rg-aks-ado-agents-002" `
    -AksClusterName "aks-ado-agents-002" `
    -AcrName "cragents002vhu5kdbk2l7v2" `
    -AzureDevOpsOrgUrl "https://dev.azure.com/MngEnvMCAP675646" `
    -AzureDevOpsPat $env:AZDO_PAT
```

### 4. Monitor Pod Startup
```powershell
# Watch pods restart and come online
kubectl get pods -n az-devops-windows-002 --watch

# Check pod startup logs (replace <pod-name>)
kubectl logs -n az-devops-windows-002 <pod-name> --follow

# View recent events
kubectl get events -n az-devops-windows-002 --sort-by='.lastTimestamp' | Select-Object -Last 20
```

### 5. Verify Pre-baked Agent in Use
```powershell
# Expected log message in pod logs:
# "Using pre-baked Azure Pipelines agent (no download required)"

# Check pod logs for this message
kubectl logs -n az-devops-windows-002 <pod-name> | Select-String "pre-baked"

# Or check all pods at once
kubectl get pods -n az-devops-windows-002 -o name | ForEach-Object {
    Write-Host "`n$($_):"
    kubectl logs $_ | Select-String "pre-baked"
}
```

## Expected Timeline

| Step | Duration | Notes |
|------|----------|-------|
| **Build Windows 2019 image** | ~8 minutes | Includes agent download (~3 min) |
| **Build Windows 2022 image** | ~8 minutes | Includes agent download (~3 min) |
| **Build Windows 2025 image** | ~8 minutes | Includes agent download (~3 min) |
| **Push to ACR** | ~2-3 min each | ~5-6 GB per image |
| **Rollout restart pods** | ~1-2 minutes | 5 pods rolling restart |
| **Pod startup (prebaked)** | <1 minute | Down from 5-10+ minutes! |
| **Total deployment** | ~30-35 minutes | Most time is building images |

## Success Criteria

✅ **Build Phase**
- [ ] All three Dockerfiles built successfully (2019, 2022, 2025)
- [ ] No Docker build errors related to agent download
- [ ] Images pushed to ACR without errors

✅ **Deployment Phase**
- [ ] Pods restart successfully (no CrashLoopBackOff)
- [ ] Pods show "Using pre-baked Azure Pipelines agent" in logs
- [ ] No "Downloading and installing Azure Pipelines agent" messages

✅ **Performance Phase**
- [ ] Pod startup time <1 minute (previously 5-10+ minutes)
- [ ] All 5 Windows pods start concurrently without delays
- [ ] Agents register with Azure DevOps pool successfully
- [ ] KEDA can scale up quickly (<1 minute vs 10+ minutes)

## Troubleshooting

### Build Error: "Cannot download agent"
**Solution:** Check internet connectivity from Docker build context. May need proxy settings.

### Push Error: "unauthorized: access token has insufficient scopes"
**Solution:** Ensure logged into Azure and ACR:
```powershell
az login
az acr login --name cragents002vhu5kdbk2l7v2
```

### Pod Error: "Pre-baked agent not found, downloading..."
**Solution:** Image may not have pre-baked agent. Verify build used `-UsePrebaked` flag.

### Pod CrashLoopBackOff
**Solution:** Check pod logs for errors:
```powershell
kubectl describe pod <pod-name> -n az-devops-windows-002
kubectl logs <pod-name> -n az-devops-windows-002
```

## Rollback Plan

If pre-baked images cause issues, rebuild standard images:

```powershell
# Build WITHOUT -UsePrebaked flag
cd azsh-windows-agent
.\01-build-and-push.ps1 -WindowsVersions @("2019", "2022", "2025")

# Force rollout to use standard images
kubectl rollout restart deployment -n az-devops-windows-002
```

## Files Created/Modified

✅ **Created:**
- `azsh-windows-agent/Dockerfile.windows-sh-agent-2019-windows2019.prebaked`
- `azsh-windows-agent/Dockerfile.windows-sh-agent-2022-windows2022.prebaked`
- `azsh-windows-agent/Dockerfile.windows-sh-agent-2025-windows2025.prebaked`
- `azsh-windows-agent/start-prebaked.ps1`
- `PREBAKED-AGENT-IMPLEMENTATION.md` (this doc)
- `NEXT-STEPS.md` (quick reference)

✅ **Modified:**
- `azsh-windows-agent/01-build-and-push.ps1` (added `-UsePrebaked` switch)

## Documentation

- **Full Implementation Guide:** `PREBAKED-AGENT-IMPLEMENTATION.md`
- **Original Issue Analysis:** `WINDOWS-AGENT-DOWNLOAD-ISSUE.md`
- **KEDA Fix Summary:** `KEDA-FIX-SUMMARY.md`
- **Deployment Status:** `DEPLOYMENT-STATUS.md`

---

**Ready to execute?** Start with Step 1 (build images) when ready.
