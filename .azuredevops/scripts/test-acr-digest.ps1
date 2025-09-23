<#
Usage: pwsh ./.azuredevops/scripts/test-acr-digest.ps1 -acr <acrNameOrFqdn> -repo <repository> -tag <tag>

This is a small, single-pass harness that tries a few az acr command variants and prints the first one
that returns a manifest digest (sha256:...). It parses JSON inline to avoid scoping issues.
#>

param(
  [Parameter(Mandatory=$true)][string] $acr,
  [Parameter(Mandatory=$true)][string] $repo,
  [Parameter(Mandatory=$true)][string] $tag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ShellCommand([string]$cmd){
  Write-Host '--------------------------------------------------------------------------------'
  Write-Host "Running: $cmd"
  try{
    $out = & bash -lc "$cmd" 2>&1
    $rc = $LASTEXITCODE
  } catch {
    $out = $_.Exception.Message
    $rc = 1
  }
  Write-Host "Exit code: $rc"
  Write-Host "Output:`n$out" -ForegroundColor Yellow
  return @{ rc = $rc; out = $out }
}

Write-Host "Testing ACR digest retrieval for registry='$acr' repo='$repo' tag='$tag'" -ForegroundColor Cyan
Write-Host 'Azure CLI version:'
Invoke-ShellCommand 'az --version'

# prepare registry names
$acrFqdn = if($acr -match '\.') { $acr } else { "$acr.azurecr.io" }
$acrShort = $acrFqdn.Split('.')[0]
$fqRepo = "$acrFqdn/$repo"

$registryArgName = @('--name', '--registry')
$repoArgName = @('--repository', '')

$candidates = @()

# build candidate commands (order chosen to maximize compatibility)
foreach($reg in $registryArgName){
  # show-manifests (accepts --repository on many CLI versions)
  $candidates += "az acr repository show-manifests $reg $acrShort --repository $repo --output json"
  $candidates += "az acr repository show-manifests $reg $acrShort $fqRepo --output json"
  # list-metadata (preview) - try both positional fq repo and --repository where supported
  $candidates += "az acr manifest list-metadata $reg $acrShort $fqRepo --output json"
  $candidates += "az acr manifest list-metadata $reg $acrShort --repository $repo --output json"
  # show-tags fallback
  $candidates += "az acr repository show-tags $reg $acrShort --repository $repo --output json"
  $candidates += "az acr repository show-tags $reg $acrShort $fqRepo --output json"
}

$results = @()
foreach($cmd in $candidates){
  $r = Invoke-ShellCommand $cmd
  $digest = $null
    if($r.rc -eq 0){
      # Normalize output to a single string and strip leading non-JSON lines (warnings) before parsing
      $outStr = if($r.out -is [System.Array]) { ($r.out -join "`n") } else { [string]$r.out }
      $firstBracket = $outStr.IndexOf('[')
      if($firstBracket -ge 0){ $jsonText = $outStr.Substring($firstBracket) } else { $jsonText = $outStr }
      # Attempt to parse JSON and find the first 'digest' property
      try{
        $obj = $jsonText | ConvertFrom-Json -ErrorAction Stop
        $arr = if($obj -is [System.Array]){ $obj } else { @($obj) }
        foreach($i in $arr){
          if($i.PSObject.Properties.Name -contains 'digest'){ $digest = $i.digest; break }
          if($i.PSObject.Properties.Name -contains 'value' -and $i.value -is [System.Array]){
            foreach($v in $i.value){ if($v.PSObject.Properties.Name -contains 'digest'){ $digest = $v.digest; break } }
            if($digest){ break }
          }
        }
      } catch {
        # JSON parse failed; we'll try regex fallback
      }
      if(-not $digest){
        $m = [regex]::Match($r.out, 'sha256:[a-f0-9]{64}')
        if($m.Success){ $digest = $m.Value }
      }
    }
  $results += [pscustomobject]@{ command = $cmd; rc = $r.rc; digest = $digest; raw = $r.out }
  if($digest){
    Write-Host "`nSUCCESS: command returned digest: $digest" -ForegroundColor Green
    Write-Host "Recommended command to use in pipeline: `n$cmd" -ForegroundColor Green
    exit 0
  }
}

Write-Host "`nNo candidate returned a digest. Detailed results:" -ForegroundColor Yellow
foreach($r in $results){
  Write-Host '---'
  Write-Host "Command: $($r.command)" -ForegroundColor Cyan
  Write-Host "Exit: $($r.rc)"; Write-Host "Digest: $($r.digest)"; Write-Host "Raw:`n$($r.raw)" -ForegroundColor DarkYellow
}
exit 2
