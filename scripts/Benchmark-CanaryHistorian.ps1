<#
.SYNOPSIS
    Cross-version Canary Historian Read API benchmark (strict-mode collection-safe).

.DESCRIPTION
    Benchmarks Canary Views Read API data extraction for Canary 23.x through 25.x.

    The script:
      1. Browses all accessible tags.
      2. Excludes literal {Diagnostics} tags by default.
      3. Retrieves oldest/latest history using getTagContext.
      4. Estimates raw TVQ count using Count in explicit <=999-day buckets.
      5. Benchmarks raw getTagData2 throughput using continuation paging.
      6. Writes CSV/JSON results and a timestamped text log.

    It supports anonymous access plus apiToken, accessToken, or userToken authentication.
    It is compatible with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    # Canary 23.x anonymous HTTP endpoint
    .\Benchmark-CanaryHistorian.ps1 `
        -Server "http://localhost:55235"

.EXAMPLE
    # Canary 25.x with API token and an untrusted HTTPS certificate
    .\Benchmark-CanaryHistorian.ps1 `
        -Server "https://canary-server:55236" `
        -ApiToken "YOUR-TOKEN" `
        -InsecureSkipCertificateCheck

.EXAMPLE
    # Include Canary's literal {Diagnostics} tags too
    .\Benchmark-CanaryHistorian.ps1 `
        -Server "http://localhost:55235" `
        -IncludeDiagnostics
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Server,

    [string]$ApiToken = "",
    [string]$AccessToken = "",
    [string]$UserToken = "",

    [string]$Path = "",

    [ValidateRange(1, 100000)]
    [int]$BrowsePageSize = 10000,

    [ValidateRange(1, 1000)]
    [int]$ContextBatchSize = 250,

    [ValidateRange(1, 1000)]
    [int]$CountBatchSize = 100,

    # Canary 23.x cannot represent one absolute TimeSpan over 1000 days.
    # Keep this <= 999 so the same request works on old and new versions.
    [ValidateRange(1, 999)]
    [int]$CountBucketDays = 365,

    [ValidateRange(1, 500)]
    [int]$BenchmarkTags = 20,

    [ValidateRange(1, 1000000)]
    [int]$BenchmarkMaxSizePerTag = 25000,

    [ValidateRange(1, 100)]
    [int]$BenchmarkPages = 2,

    [ValidateRange(0, 20)]
    [int]$RetryCount = 5,

    [ValidateRange(100, 60000)]
    [int]$RetryBaseDelayMs = 1000,

    [switch]$IncludeDiagnostics,

    [switch]$InsecureSkipCertificateCheck,

    [string]$OutputDirectory = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ============================================================================
# Initialization
# ============================================================================

$authOptions = @(
    @(
        $ApiToken,
        $AccessToken,
        $UserToken
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

if (@($authOptions).Count -gt 1) {
    throw "Specify only one of -ApiToken, -AccessToken, or -UserToken."
}

$BaseUrl = "$($Server.TrimEnd('/'))/api/v2"
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location) "CanaryBenchmark-$runStamp"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$LogFile = Join-Path $OutputDirectory "benchmark-$runStamp.log"
$SummaryFile = Join-Path $OutputDirectory "benchmark-summary.json"
$InventoryFile = Join-Path $OutputDirectory "tag-inventory.csv"
$ExcludedFile = Join-Path $OutputDirectory "excluded-tags.csv"
$BadContextFile = Join-Path $OutputDirectory "bad-context-tags.csv"
$BadCountFile = Join-Path $OutputDirectory "bad-count-tags.csv"
$NoCountFile = Join-Path $OutputDirectory "tags-without-count.csv"

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if ($InsecureSkipCertificateCheck -and $PSVersionTable.PSVersion.Major -lt 7) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("PHASE", "INFO", "OK", "DATA", "WARN", "RETRY", "ERROR", "SKIP")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "$timestamp [$Level] $Message"

    $color = switch ($Level) {
        "PHASE" { "Cyan" }
        "INFO"  { "Gray" }
        "OK"    { "Green" }
        "DATA"  { "White" }
        "WARN"  { "Yellow" }
        "RETRY" { "Magenta" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkYellow" }
        default  { "Gray" }
    }

    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Log -Level "PHASE" -Message ("=" * 68)
    Write-Log -Level "PHASE" -Message $Title
    Write-Log -Level "PHASE" -Message ("=" * 68)
}

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return "n/a"
    }

    $ts = [TimeSpan]::FromSeconds($Seconds)

    if ($ts.TotalDays -ge 1) {
        return ("{0:N2} days ({1:00}:{2:00}:{3:00})" -f $ts.TotalDays, $ts.Hours, $ts.Minutes, $ts.Seconds)
    }

    return ("{0:00}:{1:00}:{2:00}" -f [Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Test-Continuation {
    param($Continuation)

    if ($null -eq $Continuation) {
        return $false
    }

    foreach ($item in @($Continuation)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
            return $true
        }
    }

    return $false
}

function Get-Batches {
    param(
        [object[]]$Items,
        [int]$Size
    )

    $Items = @($Items)
    $itemCount = @($Items).Count

    if ($itemCount -eq 0) {
        return
    }

    for ($i = 0; $i -lt $itemCount; $i += $Size) {
        $last = [Math]::Min($i + $Size - 1, $itemCount - 1)
        ,@($Items[$i..$last])
    }
}

function Get-AuthDescription {
    if (-not [string]::IsNullOrWhiteSpace($ApiToken)) {
        return "apiToken"
    }

    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
        return "accessToken"
    }

    if (-not [string]::IsNullOrWhiteSpace($UserToken)) {
        return "userToken"
    }

    return "anonymous"
}

function Add-Authentication {
    param([hashtable]$Body)

    if (-not [string]::IsNullOrWhiteSpace($ApiToken)) {
        $Body["apiToken"] = $ApiToken
    }
    elseif (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
        $Body["accessToken"] = $AccessToken
    }
    elseif (-not [string]::IsNullOrWhiteSpace($UserToken)) {
        $Body["userToken"] = $UserToken
    }
}

function Test-TransientErrorText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return $Text -match '(?i)(timeout|timed out|temporary|busy|unavailable|connection|reset|throttl|too many requests|service unavailable|bad gateway|gateway timeout|\b429\b|\b502\b|\b503\b|\b504\b)'
}

function Test-TagSpecificError {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return $Text -match '(?i)(tag does not exist|does not have access to tag|user does not have access to tag)'
}

function Get-RetryDelayMs {
    param([int]$Attempt)

    $power = [Math]::Pow(2, [Math]::Max(0, $Attempt - 1))
    $base = [Math]::Min(30000, $RetryBaseDelayMs * $power)
    $jitter = Get-Random -Minimum 0 -Maximum ([Math]::Max(2, [int]($RetryBaseDelayMs / 2)))
    return [int]($base + $jitter)
}

function Invoke-Canary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $true)]
        [hashtable]$Body,

        [switch]$AllowApiError
    )

    $requestBody = @{}
    foreach ($key in $Body.Keys) {
        $requestBody[$key] = $Body[$key]
    }

    Add-Authentication -Body $requestBody

    $json = $requestBody | ConvertTo-Json -Depth 20 -Compress
    $maxAttempts = $RetryCount + 1

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $requestParams = @{
                Uri         = "$BaseUrl/$Endpoint"
                Method      = "POST"
                ContentType = "application/json"
                Body        = $json
            }

            if ($PSVersionTable.PSVersion.Major -lt 6) {
                $requestParams["UseBasicParsing"] = $true
            }

            if ($InsecureSkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 7) {
                $requestParams["SkipCertificateCheck"] = $true
            }

            $response = Invoke-WebRequest @requestParams
            $sw.Stop()

            $content = [string]$response.Content

            if ($content.TrimStart().StartsWith("<")) {
                throw [System.InvalidOperationException]::new(
                    "Endpoint returned HTML instead of JSON. This usually means the server/port points to Axiom or another web application rather than the Canary Views Read API. Endpoint: $BaseUrl/$Endpoint"
                )
            }

            try {
                $parsed = $content | ConvertFrom-Json
            }
            catch {
                throw [System.InvalidOperationException]::new(
                    "Could not parse Canary response as JSON. Endpoint: $Endpoint. Response: $content"
                )
            }

            $statusCode = [string]$parsed.statusCode
            $errorText = ""

            if ($null -ne $parsed.errors) {
                $errorText = (@($parsed.errors) -join "; ")
            }

            if (-not [string]::IsNullOrWhiteSpace($statusCode) -and $statusCode -ne "Good") {
                if ((Test-TransientErrorText $errorText) -and $attempt -lt $maxAttempts) {
                    $delay = Get-RetryDelayMs -Attempt $attempt
                    Write-Log -Level "RETRY" -Message "$Endpoint returned '$statusCode' on attempt $attempt/$maxAttempts. Retrying in $delay ms. $errorText"
                    Start-Sleep -Milliseconds $delay
                    continue
                }

                if (-not $AllowApiError) {
                    throw "Canary returned status '$statusCode': $errorText"
                }
            }

            return [PSCustomObject]@{
                Data          = $parsed
                Seconds       = $sw.Elapsed.TotalSeconds
                ResponseBytes = [System.Text.Encoding]::UTF8.GetByteCount($content)
                Attempts      = $attempt
            }
        }
        catch {
            if ($sw.IsRunning) {
                $sw.Stop()
            }

            $message = $_.Exception.Message

            # Wrong endpoint, bad JSON, auth/configuration errors, etc. should not be retried endlessly.
            $nonRetryable = (
                $message -match '(?i)(returned HTML instead of JSON|Could not parse Canary response as JSON|401|403|404|unauthori|forbidden)'
            )

            if ($nonRetryable -or $attempt -ge $maxAttempts) {
                throw
            }

            $delay = Get-RetryDelayMs -Attempt $attempt
            Write-Log -Level "RETRY" -Message "$Endpoint request failed on attempt $attempt/$maxAttempts. Retrying in $delay ms. $message"
            Start-Sleep -Milliseconds $delay
        }
    }

    throw "Unexpected retry loop termination for endpoint '$Endpoint'."
}

function Get-PointValue {
    param($Point)

    if ($null -eq $Point) {
        return $null
    }

    # Older API responses may represent TVQs as arrays: [timestamp, value, quality].
    if ($Point -is [System.Array]) {
        if ($Point.Count -ge 2) {
            return $Point[1]
        }
        return $null
    }

    $valueProperty = $Point.PSObject.Properties["v"]
    if ($null -ne $valueProperty) {
        return $valueProperty.Value
    }

    return $null
}

# ============================================================================
# Resilient tag-context retrieval
# ============================================================================

$badContextTags = [System.Collections.Generic.List[object]]::new()
$badCountTags = [System.Collections.Generic.List[object]]::new()

function Get-CanaryTagContextResilient {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Tags
    )

    $Tags = @($Tags)
    $tagCount = @($Tags).Count

    if ($tagCount -eq 0) {
        return
    }

    $result = Invoke-Canary -Endpoint "getTagContext" -Body @{
        tags = @($Tags)
    } -AllowApiError

    if (([string]$result.Data.statusCode) -eq "Good") {
        foreach ($item in @($result.Data.data)) {
            $oldest = $null
            $latest = $null

            if ($item.tagContext.oldestTimeStamp) {
                $oldest = [DateTimeOffset]::Parse([string]$item.tagContext.oldestTimeStamp)
            }

            if ($item.tagContext.latestTimeStamp) {
                $latest = [DateTimeOffset]::Parse([string]$item.tagContext.latestTimeStamp)
            }

            [PSCustomObject]@{
                Tag    = [string]$item.tagName
                Oldest = $oldest
                Latest = $latest
                Count  = $null
            }
        }

        return
    }

    $errorText = (@($result.Data.errors) -join "; ")

    if (-not (Test-TagSpecificError $errorText)) {
        throw "getTagContext failed with a systemic API error. Tags will not be marked bad. Canary response: $errorText"
    }

    if ($tagCount -eq 1) {
        $tag = [string]$Tags[0]
        Write-Log -Level "SKIP" -Message "Context unavailable: $tag"

        $badContextTags.Add([PSCustomObject]@{
            Tag   = $tag
            Error = $errorText
        })
        return
    }

    $middle = [int][Math]::Floor($tagCount / 2)
    $left = @($Tags[0..($middle - 1)])
    $right = @($Tags[$middle..($tagCount - 1)])

    Get-CanaryTagContextResilient -Tags $left
    Get-CanaryTagContextResilient -Tags $right
}

# ============================================================================
# Resilient Count retrieval using explicit short aggregate buckets
# ============================================================================

function Get-CanaryTagCountsResilient {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Tags,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$StartTime,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$EndTime
    )

    $Tags = @($Tags)
    $tagCount = @($Tags).Count

    if ($tagCount -eq 0) {
        return
    }

    $interval = "{0}.00:00:00" -f $CountBucketDays
    $spanDays = [Math]::Max(1.0, ($EndTime - $StartTime).TotalDays)
    $expectedBuckets = [int][Math]::Ceiling($spanDays / $CountBucketDays) + 2
    $countMaxSize = [Math]::Max(10, [Math]::Min(10000, $expectedBuckets))

    $countTotals = @{}
    foreach ($tag in $Tags) {
        $countTotals[[string]$tag] = 0.0
    }

    $hasValue = @{}
    $continuation = $null
    $page = 0

    do {
        $page++

        $body = @{
            tags              = @($Tags)
            startTime         = $StartTime.ToString("o")
            endTime           = $EndTime.ToString("o")
            aggregateName     = "Count"
            aggregateInterval = $interval
            includeQuality    = $false
            maxSize           = $countMaxSize
        }

        if (Test-Continuation $continuation) {
            $body["continuation"] = $continuation
        }

        $result = Invoke-Canary -Endpoint "getTagData2" -Body $body -AllowApiError

        if (([string]$result.Data.statusCode) -ne "Good") {
            $errorText = (@($result.Data.errors) -join "; ")

            # This is important. Do not recursively turn a request/version/configuration
            # problem into thousands of fake "bad tag" results.
            if (-not (Test-TagSpecificError $errorText)) {
                throw "Count request failed with a systemic API error. No tags will be marked bad. Canary response: $errorText"
            }

            if ($tagCount -eq 1) {
                $tag = [string]$Tags[0]
                Write-Log -Level "SKIP" -Message "Count unavailable: $tag"
                $badCountTags.Add([PSCustomObject]@{
                    Tag   = $tag
                    Error = $errorText
                })
                return
            }

            $middle = [int][Math]::Floor($tagCount / 2)
            $left = @($Tags[0..($middle - 1)])
            $right = @($Tags[$middle..($tagCount - 1)])

            Get-CanaryTagCountsResilient -Tags $left -StartTime $StartTime -EndTime $EndTime
            Get-CanaryTagCountsResilient -Tags $right -StartTime $StartTime -EndTime $EndTime
            return
        }

        if ($null -ne $result.Data.data) {
            foreach ($tag in $Tags) {
                $tagName = [string]$tag
                $property = $result.Data.data.PSObject.Properties[$tagName]

                if ($null -eq $property) {
                    continue
                }

                foreach ($point in @($property.Value)) {
                    $value = Get-PointValue -Point $point
                    if ($null -ne $value -and "$value" -ne "") {
                        $countTotals[$tagName] += [double]$value
                        $hasValue[$tagName] = $true
                    }
                }
            }
        }

        $continuation = $result.Data.continuation

        if ($page -gt 10000) {
            throw "Count continuation exceeded 10,000 pages for one batch. Aborting to prevent an infinite loop."
        }
    }
    while (Test-Continuation $continuation)

    foreach ($tag in $Tags) {
        $tagName = [string]$tag

        if ($hasValue.ContainsKey($tagName)) {
            [PSCustomObject]@{
                Tag   = $tagName
                Count = [double]$countTotals[$tagName]
            }
        }
    }
}

# ============================================================================
# Header
# ============================================================================

Write-Host ""
Write-Host "Canary Historian Read API Benchmark" -ForegroundColor Cyan
Write-Host "Server:         $Server" -ForegroundColor Gray
Write-Host "API:            $BaseUrl" -ForegroundColor Gray
Write-Host "Authentication: $(Get-AuthDescription)" -ForegroundColor Gray
Write-Host "PowerShell:     $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host "Output:         $OutputDirectory" -ForegroundColor Gray
Write-Host "Count buckets:  $CountBucketDays day(s)" -ForegroundColor Gray

if ($IncludeDiagnostics) {
    Write-Host "Diagnostics:    INCLUDED" -ForegroundColor Yellow
}
else {
    Write-Host "Diagnostics:    EXCLUDING literal {Diagnostics} paths" -ForegroundColor Green
}

if ($InsecureSkipCertificateCheck) {
    Write-Log -Level "WARN" -Message "TLS certificate validation is disabled for this process."
}

# ============================================================================
# Phase 1: Browse
# ============================================================================

Write-Section "PHASE 1 - Browse all accessible tags"

$browseWatch = [System.Diagnostics.Stopwatch]::StartNew()
$allTagsList = [System.Collections.Generic.List[string]]::new()
$continuation = $null
$browsePage = 0

try {
    do {
        $browsePage++

        $body = @{
            path    = $Path
            deep    = $true
            search  = ""
            maxSize = $BrowsePageSize
        }

        if (Test-Continuation $continuation) {
            $body["continuation"] = $continuation
        }

        $result = Invoke-Canary -Endpoint "browseTags" -Body $body
        $pageTags = @($result.Data.tags)

        foreach ($tag in $pageTags) {
            $allTagsList.Add([string]$tag)
        }

        Write-Log -Level "DATA" -Message ("Browse page {0}: {1:N0} tags in {2:N2}s, total {3:N0}" -f $browsePage, $pageTags.Count, $result.Seconds, $allTagsList.Count)
        $continuation = $result.Data.continuation
    }
    while (Test-Continuation $continuation)
}
catch {
    Write-Log -Level "ERROR" -Message $_.Exception.Message
    throw
}
finally {
    $browseWatch.Stop()
}

$allTags = @($allTagsList | Sort-Object -Unique)

if ($allTags.Count -eq 0) {
    throw "browseTags returned zero tags."
}

Write-Log -Level "OK" -Message ("Browse complete: {0:N0} unique tags in {1:N2}s." -f $allTags.Count, $browseWatch.Elapsed.TotalSeconds)

$excludedTags = @()

if (-not $IncludeDiagnostics) {
    $excludedTags = @(
        $allTags |
        Where-Object { $_ -match '\{Diagnostics\}' } |
        ForEach-Object {
            [PSCustomObject]@{
                Tag    = $_
                Reason = "Literal {Diagnostics} path"
            }
        }
    )

    $includedTags = @($allTags | Where-Object { $_ -notmatch '\{Diagnostics\}' })
}
else {
    $includedTags = @($allTags)
}

if ($excludedTags.Count -gt 0) {
    $excludedTags | Export-Csv -LiteralPath $ExcludedFile -NoTypeInformation -Encoding UTF8
    Write-Log -Level "INFO" -Message ("Excluded {0:N0} literal {{Diagnostics}} tags. Remaining: {1:N0}." -f $excludedTags.Count, $includedTags.Count)
}
else {
    Write-Log -Level "INFO" -Message ("No tags excluded. Benchmarking {0:N0} tags." -f $includedTags.Count)
}

if ($includedTags.Count -eq 0) {
    throw "No tags remain after filtering."
}

# ============================================================================
# Phase 2: Tag context
# ============================================================================

Write-Section "PHASE 2 - Resolve oldest/latest history for each tag"

$contextWatch = [System.Diagnostics.Stopwatch]::StartNew()
$contexts = [System.Collections.Generic.List[object]]::new()
$contextProcessed = 0

foreach ($batch in Get-Batches -Items $includedTags -Size $ContextBatchSize) {
    $batch = @($batch)
    try {
        $batchContexts = @(Get-CanaryTagContextResilient -Tags @($batch))

        foreach ($item in $batchContexts) {
            $contexts.Add($item)
        }
    }
    catch {
        Write-Log -Level "ERROR" -Message $_.Exception.Message
        throw
    }

    $contextProcessed += @($batch).Count
    Write-Log -Level "INFO" -Message ("Context: {0:N0}/{1:N0} checked, {2:N0} valid, {3:N0} skipped." -f $contextProcessed, $includedTags.Count, $contexts.Count, $badContextTags.Count)
}

$contextWatch.Stop()

if ($badContextTags.Count -gt 0) {
    $badContextTags | Export-Csv -LiteralPath $BadContextFile -NoTypeInformation -Encoding UTF8
}

$validContexts = @(
    $contexts |
    Where-Object { $null -ne $_.Oldest -and $null -ne $_.Latest }
)

if ($validContexts.Count -eq 0) {
    throw "No tags with valid historical timestamps were found."
}

$oldestContext = $validContexts | Sort-Object Oldest | Select-Object -First 1
$latestContext = $validContexts | Sort-Object Latest -Descending | Select-Object -First 1
$globalOldest = [DateTimeOffset]$oldestContext.Oldest
$globalLatest = [DateTimeOffset]$latestContext.Latest

Write-Log -Level "OK" -Message ("Context complete in {0:N2}s. {1:N0} tags with history, {2:N0} skipped." -f $contextWatch.Elapsed.TotalSeconds, $validContexts.Count, $badContextTags.Count)
Write-Log -Level "DATA" -Message "Oldest history: $($globalOldest.ToString('o')) | $($oldestContext.Tag)"
Write-Log -Level "DATA" -Message "Latest history: $($globalLatest.ToString('o')) | $($latestContext.Tag)"

# ============================================================================
# Phase 3: Count TVQs
# ============================================================================

Write-Section "PHASE 3 - Estimate raw TVQ count with explicit $CountBucketDays-day Count buckets"

$countWatch = [System.Diagnostics.Stopwatch]::StartNew()
$countMap = @{}
$countProcessed = 0
$countPhaseSucceeded = $true
$countPhaseError = $null
$contextTags = @($validContexts.Tag)

try {
    foreach ($batch in Get-Batches -Items $contextTags -Size $CountBatchSize) {
        $batch = @($batch)
        $counts = @(
            Get-CanaryTagCountsResilient -Tags @($batch) -StartTime $globalOldest -EndTime $globalLatest
        )

        foreach ($item in $counts) {
            $countMap[[string]$item.Tag] = [double]$item.Count
        }

        $countProcessed += @($batch).Count
        Write-Log -Level "INFO" -Message ("Count: {0:N0}/{1:N0} checked, {2:N0} counted, {3:N0} skipped." -f $countProcessed, $contextTags.Count, $countMap.Count, $badCountTags.Count)
    }
}
catch {
    $countPhaseSucceeded = $false
    $countPhaseError = $_.Exception.Message
    Write-Log -Level "ERROR" -Message "Count phase stopped because Canary returned a systemic error: $countPhaseError"
    Write-Log -Level "WARN" -Message "Raw throughput benchmarking will continue. Full-historian TVQ/time estimates will be unavailable unless Count succeeds."
}
finally {
    $countWatch.Stop()
}

foreach ($context in $contexts) {
    if ($countMap.ContainsKey([string]$context.Tag)) {
        $context.Count = [double]$countMap[[string]$context.Tag]
    }
}

if ($badCountTags.Count -gt 0) {
    $badCountTags | Export-Csv -LiteralPath $BadCountFile -NoTypeInformation -Encoding UTF8
}

$tagsWithoutCount = @(
    $validContexts |
    Where-Object { -not $countMap.ContainsKey([string]$_.Tag) } |
    Select-Object Tag, Oldest, Latest
)

if ($tagsWithoutCount.Count -gt 0) {
    $tagsWithoutCount | Export-Csv -LiteralPath $NoCountFile -NoTypeInformation -Encoding UTF8
}

$countableContexts = @(
    $contexts |
    Where-Object { $null -ne $_.Count }
)

$totalTVQs = $null

if ($countableContexts.Count -gt 0) {
    $totalTVQs = ($countableContexts | Measure-Object Count -Sum).Sum
}

if ($countPhaseSucceeded) {
    Write-Log -Level "OK" -Message ("Count phase complete in {0:N2}s. Counted {1:N0}/{2:N0} tags." -f $countWatch.Elapsed.TotalSeconds, $countableContexts.Count, $validContexts.Count)

    if ($null -ne $totalTVQs) {
        Write-Log -Level "DATA" -Message ("Estimated raw TVQs across included tags: {0:N0}" -f $totalTVQs)
    }
}

# Write inventory before benchmarking so it survives a later failure.
$contexts |
    Sort-Object Tag |
    Export-Csv -LiteralPath $InventoryFile -NoTypeInformation -Encoding UTF8

Write-Log -Level "INFO" -Message "Tag inventory: $InventoryFile"

# ============================================================================
# Phase 4: Raw benchmark
# ============================================================================

Write-Section "PHASE 4 - Raw getTagData2 throughput benchmark"

if ($countableContexts.Count -gt 0) {
    $sampleTags = @(
        $countableContexts |
        Where-Object { $_.Count -gt 0 } |
        Sort-Object Count -Descending |
        Select-Object -First $BenchmarkTags
    )
    $sampleMode = "highest TVQ counts"
}
else {
    # Count may be unavailable on a particular server/configuration. We can still benchmark
    # raw reads by choosing tags with the longest visible history.
    $sampleTags = @(
        $validContexts |
        Sort-Object @{ Expression = { ($_.Latest - $_.Oldest).TotalSeconds }; Descending = $true } |
        Select-Object -First $BenchmarkTags
    )
    $sampleMode = "longest visible history (Count unavailable)"
}

if ($sampleTags.Count -eq 0) {
    throw "No tags with historical data were available for the raw benchmark."
}

Write-Log -Level "INFO" -Message "Benchmark selection: $sampleMode."
Write-Log -Level "INFO" -Message ("Benchmarking {0:N0} tags, up to {1:N0} TVQs/tag/page for {2:N0} page(s)." -f $sampleTags.Count, $BenchmarkMaxSizePerTag, $BenchmarkPages)

foreach ($tag in $sampleTags) {
    if ($null -ne $tag.Count) {
        Write-Log -Level "DATA" -Message ("Sample | {0:N0} TVQs | {1}" -f $tag.Count, $tag.Tag)
    }
    else {
        Write-Log -Level "DATA" -Message ("Sample | {0} -> {1} | {2}" -f $tag.Oldest, $tag.Latest, $tag.Tag)
    }
}

$sampleOldest = ($sampleTags | Sort-Object Oldest | Select-Object -First 1).Oldest
$sampleLatest = ($sampleTags | Sort-Object Latest -Descending | Select-Object -First 1).Latest
$benchmarkTagNames = @($sampleTags.Tag)

$continuation = $null
$totalBenchmarkPoints = 0L
$totalBenchmarkBytes = 0L
$totalBenchmarkApiSeconds = 0.0
$totalBenchmarkWallSeconds = 0.0
$rawWatch = [System.Diagnostics.Stopwatch]::StartNew()

for ($page = 1; $page -le $BenchmarkPages; $page++) {
    $pageWall = [System.Diagnostics.Stopwatch]::StartNew()

    $body = @{
        tags           = $benchmarkTagNames
        startTime      = ([DateTimeOffset]$sampleOldest).ToString("o")
        endTime        = ([DateTimeOffset]$sampleLatest).ToString("o")
        includeQuality = $true
        maxSize        = $BenchmarkMaxSizePerTag
    }

    if (Test-Continuation $continuation) {
        $body["continuation"] = $continuation
    }

    try {
        $result = Invoke-Canary -Endpoint "getTagData2" -Body $body
    }
    catch {
        Write-Log -Level "ERROR" -Message "Raw benchmark page $page failed: $($_.Exception.Message)"
        throw
    }

    $pageWall.Stop()
    $pagePoints = 0L

    if ($null -ne $result.Data.data) {
        foreach ($property in $result.Data.data.PSObject.Properties) {
            $pagePoints += @($property.Value).Count
        }
    }

    $totalBenchmarkPoints += $pagePoints
    $totalBenchmarkBytes += $result.ResponseBytes
    $totalBenchmarkApiSeconds += $result.Seconds
    $totalBenchmarkWallSeconds += $pageWall.Elapsed.TotalSeconds

    $pageTvqRate = if ($result.Seconds -gt 0) { $pagePoints / $result.Seconds } else { 0 }
    $pageMb = $result.ResponseBytes / 1MB

    Write-Log -Level "DATA" -Message ("Raw page {0}: {1:N0} TVQs | {2:N2}s API | {3:N2}s wall | {4:N2} MB | {5:N0} TVQ/s" -f $page, $pagePoints, $result.Seconds, $pageWall.Elapsed.TotalSeconds, $pageMb, $pageTvqRate)

    $continuation = $result.Data.continuation

    if (-not (Test-Continuation $continuation)) {
        Write-Log -Level "INFO" -Message "No additional continuation returned after raw page $page."
        break
    }
}

$rawWatch.Stop()

if ($totalBenchmarkPoints -le 0 -or $totalBenchmarkApiSeconds -le 0) {
    throw "Raw benchmark returned no usable historical TVQs."
}

$apiPointsPerSecond = $totalBenchmarkPoints / $totalBenchmarkApiSeconds
$wallPointsPerSecond = if ($totalBenchmarkWallSeconds -gt 0) { $totalBenchmarkPoints / $totalBenchmarkWallSeconds } else { 0 }
$jsonMbPerSecond = ($totalBenchmarkBytes / 1MB) / $totalBenchmarkApiSeconds
$bytesPerPoint = $totalBenchmarkBytes / $totalBenchmarkPoints

$estimatedApiSeconds = $null
$estimatedWallSeconds = $null
$estimatedJsonGB = $null

if ($null -ne $totalTVQs -and $totalTVQs -gt 0) {
    $estimatedApiSeconds = $totalTVQs / $apiPointsPerSecond

    if ($wallPointsPerSecond -gt 0) {
        $estimatedWallSeconds = $totalTVQs / $wallPointsPerSecond
    }

    $estimatedJsonGB = ($totalTVQs * $bytesPerPoint) / 1GB
}

# ============================================================================
# Summary
# ============================================================================

Write-Section "CANARY HISTORIAN BENCHMARK RESULTS"

Write-Host ""
Write-Host "Historian" -ForegroundColor Cyan
Write-Host ("  Browsed tags:                 {0:N0}" -f $allTags.Count) -ForegroundColor White
Write-Host ("  Excluded {{Diagnostics}}:        {0:N0}" -f $excludedTags.Count) -ForegroundColor White
Write-Host ("  Included tags:                {0:N0}" -f $includedTags.Count) -ForegroundColor White
Write-Host ("  Tags with history:            {0:N0}" -f $validContexts.Count) -ForegroundColor White
Write-Host ("  Context tags skipped:         {0:N0}" -f $badContextTags.Count) -ForegroundColor White
Write-Host ("  Count tags skipped:           {0:N0}" -f $badCountTags.Count) -ForegroundColor White
Write-Host ("  Tags without Count result:    {0:N0}" -f $tagsWithoutCount.Count) -ForegroundColor White

Write-Host ""
Write-Host "Historical range" -ForegroundColor Cyan
Write-Host "  Oldest:                       $($globalOldest.ToString('o'))" -ForegroundColor White
Write-Host "  Latest:                       $($globalLatest.ToString('o'))" -ForegroundColor White

Write-Host ""
Write-Host "Count estimate" -ForegroundColor Cyan
Write-Host "  Aggregate interval:           $CountBucketDays day(s)" -ForegroundColor White
Write-Host "  Count phase succeeded:        $countPhaseSucceeded" -ForegroundColor $(if ($countPhaseSucceeded) { "Green" } else { "Yellow" })

if ($null -ne $totalTVQs) {
    Write-Host ("  Estimated total raw TVQs:     {0:N0}" -f $totalTVQs) -ForegroundColor Green
}
else {
    Write-Host "  Estimated total raw TVQs:     unavailable" -ForegroundColor Yellow
}

if (-not $countPhaseSucceeded -and -not [string]::IsNullOrWhiteSpace($countPhaseError)) {
    Write-Host "  Count error:                  $countPhaseError" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Raw benchmark" -ForegroundColor Cyan
Write-Host ("  Benchmark tags:               {0:N0}" -f $sampleTags.Count) -ForegroundColor White
Write-Host ("  Benchmark TVQs:               {0:N0}" -f $totalBenchmarkPoints) -ForegroundColor White
Write-Host ("  API duration:                 {0:N2} sec" -f $totalBenchmarkApiSeconds) -ForegroundColor White
Write-Host ("  Wall duration:                {0:N2} sec" -f $totalBenchmarkWallSeconds) -ForegroundColor White
Write-Host ("  API throughput:               {0:N0} TVQ/sec" -f $apiPointsPerSecond) -ForegroundColor Green
Write-Host ("  End-to-end request rate:      {0:N0} TVQ/sec" -f $wallPointsPerSecond) -ForegroundColor Green
Write-Host ("  JSON throughput:              {0:N2} MB/sec" -f $jsonMbPerSecond) -ForegroundColor White
Write-Host ("  Approx JSON bytes / TVQ:      {0:N1}" -f $bytesPerPoint) -ForegroundColor White

Write-Host ""
Write-Host "Full historian estimate" -ForegroundColor Cyan

if ($null -ne $estimatedApiSeconds) {
    Write-Host ("  Estimated API-only time:      {0}" -f (Format-Duration $estimatedApiSeconds)) -ForegroundColor Green
    Write-Host ("  Estimated end-to-end time:    {0}" -f (Format-Duration $estimatedWallSeconds)) -ForegroundColor Green
    Write-Host ("  Estimated JSON transferred:   {0:N2} GB" -f $estimatedJsonGB) -ForegroundColor Green
}
else {
    Write-Host "  Time/size estimate:           unavailable because Count did not complete" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Artifacts" -ForegroundColor Cyan
Write-Host "  Log:                          $LogFile" -ForegroundColor Gray
Write-Host "  Inventory:                    $InventoryFile" -ForegroundColor Gray

if ($excludedTags.Count -gt 0) {
    Write-Host "  Excluded tags:                $ExcludedFile" -ForegroundColor Gray
}

if ($badContextTags.Count -gt 0) {
    Write-Host "  Bad context tags:             $BadContextFile" -ForegroundColor Gray
}

if ($badCountTags.Count -gt 0) {
    Write-Host "  Bad count tags:               $BadCountFile" -ForegroundColor Gray
}

if ($tagsWithoutCount.Count -gt 0) {
    Write-Host "  Tags without count:           $NoCountFile" -ForegroundColor Gray
}

$summary = [ordered]@{
    generatedAt                 = (Get-Date).ToString("o")
    server                      = $Server
    apiBaseUrl                  = $BaseUrl
    authentication             = Get-AuthDescription
    powershellVersion           = [string]$PSVersionTable.PSVersion
    diagnosticsIncluded        = [bool]$IncludeDiagnostics
    countBucketDays            = $CountBucketDays
    browsedTags                = $allTags.Count
    excludedDiagnosticsTags    = $excludedTags.Count
    includedTags               = $includedTags.Count
    tagsWithHistory             = $validContexts.Count
    contextTagsSkipped         = $badContextTags.Count
    countTagsSkipped           = $badCountTags.Count
    tagsWithoutCount           = $tagsWithoutCount.Count
    oldest                     = $globalOldest.ToString("o")
    latest                     = $globalLatest.ToString("o")
    countPhaseSucceeded        = $countPhaseSucceeded
    countPhaseError            = $countPhaseError
    estimatedTotalRawTVQs      = $totalTVQs
    benchmarkSelection         = $sampleMode
    benchmarkTags              = $sampleTags.Count
    benchmarkPagesRequested    = $BenchmarkPages
    benchmarkTVQs              = $totalBenchmarkPoints
    benchmarkApiSeconds        = $totalBenchmarkApiSeconds
    benchmarkWallSeconds       = $totalBenchmarkWallSeconds
    apiTVQsPerSecond           = $apiPointsPerSecond
    wallTVQsPerSecond          = $wallPointsPerSecond
    jsonMBPerSecond            = $jsonMbPerSecond
    approximateJsonBytesPerTVQ = $bytesPerPoint
    estimatedApiSeconds        = $estimatedApiSeconds
    estimatedWallSeconds       = $estimatedWallSeconds
    estimatedJsonGB            = $estimatedJsonGB
    outputDirectory            = $OutputDirectory
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $SummaryFile -Encoding UTF8

Write-Log -Level "OK" -Message "Benchmark complete. Summary written to $SummaryFile"
Write-Host ""
