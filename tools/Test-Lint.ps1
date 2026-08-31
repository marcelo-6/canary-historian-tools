[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

Import-Module PSScriptAnalyzer -ErrorAction Stop

$issues = @(
    Invoke-ScriptAnalyzer `
        -Path (Join-Path $root 'scripts') `
        -Recurse `
        -Severity Error
)

if ($issues.Count -gt 0) {
    $issues | Format-Table -AutoSize
    throw "PSScriptAnalyzer found $($issues.Count) error issue(s)."
}

Write-Host 'PSScriptAnalyzer: no errors.' -ForegroundColor Green