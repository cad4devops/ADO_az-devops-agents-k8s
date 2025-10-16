# Key Files Explained

This document provides a comprehensive explanation of the key files in the Azure DevOps Self-Hosted Agents on Kubernetes repository. Understanding these files is essential for working with, maintaining, and extending this solution.

## Table of Contents

1. [Build Scripts](#build-scripts)
2. [Deployment Scripts](#deployment-scripts)
3. [Orchestration Scripts](#orchestration-scripts)
4. [Pipeline Configurations](#pipeline-configurations)
5. [Dockerfiles](#dockerfiles)
6. [Configuration Files](#configuration-files)

---

## Build Scripts

### azsh-linux-agent/01-build-and-push.ps1

**Purpose:** Builds and pushes Linux Azure DevOps agent Docker images to Azure Container Registry.

**Key Features:**
- Supports two build modes:
  - **PRE-BAKED (default)**: Agent is downloaded at build time and included in the image (faster startup, larger image)
  - **STANDARD**: Agent is downloaded at container runtime (smaller image, slower startup)
- Automatically normalizes ACR names (appends `.azurecr.io` if needed)
- Fetches the latest Azure Pipelines agent version from GitHub releases
- Creates multiple image tags (base, versioned, latest)
- Handles ACR authentication via Azure CLI
- Provides detailed error handling for push operations

**Usage Example:**
```powershell
pwsh ./azsh-linux-agent/01-build-and-push.ps1 `
    -DefaultAcr 'cragents003c66i4n7btfksg' `
    -TagSuffix '20250920-a1b2c3d' `
    -SemVer '1.0.0'
```

**Environment Variables:**
- `ACR_NAME`: Azure Container Registry name
- `LINUX_REPOSITORY_NAME`: Docker repository name
- `LINUX_BASE_TAG`: Base image tag (e.g., ubuntu-24.04)
- `TAG_SUFFIX`: Tag suffix for versioning
- `SEMVER_EFFECTIVE`: Semantic version tag

**Documentation:** Use `Get-Help ./01-build-and-push.ps1 -Full` for complete inline documentation.

---

### azsh-windows-agent/01-build-and-push.ps1

**Purpose:** Builds and pushes Windows Azure DevOps agent Docker images to Azure Container Registry.

**Key Features:**
- Supports multiple Windows versions (2019, 2022, 2025)
- Two build modes (PRE-BAKED and STANDARD, same as Linux)
- Detects Hyper-V isolation support and falls back to process isolation if needed
- Handles Windows version precedence from multiple sources
- Captures image digests for manifest list creation
- Creates Windows-version-specific tags

**Usage Example:**
```powershell
pwsh ./azsh-windows-agent/01-build-and-push.ps1 `
    -DefaultAcr 'cragents003c66i4n7btfksg' `
    -WindowsVersions @('2022', '2025') `
    -TagSuffix '20250920-a1b2c3d'
```

**Windows Version Precedence:**
1. Explicit `-WindowsVersions` parameter (highest priority)
2. `WIN_VERSION` environment variable (single version)
3. `WINDOWS_VERSIONS` environment variable (CSV)
4. Default value `@('2022', '2025')` (lowest priority)

**Isolation Modes:**
- **Hyper-V isolation**: Better security and compatibility (requires Hyper-V feature)
- **Process isolation**: Faster but requires matching host/container OS versions

**Documentation:** Use `Get-Help ./01-build-and-push.ps1 -Full` for complete inline documentation.

---

## Deployment Scripts

### deploy-selfhosted-agents-helm.ps1

**Purpose:** Deploys Azure DevOps self-hosted agents to Kubernetes using Helm charts.

**Key Features:**
- Supports both AKS and on-premises Kubernetes clusters
- Deploys Linux and/or Windows agents
- Creates or verifies Azure DevOps agent pools
- Configures KEDA autoscaling based on pipeline queue depth
- Handles Docker registry secrets for private ACR access
- Supports multiple kubeconfig scenarios (AKS, Azure Local)

**What It Does:**
1. Resolves kubeconfig and context (AKS or Azure Local mode)
2. Logs into AKS cluster (if using AKS)
3. Creates Docker registry secret if ACR credentials provided
4. Installs KEDA for autoscaling
5. Deploys Linux agent pool (if enabled)
6. Deploys Windows agent pool (if enabled)
7. Creates/verifies Azure DevOps agent pools if requested

**Usage Example:**
```powershell
pwsh ./deploy-selfhosted-agents-helm.ps1 `
    -InstanceNumber '003' `
    -AcrName 'cragents003c66i4n7btfksg' `
    -AzureDevOpsOrgUrl 'https://dev.azure.com/myorg' `
    -AcrUsername '<username>' `
    -AcrPassword '<password>' `
    -EnsureAzDoPools
```

**Environment Variables:**
- `AZDO_PAT`: Azure DevOps Personal Access Token (required for pool creation)
- `KUBECONFIG`: Path to kubeconfig file

---

### uninstall-selfhosted-agents-helm.ps1

**Purpose:** Idempotent cleanup script for removing deployed agents and resources.

**Key Features:**
- Removes Helm releases for Linux and Windows agents
- Deletes namespaces (az-devops-linux-*, az-devops-windows-*)
- Removes Docker registry secrets
- Uninstalls KEDA and optionally removes KEDA CRDs
- Optionally deletes Azure DevOps agent pools
- Forces finalization of stuck namespaces

**What It Does:**
1. Resolves kubeconfig and context
2. Uninstalls agent Helm releases
3. Removes Docker registry secrets
4. Deletes agent namespaces
5. Uninstalls KEDA
6. Optionally removes KEDA CRDs
7. Optionally deletes Azure DevOps agent pools via API

**Usage Example:**
```powershell
pwsh ./uninstall-selfhosted-agents-helm.ps1 `
    -InstanceNumber '003' `
    -AzureDevOpsOrgUrl 'https://dev.azure.com/myorg' `
    -ConfirmDeletion 'YES'
```

**Safety Features:**
- Requires explicit confirmation (`ConfirmDeletion = 'YES'`)
- Idempotent (safe to run multiple times)
- Handles stuck namespaces with finalizer removal

---

## Orchestration Scripts

### bootstrap-and-build.ps1

**Purpose:** Master orchestrator that ties together infrastructure deployment, image building, and pipeline setup.

**Key Responsibilities:**
1. **Infrastructure Deployment**: Calls Bicep templates to create/update Azure resources (ACR, AKS)
2. **Image Building**: Invokes Linux and Windows build scripts to create agent images
3. **Pipeline Template Rendering**: Replaces tokens in `.template.yml` files to create pipeline YAML
4. **Service Connection Management**: Optionally creates Azure RM service connections using Workload Identity Federation (WIF)
5. **Variable Group Management**: Updates Azure DevOps variable groups with infrastructure details

**Usage Example:**
```powershell
pwsh ./bootstrap-and-build.ps1 `
    -InstanceNumber '003' `
    -Location 'canadacentral' `
    -ADOCollectionName 'myorg' `
    -AzureDevOpsProject 'MyProject' `
    -AzureDevOpsRepo 'ADO_az-devops-agents-k8s' `
    -EnableWindows `
    -CreateWifServiceConnection `
    -SubscriptionId '<guid>' `
    -TenantId '<guid>'
```

**Workflow:**
```
Infrastructure → Extract Outputs → Build Images → Render Templates → Update Variables
```

---

## Pipeline Configurations

### .azuredevops/pipelines/weekly-agent-images-refresh.yml

**Purpose:** Scheduled pipeline that rebuilds agent images weekly to include latest security updates.

**Key Features:**
- Scheduled weekly execution
- GitVersion for semantic versioning
- Preflight checks (ACR validation, manifest list probe)
- Parallel builds for different Windows versions
- Digest capture for manifest list creation
- Summary job that publishes build artifacts

**Pipeline Stages:**
1. **Versioning**: Generates semantic version using GitVersion
2. **Preflight**: Validates ACR and detects manifest list support
3. **LinuxAgentImage**: Builds Linux agent images
4. **WindowsAgentImage_2019/2022/2025**: Parallel Windows builds per version
5. **Summary**: Collects digests, creates manifests, publishes artifacts

**Trigger:**
```yaml
schedules:
- cron: '0 2 * * 1'  # Weekly on Monday at 2 AM UTC
```

---

### .azuredevops/pipelines/deploy-selfhosted-agents-helm.yml

**Purpose:** Pipeline for deploying agents to Kubernetes clusters.

**Key Features:**
- Supports AKS and Azure Local deployments
- Linux and Windows agent deployment
- KEDA autoscaling configuration
- Agent pool creation/verification
- Environment-based approvals

---

## Dockerfiles

### Linux Dockerfiles

#### Dockerfile.linux-sh-agent-docker
**Standard variant** - Agent downloaded at runtime
- Based on Ubuntu 24.04
- Installs Docker CLI
- Downloads agent on container start via `start.sh`

#### Dockerfile.linux-sh-agent-docker.prebaked
**Prebaked variant** - Agent pre-installed at build time
- Based on Ubuntu 24.04
- Docker CLI included
- Agent downloaded during image build via `ARG AGENT_VERSION`
- Faster startup, larger image size

---

### Windows Dockerfiles

#### Dockerfile.windows-sh-agent-YYYY-windowsLTSC
Pattern: `Dockerfile.windows-sh-agent-2022-windows2022`

**Standard variants** - Agent downloaded at runtime
- Based on specific Windows Server versions
- Downloads agent on container start via `start.ps1`

#### Dockerfile.windows-sh-agent-YYYY-windowsLTSC.prebaked
Pattern: `Dockerfile.windows-sh-agent-2022-windows2022.prebaked`

**Prebaked variants** - Agent pre-installed at build time
- Based on specific Windows Server versions
- Agent downloaded during image build
- Includes Get-LatestAzureDevOpsAgent.ps1 helper
- Installs common tools via Install-WindowsAgentTools.ps1

---

## Configuration Files

### GitVersion.yml

**Purpose:** Controls semantic versioning for image tags.

**Configuration:**
```yaml
mode: ContinuousDelivery
branches:
  main:
    increment: Patch
```

---

### copilot-instructions.md

**Purpose:** Instructions for automated coding agents and developers working on the repository.

**Key Sections:**
- Quick links to important files
- Build script invocation patterns
- Mock runners for local testing
- Environment variables and parameters
- Known issues and solutions
- Troubleshooting checklist

**Target Audience:**
- GitHub Copilot agents
- Developers making changes to build/deploy scripts
- CI/CD maintainers

---

### .env.example

**Purpose:** Template for local environment configuration.

**Variables:**
```bash
ACR_NAME=cragents003c66i4n7btfksg
AZURE_DEVOPS_ORG_URL=https://dev.azure.com/myorg
AZDO_PAT=<personal-access-token>
INSTANCE_NUMBER=003
```

---

## File Relationships

```
bootstrap-and-build.ps1
    ├─> infra/bicep/deploy.ps1 (creates ACR, AKS)
    ├─> azsh-linux-agent/01-build-and-push.ps1
    ├─> azsh-windows-agent/01-build-and-push.ps1
    └─> Renders .template.yml → .yml

deploy-selfhosted-agents-helm.ps1
    ├─> helm-charts-v2/ (Helm charts)
    ├─> kubectl (namespace, secrets)
    └─> Azure DevOps API (create pools)

.azuredevops/pipelines/weekly-agent-images-refresh.yml
    ├─> GitVersion (versioning)
    ├─> azsh-linux-agent/01-build-and-push.ps1
    ├─> azsh-windows-agent/01-build-and-push.ps1
    └─> Summary job (digest collection)
```

---

## Best Practices

### When Modifying Build Scripts
1. Test with mock runners in `.tmp/` first
2. Run PowerShell syntax validation: `pwsh -Command "[void](Parser::ParseFile(...))"`
3. Verify environment variable precedence
4. Update inline documentation if adding parameters

### When Modifying Deployment Scripts
1. Test against a non-production cluster first
2. Verify kubeconfig resolution logic
3. Check AZDO_PAT masking in logs
4. Test both AKS and Azure Local modes

### When Modifying Pipelines
1. Keep changes minimal and scoped
2. Pass arguments explicitly rather than relying on environment variables
3. Test syntax: `az pipelines validate --yaml-path <path>`
4. Add per-job debug output for troubleshooting

---

## Quick Reference

| Task | File | Command |
|------|------|---------|
| Build Linux image | `azsh-linux-agent/01-build-and-push.ps1` | `pwsh 01-build-and-push.ps1 -DefaultAcr <acr>` |
| Build Windows image | `azsh-windows-agent/01-build-and-push.ps1` | `pwsh 01-build-and-push.ps1 -DefaultAcr <acr> -WindowsVersions @('2022')` |
| Deploy agents | `deploy-selfhosted-agents-helm.ps1` | `pwsh deploy-selfhosted-agents-helm.ps1 -InstanceNumber 003 -AcrName <acr> -AzureDevOpsOrgUrl <url>` |
| Remove agents | `uninstall-selfhosted-agents-helm.ps1` | `pwsh uninstall-selfhosted-agents-helm.ps1 -InstanceNumber 003 -AzureDevOpsOrgUrl <url> -ConfirmDeletion YES` |
| Full setup | `bootstrap-and-build.ps1` | `pwsh bootstrap-and-build.ps1 -InstanceNumber 003 -Location canadacentral -ADOCollectionName org -AzureDevOpsProject proj -AzureDevOpsRepo repo` |
| Get help | Any .ps1 script | `Get-Help <script> -Full` |

---

## Additional Documentation

- [README.md](../README.md) - Repository overview and architecture
- [docs/QUICK-COMMANDS.md](QUICK-COMMANDS.md) - Common command examples
- [docs/bootstrap-and-build.md](bootstrap-and-build.md) - Detailed bootstrap guide
- [docs/deploy-selfhosted-agents.md](deploy-selfhosted-agents.md) - Deployment guide
- [docs/weekly-agent-pipeline.md](weekly-agent-pipeline.md) - Pipeline documentation

---

## Summary

This repository follows a clear separation of concerns:

- **Build scripts** handle Docker image creation and ACR pushing
- **Deployment scripts** handle Kubernetes resource creation via Helm
- **Orchestration scripts** tie together infrastructure, building, and configuration
- **Pipeline configurations** automate these workflows in Azure DevOps

Each script is designed to be:
- **Idempotent**: Safe to run multiple times
- **Configurable**: Via parameters and environment variables
- **CI-friendly**: Detailed logging and error handling
- **Well-documented**: Inline help via PowerShell comment-based help

Understanding these key files will help you effectively work with, maintain, and extend this Azure DevOps self-hosted agent solution.
