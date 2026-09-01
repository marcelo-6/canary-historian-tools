# Architecture

The toolkit intentionally separates historian interaction from data transformation.

```text
Canary Views Read API
  benchmark / browse
  Export-CanaryHistorian.ps1
    context + Count estimate
    parallel raw getTagData2 workers
    per-batch continuation
    retry + checkpoint coordination
  lossless JSON pages
  Convert-CanaryJsonToCsv.ps1
    parallel page conversion
    streaming parser
    CSV escaping
    GZIP / ZIP packaging
```

This design keeps the scarce operation, reading from the historian, independent of CPU-heavy formatting and compression. A failed conversion never requires rereading the historian.

Raw export parallelism is batch-level. A worker handles one page for one batch, then the coordinator records the result, writes shared state, and schedules the next eligible page. Batches do not share output directories. `state.json` and `pages.jsonl` remain coordinator-owned so resume state has one writer.

Set `-Parallelism 1` for the serial path. Higher values increase concurrent API requests; start with `2` to `4` and tune against the server, network, and disk.

CSV conversion parallelism is also page-level. A converter worker reads one finalized source page, writes one output file, and returns the result to the coordinator for manifest updates. The raw export remains unchanged.
