[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "canary-historian-tools-$Version"
$zip = Join-Path $dist "canary-historian-tools-$Version.zip"

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zip -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'docs') -Force | Out-Null

Copy-Item (Join-Path $root 'scripts\*.ps1') (Join-Path $stage 'scripts')
Copy-Item (Join-Path $root 'docs\*.md') (Join-Path $stage 'docs')
Copy-Item (Join-Path $root 'README.md'), (Join-Path $root 'CHANGELOG.md'), (Join-Path $root 'LICENSE') $stage

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
$hash = Get-FileHash -Path $zip -Algorithm SHA256
"$($hash.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($zip))" | Set-Content -Path "$zip.sha256" -Encoding ASCII

Write-Host "Created $zip" -ForegroundColor Green
Write-Host "Created $zip.sha256" -ForegroundColor Green
