# Docs Index — Azure DevOps Self‑Hosted Agents on Kubernetes

This folder contains user and operator documentation for deploying, validating, and maintaining Azure DevOps self‑hosted agents on Kubernetes.

- Top-level docs

- `bootstrap-and-build.md` — Orchestrator to deploy infra, build images, and provision Azure DevOps (variable group, secure file, pipelines).
- `deploy-selfhosted-agents.md` — Helm deployment pipeline and guidance.
- `validate-selfhosted-agents.md` — Pipeline to validate agent registration and sample job runs.
- `run-on-selfhosted-pool-sample.md` — Minimal sample pipeline showing how to target the self‑hosted pool.
- `uninstall-selfhosted-agents.md` — Cleanup pipeline & steps to remove releases and secrets.
- `weekly-agent-pipeline.md` — Details for the scheduled weekly image rebuild & push pipeline.

Note: `validate-selfhosted-agents.md` and `deploy-selfhosted-agents.md` now support a `useOnPremAgents` boolean pipeline parameter to toggle whether CI jobs run on the repository's on‑prem pool (for example `UbuntuLatestPoolOnPrem`) or use the hosted `ubuntu-latest` pool. This parameter is separate from `useAzureLocal`, which controls where kubeconfig is sourced from.

Important: `useAzureLocal` and kubeconfig handling

- The deploy pipeline sets an explicit `USE_AZURE_LOCAL` environment variable and will pass `-UseAzureLocal` to the wrapper/script when `useAzureLocal` is true. This prevents accidentally inferring local mode from a `KUBECONFIG` value that may have been set by `az aks get-credentials` in non-local runs.
- The wrapper script `.azuredevops/scripts/run-deploy-selfhosted-agents-helm.ps1` honors the explicit `USE_AZURE_LOCAL` environment variable and only forwards `-UseAzureLocal` when the flag is truthy. The deploy helper script accepts `-Kubeconfig` and `-KubeconfigAzureLocal` and prefers the AzureLocal variant when local mode is requested.

Subfolders

- `self-hosted-agents/` — OS-specific setup and guidance (Windows/Linux). See the `setup/` pages for walkthroughs.

Notes & recent updates

- The repository includes `copilot-instructions.md` at the repo root with guidance for automated agents and contributors; follow its guidelines when editing scripts or pipelines.
- The weekly images pipeline now runs per-version Windows jobs (2019/2022/2025) to enable parallel builds and determinism. Each job writes a per-job manifest under `manifests/windows-<version>-digest.txt`.
- Temporary mock runners live in `.tmp/` to allow safe local dry-runs without network pushes. They are intended for developer convenience and should not be included in release PRs unless explicitly desired.

How to contribute updates to docs

Edit the relevant `docs/*.md` file, run a local spellcheck if desired, then open a PR describing the change and how you validated (mock run, pipeline run, or local smoke test).

Quick docs change checklist

- Make a small, focused branch and commit.
- Update the relevant `docs/*.md` file(s) and `README.md` where appropriate.
- Run a PowerShell parser check on any changed scripts:

    ```powershell
    pwsh -NoProfile -Command "[void]([System.Management.Automation.Language.Parser]::ParseFile('path\to\script.ps1',[ref]$null,[ref]$null)); Write-Host 'Syntax OK'"
    ```

- (Optional) Run the mock runners locally to validate tag formation and push targets:

    ```powershell
    pwsh -NoProfile -File .\.tmp\run-mock-linux-build.ps1
    pwsh -NoProfile -File .\.tmp\run-mock-windows-build.ps1
    ```

Push a draft PR and include what you ran to validate the change.

