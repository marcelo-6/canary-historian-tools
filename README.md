<div align="center">

# Canary Historian Tools

<h4>PowerShell tools for benchmarking, exporting, resuming, and converting large <a href="https://www.canarylabs.com/">Canary Historian</a> datasets through the Views Read API.</h4>

<a href="https://github.com/marcelo-6/canary-historian-tools/releases"><img src="https://img.shields.io/github/v/release/marcelo-6/canary-historian-tools?logo=github" alt="GitHub Release"></a>
<a href="https://github.com/marcelo-6/canary-historian-tools/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/marcelo-6/canary-historian-tools/ci.yml?branch=main&logo=GitHub%20Actions&logoColor=white&label=CI" alt="Continuous Integration"></a>
<a href="https://github.com/marcelo-6/canary-historian-tools/blob/main/LICENSE"><img src="https://img.shields.io/github/license/marcelo-6/canary-historian-tools" alt="License"></a>
<br>
<img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/marcelo-6/canary-historian-tools/total?logo=GitHub">
<img alt="GitHub commits since latest release" src="https://img.shields.io/github/commits-since/marcelo-6/canary-historian-tools/latest">
<img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white">

</div>

> [!IMPORTANT]
> This is an unofficial community project with no Canary Labs affiliation, endorsement, or support. Validate exports before using them as a sole archival or migration source.

`canary-historian-tools` is a small toolkit for moving large amounts of historical data out of Canary.

The workflow is split into three tools.

[`Benchmark-CanaryHistorian.ps1`](scripts/Benchmark-CanaryHistorian.ps1) discovers tags, inspects historical range, estimates TVQ volume, and measures raw API throughput before a bulk export.

[`Export-CanaryHistorian.ps1`](scripts/Export-CanaryHistorian.ps1) performs resumable bulk export of raw `getTagData2` pages with retries, checkpoints, continuation handling, logs, and permanent-failure classification.

[`Convert-CanaryJsonToCsv.ps1`](scripts/Convert-CanaryJsonToCsv.ps1) streams raw JSON/JSON.GZ pages to CSV, CSV.GZ, per-page ZIPs, or one ZIP for the entire converted data tree.

The scripts are designed for **Windows PowerShell 5.1 and PowerShell 7+** and have been exercised against Canary 23.x and 25.x Read API behavior. The exporter supports anonymous access as well as `apiToken`, `accessToken`, and `userToken` authentication.

## Why raw JSON first?

A Canary response page is already a lossless representation of the historian data returned by `getTagData2`. Writing that response directly to disk keeps the extraction path simple:

```text
Canary Views API
      |
      v
 getTagData2
      |
      v
 raw JSON page
      |
      v
 checkpoint
      |
      v
 later CSV / CSV.GZ / ZIP conversion
```

This keeps historian-export time focused on API reads. CSV object construction and compression can run later through the converter, or concurrently in watch mode.

## Quick start

### 1. Benchmark the historian

Canary 23.x anonymous Views endpoint:

```powershell
.\scripts\Benchmark-CanaryHistorian.ps1 `
    -Server "http://localhost:55235"
```

Secure endpoint with an API token:

```powershell
.\scripts\Benchmark-CanaryHistorian.ps1 `
    -Server "https://canary-server:55236" `
    -ApiToken $env:CANARY_API_TOKEN `
    -InsecureSkipCertificateCheck
```

The benchmark inventories tags, obtains oldest/latest history, estimates TVQ count with explicit 365-day Count buckets, and measures raw `getTagData2` throughput.

### 2. Export the historian

```powershell
.\scripts\Export-CanaryHistorian.ps1 `
    -Server "http://localhost:55235" `
    -OutputDirectory "E:\CanaryExport"
```

A larger page size can reduce request/checkpoint overhead if the server and client have enough memory:

```powershell
.\scripts\Export-CanaryHistorian.ps1 `
    -Server "http://localhost:55235" `
    -OutputDirectory "E:\CanaryExport" `
    -MaxSizePerTag 50000
```

The default exclusion removes literal `{Diagnostics}` tags only. Paths containing words such as `System.Diagnostics` remain included unless you provide a different `-ExcludeRegex`.

### 3. Convert to CSV

One compressed CSV per exporter page:

```powershell
.\scripts\Convert-CanaryJsonToCsv.ps1 `
    -ExportDirectory "E:\CanaryExport" `
    -Compression Gzip
```

One ZIP per exporter page:

```powershell
.\scripts\Convert-CanaryJsonToCsv.ps1 `
    -ExportDirectory "E:\CanaryExport" `
    -Compression Zip `
    -ZipLayout PerFile `
    -CompressionLevel Fastest
```

One ZIP containing the entire converted data tree:

```powershell
.\scripts\Convert-CanaryJsonToCsv.ps1 `
    -ExportDirectory "E:\CanaryExport" `
    -Compression Zip `
    -ZipLayout SingleArchive `
    -SingleZipName "FullHistorianExport.zip" `
    -CompressionLevel Fastest
```

The converter uses streaming parsing for large pages. Json.NET runs when available. The compiled dependency-free .NET streaming parser handles hosts without Json.NET. The converter avoids building the complete JSON document as PowerShell objects.

## Export layout

A typical export looks like this:

```text
CanaryExport/
  state.json
  pages.jsonl
  export-plan.csv
  tag-inventory.csv
  excluded-tags.csv
  unavailable-tags.csv
  tags-without-count.csv
  summary.json
  logs/
  data/
    B00001/
      page-000001.json
      page-000002.json
    B00002/
    U00873/
      page-000001.json
```

`Bxxxxx` directories are normal resolved multi-tag batches. `Uxxxxx` directories are single-tag fallback batches for tags whose historical context failed normal resolution. `export-plan.csv` records each included tag's resolved or fallback batch assignment before raw extraction starts. A `page-xxxxxx` file is one `getTagData2` response; later pages use Canary continuation tokens.

See [Export format and recovery](docs/export-format.md) for the complete model.

## Resuming an interrupted export

Run the same command against the same output directory. `state.json` stores batch status, page number, and continuation state. Finalized page files are checked before resume, and incomplete temporary files are ignored.

Permanent raw tag failures such as `TagKey contains no TrendVectors` / `0x800403F8` are classified as unavailable after a raw history request returns that condition. Aggregate Count failures only disable Count-based estimates.

## Canary version notes

The scripts avoid a known older-server compatibility issue by explicitly using bounded Count intervals. Canary 23.x can reject a historian-wide absolute `TimeSpan` greater than 1000 days; the benchmark/exporter therefore use 365-day Count buckets and sum them.

Useful API references:

- [Canary Read API 23.2.1](https://readapi.canarylabs.com/23.2.1/)
- [Canary Read API 25.4](https://readapi.canarylabs.com/25.4/)

## CSV representation

The converter flattens each TVQ to:

```csv
Tag,Timestamp,Value,Quality
Example.Process.Temperature,2024-03-08T13:37:13.1960000-05:00,27.339344,192
```

CSV escaping follows normal CSV rules. String values containing commas, quotes, or newlines are quoted and embedded quotes are doubled. Quality values are preserved numerically as returned by Canary; the converter leaves their meaning to Canary.

## Safety and operational behavior

- Raw data pages are written atomically through temporary files.
- Checkpoints are committed only after page writes succeed.
- Temporary files are ignored during resume/conversion.
- Transient failures use exponential backoff with jitter.
- Known permanent tag errors skip the complete retry schedule.
- API tokens stay out of state and logs.
- The converter leaves the raw historian export unchanged.
- Single-archive ZIP conversion uses a staging tree so failed ZIP finalization preserves conversion progress.

## Development

Runtime users only need PowerShell. Contributor tooling is optional.

This repo uses:

- [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) for PowerShell static analysis.
- [Pester](https://pester.dev/) for repository tests.
- [git-cliff](https://git-cliff.org/) for changelog and release notes.
- [typos](https://github.com/crate-ci/typos) for spell checking.
- [lychee](https://github.com/lycheeverse/lychee) for link checking.
- [just](https://github.com/casey/just) for convenient local commands.

If you have the Rust tools installed:

```text
just check
just changelog
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local and release workflow.

## Releases

The project uses Conventional Commit-style prefixes and `git-cliff` to group changes. Pushing a tag matching `v*` runs the release workflow, generates release notes, and publishes the three PowerShell scripts to GitHub Releases.

See [RELEASING.md](RELEASING.md).

## License

MIT. See [LICENSE](LICENSE).
