Describe 'Public scripts' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:scripts = @(
            Join-Path $script:repoRoot 'scripts/Benchmark-CanaryHistorian.ps1'
            Join-Path $script:repoRoot 'scripts/Export-CanaryHistorian.ps1'
            Join-Path $script:repoRoot 'scripts/Convert-CanaryJsonToCsv.ps1'
        )
    }

    It 'contains all three public entry points' {
        foreach ($scriptPath in $script:scripts) {
            Test-Path $scriptPath | Should -BeTrue
        }
    }

    It 'parses without PowerShell syntax errors' {
        foreach ($scriptPath in $script:scripts) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }

    It 'has comment-based help' {
        foreach ($scriptPath in $script:scripts) {
            $content = Get-Content -Path $scriptPath -Raw
            $content | Should -Match '(?s)<#.*?\.SYNOPSIS.*?\.DESCRIPTION'
        }
    }
}

Describe 'Exporter safety behavior' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:exporterContent = Get-Content -Path (Join-Path $script:repoRoot 'scripts/Export-CanaryHistorian.ps1') -Raw
    }

    It 'recognizes no-TrendVectors as a permanent failure' {
        $script:exporterContent | Should -Match 'TagKey contains no TrendVectors'
        $script:exporterContent | Should -Match '0x800403F8'
    }

    It 'uses bounded Count buckets for older Canary servers' {
        $script:exporterContent | Should -Match 'CountBucketDays'
        $script:exporterContent | Should -Match 'ValidateRange\(1, 999\)'
    }
}

Describe 'Converter output modes' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:converterContent = Get-Content -Path (Join-Path $script:repoRoot 'scripts/Convert-CanaryJsonToCsv.ps1') -Raw
    }

    It 'supports Gzip and Zip output' {
        $script:converterContent | Should -Match 'ValidateSet\("None", "Gzip", "Zip"\)'
    }

    It 'supports per-file and single-archive Zip layouts' {
        $script:converterContent | Should -Match 'ValidateSet\("PerFile", "SingleArchive"\)'
    }

    It 'contains a compiled streaming fallback' {
        $script:converterContent | Should -Match 'Compiled built-in \.NET streaming parser enabled'
    }
}
