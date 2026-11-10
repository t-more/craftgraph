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
