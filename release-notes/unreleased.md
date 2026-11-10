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
