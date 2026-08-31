<#
.SYNOPSIS
    Robust Canary raw JSON / JSON.GZ to CSV converter with plain CSV, per-file GZIP,
    per-file ZIP, or one ZIP archive for the entire converted data tree.

.DESCRIPTION
    PURPOSE
    =======
    This script is the post-processing companion to Export-CanaryHistorian.ps1 and is compatible
    with exports produced by earlier versions. The exporter stores Canary getTagData2 responses as
    raw JSON or JSON.GZ pages during extraction. This converter turns those lossless page files into
    conventional row-oriented CSV.

    It can be run after the export is complete, or in -Watch mode while the exporter is still writing.

    SOURCE LAYOUT
    =============
    The exporter stores finalized pages beneath:

      <ExportDirectory>\data\B00001\page-000001.json
      <ExportDirectory>\data\B00001\page-000002.json
      <ExportDirectory>\data\U00873\page-000001.json

    Older/resumed exports may contain .json.gz files. Mixed JSON and JSON.GZ input is supported
    automatically.

    Folder meanings are inherited from the exporter:
      Bxxxxx = normal/resolved multi-tag export batch.
      Uxxxxx = single-tag fallback batch for a tag whose getTagContext lookup was unresolved.
      page-xxxxxx = one Canary getTagData2 response. Later pages are continuation responses.

    The converter ignores exporter temporary files (*.tmp.*). It opens a page after the exporter has
    atomically published that page under its final .json or .json.gz name.

    CSV SHAPE
    =========
    Each Canary point is flattened to:

      Tag,Timestamp,Value,Quality

    Example:

      Example.Process.Temperature,2024-03-08T13:37:13.1960000-05:00,27.339344,192

    Canary's numeric quality value is preserved exactly as returned. Timestamp ordering, duplicate
    timestamps, values, and quality codes remain in source-page form.

    OUTPUT MODES
    ============
    Select the container with -Compression:

      -Compression None
          One normal .csv file per exporter page.

          csv-conversion\data\B00001\page-000001.csv

      -Compression Gzip
          One .csv.gz file per exporter page. This is the default and is usually the best balance
          between portability, compression ratio, restartability, and incremental processing.

          csv-conversion\data\B00001\page-000001.csv.gz

      -Compression Zip -ZipLayout PerFile
          One ZIP file per exporter page. Each ZIP contains exactly one CSV entry.

          csv-conversion\data\B00001\page-000001.csv.zip
              contains: page-000001.csv

          This mode is fully incremental and works well with -Watch. A failed conversion affects
          only one page/archive and can be retried independently.

      -Compression Zip -ZipLayout SingleArchive
          Produces one final ZIP containing the entire converted data root:

          csv-conversion\CanaryCsvData.zip
              data/B00001/page-000001.csv
              data/B00001/page-000002.csv
              data/B00002/page-000001.csv
              data/U00873/page-000001.csv
              ...

          IMPORTANT: SingleArchive mode uses a staging tree. Appending directly to one ZIP during a
          long conversion risks archive corruption during central-directory finalization.

          csv-conversion\_single-zip-staging\data\B00001\page-000001.csv

          Every source page is converted and checkpointed to staging atomically. After all currently
          required source pages are safely staged, the script builds a temporary ZIP and atomically
          renames it to CanaryCsvData.zip. If archive creation fails, the staged CSV pages remain
          intact and the archive can be rebuilt without rereading or reconverting all JSON.

          The staging tree is retained after a successful archive. It is the recovery checkpoint for
          rebuilding the single ZIP. After independent verification or copying, the
          _single-zip-staging folder may be deleted.

    WATCH MODE
    ==========
    -Watch repeatedly scans the exporter's data folder and converts newly finalized pages.

    With None, Gzip, or Zip/PerFile:
      * output files appear continuously as new exporter pages appear;
      * Ctrl+C is safe;
      * rerunning the same command resumes from conversion-manifest.jsonl.

    With Zip/SingleArchive:
      * new pages are continuously converted into the staging tree;
      * the script reads the exporter's state.json to determine whether the exporter is finished;
      * when all exporter batches are Complete or Unavailable, every discovered source page is
        checkpointed, and no conversion failures remain, the final single ZIP is built atomically;
      * after successful finalization, Watch mode exits automatically.
      * if exporter state is unavailable, the converter keeps watching.

    Without -Watch, SingleArchive mode performs one scan. If all discovered source pages are
    successfully staged, it builds a ZIP representing that snapshot. If the exporter is still running,
    that ZIP is a snapshot of what existed at scan time; use -Watch when you want automatic final
    packaging after the exporter itself completes.

    RESTART / CHECKPOINT MODEL
    ==========================
    conversion-manifest.jsonl is append-only. Each successful source page records:
      * source relative path;
      * source file length and last-write timestamp;
      * output/staging path;
      * output length;
      * row and tag counts;
      * parser and compression mode.

    On restart, a page is skipped only when:
      * a matching manifest entry exists;
      * the expected output/staging file exists and is non-empty;
      * source length matches;
      * source last-write timestamp matches.

    If an output file is deleted or a source page changes, that page is converted again.

    OUTPUT WRITES ARE ATOMIC
    ========================
    Per-page CSV/GZIP/ZIP/staging outputs are first written to a temporary file in the destination
    directory. The temporary file is moved to the final name only after conversion and stream/ZIP
    finalization succeeds. Failed temporary files are removed, and the page remains uncheckpointed.

    The final SingleArchive ZIP is built using the same principle:
      CanaryCsvData.zip.tmp.<pid>.<guid> -> CanaryCsvData.zip

    PARSER / PERFORMANCE
    ====================
    The preferred parser is a streaming Json.NET converter. It reads one token/point at a time and
    writes CSV directly to the output stream, avoiding construction of hundreds of thousands of
    PowerShell objects for a large page.

    If Json.NET is unavailable in the current PowerShell host, the script falls back to
    ConvertFrom-Json and reports that choice in the console. The fallback generally uses more memory
    and CPU.

    -CompressionLevel controls GZIP and ZIP compression and accepts Fastest or Optimal.
    Fastest is useful when conversion throughput matters more than squeezing the final archive size.

    SINGLE-INSTANCE SAFETY
    ======================
    A converter.lock file is held open exclusively for the selected OutputDirectory. A second
    converter process is blocked from the same output tree. This prevents competing manifest
    appends and duplicate/overlapping output writes.

    The converter leaves the original Canary exporter data unchanged.

.EXAMPLE
    # Default: one GZIP-compressed CSV per source page
    .\Convert-CanaryJsonToCsv.ps1 `
        -ExportDirectory ".\CanaryFullExport"

.EXAMPLE
    # Convert continuously while the exporter is running
    .\Convert-CanaryJsonToCsv.ps1 `
        -ExportDirectory ".\CanaryFullExport" `
        -Watch

.EXAMPLE
    # One ZIP file per source page
    .\Convert-CanaryJsonToCsv.ps1 `
        -ExportDirectory ".\CanaryFullExport" `
        -Compression Zip `
        -ZipLayout PerFile

.EXAMPLE
    # One final ZIP containing the complete converted data root.
    # In Watch mode it waits for exporter state.json to indicate completion,
    # then atomically creates CanaryCsvData.zip and exits.
    .\Convert-CanaryJsonToCsv.ps1 `
        -ExportDirectory ".\CanaryFullExport" `
        -Compression Zip `
        -ZipLayout SingleArchive `
        -Watch

.EXAMPLE
    # Plain uncompressed CSV pages
    .\Convert-CanaryJsonToCsv.ps1 `
        -ExportDirectory ".\CanaryFullExport" `
        -Compression None

.NOTES
    Designed for Windows PowerShell 5.1 and PowerShell 7+.
    Source data may be .json, .json.gz, or a mixture of both.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExportDirectory,

    # Defaults to <ExportDirectory>\csv-conversion.
    [string]$OutputDirectory = "",

    # None: plain .csv per page.
    # Gzip: .csv.gz per page.
    # Zip: either one .csv.zip per page or one final archive depending on -ZipLayout.
    [ValidateSet("None", "Gzip", "Zip")]
    [string]$Compression = "Gzip",

    # Used only when -Compression Zip.
    # PerFile: one independent ZIP for every source page; safe/incremental in Watch mode.
    # SingleArchive: checkpoint to plain staging CSVs, then atomically build one final ZIP.
    [ValidateSet("PerFile", "SingleArchive")]
    [string]$ZipLayout = "PerFile",

    # Name of the final ZIP when -Compression Zip -ZipLayout SingleArchive.
    [string]$SingleZipName = "CanaryCsvData.zip",

    # Applies to GZIP and ZIP output. Fastest favors throughput; Optimal favors size.
    [ValidateSet("Fastest", "Optimal")]
    [string]$CompressionLevel = "Optimal",

    # Continuously process new pages produced by the historian exporter.
    [switch]$Watch,

    [ValidateRange(1, 3600)]
    [int]$PollSeconds = 5,

    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 4,

    [ValidateRange(1, 60)]
    [int]$RetryBaseSeconds = 2,

    # Useful for a small validation run. 0 means unlimited.
    # A limited run finalizes SingleArchive after every discovered source page is staged.
    [ValidateRange(0, 100000000)]
    [int]$MaxPages = 0,

    # Re-convert pages even when a matching completed manifest entry exists.
    [switch]$Force,

    # Force the PowerShell object-model parser and skip compiled streaming parsers.
    [switch]$UsePowerShellParser,

    # Number of successfully converted pages between explicit garbage collections.
    # Mainly relevant to the PowerShell parser fallback. 0 disables explicit GC.
    [ValidateRange(0, 10000)]
    [int]$GcEveryPages = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Compression -ne "Zip" -and $ZipLayout -ne "PerFile") {
    throw "-ZipLayout is only meaningful with -Compression Zip. Use -ZipLayout PerFile for non-ZIP output."
}

if ([string]::IsNullOrWhiteSpace($SingleZipName)) {
    throw "SingleZipName cannot be empty."
}
if (-not $SingleZipName.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
    $SingleZipName = $SingleZipName + ".zip"
}

try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch {}
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch {}

# ============================================================
# Paths and runtime setup
# ============================================================

$ExportDirectory = [System.IO.Path]::GetFullPath($ExportDirectory)
$SourceDataDirectory = Join-Path $ExportDirectory "data"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $ExportDirectory "csv-conversion"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$OutputDataDirectory = Join-Path $OutputDirectory "data"
$SingleZipStagingRoot = Join-Path $OutputDirectory "_single-zip-staging"
$SingleZipStagingDataDirectory = Join-Path $SingleZipStagingRoot "data"
$SingleZipPath = Join-Path $OutputDirectory $SingleZipName
$SingleZipStatePath = Join-Path $OutputDirectory "single-archive-state.json"
$LogsDirectory = Join-Path $OutputDirectory "logs"
$ManifestPath = Join-Path $OutputDirectory "conversion-manifest.jsonl"
$SummaryPath = Join-Path $OutputDirectory "conversion-summary.json"
$LockPath = Join-Path $OutputDirectory "converter.lock"
$RunStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
$TextLogPath = Join-Path $LogsDirectory ("conversion-{0}.log" -f $RunStamp)
$EventLogPath = Join-Path $LogsDirectory ("events-{0}.jsonl" -f $RunStamp)

if (-not (Test-Path -LiteralPath $SourceDataDirectory)) {
    throw "Canary exporter data directory does not exist: $SourceDataDirectory"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDataDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $LogsDirectory -Force | Out-Null
if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") {
    New-Item -ItemType Directory -Path $SingleZipStagingDataDirectory -Force | Out-Null
}

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:ConvertedThisRun = 0L
$script:RowsThisRun = 0L
$script:InputBytesThisRun = 0L
$script:OutputBytesThisRun = 0L
$script:FailedThisRun = 0L
$script:SkippedThisRun = 0L
$script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:StreamingConverterAvailable = $false
$script:ConverterMode = "PowerShell"
$script:SingleArchiveBuiltThisRun = $false
$script:SingleArchiveBytes = 0L

# ============================================================
# Console and structured logging
# ============================================================

function Get-LevelColor {
    param([string]$Level)

    switch ($Level.ToUpperInvariant()) {
        "PHASE" { return "Cyan" }
        "INFO"  { return "Gray" }
        "SCAN"  { return "DarkCyan" }
        "DATA"  { return "White" }
        "OK"    { return "Green" }
        "SKIP"  { return "DarkGray" }
        "WARN"  { return "Yellow" }
        "RETRY" { return "Magenta" }
        "ERROR" { return "Red" }
        default  { return "Gray" }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Event = "message",
        $Data = $null
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $line = "{0} [{1}] {2}" -f $timestamp, $Level.ToUpperInvariant(), $Message

    Write-Host $line -ForegroundColor (Get-LevelColor -Level $Level)
    [System.IO.File]::AppendAllText($TextLogPath, $line + [Environment]::NewLine, $script:Utf8NoBom)

    $record = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        level = $Level.ToUpperInvariant()
        event = $Event
        message = $Message
    }

    if ($null -ne $Data) {
        $record["data"] = $Data
    }

    $jsonLine = $record | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::AppendAllText($EventLogPath, $jsonLine + [Environment]::NewLine, $script:Utf8NoBom)
}

function Format-Bytes {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    return ("{0:N0} B" -f $Bytes)
}

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalDays -ge 1) {
        return ("{0:N0}d {1:00}:{2:00}:{3:00}" -f [Math]::Floor($ts.TotalDays), $ts.Hours, $ts.Minutes, $ts.Seconds)
    }
    return ("{0:00}:{1:00}:{2:00}" -f [Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

# ============================================================
# Single-instance lock
# ============================================================

$lockStream = $null
try {
    $lockStream = [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )

    $lockStream.SetLength(0)
    $lockWriter = [System.IO.StreamWriter]::new($lockStream, $script:Utf8NoBom, 1024, $true)
    $lockWriter.WriteLine("PID={0}" -f $PID)
    $lockWriter.WriteLine("StartedUtc={0}" -f (Get-Date).ToUniversalTime().ToString("o"))
    $lockWriter.Flush()
}
catch {
    throw "Another converter appears to be using this OutputDirectory, or the lock file cannot be opened: $LockPath. $($_.Exception.Message)"
}

# ============================================================
# Initialize a fast streaming converter
#
# Selection order:
#   1. Json.NET JsonTextReader, but only when Newtonsoft.Json is already loaded.
#   2. Dependency-free compiled .NET Framework parser using JsonReaderWriterFactory.
#   3. ConvertFrom-Json only as a last-resort fallback.
#
# The second option supports Windows PowerShell 5.1 systems without Json.NET.
# It stays inside compiled C# for the hot loop, reads the JSON as a forward-only stream, and writes
# CSV rows directly. It therefore avoids creating ~500,000+ PSCustomObject instances per page.
# ============================================================

function Initialize-StreamingConverter {
    if ($UsePowerShellParser) {
        $script:StreamingConverterAvailable = $false
        $script:ConverterMode = "PowerShell"
        Write-Log -Level "WARN" -Event "parser_selected" -Message (
            "PowerShell ConvertFrom-Json parser explicitly requested. This is expected to be very slow for large Canary pages."
        )
        return
    }

    # ========================================================
    # Option 1: Json.NET, if the host already has it loaded.
    # ========================================================
    try {
        $newtonsoftAssembly = @(
            [AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object { $_.GetName().Name -eq "Newtonsoft.Json" }
        ) | Select-Object -First 1

        if ($null -ne $newtonsoftAssembly) {
            $existingType = ([System.Management.Automation.PSTypeName]'CanaryCsvStreamingConverter').Type
            if ($null -eq $existingType) {
                $source = @'
using System;
using System.IO;
using System.Text;
using System.Globalization;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

public sealed class CanaryCsvConversionStats
{
    public long Rows { get; set; }
    public int Tags { get; set; }
    public string StatusCode { get; set; }
}

public static class CanaryCsvStreamingConverter
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static CanaryCsvConversionStats Convert(Stream input, Stream output, char delimiter)
    {
        CanaryCsvConversionStats stats = new CanaryCsvConversionStats();
        string statusCode = null;
        string errorText = null;

        using (StreamReader sr = new StreamReader(input, new UTF8Encoding(false), true, 1048576, true))
        using (JsonTextReader reader = new JsonTextReader(sr))
        using (StreamWriter writer = new StreamWriter(output, new UTF8Encoding(false), 1048576, true))
        {
            reader.DateParseHandling = DateParseHandling.None;
            reader.FloatParseHandling = FloatParseHandling.Double;
            WriteHeader(writer, delimiter);

            if (!reader.Read() || reader.TokenType != JsonToken.StartObject)
                throw new InvalidDataException("Canary page JSON does not start with an object.");

            while (reader.Read())
            {
                if (reader.TokenType == JsonToken.EndObject) break;
                if (reader.TokenType != JsonToken.PropertyName) continue;

                string propertyName = Convert.ToString(reader.Value, Inv);
                if (!reader.Read()) throw new EndOfStreamException("Unexpected end of Canary page JSON.");

                if (String.Equals(propertyName, "statusCode", StringComparison.OrdinalIgnoreCase))
                {
                    statusCode = ScalarToString(reader);
                    continue;
                }
                if (String.Equals(propertyName, "errors", StringComparison.OrdinalIgnoreCase))
                {
                    errorText = ReadAnyAsCompactString(reader);
                    continue;
                }
                if (String.Equals(propertyName, "data", StringComparison.OrdinalIgnoreCase))
                {
                    ReadDataObject(reader, writer, delimiter, stats);
                    continue;
                }
                SkipCurrentValue(reader);
            }

            writer.Flush();
        }

        stats.StatusCode = statusCode ?? "";
        if (!String.IsNullOrWhiteSpace(statusCode) && !String.Equals(statusCode, "Good", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Canary page status is '" + statusCode + "'. Errors: " + (errorText ?? ""));

        return stats;
    }

    private static void ReadDataObject(JsonTextReader reader, StreamWriter writer, char delimiter, CanaryCsvConversionStats stats)
    {
        if (reader.TokenType == JsonToken.Null) return;
        if (reader.TokenType != JsonToken.StartObject)
            throw new InvalidDataException("Canary page 'data' value is not an object.");

        while (reader.Read())
        {
            if (reader.TokenType == JsonToken.EndObject) break;
            if (reader.TokenType != JsonToken.PropertyName) continue;

            string tag = Convert.ToString(reader.Value, Inv) ?? "";
            if (!reader.Read()) throw new EndOfStreamException("Unexpected end while reading tag data.");
            stats.Tags++;

            if (reader.TokenType == JsonToken.Null) continue;
            if (reader.TokenType != JsonToken.StartArray)
            {
                SkipCurrentValue(reader);
                continue;
            }

            while (reader.Read())
            {
                if (reader.TokenType == JsonToken.EndArray) break;

                string timestamp = "";
                string value = "";
                string quality = "";

                if (reader.TokenType == JsonToken.StartObject)
                    ReadObjectPoint(reader, out timestamp, out value, out quality);
                else if (reader.TokenType == JsonToken.StartArray)
                    ReadArrayPoint(reader, out timestamp, out value, out quality);
                else if (reader.TokenType == JsonToken.Null)
                    continue;
                else
                    throw new InvalidDataException("Unexpected TVQ token for tag '" + tag + "': " + reader.TokenType);

                WriteCsvRow(writer, delimiter, tag, timestamp, value, quality);
                stats.Rows++;
            }
        }
    }

    private static void ReadObjectPoint(JsonTextReader reader, out string timestamp, out string value, out string quality)
    {
        timestamp = ""; value = ""; quality = "";
        while (reader.Read())
        {
            if (reader.TokenType == JsonToken.EndObject) break;
            if (reader.TokenType != JsonToken.PropertyName) continue;
            string name = Convert.ToString(reader.Value, Inv) ?? "";
            if (!reader.Read()) throw new EndOfStreamException("Unexpected end inside TVQ object.");
            string field = ReadAnyAsCompactString(reader);
            if (String.Equals(name, "t", StringComparison.OrdinalIgnoreCase)) timestamp = field;
            else if (String.Equals(name, "v", StringComparison.OrdinalIgnoreCase)) value = field;
            else if (String.Equals(name, "q", StringComparison.OrdinalIgnoreCase)) quality = field;
        }
    }

    private static void ReadArrayPoint(JsonTextReader reader, out string timestamp, out string value, out string quality)
    {
        timestamp = ""; value = ""; quality = "";
        int index = 0;
        while (reader.Read())
        {
            if (reader.TokenType == JsonToken.EndArray) break;
            string field = ReadAnyAsCompactString(reader);
            if (index == 0) timestamp = field;
            else if (index == 1) value = field;
            else if (index == 2) quality = field;
            index++;
        }
    }

    private static string ReadAnyAsCompactString(JsonTextReader reader)
    {
        if (reader.TokenType == JsonToken.StartObject || reader.TokenType == JsonToken.StartArray)
        {
            JToken token = JToken.ReadFrom(reader);
            return token.ToString(Formatting.None);
        }
        return ScalarToString(reader);
    }

    private static string ScalarToString(JsonTextReader reader)
    {
        if (reader.TokenType == JsonToken.Null || reader.TokenType == JsonToken.Undefined) return "";
        object value = reader.Value;
        if (value == null) return "";
        if (value is double) return ((double)value).ToString("R", Inv);
        if (value is float) return ((float)value).ToString("R", Inv);
        if (value is decimal) return ((decimal)value).ToString(Inv);
        if (value is DateTime) return ((DateTime)value).ToString("o", Inv);
        if (value is DateTimeOffset) return ((DateTimeOffset)value).ToString("o", Inv);
        if (value is IFormattable) return ((IFormattable)value).ToString(null, Inv);
        return Convert.ToString(value, Inv) ?? "";
    }

    private static void SkipCurrentValue(JsonTextReader reader)
    {
        if (reader.TokenType == JsonToken.StartObject || reader.TokenType == JsonToken.StartArray)
            JToken.ReadFrom(reader);
    }

    private static void WriteHeader(StreamWriter writer, char delimiter)
    {
        writer.Write("Tag"); writer.Write(delimiter);
        writer.Write("Timestamp"); writer.Write(delimiter);
        writer.Write("Value"); writer.Write(delimiter);
        writer.WriteLine("Quality");
    }

    private static void WriteCsvRow(StreamWriter writer, char delimiter, string tag, string timestamp, string value, string quality)
    {
        WriteCsvField(writer, delimiter, tag); writer.Write(delimiter);
        WriteCsvField(writer, delimiter, timestamp); writer.Write(delimiter);
        WriteCsvField(writer, delimiter, value); writer.Write(delimiter);
        WriteCsvField(writer, delimiter, quality); writer.WriteLine();
    }

    private static void WriteCsvField(StreamWriter writer, char delimiter, string value)
    {
        if (value == null) value = "";
        bool quote = value.IndexOf(delimiter) >= 0 || value.IndexOf('"') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0;
        if (!quote) { writer.Write(value); return; }
        writer.Write('"'); writer.Write(value.Replace("\"", "\"\"")); writer.Write('"');
    }
}
'@

                $assemblyLocation = $newtonsoftAssembly.Location
                if ([string]::IsNullOrWhiteSpace($assemblyLocation)) {
                    throw "Newtonsoft.Json is loaded but does not expose a usable assembly path."
                }
                Add-Type -TypeDefinition $source -ReferencedAssemblies $assemblyLocation -ErrorAction Stop
            }

            $script:StreamingConverterAvailable = $true
            $script:ConverterMode = "StreamingJsonNet"
            Write-Log -Level "OK" -Event "parser_selected" -Message (
                "Streaming Json.NET parser enabled. Large pages will be converted entirely in compiled code."
            )
            return
        }
    }
    catch {
        Write-Log -Level "WARN" -Event "jsonnet_parser_failed" -Message (
            "Json.NET was present but its streaming converter could not be initialized. Trying the built-in compiled parser. $($_.Exception.Message)"
        )
    }

    # ========================================================
    # Option 2: dependency-free compiled .NET streaming parser.
    # JsonReaderWriterFactory is part of .NET Framework and exposes
    # a forward-only JSON reader through XmlDictionaryReader.
    # ========================================================
    try {
        try { Add-Type -AssemblyName System.Runtime.Serialization -ErrorAction Stop } catch {}

        $existingBuiltinType = ([System.Management.Automation.PSTypeName]'CanaryCsvBuiltInStreamingConverter').Type
        if ($null -eq $existingBuiltinType) {
            $builtinSource = @'
using System;
using System.IO;
using System.Text;
using System.Xml;
using System.Globalization;
using System.Runtime.Serialization.Json;

public sealed class CanaryCsvBuiltInConversionStats
{
    public long Rows { get; set; }
    public int Tags { get; set; }
    public string StatusCode { get; set; }
}

public static class CanaryCsvBuiltInStreamingConverter
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static CanaryCsvBuiltInConversionStats Convert(Stream input, Stream output, char delimiter)
    {
        CanaryCsvBuiltInConversionStats stats = new CanaryCsvBuiltInConversionStats();
        string statusCode = "";
        string errors = "";

        XmlDictionaryReaderQuotas quotas = new XmlDictionaryReaderQuotas();
        quotas.MaxDepth = 128;
        quotas.MaxStringContentLength = Int32.MaxValue;
        quotas.MaxArrayLength = Int32.MaxValue;
        quotas.MaxBytesPerRead = 1048576;
        quotas.MaxNameTableCharCount = Int32.MaxValue;

        using (XmlDictionaryReader reader = JsonReaderWriterFactory.CreateJsonReader(input, Encoding.UTF8, quotas, null))
        using (StreamWriter writer = new StreamWriter(output, new UTF8Encoding(false), 1048576, true))
        {
            writer.Write("Tag"); writer.Write(delimiter);
            writer.Write("Timestamp"); writer.Write(delimiter);
            writer.Write("Value"); writer.Write(delimiter);
            writer.WriteLine("Quality");

            reader.MoveToContent();
            if (reader.NodeType != XmlNodeType.Element)
                throw new InvalidDataException("Canary page JSON does not contain a root object.");

            if (reader.IsEmptyElement)
                throw new InvalidDataException("Canary page JSON root object is empty.");

            reader.ReadStartElement();

            while (!reader.EOF && reader.NodeType != XmlNodeType.EndElement)
            {
                if (reader.NodeType != XmlNodeType.Element)
                {
                    reader.Read();
                    continue;
                }

                string name = XmlConvert.DecodeName(reader.LocalName);

                if (String.Equals(name, "statusCode", StringComparison.OrdinalIgnoreCase))
                {
                    statusCode = ReadScalarElement(reader);
                    continue;
                }

                if (String.Equals(name, "errors", StringComparison.OrdinalIgnoreCase))
                {
                    errors = ReadValueAsJsonOrScalar(reader);
                    continue;
                }

                if (String.Equals(name, "data", StringComparison.OrdinalIgnoreCase))
                {
                    ReadData(reader, writer, delimiter, stats);
                    continue;
                }

                reader.Skip();
            }

            writer.Flush();
        }

        stats.StatusCode = statusCode ?? "";
        if (!String.IsNullOrWhiteSpace(statusCode) && !String.Equals(statusCode, "Good", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Canary page status is '" + statusCode + "'. Errors: " + errors);

        return stats;
    }

    private static void ReadData(XmlDictionaryReader reader, StreamWriter writer, char delimiter, CanaryCsvBuiltInConversionStats stats)
    {
        string type = reader.GetAttribute("type") ?? "";
        if (!String.Equals(type, "object", StringComparison.OrdinalIgnoreCase) && reader.IsEmptyElement)
        {
            reader.Read();
            return;
        }

        if (reader.IsEmptyElement)
        {
            reader.Read();
            return;
        }

        reader.ReadStartElement();
        while (!reader.EOF && reader.NodeType != XmlNodeType.EndElement)
        {
            if (reader.NodeType != XmlNodeType.Element)
            {
                reader.Read();
                continue;
            }

            string tag = XmlConvert.DecodeName(reader.LocalName);
            stats.Tags++;
            ReadTagArray(reader, writer, delimiter, stats, tag);
        }
        if (reader.NodeType == XmlNodeType.EndElement) reader.ReadEndElement();
    }

    private static void ReadTagArray(XmlDictionaryReader reader, StreamWriter writer, char delimiter, CanaryCsvBuiltInConversionStats stats, string tag)
    {
        if (reader.IsEmptyElement)
        {
            reader.Read();
            return;
        }

        reader.ReadStartElement();
        while (!reader.EOF && reader.NodeType != XmlNodeType.EndElement)
        {
            if (reader.NodeType != XmlNodeType.Element)
            {
                reader.Read();
                continue;
            }

            string timestamp = "";
            string value = "";
            string quality = "";
            ReadPoint(reader, out timestamp, out value, out quality);
            WriteCsvRow(writer, delimiter, tag, timestamp, value, quality);
            stats.Rows++;
        }
        if (reader.NodeType == XmlNodeType.EndElement) reader.ReadEndElement();
    }

    private static void ReadPoint(XmlDictionaryReader reader, out string timestamp, out string value, out string quality)
    {
        timestamp = ""; value = ""; quality = "";
        string pointType = reader.GetAttribute("type") ?? "";

        if (reader.IsEmptyElement)
        {
            reader.Read();
            return;
        }

        reader.ReadStartElement();
        int arrayIndex = 0;

        while (!reader.EOF && reader.NodeType != XmlNodeType.EndElement)
        {
            if (reader.NodeType != XmlNodeType.Element)
            {
                reader.Read();
                continue;
            }

            string name = XmlConvert.DecodeName(reader.LocalName);
            string field = ReadValueAsJsonOrScalar(reader);

            if (String.Equals(pointType, "array", StringComparison.OrdinalIgnoreCase))
            {
                if (arrayIndex == 0) timestamp = field;
                else if (arrayIndex == 1) value = field;
                else if (arrayIndex == 2) quality = field;
                arrayIndex++;
            }
            else
            {
                if (String.Equals(name, "t", StringComparison.OrdinalIgnoreCase)) timestamp = field;
                else if (String.Equals(name, "v", StringComparison.OrdinalIgnoreCase)) value = field;
                else if (String.Equals(name, "q", StringComparison.OrdinalIgnoreCase)) quality = field;
            }
        }
        if (reader.NodeType == XmlNodeType.EndElement) reader.ReadEndElement();
    }

    private static string ReadScalarElement(XmlDictionaryReader reader)
    {
        if (reader.IsEmptyElement)
        {
            reader.Read();
            return "";
        }
        return reader.ReadElementContentAsString();
    }

    private static string ReadValueAsJsonOrScalar(XmlDictionaryReader reader)
    {
        string type = reader.GetAttribute("type") ?? "";
        if (String.Equals(type, "object", StringComparison.OrdinalIgnoreCase) ||
            String.Equals(type, "array", StringComparison.OrdinalIgnoreCase))
            return ReadComplexJson(reader, type);

        return ReadScalarElement(reader);
    }

    private static string ReadComplexJson(XmlDictionaryReader reader, string type)
    {
        StringBuilder sb = new StringBuilder();
        bool isArray = String.Equals(type, "array", StringComparison.OrdinalIgnoreCase);
        sb.Append(isArray ? '[' : '{');

        if (reader.IsEmptyElement)
        {
            reader.Read();
            sb.Append(isArray ? ']' : '}');
            return sb.ToString();
        }

        reader.ReadStartElement();
        bool first = true;
        while (!reader.EOF && reader.NodeType != XmlNodeType.EndElement)
        {
            if (reader.NodeType != XmlNodeType.Element)
            {
                reader.Read();
                continue;
            }

            if (!first) sb.Append(',');
            first = false;

            string childName = XmlConvert.DecodeName(reader.LocalName);
            string childType = reader.GetAttribute("type") ?? "";

            if (!isArray)
            {
                AppendJsonString(sb, childName);
                sb.Append(':');
            }

            AppendElementAsJson(reader, childType, sb);
        }
        if (reader.NodeType == XmlNodeType.EndElement) reader.ReadEndElement();

        sb.Append(isArray ? ']' : '}');
        return sb.ToString();
    }

    private static void AppendElementAsJson(XmlDictionaryReader reader, string type, StringBuilder sb)
    {
        if (String.Equals(type, "object", StringComparison.OrdinalIgnoreCase) ||
            String.Equals(type, "array", StringComparison.OrdinalIgnoreCase))
        {
            sb.Append(ReadComplexJson(reader, type));
            return;
        }

        string value = ReadScalarElement(reader);
        if (String.Equals(type, "number", StringComparison.OrdinalIgnoreCase) ||
            String.Equals(type, "boolean", StringComparison.OrdinalIgnoreCase))
        {
            sb.Append(value);
        }
        else if (String.Equals(type, "null", StringComparison.OrdinalIgnoreCase))
        {
            sb.Append("null");
        }
        else
        {
            AppendJsonString(sb, value);
        }
    }

    private static void AppendJsonString(StringBuilder sb, string value)
    {
        if (value == null) value = "";
        sb.Append('"');
        foreach (char c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append("\\u" + ((int)c).ToString("x4", Inv));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    private static void WriteCsvRow(StreamWriter writer, char delimiter, string tag, string timestamp, string value, string quality)
    {
        WriteCsvField(writer, delimiter, tag); writer.Write(delimiter);
        WriteCsvField(writer, delimiter, timestamp); writer.Write(delimiter);
        WriteCsvField(writer, delimiter, value); writer.Write(delimiter);
        WriteCsvField(writer, delimiter, quality); writer.WriteLine();
    }

    private static void WriteCsvField(StreamWriter writer, char delimiter, string value)
    {
        if (value == null) value = "";
        bool quote = value.IndexOf(delimiter) >= 0 || value.IndexOf('"') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0;
        if (!quote)
        {
            writer.Write(value);
            return;
        }
        writer.Write('"');
        writer.Write(value.Replace("\"", "\"\""));
        writer.Write('"');
    }
}
'@

            $runtimeAssembly = [System.Runtime.Serialization.Json.JsonReaderWriterFactory].Assembly.Location
            $xmlAssembly = [System.Xml.XmlReader].Assembly.Location
            $references = @($runtimeAssembly, $xmlAssembly) | Sort-Object -Unique
            Add-Type -TypeDefinition $builtinSource -ReferencedAssemblies $references -ErrorAction Stop
        }

        $script:StreamingConverterAvailable = $true
        $script:ConverterMode = "StreamingBuiltInDotNet"
        Write-Log -Level "OK" -Event "parser_selected" -Message (
            "Compiled built-in .NET streaming parser enabled. Json.NET is not required; large pages will not use ConvertFrom-Json."
        )
        return
    }
    catch {
        $script:StreamingConverterAvailable = $false
        $script:ConverterMode = "PowerShell"
        Write-Log -Level "ERROR" -Event "streaming_parser_unavailable" -Message (
            "Could not initialize either compiled streaming parser. Falling back to ConvertFrom-Json, which is extremely slow for large pages. $($_.Exception.Message)"
        )
    }
}

# ============================================================
# CSV helpers for PowerShell parser fallback
# ============================================================

function Convert-ValueToInvariantText {
    param($Value)

    if ($null -eq $Value) { return "" }

    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [DateTimeOffset]) { return $Value.ToString("o", [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTime]) { return $Value.ToString("o", [Globalization.CultureInfo]::InvariantCulture) }

    if ($Value -is [System.Collections.IDictionary] -or
        ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]))) {
        return ($Value | ConvertTo-Json -Depth 20 -Compress)
    }

    if ($Value -is [PSCustomObject]) {
        return ($Value | ConvertTo-Json -Depth 20 -Compress)
    }

    if ($Value -is [System.IFormattable]) {
        return $Value.ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Convert-ToCsvField {
    param(
        [AllowNull()]$Value,
        [char]$Delimiter = ','
    )

    $text = Convert-ValueToInvariantText -Value $Value
    if ($null -eq $text) { $text = "" }

    if ($text.IndexOf($Delimiter) -ge 0 -or
        $text.IndexOf('"') -ge 0 -or
        $text.IndexOf("`r") -ge 0 -or
        $text.IndexOf("`n") -ge 0) {
        return '"' + $text.Replace('"', '""') + '"'
    }

    return $text
}

function Convert-PageWithPowerShell {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$InputStream,
        [Parameter(Mandatory = $true)][System.IO.Stream]$OutputStream
    )

    $reader = [System.IO.StreamReader]::new($InputStream, $script:Utf8NoBom, $true, 65536, $true)
    try {
        $json = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    try {
        $parsed = $json | ConvertFrom-Json
    }
    finally {
        $json = $null
    }

    if ($null -eq $parsed) {
        throw "JSON parsed to null."
    }

    $statusProperty = $parsed.PSObject.Properties["statusCode"]
    if ($null -ne $statusProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$statusProperty.Value) -and
        [string]$statusProperty.Value -ne "Good") {
        $errors = ""
        $errorsProperty = $parsed.PSObject.Properties["errors"]
        if ($null -ne $errorsProperty) {
            $errors = @($errorsProperty.Value) -join "; "
        }
        throw "Canary page status is '$($statusProperty.Value)'. Errors: $errors"
    }

    $dataProperty = $parsed.PSObject.Properties["data"]
    if ($null -eq $dataProperty -or $null -eq $dataProperty.Value) {
        throw "Canary page does not contain a data object."
    }

    $writer = [System.IO.StreamWriter]::new($OutputStream, $script:Utf8NoBom, 65536, $true)
    $rows = 0L
    $tags = 0
    $buffer = New-Object System.Text.StringBuilder 1048576

    try {
        $writer.WriteLine("Tag,Timestamp,Value,Quality")

        foreach ($property in $dataProperty.Value.PSObject.Properties) {
            $tags++
            $tag = [string]$property.Name

            foreach ($point in @($property.Value)) {
                if ($null -eq $point) { continue }

                $timestamp = $null
                $value = $null
                $quality = $null

                if ($point -is [System.Array]) {
                    $items = @($point)
                    if ($items.Count -ge 1) { $timestamp = $items[0] }
                    if ($items.Count -ge 2) { $value = $items[1] }
                    if ($items.Count -ge 3) { $quality = $items[2] }
                }
                else {
                    $p = $point.PSObject.Properties["t"]
                    if ($null -ne $p) { $timestamp = $p.Value }
                    $p = $point.PSObject.Properties["v"]
                    if ($null -ne $p) { $value = $p.Value }
                    $p = $point.PSObject.Properties["q"]
                    if ($null -ne $p) { $quality = $p.Value }
                }

                [void]$buffer.Append((Convert-ToCsvField -Value $tag))
                [void]$buffer.Append(',')
                [void]$buffer.Append((Convert-ToCsvField -Value $timestamp))
                [void]$buffer.Append(',')
                [void]$buffer.Append((Convert-ToCsvField -Value $value))
                [void]$buffer.Append(',')
                [void]$buffer.Append((Convert-ToCsvField -Value $quality))
                [void]$buffer.Append("`r`n")

                $rows++

                if ($buffer.Length -ge 1MB) {
                    $writer.Write($buffer.ToString())
                    [void]$buffer.Clear()
                }
            }
        }

        if ($buffer.Length -gt 0) {
            $writer.Write($buffer.ToString())
            [void]$buffer.Clear()
        }

        $writer.Flush()
    }
    finally {
        $writer.Dispose()
        $parsed = $null
        $buffer = $null
    }

    return [PSCustomObject]@{
        Rows = $rows
        Tags = $tags
        StatusCode = "Good"
    }
}

# ============================================================
# Manifest and page discovery
# ============================================================

function Load-ManifestIndex {
    $index = @{}

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $index
    }

    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($ManifestPath)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $record = $line | ConvertFrom-Json
            if ($null -ne $record -and -not [string]::IsNullOrWhiteSpace([string]$record.sourceRelative)) {
                $index[[string]$record.sourceRelative] = $record
            }
        }
        catch {
            # An interrupted append can leave one incomplete trailing JSONL record.
            Write-Log -Level "WARN" -Event "manifest_line_ignored" -Message (
                "Ignoring malformed conversion manifest line $lineNumber. Earlier complete records remain valid."
            )
        }
    }

    return $index
}

function Append-ManifestRecord {
    param([Parameter(Mandatory = $true)]$Record)

    $line = $Record | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::AppendAllText($ManifestPath, $line + [Environment]::NewLine, $script:Utf8NoBom)
}

function Get-RelativeSourcePath {
    param([Parameter(Mandatory = $true)][string]$FullName)

    $base = $SourceDataDirectory.TrimEnd('\', '/')
    $relative = $FullName.Substring($base.Length).TrimStart('\', '/')
    return $relative.Replace('/', '\')
}

function Get-OutputPathForSource {
    param([Parameter(Mandatory = $true)][string]$SourceRelative)

    $relative = $SourceRelative
    if ($relative.EndsWith(".json.gz", [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring(0, $relative.Length - ".json.gz".Length)
    }
    elseif ($relative.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring(0, $relative.Length - ".json".Length)
    }

    if ($Compression -eq "Gzip") {
        $relative = $relative + ".csv.gz"
        return Join-Path $OutputDataDirectory $relative
    }

    if ($Compression -eq "Zip" -and $ZipLayout -eq "PerFile") {
        $relative = $relative + ".csv.zip"
        return Join-Path $OutputDataDirectory $relative
    }

    # Plain CSV mode and SingleArchive staging both use plain CSV files.
    $relative = $relative + ".csv"
    if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") {
        return Join-Path $SingleZipStagingDataDirectory $relative
    }

    return Join-Path $OutputDataDirectory $relative
}

function Test-AlreadyConverted {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory = $true)][string]$SourceRelative,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][hashtable]$ManifestIndex
    )

    if ($Force) { return $false }
    if (-not $ManifestIndex.ContainsKey($SourceRelative)) { return $false }

    $record = $ManifestIndex[$SourceRelative]

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { return $false }

    $outputInfo = Get-Item -LiteralPath $OutputPath
    if ($outputInfo.Length -le 0) { return $false }

    if ([long]$record.sourceLength -ne [long]$SourceFile.Length) { return $false }
    if ([long]$record.sourceLastWriteTimeUtcTicks -ne [long]$SourceFile.LastWriteTimeUtc.Ticks) { return $false }

    return $true
}

function Get-SourcePages {
    return @(
        Get-ChildItem -LiteralPath $SourceDataDirectory -File -Recurse -ErrorAction Stop |
            Where-Object {
                $_.Name -notlike "*.tmp.*" -and
                (
                    $_.Name.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase) -or
                    $_.Name.EndsWith(".json.gz", [System.StringComparison]::OrdinalIgnoreCase)
                )
            } |
            Sort-Object FullName
    )
}

function Get-DotNetCompressionLevel {
    if ($CompressionLevel -eq "Fastest") {
        return [System.IO.Compression.CompressionLevel]::Fastest
    }
    return [System.IO.Compression.CompressionLevel]::Optimal
}

function Get-PagePackagingMode {
    if ($Compression -eq "Gzip") { return "Gzip" }
    if ($Compression -eq "Zip" -and $ZipLayout -eq "PerFile") { return "ZipPerFile" }
    if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") { return "SingleArchiveStaging" }
    return "Plain"
}

# ============================================================
# Atomic output handling
# ============================================================

function Move-CompletedFile {
    param(
        [Parameter(Mandatory = $true)][string]$TemporaryPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        try {
            [System.IO.File]::Replace($TemporaryPath, $DestinationPath, $null)
            return
        }
        catch {
            Remove-Item -LiteralPath $DestinationPath -Force
        }
    }

    [System.IO.File]::Move($TemporaryPath, $DestinationPath)
}

# ============================================================
# Page conversion
# ============================================================

function Convert-OnePage {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory = $true)][string]$SourceRelative,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $outputDirectoryForPage = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Path $outputDirectoryForPage -Force | Out-Null

    $tempPath = "{0}.tmp.{1}.{2}" -f $OutputPath, $PID, ([Guid]::NewGuid().ToString("N"))
    $pagePackagingMode = Get-PagePackagingMode
    $dotNetCompressionLevel = Get-DotNetCompressionLevel

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $inputFileStream = $null
        $inputGzipStream = $null
        $inputPayloadStream = $null
        $outputFileStream = $null
        $outputPayloadStream = $null
        $zipArchive = $null
        $zipEntryStream = $null

        try {
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force
            }

            # FileShare.Read allows the exporter and converter to coexist. The exporter exposes
            # page-*.json / page-*.json.gz only after its own atomic write has completed.
            $inputFileStream = [System.IO.File]::Open(
                $SourceFile.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )

            $inputPayloadStream = $inputFileStream
            if ($SourceFile.Name.EndsWith(".json.gz", [System.StringComparison]::OrdinalIgnoreCase)) {
                $inputGzipStream = [System.IO.Compression.GZipStream]::new(
                    $inputFileStream,
                    [System.IO.Compression.CompressionMode]::Decompress,
                    $true
                )
                $inputPayloadStream = $inputGzipStream
            }

            $outputFileStream = [System.IO.File]::Open(
                $tempPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            switch ($pagePackagingMode) {
                "Gzip" {
                    $outputPayloadStream = [System.IO.Compression.GZipStream]::new(
                        $outputFileStream,
                        $dotNetCompressionLevel,
                        $true
                    )
                }
                "ZipPerFile" {
                    $zipArchive = [System.IO.Compression.ZipArchive]::new(
                        $outputFileStream,
                        [System.IO.Compression.ZipArchiveMode]::Create,
                        $true
                    )
                    # Removing only the outer .zip leaves the intended CSV entry name.
                    # Example: page-000001.csv.zip -> page-000001.csv.
                    $entryName = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
                    $zipEntry = $zipArchive.CreateEntry($entryName, $dotNetCompressionLevel)
                    $zipEntryStream = $zipEntry.Open()
                    $outputPayloadStream = $zipEntryStream
                }
                default {
                    # None and SingleArchive both write a plain CSV page. In SingleArchive mode
                    # this is the durable staging file that will later be packed into one ZIP.
                    $outputPayloadStream = $outputFileStream
                }
            }

            if ($script:ConverterMode -eq "StreamingJsonNet") {
                $stats = [CanaryCsvStreamingConverter]::Convert($inputPayloadStream, $outputPayloadStream, ',')
            }
            elseif ($script:ConverterMode -eq "StreamingBuiltInDotNet") {
                $stats = [CanaryCsvBuiltInStreamingConverter]::Convert($inputPayloadStream, $outputPayloadStream, ',')
            }
            else {
                $stats = Convert-PageWithPowerShell -InputStream $inputPayloadStream -OutputStream $outputPayloadStream
            }

            # Finalize wrapper streams in the correct order before publishing the temporary file.
            if ($pagePackagingMode -eq "Gzip" -and $null -ne $outputPayloadStream) {
                $outputPayloadStream.Dispose()
                $outputPayloadStream = $null
            }
            elseif ($pagePackagingMode -eq "ZipPerFile") {
                if ($null -ne $zipEntryStream) {
                    $zipEntryStream.Dispose()
                    $zipEntryStream = $null
                    $outputPayloadStream = $null
                }
                if ($null -ne $zipArchive) {
                    $zipArchive.Dispose()
                    $zipArchive = $null
                }
            }

            if ($null -ne $outputFileStream) {
                $outputFileStream.Flush()
                $outputFileStream.Dispose()
                $outputFileStream = $null
            }

            if ($null -ne $inputGzipStream) {
                $inputGzipStream.Dispose()
                $inputGzipStream = $null
            }
            if ($null -ne $inputFileStream) {
                $inputFileStream.Dispose()
                $inputFileStream = $null
            }

            Move-CompletedFile -TemporaryPath $tempPath -DestinationPath $OutputPath
            $sw.Stop()

            $outputInfo = Get-Item -LiteralPath $OutputPath

            return [PSCustomObject]@{
                Success = $true
                Rows = [long]$stats.Rows
                Tags = [int]$stats.Tags
                Seconds = $sw.Elapsed.TotalSeconds
                OutputBytes = [long]$outputInfo.Length
                Attempt = $attempt
                Error = $null
            }
        }
        catch {
            $sw.Stop()
            $failure = $_.Exception.Message

            if ($null -ne $zipEntryStream) { try { $zipEntryStream.Dispose() } catch {} }
            if ($null -ne $zipArchive) { try { $zipArchive.Dispose() } catch {} }
            if ($null -ne $outputPayloadStream -and $outputPayloadStream -ne $outputFileStream -and $outputPayloadStream -ne $zipEntryStream) {
                try { $outputPayloadStream.Dispose() } catch {}
            }
            if ($null -ne $outputFileStream) { try { $outputFileStream.Dispose() } catch {} }
            if ($null -ne $inputGzipStream) { try { $inputGzipStream.Dispose() } catch {} }
            if ($null -ne $inputFileStream) { try { $inputFileStream.Dispose() } catch {} }
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }

            if ($attempt -lt $MaxAttempts) {
                $delay = [Math]::Min(60.0, ($RetryBaseSeconds * [Math]::Pow(2, $attempt - 1)) + (Get-Random -Minimum 0 -Maximum 1000) / 1000.0)
                Write-Log -Level "RETRY" -Event "page_retry" -Message (
                    "Conversion failed for $SourceRelative on attempt $attempt/$MaxAttempts. Retrying in $([Math]::Round($delay, 1))s. $failure"
                ) -Data @{
                    source = $SourceRelative
                    attempt = $attempt
                    maxAttempts = $MaxAttempts
                    delaySeconds = $delay
                    error = $failure
                }
                Start-Sleep -Milliseconds ([int]($delay * 1000))
                continue
            }

            return [PSCustomObject]@{
                Success = $false
                Rows = 0L
                Tags = 0
                Seconds = $sw.Elapsed.TotalSeconds
                OutputBytes = 0L
                Attempt = $attempt
                Error = $failure
            }
        }
    }
}

# ============================================================
# Single ZIP archive finalization
# ============================================================

function Test-ExporterComplete {
    $exporterStatePath = Join-Path $ExportDirectory "state.json"
    if (-not (Test-Path -LiteralPath $exporterStatePath -PathType Leaf)) {
        return $false
    }

    try {
        $state = [System.IO.File]::ReadAllText($exporterStatePath) | ConvertFrom-Json
        $batches = @($state.Batches)
        if ($batches.Count -eq 0) { return $false }

        $notFinished = @(
            $batches | Where-Object {
                $_.Status -ne "Complete" -and $_.Status -ne "Unavailable"
            }
        )
        return ($notFinished.Count -eq 0)
    }
    catch {
        Write-Log -Level "WARN" -Event "export_state_unreadable" -Message (
            "Could not determine exporter completion from state.json. SingleArchive Watch mode will keep waiting. $($_.Exception.Message)"
        )
        return $false
    }
}

function Test-AllSourcePagesCheckpointed {
    param(
        [Parameter(Mandatory = $true)][object[]]$SourcePages,
        [Parameter(Mandatory = $true)][hashtable]$ManifestIndex
    )

    foreach ($sourceFile in @($SourcePages)) {
        $sourceRelative = Get-RelativeSourcePath -FullName $sourceFile.FullName
        $outputPath = Get-OutputPathForSource -SourceRelative $sourceRelative
        if (-not (Test-AlreadyConverted -SourceFile $sourceFile -SourceRelative $sourceRelative -OutputPath $outputPath -ManifestIndex $ManifestIndex)) {
            return $false
        }
    }
    return $true
}

function Get-StagingFingerprint {
    $files = @(
        Get-ChildItem -LiteralPath $SingleZipStagingDataDirectory -File -Filter "*.csv" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName
    )

    $totalBytes = 0L
    $latestTicks = 0L
    foreach ($file in $files) {
        $totalBytes += [long]$file.Length
        if ($file.LastWriteTimeUtc.Ticks -gt $latestTicks) {
            $latestTicks = [long]$file.LastWriteTimeUtc.Ticks
        }
    }

    return [PSCustomObject]@{
        Files = $files
        Count = $files.Count
        TotalBytes = $totalBytes
        LatestWriteTimeUtcTicks = $latestTicks
    }
}

function Test-SingleArchiveCurrent {
    param([Parameter(Mandatory = $true)]$Fingerprint)

    if ($Force) { return $false }
    if (-not (Test-Path -LiteralPath $SingleZipPath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $SingleZipStatePath -PathType Leaf)) { return $false }

    try {
        $archiveInfo = Get-Item -LiteralPath $SingleZipPath
        if ($archiveInfo.Length -le 0) { return $false }

        $state = [System.IO.File]::ReadAllText($SingleZipStatePath) | ConvertFrom-Json
        if ([int]$state.stagedFileCount -ne [int]$Fingerprint.Count) { return $false }
        if ([long]$state.stagedTotalBytes -ne [long]$Fingerprint.TotalBytes) { return $false }
        if ([long]$state.stagedLatestWriteTimeUtcTicks -ne [long]$Fingerprint.LatestWriteTimeUtcTicks) { return $false }
        if ([long]$state.archiveBytes -ne [long]$archiveInfo.Length) { return $false }
        return $true
    }
    catch {
        return $false
    }
}

function Build-SingleZipArchive {
    $fingerprint = Get-StagingFingerprint
    if ($fingerprint.Count -eq 0) {
        throw "SingleArchive cannot be built because no staged CSV files exist."
    }

    if (Test-SingleArchiveCurrent -Fingerprint $fingerprint) {
        Write-Log -Level "OK" -Event "single_archive_current" -Message (
            "Single ZIP is already current: $SingleZipPath ($($fingerprint.Count.ToString('N0')) CSV entries)."
        )
        $script:SingleArchiveBytes = (Get-Item -LiteralPath $SingleZipPath).Length
        return
    }

    $tempZip = "{0}.tmp.{1}.{2}" -f $SingleZipPath, $PID, ([Guid]::NewGuid().ToString("N"))
    $fileStream = $null
    $archive = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $level = Get-DotNetCompressionLevel

    Write-Log -Level "PHASE" -Event "single_archive_start" -Message (
        "Building one ZIP from $($fingerprint.Count.ToString('N0')) staged CSV file(s): $SingleZipPath"
    )

    try {
        if (Test-Path -LiteralPath $tempZip) {
            Remove-Item -LiteralPath $tempZip -Force
        }

        $fileStream = [System.IO.File]::Open(
            $tempZip,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $archive = [System.IO.Compression.ZipArchive]::new(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $true
        )

        $ordinal = 0
        foreach ($csvFile in @($fingerprint.Files)) {
            $ordinal++
            $base = $SingleZipStagingDataDirectory.TrimEnd('\', '/')
            $relative = $csvFile.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
            $entryName = "data/" + $relative
            $entry = $archive.CreateEntry($entryName, $level)
            $entryStream = $null
            $input = $null
            try {
                $entryStream = $entry.Open()
                $input = [System.IO.File]::Open(
                    $csvFile.FullName,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read
                )
                $input.CopyTo($entryStream, 1048576)
            }
            finally {
                if ($null -ne $input) { $input.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }

            if (($ordinal % 100) -eq 0 -or $ordinal -eq $fingerprint.Count) {
                Write-Log -Level "INFO" -Event "single_archive_progress" -Message (
                    "Single ZIP: packed $($ordinal.ToString('N0'))/$($fingerprint.Count.ToString('N0')) CSV file(s)."
                )
            }
        }

        $archive.Dispose()
        $archive = $null
        $fileStream.Flush()
        $fileStream.Dispose()
        $fileStream = $null

        Move-CompletedFile -TemporaryPath $tempZip -DestinationPath $SingleZipPath
        $sw.Stop()

        $archiveInfo = Get-Item -LiteralPath $SingleZipPath
        $script:SingleArchiveBuiltThisRun = $true
        $script:SingleArchiveBytes = [long]$archiveInfo.Length

        $archiveState = [ordered]@{
            generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
            archive = $SingleZipName
            archiveBytes = [long]$archiveInfo.Length
            compressionLevel = $CompressionLevel
            stagedFileCount = [int]$fingerprint.Count
            stagedTotalBytes = [long]$fingerprint.TotalBytes
            stagedLatestWriteTimeUtcTicks = [long]$fingerprint.LatestWriteTimeUtcTicks
            stagingDirectory = $SingleZipStagingDataDirectory
        }
        $stateTemp = "{0}.tmp.{1}" -f $SingleZipStatePath, $PID
        [System.IO.File]::WriteAllText($stateTemp, ($archiveState | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
        Move-CompletedFile -TemporaryPath $stateTemp -DestinationPath $SingleZipStatePath

        Write-Log -Level "OK" -Event "single_archive_complete" -Message (
            "Single ZIP complete: $SingleZipPath | $((Format-Bytes -Bytes $archiveInfo.Length)) | $($fingerprint.Count.ToString('N0')) CSV entries | $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s."
        )
    }
    catch {
        if ($sw.IsRunning) { $sw.Stop() }
        if ($null -ne $archive) { try { $archive.Dispose() } catch {} }
        if ($null -ne $fileStream) { try { $fileStream.Dispose() } catch {} }
        if (Test-Path -LiteralPath $tempZip) {
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

# ============================================================
# Progress and summary
# ============================================================

function Write-SummaryFile {
    param(
        [int]$DiscoveredPages,
        [int]$ManifestPages
    )

    $elapsed = [Math]::Max(0.001, $script:RunStopwatch.Elapsed.TotalSeconds)
    $rowsPerSecond = $script:RowsThisRun / $elapsed

    $summary = [ordered]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        exportDirectory = $ExportDirectory
        outputDirectory = $OutputDirectory
        sourceDataDirectory = $SourceDataDirectory
        outputDataDirectory = $OutputDataDirectory
        compression = $Compression
        zipLayout = $ZipLayout
        compressionLevel = $CompressionLevel
        converterMode = $script:ConverterMode
        watchMode = [bool]$Watch
        discoveredSourcePages = $DiscoveredPages
        manifestPages = $ManifestPages
        convertedThisRun = $script:ConvertedThisRun
        skippedThisRun = $script:SkippedThisRun
        failedThisRun = $script:FailedThisRun
        rowsThisRun = $script:RowsThisRun
        inputBytesThisRun = $script:InputBytesThisRun
        outputBytesThisRun = $script:OutputBytesThisRun
        elapsedSeconds = $elapsed
        rowsPerSecond = $rowsPerSecond
        manifest = "conversion-manifest.jsonl"
        dataDirectory = $(if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") { "_single-zip-staging/data" } else { "data" })
        singleZip = $(if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") { $SingleZipPath } else { $null })
        singleArchiveBuiltThisRun = [bool]$script:SingleArchiveBuiltThisRun
        singleArchiveBytes = [long]$script:SingleArchiveBytes
        textLog = $TextLogPath
        eventLog = $EventLogPath
    }

    $temp = "{0}.tmp.{1}" -f $SummaryPath, $PID
    [System.IO.File]::WriteAllText($temp, ($summary | ConvertTo-Json -Depth 10), $script:Utf8NoBom)
    Move-CompletedFile -TemporaryPath $temp -DestinationPath $SummaryPath
}

# ============================================================
# Startup
# ============================================================

try {
    # Clean only our own abandoned converter temp files. Never touch exporter temp files.
    Get-ChildItem -LiteralPath $OutputDataDirectory -Filter "*.tmp.*" -File -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $SingleZipStagingDataDirectory) {
        Get-ChildItem -LiteralPath $SingleZipStagingDataDirectory -Filter "*.tmp.*" -File -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " CANARY JSON / JSON.GZ -> CSV CONVERTER" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host (" Export root:       {0}" -f $ExportDirectory) -ForegroundColor Gray
    Write-Host (" Source data:       {0}" -f $SourceDataDirectory) -ForegroundColor Gray
    Write-Host (" CSV output:        {0}" -f $(if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") { $SingleZipPath } else { $OutputDataDirectory })) -ForegroundColor Gray
    Write-Host (" Compression:       {0}" -f $Compression) -ForegroundColor Gray
    if ($Compression -eq "Zip") {
        Write-Host (" ZIP layout:        {0}" -f $ZipLayout) -ForegroundColor Gray
    }
    Write-Host (" Compression level: {0}" -f $CompressionLevel) -ForegroundColor Gray
    if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") {
        Write-Host (" Staging data:      {0}" -f $SingleZipStagingDataDirectory) -ForegroundColor DarkGray
    }
    Write-Host (" Watch mode:        {0}" -f [bool]$Watch) -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    Initialize-StreamingConverter

    $manifestIndex = Load-ManifestIndex
    Write-Log -Level "INFO" -Event "manifest_loaded" -Message (
        "Loaded $(@($manifestIndex.Keys).Count.ToString('N0')) prior conversion checkpoint(s)."
    )

    $pagesHandledForLimit = 0
    $scanNumber = 0

    while ($true) {
        $scanNumber++
        $sourcePages = @(Get-SourcePages)
        $newlyConvertedThisScan = 0
        $failedThisScan = 0

        Write-Log -Level "SCAN" -Event "scan" -Message (
            "Scan $scanNumber found $($sourcePages.Count.ToString('N0')) finalized exporter page(s); $(@($manifestIndex.Keys).Count.ToString('N0')) page(s) are checkpointed."
        )

        foreach ($sourceFile in $sourcePages) {
            if ($MaxPages -gt 0 -and $pagesHandledForLimit -ge $MaxPages) {
                break
            }

            $sourceRelative = Get-RelativeSourcePath -FullName $sourceFile.FullName
            $outputPath = Get-OutputPathForSource -SourceRelative $sourceRelative

            if (Test-AlreadyConverted -SourceFile $sourceFile -SourceRelative $sourceRelative -OutputPath $outputPath -ManifestIndex $manifestIndex) {
                $script:SkippedThisRun++
                continue
            }

            $pagesHandledForLimit++
            $pageOrdinal = $script:ConvertedThisRun + $script:FailedThisRun + 1

            Write-Log -Level "INFO" -Event "page_start" -Message (
                "Converting $sourceRelative ($((Format-Bytes -Bytes $sourceFile.Length))) using $script:ConverterMode."
            ) -Data @{
                source = $sourceRelative
                sourceBytes = [long]$sourceFile.Length
                parser = $script:ConverterMode
                compression = $Compression
                zipLayout = $ZipLayout
                compressionLevel = $CompressionLevel
            }

            $result = Convert-OnePage -SourceFile $sourceFile -SourceRelative $sourceRelative -OutputPath $outputPath

            if (-not $result.Success) {
                $script:FailedThisRun++
                $failedThisScan++
                Write-Log -Level "ERROR" -Event "page_failed" -Message (
                    "Failed to convert $sourceRelative after $($result.Attempt) attempt(s). It was not checkpointed and will be retried on the next run/scan. $($result.Error)"
                ) -Data @{
                    source = $sourceRelative
                    attempts = $result.Attempt
                    error = $result.Error
                }
                continue
            }

            $outputInfo = Get-Item -LiteralPath $outputPath
            $outputRelative = $outputInfo.FullName.Substring($OutputDirectory.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('/', '\')

            $record = [ordered]@{
                timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
                sourceRelative = $sourceRelative
                sourceLength = [long]$sourceFile.Length
                sourceLastWriteTimeUtcTicks = [long]$sourceFile.LastWriteTimeUtc.Ticks
                outputRelative = $outputRelative
                outputLength = [long]$outputInfo.Length
                rows = [long]$result.Rows
                tags = [int]$result.Tags
                seconds = [double]$result.Seconds
                attempt = [int]$result.Attempt
                compression = $Compression
                zipLayout = $ZipLayout
                compressionLevel = $CompressionLevel
                parser = $script:ConverterMode
            }

            Append-ManifestRecord -Record $record
            $manifestIndex[$sourceRelative] = [PSCustomObject]$record

            $script:ConvertedThisRun++
            $script:RowsThisRun += [long]$result.Rows
            $script:InputBytesThisRun += [long]$sourceFile.Length
            $script:OutputBytesThisRun += [long]$result.OutputBytes
            $newlyConvertedThisScan++

            $rate = 0.0
            if ($result.Seconds -gt 0) {
                $rate = $result.Rows / $result.Seconds
            }

            Write-Log -Level "DATA" -Event "page_complete" -Message (
                "$sourceRelative -> $outputRelative | $($result.Rows.ToString('N0')) rows | $($result.Tags) tags | $((Format-Bytes -Bytes $sourceFile.Length)) in -> $((Format-Bytes -Bytes $result.OutputBytes)) out | $([Math]::Round($result.Seconds, 2))s | $([Math]::Round($rate, 0).ToString('N0')) rows/s"
            ) -Data @{
                source = $sourceRelative
                output = $outputRelative
                rows = [long]$result.Rows
                tags = [int]$result.Tags
                inputBytes = [long]$sourceFile.Length
                outputBytes = [long]$result.OutputBytes
                seconds = [double]$result.Seconds
                rowsPerSecond = [double]$rate
                attempt = [int]$result.Attempt
            }

            if ($GcEveryPages -gt 0 -and ($script:ConvertedThisRun % $GcEveryPages) -eq 0) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
            }
        }

        Write-SummaryFile -DiscoveredPages $sourcePages.Count -ManifestPages @($manifestIndex.Keys).Count

        $singleArchiveReady = $false
        if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") {
            $singleArchiveReady = Test-AllSourcePagesCheckpointed -SourcePages @($sourcePages) -ManifestIndex $manifestIndex

            if ($Watch) {
                $exporterComplete = Test-ExporterComplete
                if ($exporterComplete -and $singleArchiveReady -and $failedThisScan -eq 0) {
                    Build-SingleZipArchive
                    Write-SummaryFile -DiscoveredPages $sourcePages.Count -ManifestPages @($manifestIndex.Keys).Count
                    Write-Log -Level "OK" -Event "watch_single_archive_complete" -Message (
                        "Exporter is complete and all discovered pages are converted. Final single ZIP was created; Watch mode is exiting."
                    )
                    break
                }
            }
            elseif ($singleArchiveReady -and $failedThisScan -eq 0) {
                if (-not (Test-ExporterComplete)) {
                    Write-Log -Level "WARN" -Event "single_archive_snapshot" -Message (
                        "Exporter state does not indicate completion. Building a single ZIP for the currently discovered snapshot only. Use -Watch for automatic final packaging after exporter completion."
                    )
                }
                Build-SingleZipArchive
                Write-SummaryFile -DiscoveredPages $sourcePages.Count -ManifestPages @($manifestIndex.Keys).Count
            }
            elseif (-not $Watch) {
                Write-Log -Level "WARN" -Event "single_archive_not_ready" -Message (
                    "Single ZIP was not finalized because not every discovered source page has a valid conversion checkpoint. Re-run after failed/limited pages are converted."
                )
            }
        }

        if ($MaxPages -gt 0 -and $pagesHandledForLimit -ge $MaxPages) {
            Write-Log -Level "OK" -Event "max_pages_reached" -Message "MaxPages=$MaxPages reached. Stopping after the requested validation workload."
            break
        }

        if (-not $Watch) {
            break
        }

        if ($newlyConvertedThisScan -eq 0 -and $failedThisScan -eq 0) {
            Write-Log -Level "INFO" -Event "watch_idle" -Message (
                $(if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") {
                    "No new finalized pages are waiting. SingleArchive staging is caught up, but exporter state is not yet complete; next scan in $PollSeconds second(s). Ctrl+C stops safely."
                } else {
                    "No new finalized pages are waiting. Watching exporter output; next scan in $PollSeconds second(s). Ctrl+C stops safely."
                })
            )
        }
        elseif ($failedThisScan -gt 0) {
            Write-Log -Level "WARN" -Event "watch_retry_later" -Message (
                "$failedThisScan page(s) failed this scan and remain uncheckpointed. They will be retried after $PollSeconds second(s)."
            )
        }

        Start-Sleep -Seconds $PollSeconds
    }

    $script:RunStopwatch.Stop()

    $elapsed = [Math]::Max(0.001, $script:RunStopwatch.Elapsed.TotalSeconds)
    $overallRate = $script:RowsThisRun / $elapsed

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " CONVERSION SUMMARY" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host (" Converted this run:  {0:N0} pages" -f $script:ConvertedThisRun) -ForegroundColor Green
    Write-Host (" Rows this run:       {0:N0}" -f $script:RowsThisRun) -ForegroundColor White
    Write-Host (" Skipped/checkpointed:{0,11:N0} pages" -f $script:SkippedThisRun) -ForegroundColor DarkGray
    Write-Host (" Failed this run:     {0:N0} pages" -f $script:FailedThisRun) -ForegroundColor $(if ($script:FailedThisRun -gt 0) { "Red" } else { "Green" })
    Write-Host (" Input read:          {0}" -f (Format-Bytes -Bytes $script:InputBytesThisRun)) -ForegroundColor Gray
    Write-Host (" CSV output written:  {0}" -f (Format-Bytes -Bytes $script:OutputBytesThisRun)) -ForegroundColor Gray
    Write-Host (" Elapsed:             {0}" -f (Format-Duration -Seconds $elapsed)) -ForegroundColor Gray
    Write-Host (" Overall throughput:  {0:N0} rows/s" -f $overallRate) -ForegroundColor Cyan
    Write-Host (" Parser:              {0}" -f $script:ConverterMode) -ForegroundColor Gray
    Write-Host (" Output:              {0}" -f $(if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") { $SingleZipPath } else { $OutputDataDirectory })) -ForegroundColor Gray
    if ($Compression -eq "Zip" -and $ZipLayout -eq "SingleArchive") {
        Write-Host (" Staging:             {0}" -f $SingleZipStagingDataDirectory) -ForegroundColor DarkGray
    }
    Write-Host (" Manifest:            {0}" -f $ManifestPath) -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
}
finally {
    if ($null -ne $lockStream) {
        try { $lockStream.Dispose() } catch {}
    }
}
