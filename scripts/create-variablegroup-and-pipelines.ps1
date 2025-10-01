Param(
    [Parameter(Mandatory = $false)][string]$OrganizationUrl = 'https://dev.azure.com/cad4devops',
    [Parameter(Mandatory = $false)][string]$ProjectName = 'Cad4DevOps',
    [Parameter(Mandatory = $false)][string]$RepositoryName = 'ADO_az-devops-agents-k8s',
    [Parameter(Mandatory = $false)][string]$AzdoPatSecretName = 'AZDO_PAT',
    [Parameter(Mandatory = $false)][string]$VariableGroupName = 'ADO_az-devops-agents-k8s-003',
    [Parameter(Mandatory = $false)][string]$KubeConfigSecretFile = "AKS_workload-cluster-003-kubeconfig_file",
    [Parameter(Mandatory = $false)][string]$KubeConfigFilePath = "C:\Users\emmanuel.DEVOPSABCS.000\.kube\workload-cluster-003-kubeconfig.yaml",
    [Parameter(Mandatory = $false)][string]$InstallPipelineName = "ADO_az-devops-agents-k8s-deploy-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$UninstallPipelineName = "ADO_az-devops-agents-k8s-uninstall-selfhosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ValidatePipelineName = "ADO_az-devops-agents-k8s-validate-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ImageRefreshPipelineName = "ADO_az-devops-agents-k8s-weekly-image-refresh",
    [Parameter(Mandatory = $false)][string]$RunOnPoolSamplePipelineName = "ADO_az-devops-agents-k8s-run-on-selfhosted-pool-sample-helm",
    [Parameter(Mandatory = $false)][string]$DeployAksInfraPipelineName = "ADO_az-devops-agents-k8s-deploy-aks-helm"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) { Write-Error $msg; exit 1 }

Write-Host "Checking Azure DevOps organization/project/repo: $OrganizationUrl / $ProjectName / $RepositoryName"

# Quick checks using az devops CLI and REST where needed
try {
    $orgParts = $OrganizationUrl -replace '^https?://', '' -split '/'
}
catch { Fail "Invalid OrganizationUrl: $OrganizationUrl" }

# Ensure az CLI is available and the azure-devops extension is installed
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) { Fail "Azure CLI 'az' not found in PATH. Install Azure CLI and the 'azure-devops' extension." }
try {
    az extension show --name azure-devops > $null 2> $null
    if ($LASTEXITCODE -ne 0) { Fail "Azure DevOps az extension 'azure-devops' is not installed. Install with: az extension add --name azure-devops" }
}
catch {
    Fail ("Failed to query az extensions: {0}" -f $_.Exception.Message)
}

Write-Host "Verifying project exists..."
try {
    $proj = az devops project show --org $OrganizationUrl --project $ProjectName --query "id" -o tsv 2>$null
}
catch {
    Fail ("Failed to query project {0} in {1}: {2}" -f $ProjectName, ${OrganizationUrl}, ($_.Exception.Message))
}
if (-not $proj) { Fail "Project '$ProjectName' does not exist in org $OrganizationUrl" }
Write-Host "Project exists: $ProjectName (id=$proj)"

Write-Host "Verifying repository exists..."
try {
    $repo = az repos show --org $OrganizationUrl --project $ProjectName --repository $RepositoryName --query "id" -o tsv 2>$null
}
catch {
    Fail ("Failed to query repo {0} in project {1}: {2}" -f $RepositoryName, ${ProjectName}, ($_.Exception.Message))
}
if (-not $repo) { Fail "Repository '$RepositoryName' does not exist in project $ProjectName" }
Write-Host "Repository exists: $RepositoryName (id=$repo)"

# Create or update variable group with a secret variable (AZDO_PAT). We'll use the Azure DevOps REST API for secrets.
Write-Host "Creating or updating variable group '$VariableGroupName' with secret variable '$AzdoPatSecretName'"

# Check if variable group exists
$vgId = az pipelines variable-group list --org $OrganizationUrl --project $ProjectName --query "[?name=='$VariableGroupName'].id | [0]" -o tsv 2>$null
if ($vgId) { Write-Host "Variable group exists (id=$vgId), will update." }

# Prefer reading the PAT from an environment variable matching the secret name (non-interactive friendly)
$envPat = [Environment]::GetEnvironmentVariable($AzdoPatSecretName)
if ($envPat -and $envPat.Trim() -ne '') {
    Write-Host "Using environment variable '$AzdoPatSecretName' for PAT (from env)."
    $patPlain = $envPat
}
else {
    Write-Host "Please enter the AZDO PAT value (will be stored as a secret in the variable group):"
    $pat = Read-Host -AsSecureString
    $patPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pat))
}

if (-not $vgId) {
    # Create variable group with initial secret
    $resp = az pipelines variable-group create --org $OrganizationUrl --project $ProjectName --name $VariableGroupName --variables "placeholder=placeholder" -o json 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "Failed to create variable group $VariableGroupName" }
    $vgId = ($resp | ConvertFrom-Json).id
    Write-Host "Created variable group id=$vgId"
}

# Set or update the secret variable using az pipelines variable-group variable subcommands which support marking secrets.
Write-Host "Creating/updating secret variable '$AzdoPatSecretName' in variable group id $vgId using az CLI"
try {
    az pipelines variable-group variable update --id $vgId --name $AzdoPatSecretName --secret true --value $patPlain --org $OrganizationUrl --project $ProjectName 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Updated existing variable '$AzdoPatSecretName' as secret in group $vgId"
    }
    else {
        Write-Host "Variable update failed or did not exist; attempting to create variable instead."
        az pipelines variable-group variable create --id $vgId --name $AzdoPatSecretName --secret true --value $patPlain --org $OrganizationUrl --project $ProjectName 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { Fail ("Failed to create secret variable $AzdoPatSecretName in group $vgId") }
        Write-Host "Created secret variable '$AzdoPatSecretName' in group $vgId"
    }
}
catch {
    Fail (("Failed to set secret variable in variable group: {0}" -f $_.Exception.Message))
}

# Create or update an Azure DevOps secure file for the kubeconfig so pipelines can reference it
try {
    $kubeSecretName = $KubeConfigSecretFile
    $kubeFilePath = $KubeConfigFilePath
    if (-not $kubeSecretName) {
        Write-Host 'No KubeConfigSecretFile parameter provided; skipping secure file upload.'
    }
    elseif (-not (Test-Path $kubeFilePath)) {
        Write-Warning ("KubeConfig file not found at path '$kubeFilePath'; skipping secure file upload.")
    }
    else {
        Write-Host "Ensuring secure file '$kubeSecretName' is uploaded to Azure DevOps project '$ProjectName'"

        # Create a temp file with the desired secure file name (Azure DevOps uses the uploaded filename)
        $tempUploadPath = Join-Path $env:TEMP $kubeSecretName
        Copy-Item -Path $kubeFilePath -Destination $tempUploadPath -Force

        # Call the dedicated REST helper script to perform delete+upload using PAT-based Basic auth.
        $helper = Join-Path $PSScriptRoot 'upload-secure-file-rest.ps1'
        if (-not (Test-Path $helper)) {
            Write-Warning "Upload helper script not found at '$helper'. Skipping secure-file upload."
        }
        else {
            Write-Host "Uploading secure file using helper script: $helper"
            try {
                $args = @(
                    '-NoProfile', '-File', $helper,
                    '-PAT', $patPlain,
                    '-AzureDevOpsOrg', $OrganizationUrl,
                    '-AzureDevOpsProjectID', $ProjectName,
                    '-SecureNameFile2Upload', $kubeSecretName,
                    '-SecureNameFilePath2Upload', $tempUploadPath
                )
                $out = & pwsh @args 2>&1
                $rc = $LASTEXITCODE
                if ($rc -eq 0) {
                    Write-Host "Secure file uploaded successfully via helper."
                }
                else {
                    Write-Warning "Secure-file helper exited with code $rc. Output: `n$out"
                }
            }
            catch {
                Write-Warning ("Failed to invoke secure-file helper: {0}" -f $_.Exception.Message)
            }
        }

        Remove-Item -Path $tempUploadPath -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Warning ("Error while creating/updating secure file: {0}" -f $_.Exception.Message)
}

# Create or update pipelines for a set of YAML files
$pipelineFiles = @(
    '.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml',
    '.azuredevops/pipelines/uninstall-selfhosted-agents-helm.yml',
    '.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml',
    '.azuredevops/pipelines/weekly-agent-images-refresh.yml',
    '.azuredevops/pipelines/validate-selfhosted-agents-helm.yml'
)

foreach ($relPath in $pipelineFiles) {
    $fullPath = Join-Path $PWD $relPath
    if (-not (Test-Path $fullPath)) { Write-Warning "Pipeline file not found: $relPath; skipping"; continue }
    # read file to ensure path is accessible; content isn't needed here because Azure CLI will reference the repo path
    Get-Content -Raw -Path $fullPath | Out-Null
    # Create or update pipeline by name. Use the explicit parameter names instead of the filename.
    switch ($relPath) {
        '.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml' { $pipelineName = $InstallPipelineName }
        '.azuredevops/pipelines/uninstall-selfhosted-agents-helm.yml' { $pipelineName = $UninstallPipelineName }
        '.azuredevops/pipelines/validate-selfhosted-agents-helm.yml' { $pipelineName = $ValidatePipelineName }
        '.azuredevops/pipelines/weekly-agent-images-refresh.yml' { $pipelineName = $ImageRefreshPipelineName }
        '.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml' { $pipelineName = $RunOnPoolSamplePipelineName }
        '.azuredevops/pipelines/deploy-aks.yml' { $pipelineName = $DeployAksInfraPipelineName }
        default { $pipelineName = (Split-Path $relPath -Leaf) }
    }
    Write-Host "Pipeline $relPath will be created/updated with name: $pipelineName"
    Write-Host "Create/update pipeline: $pipelineName from $relPath"
    # See if pipeline exists
    $existing = az pipelines list --org $OrganizationUrl --project $ProjectName --query "[?name=='$pipelineName'].id | [0]" -o tsv 2>$null
    if ($existing) {
        Write-Host "Pipeline exists (id=$existing). Updating to point to YAML in repo."
        # Update the pipeline to use the YAML path and branch. Avoid repository/repository-type flags which
        # may not be supported across az extension versions; update by id and set yml-path/branch.
        az pipelines update --id $existing --org $OrganizationUrl --project $ProjectName --yml-path $relPath --branch main 1>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Failed to update pipeline $pipelineName" }
    }
    else {
        Write-Host "Creating new pipeline $pipelineName"
        # Create pipeline referencing the YAML in the repository. Passing repository name is supported in many
        # az versions; if it fails in your environment, create the pipeline manually in the project or adjust.
        az pipelines create --name $pipelineName --org $OrganizationUrl --project $ProjectName --repository $RepositoryName --branch main --yml-path $relPath --skip-first-run true 1>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Failed to create pipeline $pipelineName" }
    }
}

Write-Host "Done. Variable group '$VariableGroupName' created/updated and pipelines processed."
