# The sales estimate

[Guide](../README.md) › [Under the hood](README.md)

Code: `Market.TrackSales` and `Market.Sales` in `CraftGraph/Market.lua`.

## Matching
The full scan gives no auction ids, so auctions are matched by seller, stack and buyout. Identical
ones are counted. What was there and is gone is "vanished".

## A probability per vanished auction
```
P(sold) = P(not run out | it is gone) x P(not cancelled) x (cheaper ones left ? 0.25 : 1)
```
- **Run out:** the time-left band gives a least and a most. The chance it ran out in the gap is
  set against how often auctions that *could not* have run out vanished in the same gap.
- **Cancelled:** 10% by default, 95% when the seller's new auctions explain it. New auctions are
  matched to the seller's dearest vanished ones first: what gets undercut and pulled is what no
  longer sells.
- **Skipped:** buyers take the cheapest first.

## Unseen sales
Auctions posted and sold inside the gap are never seen. If a share `hit` of the auctions cheap
enough to sell went in the gap, sales are scaled by `-ln(1 - hit) / hit`.

## The rate
Sales of auctions arrive at an unknown rate; the belief about it is a Gamma distribution updated
by every pair of scans (Gamma-Poisson), with evidence fading by half each week. Units follow
from the average stack sold. The range shown is the middle four fifths.

## How good is it
`lua5.1 tools/backtest_sales.lua`, a simulated item with a known rate:

| Case | True per day | Estimate |
|---|---|---|
| slow item, scans every 15 min | 100 | 104 |
| slow item, scans every 3 h | 70 | 64 |
| busy item, scans every 15 min | 1,200 | 995 |
| busy item, scans every hour | 1,180 | 752 |
| busy item, scans every 3 h | 1,190 | 417 |
| busy item, scans every 8 h | 1,180 | 177, shown as "at least" |
| nothing sells | 0 | 14 |

Good for slow items and frequent scans; too low for busy items scanned hours apart. It has not
been checked against real sales.
