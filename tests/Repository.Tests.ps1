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

    It 'validates export-plan coverage before raw export' {
        $script:exporterContent | Should -Match 'export-plan\.csv'
        $script:exporterContent | Should -Match 'Assert-ExportPlanCoverage'
        $script:exporterContent | Should -Match 'Export plan validated'
    }

    It 'applies exclusion regex case-sensitively' {
        $script:exporterContent | Should -Match '-cmatch \$ExcludeRegex'
        $script:exporterContent | Should -Match '-cnotmatch \$ExcludeRegex'
    }

    It 'keeps Count failures separate from export eligibility' {
        $script:exporterContent | Should -Match 'Test-SystemicCountFailure'
        $script:exporterContent | Should -Match 'Raw export eligibility is unaffected'
        $script:exporterContent | Should -Match '-Attempts 1'
    }

    It 'repairs missing or empty checkpoint pages before resume' {
        $script:exporterContent | Should -Match 'Reset-BatchForReexport'
        $script:exporterContent | Should -Match 'missing or empty page'
        $script:exporterContent | Should -Match '\.Length -le 0'
    }

    It 'repairs invalid continuation checkpoints before resume' {
        $script:exporterContent | Should -Match 'Invalid continuation'
        $script:exporterContent | Should -Match 'checkpoint references an invalid continuation'
    }

    It 'permits MaxSizePerTag changes by resetting unfinished batches' {
        $script:exporterContent | Should -Match 'Repair-MaxSizeChange'
        $script:exporterContent | Should -Match 'MaxSizePerTag changed from'
        $script:exporterContent | Should -Match 'completed batches were retained'
    }

    It 'permits ExportBatchSize changes by regrouping unfinished batches' {
        $script:exporterContent | Should -Match 'Repair-ExportBatchSizeChange'
        $script:exporterContent | Should -Match 'ExportBatchSize changed from'
        $script:exporterContent | Should -Match 'Regrouped .* unfinished batch checkpoint'
    }

    It 'replays raw continuation tokens without nesting them' {
        $script:exporterContent | Should -Match 'Convert-ContinuationForRequest -Continuation \$Batch\.Continuation'
        $script:exporterContent | Should -Not -Match '\$body\["continuation"\] = @\(\$Batch\.Continuation\)'
    }

    It 'normalizes only continuation nulls before raw requests' {
        $script:exporterContent | Should -Match 'function Convert-ContinuationForRequest'
        $script:exporterContent | Should -Match 'if \(\$null -eq \$item\) \{ "" \}'
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

    It 'guards large ConvertFrom-Json fallback usage' {
        $script:converterContent | Should -Match 'PowerShellParserMaxInputMB'
        $script:converterContent | Should -Match 'Refusing ConvertFrom-Json fallback'
        $script:converterContent | Should -Match 'compressed source page'
    }

    It 'invalidates checkpoints when output settings change' {
        $script:converterContent | Should -Match 'record\.compression'
        $script:converterContent | Should -Match 'record\.zipLayout'
        $script:converterContent | Should -Match 'record\.compressionLevel'
    }
}

Describe 'Benchmark safety behavior' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:benchmarkContent = Get-Content -Path (Join-Path $script:repoRoot 'scripts/Benchmark-CanaryHistorian.ps1') -Raw
    }

    It 'records malformed or omitted context rows as skipped tags' {
        $script:benchmarkContent | Should -Match 'Add-BadContextTag'
        $script:benchmarkContent | Should -Match 'Context response omitted tag'
        $script:benchmarkContent | Should -Match 'Context response duplicated tag'
        $script:benchmarkContent | Should -Match 'missing oldestTimeStamp or latestTimeStamp'
    }
}

Describe 'Offline fixtures' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:fixtureDirectory = Join-Path $script:repoRoot 'tests/fixtures'
        $script:fixtures = @(
            'context-good.json'
            'context-missing-tag.json'
            'context-null-timestamp.json'
            'raw-good.json'
            'raw-empty.json'
            'raw-continuation.json'
            'raw-no-trend-vectors.json'
            'aggregate-no-license.json'
            'string-values.json'
        )
    }

    It 'contains valid JSON fixture files' {
        foreach ($fixture in $script:fixtures) {
            $path = Join-Path $script:fixtureDirectory $fixture
            Test-Path $path | Should -BeTrue
            { Get-Content -Path $path -Raw | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}
