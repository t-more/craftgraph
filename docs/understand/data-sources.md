# Data sources

[Guide](../README.md) › Understanding it

Your own scans always count. Everything else is a second opinion that may be wrong, stale, or
about another auction house, so each has a switch.

![The data sources window](../media/sources.png)

Open it by clicking the status line under the graph, with the button beside the auction window,
or with `/cg sources`.

| Source | What it adds | Needs |
|---|---|---|
| Your own scans | everything | nothing |
| Sales seen between full scans | how fast things sell | two full scans within 12 hours |
| Auctionator's prices | prices for items you have not scanned here | the Auctionator addon |
| Blizzard's hourly data | prices and sales while you are away | Python 3 and a free Battle.net API key |

Switch one off and the numbers are worked out again without it, so you can see what it changes.

## The optional Python tool
The game cannot reach the internet or write a database, so those two jobs sit in a small tool,
`sync/craftgraph_sync.py`, that runs outside the game:

- `setup` and `run` bring Blizzard's hourly auction data in. This part has only been tested
  against a copy of the service, never the live one.
- `archive` copies every scan into a SQLite database and keeps the raw saved files.

Without Python nothing is missing in the game.

Next: [Under the hood](../internals/README.md)
