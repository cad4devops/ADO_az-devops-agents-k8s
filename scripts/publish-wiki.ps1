param(
    [Parameter(Mandatory)] [string] $OrgUrl,
    [Parameter(Mandatory)] [string] $Project,
    [Parameter(Mandatory)] [string] $WikiName,
    [Parameter(Mandatory)] [string] $WikiPath,
    [Parameter(Mandatory)] [string] $MarkdownPath,
    [string] $Comment = "Automated tooling report publish"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $MarkdownPath -PathType Leaf)) {
    throw "Markdown file not found at $MarkdownPath"
}

$pat = $env:AZDO_PAT
if ([string]::IsNullOrWhiteSpace($pat)) {
    throw "Set AZDO_PAT environment variable with a valid Personal Access Token."
}

Write-Host "Installing Azure DevOps CLI extension if needed..."
az extension add --name azure-devops --only-show-errors --yes | Out-Null

Write-Host "Authenticating to Azure DevOps ($OrgUrl)..."
$null = $pat | az devops login --organization $OrgUrl --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to authenticate with the provided AZDO_PAT."
}

az devops configure --defaults organization=$OrgUrl project=$Project | Out-Null

$normalizedPath = $WikiPath.Trim()
if ($normalizedPath.StartsWith('/')) { $normalizedPath = $normalizedPath.Substring(1) }

function Ensure-ParentPages {
    param([string[]]$Segments)

    if ($Segments.Length -lt 2) { return }

    $built = @()
    for ($i = 0; $i -lt ($Segments.Length - 1); $i++) {
        $segment = $Segments[$i].Trim()
        if (-not $segment) { continue }

        $built += $segment
        $currentPath = '/' + ($built -join '/')

        $null = az devops wiki page show --wiki $WikiName --path $currentPath --only-show-errors 2>&1
        if ($LASTEXITCODE -eq 0) { continue }

        Write-Host "Creating missing parent page $currentPath ..."
        $placeholder = "# $segment"
        $null = az devops wiki page create --wiki $WikiName --path $currentPath --content $placeholder --comment "Auto-created parent page" --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create parent page $currentPath"
        }
    }
}

$segments = $normalizedPath -split '/'
Ensure-ParentPages -Segments $segments

$targetPath = '/' + $normalizedPath
$null = az devops wiki page show --wiki $WikiName --path $targetPath --only-show-errors 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Updating existing wiki page $targetPath ..."
    $null = az devops wiki page update --wiki $WikiName --path $targetPath --file-path $MarkdownPath --encoding utf-8 --comment $Comment --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to update wiki page $targetPath" }
    Write-Host "Wiki page updated successfully."
} else {
    Write-Host "Creating wiki page $targetPath ..."
    $null = az devops wiki page create --wiki $WikiName --path $targetPath --file-path $MarkdownPath --encoding utf-8 --comment $Comment --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to create wiki page $targetPath" }
    Write-Host "Wiki page created successfully."
}