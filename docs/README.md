# Docs Index — Azure DevOps Self‑Hosted Agents on Kubernetes

This folder contains user and operator documentation for deploying, validating, and maintaining Azure DevOps self‑hosted agents on Kubernetes.

## Core Documentation

### Setup & Deployment

- `bootstrap-and-build.md` — Orchestrator (infra + prebaked image build + pipeline provisioning)
- `bootstrap-env.md` — Environment setup and prerequisites
- `deploy-selfhosted-agents.md` — Helm deployment & update flow
- `validate-selfhosted-agents.md` — Post‑deploy validation
- `uninstall-selfhosted-agents.md` — Removal & cleanup
- `weekly-agent-pipeline.md` — Scheduled weekly prebaked image refresh

### Docker-in-Docker (DinD) Support

✅ **Both Linux and Windows DinD are fully functional on Azure AKS and AKS-HCI (Azure Local)**

#### Windows DinD

- `WINDOWS-DIND-WORKING-SOLUTION.md` — ✅ **AKS-HCI Manual Installation Guide**
- `WINDOWS-DIND-AZURE-AKS-MANUAL-INSTALLATION.md` — ✅ **Azure AKS Manual Installation Guide**
- `WINDOWS-DIND-YAML-MANIFESTS.md` — Kubernetes manifests and Helm configuration
- `WINDOWS-DIND-IMPLEMENTATION.md` — Technical implementation details

**Key Points:**

- Windows DinD requires manual Docker Engine installation on Windows nodes
- Same installation process works on both Azure AKS and AKS-HCI
- Docker 28.0.2 coexists with containerd (Kubernetes runtime)
- Named pipe `\\.\pipe\docker_engine` enables DinD mounting

#### Linux DinD

- Linux DinD is **built-in** to the `linux-sh-agent-dind` image variant
- No additional installation required
- Works out-of-the-box on both Azure AKS and AKS-HCI

### Quick Reference

- `QUICK-COMMANDS.md` — Common build/deploy commands
- `run-on-selfhosted-pool-sample.md` — Minimal usage example

Note: `validate-selfhosted-agents.md` and `deploy-selfhosted-agents.md` now support a `useOnPremAgents` boolean pipeline parameter to toggle whether CI jobs run on the repository's on-prem pool (for example `UbuntuLatestPoolOnPrem`) or use the hosted `ubuntu-latest` pool. Even when the parameter is left false, the pipeline computes an effective flag so that setting `useAzureLocal: true` automatically runs the jobs on the on-prem pool.

Important: `useAzureLocal` and kubeconfig handling

- The deploy pipeline sets an explicit `USE_AZURE_LOCAL` environment variable and will pass `-UseAzureLocal` to the wrapper/script when `useAzureLocal` is true. This prevents accidentally inferring local mode from a `KUBECONFIG` value that may have been set by `az aks get-credentials` in non-local runs, and forces the pipeline to pick your on-prem pool.
- The wrapper script `.azuredevops/scripts/run-deploy-selfhosted-agents-helm.ps1` honors the explicit `USE_AZURE_LOCAL` environment variable and only forwards `-UseAzureLocal` when the flag is truthy. The deploy helper script accepts `-Kubeconfig` and `-KubeconfigAzureLocal` and prefers the AzureLocal variant when local mode is requested.

Subfolders

- `self-hosted-agents/` — OS-specific setup and guidance (Windows/Linux). See the `setup/` pages for walkthroughs.

Recent key updates (2025-10)

| Area | Change | Impact |
|------|--------|--------|
| **Windows DinD** | **✅ Working on BOTH Azure AKS & AKS-HCI** | **Manual Docker install via hostProcess pods; same process for both platforms** |
| **Linux DinD** | **✅ Built-in support for BOTH platforms** | **Works out-of-the-box on Azure AKS & AKS-HCI** |
| Images | Prebaked agents now default (Linux + Windows) | < 1 min cold start |
| Linux Variant | DinD (`linux-sh-agent-dind`) is the default; weekly pipeline pins `LINUX_REPOSITORY_NAME` accordingly | In-pod Docker daemon, isolated build context |
| Versioning | Dynamic agent version via GitHub releases | No manual bumps |
| Download host | Switched to `download.agent.dev.azure.com` | Fixed legacy DNS failures |
| Pipelines | Parallel per-version Windows builds | Faster refresh cadence |
| Orchestrator | ACR reuse & skip flag improvements | Idempotent reruns |

How to contribute updates to docs

Edit the relevant `docs/*.md` file, run a local spellcheck if desired, then open a PR describing the change and how you validated (mock run, pipeline run, or local smoke test).

Quick docs change checklist

- Make a small, focused branch and commit.
- Update the relevant `docs/*.md` file(s) and `README.md` where appropriate.
- Run a PowerShell parser check on any changed scripts:

    ```powershell
    pwsh -NoProfile -Command "[void]([System.Management.Automation.Language.Parser]::ParseFile('path\to\script.ps1',[ref]$null,[ref]$null)); Write-Host 'Syntax OK'"
    ```

- (Optional) Run mock runners (if present) to validate tag formation and push targets:

    ```powershell
    pwsh -NoProfile -File .\.tmp\run-mock-linux-build.ps1
    pwsh -NoProfile -File .\.tmp\run-mock-windows-build.ps1
    ```

Push a draft PR and include what you ran to validate the change.

