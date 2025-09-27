# Uninstall Self‑Hosted Agents Pipeline

Location: `.azuredevops/pipelines/uninstall-selfhosted-agents.yml`

Purpose

- Removes Helm releases / Kubernetes resources associated with the self‑hosted agent pools and cleans up related secrets and KEDA objects.

When to run

- Run when decommissioning clusters or removing agent pools from a cluster.

How it works

1. Optionally scale down or cordon nodes to drain workloads.
2. Uninstall Helm release(s) or apply `kubectl delete` operations for the chart's resources.
3. Remove secrets if requested.
4. Optionally remove ACR images (careful: this is destructive and should be gated).

Safety notes

- This pipeline may perform destructive actions. Ensure approvals and gated permissions are in place for production use.
- Take backups of any configuration or secrets you want to preserve before running the uninstall pipeline.

Credentials and safety behaviors

- Azure DevOps credentials: the uninstall helper prefers an explicit Azure DevOps PAT parameter but will fall back to the `AZDO_PAT` environment variable when a parameter is not supplied. If pool removal is requested and no PAT (parameter or `AZDO_PAT`) is present, the pipeline skips pool removal to avoid accidental destructive actions.
- ACR / registry cleanup: any steps that remove images or registries are destructive and should be gated with approvals. The helper expects both `ACR_ADO_USERNAME` and `ACR_ADO_PASSWORD` to be supplied when registry operations are required; it will fail early on partial credentials to avoid ambiguous failures.

- Note: the helpers capture Helm `--debug` output to a temporary file when enabled; any published debug artifact is masked to remove likely secret keys/values (PATs, `AZP_TOKEN`, docker auth/password fields) before publishing.

Wrapper and output handling

- When running locally, prefer the repository wrapper script that spawns a child `pwsh` process to execute the uninstall helper. This reduces argument-parsing fragility and avoids accidental token leakage in the local shell.
- If the helper captures Helm debug output for debugging, any published artifact is masked to remove likely secrets (PATs, docker auth/password fields, `AZP_TOKEN`, and commonly used secret key names) before publishing.

Troubleshooting

- If resources remain, run `kubectl get all -n <namespace>` and inspect finalizers blocking deletion.
- Check Helm release history `helm history <release> -n <namespace>` for clues.
