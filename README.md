# CraftGraph

A World of Warcraft Forever addon (interface 16001): every way to make money
at the auction house right now, a crafting graph with buy, make and sell
buttons, price history with forecasts, and a plan tracker. Open it in game
with `/cg`. What it does for a player is in `CraftGraph/README.txt`.

## Dependencies

The addon needs nothing but the game. The rule for this project: what can be
done in the game is done in the game, in plain Lua, including the statistics.
Anything that needs a program outside the game is optional and must leave the
addon complete without it. Python is used only for what the game cannot do
(reach the internet, write a database) or for analysis too heavy to run in
the game; `lua5.1` is needed only to run the offline checks.

## Working on it

    ./test.sh        offline checks with plain Lua 5.1
    ./install.sh     copy the addon into the game (then /cg reload in game)
    ./package.sh     build dist/CraftGraph-<version>.zip to share

`install.sh --check` shows what would change without changing it. A full game
restart is only needed when a file is added or `CraftGraph.toc` changes.

## Layout

    CraftGraph/            the addon as the game loads it
      CraftGraph.toc       load order
      Core.lua             events, saved data, slash commands, logging
      Market.lua           scans, price ladders, history, auto scan
      Stats.lua            price model: level, fading trend, hour and weekday habits
      Optimizer.lua        cheapest way to make things, plans, opportunities, projections
      Graph.lua            the crafting graph
      UI/                  window, charts, graph view
      Data/Recipes.lua     generated recipe and item data
      Data/Online.lua      empty here; the sync tool writes the real one in the game folder
      sync/                optional Python tool: scan archive (SQLite) and Blizzard's hourly data
      tools/               development only, not installed or shipped
        test.lua           the offline checks
        backtest.lua       price model against simulated markets
        backtest_real.lua  price model against the scans really saved
        stats_v1.lua       the first price model, kept for comparison
        gen_data.py        regenerates Data/Recipes.lua from wago.tools DB2 exports

## Where things are on this machine

- Game addons: `~/.local/share/Steam/steamapps/compatdata/3574889647/pfx/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/`
- Saved data and the in-game log: `.../_forever_/WTF/Account/<account>/SavedVariables/CraftGraph.lua`
- Scan archive: `~/.local/share/craftgraph/market.sqlite`, raw copies in `~/.local/share/craftgraph/raw/`

## Checking the price model

    cd CraftGraph
    lua5.1 tools/backtest.lua . tools/stats_v1.lua 6
    lua5.1 tools/backtest_real.lua . tools/stats_v1.lua <path to SavedVariables/CraftGraph.lua>

Run both before changing a setting in `Stats.lua`. Where they disagree, trust
the real scans.
