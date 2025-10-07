# bootstrap-and-build.ps1 — Orchestrator for infra, images, and Azure DevOps provisioning

This document describes the new single-entry orchestrator script `bootstrap-and-build.ps1` (located at the repository root). The script is intended to simplify onboarding and CI-driven provisioning by performing these steps end-to-end:

- Deploy infrastructure (Bicep) or run an existing infra helper.
- Discover or accept an ACR name and AKS cluster.
- Build and push Linux and Windows agent images to ACR.
- Render pipeline YAML templates (.template.yml -> .yml) with repository-specific tokens.
- Create/update Azure DevOps resources:
  - Variable Group (secret `AZDO_PAT`).
  - Upload kubeconfig as a secure file (for local-mode scenarios).
  - Create or update five required pipelines from `.azuredevops/pipelines/`.

Why use this script

- Single command to bring up infra, images, and CI wiring for an AKS-based self-hosted agent pool.
- Reduces manual steps and ensures pipeline templates are rendered consistently with the instance name and ACR.
- Includes robust Azure DevOps provisioning with CLI-first, then REST fallback for secure-file uploads.

Prerequisites

- PowerShell 7+ (pwsh) available on PATH.
- Azure CLI (`az`) with `azure-devops` extension installed and configured (for AZ operations).
- **Azure DevOps Personal Access Token (PAT)** set as `AZDO_PAT` environment variable (required).
- Docker (for building images) and appropriate host support (Windows Docker for Windows images) - optional if using `-BuildInPipeline`.
- A container registry (ACR) or provide `-ContainerRegistryName` to the script.
- kubectl / helm not strictly required for the top-level script, but the deploy helper and Helm steps will need them when deploying into a cluster.

Usage

**IMPORTANT:** Set the `AZDO_PAT` environment variable before running.

## Option 1: Using .env file (recommended for local development)

```powershell
# Copy the example file
cp .env.example .env

# Edit .env and set your PAT
# AZDO_PAT=your-actual-pat-token-here

# The script will automatically load .env when you run it
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -InstanceNumber 003 `
  -Location canadacentral `
  -ADOCollectionName <your-org-name> `
  -AzureDevOpsProject <your-project-name> `
  -AzureDevOpsRepo <your-repo-name> `
  -BuildInPipeline
```

## Option 2: Using environment variable (one-time or CI)

```powershell
# Set PAT first
$env:AZDO_PAT = 'your-pat-token-here'

# Then run the script
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -InstanceNumber 003 `
  -Location canadacentral `
  -ADOCollectionName <your-org-name> `
  -AzureDevOpsProject <your-project-name> `
  -AzureDevOpsRepo <your-repo-name> `
  -BuildInPipeline
```

Run locally or in CI.

**Example with local Docker builds:**

```powershell
# Set PAT first
$env:AZDO_PAT = 'your-pat-token-here'

# Run with local builds
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -InstanceNumber 003 `
  -Location canadacentral `
  -ADOCollectionName <your-org-name> `
  -AzureDevOpsProject <your-project-name> `
  -AzureDevOpsRepo <your-repo-name> `
  -ContainerRegistryName <your-acr-shortname>
```

**Example deferring builds to pipeline (recommended for local setup):**

```powershell
# Set PAT first
$env:AZDO_PAT = 'your-pat-token-here'

# Run without local builds
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -InstanceNumber 003 `
  -Location canadacentral `
  -ADOCollectionName <your-org-name> `
  -AzureDevOpsProject <your-project-name> `
  -AzureDevOpsRepo <your-repo-name> `
  -BuildInPipeline
```

> **Note:** When using `-BuildInPipeline`, the script sets up infrastructure and pipelines but skips local Docker builds. Run the weekly image refresh pipeline afterward to build and push images using CI agents with Docker.

Key parameters

**Required Parameters:**

- `-InstanceNumber` (required): short identifier used to create resource names (RG, AKS, ACR defaults).
- `-Location` (required): Azure location for infra deployment (when running deploy step).
- `-ADOCollectionName` (required): Azure DevOps organization name.
- `-AzureDevOpsProject` (required): Azure DevOps project name.
- `-AzureDevOpsRepo` (required): Azure DevOps repository name.

**Optional Parameters:**

- `-ContainerRegistryName` (optional): when present, uses this ACR and skips discovery.
- `-BuildInPipeline` (optional switch): skip local Docker image builds; infrastructure and pipelines will be set up, but image builds are deferred to the weekly refresh pipeline. Use this when running the bootstrap script locally without Docker Desktop or when you prefer to build images in CI rather than locally.
- `-SkipContainerRegistry` (optional switch): explicitly signal to skip ACR creation. This is implied automatically whenever `-ContainerRegistryName` is supplied. The orchestrator renders `__SKIP_CONTAINER_REGISTRY__` token values in pipeline templates as `True` or `False` accordingly.
- `-EnableWindows` (switch): enable Windows images and builds.
- `-ResourceGroupName` (optional): custom resource group name (defaults to `rg-aks-ado-agents-<InstanceNumber>`).
- `-WindowsNodeCount` (optional): number of Windows nodes (default: 1).
- `-LinuxNodeCount` (optional): number of Linux nodes (default: 1).
- `-AzureDevOpsOrgUrl` (optional): Azure DevOps organization URL (defaults to `https://dev.azure.com/<ADOCollectionName>`).
- `-BootstrapPoolName` (optional): agent pool name for bootstrap (default: "KubernetesPoolWindows").
- `-KubeconfigAzureLocalPath` / `-KubeContextAzureLocal`: used when uploading a kubeconfig as a secure file for local-mode pipelines.
- `-AzureDevOpsServiceConnectionName` (optional): service connection name (default: "ADO_SvcConnRgScopedProd").
- `-AzureDevOpsVariableGroup` (optional): variable group name (defaults to `<AzureDevOpsProject>-<InstanceNumber>`).
- `-AzureDevOpsPatTokenEnvironmentVariableName` (optional): environment variable name for PAT (default: "AZDO_PAT").
- Various pipeline name parameters for customizing created pipeline names.

What it provisions

- Bicep/Azure resources (if deploy helper is present and invoked).
- Agent images (Linux and optional Windows) built and pushed to ACR.
- Rendered pipeline files written to `.azuredevops/pipelines/*.yml`.
- Variable group named `ADO_az-devops-agents-k8s` (default) with `AZDO_PAT` secret (reads from env var `AZDO_PAT` when present).
- Secure file in Azure DevOps for kubeconfig (helps `-UseAzureLocal` runs) via a helper that attempts CLI upload and falls back to REST with PAT auth.
- Five pipelines created/updated from the rendered YAMLs:
  - deploy-selfhosted-agents-helm
  - uninstall-selfhosted-agents-helm
  - run-on-selfhosted-pool-sample-helm
  - weekly-agent-images-refresh
  - validate-selfhosted-agents-helm

Behavioral notes & safety

- The script captures and parses deploy output to pick up named outputs (for example `containerRegistryName`) but falls back to discovery heuristics when outputs are not present.
- When `-ContainerRegistryName` is specified the orchestrator forwards `-SkipContainerRegistry` to the infra deploy helper / Bicep template (param `skipContainerRegistry`) to avoid attempting to recreate an existing registry.
- After running the ACR credential helper the script performs a verification pass (only if a PAT env var is present) that fails fast if `ACR_USERNAME` or `ACR_PASSWORD` are absent from the variable group.
- Docker Desktop engine switching is attempted automatically on Windows (Linux build → linux engine, Windows build → windows engine) but degrades gracefully if DockerCli.exe is not found.
- Variable group JSON parsing is defensive and supports differing az CLI / extension return shapes (array, `variables` map, or flat object).
- If an explicit `-ContainerRegistryName` is provided the deploy helper is invoked with `-SkipContainerRegistry` so the Bicep template will not attempt to create an ACR. (Bicep template exposes `skipContainerRegistry` parameter.)
- After attempting to add ACR credentials to the Azure DevOps variable group, the orchestrator now performs a verification step (only when PAT present) to ensure `ACR_USERNAME` and `ACR_PASSWORD` exist; failure aborts early so dependent pipelines fail fast.
- The Azure DevOps provisioning helper prefers environment variable `AZDO_PAT` for non-interactive runs. If not provided it will request a PAT interactively.
- Secure-file upload uses a helper that will delete an existing secure-file with the same name and re-upload the provided kubeconfig.
- Pipeline create/update uses the az CLI where possible; the helper omits brittle flags (like `--repository-type`) to remain compatible across extension versions.

Logs & streaming

- The script streams child script output to the console while keeping a captured copy for post-run logging. This makes it possible to follow long-running build/push and provisioning steps live in CI logs.

Next steps and customization

- Make the provisioning helper fatal on failure: the orchestrator currently treats provisioning helper failures as warnings by default; CI workflows can be tightened to fail the job if provisioning doesn't succeed.
- Add az-devops extension version detection to choose the most compatible pipeline creation/update method automatically.
- Add registry existence preflight when skipping ACR creation (planned) to emit a clearer error if a supplied registry name does not exist.

Support & troubleshooting

- If pipeline create/update fails due to az CLI extension differences, re-run with `AZDO_PAT` set and inspect the helper output. The helper prints `az` stdout/stderr when commands fail to aid diagnosis.
- For secure-file upload failures, ensure the PAT has `Manage` permissions on secure files or use the helper's REST fallback which requires a PAT with secure-files write permissions.
- If the orchestrator fails with "Variable group ... is missing required ACR variables" re-run the ACR credentials helper manually (`.azuredevops/scripts/add-acr-creds-to-variablegroup.ps1`) or verify PAT scopes include Variable Groups (Read, Manage). Secret values appear as null in CLI listing—presence, not value content, is what the verification checks.

Related docs

## Recent enhancements (2025-10)

| Area | Change | Benefit |
|------|--------|---------|
| Registry reuse | `-SkipContainerRegistry` + implicit when `-ContainerRegistryName` present | Clean reuse of existing ACR without template edits |
| Credential assurance | Post-helper verification of `ACR_USERNAME` / `ACR_PASSWORD` | Early, clear failure instead of latent pipeline errors |
| Robust parsing | Multi-shape variable-group JSON handling | Resilient across az CLI / extension versions |
| Docker engine mgmt | Automatic engine switching on Windows hosts | Reduces manual Docker Desktop interaction |
| Token rendering | `__SKIP_CONTAINER_REGISTRY__` token now deterministic | Pipelines can branch on registry creation logic |


- `docs/deploy-selfhosted-agents.md` — details the Helm deploy flow used by the deploy helper.
- `docs/weekly-agent-pipeline.md` — explains the weekly images refresh pipeline referenced by the orchestrator.

 
