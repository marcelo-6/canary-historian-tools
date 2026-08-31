# Security Policy

## Reporting a vulnerability

Please do not publish credentials, API tokens, customer historian data, or sensitive tag paths in a public issue.

For a security issue in these scripts, use GitHub's private vulnerability reporting feature when available. For ordinary bugs without sensitive information, open a normal issue.

## Credential handling

The tools accept Canary tokens as command-line parameters for compatibility, but environment variables are preferable when practical:

```powershell
$env:CANARY_API_TOKEN = "..."
.\scripts\Export-CanaryHistorian.ps1 -Server "https://server:55236" -ApiToken $env:CANARY_API_TOKEN
```

The scripts are designed not to persist authentication tokens in export state or logs. Review logs before sharing them publicly because historian paths and error messages may still disclose system-specific information.
