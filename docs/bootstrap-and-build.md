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
- Docker (for building images) and appropriate host support (Windows Docker for Windows images).
- A container registry (ACR) or provide `-ContainerRegistryName` to the script.
- An Azure DevOps PAT with scopes sufficient to manage variable groups, pipelines, and secure files if running the provisioning step (`AZDO_PAT` env var or provided interactively).
- kubectl / helm not strictly required for the top-level script, but the deploy helper and Helm steps will need them when deploying into a cluster.

Usage

Run locally or in CI. Example:

```powershell
pwsh -NoProfile -File .\bootstrap-and-build.ps1 -InstanceNumber 003 -Location canadacentral -ContainerRegistryName cragents003c66i4n7btfksg
```

Key parameters

- `-InstanceNumber` (required): short identifier used to create resource names (RG, AKS, ACR defaults).
- `-Location` (required): Azure location for infra deployment (when running deploy step).
- `-ContainerRegistryName` (optional): when present, uses this ACR and skips discovery.
- `-EnableWindows` (switch): enable Windows images and builds.
- `-KubeconfigAzureLocalPath` / `-KubeContextAzureLocal`: used when uploading a kubeconfig as a secure file for local-mode pipelines.
- `-AzureDevOpsOrgUrl`, `-AzureDevOpsProject`, `-AzureDevOpsRepo`: used by the provisioning helper when creating/updating pipelines.

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
- The Azure DevOps provisioning helper prefers environment variable `AZDO_PAT` for non-interactive runs. If not provided it will request a PAT interactively.
- Secure-file upload uses a helper that will delete an existing secure-file with the same name and re-upload the provided kubeconfig.
- Pipeline create/update uses the az CLI where possible; the helper omits brittle flags (like `--repository-type`) to remain compatible across extension versions.

Logs & streaming

- The script streams child script output to the console while keeping a captured copy for post-run logging. This makes it possible to follow long-running build/push and provisioning steps live in CI logs.

Next steps and customization

- Make the provisioning helper fatal on failure: the orchestrator currently treats provisioning helper failures as warnings by default; CI workflows can be tightened to fail the job if provisioning doesn't succeed.
- Add az-devops extension version detection to choose the most compatible pipeline creation/update method automatically.

Support & troubleshooting

- If pipeline create/update fails due to az CLI extension differences, re-run with `AZDO_PAT` set and inspect the helper output. The helper prints `az` stdout/stderr when commands fail to aid diagnosis.
- For secure-file upload failures, ensure the PAT has `Manage` permissions on secure files or use the helper's REST fallback which requires a PAT with secure-files write permissions.

Related docs

- `docs/deploy-selfhosted-agents.md` — details the Helm deploy flow used by the deploy helper.
- `docs/weekly-agent-pipeline.md` — explains the weekly images refresh pipeline referenced by the orchestrator.

 
