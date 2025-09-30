<#
.azuredevops/scripts/bootstrap-and-build.ps1

Orchestrator script to:
 1) Deploy infra (calls infra/bicep/deploy.ps1)
 2) Extract useful outputs (instance number, ACR name, AKS name, AKS RG)
 3) Build & push linux and windows images (calls azsh-*/01-build-and-push.ps1)
 4) Render pipeline templates from .template.yml files by replacing tokens

This script is intended to be run from a CI job or locally where Azure CLI,
Docker (for builds), and pwsh are available.

Usage examples:
  pwsh .\.azuredevops\scripts\bootstrap-and-build.ps1 -InstanceNumber 003 -Location canadacentral

Notes:
- The deploy step will attempt to create or update resources in the specified resource group.
- The build steps will attempt to login to the created ACR and push images; ensure Docker and build hosts are available.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstanceNumber,
    [Parameter(Mandatory = $true)][string]$Location,
    [Parameter(Mandatory = $false)][string]$ResourceGroupName,
    [Parameter(Mandatory = $false)][string]$ContainerRegistryName,
    [Parameter(Mandatory = $false)][switch]$EnableWindows,
    [Parameter(Mandatory = $false)][int]$WindowsNodeCount = 1,
    [Parameter(Mandatory = $false)][int]$LinuxNodeCount = 1,
    [Parameter(Mandatory = $false)][string]$AzureDevOpsOrgUrl = 'https://dev.azure.com/cad4devops',
    [Parameter(Mandatory = $false)][string]$AzureDevOpsProject = 'Cad4DevOps',
    [Parameter(Mandatory = $false)][string]$AzureDevOpsRepo = 'ADO_az-devops-agents-k8s',
    [Parameter(Mandatory = $false)][string]$BootstrapPoolName = 'KubernetesPoolWindows',
    [Parameter(Mandatory = $false)][string]$KubeconfigAzureLocalPath = 'my-workload-cluster-dev-014-kubeconfig.yaml',
    [Parameter(Mandatory = $false)][string]$KubeContextAzureLocal = 'my-workload-cluster-dev-014-admin@my-workload-cluster-dev-014',
    [Parameter(Mandatory = $false)][string]$KubeConfigFilePath = "C:\Users\emmanuel.DEVOPSABCS.000\.kube\my-workload-cluster-dev-014-kubeconfig.yaml",
    [Parameter(Mandatory = $false)][string]$AzureDevOpsServiceConnectionName = 'DOS_DevOpsShield_Prod',
    [Parameter(Mandatory = $false)][string]$AzureDevOpsVariableGroup = 'ADO_az-devops-agents-k8s',
    [Parameter(Mandatory = $false)][string]$AzureDevOpsPatTokenEnvironmentVariableName = "AZDO_PAT",
    [Parameter(Mandatory = $false)][string]$InstallPipelineName = "GEN_az-devops-agents-k8s-deploy-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$UninstallPipelineName = "GEN_az-devops-agents-k8s-uninstall-selfhosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ValidatePipelineName = "GEN_az-devops-agents-k8s-validate-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ImageRefreshPipelineName = "GEN_az-devops-agents-k8s-weekly-image-refresh",
    [Parameter(Mandatory = $false)][string]$RunOnPoolSamplePipelineName = "GEN_az-devops-agents-k8s-run-on-selfhosted-pool-sample-helm",
    [Parameter(Mandatory = $false)][string]$KubeConfigSecretFile = "AKS_my-workload-cluster-dev-014-kubeconfig_file"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) { Write-Error $msg; exit 1 }

function Write-Green([string]$msg) { try { if ($IsWindows) { Write-Host -ForegroundColor Green $msg } else { Write-Host "`e[32m$msg`e[0m" } } catch { Write-Host $msg } }

# Switch Docker Desktop engine between linux and windows on Windows hosts when available
function Switch-DockerEngine([ValidateSet('linux', 'windows')][string]$target, [int]$timeoutSeconds = 60) {
    if (-not $IsWindows) { Write-Host "Not on Windows host; skipping Docker engine switch to '$target'"; return }
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) { Write-Warning "docker CLI not found; cannot check engine. Skipping switch."; return }

    # Path to Docker Desktop CLI helper
    $possible = @(((Join-Path $Env:ProgramFiles 'Docker\Docker\DockerCli.exe'), (Join-Path $Env:ProgramFiles 'Docker\DockerCli.exe')) | Where-Object { Test-Path $_ })

    if ($possible.Count -gt 0) {
        $dockerCli = $possible[0]
        if ($target -eq 'linux') { $arg = '-SwitchLinuxEngine' } else { $arg = '-SwitchWindowsEngine' }
        Write-Host "Attempting to switch Docker Desktop engine to '$target' using $dockerCli $arg"
        try {
            & "$dockerCli" $arg 2>$null | Out-Null
        }
        catch { Write-Warning "Failed to invoke DockerCli.exe: $($_.Exception.Message)" }
        # Poll docker info for OSType
        $deadline = (Get-Date).AddSeconds($timeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            try {
                $ostype = (& docker info --format '{{.OSType}}' 2>$null).Trim()
                if ($ostype -eq $target) { Write-Host "Docker engine now reports OSType='$ostype'"; return }
            }
            catch {
                # ignore transient errors while Docker restarts
            }
        }
        Write-Warning "Timed out waiting for Docker engine to report OSType='$target'"
    }
    else {
        Write-Warning "Docker Desktop CLI (DockerCli.exe) not found under Program Files; attempting to set DOCKER_DEFAULT_PLATFORM for the upcoming build as a fallback."
    }
}

# Resolve script and repo roots
$scriptPath = $MyInvocation.MyCommand.Path
$scriptRoot = Split-Path -Parent $scriptPath
$repoRoot = Resolve-Path (Join-Path $scriptRoot '.')

Write-Host "Script root: $scriptRoot"
Write-Host "Repo root  : $repoRoot"

# Default ResourceGroupName if not provided
if (-not $ResourceGroupName -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = "rg-aks-ado-agents-$InstanceNumber"
    Write-Host "No ResourceGroupName provided. Defaulting to: $ResourceGroupName"
}

# Deploy infra by invoking the bicep deploy helper
$deployScript = Join-Path $repoRoot 'infra\bicep\deploy.ps1'
if (-not (Test-Path $deployScript)) { Fail "Deploy script not found at $deployScript" }

Write-Host "Invoking infra deploy: $deployScript"

$deployArgs = @(
    '-InstanceNumber', $InstanceNumber,
    '-Location', $Location,
    '-ResourceGroupName', $ResourceGroupName,
    '-WindowsNodeCount', [string]$WindowsNodeCount,
    '-LinuxNodeCount', [string]$LinuxNodeCount
)
if ($EnableWindows.IsPresent) { $deployArgs += '-EnableWindows'; $deployArgs += $true }
if ($ContainerRegistryName) { $deployArgs += '-ContainerRegistryName'; $deployArgs += $ContainerRegistryName }

# Capture output (stdout + stderr) for parsing
Write-Host "Running deploy.ps1 with: $($deployArgs -join ' ')"
$rawOut = & pwsh -NoProfile -NonInteractive -File $deployScript @deployArgs 2>&1
if ($LASTEXITCODE -ne 0) { Write-Warning "deploy.ps1 exited with code $LASTEXITCODE; output may contain partial information." }

# Attempt to extract the JSON that the deploy script prints after 'Deployment outputs:'
$joined = $rawOut -join "`n"
$deployOutputs = $null
try {
    $m = [regex]::Match($joined, 'Deployment outputs:\s*(\{.*\})', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) {
        $jsonText = $m.Groups[1].Value
        $deployOutputs = $jsonText | ConvertFrom-Json -ErrorAction Stop
        Write-Host "Parsed deployment outputs from deploy.ps1"
    }
    else {
        Write-Host "No explicit 'Deployment outputs:' JSON block found in deploy.ps1 output. Falling back to discovery."
    }
}
catch {
    Write-Warning "Failed to parse deployment outputs JSON: $($_.Exception.Message)"; $deployOutputs = $null
}

# Determine ACR name
$acrName = $null
if ($ContainerRegistryName -and -not [string]::IsNullOrWhiteSpace($ContainerRegistryName)) {
    $acrName = $ContainerRegistryName
    Write-Host "Using ContainerRegistryName parameter: $acrName"
}
elseif ($deployOutputs -and $deployOutputs.containerRegistryName -and $deployOutputs.containerRegistryName.value) {
    $acrName = $deployOutputs.containerRegistryName.value
    Write-Host "Found containerRegistryName in deploy outputs: $acrName"
}

if (-not $acrName) {
    Write-Host "Attempting to discover ACRs in resource group $ResourceGroupName"
    $acrListJson = az acr list -g $ResourceGroupName --query "[].name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $acrListJson) {
        $acrCandidates = @($acrListJson -split "\n" | Where-Object { $_ -ne '' })
        if ($acrCandidates.Count -eq 1) { $acrName = $acrCandidates[0]; Write-Host "Discovered single ACR in RG: $acrName" }
        elseif ($acrCandidates.Count -gt 1) { $acrName = $acrCandidates[0]; Write-Warning "Multiple ACRs found in RG; picking first: $acrName" }
    }
}

if (-not $acrName) { Fail "Unable to determine container registry name. Provide -ContainerRegistryName or ensure deploy produces an output 'containerRegistryName'." }

# Normalize ACR values
if ($acrName -match '\.') { $acrFqdn = $acrName; $acrShort = $acrName.Split('.')[0] } else { $acrShort = $acrName; $acrFqdn = "$acrShort.azurecr.io" }
Write-Host "ACR short: $acrShort  ACR FQDN: $acrFqdn"

# AKS name and resource group
$aksName = "aks-ado-agents-$InstanceNumber"
Write-Host "Assumed AKS name: $aksName"

# Export variables for downstream pipeline usage (if running in Azure Pipelines)
Write-Host "##vso[task.setvariable variable=INSTANCE_NUMBER]$InstanceNumber"
Write-Host "##vso[task.setvariable variable=ACR_NAME]$acrShort"
Write-Host "##vso[task.setvariable variable=ACR_FQDN]$acrFqdn"
Write-Host "##vso[task.setvariable variable=AKS_NAME]$aksName"
Write-Host "##vso[task.setvariable variable=AKS_RESOURCE_GROUP]$ResourceGroupName"

# Build & push images: Linux
Write-Host "Starting Linux image build/push using azsh-linux-agent/01-build-and-push.ps1"
$linuxDir = Join-Path $repoRoot 'azsh-linux-agent'
$linuxScriptName = '01-build-and-push.ps1'
$linuxScriptPath = Join-Path $linuxDir $linuxScriptName
if (-not (Test-Path $linuxScriptPath)) {
    Write-Warning "Linux build script not found at $linuxScriptPath; skipping Linux build."
}
else {
    # Attempt to ensure Docker is using Linux containers on Windows hosts
    Switch-DockerEngine -target 'linux' -timeoutSeconds 90
    # Run the linux build script from its directory so relative Dockerfile paths resolve correctly
    $cmd = "Set-StrictMode -Version Latest; Set-Location -LiteralPath '$linuxDir'; `$env:DEFAULT_ACR='$acrShort'; `$env:ACR_NAME='$acrShort'; `$env:DOCKER_DEFAULT_PLATFORM='linux'; & .\\$linuxScriptName -ContainerRegistryName '$acrFqdn' -DefaultAcr '$acrShort'"
    Write-Host "Invoking linux build: pwsh -NoProfile -NonInteractive -Command <script in $linuxDir>"
    pwsh -NoProfile -NonInteractive -Command $cmd
    if ($LASTEXITCODE -ne 0) { Write-Warning "Linux build script exited with code $LASTEXITCODE" }
}

# Build & push images: Windows (multiple versions)
Write-Host "Starting Windows image builds using azsh-windows-agent/01-build-and-push.ps1"
$winDir = Join-Path $repoRoot 'azsh-windows-agent'
$winScriptName = '01-build-and-push.ps1'
$winScriptPath = Join-Path $winDir $winScriptName
if (-not (Test-Path $winScriptPath)) {
    Write-Warning "Windows build script not found at $winScriptPath; skipping Windows builds."
}
else {
    # Switch Docker to Windows containers when building Windows images
    Switch-DockerEngine -target 'windows' -timeoutSeconds 90
    # Run the Windows build script in a separate pwsh process and pass parameters explicitly so PSBoundParameters in that script is populated correctly
    $cmd = "Set-StrictMode -Version Latest; Set-Location -LiteralPath '$winDir'; `$env:DEFAULT_ACR='$acrShort'; `$env:ACR_NAME='$acrShort'; & .\$winScriptName -ContainerRegistryName '$acrFqdn' -DefaultAcr '$acrShort'"
    Write-Host "Invoking windows build script in $winDir with explicit parameters"
    pwsh -NoProfile -NonInteractive -Command $cmd
    if ($LASTEXITCODE -ne 0) { Write-Warning "Windows build invocation exited with code $LASTEXITCODE" }
}

# Render pipeline templates by replacing tokens
Write-Host "Rendering pipeline templates in .azuredevops/pipelines (replacing tokens)"
$pipelineTemplates = Get-ChildItem -Path (Join-Path $repoRoot '.azuredevops\pipelines') -Filter '*.template.yml' -File -Recurse
foreach ($tpl in $pipelineTemplates) {
    $text = Get-Content -Raw -Path $tpl.FullName -ErrorAction Stop
    $replacements = @{
        '__ACR_NAME__'                         = $acrShort
        '__AZURE_DEVOPS_ORG_URL__'             = $AzureDevOpsOrgUrl
        '__INSTANCE_NUMBER__'                  = $InstanceNumber
        '__BOOTSTRAP_POOL_NAME__'              = $BootstrapPoolName
        '__KUBECONFIG_AZURE_LOCAL__'           = $KubeconfigAzureLocalPath
        '__KUBECONTEXT_AZURE_LOCAL__'          = $KubeContextAzureLocal
        '__AZURE_SERVICE_CONNECTION__'         = $AzureDevOpsServiceConnectionName
        '__AZURE_DEVOPS_VARIABLE_GROUP__'      = $AzureDevOpsVariableGroup
        '__INSTALL_PIPELINE_NAME__'            = $InstallPipelineName
        '__RUN_ON_POOL_SAMPLE_PIPELINE_NAME__' = $RunOnPoolSamplePipelineName
        '__KUBECONFIG_SECRET_FILE__'           = $KubeConfigSecretFile
    }
    foreach ($k in $replacements.Keys) {
        $v = $replacements[$k]
        if ([string]::IsNullOrWhiteSpace([string]$v)) { $v = '' }
        # Use simple literal string replacement to avoid regex escaping complexities
        $text = $text.Replace($k, [string]$v)
    }
    $outPath = $tpl.FullName -replace '\.template\.yml$', '.yml'
    Write-Host "Writing rendered pipeline: $outPath"
    $text | Out-File -FilePath $outPath -Encoding utf8
}

# Invoke helper to create/update variable group and pipelines (if present)
$vgHelper = Join-Path $repoRoot 'scripts\create-variablegroup-and-pipelines.ps1'
if (Test-Path $vgHelper) {
    Write-Host "Invoking variable-group & pipeline helper: $vgHelper"
    try {
        $vgArgs = @(
            '-NoProfile', '-NonInteractive', '-File', $vgHelper,
            '-OrganizationUrl', $AzureDevOpsOrgUrl,
            '-ProjectName', $AzureDevOpsProject,
            '-RepositoryName', $AzureDevOpsRepo,
            '-AzdoPatSecretName', $AzureDevOpsPatTokenEnvironmentVariableName,
            '-VariableGroupName', $AzureDevOpsVariableGroup,
            '-KubeConfigSecretFile', $KubeConfigSecretFile,
            '-KubeConfigFilePath', $KubeConfigFilePath,
            '-InstallPipelineName', $InstallPipelineName,
            '-UninstallPipelineName', $UninstallPipelineName,
            '-ValidatePipelineName', $ValidatePipelineName,
            '-ImageRefreshPipelineName', $ImageRefreshPipelineName,
            '-RunOnPoolSamplePipelineName', $RunOnPoolSamplePipelineName
        )
        # Stream helper output live to the console while capturing it for later logging.
        # Using Tee-Object lets us display each output line as it arrives and also keep a copy.
        $vgOutput = @()
        & pwsh @vgArgs 2>&1 | Tee-Object -Variable vgOutput | ForEach-Object { Write-Host $_ }
        # Capture the exit code from the child pwsh run. $LASTEXITCODE is set by native processes.
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            $joined = $vgOutput -join "`n"
            Write-Warning "create-variablegroup-and-pipelines helper exited with code $rc. Output:`n$joined"
        }
        else {
            Write-Host "Variable group & pipelines helper completed successfully."
        }
    }
    catch {
        Write-Warning ("Failed to invoke variable-group helper: {0}" -f $_.Exception.Message)
    }
}
else {
    Write-Host "Variable-group helper not found at $vgHelper; skipping Azure DevOps provisioning step."
}

Write-Green "Bootstrap and build run completed. ACR: $acrShort, AKS: $aksName, RG: $ResourceGroupName"

exit 0
