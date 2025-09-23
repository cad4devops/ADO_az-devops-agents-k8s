# Weekly Agent Images Refresh Pipeline

This document describes the Azure DevOps pipeline defined in `.azuredevops/pipelines/weekly-agent-images-refresh.yaml` which performs a scheduled (weekly) rebuild & push of the Linux and Windows self‑hosted Azure DevOps agent images.

## Goals

- Ensure agent base images are rebuilt regularly to pick up OS & toolchain security patches.
- Maintain a consistent semantic version tag across all related images.
- Provide a deterministic fallback tag when semantic version resolution fails.
- Produce traceability artifacts (digests, tag inventory, optional SBOM placeholder).
- Fail early if required prerequisites (ACR permissions, versioning) are not met.

## Schedule

Cron: `0 2 * * 1` (Every Monday at 02:00 UTC) — defined under `schedules:` with `trigger: none` (no CI runs on push).

## High-Level Flow

1. Versioning job:
   - Tries to resolve SemVer via GitVersion (ContinuousDeployment mode).
   - Falls back to `yyyyMMdd-<shortSha>` when GitVersion is unavailable or invalid.
   - Optionally creates & pushes a git tag `v<Major.Minor.Patch>`.
   - Exposes outputs: `SEMVER_EFFECTIVE`, `SEMVER_MODE` (`GitVersion` or `Fallback`).
2. Preflight job:
   - Validates ACR existence & push/list permissions using the configured service connection.
3. LinuxAgentImage job (conditional):
   - Builds & pushes Linux agent image with the effective tag suffix.
   - Captures image digest for traceability.
4. WindowsAgentImages job (conditional):
   - Iterates the configured Windows base versions (2019/2022/2025) building & tagging images.
   - Captures per‑version image digests.
5. Summary job:
   - Lists recent repository tags (Linux + Windows) and prints collected digests.
   - Verifies the effective tag exists across the expected repositories.
   - Generates `tags.json` inventory and optional SBOM placeholder.
   - Publishes artifacts (manifests, sbom, tags, workspace dump).

## Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `skipLinux` | boolean | `false` | Skip building/pushing the Linux agent image. |
| `skipWindows` | boolean | `false` | Skip building/pushing Windows agent images. |
| `useGitVersion` | boolean | `true` | Attempt semantic version resolution using GitVersion. |
| `createGitTag` | boolean | `true` | Create & push an annotated git tag `v<semver>` when semantic versioning succeeds. |
| `generateSbom` | boolean | `true` | Generate SBOM placeholder artifact. |
| `failOnFallback` | boolean | `true` | Fail the pipeline if semantic versioning fails and fallback is used. |

### Parameter Interactions & Validation

- If both `skipLinux` and `skipWindows` are true the pipeline errors early (nothing to build).
- When `useGitVersion=false`, `failOnFallback` is effectively ignored (fallback becomes intentional).
- `createGitTag` only applies when `useGitVersion=true` and a valid SemVer is produced.

## Versioning Strategy

- GitVersion (ContinuousDeployment mode) produces Major.Minor.Patch. Pre-release/build metadata is stripped to ensure a clean `x.y.z` tag.
- Fallback: `yyyyMMdd-<short7sha>` ensures uniqueness & temporal ordering.
- Output Variable Names:
  - `SEMVER_EFFECTIVE` — actual tag suffix used.
  - `SEMVER_MODE` — `GitVersion` or `Fallback`.
  - `GIT_TAG_CREATED` (optional) — set to `true` if tag push succeeded.
- Failing on fallback is controlled by `failOnFallback` (default `true`).

## Security & Credentials

- Git tag push uses the system OAuth token (`SYSTEM_ACCESSTOKEN`) injected via ephemeral `git -c http.extraheader` to avoid persisting credentials.
- ACR access validated before builds (list + login + token retrieval). Prevents wasted compute on permission errors.
- PAT / secrets for agent runtime are handled separately (not part of this pipeline), typically via Kubernetes secrets / Helm values.

## Artifacts Produced

| Artifact Name | Contents |
|---------------|----------|
| `image-manifests` | Text files mapping `<repo>:<tag>=<digest>` for Linux & Windows variants. |
| `tags` | `tags.json` containing recent tag inventories per repository plus metadata. |
| `sbom` | Placeholder SBOM (`sbom.txt`) unless SBOM generation disabled. |
| `linux-build-context` | Source context directory (post build) for Linux image. |
| `windows-build-context` | Source context directory (post build) for Windows image. |
| `pipeline-workspace-dump` | Entire workspace snapshot (debugging aid). |

## tags.json Structure (Example)

```json
{
  "effectiveTagSuffix": "1.4.27",
  "generated": "2025-09-21T02:03:12.3456789Z",
  "mode": "GitVersion",
  "linux": { "repository": "linux-sh-agent-docker", "tags": ["1.4.27", "1.4.26", "20250914-a1b2c3d"] },
  "windows": {
    "windows-sh-agent-2019": ["1.4.27", "1.4.26"],
    "windows-sh-agent-2022": ["1.4.27"],
    "windows-sh-agent-2025": ["1.4.27"]
  }
}
```

## Adding Real SBOM Generation

Replace the placeholder step with a tool such as `syft`:

```yaml
- pwsh: |
    dotnet tool install --global syft --version *
    $env:PATH += ":$HOME/.dotnet/tools"
    syft $(ACR_NAME)/$(LINUX_REPOSITORY_NAME):$(EFFECTIVE_TAG_SUFFIX) -o json > $(Pipeline.Workspace)/sbom/linux-sbom.json
  displayName: Generate real SBOM (Syft)
```

(Repeat per image; consider parallelization or matrix for many variants.)

## Extending Windows Versions

Adjust variable `WINDOWS_VERSIONS` (comma-separated). The Summary & digest collection loops automatically adapt.

## Failure Modes & Diagnostics

| Stage | Typical Failure | Diagnostic Clue | Action |
|-------|-----------------|-----------------|--------|
| Versioning | GitVersion install/parse failure | Warning: "fallback"; pipeline may fail if `failOnFallback=true` | Inspect logs, confirm `GitVersion.yml`. |
| Preflight | ACR permission | Error: unable to list repos / obtain access token | Fix RBAC / service connection. |
| Build | Script failure in `01-build-and-push.ps1` | Non-zero exit; stderr logs | Fix Dockerfile or script; re-run. |
| Digest Capture | Tag not yet available | Digest warnings | Confirm push succeeded; race is rare. |
| Verification | Tag not found | `Tag <x> not found` error | Ensure build jobs ran & not skipped. |

## Local Dry Run (Manual Version Resolution)

You can test semantic versioning logic locally:

```powershell
pwsh ./infra/scripts/Get-SemanticVersion.ps1
```

Or approximate fallback:

```powershell
(Get-Date -Format 'yyyyMMdd') + '-' + (git rev-parse --short=7 HEAD)
```

## Operational Recommendations

- Keep `failOnFallback=true` to ensure visibility when semantic versioning fails unexpectedly.
- Periodically prune stale tags in ACR (lifecycle tasks) if retention is a concern.
- Add retention policy to artifacts if storage growth becomes significant.
- Consider adding a Markdown summary artifact (future enhancement) for human-readable diff in PRs or release notes.

## Future Enhancements (Backlog)

- Real SBOM (syft or trivy) + vulnerability summary.
- Retry logic (with exponential backoff) for transient `git push` / ACR operations.
- Markdown summary publishing (semantic mode, tag, digests table).
- Conditional tag creation only on schedule vs manual runs (check `Build.Reason`).
- Multi-arch (linux/arm64) build matrix.
- Automatic GitVersion configuration enforcement.

## Quick Reference (Key Output Variables)

| Variable | Source Job | Purpose |
|----------|------------|---------|
| `SetSemVer.SEMVER_EFFECTIVE` | Versioning | Effective tag suffix used for all images. |
| `SetSemVer.SEMVER_MODE` | Versioning | Indicates `GitVersion` or `Fallback`. |
| `PreflightVars.ACR_READY` | Preflight | Gates build jobs (must be `true`). |
| `GIT_TAG_CREATED` | Versioning | (Optional) Indicates git tag push success. |

## Support / Questions

Open an issue with logs from the failing stage and (optionally) redact sensitive values. Include the parameter set you used.

---

*Document generated to enhance maintainability & onboarding for the weekly agent refresh pipeline.*
