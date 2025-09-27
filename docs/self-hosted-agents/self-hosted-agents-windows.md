
# Windows self-hosted agents (Kubernetes)

Windows pools require Windows nodes in your Kubernetes cluster. For production workloads we recommend running Windows agents via the Helm chart in `helm-charts-v2` and managing secrets/values via `values.secret.yaml` or an external secret store.

Key notes

- Ensure your cluster contains Windows node pools and that the chart values request the Windows subchart (`windows.enabled: true`).
- Use `values.secret.yaml` to supply `AZP_URL`, `AZP_TOKEN`, and `AZP_POOL` (base64-encoded).

Wrapper & deployment

- Use the same deploy helper wrapper described in `docs/deploy-selfhosted-agents.md` to install the Windows pool via Helm. The helper performs preflight checks and can optionally create pools in Azure DevOps for you.

- The helper will accept `AZDO_PAT` from the environment as a fallback for interactive/local runs. If you supply registry credentials via `ACR_ADO_USERNAME` / `ACR_ADO_PASSWORD` ensure both are present. If Helm `--debug` is enabled the helper captures and masks debug logs before publishing.

Validation

- The validate pipeline forwards `windowsHelloWaitSeconds` (default 180) to the sample pipeline so the Windows stream can wait longer for containers or Windows-specific readiness.

Appendix: manual Windows agent (legacy)

If you need to register a single Windows VM agent manually:

```powershell
mkdir agent; cd agent
# download agent zip from Microsoft
[System.IO.Compression.ZipFile]::ExtractToDirectory("$HOME\Downloads\vsts-agent-win-x64-3.234.0.zip", "$PWD")
.\config.cmd
.\run.cmd  # to run interactively

# to install as a service use the svc installer included with the agent package
# .\svc.sh install
```


