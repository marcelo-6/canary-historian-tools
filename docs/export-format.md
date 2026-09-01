# Export format and recovery

## Batch identifiers

The exporter creates two batch types under `data/`:

- `Bxxxxx`: normal batches whose tags successfully resolved historical context.
- `Uxxxxx`: one-tag fallback batches for tags whose `getTagContext` request failed normal resolution.

The numeric suffix is one global batch identifier. `U00873` means global batch 873.

## Pages

Each `page-xxxxxx.json` (or legacy `.json.gz`) is one successful `getTagData2` response.

If Canary returns continuation tokens, the exporter checkpoints those tokens and requests the next page. A batch is complete when no continuation remains.

```text
B00001/page-000001.json
         |
         | continuation
         v
B00001/page-000002.json
         |
         | continuation
         v
        ...
```

Parallel export does not change the file format. It only changes scheduling. Pages remain sequential inside each batch, while different batch directories can advance at the same time.

## State and audit files

### `state.json`

Durable resume state. It records the export configuration and per-batch progress, including continuation/page state. It is updated only after successful page publication.

`Parallelism` controls runtime scheduling only. Changing it on resume does not invalidate existing pages. Changing `ExportBatchSize` or `MaxSizePerTag` can alter unfinished work, so the exporter resets unfinished batch directories and retains completed batches.

### `pages.jsonl`

Append-only audit metadata for committed pages. Use it to review counts, sizes, and timing without opening every JSON page.

Parallel runs append page records as workers complete. This means `pages.jsonl` ordering can differ from batch/page ordering. Use `batchId` and `page` fields when reviewing it.

### `export-plan.csv`

Per-tag export assignment written before raw extraction starts. Each included tag appears once with `PlanType`, `BatchId`, context status, timestamps, Count value, and Count status.

### `tag-inventory.csv`

The resolved tag inventory with context/count information used by the exporter.

### `unavailable-tags.csv`

Tags whose context lookup failed normal resolution. These may still be attempted as `U` fallback batches.

## Atomic writes

A page is first written to a temporary file in the destination batch directory. The file is renamed to its final name only after the complete response has been written and flushed.

This means the converter can safely ignore `*.tmp.*` and process only finalized files.

## Permanent failures

Some Canary errors are permanent. For example, `TagKey contains no TrendVectors` (`0x800403F8`) indicates that the tag lacks historical trend vectors. The exporter classifies known permanent conditions and skips the full backoff schedule.

## Count is advisory

The Count phase exists for progress and ETA estimates. Raw extraction correctness comes from `getTagData2` pages and checkpoints. If Count fails systemically, the exporter can continue with raw history requests.

Aggregate errors such as `GetAggregateDataAsync` with `NoLicense` disable Count estimation only. They do not remove tags from `export-plan.csv` or raw export batches.
