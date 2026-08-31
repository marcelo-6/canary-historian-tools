$repoRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(
    Join-Path $repoRoot 'scripts/Benchmark-CanaryHistorian.ps1'
    Join-Path $repoRoot 'scripts/Export-CanaryHistorian.ps1'
    Join-Path $repoRoot 'scripts/Convert-CanaryJsonToCsv.ps1'
)

Describe 'Public scripts' {
    It 'contains all three public entry points' {
        foreach ($script in $scripts) {
            Test-Path $script | Should -BeTrue
        }
    }

    It 'parses without PowerShell syntax errors' {
        foreach ($script in $scripts) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }

    It 'has comment-based help' {
        foreach ($script in $scripts) {
            $content = Get-Content -Path $script -Raw
            $content | Should -Match '(?s)<#.*?\.SYNOPSIS.*?\.DESCRIPTION'
        }
    }
}

Describe 'Exporter safety behavior' {
    $content = Get-Content -Path (Join-Path $repoRoot 'scripts/Export-CanaryHistorian.ps1') -Raw

    It 'recognizes no-TrendVectors as a permanent failure' {
        $content | Should -Match 'TagKey contains no TrendVectors'
        $content | Should -Match '0x800403F8'
    }

    It 'uses bounded Count buckets for older Canary servers' {
        $content | Should -Match 'CountBucketDays'
        $content | Should -Match 'ValidateRange\(1, 999\)'
    }
}

Describe 'Converter output modes' {
    $content = Get-Content -Path (Join-Path $repoRoot 'scripts/Convert-CanaryJsonToCsv.ps1') -Raw

    It 'supports Gzip and Zip output' {
        $content | Should -Match 'ValidateSet\("None", "Gzip", "Zip"\)'
    }

    It 'supports per-file and single-archive Zip layouts' {
        $content | Should -Match 'ValidateSet\("PerFile", "SingleArchive"\)'
    }

    It 'contains a compiled streaming fallback' {
        $content | Should -Match 'Compiled built-in \.NET streaming parser enabled'
    }
}
