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
    [Parameter(Mandatory = $true)][string]$ADOCollectionName,
    [Parameter(Mandatory = $true)][string]$AzureDevOpsProject,
    [Parameter(Mandatory = $true)][string]$AzureDevOpsRepo,
    [Parameter(Mandatory = $false)][string]$ResourceGroupName,
    [Parameter(Mandatory = $false)][string]$ContainerRegistryName, # = "devopsabcsrunners", # specify your container registry name or leave empty to create one
    [Parameter(Mandatory = $false)][switch]$BuildInPipeline,
    [Parameter(Mandatory = $false)][switch]$EnableWindows,
    [Parameter(Mandatory = $false)][int]$WindowsNodeCount = 1,
    [Parameter(Mandatory = $false)][int]$LinuxNodeCount = 1,
    [Parameter(Mandatory = $false)][string]$LinuxVmSize = 'Standard_D4s_v3',
    [Parameter(Mandatory = $false)][string]$WindowsVmSize = 'Standard_D2s_v3',
    [Parameter(Mandatory = $false)][string]$AzureDevOpsOrgUrl = "https://dev.azure.com/$ADOCollectionName",


    [Parameter(Mandatory = $false)][string]$BootstrapPoolName = 'KubernetesPoolWindows',
    [Parameter(Mandatory = $false)][string]$KubeconfigAzureLocalPath = "workload-cluster-$InstanceNumber-kubeconfig.yaml",
    [Parameter(Mandatory = $false)][string]$KubeContextAzureLocal = "workload-cluster-$InstanceNumber-admin@workload-cluster-$InstanceNumber",
    [Parameter(Mandatory = $false)][string]$KubeConfigFilePath = "${HOME}\.kube\workload-cluster-$InstanceNumber-kubeconfig.yaml",
    [Parameter(Mandatory = $false)][string]$AzureDevOpsServiceConnectionName = 'DOS_DevOpsShield_Prod', # specify you ARM azure devops service connection name
    [Parameter(Mandatory = $false)][string]$AzureDevOpsVariableGroup = "$AzureDevOpsRepo-$InstanceNumber",
    [Parameter(Mandatory = $false)][string]$AzureDevOpsPatTokenEnvironmentVariableName = "AZDO_PAT",
    [Parameter(Mandatory = $false)][string]$InstallPipelineName = "$AzureDevOpsRepo-deploy-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$UninstallPipelineName = "$AzureDevOpsRepo-uninstall-selfhosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ValidatePipelineName = "$AzureDevOpsRepo-validate-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ImageRefreshPipelineName = "$AzureDevOpsRepo-weekly-image-refresh",
    [Parameter(Mandatory = $false)][string]$RunOnPoolSamplePipelineName = "$AzureDevOpsRepo-run-on-selfhosted-pool-sample-helm",
    [Parameter(Mandatory = $false)][string]$DeployAksInfraPipelineName = "$AzureDevOpsRepo-deploy-aks-helm",
    [Parameter(Mandatory = $false)][string]$KubeConfigSecretFile = "AKS_workload-cluster-$InstanceNumber-kubeconfig_file",
    [Parameter(Mandatory = $false)][string]$UbuntuOnPremPoolName = "UbuntuLatestPoolOnPrem",
    [Parameter(Mandatory = $false)][string]$WindowsOnPremPoolName = "WindowsLatestPoolOnPrem",
    [Parameter(Mandatory = $false)][string]$UseOnPremAgents = "false"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load .env file if it exists (before validation)
$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $envFile) {
    Write-Host "Loading environment variables from .env file..."
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $name = $matches[1].Trim()
                $value = $matches[2].Trim()
                # Remove surrounding quotes if present
                if ($value -match '^["''](.*)["'']$') {
                    $value = $matches[1]
                }
                Set-Item -Path "env:$name" -Value $value
                Write-Host "  Loaded: $name"
            }
        }
    }
}

# Helper functions (must be defined before use)
function Fail([string]$msg) { Write-Error $msg; exit 1 }

function Write-Green([string]$msg) { try { if ($IsWindows) { Write-Host -ForegroundColor Green $msg } else { Write-Host "`e[32m$msg`e[0m" } } catch { Write-Host $msg } }

# Helper to mask PAT for safe logging (preserve first 4 + last 4 chars)
function MaskPat([string]$pat) {
    if (-not $pat) { return '(empty)' }
    if ($pat.Length -le 8) { return '****' }
    $mid = -join (1..($pat.Length - 8) | ForEach-Object { '*' })
    return $pat.Substring(0, 4) + $mid + $pat.Substring($pat.Length - 4)
}

# Validate required environment variable
if ([string]::IsNullOrWhiteSpace($env:AZDO_PAT)) {
    Write-Error @"
ERROR: Required environment variable 'AZDO_PAT' is not set.

The Azure DevOps Personal Access Token (PAT) is required to create/update:
  - Variable groups
  - Pipelines
  - Secure files

Please set the AZDO_PAT environment variable before running this script:

  `$env:AZDO_PAT = 'your-actual-pat-token'

Or create a .env file in the repository root with:
  AZDO_PAT=your-actual-pat-token

See docs/bootstrap-env.md for PAT scope requirements.
"@
    exit 1
}

# Validate PAT is not the default placeholder value
if ($env:AZDO_PAT -eq 'your-pat-token-here' -or $env:AZDO_PAT -match '^your-pat-token' -or $env:AZDO_PAT -eq 'your-actual-pat-token') {
    Write-Error @"
ERROR: AZDO_PAT contains a placeholder value ('$($env:AZDO_PAT)').

Please set a valid Azure DevOps Personal Access Token.
The PAT must have the following scopes:
  - Agent Pools (Read & manage)
  - Build (Read & execute)
  - Code (Read)
  - Variable Groups (Read, create & manage)

See docs/bootstrap-env.md for detailed PAT creation instructions.
"@
    exit 1
}

# Output masked PAT for debugging (safe to log)
Write-Host "AZDO_PAT validation passed (masked): $(MaskPat $env:AZDO_PAT)"

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
    '-LinuxNodeCount', [string]$LinuxNodeCount,
    '-LinuxVmSize', $LinuxVmSize,
    '-WindowsVmSize', $WindowsVmSize
)
if ($EnableWindows.IsPresent) { $deployArgs += '-EnableWindows'; $deployArgs += $true }
if ($ContainerRegistryName) { $deployArgs += '-ContainerRegistryName'; $deployArgs += $ContainerRegistryName }
if ($ContainerRegistryName) { $deployArgs += '-SkipContainerRegistry'; }

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
if ($BuildInPipeline) {
    Write-Host "BuildInPipeline is set; skipping local image builds. Images will be built via the weekly image refresh pipeline."
}
else {
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
        '__SKIP_CONTAINER_REGISTRY__'          = ($ContainerRegistryName -and -not [string]::IsNullOrWhiteSpace($ContainerRegistryName))
        '__UBUNTU_ONPREM_POOL_NAME__'          = $UbuntuOnPremPoolName
        '__WINDOWS_ONPREM_POOL_NAME__'         = $WindowsOnPremPoolName
        '__USE_ONPREM_AGENTS__'                = $UseOnPremAgents
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
    Write-Host "Using AZDO_PAT (masked): $(MaskPat $env:AZDO_PAT)"
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

# Attempt to invoke helper that will add ACR credentials into the Azure DevOps variable group.
# The CLI-based helper uses Azure CLI commands and AZDO_PAT from environment automatically.
$addAcrScript = Join-Path $repoRoot '.azuredevops\scripts\add-acr-creds-to-variablegroup-cli.ps1'
if (Test-Path $addAcrScript) {
    Write-Host "Invoking add-acr-creds-to-variablegroup-cli helper: $addAcrScript"
    Write-Host "Using AZDO_PAT (masked): $(MaskPat $env:AZDO_PAT) pushed as secret to Azure DevOps"
    $addArgs = @(
        '-AcrName', $acrShort,
        '-OrgUrl', $AzureDevOpsOrgUrl,
        '-Project', $AzureDevOpsProject,
        '-VariableGroupName', $AzureDevOpsVariableGroup
    )
    $addOutput = @()
    & pwsh -NoProfile -NonInteractive -File $addAcrScript @addArgs 2>&1 | Tee-Object -Variable addOutput | ForEach-Object { Write-Host $_ }
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        $joined = $addOutput -join "`n"
        Write-Warning "add-acr-creds-to-variablegroup-cli helper exited with code $rc. Output:`n$joined"
    }
    else {
        Write-Host "add-acr-creds-to-variablegroup-cli helper completed successfully."
    }
}
else {
    Write-Host "add-acr-creds-to-variablegroup-cli helper not found at $addAcrScript; skipping."
}

# Post-check: verify the variable group contains ACR_USERNAME and ACR_PASSWORD 
# so pipelines fail fast if secrets weren't created.
try {
    Write-Host "Verifying variable group '$AzureDevOpsVariableGroup' contains ACR_USERNAME and ACR_PASSWORD..."
    $vgListJson = az pipelines variable-group list --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vgListJson)) {
        Write-Warning "Unable to list variable groups using az CLI; skipping ACR variable verification."
    }
    else {
        $vgList = $null
        try { $vgList = $vgListJson | ConvertFrom-Json -ErrorAction Stop } catch { $vgList = $null }
        if (-not $vgList) { Write-Warning "Failed to parse variable groups list JSON; skipping verification." }
        else {
            $vg = $vgList | Where-Object { $_.name -eq $AzureDevOpsVariableGroup }
            if (-not $vg) { Fail "Variable group '$AzureDevOpsVariableGroup' not found in project '$AzureDevOpsProject' (cannot verify ACR variables)." }
            $vgId = $vg.id
            Write-Host "Found variable group id=$vgId; listing variables..."
            $varsJson = az pipelines variable-group variable list --id $vgId --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject -o json 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($varsJson)) { Fail "Failed to list variables for variable group id=$vgId via az CLI." }
            $vars = $null
            try { $vars = $varsJson | ConvertFrom-Json -ErrorAction Stop } catch { $vars = $null }
            if (-not $vars) { Fail "Failed to parse variables JSON for variable group id=$vgId." }
            # Normalize several possible JSON shapes returned by different az/extension versions:
            # 1) An array of { name: 'VAR', ... }
            # 2) An object with a 'variables' map: { variables: { VAR: {...}, ... } }
            # 3) A flat object where each property name is a variable name
            $names = @()
            try {
                if ($vars -is [System.Collections.IEnumerable] -and $vars.Count -gt 0 -and ($vars[0].PSObject.Properties.Name -contains 'name')) {
                    # Shape 1: array of objects with 'name'
                    $names = $vars | ForEach-Object { $_.name }
                }
                elseif ($vars -and $vars.PSObject.Properties.Match('variables').Count -gt 0) {
                    # Shape 2: object with 'variables' map
                    $map = $vars.variables
                    if ($map) {
                        # map is usually an object with properties named after variables
                        $names = $map.PSObject.Properties | ForEach-Object { $_.Name }
                    }
                }
                else {
                    # Shape 3: treat top-level property names as variable names
                    $names = $vars.PSObject.Properties | ForEach-Object { $_.Name }
                }
            }
            catch { $names = @() }
            $hasUser = $names -contains 'ACR_USERNAME'
            $hasPass = $names -contains 'ACR_PASSWORD'
            if (-not $hasUser -or -not $hasPass) {
                $missing = @()
                if (-not $hasUser) { $missing += 'ACR_USERNAME' }
                if (-not $hasPass) { $missing += 'ACR_PASSWORD' }
                Fail (("Variable group '{0}' is missing required ACR variables. Present: {1}. Missing: {2}") -f $AzureDevOpsVariableGroup, ($names -join ', '), ($missing -join ', '))
            }
            else {
                Write-Host "Verified: ACR_USERNAME and ACR_PASSWORD exist in variable group (id=$vgId)."
            }
        }
    }
}
catch {
    Fail ("ACR variable verification failed: {0}" -f $_.Exception.Message)
}

Write-Green "Bootstrap and build run completed. ACR: $acrShort, AKS: $aksName, RG: $ResourceGroupName"

Write-Green "Remember to commite and push your upated pipeline .yml files in .azuredevops/pipelines. BEFORE running any of the created pipelines."
exit 0

