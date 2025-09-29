# Azure DevOps Self‑Hosted Agents on Kubernetes  

[![License](https://img.shields.io/github/license/devopsabcs-engineering/az-devops-agents-k8s?color=blue)](LICENSE)
[![Terraform](https://img.shields.io/badge/IaC-Bicep-blueviolet)](#infrastructure)
[![Helm](https://img.shields.io/badge/Deploy-Helm-orange)](#helm-chart)
[![KEDA](https://img.shields.io/badge/Autoscaling-KEDA-success)](#keda-autoscaling)

Run scalable, secure, cost‑efficient Azure DevOps (ADO) self‑hosted agents on any Kubernetes (AKS, on‑prem K8s, kind, AKS-HCI, etc.). This repository provides:  
* Production‑ready Docker images for Linux, Windows, and Docker‑in‑Docker (DinD) scenarios.  
* Helm charts to deploy and manage agent pools declaratively.  
* Optional KEDA auto‑scaling based on real ADO pipeline queue depth.  
* Infrastructure (Bicep) examples for container registry provisioning.  
* Scripts to simplify local builds, image pushes, and deployment automation.  

> Goal: Reduce pipeline queue times, standardize build environments, and only pay (in cluster capacity) for agents when they are needed.

---

## Table of Contents  
1. [Why Kubernetes for ADO Agents?](#why-kubernetes)  
2. [Architecture Overview](#architecture)  
3. [Repository Structure](#repository-structure)  
4. [Images & Variants](#images--variants)  
5. [Helm Chart](#helm-chart)  
6. [Configuration (values.yaml)](#configuration)  
7. [Secrets Management](#secrets)  
8. [KEDA Autoscaling](#keda-autoscaling)  
9. [Deployment Quick Start](#quick-start)  
10. [Advanced Deployment Scenarios](#advanced)  
11. [Security Considerations](#security)  
12. [Troubleshooting](#troubleshooting)  
13. [Roadmap](#roadmap)  
14. [Contributing](#contributing)  
15. [Maintainers](#maintainers)  
16. [Contact](#contact)  
17. [Weekly Pipeline](#weekly-pipeline)  
18. [Azure DevOps Pipelines](#azure-devops-pipelines)

---

## Why Kubernetes? <a id="why-kubernetes"></a>
Traditional VM‑based agents are:  
* Slow to scale (manual provisioning).  
* Hard to version and standardize.  
* Costly when idle.  

Kubernetes + containers give you:  
* Ephemeral, immutable build environments.  
* Horizontal scale responding to real demand (via KEDA).  
* Unified management (Helm + GitOps).  
* Support for mixed OS pools (Windows + Linux).  
* Customization: Add tooling in Dockerfiles per workload (e.g., Node, .NET, Java, Docker CLI, etc.).  

---

## Architecture Overview <a id="architecture"></a>
```
Azure DevOps            KEDA (optional)        Kubernetes Cluster
-------------           ---------------        ------------------
 Pipelines  ─────┐      Watch Queue Length --> ScaledObject (KEDA)
                 │                                │
  Requests Pool ─┴─>  Agent Deployment <──────────┘
                          (Linux / Windows / DinD pods)
                            |  Secret (AZP_URL, AZP_TOKEN, AZP_POOL)
                            |  Mounted Docker socket (optional)
                            |  Sysbox Runtime (DinD isolation)
```

Core building blocks:  
* `helm-charts/az-selfhosted-agents` – Primary deployment mechanism.  
* `dockerfiles/` & `azsh-*` folders – Image build scripts + start wrappers.  
* `keda/` – KEDA ScaledObject + TriggerAuthentication templates.  
* `infra/bicep` – Bicep sample for container registry creation.  

---

## Repository Structure <a id="repository-structure"></a>
```
azsh-linux-agent/        # Linux agent image + helper scripts
azsh-windows-agent/      # Windows agent image + helper scripts
dind/                    # Docker-in-Docker (Sysbox) variant
dockerfiles/             # Additional curated Dockerfiles (root/non-root)
helm-charts/             # v1 Helm chart (current)
helm-charts-v2/          # Helm Chart v2 — redesigned chart structure and deployment helpers (recommended)
infra/bicep/             # Bicep for ACR or infra prereqs
keda/                    # KEDA scaling manifests (Linux & Windows)
self-hosted-agents/      # Docs for OS specific setup
```

---

## Images & Variants <a id="images--variants"></a>
| Variant | Use Case | Notes |
|--------|----------|-------|
| Linux Standard | General builds (.NET, Node, Java, etc.) | Mounts host Docker socket by default. |
| Windows | MSBuild/Windows-based workloads | Requires Windows nodes in cluster. |
| DinD (Sysbox) | Container builds w/ isolation | Uses `sysbox-runc` runtime class, avoids privileged docker socket mount. |

All images start a standard Azure DevOps agent via startup script (`start.sh` / `start.ps1`). Customize Dockerfiles to add tools (e.g., `RUN apt-get install ...`).

---

## Helm Chart <a id="helm-chart"></a>
Chart (v1): `helm-charts/az-selfhosted-agents` — legacy layout

Chart (v2, recommended): `helm-charts-v2/` — consolidated v2 chart with per-OS subcharts, better values composition, and CI helpers. See `helm-charts-v2/README.md` for full details.

Key templates (v2 example):
- `linux-deploy.yaml`
- `windows-deploy.yaml`
- `dind-deploy.yaml`
- `secret.yaml`
- `keda-scaledobject.yaml` (rendered when autoscaling.keda.enabled=true)

Supports enabling each pool independently via values.


Quick v2 install (manual):
```bash
helm upgrade --install az-selfhosted-agents ./helm-charts-v2 -n az-devops-linux-003 --create-namespace -f values.secret.yaml
```

---

## Configuration (values.yaml) <a id="configuration"></a>
Excerpt of important fields:
```yaml
secret:
  name: azdevops
  data:               # Base64 encoded (Helm will substitute directly)
    AZP_POOL_VALUE: ...
    AZP_TOKEN_VALUE: ...
    AZP_URL_VALUE:   ...

linux:
  enabled: true
  deploy:
    name: azsh-linux-agent
    replicas: 1
    container:
      image: yourrepo/linux-agent:tag

windows:
  enabled: false

dind:
  enabled: false

autoscaling:
  enabled: false  # Separate from KEDA (this is standard HPA if wired)
```

Environment variables inside pods (resolved from Secret):  
* `AZP_URL` – Organization URL e.g. `https://dev.azure.com/yourorg`  
* `AZP_TOKEN` – PAT (Agent Pools (Read, Manage) + maybe Build scope).  
* `AZP_POOL` – Name of the agent pool to register into.  

> NOTE: Values file stores base64 strings (e.g., produced with `echo -n "value" | base64`). Do NOT commit raw secrets.

---

## Secrets Management <a id="secrets"></a>
Helm template `secret.yaml` materializes the Kubernetes Secret:  
```yaml
data:
  AZP_POOL: <base64 pool>
  AZP_TOKEN: <base64 token>
  AZP_URL: <base64 url>
```
Recommendations:  
* Prefer external secret management (e.g., Azure Key Vault + CSI driver) for production.  
* Use a separate PAT with least privilege. Rotate regularly.  
* Avoid committing populated `values.yaml`; instead create `values.secret.yaml` locally and use `--values`.  

---

## KEDA Autoscaling <a id="keda-autoscaling"></a>
KEDA watches Azure DevOps queue length and scales the target Deployment. Example (`keda/linux/azure-pipelines-scaledobject.yaml`):  
```yaml
spec:
  scaleTargetRef:
    name: azsh-linux
  minReplicaCount: 1
  maxReplicaCount: 5
  triggers:
  - type: azure-pipelines
    metadata:
      poolID: "12"
      organizationURLFromEnv: AZP_URL
```
Steps:  
1. Install KEDA (`keda/linux/01-Install-Keda.ps1` or Helm).  
2. Apply `TriggerAuthentication` + `ScaledObject`.  
3. Ensure your secret exposes token & URL as expected.  

> Pool ID can be retrieved via Azure DevOps REST API or UI (Agent Pools).  

---

## Deployment Quick Start <a id="quick-start"></a>
Prereqs:  
* Kubernetes cluster (Linux nodes; add Windows nodes for Windows pool).  
* kubectl + Helm installed.  
* Container registry (ACR, Docker Hub, etc.).  
* PAT created in Azure DevOps with required scopes.  

### 1. Build & Push Image (example Linux)
```
cd azsh-linux-agent
pwsh ./01-build-and-push.ps1 -ImageTag 2025-09-20 -Registry yourrepo
```

```powershell
```

### 2. Prepare values file
```
cp helm-charts/az-selfhosted-agents/values.yaml my-values.yaml
# Edit: enable linux.enabled=true, set image, replicas, supply base64 secrets
```

```bash
```

---

## Local helper & pipeline notes

Small repository helpers and pipelines provide a few convenience and safety behaviors you should know about when running locally or from CI:

* kubeconfig defaulting: the deploy/validate helpers default to `$env:KUBECONFIG` or the standard user kubeconfig (`~/.kube/config`) when a `-Kubeconfig` parameter is not supplied. This makes it easier to run the helpers locally without repeating the kubeconfig path.
* Azure DevOps PAT fallback: where an Azure DevOps PAT parameter is accepted by a helper, the helpers will fall back to the `AZDO_PAT` environment variable if the parameter is not provided. This is a convenience for local runs but prefer explicit pipeline secrets in CI.
* ACR credentials: if you provide container registry credentials via the environment variables `ACR_ADO_USERNAME` / `ACR_ADO_PASSWORD`, both must be supplied. The helpers will fail fast on partial credentials to avoid confusing authentication or image-push failures.
* Wrapper script: to avoid PowerShell parser/tokenization fragility for complex CLI strings, use the provided wrapper script which spawns a child `pwsh` to execute the deploy helper. See `.azuredevops/scripts/run-deploy-selfhosted-agents-helm.ps1` for the wrapper usage.
* Helm debug capture & masking: when helpers run Helm with `--debug` they capture full debug output to a temporary log. Before publishing the log as an artifact the helpers mask/redact common secret keys and values (for example PATs, `AZP_TOKEN`, docker registry passwords, and common secret key names like `personalAccessToken`, `password`, `pw`, `token`). This masked debug log can be published for diagnostics without leaking secrets.
* Validation pipeline parameters: the validation pipeline exposes OS-specific wait-time parameters so the sample pipeline can tune timeouts:
  * `linuxHelloWaitSeconds` (default: 120)
  * `windowsHelloWaitSeconds` (default: 180)
  The validate pipeline forwards these as literal numeric parameters into the sample pipeline to avoid shell interpolation issues.

These notes are a short summary — see the `docs/` folder for complete guidance and the pipeline YAMLs under `.azuredevops/pipelines/` for exact parameter names and behavior.

### 3. Install Chart
```
helm upgrade --install az-agents ./helm-charts/az-selfhosted-agents -n az-devops --create-namespace -f my-values.yaml
```

```bash
```

### 4. Verify
```
kubectl get pods -n az-devops
kubectl logs <pod> -n az-devops
```

### 5. (Optional) Enable KEDA
```
kubectl apply -f keda/linux/trigger-auth.yaml
kubectl apply -f keda/linux/azure-pipelines-scaledobject.yaml
```

---

## Advanced Scenarios <a id="advanced"></a>
| Scenario | Approach |
|----------|----------|
| Separate pools per team | Deploy multiple releases with different `AZP_POOL` secrets. |
| GPU builds | Extend Dockerfile adding CUDA + request GPU resources in values. |
| Private dependencies | Add `imagePullSecrets` in values. |
| Rootless builds | Use non-root Dockerfiles in `dockerfiles/dind/nonroot/`. |
| Isolated Docker builds | Use DinD + Sysbox runtime class. |
| GitOps | Manage values via ArgoCD / Flux referencing this chart. |

---

## Security Considerations <a id="security"></a>
* PAT leakage risk: keep secrets external; restrict scopes.  
* Windows + Linux node isolation: use nodeSelectors / taints.  
* Docker socket mount (Linux & Windows) grants host build control – consider DinD+Sysbox alternative.  
* Regularly patch base images (rebuild frequently).  
* Use network policies if cluster supports them.  
* Enable audit logging for secret access.  

---

## Troubleshooting <a id="troubleshooting"></a>
| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod CrashLoopBackOff | Wrong PAT / URL / pool | Check logs: `AZP URL/TOKEN invalid`. Regenerate PAT, verify base64. |
| Agent stays offline in ADO | Network egress blocked | Ensure outbound https to dev.azure.com allowed. |
| KEDA not scaling | Missing TriggerAuthentication or wrong poolID | Validate CRDs, run `kubectl describe scaledobject`. |
| Windows deploy pending | No matching Windows nodes | Add Windows nodepool & tolerations if required. |
| DinD build fails | RuntimeClass not found | Install Sysbox (`dind/02-Install-SysBox.ps1`). |

Pod log snippet (successful registration):
```
1. Determining matching Azure Pipelines agent...
2. Downloading agent...
Listening for Jobs
```

---

## Roadmap <a id="roadmap"></a>
Planned improvements:  
* Helm Chart v2 consolidation.  
* Azure Key Vault CSI integration examples.  
* Automatic pool creation script.  
* Metrics dashboard (Grafana) for queue vs replicas.  
* Optional ephemeral runner cleanup job.  

---

## Contributing <a id="contributing"></a>
1. Fork & branch (`feature/<topic>`).  
2. Make changes + add/update docs.  
3. Test deploying locally.  
4. Submit PR describing change & rationale.  

Please open issues for bugs, feature requests, or clarifications.

---

## Weekly Pipeline <a id="weekly-pipeline"></a>
Automated weekly rebuild & tagging of Linux and Windows self-hosted agent images is performed by an Azure DevOps pipeline (`.azuredevops/pipelines/weekly-agent-images-refresh.yaml`).

Highlights:
- Scheduled (cron) only – no CI trigger noise.
- Semantic version tagging (GitVersion) with deterministic fallback (date+shortSha).
- Optional git tag creation (`v<semver>`), digest capture, tag inventory artifact (`tags.json`).
- Guard rails: ACR permission preflight, skip parameter validation, fail-on-fallback option.

Full documentation: see `docs/weekly-agent-pipeline.md`.

---

## Azure DevOps Pipelines <a id="azure-devops-pipelines"></a>

This repository includes several key Azure DevOps pipeline YAML files used to deploy, validate, and manage self‑hosted agent pools. Below are the primary pipelines and links to additional documentation in the `docs/` folder.

- Deploy self‑hosted agents: `.azuredevops/pipelines/deploy-selfhosted-agents.yml`
  - Docs: `docs/deploy-selfhosted-agents.md` — Helm deployment of agent pools, secrets management, and optional KEDA wiring.
- Validate self‑hosted agents: `.azuredevops/pipelines/validate-selfhosted-agents.yml`
  - Docs: `docs/validate-selfhosted-agents.md` — Verifies agent registration and can queue the sample job to validate execution.
  - Note (recent change): the Helm validate pipeline used by the `deploy-selfhosted-agents-helm` flow has been reworked into a 3-stage layout to make pool-name computation deterministic and robust against Azure DevOps runtime-evaluation timing issues. The stages are:
    1. LoadConfig — downloads the `agent-config` artifact and runs a `ParseConfig` task that computes and emits job outputs (instanceNumber, deployLinux, deployWindows, azureDevOpsOrgUrl, useAzureLocal, poolNameLinux, poolNameWindows).
    2. Validate — two parallel jobs (Linux and Windows). Each job downloads the same artifact and runs a short `CheckShouldRun` step that reads `config.json` and sets job-local variables (shouldRun, poolName, instanceNumber, etc.). The Poll and TriggerSample steps in the job are gated on `shouldRun` so they only execute when the config requests it. This avoids fragile cross-stage condition evaluation while keeping the computed pool names visible to the jobs.
    3. Summary — collects trigger results (when present) and emits a small validation summary attachment.

    Why this change: Azure DevOps can evaluate job-level conditions before task outputs are available which can cause expressions that reference cross-stage outputs to resolve to Null. Computing pool names in `ParseConfig` (LoadConfig) and doing a short runtime check inside each Validate job (CheckShouldRun) gives deterministic, observable behavior and clearer logs.

    Verification tips: run the pipeline and inspect the LoadConfig -> ParseConfig log for "Exported ..." lines (the ParseConfig task prints the values it emits). Then inspect each Validate job's `Check if ... validation should run` log — it will show whether the job will proceed and the job-local `poolName` used by the Poll step.
- Run-on self‑hosted pool sample: `.azuredevops/pipelines/run-on-selfhosted-pool-sample.yml`
  - Docs: `docs/run-on-selfhosted-pool-sample.md` — Minimal sample pipeline to exercise agents.
- Uninstall self‑hosted agents: `.azuredevops/pipelines/uninstall-selfhosted-agents.yml`
  - Docs: `docs/uninstall-selfhosted-agents.md` — Cleanup pipeline for helm releases, secrets, and optional registry cleanup.
- Weekly agent images refresh: `.azuredevops/pipelines/weekly-agent-images-refresh.yaml`
  - Docs: `docs/weekly-agent-pipeline.md` — Scheduled weekly rebuild/push plus digest capture and artifacts.

---



## Docs index

Comprehensive docs live in the `docs/` folder. Start at `docs/README.md` for a brief index and pointers.

## Copilot / automation guidance

If you're an automated agent or contributor editing scripts or pipeline YAML, read `copilot-instructions.md` at the repository root before making changes. It contains runbooks, safe mock-run helpers, known pitfalls (PowerShell interpolation and ACR tagging), and pipeline authoring tips.

## Maintainers

| Maintainer | Profile |
|------------|---------|
| Anvesh Muppeda | [profile](https://anveshmuppeda.github.io/profile/) |

---

## Contact

* Email: <muppedaanvesh@gmail.com>
* LinkedIn: [Anvesh](https://www.linkedin.com/in/anvesh-muppeda-5a0a83167)
* Issues: [GitHub Tracker](https://github.com/devopsabcs-engineering/az-devops-agents-k8s/issues)

---

## Feedback

We welcome your feedback. Open an issue or discussion and help shape future enhancements.

Back to top: see the top of this README


