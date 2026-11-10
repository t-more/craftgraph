# Working on the addon

[Guide](../README.md) › [Under the hood](README.md)

## Everyday

    ./test.sh        offline checks with plain Lua 5.1
    ./install.sh     copy the addon into the game (then /cg reload in game)
    ./package.sh     build dist/CraftGraph-<version>.zip to share

`windows/` holds the installer that goes into the zip for friends on Windows:
`Install CraftGraph.cmd` (double-click) starts `install.ps1`. It has not been
run on a Windows machine yet.

`install.sh --check` shows what would change without changing it. A full game
restart is only needed when a file is added or `CraftGraph.toc` changes.

## Layout of the repository

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
        gen_data.py        regenerates Data/Recipes.lua (recipes, items, which item teaches a
                           recipe) from wago.tools DB2 exports

## Where things are on this machine

- Game addons (Steam on Linux): `~/.local/share/Steam/steamapps/compatdata/<number>/pfx/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/`
- Saved data and the in-game log: `.../_forever_/WTF/Account/<account>/SavedVariables/CraftGraph.lua`
- Scan archive: `~/.local/share/craftgraph/market.sqlite`, raw copies in `~/.local/share/craftgraph/raw/`

## Checking the models

    cd CraftGraph
    lua5.1 tools/backtest.lua . tools/stats_v1.lua 6
    lua5.1 tools/backtest_real.lua . tools/stats_v1.lua <path to SavedVariables/CraftGraph.lua>

`lua5.1 tools/backtest_sales.lua` does the same for the sales estimate in
`Market.lua` (a simulated item with a known selling rate), and
`tools/qa_real.lua`, `tools/qa_fit.lua` and `tools/qa_empty.lua` run the whole
addon on a real saved file, estimate label fit, and exercise an empty install.

Run both before changing a setting in `Stats.lua`. Where they disagree, trust
the real scans.


## Drawing the pictures
The pictures in the readme and this guide are not screenshots. `tools/render/` runs the addon's
real interface code against a stand-in for the game's widget system that also works out where
everything sits, and writes SVG.

```
cd CraftGraph
lua5.1 tools/render/scenes.lua media-build         # SVG frames from a simulated market
python3 tools/render/fetch_icons.py media-build/icons-wanted.txt   # optional: real item icons
lua5.1 tools/render/scenes.lua media-build         # again, now with icons
tools/render/make_media.sh media-build ../docs/media-new
```

- `wowlayout.lua`: the stand-in and the SVG drawing. Fonts, frames and buttons are
  approximations.
- `world.lua`: the simulated market (three weeks of scans, evening and weekend habits, drifts).
- `scenes.lua`: what is shown, in which order, with which captions.
- Needs `rsvg-convert` and `ffmpeg`; the icon fetcher needs Python with Pillow. Icons are
  Blizzard's art and are not committed.

It doubles as a visual check: it found a graph that did not fit its view.

## The trailer
`tools/render/make_trailer.py <frames folder> <real-graph.svg> <out.mp4>` builds the parody
trailer from the rendered frames: animation with Pillow, music synthesised with numpy. The
voices use Kokoro (a small neural speech model) when it is installed in its own environment at
`~/.local/share/craftgraph-tts` (a Python 3.12 venv with `kokoro-onnx` and `soundfile`, the two
model files from the kokoro-onnx releases, and a `say.py` that writes one line to a WAV), and
fall back to espeak-ng. None of this is needed for the addon.

## Checking the priors
`lua5.1 tools/backtest_priors.lua` (simulated market) or with the path of a saved file (real
scans) compares fixed priors with the market's on held-out scans.
