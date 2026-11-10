# Not released yet

Notes on what has been done since the last release. They become the next version's release notes
when the version is bumped; see [README.md](README.md).

- Margin over time: a sixth tick box under "Show ..." draws what making one and selling it left
  at each scan (pink), with where it is heading and how sure that is.
- Priors from the market: the daily wander and the hour-of-day effect of a new item start from
  what the realm's other items do; the selling rate starts from the share of stock this market
  sells a day. `/cg priors` prints them. Measured: about a tenth less error with 2 to 4 days of
  history on the simulated market, no difference yet on 15 hours of real scans.
- The sell signal only says "now" or "wait" when it is at least three chances in four.
- "If prices turn" is described honestly: on real scans it ends worse roughly one time in ten.
- Chart: labels no longer overlap at the top.
- Trailer remade (35 seconds, a composed track, a neural narrator when Kokoro is installed).
- Readme: a "not financial advice" picture at the top.
