<div align="center">

# Canary Historian Tools

<h4>PowerShell tools for exporting and converting large <a href="https://www.canarylabs.com/">Canary Historian</a> datasets through the Views Read API.</h4>

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

## How to think about the workflow

Canary stores historian values as TVQs: timestamp, value, and quality. A bulk export can touch millions or billions of TVQs, so the toolkit treats the job as a checkpointed extraction first and a formatting job second.

Start with the benchmark when you do not know the historian size. It lists accessible tags, reads their history ranges, estimates TVQ volume, and runs a small raw API throughput check.

Use the exporter to capture raw Canary `getTagData2` pages. The exporter writes one finalized page at a time, saves state after each page, and can resume after interruption. It also writes `export-plan.csv` before raw extraction so every included tag has a planned resolved batch or a one-tag fallback batch.

Use the converter after raw export completes. Conversion is separate because CSV formatting and compression spend CPU and disk time. Keeping that work outside the live historian read path makes the actual extraction easier to resume and validate.

## Export concepts

A tag is one named historian series. For example, a temperature transmitter or process value.

A TVQ is one historian value: timestamp, value, and quality.

A batch is a group of tags exported together over a shared time range. Normal `Bxxxxx` batches contain tags whose historical context resolved cleanly. If `-ExportBatchSize 20` is used, most normal batches contain up to 20 tags.

A one-tag fallback batch is a `Uxxxxx` batch created when a tag is browsed and included, but normal context lookup cannot prove its oldest/latest range. The exporter still attempts that tag individually over the fallback time range so it is recorded as exported or unavailable instead of quietly disappearing.

A page is one successful `getTagData2` API response written to disk. A batch can have one page or many pages. If Canary returns a continuation token, the next page for that same batch must use that token.

Parallel export runs multiple batches at once. It does not run multiple pages from the same batch at once because continuation tokens make pages order-dependent.

## Choosing export settings

| Parameter | Recommended start | What it does | When to change it |
| --- | --- | --- | --- |
| `-Server` | Required | Canary Views endpoint. The script adds `/api/v2` if needed. | Use `http://server:55235` for anonymous Views or `https://server:55236` for secured Views. |
| `-ApiToken` | Use when required | Sends a Canary API token with each request. | Use `-AccessToken` or `-UserToken` only when that is how the site authenticates Read API calls. |
| `-OutputDirectory` | Required for real exports | Stores state, logs, raw pages, inventory files, and summaries. | Reuse the same directory to resume. Use a new directory for a clean export. |
| `-Path` | Empty | Limits browsing to a Canary tag path. Empty means all accessible tags. | Use it for a plant, area, or subsystem export. |
| `-ExcludeRegex` | `\{Diagnostics\}` | Removes matching tags before export planning. The default excludes literal Canary diagnostics tags. | Change it only when you know which tags should stay out of the export. |
| `-Parallelism` | `4` | Runs that many independent batch-page requests at once. | Use `2` to `4` first. Use `1` for troubleshooting or gentle server load. |
| `-ExportBatchSize` | `20` | Sets how many resolved tags go into a normal batch. | Lower it when dense tags create many continuation pages. Raise it only when the server handles larger combined pages well. |
| `-MaxSizePerTag` | `25000` | Requests up to this many values per tag per API call. | Raise it to reduce paging when the server allows it. Lower it if responses become too large. |
| `-SkipCount` | Use for production retries | Skips aggregate Count estimates. Raw export still runs. | Use it when Count is slow, unavailable, license-restricted, or already proven unnecessary. |
| `-OutputCompression` | `None` | Controls raw page storage during export. `None` writes plain JSON. | Use compression only when disk space matters during export. Convert/compress later when possible. |
| `-MaxAttempts` | `6` | Controls retry count for transient request failures. | Raise it for unstable networks. Lower it when testing failure behavior. |
| `-RetryFailedOnly` | Off | Processes only batches currently marked failed in `state.json`. | Use it after a mostly complete run when you want to focus on failures. |
| `-InsecureSkipCertificateCheck` | Off | Skips TLS certificate validation in PowerShell 7+. | Use only for known self-signed internal endpoints. |

## Choosing conversion settings

The converter reads finalized raw pages from the export directory and writes CSV output under `csv-conversion/` by default. It uses a manifest so finished pages can be skipped on the next run.

Parallel conversion is page-level. Each worker reads one raw page and writes one unique output file. Shared checkpoint files stay under the coordinator, so resume still has one durable manifest writer.

| Parameter | Recommended start | What it does | When to change it |
| --- | --- | --- | --- |
| `-ExportDirectory` | Required | Points at the completed or in-progress exporter output. | Use the same directory that contains `state.json` and `data/`. |
| `-OutputDirectory` | `<ExportDirectory>\csv-conversion` | Stores converted CSV files, logs, manifest, and summary. | Use a different directory for a fresh conversion run. |
| `-Compression` | `Gzip` | Chooses `None`, `Gzip`, or `Zip` output. | Use `None` for fastest local inspection. Use `Gzip` for normal compressed CSV pages. |
| `-ZipLayout` | `PerFile` | With `Zip`, chooses one ZIP per page or one final archive. | Use `SingleArchive` when you want one ZIP after all pages are staged. |
| `-CompressionLevel` | `Fastest` for throughput | Applies to Gzip and ZIP output. | Use `Optimal` when final size matters more than conversion time. |
| `-Parallelism` | `4` | Converts up to this many independent source pages at once. | Raise it when CPU and disk have room. Lower it when conversion competes with export or storage. |
| `-Watch` | Off | Keeps scanning for new finalized exporter pages. | Use it to convert while a long export is still running. |
| `-PollSeconds` | `5` | Wait time between watch-mode scans. | Raise it to reduce filesystem chatter. Lower it for quicker pickup. |
| `-MaxPages` | `0` | Limits pages converted in one run. `0` means unlimited. | Use it for test runs. |
| `-Force` | Off | Re-converts pages even when the manifest says they are complete. | Use it after changing output expectations or validating a converter fix. |
| `-UsePowerShellParser` | Off | Forces the slower `ConvertFrom-Json` parser. | Use only for troubleshooting. Parallelism is forced to `1` with this parser. |

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

Raw export runs parallel batch workers by default:

```powershell
.\scripts\Export-CanaryHistorian.ps1 `
    -Server "http://localhost:55235" `
    -OutputDirectory "E:\CanaryExport" `
    -Parallelism 4
```

Each batch remains sequential internally. The exporter writes one page, checkpoints that batch, then requests the next continuation page for that same batch. `-Parallelism 1` uses the serial path.

The default exclusion removes literal `{Diagnostics}` tags only. Paths containing words such as `System.Diagnostics` remain included unless you provide a different `-ExcludeRegex`.

### 3. Convert to CSV

One compressed CSV per exporter page:

```powershell
.\scripts\Convert-CanaryJsonToCsv.ps1 `
    -ExportDirectory "E:\CanaryExport" `
    -Compression Gzip `
    -CompressionLevel Fastest `
    -Parallelism 4
```

The converter uses parallel workers by default when a compiled streaming parser is active. If it falls back to PowerShell `ConvertFrom-Json`, it runs serially to avoid multiplying memory use.

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

`Bxxxxx` directories are normal resolved multi-tag batches. `Uxxxxx` directories are single-tag fallback batches for tags whose historical context failed normal resolution. `export-plan.csv` records each included tag's resolved or fallback batch assignment before raw extraction starts. A `page-xxxxxx` file is one `getTagData2` response; later pages use Canary continuation tokens. Parallel workers operate on separate batches, so page order is guaranteed inside a batch and interleaved across batches.

See [Export format and recovery](docs/export-format.md) for the complete model.

## Resuming an interrupted export

Run the same command against the same output directory. `state.json` stores batch status, page number, and continuation state. Finalized page files are checked before resume, and incomplete temporary files are ignored.

`-Parallelism` and `-MaxSizePerTag` are stored in the final summary. Changing `-Parallelism` on resume does not invalidate existing pages; it only changes how many independent batch pages run at once. Changing `-ExportBatchSize` or `-MaxSizePerTag` resets unfinished batches and keeps completed batches.

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
