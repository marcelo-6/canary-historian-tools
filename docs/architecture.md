# Architecture

The toolkit intentionally separates historian interaction from data transformation.

```text
                 +-----------------------------+
                 | Canary Views Read API       |
                 +--------------+--------------+
                                |
                         benchmark / browse
                                |
             +------------------v------------------+
             | Export-CanaryHistorian.ps1          |
             | - context + Count estimate           |
             | - raw getTagData2                    |
             | - continuation                       |
             | - retry + checkpoint                 |
             +------------------+------------------+
                                |
                       lossless JSON pages
                                |
             +------------------v------------------+
             | Convert-CanaryJsonToCsv.ps1          |
             | - streaming parser                   |
             | - CSV escaping                       |
             | - GZIP / ZIP packaging               |
             +--------------------------------------+
```

This design keeps the scarce operation, reading from the historian, independent of CPU-heavy formatting and compression. A failed conversion never requires rereading the historian.
