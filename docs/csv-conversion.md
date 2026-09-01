# CSV conversion modes

`Convert-CanaryJsonToCsv.ps1` reads finalized exporter `.json` and `.json.gz` pages and flattens each Canary TVQ to:

```csv
Tag,Timestamp,Value,Quality
```

The converter leaves the original export unchanged.

## Parallel conversion

`-Parallelism` controls how many finalized source pages can be converted at once. The default is `4`.

Parallel conversion is page-level. Each worker owns one source page and one output file. The coordinator writes the manifest after each worker succeeds, which keeps resume behavior simple.

Parallelism is enabled for the compiled streaming parsers. If `-UsePowerShellParser` is selected, or if the converter falls back to PowerShell `ConvertFrom-Json`, effective parallelism is forced to `1` because that parser materializes full pages in memory.

Use `-Parallelism 1` for troubleshooting. Use `2` to `4` when converting while an export is still running. Raise it only when CPU and disk are clearly waiting around.

## Watch mode

`-Watch` repeatedly scans the export directory for finalized pages. This lets conversion run beside a long export. Temporary exporter files are ignored.

In `SingleArchive` mode, watch mode stages CSV pages first, waits for exporter `state.json` to show completion, then builds the final ZIP.

## `-Compression None`

Writes one plain `.csv` per source page. This helps inspection and can consume substantially more disk space.

## `-Compression Gzip`

Writes one `.csv.gz` per source page. This is the default incremental compressed format and has strong restart behavior because every page can be committed independently.

## `-Compression Zip -ZipLayout PerFile`

Writes one `.csv.zip` per source page, with one CSV entry inside each ZIP. This remains fully incremental and works well with `-Watch`.

## `-Compression Zip -ZipLayout SingleArchive`

Creates a single final ZIP that contains the complete converted `data/` tree.

The script creates checkpointed plain CSVs under `_single-zip-staging/data/`, then builds the final archive atomically from that staging tree. This preserves conversion progress if ZIP central-directory finalization fails.

The staging tree is intentionally retained after the ZIP is built. Delete it only after the archive has been independently verified or copied elsewhere.

## CSV escaping

Commas, quotes, CR, and LF characters in tag/value fields are handled with normal CSV quoting. Embedded double quotes are doubled.

The converter preserves Canary timestamps, values, duplicate timestamps, ordering, and numeric quality codes as represented by the source page.
