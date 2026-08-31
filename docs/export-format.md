# Export format and recovery

## Batch identifiers

The exporter creates two batch types under `data/`:

- `Bxxxxx`: normal batches whose tags successfully resolved historical context.
- `Uxxxxx`: one-tag fallback batches for tags whose `getTagContext` request could not be resolved normally.

The numeric suffix is one global batch identifier. `U00873` means global batch 873, not the 873rd unavailable tag.

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

## State and audit files

### `state.json`

Durable resume state. It records the export configuration and per-batch progress, including continuation/page state. It is updated only after successful page publication.

### `pages.jsonl`

Append-only audit metadata for committed pages. This is useful for reviewing counts, sizes, and timing without opening every JSON page.

### `tag-inventory.csv`

The resolved tag inventory with context/count information used by the exporter.

### `unavailable-tags.csv`

Tags whose context lookup could not be resolved normally. These may still be attempted as `U` fallback batches.

## Atomic writes

A page is first written to a temporary file in the destination batch directory. The file is renamed to its final name only after the complete response has been written and flushed.

This means the converter can safely ignore `*.tmp.*` and process only finalized files.

## Permanent failures

Some Canary errors are not transient. For example, `TagKey contains no TrendVectors` (`0x800403F8`) indicates that the tag cannot provide historical trend vectors. The exporter classifies known permanent conditions and stops retrying them through the full backoff schedule.

## Count is advisory

The Count phase exists for progress and ETA estimates. It is not required for correctness of raw extraction. If Count cannot be performed systemically, the exporter can continue with raw history requests.
