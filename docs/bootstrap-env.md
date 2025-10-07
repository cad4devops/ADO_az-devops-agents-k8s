# Environment & PAT guidance for bootstrap-and-build.ps1

This page documents the environment variables and Azure DevOps PAT scopes commonly needed when running `bootstrap-and-build.ps1` and the provisioning helper `scripts/create-variablegroup-and-pipelines.ps1`.

Important environment variables

- `AZDO_PAT` — Preferred non-interactive PAT. When present the provisioning helper will use this value and will not prompt interactively.
- `ACR_ADO_USERNAME` / `ACR_ADO_PASSWORD` — Optional ACR credentials. If one is provided the other must also be provided.
- (Verification) After the orchestrator runs the ACR credential helper it expects to find `ACR_USERNAME` (non‑secret) and `ACR_PASSWORD` (secret) in the Azure DevOps variable group. Presence is validated automatically when `AZDO_PAT` is set. Secret values will appear as `null` when listed via CLI — this is expected; only the variable names are required for the pass condition.

Recommended PAT scopes

For the orchestrator to create/update variable groups, upload secure files, and create/update pipelines the PAT should include the following scopes (minimum):

- "Packaging (Read & write)" — if you need to push/pull packages (ACR pushes are done via Azure CLI + ACR auth separate from PAT, but this scope is sometimes required for registry interactions in pipelines).
- "Variable groups (Read, & Manage)" or "Variable Groups (Read, Write, Manage)" — required to create/update variable groups and mark variables as secret.
- "Build (Read & execute)" and "Pipelines (Read & execute)" — required to create/update pipelines and trigger runs if needed.
- "Secure files (Read & Manage)" — required to upload and manage secure files (kubeconfig) in the project.

Notes & least-privilege guidance

- The exact PAT scope names differ between Azure DevOps UI and REST/CLI terminology. When in doubt select the smaller-permission options that include "Read & manage" for the resources the script uses (variable groups, pipelines, secure files).
- For production, create a dedicated service user with a PAT scoped narrowly to the operations required by provisioning. Avoid using user-level PATs with broad organization-wide scopes.
- If your CI environment has an Azure DevOps service connection with sufficient permissions, you can skip providing `AZDO_PAT` to local runs and rely on the service connection for pipeline runs.

Troubleshooting permission errors

- If the helper prints permission errors while creating variable groups or uploading secure files, verify the PAT has `Secure files (manage)` and `Variable groups (manage)` permissions and that the PAT is valid (not expired).
- If pipeline create/update fails with unrecognized CLI args, it is often due to an incompatible `azure-devops` CLI extension version. The helper intentionally avoids brittle flags like `--repository-type` to be compatible across versions; if you still see failures, set `AZDO_PAT` and re-run to show raw CLI error output for diagnosis.

Example (export AZDO_PAT in pwsh)

```powershell
$env:AZDO_PAT = 'ghp_xxx-your-pat-here'
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -InstanceNumber 003 `
  -Location canadacentral `
  -ADOCollectionName <your-org-name> `
  -AzureDevOpsProject <your-project-name> `
  -AzureDevOpsRepo <your-repo-name> `
  -ContainerRegistryName <your-acr-shortname>
```

Security reminder

- Treat PAT values like secrets. When running interactively prefer reading the PAT from an environment variable or a secure file; avoid embedding the PAT in scripts or source control.

