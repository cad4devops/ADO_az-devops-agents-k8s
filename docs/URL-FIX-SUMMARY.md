# URL Fix Summary - Correct Azure DevOps Agent Download URL

## Problem
The prebaked Dockerfiles were using the old URL `https://vstsagentpackage.azureedge.net/agent/` which no longer resolves (DNS failure: "The remote name could not be resolved").

## Solution
Updated all files to use the correct Microsoft URL: `https://download.agent.dev.azure.com/agent/`

## Files Updated ✅

### Windows Prebaked Dockerfiles
- ✅ `azsh-windows-agent/Dockerfile.windows-sh-agent-2019-windows2019.prebaked`
- ✅ `azsh-windows-agent/Dockerfile.windows-sh-agent-2022-windows2022.prebaked`
- ✅ `azsh-windows-agent/Dockerfile.windows-sh-agent-2025-windows2025.prebaked`

### Linux Prebaked Dockerfile
- ✅ `azsh-linux-agent/Dockerfile.linux-sh-agent-docker.prebaked`

### Helper Scripts
- ✅ `azsh-windows-agent/Get-LatestAzureDevOpsAgent.ps1`

## Correct URLs

### Windows Agent
```
https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-win-x64-4.261.0.zip
```

### Linux Agent
```
https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-linux-x64-4.261.0.tar.gz
```

## URL Pattern
```
https://download.agent.dev.azure.com/agent/${VERSION}/vsts-agent-${PLATFORM}-${VERSION}.${EXT}
```

Where:
- `${VERSION}` = Agent version (e.g., "4.261.0")
- `${PLATFORM}` = "win-x64" or "linux-x64"
- `${EXT}` = "zip" for Windows, "tar.gz" for Linux

## Testing

### Test the URLs manually:
```powershell
# Windows
Invoke-WebRequest -Uri "https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-win-x64-4.261.0.zip" -Method Head

# Linux
curl -I "https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-linux-x64-4.261.0.tar.gz"
```

### Build with fixed URLs:
```powershell
# Windows (will now download successfully)
cd azsh-windows-agent
.\01-build-and-push.ps1

# Linux (will now download successfully)
cd azsh-linux-agent
.\01-build-and-push.ps1
```

## Expected Build Output
```
Downloading Azure Pipelines agent v4.261.0...
Download URL: https://download.agent.dev.azure.com/agent/4.261.0/vsts-agent-win-x64-4.261.0.zip
✅ Download successful
✅ Extraction complete
✅ Agent v4.261.0 ready.
```

## Documentation Updates Needed
The following documentation files still reference the old URL and should be updated for accuracy (not critical for functionality):
- `docs/COMPLETE-IMPLEMENTATION-SUMMARY.md`
- `docs/IMPLEMENTATION-SUMMARY.md`
- `docs/LINUX-PREBAKED-IMPLEMENTATION.md`
- `docs/PREBAKED-AGENT-IMPLEMENTATION.md`
- `docs/PREBAKED-UPDATES.md`
- `docs/self-hosted-agents/self-hosted-agents-linux.md`

## Ready to Build ✅

All functional code has been updated with the correct URL. You can now run:

```powershell
# From repository root
.\bootstrap-and-build.ps1

# Or build individually:
cd azsh-windows-agent
.\01-build-and-push.ps1

cd ..\azsh-linux-agent
.\01-build-and-push.ps1
```

The Docker builds should now complete successfully! 🎉
