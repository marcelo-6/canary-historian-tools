<#
.SYNOPSIS
    Robust, resumable, full-history exporter for the Canary Labs Views Read API.

.DESCRIPTION
    PURPOSE
    =======
    This script creates a lossless bulk export of all accessible historical Canary tag data.
    It is designed for large historians, long-running unattended exports, older Canary 23.x
    servers, current Canary 25.x servers, and Windows PowerShell 5.1 as well as PowerShell 7+.

    The exporter stores Canary's raw getTagData2 JSON response pages during extraction. This keeps
    the historian-facing portion of the workflow focused on API reads. A separate converter can turn
    the completed JSON/JSON.GZ pages into CSV, CSV.GZ, per-page ZIP files, or one ZIP archive later.

    HIGH-LEVEL WORKFLOW
    ===================
    1. Browse tags
       * Calls browseTags and follows Canary continuation until all accessible tags are discovered.
       * By default excludes only tags containing the literal text {Diagnostics}.
       * Names containing words such as System.Diagnostics remain included unless the
         -ExcludeRegex parameter is changed.

    2. Resolve historical context
       * Calls getTagContext in batches to determine each tag's oldest/latest historical timestamp.
       * If a context batch fails because of one or more tag-specific problems, the batch is split
         recursively until the individual problematic tag(s) are identified.
       * Tags that fail context resolution become individual fallback batches and receive one direct
         raw-history export attempt.

    3. Count expected TVQs (optional)
       * Uses Canary's Count aggregate only for progress and ETA estimation.
       * Uses explicit Count buckets (365 days by default). Canary 23.x rejects some absolute
         TimeSpan values over 1000 days.
       * If Count is unavailable systemically, the raw export can still proceed.

    4. Export raw history
       * Calls getTagData2 without aggregate parameters, which requests raw historical TVQs.
       * Normal resolved tags are grouped into B batches (B00001, B00002, ...).
       * Context-unresolved fallback tags are attempted one-at-a-time as U batches
         (U00001, U00002, ... within the same global batch numbering sequence).
       * Each Canary response is one page. If Canary returns continuation tokens, the next request
         uses those tokens and produces the next page.

    BATCH AND PAGE DIRECTORY MEANING
    ================================
    data\B00001\page-000001.json
        B = normal/resolved batch, usually containing -ExportBatchSize tags.
        00001 = global batch identifier.
        page-000001 = first getTagData2 response for that batch.

    data\B00001\page-000002.json
        The continuation response following page 1.

    data\U00873\page-000001.json
        U = context-fallback batch containing exactly one tag whose getTagContext lookup failed.
        The U number is the global batch identifier.

    A batch is complete when Canary no longer returns continuation tokens.

    OUTPUT AND CHECKPOINTING
    ========================
    <OutputDirectory>\
      state.json                Durable resume checkpoint and per-batch state.
      pages.jsonl               Append-only audit record for successfully committed pages.
      tag-inventory.csv         Tag context/count inventory.
      export-plan.csv           Per-tag assignment to a resolved or fallback raw export batch.
      excluded-tags.csv         Tags removed by -ExcludeRegex.
      unavailable-tags.csv      Context-unresolved tags discovered during setup.
      tags-without-count.csv    Tags for which Count could not be obtained.
      failed-batches.csv        Present only when batches remain failed.
      summary.json              Final/current export summary.
      logs\                     Human-readable and structured JSONL logs.
      data\Bxxxxx\page-*.json  Actual lossless Canary raw history pages.
      data\Uxxxxx\page-*.json  Fallback tag history pages when available.

    Every data page is written atomically:
      1. A temporary file is created in the destination batch directory.
      2. The complete response is written and flushed.
      3. The temporary file is renamed to its final page name.
      4. Only after the final data file exists is state.json checkpointed.

    This ordering keeps state.json aligned with committed data files. Re-running the same command
    with the same OutputDirectory resumes from the last committed continuation.

    RAW JSON VS GZIP
    ================
    The exporter defaults to -OutputCompression None. Raw JSON keeps historian access on the critical
    path, and compression can run later without touching Canary again.

      None     -> page-000001.json
      Fastest  -> page-000001.json.gz using fast gzip compression
      Optimal  -> page-000001.json.gz using optimal gzip compression

    Existing JSON and JSON.GZ pages can coexist when resuming an older export with a different
    storage setting. Checkpoint repair recognizes both formats.

    RETRIES AND PERMANENT FAILURES
    ==============================
    Transient HTTP/network/API failures use exponential backoff with jitter. With the defaults,
    retry waits grow approximately 2s, 4s, 8s, 16s, 32s, capped by -RetryMaxDelaySeconds.

    Known permanent failures skip repeated retries. Examples include:
      * authentication/authorization/not-found HTTP responses;
      * an inaccessible or missing tag;
      * Canary 23.x >1000-day absolute TimeSpan errors;
      * Canary error 0x800403F8 / "TagKey contains no TrendVectors".

    "TagKey contains no TrendVectors" means Canary can identify the tag metadata but has no trend
    vectors available to satisfy a historical read. The exporter classifies the condition as
    permanent immediately. For a U fallback batch, that tag is marked Unavailable after the first
    failed API request.

    AUTHENTICATION / CANARY VERSION COMPATIBILITY
    =============================================
    The same script supports:
      * anonymous Views endpoint, commonly http://server:55235 on Canary 23.x;
      * -AccessToken for older Views configurations;
      * -UserToken where configured;
      * -ApiToken for newer Canary versions;
      * HTTPS endpoint, commonly https://server:55236.

    Specify at most one token parameter. Tokens stay out of logs, state, manifests, and output files.

    PERFORMANCE NOTES
    =================
    * Large raw history responses use a compiled .NET metadata parser when available. It extracts
      only response status, exact TVQ count, and continuation metadata without converting a 30-60 MB
      JSON response into hundreds of thousands of PowerShell objects.
    * -MaxSizePerTag controls the maximum values requested per tag per API call. With the default
      ExportBatchSize=20 and MaxSizePerTag=25000, a high-volume page is roughly 500,000 TVQs.
      A fresh export can often use MaxSizePerTag=50000 for roughly 1,000,000 TVQs/page, subject to
      server/network capacity.
    * Enable hashes only when required. Hashing adds local I/O/CPU work.

    SAFETY / OPERATIONAL NOTES
    ==========================
    * The script uses only Canary Read API operations.
    * The script leaves existing finalized page files unchanged during normal extraction.
    * Ctrl+C, a PowerShell crash, network interruption, or host reboot can be recovered by rerunning
      the same command against the same OutputDirectory.
    * Leave state.json unchanged while an export is running.
    * For a uniform storage format, start a new OutputDirectory. For fastest recovery/resume, reuse
      the existing one and allow mixed legacy JSON.GZ plus new JSON pages.

.EXAMPLE
    # Canary 23.x anonymous Views endpoint, fastest raw JSON export
    .\Export-CanaryHistorian.ps1 `
        -Server "http://localhost:55235" `
        -OutputDirectory ".\CanaryFullExport"

.EXAMPLE
    # Canary 25.x secure endpoint with an API token and self-signed certificate
    .\Export-CanaryHistorian.ps1 `
        -Server "https://canary-server:55236" `
        -ApiToken "YOUR-TOKEN" `
        -OutputDirectory ".\CanaryFullExport" `
        -InsecureSkipCertificateCheck

.EXAMPLE
    # Fresh higher-throughput run targeting roughly 1M TVQs/page for full batches
    .\Export-CanaryHistorian.ps1 `
        -Server "http://localhost:55235" `
        -OutputDirectory ".\CanaryFullExport" `
        -MaxSizePerTag 50000

.NOTES
    Data payload: lossless Canary getTagData2 response pages.
    Default storage: raw UTF-8 JSON.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Server,

    [string]$ApiToken = "",
    [string]$AccessToken = "",
    [string]$UserToken = "",

    [string]$OutputDirectory = ".\CanaryExport",

    [string]$Path = "",

    # Exact default requirement: exclude any tag containing literal {Diagnostics}.
    [string]$ExcludeRegex = '\{Diagnostics\}',

    [int]$BrowsePageSize = 10000,
    [int]$ContextBatchSize = 250,
    [int]$CountBatchSize = 100,

    # Canary 23.x rejects some absolute TimeSpan values over 1000 days.
    # Keep this <= 999 so Count works across old and new Canary versions.
    [ValidateRange(1, 999)]
    [int]$CountBucketDays = 365,

    # Defaults based on the successful benchmark: 20 x 25,000 ~= 500,000 TVQs/page.
    # For a fresh export, -MaxSizePerTag 50000 typically targets ~1,000,000 TVQs/page.
    [int]$ExportBatchSize = 20,
    [int]$MaxSizePerTag = 25000,

    # Raw JSON is the default because historian extraction is the critical path.
    # Compression can be done after the historian has been fully extracted.
    # Fastest/Optimal keep the older direct-to-gzip behavior when desired.
    [ValidateSet("None", "Fastest", "Optimal")]
    [string]$OutputCompression = "None",

    # Disable only for troubleshooting. The fast parser avoids PowerShell
    # ConvertFrom-Json for large raw-history responses.
    [switch]$DisableFastRawParser,

    [int]$MaxAttempts = 6,
    [double]$RetryBaseDelaySeconds = 2.0,
    [double]$RetryMaxDelaySeconds = 45.0,

    # Used only when getTagContext rejects a browsed non-diagnostic tag.
    # Such tags are attempted individually.
    [string]$FallbackStartTime = "1900-01-01T00:00:00Z",

    [switch]$InsecureSkipCertificateCheck,
    [switch]$SkipCount,
    [switch]$ExcludeQuality,
    [switch]$EnableHashes,
    [switch]$RetryFailedOnly
)

$ErrorActionPreference = "Stop"

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

if ($ExportBatchSize -lt 1) { throw "ExportBatchSize must be >= 1." }
if ($MaxSizePerTag -lt 1) { throw "MaxSizePerTag must be >= 1." }
if ($MaxAttempts -lt 1) { throw "MaxAttempts must be >= 1." }
if ($ContextBatchSize -lt 1) { throw "ContextBatchSize must be >= 1." }
if ($CountBatchSize -lt 1) { throw "CountBatchSize must be >= 1." }

$BaseUrl = "$($Server.TrimEnd('/'))/api/v2"
$IncludeQuality = -not $ExcludeQuality

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$DataDirectory = Join-Path $OutputDirectory "data"
$LogsDirectory = Join-Path $OutputDirectory "logs"
$StatePath = Join-Path $OutputDirectory "state.json"
$InventoryPath = Join-Path $OutputDirectory "tag-inventory.csv"
$ExportPlanPath = Join-Path $OutputDirectory "export-plan.csv"
$ExportPlanFailurePath = Join-Path $OutputDirectory "export-plan-validation-failures.csv"
$ExcludedPath = Join-Path $OutputDirectory "excluded-tags.csv"
$UnavailablePath = Join-Path $OutputDirectory "unavailable-tags.csv"
$NoCountPath = Join-Path $OutputDirectory "tags-without-count.csv"
$FailedPath = Join-Path $OutputDirectory "failed-batches.csv"
$SummaryPath = Join-Path $OutputDirectory "summary.json"
$PageManifestPath = Join-Path $OutputDirectory "pages.jsonl"

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $LogsDirectory -Force | Out-Null

$RunStamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$script:TextLogPath = Join-Path $LogsDirectory "export-$RunStamp.log"
$script:EventLogPath = Join-Path $LogsDirectory "events-$RunStamp.jsonl"

# Force TLS 1.2 for Windows PowerShell 5.1 environments.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if ($InsecureSkipCertificateCheck -and $PSVersionTable.PSVersion.Major -lt 7) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Write-JsonUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "RETRY", "DATA", "DEBUG")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Event = "log",
        [hashtable]$Data
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $line = "$timestamp [$Level] $Message"

    $color = "Gray"
    switch ($Level) {
        "INFO"  { $color = "Cyan" }
        "OK"    { $color = "Green" }
        "WARN"  { $color = "Yellow" }
        "ERROR" { $color = "Red" }
        "RETRY" { $color = "Magenta" }
        "DATA"  { $color = "White" }
        "DEBUG" { $color = "DarkGray" }
    }

    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $script:TextLogPath -Value $line -Encoding UTF8

    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        level     = $Level
        event     = $Event
        message   = $Message
    }

    if ($null -ne $Data) {
        $record["data"] = $Data
    }

    $eventJson = ([PSCustomObject]$record | ConvertTo-Json -Depth 12 -Compress)
    Add-Content -LiteralPath $script:EventLogPath -Value $eventJson -Encoding UTF8
}

function Write-Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " CANARY HISTORIAN FULL EXPORT" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " Server:           $Server" -ForegroundColor Gray
    Write-Host " Authentication:   $(Get-AuthDescription)" -ForegroundColor Gray
    Write-Host " Output:           $OutputDirectory" -ForegroundColor Gray
    Write-Host " Exclude regex:    $ExcludeRegex" -ForegroundColor Gray
    Write-Host " Export batch:     $ExportBatchSize tags" -ForegroundColor Gray
    Write-Host " Max/tag/request:  $MaxSizePerTag TVQs" -ForegroundColor Gray
    Write-Host " Count buckets:    $CountBucketDays day(s)" -ForegroundColor Gray
    Write-Host " Output storage:   $(if ($OutputCompression -eq 'None') { 'raw JSON (.json)' } else { "gzip JSON (.json.gz, $OutputCompression)" })" -ForegroundColor Gray
    Write-Host " Include quality:  $IncludeQuality" -ForegroundColor Gray
    Write-Host " Resume state:     $StatePath" -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Test-Continuation {
    param($Continuation)

    if ($null -eq $Continuation) { return $false }

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
        [Parameter(Mandatory = $true)][int]$Size
    )

    if ($null -eq $Items -or $Items.Count -eq 0) { return }

    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        $last = [Math]::Min($i + $Size - 1, $Items.Count - 1)
        ,@($Items[$i..$last])
    }
}

function Get-UniqueStringsOrdinal {
    param([object[]]$Items)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $unique = New-Object System.Collections.ArrayList

    foreach ($item in @($Items)) {
        $value = [string]$item
        if ($seen.Add($value)) {
            [void]$unique.Add($value)
        }
    }

    @($unique | Sort-Object)
}


# A tiny compiled parser used only for large raw getTagData2 responses.
# It extracts statusCode, exact TVQ count, and continuation without building
# a 500k+ object PowerShell graph with ConvertFrom-Json.
$script:FastRawParserAvailable = $false

if (-not $DisableFastRawParser) {
    try {
        if (-not ("CanaryFastJson" -as [type])) {
            Add-Type -TypeDefinition @'
using System;

public sealed class CanaryFastMetadata
{
    public string StatusCode;
    public long PointCount;
    public string ContinuationJson;
}

public static class CanaryFastJson
{
    private static int SkipWs(string s, int i)
    {
        while (i < s.Length)
        {
            char c = s[i];
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
            i++;
        }
        return i;
    }

    private static int SkipString(string s, int i)
    {
        // i points at opening quote.
        i++;
        while (i < s.Length)
        {
            char c = s[i++];
            if (c == '\\')
            {
                if (i < s.Length) i++;
                continue;
            }
            if (c == '"') break;
        }
        return i;
    }

    private static int SkipContainer(string s, int i)
    {
        char open = s[i];
        char close = open == '{' ? '}' : ']';
        int curly = 0;
        int square = 0;

        for (; i < s.Length; i++)
        {
            char c = s[i];

            if (c == '"')
            {
                i = SkipString(s, i) - 1;
                continue;
            }

            if (c == '{') curly++;
            else if (c == '}')
            {
                curly--;
                if (open == '{' && curly == 0 && square == 0) return i + 1;
            }
            else if (c == '[') square++;
            else if (c == ']')
            {
                square--;
                if (open == '[' && square == 0 && curly == 0) return i + 1;
            }
        }

        return i;
    }

    private static int SkipValue(string s, int i)
    {
        i = SkipWs(s, i);
        if (i >= s.Length) return i;

        char c = s[i];
        if (c == '"') return SkipString(s, i);
        if (c == '{' || c == '[') return SkipContainer(s, i);

        while (i < s.Length)
        {
            c = s[i];
            if (c == ',' || c == ']' || c == '}') break;
            i++;
        }
        return i;
    }

    private static bool KeyEquals(string s, int quoteStart, int quoteEndExclusive, string key)
    {
        int len = quoteEndExclusive - quoteStart - 2;
        if (len != key.Length) return false;

        int p = quoteStart + 1;
        for (int i = 0; i < key.Length; i++)
        {
            if (s[p + i] != key[i]) return false;
        }
        return true;
    }

    private static string ReadSimpleStringValue(string s, int i)
    {
        i = SkipWs(s, i);
        if (i >= s.Length || s[i] != '"') return null;

        int start = i + 1;
        i++;
        bool escaped = false;

        while (i < s.Length)
        {
            char c = s[i];
            if (c == '\\')
            {
                escaped = true;
                i += 2;
                continue;
            }
            if (c == '"')
            {
                if (!escaped) return s.Substring(start, i - start);
                // statusCode is never escaped; fallback caller can fully parse
                // unusual content if this ever occurs.
                return null;
            }
            i++;
        }
        return null;
    }

    private static long CountArrayElements(string s, ref int i)
    {
        // i points at '['
        i++;
        i = SkipWs(s, i);

        if (i < s.Length && s[i] == ']')
        {
            i++;
            return 0;
        }

        long count = 0;
        while (i < s.Length)
        {
            i = SkipWs(s, i);
            if (i < s.Length && s[i] == ']')
            {
                i++;
                break;
            }

            count++;
            i = SkipValue(s, i);
            i = SkipWs(s, i);

            if (i < s.Length && s[i] == ',')
            {
                i++;
                continue;
            }

            if (i < s.Length && s[i] == ']')
            {
                i++;
                break;
            }
        }
        return count;
    }

    private static long CountDataObject(string s, int i, out int end)
    {
        long total = 0;
        end = i;

        if (i >= s.Length || s[i] != '{') return 0;
        i++;

        while (i < s.Length)
        {
            i = SkipWs(s, i);

            if (i < s.Length && s[i] == '}')
            {
                end = i + 1;
                return total;
            }

            if (i < s.Length && s[i] == ',')
            {
                i++;
                continue;
            }

            if (i >= s.Length || s[i] != '"')
            {
                end = SkipValue(s, i);
                return total;
            }

            i = SkipString(s, i); // tag name
            i = SkipWs(s, i);

            if (i < s.Length && s[i] == ':') i++;
            i = SkipWs(s, i);

            if (i < s.Length && s[i] == '[')
            {
                total += CountArrayElements(s, ref i);
            }
            else
            {
                i = SkipValue(s, i);
            }

            i = SkipWs(s, i);
            if (i < s.Length && s[i] == ',') i++;
        }

        end = i;
        return total;
    }

    private static string ExtractJsonValue(string s, int start, int end)
    {
        if (start < 0 || end <= start || end > s.Length) return null;
        return s.Substring(start, end - start);
    }

    public static CanaryFastMetadata Parse(string json)
    {
        CanaryFastMetadata result = new CanaryFastMetadata();
        result.PointCount = 0;
        result.ContinuationJson = null;

        if (String.IsNullOrEmpty(json)) return result;

        int i = SkipWs(json, 0);
        if (i >= json.Length || json[i] != '{') return result;
        i++;

        while (i < json.Length)
        {
            i = SkipWs(json, i);

            if (i < json.Length && json[i] == '}') break;
            if (i < json.Length && json[i] == ',')
            {
                i++;
                continue;
            }
            if (i >= json.Length || json[i] != '"') break;

            int keyStart = i;
            int keyEnd = SkipString(json, i);
            i = SkipWs(json, keyEnd);

            if (i >= json.Length || json[i] != ':') break;
            i++;
            i = SkipWs(json, i);

            bool isStatus = KeyEquals(json, keyStart, keyEnd, "statusCode");
            bool isData = KeyEquals(json, keyStart, keyEnd, "data");
            bool isContinuation = KeyEquals(json, keyStart, keyEnd, "continuation");

            if (isStatus)
            {
                result.StatusCode = ReadSimpleStringValue(json, i);
                i = SkipValue(json, i);
            }
            else if (isData && i < json.Length && json[i] == '{')
            {
                int valueEnd;
                result.PointCount = CountDataObject(json, i, out valueEnd);
                i = valueEnd;
            }
            else if (isContinuation)
            {
                int valueStart = i;
                int valueEnd = SkipValue(json, i);
                result.ContinuationJson = ExtractJsonValue(json, valueStart, valueEnd);
                i = valueEnd;
            }
            else
            {
                i = SkipValue(json, i);
            }
        }

        return result;
    }
}
'@ -ErrorAction Stop
        }

        $script:FastRawParserAvailable = $true
    }
    catch {
        $script:FastRawParserAvailable = $false
    }
}

function Convert-ContinuationJson {
    param([string]$ContinuationJson)

    if ([string]::IsNullOrWhiteSpace($ContinuationJson)) { return $null }
    if ($ContinuationJson.Trim().Equals("null", [System.StringComparison]::OrdinalIgnoreCase)) { return $null }

    $parsed = $ContinuationJson | ConvertFrom-Json
    return @($parsed)
}

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) {
        return "unknown"
    }

    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalDays -ge 1) {
        return ("{0:N1}d {1:hh\:mm\:ss}" -f [Math]::Floor($ts.TotalDays), $ts)
    }
    return $ts.ToString("hh\:mm\:ss")
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $EnableHashes) { return $null }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-RawUtf8Atomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $tempPath = "$Path.tmp.$PID"
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    $fileStream = $null
    $writer = $null

    try {
        $fileStream = New-Object System.IO.FileStream(
            $tempPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            1048576,
            [System.IO.FileOptions]::SequentialScan
        )

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter(
            $fileStream,
            $utf8NoBom,
            1048576,
            $false
        )

        $writer.Write($Content)
        $writer.Flush()
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        elseif ($null -ne $fileStream) { $fileStream.Dispose() }
    }

    Move-Item -LiteralPath $tempPath -Destination $Path -Force
    return (Get-Item -LiteralPath $Path).Length
}

function Write-GzipUtf8Atomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $tempPath = "$Path.tmp.$PID"
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    $fileStream = $null
    $gzipStream = $null
    $writer = $null

    try {
        $fileStream = New-Object System.IO.FileStream(
            $tempPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            1048576,
            [System.IO.FileOptions]::SequentialScan
        )

        $level = [System.Enum]::Parse(
            [System.IO.Compression.CompressionLevel],
            $OutputCompression,
            $true
        )

        $gzipStream = New-Object System.IO.Compression.GZipStream(
            $fileStream,
            $level,
            $false
        )

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter(
            $gzipStream,
            $utf8NoBom,
            1048576,
            $false
        )

        $writer.Write($Content)
        $writer.Flush()
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        elseif ($null -ne $gzipStream) { $gzipStream.Dispose() }
        elseif ($null -ne $fileStream) { $fileStream.Dispose() }
    }

    Move-Item -LiteralPath $tempPath -Destination $Path -Force
    return (Get-Item -LiteralPath $Path).Length
}

function Write-PageContentAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    if ($OutputCompression -eq "None") {
        return Write-RawUtf8Atomic -Path $Path -Content $Content
    }

    return Write-GzipUtf8Atomic -Path $Path -Content $Content
}


function Save-State {
    param([Parameter(Mandatory = $true)]$State)

    $State.UpdatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    $json = $State | ConvertTo-Json -Depth 30
    $tempPath = "$StatePath.tmp.$PID"
    Write-JsonUtf8NoBom -Path $tempPath -Content $json

    if (Test-Path -LiteralPath $StatePath) {
        try {
            [System.IO.File]::Replace($tempPath, $StatePath, $null)
        }
        catch {
            Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
        }
    }
    else {
        Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
    }
}

function Get-AuthDescription {
    if (-not [string]::IsNullOrWhiteSpace($ApiToken)) { return "apiToken" }
    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) { return "accessToken" }
    if (-not [string]::IsNullOrWhiteSpace($UserToken)) { return "userToken" }
    return "anonymous"
}

function Add-Authentication {
    param([Parameter(Mandatory = $true)][hashtable]$Body)

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

function Get-PointValue {
    param($Point)

    if ($null -eq $Point) { return $null }

    # Canary 23.x responses may use [timestamp, value, quality] arrays.
    if ($Point -is [System.Array]) {
        if (@($Point).Count -ge 2) { return $Point[1] }
        return $null
    }

    # Newer responses commonly expose named t/v/q properties.
    $valueProperty = $Point.PSObject.Properties["v"]
    if ($null -ne $valueProperty) { return $valueProperty.Value }

    return $null
}

function Test-TagSpecificFailure {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    return $Message -match '(?i)(tag does not exist|does not have access to tag|user does not have access to tag|TagKey contains no TrendVectors|0x800403F8|Error reading data for tag)'
}

function Test-SystemicCountFailure {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    return $Message -match '(?i)(GetAggregateDataAsync|NoLicense|aggregate processing|aggregateName)'
}

function Test-PermanentFailure {
    param(
        [string]$Message,
        [int]$HttpStatusCode = 0
    )

    if ($HttpStatusCode -eq 400 -or $HttpStatusCode -eq 401 -or $HttpStatusCode -eq 403 -or $HttpStatusCode -eq 404) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    $patterns = @(
        "does not exist or user does not have access",
        "not authorized",
        "unauthorized",
        "forbidden",
        "invalid api token",
        "invalid token",
        "Cannot represent an actual TimeSpan more than 1000 days",
        "TagKey contains no TrendVectors",
        "0x800403F8"
    )

    foreach ($pattern in $patterns) {
        if ($Message.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Invoke-CanaryRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][hashtable]$Body,
        [Parameter(Mandatory = $true)][string]$Operation,
        [int]$Attempts = $MaxAttempts,
        [switch]$RawExport
    )

    $requestBody = @{}
    foreach ($key in $Body.Keys) {
        $requestBody[$key] = $Body[$key]
    }

    Add-Authentication -Body $requestBody

    $json = $requestBody | ConvertTo-Json -Depth 20 -Compress

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $failureMessage = $null
        $permanent = $false
        $httpStatus = 0
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
            $responseBytes = [System.Text.Encoding]::UTF8.GetByteCount($content)

            # Fast path used only for the very large raw-history payloads.
            # Discovery/context/count responses stay on the normal parser.
            if ($RawExport -and $script:FastRawParserAvailable) {
                $parseSw = [System.Diagnostics.Stopwatch]::StartNew()
                $meta = [CanaryFastJson]::Parse($content)
                $parseSw.Stop()

                if (-not [string]::IsNullOrWhiteSpace($meta.StatusCode) -and $meta.StatusCode -eq "Good") {
                    $continuation = Convert-ContinuationJson -ContinuationJson $meta.ContinuationJson

                    return [PSCustomObject]@{
                        Parsed        = $null
                        Raw           = $content
                        ApiSeconds    = $sw.Elapsed.TotalSeconds
                        ParseSeconds  = $parseSw.Elapsed.TotalSeconds
                        ResponseBytes = $responseBytes
                        Attempt       = $attempt
                        PointCount    = [long]$meta.PointCount
                        Continuation  = $continuation
                        Parser        = "compiled-fast"
                    }
                }

                # Parse normally when Canary reports an error or the helper
                # misses the response shape. Preserve the full error.
            }

            $parseSw = [System.Diagnostics.Stopwatch]::StartNew()
            $parsed = $content | ConvertFrom-Json
            $parseSw.Stop()

            if ($parsed.statusCode -and $parsed.statusCode -ne "Good") {
                $failureMessage = "Canary status '$($parsed.statusCode)': $($parsed.errors -join '; ')"
                $permanent = Test-PermanentFailure -Message $failureMessage
            }
            else {
                if ($RawExport) {
                    return [PSCustomObject]@{
                        Parsed        = $parsed
                        Raw           = $content
                        ApiSeconds    = $sw.Elapsed.TotalSeconds
                        ParseSeconds  = $parseSw.Elapsed.TotalSeconds
                        ResponseBytes = $responseBytes
                        Attempt       = $attempt
                        PointCount    = [long](Get-PointCountFromParsedData -Data $parsed.data)
                        Continuation  = $parsed.continuation
                        Parser        = "ConvertFrom-Json"
                    }
                }

                return [PSCustomObject]@{
                    Parsed        = $parsed
                    Raw           = $content
                    ApiSeconds    = $sw.Elapsed.TotalSeconds
                    ParseSeconds  = $parseSw.Elapsed.TotalSeconds
                    ResponseBytes = $responseBytes
                    Attempt       = $attempt
                }
            }
        }
        catch {
            if ($sw.IsRunning) { $sw.Stop() }

            $failureMessage = $_.Exception.Message

            try {
                if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                    $httpStatus = [int]$_.Exception.Response.StatusCode
                }
            }
            catch { }

            $permanent = Test-PermanentFailure -Message $failureMessage -HttpStatusCode $httpStatus
        }

        if ($permanent -or $attempt -ge $Attempts) {
            if ($permanent) {
                throw "Permanent failure during ${Operation}: $failureMessage"
            }
            throw "Failed after $Attempts attempts during ${Operation}: $failureMessage"
        }

        $exponential = $RetryBaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
        $bounded = [Math]::Min($RetryMaxDelaySeconds, $exponential)
        $jitterMs = Get-Random -Minimum 100 -Maximum 1000
        $delay = $bounded + ($jitterMs / 1000.0)

        Write-Log -Level "RETRY" -Event "request_retry" -Message (
            "$Operation failed on attempt $attempt/$Attempts. Retrying in $([Math]::Round($delay, 1))s. $failureMessage"
        ) -Data @{
            operation = $Operation
            attempt = $attempt
            maxAttempts = $Attempts
            delaySeconds = $delay
            httpStatus = $httpStatus
        }

        Start-Sleep -Milliseconds ([int]($delay * 1000))
    }
}


function Get-PointCountFromParsedData {
    param($Data)

    if ($null -eq $Data) { return 0L }

    $count = 0L
    foreach ($property in $Data.PSObject.Properties) {
        $count += @($property.Value).Count
    }
    return $count
}

$script:UnavailableTags = New-Object System.Collections.ArrayList
$script:NoCountTags = New-Object System.Collections.ArrayList

function Add-UnavailableTag {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Error
    )

    [void]$script:UnavailableTags.Add([PSCustomObject]@{
        Tag = $Tag
        Stage = $Stage
        Error = $Error
    })
}

function Add-NoCountTag {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    [void]$script:NoCountTags.Add([PSCustomObject]@{
        Tag = $Tag
        Reason = $Reason
    })
}

function Get-CanaryTagContextResilient {
    param([Parameter(Mandatory = $true)][object[]]$Tags)

    if ($Tags.Count -eq 0) { return }

    try {
        $result = Invoke-CanaryRequest -Endpoint "getTagContext" -Body @{
            tags = @($Tags)
        } -Operation "getTagContext ($($Tags.Count) tags)"

        $returnedTags = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)

        foreach ($item in @($result.Parsed.data)) {
            $oldest = $null
            $latest = $null
            $tagName = ""

            try {
                if ($null -ne $item.PSObject.Properties["tagName"]) {
                    $tagName = [string]$item.tagName
                }

                if ([string]::IsNullOrWhiteSpace($tagName)) {
                    Write-Log -Level "WARN" -Event "context_malformed" -Message "getTagContext returned a context item without tagName."
                    continue
                }

                [void]$returnedTags.Add($tagName)

                if ($null -eq $item.PSObject.Properties["tagContext"] -or $null -eq $item.tagContext) {
                    Add-UnavailableTag -Tag $tagName -Stage "getTagContext" -Error "Context item omitted tagContext"
                    Write-Log -Level "WARN" -Event "context_unavailable" -Message "Context missing tagContext; will attempt tag individually later: $tagName"
                    continue
                }

                $oldestText = [string]$item.tagContext.oldestTimeStamp
                $latestText = [string]$item.tagContext.latestTimeStamp

                if ([string]::IsNullOrWhiteSpace($oldestText)) {
                    Add-UnavailableTag -Tag $tagName -Stage "getTagContext" -Error "Context omitted oldestTimeStamp"
                    Write-Log -Level "WARN" -Event "context_unavailable" -Message "Context missing oldestTimeStamp; will attempt tag individually later: $tagName"
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($latestText)) {
                    Add-UnavailableTag -Tag $tagName -Stage "getTagContext" -Error "Context omitted latestTimeStamp"
                    Write-Log -Level "WARN" -Event "context_unavailable" -Message "Context missing latestTimeStamp; will attempt tag individually later: $tagName"
                    continue
                }

                $oldest = [DateTimeOffset]::Parse($oldestText)
                $latest = [DateTimeOffset]::Parse($latestText)

                if ($oldest -gt $latest) {
                    Add-UnavailableTag -Tag $tagName -Stage "getTagContext" -Error "Context oldestTimeStamp is later than latestTimeStamp"
                    Write-Log -Level "WARN" -Event "context_unavailable" -Message "Context timestamp range is inverted; will attempt tag individually later: $tagName"
                    continue
                }
            }
            catch {
                if (-not [string]::IsNullOrWhiteSpace($tagName)) {
                    Add-UnavailableTag -Tag $tagName -Stage "getTagContext" -Error $_.Exception.Message
                    Write-Log -Level "WARN" -Event "context_unavailable" -Message "Context malformed; will attempt tag individually later: $tagName"
                }
                continue
            }

            [PSCustomObject]@{
                Tag    = $tagName
                Oldest = $oldest
                Latest = $latest
                Count  = $null
            }
        }

        foreach ($tag in $Tags) {
            $tagName = [string]$tag
            if (-not $returnedTags.Contains($tagName)) {
                Add-UnavailableTag -Tag $tagName -Stage "getTagContext" -Error "Context response omitted tag"
                Write-Log -Level "WARN" -Event "context_unavailable" -Message "Context response omitted tag; will attempt tag individually later: $tagName"
            }
        }

        return
    }
    catch {
        if ($Tags.Count -eq 1) {
            $tag = [string]$Tags[0]
            Add-UnavailableTag -Tag $tag -Stage "getTagContext" -Error $_.Exception.Message
            Write-Log -Level "WARN" -Event "context_unavailable" -Message "Context unavailable; will attempt tag individually later: $tag"
            return
        }
    }

    $middle = [int][Math]::Floor($Tags.Count / 2)
    $left = @($Tags[0..($middle - 1)])
    $right = @($Tags[$middle..($Tags.Count - 1)])

    Get-CanaryTagContextResilient -Tags $left
    Get-CanaryTagContextResilient -Tags $right
}

function Get-CanaryCountsResilient {
    param(
        [Parameter(Mandatory = $true)][object[]]$Tags,
        [Parameter(Mandatory = $true)][DateTimeOffset]$StartTime,
        [Parameter(Mandatory = $true)][DateTimeOffset]$EndTime
    )

    $Tags = @($Tags)
    $tagCount = @($Tags).Count
    if ($tagCount -eq 0) { return }

    # Explicit short buckets are required for Canary 23.x when the historian
    # span exceeds 1000 days. We sum the returned Count buckets per tag.
    $interval = "{0}.00:00:00" -f $CountBucketDays
    $spanDays = [Math]::Max(1.0, ($EndTime - $StartTime).TotalDays)
    $expectedBuckets = [int][Math]::Ceiling($spanDays / $CountBucketDays) + 2
    $countMaxSize = [Math]::Max(10, [Math]::Min(10000, $expectedBuckets))

    $countTotals = @{}
    $hasValue = @{}

    foreach ($tag in $Tags) {
        $countTotals[[string]$tag] = 0.0
    }

    $continuation = $null
    $page = 0

    try {
        do {
            $page++

            $body = @{
                tags              = @($Tags)
                startTime         = $StartTime.ToString("o")
                endTime           = $EndTime.ToString("o")
                aggregateName     = "Count"
                aggregateInterval = $interval
                maxSize           = $countMaxSize
                includeQuality    = $false
            }

            if (Test-Continuation $continuation) {
                $body["continuation"] = $continuation
            }

            $result = Invoke-CanaryRequest -Endpoint "getTagData2" -Body $body -Operation "Count aggregate ($tagCount tags, page $page)" -Attempts 1

            if ($null -ne $result.Parsed.data) {
                foreach ($tag in $Tags) {
                    $tagName = [string]$tag
                    $property = $result.Parsed.data.PSObject.Properties[$tagName]
                    if ($null -eq $property) { continue }

                    foreach ($point in @($property.Value)) {
                        $value = Get-PointValue -Point $point
                        if ($null -ne $value -and "$value" -ne "") {
                            $countTotals[$tagName] += [double]$value
                            $hasValue[$tagName] = $true
                        }
                    }
                }
            }

            $continuation = $result.Parsed.continuation

            if ($page -gt 10000) {
                throw "Count continuation exceeded 10,000 pages for one batch. Aborting to prevent an infinite loop."
            }
        }
        while (Test-Continuation $continuation)
    }
    catch {
        $errorText = $_.Exception.Message

        # Only split batches for errors that can actually be caused by a tag.
        # Systemic/version/request errors must remain one clear error rather
        # than being transformed into thousands of fake bad-tag warnings.
        if (Test-SystemicCountFailure -Message $errorText) {
            foreach ($tag in $Tags) {
                Add-NoCountTag -Tag ([string]$tag) -Reason $errorText
            }
            throw "Canary aggregate processing returned NoLicense or another systemic aggregate failure. Count estimation is unavailable. Raw export eligibility is unaffected. $errorText"
        }

        if (-not (Test-TagSpecificFailure -Message $errorText)) {
            foreach ($tag in $Tags) {
                Add-NoCountTag -Tag ([string]$tag) -Reason $errorText
            }
            throw "Systemic Count failure. Count estimation is unavailable. Raw export eligibility is unaffected. $errorText"
        }

        if ($tagCount -eq 1) {
            Add-NoCountTag -Tag ([string]$Tags[0]) -Reason $errorText
            Write-Log -Level "WARN" -Event "count_unavailable" -Message "Count unavailable for tag: $($Tags[0])"
            return
        }

        $middle = [int][Math]::Floor($tagCount / 2)
        $left = @($Tags[0..($middle - 1)])
        $right = @($Tags[$middle..($tagCount - 1)])

        Get-CanaryCountsResilient -Tags $left -StartTime $StartTime -EndTime $EndTime
        Get-CanaryCountsResilient -Tags $right -StartTime $StartTime -EndTime $EndTime
        return
    }

    foreach ($tag in $Tags) {
        $tagName = [string]$tag

        if ($hasValue.ContainsKey($tagName)) {
            [PSCustomObject]@{
                Tag = $tagName
                Count = [double]$countTotals[$tagName]
            }
        }
        else {
            Add-NoCountTag -Tag $tagName -Reason "No Count result returned"
        }
    }
}

function Repair-CheckpointData {
    param([Parameter(Mandatory = $true)]$State)

    $repaired = 0

    # Remove abandoned temporary files from interrupted page/state writes.
    Get-ChildItem -LiteralPath $DataDirectory -Filter "*.tmp.*" -File -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    foreach ($batch in $State.Batches) {
        $lastCheckpointedPage = [int]$batch.NextPage - 1
        if ($lastCheckpointedPage -le 0) { continue }

        $batchDir = Join-Path $DataDirectory $batch.Id
        $missing = $false

        for ($page = 1; $page -le $lastCheckpointedPage; $page++) {
            $expectedRaw = Join-Path $batchDir ("page-{0:D6}.json" -f $page)
            $expectedGzip = Join-Path $batchDir ("page-{0:D6}.json.gz" -f $page)
            $existingPage = $null
            if (Test-Path -LiteralPath $expectedRaw) {
                $existingPage = Get-Item -LiteralPath $expectedRaw -ErrorAction SilentlyContinue
            }
            elseif (Test-Path -LiteralPath $expectedGzip) {
                $existingPage = Get-Item -LiteralPath $expectedGzip -ErrorAction SilentlyContinue
            }

            if ($null -eq $existingPage -or $existingPage.Length -le 0) {
                $missing = $true
                Write-Log -Level "WARN" -Event "checkpoint_repair" -Message (
                    "$($batch.Id) checkpoint references missing or empty page $page. Resetting this batch and re-exporting it from the beginning."
                )
                break
            }
        }

        if ($missing) {
            if (Test-Path -LiteralPath $batchDir) {
                Remove-Item -LiteralPath $batchDir -Recurse -Force
            }

            $batch.Status = "Pending"
            $batch.NextPage = 1
            $batch.Continuation = $null
            $batch.PointsWritten = 0L
            $batch.RawBytes = 0L
            $batch.CompressedBytes = 0L
            $batch.LastError = $null
            $repaired++
        }
    }

    if ($repaired -gt 0) {
        Save-State -State $State
        Write-Log -Level "OK" -Event "checkpoint_repair_complete" -Message "$repaired batch checkpoint(s) were safely reset for re-export."
    }
}

function Assert-ResumeCompatibility {
    param($State)

    $mismatches = New-Object System.Collections.ArrayList

    if ([string]$State.Server -ne [string]$Server) { [void]$mismatches.Add("Server") }
    if ([string]$State.Path -ne [string]$Path) { [void]$mismatches.Add("Path") }
    if ([string]$State.ExcludeRegex -ne [string]$ExcludeRegex) { [void]$mismatches.Add("ExcludeRegex") }
    if ([int]$State.ExportBatchSize -ne [int]$ExportBatchSize) { [void]$mismatches.Add("ExportBatchSize") }
    if ([int]$State.MaxSizePerTag -ne [int]$MaxSizePerTag) { [void]$mismatches.Add("MaxSizePerTag") }
    if ($null -ne $State.PSObject.Properties["CountBucketDays"] -and [int]$State.CountBucketDays -ne [int]$CountBucketDays) { [void]$mismatches.Add("CountBucketDays") }
    if ([bool]$State.IncludeQuality -ne [bool]$IncludeQuality) { [void]$mismatches.Add("IncludeQuality") }

    if ($mismatches.Count -gt 0) {
        throw "Existing state.json does not match current options: $($mismatches -join ', '). Use the original options or a different OutputDirectory."
    }
}

function Add-PlanCount {
    param(
        [Parameter(Mandatory = $true)]$Map,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    if ($Map.ContainsKey($Tag)) {
        $Map[$Tag] = [int]$Map[$Tag] + 1
    }
    else {
        $Map[$Tag] = 1
    }
}

function New-ExportPlan {
    param(
        [Parameter(Mandatory = $true)][object[]]$IncludedTags,
        [Parameter(Mandatory = $true)][object[]]$Contexts,
        [Parameter(Mandatory = $true)][object[]]$UnavailableTags,
        [Parameter(Mandatory = $true)][object[]]$NoCountTags,
        [Parameter(Mandatory = $true)][object[]]$Batches,
        [bool]$CountSkipped,
        [string]$CountSystemicFailure
    )

    $contextByTag = @{}
    foreach ($context in $Contexts) {
        if ($null -eq $context) { continue }
        $tag = [string]$context.Tag
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        if (-not $contextByTag.ContainsKey($tag)) {
            $contextByTag[$tag] = $context
        }
    }

    $unavailableByTag = @{}
    foreach ($item in $UnavailableTags) {
        if ($null -eq $item) { continue }
        $tag = [string]$item.Tag
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        if (-not $unavailableByTag.ContainsKey($tag)) {
            $unavailableByTag[$tag] = $item
        }
    }

    $noCountByTag = @{}
    foreach ($item in $NoCountTags) {
        if ($null -eq $item) { continue }
        $tag = [string]$item.Tag
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        if (-not $noCountByTag.ContainsKey($tag)) {
            $noCountByTag[$tag] = $item
        }
    }

    $batchIdsByTag = @{}
    foreach ($batch in $Batches) {
        foreach ($tagValue in @($batch.Tags)) {
            $tag = [string]$tagValue
            if (-not $batchIdsByTag.ContainsKey($tag)) {
                $batchIdsByTag[$tag] = New-Object System.Collections.ArrayList
            }
            [void]$batchIdsByTag[$tag].Add([string]$batch.Id)
        }
    }

    foreach ($tagValue in ($IncludedTags | Sort-Object)) {
        $tag = [string]$tagValue
        $context = $null
        $unavailable = $null
        $noCount = $null

        if ($contextByTag.ContainsKey($tag)) { $context = $contextByTag[$tag] }
        if ($unavailableByTag.ContainsKey($tag)) { $unavailable = $unavailableByTag[$tag] }
        if ($noCountByTag.ContainsKey($tag)) { $noCount = $noCountByTag[$tag] }

        $batchIds = @()
        if ($batchIdsByTag.ContainsKey($tag)) {
            $batchIds = @($batchIdsByTag[$tag])
        }

        $planType = "Missing"
        if ($batchIds.Count -gt 0) {
            $hasResolved = $false
            $hasFallback = $false
            foreach ($batchId in $batchIds) {
                if ([string]$batchId -like "B*") { $hasResolved = $true }
                if ([string]$batchId -like "U*") { $hasFallback = $true }
            }

            if ($hasResolved -and $hasFallback) { $planType = "Duplicate" }
            elseif ($hasResolved) { $planType = "B" }
            elseif ($hasFallback) { $planType = "U" }
        }

        $contextStatus = "Missing"
        if ($null -ne $context) {
            $contextStatus = "Resolved"
        }
        elseif ($null -ne $unavailable) {
            $contextStatus = "Unresolved: $($unavailable.Error)"
        }

        $countValue = $null
        $countStatus = "Not attempted"
        if ($null -ne $context) {
            if ($null -ne $context.Count) {
                $countValue = $context.Count
                $countStatus = "Available"
            }
            elseif ($CountSkipped) {
                $countStatus = "Skipped"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($CountSystemicFailure)) {
                $countStatus = "Unavailable: systemic Count failure"
            }
            elseif ($null -ne $noCount) {
                $countStatus = "Unavailable: $($noCount.Reason)"
            }
            else {
                $countStatus = "Unknown"
            }
        }

        [PSCustomObject]@{
            Tag = $tag
            PlanType = $planType
            BatchId = ($batchIds -join ";")
            ContextStatus = $contextStatus
            Oldest = $(if ($null -ne $context -and $null -ne $context.Oldest) { $context.Oldest.ToString("o") } else { "" })
            Latest = $(if ($null -ne $context -and $null -ne $context.Latest) { $context.Latest.ToString("o") } else { "" })
            Count = $countValue
            CountStatus = $countStatus
            RawExportStatus = "Pending"
        }
    }
}

function Assert-ExportPlanCoverage {
    param(
        [Parameter(Mandatory = $true)][object[]]$IncludedTags,
        [Parameter(Mandatory = $true)][object[]]$Batches
    )

    $includedSet = @{}
    foreach ($tagValue in $IncludedTags) {
        $includedSet[[string]$tagValue] = $true
    }

    $plannedCounts = @{}
    $resolvedSet = @{}
    $fallbackSet = @{}

    foreach ($batch in $Batches) {
        foreach ($tagValue in @($batch.Tags)) {
            $tag = [string]$tagValue
            Add-PlanCount -Map $plannedCounts -Tag $tag

            if ([string]$batch.Kind -eq "resolved") {
                $resolvedSet[$tag] = $true
            }
            elseif ([string]$batch.Kind -eq "context-fallback") {
                $fallbackSet[$tag] = $true
            }
        }
    }

    $missing = New-Object System.Collections.ArrayList
    foreach ($tag in $includedSet.Keys) {
        if (-not $plannedCounts.ContainsKey($tag)) {
            [void]$missing.Add($tag)
        }
    }

    $duplicate = New-Object System.Collections.ArrayList
    $extra = New-Object System.Collections.ArrayList
    foreach ($tag in $plannedCounts.Keys) {
        if ([int]$plannedCounts[$tag] -ne 1) {
            [void]$duplicate.Add($tag)
        }
        if (-not $includedSet.ContainsKey($tag)) {
            [void]$extra.Add($tag)
        }
    }

    $intersection = New-Object System.Collections.ArrayList
    foreach ($tag in $resolvedSet.Keys) {
        if ($fallbackSet.ContainsKey($tag)) {
            [void]$intersection.Add($tag)
        }
    }

    $failureCount = $missing.Count + $duplicate.Count + $extra.Count + $intersection.Count
    if ($failureCount -gt 0) {
        $records = New-Object System.Collections.ArrayList
        foreach ($tag in $missing) { [void]$records.Add([PSCustomObject]@{ Tag = $tag; Problem = "Missing" }) }
        foreach ($tag in $duplicate) { [void]$records.Add([PSCustomObject]@{ Tag = $tag; Problem = "Duplicate" }) }
        foreach ($tag in $extra) { [void]$records.Add([PSCustomObject]@{ Tag = $tag; Problem = "Extra" }) }
        foreach ($tag in $intersection) { [void]$records.Add([PSCustomObject]@{ Tag = $tag; Problem = "ResolvedAndFallback" }) }
        $records | Sort-Object Problem, Tag | Export-Csv -LiteralPath $ExportPlanFailurePath -NoTypeInformation

        Write-Log -Level "ERROR" -Event "export_plan_validation_failed" -Message (
            "Export plan validation failed. Included tags: $($includedSet.Count). Resolved tags: $($resolvedSet.Count). Fallback tags: $($fallbackSet.Count). Planned unique tags: $($plannedCounts.Count). Missing tags: $($missing.Count). Duplicate tags: $($duplicate.Count)."
        ) -Data @{
            includedTags = $includedSet.Count
            resolvedTags = $resolvedSet.Count
            fallbackTags = $fallbackSet.Count
            plannedUniqueTags = $plannedCounts.Count
            missingTags = $missing.Count
            duplicateTags = $duplicate.Count
            extraTags = $extra.Count
            resolvedAndFallbackTags = $intersection.Count
            failurePath = $ExportPlanFailurePath
        }

        throw "Export plan validation failed. See $ExportPlanFailurePath."
    }

    if (Test-Path -LiteralPath $ExportPlanFailurePath) {
        Remove-Item -LiteralPath $ExportPlanFailurePath -Force
    }

    Write-Log -Level "OK" -Event "export_plan_validated" -Message (
        "Export plan validated: all $($includedSet.Count.ToString('N0')) included tags are assigned exactly once. Resolved: $($resolvedSet.Count.ToString('N0')). Fallback: $($fallbackSet.Count.ToString('N0'))."
    ) -Data @{
        includedTags = $includedSet.Count
        resolvedTags = $resolvedSet.Count
        fallbackTags = $fallbackSet.Count
        plannedUniqueTags = $plannedCounts.Count
    }
}

function New-ExportState {
    Write-Log -Level "INFO" -Event "discovery_start" -Message "Phase 1/3: browsing all accessible tags."

    $allTagsList = New-Object System.Collections.Generic.List[string]
    $continuation = $null
    $browsePage = 0

    do {
        $browsePage++
        $body = @{
            path = $Path
            deep = $true
            search = ""
            maxSize = $BrowsePageSize
        }

        if (Test-Continuation $continuation) {
            $body["continuation"] = $continuation
        }

        $result = Invoke-CanaryRequest -Endpoint "browseTags" -Body $body -Operation "browseTags page $browsePage"
        $pageTags = @($result.Parsed.tags)

        foreach ($tag in $pageTags) {
            $allTagsList.Add([string]$tag)
        }

        Write-Log -Level "OK" -Event "browse_page" -Message (
            "Browse page ${browsePage}: $($pageTags.Count.ToString('N0')) tags in $([Math]::Round($result.ApiSeconds, 2))s; cumulative $($allTagsList.Count.ToString('N0'))."
        )

        $continuation = $result.Parsed.continuation
    }
    while (Test-Continuation $continuation)

    $allTags = @(Get-UniqueStringsOrdinal -Items $allTagsList.ToArray())
    $excluded = @($allTags | Where-Object { $_ -cmatch $ExcludeRegex })
    $included = @($allTags | Where-Object { $_ -cnotmatch $ExcludeRegex })

    $excluded | ForEach-Object {
        [PSCustomObject]@{ Tag = $_; Reason = "Matched exclusion regex: $ExcludeRegex" }
    } | Export-Csv -LiteralPath $ExcludedPath -NoTypeInformation

    Write-Log -Level "INFO" -Event "tag_filter" -Message (
        "Discovered $($allTags.Count.ToString('N0')) tags; excluding $($excluded.Count.ToString('N0')); $($included.Count.ToString('N0')) remain for export."
    ) -Data @{
        discovered = $allTags.Count
        excluded = $excluded.Count
        included = $included.Count
        excludeRegex = $ExcludeRegex
    }

    if ($included.Count -eq 0) {
        throw "No tags remain after applying ExcludeRegex '$ExcludeRegex'."
    }

    Write-Log -Level "INFO" -Event "context_start" -Message "Phase 2/3: resolving oldest/latest historical timestamps."

    $contexts = New-Object System.Collections.ArrayList
    $checked = 0

    foreach ($batch in Get-Batches -Items $included -Size $ContextBatchSize) {
        $batchContexts = @(Get-CanaryTagContextResilient -Tags @($batch))
        foreach ($item in $batchContexts) { [void]$contexts.Add($item) }

        $checked += $batch.Count
        Write-Log -Level "INFO" -Event "context_progress" -Message (
            "Context: $($checked.ToString('N0'))/$($included.Count.ToString('N0')) checked; $($contexts.Count.ToString('N0')) resolved; $($script:UnavailableTags.Count.ToString('N0')) unresolved."
        )
    }

    $validContexts = @($contexts | Where-Object { $null -ne $_.Oldest -and $null -ne $_.Latest })
    $fallbackEndTime = (Get-Date).ToUniversalTime()

    if ($validContexts.Count -gt 0) {
        $globalOldest = ($validContexts | Sort-Object Oldest | Select-Object -First 1).Oldest
        $globalLatest = ($validContexts | Sort-Object Latest -Descending | Select-Object -First 1).Latest

        Write-Log -Level "OK" -Event "context_complete" -Message (
            "Resolved $($validContexts.Count.ToString('N0')) tags. Historical range: $($globalOldest.ToString('o')) through $($globalLatest.ToString('o'))."
        )
    }
    else {
        $globalOldest = [DateTimeOffset]::Parse($FallbackStartTime)
        $globalLatest = [DateTimeOffset]$fallbackEndTime

        Write-Log -Level "WARN" -Event "context_none_resolved" -Message (
            "No included tags returned valid historical context. All included tags will use individual fallback raw export attempts."
        )
    }

    $countMap = @{}
    $countSkipped = [bool]$SkipCount
    $countSystemicFailure = ""

    if (-not $SkipCount -and $validContexts.Count -gt 0) {
        Write-Log -Level "INFO" -Event "count_start" -Message "Phase 3/3: counting TVQs using explicit $CountBucketDays-day buckets for cross-version compatibility."
        $countChecked = 0
        $contextTags = @($validContexts.Tag)

        try {
            foreach ($batch in Get-Batches -Items $contextTags -Size $CountBatchSize) {
                $items = @(Get-CanaryCountsResilient -Tags @($batch) -StartTime $globalOldest -EndTime $globalLatest)
                foreach ($item in $items) {
                    $countMap[$item.Tag] = $item.Count
                }

                $countChecked += @($batch).Count
                Write-Log -Level "INFO" -Event "count_progress" -Message (
                    "Count: $($countChecked.ToString('N0'))/$($contextTags.Count.ToString('N0')) checked; $($countMap.Count.ToString('N0')) returned counts."
                )
            }
        }
        catch {
            $countSystemicFailure = $_.Exception.Message
            # Count is only used for ordering/progress estimation. A systemic Count
            # incompatibility must never prevent the actual raw historian export.
            Write-Log -Level "WARN" -Event "count_systemic_failure" -Message (
                "Canary aggregate processing returned a systemic Count failure. Count estimation is unavailable. Raw export eligibility is unaffected; continuing with all planned tags. $($_.Exception.Message)"
            )
            $countMap = @{}
        }
    }
    elseif ($SkipCount) {
        Write-Log -Level "WARN" -Event "count_skipped" -Message "Count phase skipped. Percentage and ETA will be based on completed batches rather than TVQs."
    }
    else {
        $countSkipped = $true
        Write-Log -Level "WARN" -Event "count_skipped_no_context" -Message "Count phase skipped because no tags resolved historical context. Raw fallback export will continue."
    }

    foreach ($context in $contexts) {
        if ($countMap.ContainsKey($context.Tag)) {
            $context.Count = $countMap[$context.Tag]
        }
    }

    @($contexts) | Sort-Object Tag | Export-Csv -LiteralPath $InventoryPath -NoTypeInformation
    @($script:UnavailableTags) | Export-Csv -LiteralPath $UnavailablePath -NoTypeInformation
    @($script:NoCountTags) | Export-Csv -LiteralPath $NoCountPath -NoTypeInformation

    $resolvedTagSet = @{}
    foreach ($context in $validContexts) {
        $resolvedTagSet[[string]$context.Tag] = $true
    }

    $unavailableTagSet = @{}
    foreach ($item in @($script:UnavailableTags)) {
        if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.Tag)) {
            $unavailableTagSet[[string]$item.Tag] = $true
        }
    }

    foreach ($tagValue in $included) {
        $tag = [string]$tagValue
        if (-not $resolvedTagSet.ContainsKey($tag) -and -not $unavailableTagSet.ContainsKey($tag)) {
            Add-UnavailableTag -Tag $tag -Stage "exportPlanning" -Error "Included tag had no resolved context or fallback record"
            $unavailableTagSet[$tag] = $true
            Write-Log -Level "WARN" -Event "context_unavailable" -Message "Included tag had no resolved context or fallback record; will attempt tag individually later: $tag"
        }
    }

    # Sort high-volume tags first when counts are known. This gives full pages early
    # and makes the live throughput estimate settle quickly.
    $resolvedForExport = @(
        $contexts | Sort-Object @{ Expression = {
            if ($null -eq $_.Count) { -1 } else { [double]$_.Count }
        }; Descending = $true }, Tag
    )

    $batches = New-Object System.Collections.ArrayList
    $batchId = 0

    foreach ($tagBatch in Get-Batches -Items @($resolvedForExport.Tag) -Size $ExportBatchSize) {
        $batchId++
        [void]$batches.Add([PSCustomObject]@{
            Id = ("B{0:D5}" -f $batchId)
            Kind = "resolved"
            Tags = @($tagBatch)
            StartTime = $globalOldest.ToString("o")
            EndTime = $globalLatest.ToString("o")
            Status = "Pending"
            NextPage = 1
            Continuation = $null
            PointsWritten = 0L
            RawBytes = 0L
            CompressedBytes = 0L
            LastError = $null
        })
    }

    @($script:UnavailableTags) | Export-Csv -LiteralPath $UnavailablePath -NoTypeInformation

    # Attempt context-rejected non-diagnostic tags individually across a broad fallback interval.
    # Permanent access/not-found failures are logged and preserved in state.
    $unresolvedUnique = @(Get-UniqueStringsOrdinal -Items @($script:UnavailableTags | Select-Object -ExpandProperty Tag))
    foreach ($tag in $unresolvedUnique) {
        $batchId++
        [void]$batches.Add([PSCustomObject]@{
            Id = ("U{0:D5}" -f $batchId)
            Kind = "context-fallback"
            Tags = @([string]$tag)
            StartTime = $FallbackStartTime
            EndTime = $fallbackEndTime.ToString("o")
            Status = "Pending"
            NextPage = 1
            Continuation = $null
            PointsWritten = 0L
            RawBytes = 0L
            CompressedBytes = 0L
            LastError = $null
        })
    }

    Assert-ExportPlanCoverage -IncludedTags $included -Batches @($batches)
    $exportPlan = @(
        New-ExportPlan `
            -IncludedTags $included `
            -Contexts @($contexts) `
            -UnavailableTags @($script:UnavailableTags) `
            -NoCountTags @($script:NoCountTags) `
            -Batches @($batches) `
            -CountSkipped $countSkipped `
            -CountSystemicFailure $countSystemicFailure
    )
    $exportPlan | Export-Csv -LiteralPath $ExportPlanPath -NoTypeInformation

    $expectedPoints = 0.0
    foreach ($context in $contexts) {
        if ($null -ne $context.Count) { $expectedPoints += [double]$context.Count }
    }

    $state = [PSCustomObject]@{
        Version = 2
        CreatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        Server = $Server
        Path = $Path
        ExcludeRegex = $ExcludeRegex
        IncludeQuality = $IncludeQuality
        ExportBatchSize = $ExportBatchSize
        MaxSizePerTag = $MaxSizePerTag
        CountBucketDays = $CountBucketDays
        OutputCompression = $OutputCompression
        Authentication = (Get-AuthDescription)
        DiscoveredTags = $allTags.Count
        ExcludedTags = $excluded.Count
        ResolvedTags = $validContexts.Count
        ContextFallbackTags = $unresolvedUnique.Count
        HistoricalStart = $globalOldest.ToString("o")
        HistoricalEnd = $globalLatest.ToString("o")
        ExpectedPoints = $expectedPoints
        ExportPlan = "export-plan.csv"
        Batches = @($batches)
    }

    Save-State -State $state

    Write-Log -Level "OK" -Event "state_created" -Message (
        "Export state created with $($batches.Count.ToString('N0')) batches. Checkpointing will occur after every successful page."
    )

    return $state
}

function Write-PageManifestRecord {
    param([hashtable]$Record)

    $json = ([PSCustomObject]$Record | ConvertTo-Json -Depth 12 -Compress)
    Add-Content -LiteralPath $PageManifestPath -Value $json -Encoding UTF8
}

function Export-Batch {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Batch,
        [Parameter(Mandatory = $true)][int]$BatchOrdinal,
        [Parameter(Mandatory = $true)][int]$TotalBatches,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$RunStopwatch
    )

    $batchDir = Join-Path $DataDirectory $Batch.Id
    New-Item -ItemType Directory -Path $batchDir -Force | Out-Null

    $Batch.Status = "InProgress"
    Save-State -State $State

    Write-Log -Level "INFO" -Event "batch_start" -Message (
        "[$BatchOrdinal/$TotalBatches] Starting $($Batch.Id) ($($Batch.Kind)), $(@($Batch.Tags).Count) tag(s), page $($Batch.NextPage)."
    ) -Data @{
        batchId = $Batch.Id
        ordinal = $BatchOrdinal
        totalBatches = $TotalBatches
        tagCount = @($Batch.Tags).Count
        nextPage = $Batch.NextPage
        kind = $Batch.Kind
    }

    while ($true) {
        $page = [int]$Batch.NextPage
        $pageStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $body = @{
            tags = @($Batch.Tags)
            startTime = [string]$Batch.StartTime
            endTime = [string]$Batch.EndTime
            includeQuality = $IncludeQuality
            includeBounds = $false
            maxSize = $MaxSizePerTag
        }

        if (Test-Continuation $Batch.Continuation) {
            $body["continuation"] = @($Batch.Continuation)
        }

        try {
            $result = Invoke-CanaryRequest -Endpoint "getTagData2" -Body $body -Operation "$($Batch.Id) page $page" -RawExport
        }
        catch {
            $pageStopwatch.Stop()
            $Batch.LastError = $_.Exception.Message

            $isPermanent = $Batch.LastError.StartsWith("Permanent failure", [System.StringComparison]::OrdinalIgnoreCase)
            if ($isPermanent -and $Batch.Kind -eq "context-fallback") {
                $Batch.Status = "Unavailable"
                Save-State -State $State

                Write-Log -Level "WARN" -Event "fallback_unavailable" -Message (
                    "$($Batch.Id) could not be exported because Canary reports the tag as permanently unavailable. It will not be retried automatically. $($Batch.LastError)"
                ) -Data @{
                    batchId = $Batch.Id
                    page = $page
                    tags = @($Batch.Tags)
                    error = $Batch.LastError
                }
                return $false
            }

            $Batch.Status = "Failed"
            Save-State -State $State

            Write-Log -Level "ERROR" -Event "batch_failed" -Message (
                "$($Batch.Id) page $page failed and was checkpointed for resume. $($Batch.LastError)"
            ) -Data @{
                batchId = $Batch.Id
                page = $page
                error = $Batch.LastError
            }
            return $false
        }

        $pointCount = [long]$result.PointCount
        $fileName = if ($OutputCompression -eq "None") {
            "page-{0:D6}.json" -f $page
        }
        else {
            "page-{0:D6}.json.gz" -f $page
        }
        $filePath = Join-Path $batchDir $fileName

        try {
            $writeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $storedBytes = Write-PageContentAtomic -Path $filePath -Content $result.Raw
            $writeStopwatch.Stop()

            $hashStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $sha256 = Get-Sha256 -Path $filePath
            $hashStopwatch.Stop()
        }
        catch {
            $pageStopwatch.Stop()
            $Batch.Status = "Failed"
            $Batch.LastError = "Disk write failed for ${filePath}: $($_.Exception.Message)"
            Save-State -State $State

            Write-Log -Level "ERROR" -Event "disk_write_failed" -Message $Batch.LastError -Data @{
                batchId = $Batch.Id
                page = $page
                path = $filePath
            }
            return $false
        }

        $pageStopwatch.Stop()

        $Batch.PointsWritten = [long]$Batch.PointsWritten + [long]$pointCount
        $Batch.RawBytes = [long]$Batch.RawBytes + [long]$result.ResponseBytes
        # Legacy state field name retained for v3/v4 resume compatibility.
        # In v6 this tracks bytes actually stored on disk, compressed or raw.
        $Batch.CompressedBytes = [long]$Batch.CompressedBytes + [long]$storedBytes
        $Batch.Continuation = $result.Continuation
        $Batch.NextPage = $page + 1
        $Batch.LastError = $null

        $hasMore = Test-Continuation $Batch.Continuation
        if ($hasMore) { $Batch.Status = "InProgress" } else { $Batch.Status = "Complete" }

        # Checkpoint only after the data file is safely present.
        Save-State -State $State

        $manifestRecord = @{
            timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
            batchId = $Batch.Id
            batchKind = $Batch.Kind
            page = $page
            file = ("data/{0}/{1}" -f $Batch.Id, $fileName)
            tagCount = @($Batch.Tags).Count
            points = [long]$pointCount
            rawBytes = [long]$result.ResponseBytes
            storedBytes = [long]$storedBytes
            outputCompression = $OutputCompression
            apiSeconds = $result.ApiSeconds
            parseSeconds = $result.ParseSeconds
            writeSeconds = $writeStopwatch.Elapsed.TotalSeconds
            hashSeconds = $hashStopwatch.Elapsed.TotalSeconds
            parser = $result.Parser
            endToEndSeconds = $pageStopwatch.Elapsed.TotalSeconds
            attempt = $result.Attempt
            sha256 = $sha256
        }
        Write-PageManifestRecord -Record $manifestRecord

        $allPoints = 0L
        $allRawBytes = 0L
        $allCompressedBytes = 0L
        $completeBatches = 0
        foreach ($b in $State.Batches) {
            $allPoints += [long]$b.PointsWritten
            $allRawBytes += [long]$b.RawBytes
            $allCompressedBytes += [long]$b.CompressedBytes
            if ($b.Status -eq "Complete") { $completeBatches++ }
        }

        $runtimeSeconds = [Math]::Max(0.001, $RunStopwatch.Elapsed.TotalSeconds)
        $runPoints = [Math]::Max(0.0, [double]$allPoints - [double]$script:RunBaselinePoints)
        $e2eRate = $runPoints / $runtimeSeconds
        $progressText = "$completeBatches/$TotalBatches batches"
        $etaText = "unknown"
        $pctText = "n/a"

        if ([double]$State.ExpectedPoints -gt 0 -and $allPoints -gt 0) {
            $pct = [Math]::Min(100.0, 100.0 * $allPoints / [double]$State.ExpectedPoints)
            $remaining = [Math]::Max(0.0, [double]$State.ExpectedPoints - $allPoints)
            if ($e2eRate -gt 0) {
                $etaText = Format-Duration ($remaining / $e2eRate)
            }
            $pctText = ("{0:N1}%" -f $pct)
        }
        elseif ($TotalBatches -gt 0) {
            $pct = 100.0 * $completeBatches / $TotalBatches
            $pctText = ("{0:N1}% batches" -f $pct)
        }

        $storedMb = $storedBytes / 1MB
        $rawMb = $result.ResponseBytes / 1MB
        $apiRate = 0.0
        if ($result.ApiSeconds -gt 0) { $apiRate = $pointCount / $result.ApiSeconds }

        $storageText = if ($OutputCompression -eq "None") {
            "$([Math]::Round($storedMb, 1)) MB json"
        }
        else {
            "$([Math]::Round($storedMb, 1)) MB gz"
        }

        Write-Log -Level "DATA" -Event "page_written" -Message (
            "$($Batch.Id) p$page | $($pointCount.ToString('N0')) TVQs | $([Math]::Round($rawMb, 1)) MB API -> $storageText | API $([Math]::Round($result.ApiSeconds, 2))s | parse $([Math]::Round($result.ParseSeconds, 2))s | write $([Math]::Round($writeStopwatch.Elapsed.TotalSeconds, 2))s | page $([Math]::Round($pageStopwatch.Elapsed.TotalSeconds, 2))s | $([Math]::Round($apiRate, 0).ToString('N0')) TVQ/s API | progress $pctText | ETA $etaText"
        ) -Data @{
            batchId = $Batch.Id
            page = $page
            points = $pointCount
            apiSeconds = $result.ApiSeconds
            parseSeconds = $result.ParseSeconds
            writeSeconds = $writeStopwatch.Elapsed.TotalSeconds
            hashSeconds = $hashStopwatch.Elapsed.TotalSeconds
            parser = $result.Parser
            endToEndSeconds = $pageStopwatch.Elapsed.TotalSeconds
            rawBytes = $result.ResponseBytes
            storedBytes = $storedBytes
            outputCompression = $OutputCompression
            progress = $pctText
            eta = $etaText
            completedBatches = $completeBatches
            totalBatches = $TotalBatches
        }

        if (-not $hasMore) {
            Write-Log -Level "OK" -Event "batch_complete" -Message (
                "$($Batch.Id) complete: $(([long]$Batch.PointsWritten).ToString('N0')) TVQs in $($Batch.NextPage - 1) page(s)."
            )
            return $true
        }

        # Release the large parsed response before the next page.
        $result = $null
    }
}

function Write-FinalSummary {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$RunStopwatch
    )

    $complete = @($State.Batches | Where-Object { $_.Status -eq "Complete" })
    $failed = @($State.Batches | Where-Object { $_.Status -eq "Failed" })
    $unavailable = @($State.Batches | Where-Object { $_.Status -eq "Unavailable" })
    $pending = @($State.Batches | Where-Object {
        $_.Status -ne "Complete" -and $_.Status -ne "Failed" -and $_.Status -ne "Unavailable"
    })

    $points = 0L
    $rawBytes = 0L
    $compressedBytes = 0L
    $plannedTags = 0
    $completeTags = 0
    $failedTags = 0
    $unavailableTags = 0
    $pendingTags = 0

    foreach ($batch in $State.Batches) {
        $batchTagCount = @($batch.Tags).Count
        $points += [long]$batch.PointsWritten
        $rawBytes += [long]$batch.RawBytes
        $compressedBytes += [long]$batch.CompressedBytes
        $plannedTags += $batchTagCount

        if ($batch.Status -eq "Complete") { $completeTags += $batchTagCount }
        elseif ($batch.Status -eq "Failed") { $failedTags += $batchTagCount }
        elseif ($batch.Status -eq "Unavailable") { $unavailableTags += $batchTagCount }
        else { $pendingTags += $batchTagCount }
    }

    if ($failed.Count -gt 0) {
        $failed | Select-Object Id, Kind, Status, NextPage, PointsWritten, LastError, Tags |
            Export-Csv -LiteralPath $FailedPath -NoTypeInformation
    }
    elseif (Test-Path -LiteralPath $FailedPath) {
        Remove-Item -LiteralPath $FailedPath -Force
    }

    $elapsed = $RunStopwatch.Elapsed.TotalSeconds
    $runPoints = [Math]::Max(0.0, [double]$points - [double]$script:RunBaselinePoints)
    $rate = 0.0
    if ($elapsed -gt 0) { $rate = $runPoints / $elapsed }

    $summary = [PSCustomObject]@{
        completedUtc = (Get-Date).ToUniversalTime().ToString("o")
        server = $State.Server
        outputDirectory = $OutputDirectory
        discoveredTags = $State.DiscoveredTags
        excludedTags = $State.ExcludedTags
        resolvedTags = $State.ResolvedTags
        contextFallbackTags = $State.ContextFallbackTags
        totalBatches = @($State.Batches).Count
        completeBatches = $complete.Count
        failedBatches = $failed.Count
        unavailableBatches = $unavailable.Count
        pendingBatches = $pending.Count
        plannedTags = $plannedTags
        completeTags = $completeTags
        unavailableTags = $unavailableTags
        failedTags = $failedTags
        pendingTags = $pendingTags
        pointsWritten = $points
        pointsWrittenThisRun = $runPoints
        expectedPointsFromCount = [double]$State.ExpectedPoints
        rawResponseBytes = $rawBytes
        storedOutputBytes = $compressedBytes
        outputCompressionCurrentRun = $OutputCompression
        elapsedSecondsThisRun = $elapsed
        endToEndTvqPerSecondThisRun = $rate
        includeQuality = $State.IncludeQuality
        countBucketDays = $(if ($null -ne $State.PSObject.Properties["CountBucketDays"]) { $State.CountBucketDays } else { $CountBucketDays })
        historicalStart = $State.HistoricalStart
        historicalEnd = $State.HistoricalEnd
        dataFormat = $(if ($OutputCompression -eq "None") { "raw Canary getTagData2 JSON responses (.json)" } else { "gzip-compressed raw Canary getTagData2 JSON responses (.json.gz)" })
        stateFile = "state.json"
        exportPlan = "export-plan.csv"
        pageManifest = "pages.jsonl"
    }

    Write-JsonUtf8NoBom -Path $SummaryPath -Content ($summary | ConvertTo-Json -Depth 12)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " EXPORT SUMMARY" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host (" Complete batches:   {0:N0}/{1:N0}" -f $complete.Count, @($State.Batches).Count) -ForegroundColor Green
    Write-Host (" Failed batches:     {0:N0}" -f $failed.Count) -ForegroundColor $(if ($failed.Count -eq 0) { "Green" } else { "Red" })
    Write-Host (" Unavailable tags:   {0:N0}" -f $unavailable.Count) -ForegroundColor $(if ($unavailable.Count -eq 0) { "Green" } else { "Yellow" })
    Write-Host (" Planned tags:       {0:N0}" -f $plannedTags) -ForegroundColor White
    Write-Host (" Complete tags:      {0:N0}" -f $completeTags) -ForegroundColor White
    Write-Host (" Failed tags:        {0:N0}" -f $failedTags) -ForegroundColor $(if ($failedTags -eq 0) { "Green" } else { "Red" })
    Write-Host (" Pending tags:       {0:N0}" -f $pendingTags) -ForegroundColor $(if ($pendingTags -eq 0) { "Green" } else { "Yellow" })
    Write-Host (" TVQs written:       {0:N0}" -f $points) -ForegroundColor White
    Write-Host (" TVQs this run:      {0:N0}" -f $runPoints) -ForegroundColor White
    Write-Host (" Raw API data:       {0:N2} GB" -f ($rawBytes / 1GB)) -ForegroundColor White
    Write-Host (" Stored output:      {0:N2} GB" -f ($compressedBytes / 1GB)) -ForegroundColor White
    Write-Host (" This-run elapsed:   {0}" -f (Format-Duration $elapsed)) -ForegroundColor White
    Write-Host (" End-to-end rate:    {0:N0} TVQ/s" -f $rate) -ForegroundColor White
    Write-Host " State:              $StatePath" -ForegroundColor Gray
    Write-Host " Summary:            $SummaryPath" -ForegroundColor Gray
    Write-Host " Logs:               $LogsDirectory" -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""

    if ($failed.Count -gt 0 -or $pending.Count -gt 0) {
        Write-Log -Level "WARN" -Event "export_incomplete" -Message (
            "$($failed.Count) failed batch(es) and $($pending.Count) pending batch(es) remain. Re-run the same command with the same OutputDirectory to resume from the last checkpoints."
        )
    }
    elseif ($unavailable.Count -gt 0) {
        Write-Log -Level "WARN" -Event "export_complete_with_unavailable" -Message (
            "All retrievable batches completed. $($unavailable.Count) context-rejected tag(s) were also attempted individually and Canary reported them as permanently unavailable."
        )
    }
    else {
        Write-Log -Level "OK" -Event "export_complete" -Message "All export batches completed successfully."
    }
}

# ============================= MAIN =============================

Write-Banner

if ($InsecureSkipCertificateCheck) {
    Write-Log -Level "WARN" -Event "tls_validation_disabled" -Message "TLS certificate validation is disabled for this PowerShell process."
}

Write-Log -Level "INFO" -Event "run_start" -Message "Starting Canary historian export using PowerShell $($PSVersionTable.PSVersion)."
Write-Log -Level "INFO" -Event "performance_mode" -Message (
    "Raw parser: $(if ($script:FastRawParserAvailable) { 'compiled-fast' } else { 'ConvertFrom-Json fallback' }); storage: $(if ($OutputCompression -eq 'None') { 'raw-json' } else { "gzip-$OutputCompression" }); maxSize/tag: $MaxSizePerTag."
)

$state = $null

if (Test-Path -LiteralPath $StatePath) {
    Write-Log -Level "INFO" -Event "resume_detected" -Message "Existing checkpoint found; validating and resuming."
    $state = (Get-Content -LiteralPath $StatePath -Raw) | ConvertFrom-Json
    Assert-ResumeCompatibility -State $state

    # Output storage may be changed when resuming because each page is self-contained.
    # Existing .json.gz pages remain valid while new pages can be written as raw .json,
    # or vice versa. Repair-CheckpointData accepts both formats.
    $previousOutputCompression = $null
    if ($null -ne $state.PSObject.Properties["OutputCompression"]) {
        $previousOutputCompression = [string]$state.OutputCompression
    }
    else {
        $legacyGzipPage = Get-ChildItem -LiteralPath $DataDirectory -Filter "*.json.gz" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $legacyGzipPage) {
            $previousOutputCompression = "LegacyGzip"
        }
    }

    if ($null -eq $state.PSObject.Properties["OutputCompression"]) {
        $state | Add-Member -NotePropertyName OutputCompression -NotePropertyValue $OutputCompression
    }
    else {
        $state.OutputCompression = $OutputCompression
    }

    Repair-CheckpointData -State $state
    Save-State -State $state

    if (-not [string]::IsNullOrWhiteSpace($previousOutputCompression) -and
        $previousOutputCompression -ne $OutputCompression) {
        Write-Log -Level "WARN" -Event "storage_mode_changed" -Message (
            "Resuming with output storage '$OutputCompression' after '$previousOutputCompression'. Existing completed pages are retained as-is, so this export may contain both .json.gz and .json files."
        )
    }

    $completedAlready = @($state.Batches | Where-Object { $_.Status -eq "Complete" }).Count
    $failedAlready = @($state.Batches | Where-Object { $_.Status -eq "Failed" }).Count
    Write-Log -Level "OK" -Event "resume_ready" -Message (
        "Resume state loaded: $completedAlready complete, $failedAlready failed, $(@($state.Batches).Count - $completedAlready - $failedAlready) incomplete."
    )
}
else {
    $state = New-ExportState
}

$script:RunBaselinePoints = 0L
foreach ($existingBatch in $state.Batches) {
    $script:RunBaselinePoints += [long]$existingBatch.PointsWritten
}

$runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$totalBatches = @($state.Batches).Count
$ordinal = 0

foreach ($batch in $state.Batches) {
    $ordinal++

    if ($batch.Status -eq "Complete") {
        continue
    }

    if ($RetryFailedOnly -and $batch.Status -ne "Failed") {
        continue
    }

    [void](Export-Batch -State $state -Batch $batch -BatchOrdinal $ordinal -TotalBatches $totalBatches -RunStopwatch $runStopwatch)
}

$runStopwatch.Stop()
Save-State -State $state
Write-FinalSummary -State $state -RunStopwatch $runStopwatch
