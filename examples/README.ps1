# Examples

# Canary 23.x anonymous endpoint
.\scripts\Benchmark-CanaryHistorian.ps1 -Server "http://localhost:55235"

# Export raw history
.\scripts\Export-CanaryHistorian.ps1 `
    -Server "http://localhost:55235" `
    -OutputDirectory "E:\CanaryExport" `
    -MaxSizePerTag 50000

# Secure server using an environment-provided API token
.\scripts\Export-CanaryHistorian.ps1 `
    -Server "https://canary-server:55236" `
    -ApiToken $env:CANARY_API_TOKEN `
    -OutputDirectory "E:\CanaryExport" `
    -InsecureSkipCertificateCheck

# Convert to one final ZIP
.\scripts\Convert-CanaryJsonToCsv.ps1 `
    -ExportDirectory "E:\CanaryExport" `
    -Compression Zip `
    -ZipLayout SingleArchive `
    -SingleZipName "FullHistorianExport.zip" `
    -CompressionLevel Fastest
