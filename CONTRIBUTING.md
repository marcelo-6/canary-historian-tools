# Contributing

Contributions are welcome. The runtime tools remain plain PowerShell scripts with no mandatory third-party runtime dependency.

## Requirements

For normal script development:

- Windows PowerShell 5.1 and/or PowerShell 7.4+
- Git

Recommended contributor tools:

- PSScriptAnalyzer 1.25.0
- Pester 5.9.0
- git-cliff
- typos
- lychee
- just

Pester 5 runs in CI because it supports both Windows PowerShell 5.1 and current PowerShell 7.

## Setup

```powershell
Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
Install-Module Pester -RequiredVersion 5.9.0 -Scope CurrentUser
```

Optional Rust tooling can be installed with your preferred method (`cargo install`, `cargo-binstall`, package manager, or packaged binaries).

## Checks

With `just`:

```text
just check
```

Or directly:

```powershell
pwsh ./tools/Test-Repository.ps1
```

The CI matrix performs parser validation on Windows PowerShell 5.1 and PowerShell 7, then runs PSScriptAnalyzer and Pester.

## Commit style

Use Conventional Commit-style prefixes so `git-cliff` can group release notes:

```text
feat: add export filter option
fix: classify unavailable TrendVectors as permanent
perf: stream continuation parsing in compiled code
docs: explain batch and page layout
test: cover CSV quoting behavior
chore: update CI dependencies
```

Scopes are welcome but optional:

```text
perf(export): avoid full JSON deserialization
fix(convert): preserve embedded CSV newlines
```

## Pull requests

A useful pull request should include:

1. The Canary version or API behavior it targets when relevant.
2. Whether it was tested in Windows PowerShell 5.1, PowerShell 7, or both.
3. A description of resume/checkpoint implications for exporter changes.
4. Tests or a reproducible sample payload for parser/converter changes.

Keep API tokens, historian exports, customer tag names, production logs, and other private system data out of commits.
