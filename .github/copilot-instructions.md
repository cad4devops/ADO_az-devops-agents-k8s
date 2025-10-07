## Copilot / Automation Instructions for this repository

Purpose
--------
This file documents the repository layout, developer/automation workflows, and the expectations for automated coding agents (Copilot-style) and humans working on changes to the image build and CI pipeline. It is intentionally concise and focused on the things an automated agent or reviewer needs to know to safely make, test and validate changes.

Quick links
-----------
- Pipeline: `.azuredevops/pipelines/weekly-agent-images-refresh.yml`
- Linux build script: `azsh-linux-agent/01-build-and-push.ps1`
- Windows build script: `azsh-windows-agent/01-build-and-push.ps1`
- Windows Dockerfiles: `azsh-windows-agent/Dockerfile.windows-sh-agent-*-windows*`
- Linux Dockerfile: `azsh-linux-agent/Dockerfile.linux-sh-agent-docker`

Goals and scope for Copilot
---------------------------
- Make focused, minimal edits that preserve existing behaviour unless the change explicitly intends to modify it.
- When changing scripts or pipeline YAML, run lightweight local checks (PowerShell parser, mock runs) so PRs don't introduce trivial parse/runtime errors.
- Prefer explicit and deterministic behavior in CI: pass script arguments from pipeline tasks rather than relying on implicit environment-variable precedence.

Local prerequisites for testing
-------------------------------
- Docker (Windows: Docker Desktop configured for Windows containers if testing Windows images)
- PowerShell 7 (pwsh)
- Azure CLI (az) if you plan to run `az acr login` or query ACR; for local mock tests it's not required

How the build scripts are expected to be invoked
-----------------------------------------------
- Linux builds (CI or local):
  - Script: `azsh-linux-agent/01-build-and-push.ps1`
  - Accepts env vars: `ACR_NAME`, `LINUX_REPOSITORY_NAME`, `TAG_SUFFIX`/`SEMVER_EFFECTIVE`

- Windows builds (CI or local):
  - Script: `azsh-windows-agent/01-build-and-push.ps1`
  - Preferred invocation in CI: pass the Windows version explicitly as an argument:
    - `-WindowsVersions <version>`
  - Fallback: `WINDOWS_VERSIONS` (CSV) or `WIN_VERSION` environment variables will be respected only when no `-WindowsVersions` parameter was provided.

Mocked local runs (safe, no network pushes)
-------------------------------------------
Two temporary helpers were added during development to safely simulate runs without network access or credentials. They live in `.tmp/` and are safe to run locally. They should not be committed to a PR unless explicitly intended.

- `.tmp/run-mock-linux-build.ps1` — defines mock `docker` and `az` functions and runs the linux script to verify tag construction and push targets.
- `.tmp/run-mock-windows-build.ps1` — same for the windows script.

Run a mock Linux script locally (example):
```powershell
# from repository root
pwsh -NoProfile -File .\.tmp\run-mock-linux-build.ps1
```

Run a mock Windows script locally (example):
```powershell
pwsh -NoProfile -File .\.tmp\run-mock-windows-build.ps1
```

Key environment variables and parameters
----------------------------------------
- `ACR_NAME` — the ACR name or FQDN (e.g. `cragents003c66i4n7btfksg` or `cragents003c66i4n7btfksg.azurecr.io`). Scripts will append `.azurecr.io` if the name looks unqualified.
- `AZURE_SERVICE_CONNECTION` — Azure DevOps service connection used by `AzureCLI` tasks.
- `TAG_SUFFIX` / `SEMVER_EFFECTIVE` — tag suffix used for created image tags (from GitVersion or fallback date+sha).
- `WINDOWS_VERSIONS` or `WIN_VERSION` — single value or CSV of Windows versions; prefer `-WindowsVersions` script arg when invoking the script from CI tasks.

Known issues and how they were addressed
----------------------------------------
- Mis-tagging to Docker Hub: previously, unqualified registry names caused docker to push to Docker Hub (docker.io). Fix: scripts now normalize unqualified `ACR_NAME` by appending `.azurecr.io`.
- PowerShell parser errors with ${var}: constructs: double-quoted strings containing `${name}:...` can cause parser errors on Windows agents. Fix: use `-f` formatting or avoid embedding colon after ${...} in double-quotes.
- Push authentication failures ("unauthorized: access token has insufficient scopes"): typically means the pipeline service principal lacks `AcrPush` role on the ACR. Fix: grant `AcrPush` to the service principal used by the Azure DevOps service connection.
- PublishBuildArtifacts error: Not found PathtoPublish when manifests were absent. Fix: Summary job sets `HAS_MANIFESTS` as a lowercase `'true'`/`'false'` string and Publish manifests runs only when `HAS_MANIFESTS == 'true'`.
- KEDA ScaledObject failure ("error parsing azure Pipelines metadata: no poolName or poolID given"): Helm chart templates now conditionally render KEDA ScaledObjects only when valid poolID values are present (not empty, not placeholder "x"/"y"). The deploy script attempts to resolve pool IDs from Azure DevOps API when AZDO_PAT is available; if resolution fails or credentials are absent, KEDA autoscaling is gracefully disabled and agents run with fixed replica count.
- Agent pool creation 409 Conflict: When creating project-scoped pools, the script may encounter "Agent pool X already exists" if the pool exists at organization level. Fix: deploy script now catches 409 errors, queries the existing pool to get its ID, and re-checks if the project queue already exists before attempting to create it.

Pipeline notes
--------------
- File: `.azuredevops/pipelines/weekly-agent-images-refresh.yml`
  - Scheduled weekly rebuild of Linux and Windows agent images.
  - Versioning job uses GitVersion (or fallback) to produce `SEMVER_EFFECTIVE`.
  - Preflight job validates ACR and detects a working ACR manifest list command; it deliberately does not fail on non-critical probe exits.
  - Windows builds are split into per-version jobs (`WindowsAgentImage_2019`, `..._2022`, `..._2025`) and each job passes `-WindowsVersions $(WIN_VERSION)` to the script so each job builds only its target.
  - Digest capture writes per-job files into `$(Pipeline.Workspace)/manifests/windows-<version>-digest.txt` and those artifacts are published by the `Summary` job.

When making changes to the pipeline
----------------------------------
1. Keep changes minimal and well-scoped. If you add a new Windows version, add a matching Dockerfile under `azsh-windows-agent/` named `Dockerfile.windows-sh-agent-<version>-windows<ltsc>` and add a job (or extend the matrix).
2. Prefer passing `-WindowsVersions` as an argument from the AzureCLI task inputs (the pipeline has examples).
3. Run a local PowerShell parser check for any changed scripts before pushing:
```powershell
pwsh -NoProfile -Command "[void]([System.Management.Automation.Language.Parser]::ParseFile('path\to\script.ps1',[ref]$null,[ref]$null)); Write-Host 'Syntax OK'"
```

Troubleshooting checklist (CI failures)
--------------------------------------
- If docker push goes to docker.io -> verify `ACR_NAME` normalization; ensure tags are prefixed with the ACR FQDN.
- If pushes fail with insufficient scopes -> check service principal permissions; assign `AcrPush` to service principal for the ACR resource.
- If PublishBuildArtifacts fails with Not found PathtoPublish -> inspect `HAS_MANIFESTS` variable (Summary job) and ensure the Publish step is gated on it; the pipeline already sets it to `'true'`/`'false'.`
- If PowerShell parser errors reference `${var}:` -> convert the message/interpolation to use `-f` formatting or `${var}` braced names prior to colon.
- If KEDA ScaledObject fails with "no poolName or poolID given" -> The deploy script now fails early if AZDO_PAT is not set or pool IDs cannot be resolved. Ensure AZDO_PAT is set when running deploy-selfhosted-agents-helm.ps1 so the script can query Azure DevOps API to resolve pool IDs; verify the agent pools exist in Azure DevOps before running the deployment; check the script output for masked PAT debug info. ScaledObjects are now conditional and will be skipped when poolID is invalid (though the script will fail before rendering if pools cannot be resolved).
- If agent pool creation fails with 409 "Agent pool X already exists" -> The pool likely exists at organization level but the script is trying to create a project-scoped version. The deploy script now handles this by catching the 409 error, querying to get the existing pool ID, and checking if a project queue needs to be created to link the pool to the project.

Testing & CI hygiene
---------------------
- Prefer small, focused commits and include a short test plan in the PR description (how to run the mock runner or which pipeline to run).
- Add or update unit/smoke tests only when changing behavior that affects callers; for build/publish scripts prefer deterministic mock runs as shown above.

Conventions for automated agents
--------------------------------
- When editing files, create the smallest change set required to achieve the goal.
- Add an explanatory comment or note in the PR for non-obvious changes (authentication/role requirements, side effects on CI).
- If adding new files (Dockerfiles, scripts), ensure their names follow the `windows-sh-agent-<version>` pattern used elsewhere.

Cleanup
-------
- The `.tmp/` mock runners are development helpers. Remove them before finalizing a release PR if you don't want them in the main tree. They are safe to keep for developer convenience but should not be treated as production artifacts.

Contact / context
-----------------
If you need context on past edits, check recent commits that updated the pipeline and `azsh-*-agent/01-build-and-push.ps1` scripts — those contain the rationale for registry normalization, push resilience, and Windows-version handling.

-- End
