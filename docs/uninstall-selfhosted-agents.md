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

Troubleshooting

- If resources remain, run `kubectl get all -n <namespace>` and inspect finalizers blocking deletion.
- Check Helm release history `helm history <release> -n <namespace>` for clues.
