[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Test-Syntax.ps1')
& (Join-Path $PSScriptRoot 'Test-Lint.ps1')
Invoke-Pester -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests') -Output Detailed
