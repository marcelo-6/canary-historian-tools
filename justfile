set shell := ["pwsh", "-NoLogo", "-NoProfile", "-Command"]

# Run the full local validation suite.
check: syntax lint test spell links

# Parse all PowerShell scripts under the current PowerShell runtime.
syntax:
    ./tools/Test-Syntax.ps1

# PSScriptAnalyzer checks.
lint:
    ./tools/Test-Lint.ps1

# Pester repository tests.
test:
    Invoke-Pester -Path ./tests -Output Detailed

# Rust-based typo checker.
spell:
    typos

# Rust-based link checker.
links:
    lychee --config ./lychee.toml "./**/*.md"

# Regenerate CHANGELOG.md from Git history.
changelog:
    git cliff -o CHANGELOG.md

# Print the version git-cliff would choose from commit history.
next-version:
    git cliff --bumped-version
