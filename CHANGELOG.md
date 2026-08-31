# Changelog

All notable changes to this project will be documented in this file.

The format is generated with [git-cliff](https://git-cliff.org/) from Conventional Commit-style history.

## [0.1.0] - 2026-08-31

### Added

- Cross-version Canary Read API benchmark with historical range discovery and TVQ throughput estimation.
- Resumable raw historian exporter with continuation paging, atomic page writes, checkpoints, structured logs, retries, and permanent-failure classification.
- Compatibility for Canary 23.x Count aggregation through explicit 365-day buckets.
- Raw JSON-first export path for higher historian extraction throughput.
- Streaming JSON/JSON.GZ to CSV converter with plain CSV, GZIP, per-page ZIP, and single-archive ZIP layouts.
- Built-in compiled streaming conversion fallback when Json.NET is unavailable.
- Support for anonymous, `apiToken`, `accessToken`, and `userToken` authentication.
- GitHub Actions CI, release automation, PSScriptAnalyzer, Pester, typos, lychee, and git-cliff configuration.
