# Security Policy

## Reporting a vulnerability

Keep credentials, API tokens, customer historian data, and sensitive tag paths out of public issues.

For a security issue in these scripts, use GitHub's private vulnerability reporting feature when available. For ordinary bugs without sensitive information, open a normal issue.

## Credential handling

The tools accept Canary tokens as command-line parameters for compatibility. Use environment variables when practical:

```powershell
$env:CANARY_API_TOKEN = "..."
.\scripts\Export-CanaryHistorian.ps1 -Server "https://server:55236" -ApiToken $env:CANARY_API_TOKEN
```

The scripts keep authentication tokens out of export state and logs. Review logs before sharing them publicly because historian paths and error messages may still disclose system-specific information.
