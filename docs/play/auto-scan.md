# Auto scan

[Guide](../README.md) › Playing with it

The game only lets an addon read auctions while the auction house window is open. With **Auto
scan** ticked (under the graph, or beside the auction window, or `/cg auto`), CraftGraph keeps
prices fresh for as long as that window stays open:

- a **full scan** the moment the game allows another, which is every 15 minutes;
- in between, the items in your **plan** and on the **graph** are looked up again every 10
  minutes.

It waits while you are buying or selling by hand, and it backs off if the game does not answer.
The words beside the tick box say what comes next.

The game logs an idle character out after about half an hour; no addon can prevent that. For
prices while you are away, see [Data sources](../understand/data-sources.md).

Next: [Prices and history](../understand/prices-and-history.md)
