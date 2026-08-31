[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -Path $root -Recurse -File -Include *.ps1,*.psm1,*.psd1)
$failed = $false

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        $failed = $true
        Write-Host "Parser errors in $($file.FullName):" -ForegroundColor Red
        foreach ($error in @($errors)) {
            Write-Host "  $($error.Message) at $($error.Extent.StartLineNumber):$($error.Extent.StartColumnNumber)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "OK  $($file.FullName)" -ForegroundColor Green
    }
}

if ($failed) { exit 1 }
