# Under the hood

[Guide](../README.md)

For the curious, and for whoever works on the addon. The design principles are in
[AGENTS.md](../../AGENTS.md).

- [The price model](price-model.md): level, fading trend, habits, and what the checks showed
- [The sales estimate](sales-model.md): probabilities for vanished auctions, and a Bayesian rate
- [How history is stored](storage.md): one saved file, kept small
- [Working on the addon](developing.md): tests, install, packaging, drawing the pictures

## The pieces

```
scans ──► Market ──► Stats ──► Optimizer ──► the window
          ladders    level      cheapest      graph, lists,
          history    trend      way to make   charts, plan
          sales      habits     profit, plans
```

| File | Job |
|---|---|
| `Core.lua` | events, saved data, slash commands, log |
| `Market.lua` | scans, price ladders, history, sales, auto scan, data sources |
| `Stats.lua` | the price model and the judgment of whether to show a forecast |
| `Optimizer.lua` | cheapest way to make things, plans, opportunities, projections |
| `Graph.lua`, `UI/` | the graph and everything drawn |
| `Data/Recipes.lua` | recipes and items, generated from the game's data files |
