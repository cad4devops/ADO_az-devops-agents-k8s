<#
Generate a `helm-charts-v2/values.secret.yaml` file from environment variables.
Intended for local use or CI when secrets are passed via environment variables.

Required env vars (example):
  VAL_AZP_URL_B64
  VAL_AZP_TOKEN_B64
  VAL_AZP_POOL_LINUX_B64
  VAL_AZP_POOL_WINDOWS_B64

Outputs: helm-charts-v2/values.secret.yaml
#>
[CmdletBinding()]
param()

$out = @{}
$out['secret'] = @{
  name = 'sh-agent-secret-003'
  data = @{}
}

foreach($k in @('AZP_URL','AZP_TOKEN','AZP_POOL_LINUX','AZP_POOL_WINDOWS')){
  $envName = "VAL_${k}_B64"
  $val = $env:$envName
  if(-not $val){ Write-Warning "Environment variable $envName not set; leaving empty" }
  $out['secret']['data'][$k] = $val
}

$yaml = $out | ConvertTo-Yaml -Depth 5
$path = Join-Path $PSScriptRoot '..\..\helm-charts-v2\values.secret.yaml'
$yaml | Out-File -FilePath $path -Encoding utf8
Write-Host "Wrote values secret to $path"
