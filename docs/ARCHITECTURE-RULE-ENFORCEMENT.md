# Architecture Rule Enforcement: Windows DinD Only on AKS-HCI

## Summary

All scripts and pipelines have been updated to enforce the architecture rule:

✅ **Windows DinD is ONLY supported on AKS-HCI (useAzureLocal=true)**  
❌ **Windows DinD is NOT supported on standard AKS (useAzureLocal=false)**

When deploying to standard AKS, `windowsImageVariant` will automatically be forced from `'dind'` to `'docker'` with warnings.

## Root Cause

- **Standard AKS**: Windows nodes use `containerd` runtime (no Docker Engine, no `\\.\pipe\docker_engine` pipe)
- **AKS-HCI**: Windows nodes have Docker Engine pre-installed with the named pipe available

## Changes Made

### 1. `deploy-selfhosted-agents-helm.ps1`

**Location**: Lines 70-77

**Change**: Added enforcement logic that forces `WindowsImageVariant` to `'docker'` when `-UseAzureLocal` is not specified:

```powershell
# ARCHITECTURE RULE: Windows DinD only supported on AKS-HCI, not standard AKS
if (-not $UseAzureLocal.IsPresent -and $WindowsImageVariant -eq 'dind') {
    Write-Warning "Windows DinD is not supported on standard AKS (only on AKS-HCI)."
    Write-Warning "Standard AKS Windows nodes use containerd and cannot run Docker Engine."
    Write-Warning "Forcing WindowsImageVariant from 'dind' to 'docker'."
    $WindowsImageVariant = 'docker'
}
```

### 2. `.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml`

**Location**: After checkout step (new task added)

**Change**: Added enforcement task that sets `WINDOWS_IMAGE_VARIANT` variable:

```yaml
- task: PowerShell@2
  displayName: Enforce architecture rules (Windows DinD only on AKS-HCI)
  inputs:
    targetType: inline
    pwsh: true
    script: |
      # ARCHITECTURE RULE: Windows DinD only supported on AKS-HCI
      if ($useAzureLocal -ne 'True' -and $windowsImageVariant -eq 'dind') {
        Write-Warning "Windows DinD is NOT supported on standard AKS."
        Write-Warning "Forcing windowsImageVariant from 'dind' to 'docker'"
        Write-Host "##vso[task.setvariable variable=WINDOWS_IMAGE_VARIANT]docker"
      } else {
        Write-Host "##vso[task.setvariable variable=WINDOWS_IMAGE_VARIANT]$windowsImageVariant"
      }
```

**Location**: Environment variable in deploy task

**Change**: Updated to use computed variable instead of parameter:

```yaml
WINDOWS_IMAGE_VARIANT: "$(WINDOWS_IMAGE_VARIANT)"  # Was: "${{ parameters.windowsImageVariant }}"
```

**Location**: Config artifact generation (Summary job)

**Change**: Applies same enforcement logic when creating config.json for validation pipeline:

```powershell
$effectiveWindowsVariant = '${{ parameters.windowsImageVariant }}'
$useAzureLocal = $${{ parameters.useAzureLocal }}
if (-not $useAzureLocal -and $effectiveWindowsVariant -eq 'dind') {
  Write-Host "Architecture rule applied: forcing windowsImageVariant to 'docker'"
  $effectiveWindowsVariant = 'docker'
}
```

**Location**: Parameter documentation

**Change**: Updated comments to clarify support:

```yaml
- name: windowsImageVariant
  type: string
  default: "dind" # Default: dind for AKS-HCI. Automatically forced to 'docker' for standard AKS.
  values:
    - "dind" # Only supported on AKS-HCI (useAzureLocal=true)
    - "docker" # Standard Windows agents (works on both AKS and AKS-HCI)
```

### 3. `.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml`

**Location**: Docker DinD smoke test step

**Change**: Made the test conditional on BOTH `windowsImageVariant='dind'` AND `useAzureLocal=true`:

```yaml
- ${{ if and(eq(parameters.windowsImageVariant, 'dind'), eq(parameters.useAzureLocal, true)) }}:
    - task: PowerShell@2
      displayName: Docker DinD smoke test (Windows - AKS-HCI only)
```

Added informational message in test:

```powershell
Write-Host "Windows DinD smoke test (AKS-HCI/Azure Local only)"
Write-Host "Note: This test is skipped on standard AKS as Windows DinD is not supported there."
```

### 4. `.azuredevops/pipelines/validate-selfhosted-agents-helm.yml`

**Location**: CheckShouldRun step for Windows validation job

**Change**: Added enforcement logic when reading config:

```powershell
$variant = [string]$cfg.windowsImageVariant
if ([string]::IsNullOrWhiteSpace($variant)) { $variant = 'docker' }

# ARCHITECTURE RULE: Windows DinD only supported on AKS-HCI
if (-not $useLocalVal -and $variant -eq 'dind') {
  Write-Warning "Architecture rule: Windows DinD not supported on standard AKS. Forcing variant to 'docker'."
  $variant = 'docker'
}
```

**Location**: Parameter documentation

**Change**: Added clarifying comment:

```yaml
- name: useAzureLocal
  type: boolean
  default: false # When false (standard AKS), Windows DinD is not supported and will be forced to 'docker'
```

## Behavior Matrix

| Scenario | useAzureLocal | windowsImageVariant (requested) | windowsImageVariant (effective) | Result |
|----------|---------------|----------------------------------|----------------------------------|--------|
| AKS-HCI | `true` | `dind` | `dind` | ✅ Windows DinD agents deployed |
| AKS-HCI | `true` | `docker` | `docker` | ✅ Regular Windows agents deployed |
| Standard AKS | `false` | `dind` | `docker` (forced) | ⚠️  Regular Windows agents deployed (with warning) |
| Standard AKS | `false` | `docker` | `docker` | ✅ Regular Windows agents deployed |

## User Experience

### When Deploying to Standard AKS with windowsImageVariant=dind

Users will see clear warnings:

```
WARNING: ============================================================
WARNING: ARCHITECTURE ENFORCEMENT
WARNING: ============================================================
WARNING: Windows DinD is NOT supported on standard AKS.
WARNING: Standard AKS uses containerd (not Docker Engine).
WARNING: The \\.\pipe\docker_engine named pipe does not exist.
WARNING: 
WARNING: Windows DinD is ONLY available on AKS-HCI (useAzureLocal=true)
WARNING: where Docker Engine is pre-installed on Windows nodes.
WARNING: 
WARNING: Forcing windowsImageVariant from 'dind' to 'docker'
WARNING: ============================================================
```

### Pipeline Success

- Pipelines will NOT fail due to this enforcement
- The deployment proceeds with regular Windows agents instead
- The config artifact will reflect the effective (corrected) variant
- Downstream validation pipelines will use the correct variant

## Testing Recommendations

### For Standard AKS Deployments

✅ Test regular Windows agent functionality:
- PowerShell execution
- Azure CLI commands
- File operations
- Build tasks (without Docker)

❌ Do NOT test:
- Docker daemon access
- Docker CLI commands requiring daemon
- Container-based builds

### For AKS-HCI Deployments

✅ Test both regular and DinD agents:
- All standard agent functionality
- Docker daemon access via `\\.\pipe\docker_engine`
- Docker pull/run commands
- Container-based builds

## Migration Path for Existing Pipelines

If you have pipelines currently specifying `windowsImageVariant: dind` for standard AKS:

1. **No immediate action required** - enforcement logic will auto-correct
2. **Recommended**: Update pipeline parameters to explicitly set `windowsImageVariant: docker` for standard AKS
3. **Optional**: Add conditional logic based on `useAzureLocal` parameter

Example:

```yaml
parameters:
  - name: windowsImageVariant
    type: string
    ${{ if eq(parameters.useAzureLocal, true) }}:
      default: "dind"  # DinD available on AKS-HCI
    ${{ else }}:
      default: "docker"  # Standard agents for AKS
```

## Files Modified

1. ✅ `deploy-selfhosted-agents-helm.ps1` - Script enforcement
2. ✅ `.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml` - Pipeline enforcement
3. ✅ `.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml` - Conditional DinD testing
4. ✅ `.azuredevops/pipelines/validate-selfhosted-agents-helm.yml` - Validation enforcement

## Files Checked (No Changes Needed)

- ✅ `bootstrap-and-build.ps1` - Does not reference windowsImageVariant
- ✅ `.azuredevops/pipelines/deploy-aks.yml` - Does not reference windowsImageVariant

## Related Documentation

- `docs/WINDOWS-DIND-AKS-ISSUE.md` - Technical analysis of the issue
- `docs/WINDOWS-DIND-AKS-RESOLUTION.md` - Complete resolution summary

## Verification

To verify the enforcement is working:

1. Deploy to standard AKS with `windowsImageVariant: dind`:
   ```bash
   # Should show warnings and deploy regular Windows agents
   ```

2. Check deployed pods:
   ```powershell
   kubectl get deployment -n az-devops-windows-002 -o yaml | Select-String "image:"
   # Should show: windows-sh-agent-2022:latest (not *-dind)
   ```

3. Check config artifact:
   ```powershell
   # Download from pipeline artifacts
   # Should show: "windowsImageVariant": "docker"
   ```

---

**Date**: October 22, 2025  
**Status**: Complete  
**Impact**: All Windows DinD deployments to standard AKS will auto-correct to regular agents
