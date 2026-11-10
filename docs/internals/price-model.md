# The price model

[Guide](../README.md) › [Under the hood](README.md)

Code: `CraftGraph/Stats.lua`. Everything is in log price.

## Shape
```
log price = level + trend carried forward + hour effect + weekday effect + scatter
```
- **Level and trend** are the two states of a Kalman filter. The trend is damped: a tenth of it
  is gone a day later unless scans keep confirming it. A smoother pass gives the history line.
- **Hour effects** come from how each scan differs from the other scans of the same day, so a
  market that is falling does not pass for an evening habit. **Weekday effects** come from each
  day's level against a straight line through the week around it.
- Old scans count less (half after three weeks). An effect seen once is mostly doubted.
- **How much the level wanders in a day** is taken from the middle value of day-long moves, not
  from scan-to-scan jumps, which are mostly zero with a few huge ones.

## What the real data said
On the first 9.5 hours of real scans (about 1,000 items), predicting the next scan:

| Guess | Average miss |
|---|---|
| the last scan, unchanged | 3.7% |
| this model | 4.0% |
| the first version of the model | 4.9% |
| this model, doubting scans that jump far | 6.7% |

Price jumps on this realm stay; they do not drift back within hours. So a scan is taken almost
at its word (`TAU` is small) and the "doubt far-off scans" step is switched off (`CLIP`).
Items with few listed were not noisier than items with many, so depth adds no extra doubt.

## Where each estimate starts: priors
Every estimate starts from an assumption (a prior) and lets the item's own scans pull it away as
they add up. An item with two scans is mostly the assumption; one with two weeks of scans is
mostly itself.

| Belief | Starts from | Held as firmly as |
|---|---|---|
| how much the price wanders in a day | **the market**: the middle of what its other items do, with the hour of day taken out first. With fewer than 8 items to go by, 12% a day | 2 days of the item's own history |
| the hour-of-day effect | **the market's** effect at that hour, from every item scanned at two or more hours of a day. Without that, "no effect" | 3 scans at that hour |
| the weekday effect | "no effect" | 4 days |
| the trend | "none", give or take 4% a day, fading by a tenth each day | built into the filter |
| a price with no history | give or take 30% | until the first scan |
| the direction of a margin | "no trend", give or take 5% a day; the wander from the market | see below |

The two market rows are new. The fixed numbers are assumptions about auction houses in general;
once a realm has been scanned, its other items say more about a new item than those numbers do.
`/cg priors` prints what the market currently says.

**Measured** (`tools/backtest_priors.lua`: keep only the first days of every item's scans,
predict the next day):

- Simulated market, 590 items: with 2 to 4 days of history the market priors cut the typical
  error by about a tenth (0.044 to 0.039); with 14 days by about 6%; with one day or less, and
  at 8 days, no gain (at 8 days 4% worse). Margins stay about as honest as before.
- Real scans (15 hours, about 1,100 items): no difference yet. There is not a second day to
  learn hours from, and the market's wander came out at 12.6% against the fixed 12%.
- What the real scans did show: the truth fell within one margin 62 to 75% of the time (68% is
  honest) but within two margins only 79 to 88% (95% would be). Prices here jump more than a
  bell curve allows. So the "If prices turn" line, which is two margins under the estimate, is
  described as ending worse "roughly one time in ten", not one in forty.

## The direction of a margin
The margin line on the chart (what making one and selling it leaves, over time) comes with a
direction. The ratio of sale to cost is read every half day. Its drift is the average move a
day; how far that can be trusted depends on how much the moves differ from one another and on
how many days there are. That is weighed against the prior above. "Rising" or "falling" is said
only when it is at least three chances in four and at least 1% a day; otherwise "no clear
direction". Under a day of history: "too little history".

## Is now above usual?
The sell signal ("now" / "wait") compares the last three hours with the usual price. It now
also works out how sure it is that the price really is on that side of usual, given how well the
level is known, and only speaks at three chances in four.

## What is not proven
The trend and the habits made no measurable difference on that data: 9.5 hours is too short to
show either. They help on simulated markets that contain such patterns.

## Checking it
```
cd CraftGraph
lua5.1 tools/backtest.lua . tools/stats_v1.lua 6
lua5.1 tools/backtest_real.lua . tools/stats_v1.lua <path to SavedVariables/CraftGraph.lua>
```
Run both before changing a setting. Where they disagree, trust the real scans.

## Whether to show a forecast
`Stats.Trust` judges each item: too early (under 8 scans or 2 days), too unsettled (tomorrow's
range wider than about a third either way), or fine. The thresholds are judgment. See
[Forecasts](../understand/forecasts.md).
