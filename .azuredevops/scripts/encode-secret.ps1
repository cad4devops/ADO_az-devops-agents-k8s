<#
.SYNOPSIS
  Encode a value to base64 (UTF8) for use in Helm values on Windows/PowerShell.

USAGE
  pwsh .\encode-secret.ps1 -Value 'https://dev.azure.com/yourorg'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$Value
)

[Console]::Out.WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)))
