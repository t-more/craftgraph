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
