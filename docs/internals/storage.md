# How history is stored

[Guide](../README.md) › [Under the hood](README.md)

An addon can keep data in one place only: its saved file, written at logout or `/reload`. No
database, no other files. So history is built to stay small and quick inside that file.

Per item (`Market.lua`):
- `h`: recent points, every scan, four numbers each: time, cheapest price, sturdier price, units.
- `hp`: everything older, thinned by age and packed into one string
  (`seconds since the point before,price,price,units;...`).
- `au`: the auctions of the last full scan, for the sales estimate.
- `sa`, `sn`, `sb`, `sh`: the belief about the selling rate and its short history.

A packed point takes about 17 bytes where four table entries take about 80, and a string loads
far faster than a table. A run of unchanged scans is its first and last point. Results that
arrive within five minutes of each other count as one scan.

With every item scanned every 15 minutes for months the file could reach tens of megabytes; with
occasional scanning it stays far below.

## Outside the game (optional)
`sync/craftgraph_sync.py archive` copies every point into SQLite and keeps compressed raw copies
of the saved file. A file already imported is not read again.
