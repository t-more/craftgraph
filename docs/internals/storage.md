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

## Part scans
The game sends a full scan in pieces. A list read before all of it had come is only part of the
auction house: its cheapest prices are too high, and everything missing looks unlisted or sold.
Up to 0.3.0 this could still happen when the last complete list was more than an hour old (seen in
the game: 19,084 auctions between lists of 164,015 and 213,689). Now a list waits longer whenever
it is much shorter than the last complete one of the last two days, and one under 35% of it is
recorded as only part: its prices are kept, but it writes no "none listed" points, counts no sales
and is not a full scan.

Part scans already saved are taken out once, at login (`M.RepairPartScans`): a scan whose auction
count is under 80% of the largest within an hour, or under half of the largest within six hours,
loses its points, and the sales worked out across it are cut to the gaps that did not touch it
(each item keeps the rate of every gap, `sh`, so the clean share of the evidence is known).

## The base data (`Data/Base.lua`)
The addon ships the author's own scans of one auction house so that a new install there starts
with history. It is built by `tools/make_base.lua` from a saved file, cleaned of part scans the
same way, and holds per item, as one string:

- the history, one point an hour at most: time, cheapest price, sturdier price, units listed
- the last ladder, how listings were stacked, and the selling-rate belief

Numbers are written in a 64-letter alphabet, five bits a letter, the first 32 letters ending a
number and the other 32 saying more follows; signed numbers are folded (0, -1, 1, -2 become
0, 1, 2, 3). Each value is a step from the one before, so most take one letter. Prices are on a log
scale in steps of 0.2% (exact below about 5 silver, within a tenth of a percent and a copper
above), times in steps of five minutes. `tools/basepack.lua` writes it and says the layout in
full; `Market.lua` (`M.BaseUnpack`) reads it.

From two days of scans (43 full scans, 4,543 items, 39,061 points) that is 394 KB, about 8.5 bytes
a point with ladders and sales included, against about 17 for the saved file's own packing and 80
as a table. It loads in a few milliseconds; an item is unpacked only when something asks for it,
and let go again when memory is short.

It is used only on its own auction house and, per item, only before the player's own first
record of it, so on the author's install it changes nothing (`tools/qa_base.lua` checks exactly
that, item by item). It holds no seller or character names and none of Blizzard's web data.

## Outside the game (optional)
`sync/craftgraph_sync.py archive` copies every point into SQLite and keeps compressed raw copies
of the saved file. A file already imported is not read again.
