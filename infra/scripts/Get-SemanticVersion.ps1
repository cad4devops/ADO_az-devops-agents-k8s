<#
.SYNOPSIS
  Replicates the pipeline's semantic version calculation (GitVersion with fallback) locally.
.DESCRIPTION
  Attempts to run GitVersion with the repository's GitVersion.yml. If GitVersion is unavailable or fails twice,
  falls back to date+shortSha (yyyyMMdd-<7charSHA>). Returns a PSCustomObject with:
    Version            - The resolved Major.Minor.Patch version or fallback suffix
    UsedGitVersion     - $true if GitVersion succeeded
    FallbackReason     - Populated if fallback was used
    Major/Minor/Patch  - Numeric components when GitVersion succeeded
.EXAMPLE
  PS> ./infra/scripts/Get-SemanticVersion.ps1
  PS> ./infra/scripts/Get-SemanticVersion.ps1 -Strict
.PARAMETER Strict
  If specified, any GitVersion failure throws instead of falling back.
#>
[CmdletBinding()]
param(
  [switch]$Strict
)
 $ErrorActionPreference = 'Stop'

function Write-Info($msg){ Write-Host "[INFO] $msg" }
function Write-Warn($msg){ Write-Warning $msg }

# Ensure we're at repo root (script may be invoked from elsewhere)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location (Join-Path $scriptRoot '..' '..')
try {
  $repoRoot = Get-Location
  if(-not (Test-Path .git)){ throw 'Not in a git repository root.' }
  $configPath = Join-Path $repoRoot 'GitVersion.yml'
  if(-not (Test-Path $configPath)){ Write-Warn 'GitVersion.yml not found; GitVersion will use internal defaults.' }

  # Try to locate GitVersion
  $gitVersionCmd = Get-Command dotnet-gitversion -ErrorAction SilentlyContinue
  if(-not $gitVersionCmd){ $gitVersionCmd = Get-Command gitversion -ErrorAction SilentlyContinue }

  if(-not $gitVersionCmd){
    Write-Info 'GitVersion CLI not found; attempting dotnet tool install --global GitVersion.Tool'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'; $env:DOTNET_NOLOGO='1'
    dotnet tool install --global GitVersion.Tool --version 5.* --ignore-failed-sources | Out-Null
    $env:PATH += ":$HOME/.dotnet/tools"
    $gitVersionCmd = Get-Command dotnet-gitversion -ErrorAction SilentlyContinue
  }

  $fallbackSuffix = (Get-Date -Format 'yyyyMMdd') + '-' + (git rev-parse --short=7 HEAD)
  $gv = $null
  $global:__GitVersionConfigPath = $configPath
  function Invoke-GV {
    [CmdletBinding()]
    param(
      [switch]$AllowRetry
    )
    $cmdName = if($gitVersionCmd){ $gitVersionCmd.Name } else { 'dotnet-gitversion' }
    $gvArgs = @('/output','json','/nocache')
    $useConfig = $false
    if(Test-Path $configPath){
      $gvArgs += @('/config',$configPath)
      $useConfig = $true
    }
  Write-Info "Running $cmdName $($gvArgs -join ' ')"
  $raw = & $cmdName @gvArgs 2>&1
    if($LASTEXITCODE -ne 0){
      Write-Warn 'GitVersion failed.'
      Write-Host $raw
      $yamlError = ($raw -match 'YamlDotNet' -or $raw -match 'deserialization')
      if($useConfig -and $yamlError){
        Write-Warn 'GitVersion config parse failed. Retrying WITHOUT config file.'
        $gvArgs = @('/output','json','/nocache')
        $useConfig = $false
        $raw = & $cmdName @gvArgs 2>&1
        if($LASTEXITCODE -eq 0){
          try { return ($raw | ConvertFrom-Json) } catch { Write-Warn 'JSON parse failed after config removal.'; return $null }
        }
      }
      if($AllowRetry){
        if(Test-Path .git/shallow){
          Write-Info 'Shallow clone detected. Attempting unshallow fetch.'
          git fetch --unshallow || git fetch --depth=1000
        } else {
          Write-Info 'Retrying (non-shallow) after failure.'
        }
        $raw = & $cmdName @gvArgs 2>&1
        if($LASTEXITCODE -ne 0){
          Write-Host $raw
          return $null
        }
      } else { return $null }
    }
    try { return ($raw | ConvertFrom-Json) } catch { Write-Warn 'JSON parse failed.'; Write-Host $raw; return $null }
  }

  $gv = Invoke-GV -allowRetry
  if($gv){
    $full = $gv.MajorMinorPatch
    if(-not $full){ $full = $gv.FullSemVer }
    if(-not $full){ throw 'GitVersion returned no usable version.' }
    $full = ($full -split '-')[0] -split '\+' | Select-Object -First 1
    if($full -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$'){ throw "Normalized version not Major.Minor.Patch: $full" }
    $parts = $full.Split('.')
    [pscustomobject]@{
      Version        = $full
      UsedGitVersion = $true
      FallbackReason = $null
      Major          = [int]$parts[0]
      Minor          = [int]$parts[1]
      Patch          = [int]$parts[2]
    }
  }
  else {
    $msg = 'GitVersion failed; using fallback suffix.'
    if($Strict){ throw $msg }
    [pscustomobject]@{
      Version        = $fallbackSuffix
      UsedGitVersion = $false
      FallbackReason = $msg
      Major          = $null
      Minor          = $null
      Patch          = $null
    }
  }
}
finally { Pop-Location }
