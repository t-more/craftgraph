# Not released yet

Notes on what has been done since the last release. They become the next version's release notes
when the version is bumped; see [README.md](README.md).

- Price chart: Demand has its own checkbox next to Supply. Its line is units sold a day evened
  out over a stretch of time, with a scale at the right edge in units a day. Without sales seen
  yet it says what it needs. (The first version drew a jumpy line with no scale, under the Supply
  tick.)
- The Certainty tick is now labelled "Glow" to make room for the two above.
- The addon knows its own version (`/cg version`). It says at login when a newer release is out,
  if the optional sync tool has looked (`check-update`, also done by `run` and `archive`). The
  game itself cannot look.
- The Windows installer says when a newer release exists than the one being installed.
- The install script for Linux finds the game folder by itself.
- **Fixed: full scans were recorded piece by piece.** The game sends the full list in pieces
  (about a thousand auctions, then tens of thousands, then the rest) and each piece was taken for
  a whole scan. Anything not yet arrived was written down as "none listed" and counted as sold,
  which gave wild "sells N a day" figures (a vendor item at 343 a day) and false gaps in the
  history. The list is now read once it has stopped growing, and re-read if it changes underneath.
  Found in the game's own saved data.
- Old data is repaired once at login: false "none listed" points between real prices are removed
  (6,148 of 23,462 points in the data this was found in) and the turnover built on them starts
  again.
- Fixed: the count of sold auctions shared a storage field with the number of sellers, which
  spoiled both.
- The demand figure under the chart is now the same number the item's card and the side panel
  show; the line is how the rate has moved. Before any sale is seen the rate starts near one a
  day instead of ten.
- Reading a full scan adapts to the frame rate, so it no longer takes minutes with the game in
  the background.
- Price chart: a smoothing period under the chart (click to step through auto, 15 min, 30 min,
  1 h, 3 h, 6 h, 12 h, 1 day; right-click goes back). It evens out the supply and demand lines
  and adds a thin white average through the scanned prices.
- Pictures: a supply and demand story in the simulated market, and a GIF of the smoothing.
- Opportunities: a "Sell?" mark on every row (now / ok / wait) from the last three hours against
  the middle price of the last week; the reason is in the tooltip, also in Sell bags.
- A price that stood still for days is now judged by how long it stood, not by how many points
  were kept for it (it is stored as two). The count of scans is kept separately, so such an item
  is no longer "too early to forecast" for ever.
- Sharing prices: `/cg share` exports the last day's scans as JSON text and imports what is
  pasted, saying what happened. Files ending in `.cg.json` can be brought in with "Import
  CraftGraph data" on Windows or the Python tool. Shared prices are a data source with its own
  switch.
- Shared prices are kept per player and each player is a data source of their own, by character
  name, with a switch in the Data sources window.
- Optional: the Python tool can share your latest prices to a public GitHub repository and fetch
  what others shared there (`data-publish`, `data-pull`, `data-sync`).
- Graph: faint lights drift along the lines that clearly earn, from the material towards the
  thing made of it. `/cg flow` switches them off.
