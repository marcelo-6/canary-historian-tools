# CSV conversion modes

`Convert-CanaryJsonToCsv.ps1` reads finalized exporter `.json` and `.json.gz` pages and flattens each Canary TVQ to:

```csv
Tag,Timestamp,Value,Quality
```

The original export is never modified.

## `-Compression None`

Writes one plain `.csv` per source page. This is convenient for inspection but can consume substantially more disk space.

## `-Compression Gzip`

Writes one `.csv.gz` per source page. This is the default incremental compressed format and has strong restart behavior because every page can be committed independently.

## `-Compression Zip -ZipLayout PerFile`

Writes one `.csv.zip` per source page, with one CSV entry inside each ZIP. This remains fully incremental and works well with `-Watch`.

## `-Compression Zip -ZipLayout SingleArchive`

Creates a single final ZIP that contains the complete converted `data/` tree.

The script does **not** continually append to one ZIP while conversion is in progress. Instead it creates checkpointed plain CSVs under `_single-zip-staging/data/`, then builds the final archive atomically from that staging tree. This prevents a crash during ZIP central-directory finalization from destroying hours of conversion work.

The staging tree is intentionally retained after the ZIP is built. Delete it only after the archive has been independently verified or copied elsewhere.

## CSV escaping

Commas, quotes, CR, and LF characters in tag/value fields are handled with normal CSV quoting. Embedded double quotes are doubled.

The converter preserves Canary timestamps, values, duplicate timestamps, ordering, and numeric quality codes as represented by the source page. It does not sort or reinterpret them.
