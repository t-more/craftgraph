# CraftGraph

**Make gold at the auction house in World of Warcraft Forever without doing the sums yourself.**
Open it in game with `/cg`.

![A quick tour](docs/media/tour.gif)

*A one-minute tour ([video](docs/media/tour.mp4)). Every picture here was drawn from the addon's
own interface code on a simulated market, outside the game.*

## What you can do with it

**See what anything is made of.** Click an item and you get a map: what it is made from on the
right, what it is used in on the left, with the price of every step and buttons to buy, make and
sell.

**Get a list of ways to make money right now.** Craft and sell, buy cheap and relist, buy under
vendor price, sell what is in your bags. Each line says what it costs, what it should earn and how
sure that is.

![Opportunities](docs/media/opportunities.png)

**Ask "what would this cost on a Monday afternoon?"** Drag across the week and read the price.

![Dragging across the week](docs/media/week.gif)

**See why a price moved.** Tick Supply and Demand on the price chart. Here goods flood in (blue)
and the price sinks; then a rush of buyers (green) empties the market and it jumps. Pick how much
to smooth: an hour shows every wiggle, a day shows the story.

![Supply and demand beside the price](docs/media/smoothing.gif)

**Make a plan and watch it.** Press "Plan it" and a small window tells you the next step wherever
you are. After every scan it shows what the plan should earn now, and whether that went up or down.

![A plan following the market](docs/media/plan.gif)

**Know when to sell.** For anything you hold, it names the best hour this week, if there is one.

**Trust it to say "I don't know".** With too few scans, or a price that jumps about, it shows only
what it saw and tells you why. One switch shows the guess anyway.

![No guess without enough to go on](docs/media/guesses.gif)

## Install

1. Download `CraftGraph-0.1.zip` from the [latest release](https://github.com/t-more/craftgraph/releases/latest) and unzip it.
2. Windows: double-click **Install CraftGraph**. Anything else: copy the `CraftGraph` folder into
   `World of Warcraft/_forever_/Interface/AddOns/`.
3. Start the game, open the auction house, type `/cg` and press **Full scan**.

It needs nothing but the game. This is an early version: most of it has only been checked outside
the game so far, so expect rough edges and please say what breaks. [More on installing](docs/start/install.md).

## Want to know more?

Start at the [guide](docs/README.md). It goes from "what do I click" to "how does the maths work",
one step at a time, and you can stop wherever you like.

| I want to... | Read |
|---|---|
| get going | [Your first session](docs/start/first-session.md) |
| make gold | [Opportunities](docs/play/opportunities.md), [Plans](docs/play/plans.md), [When to sell](docs/play/timing.md) |
| understand the numbers | [Prices and history](docs/understand/prices-and-history.md), [Forecasts](docs/understand/forecasts.md) |
| see how it is built | [Under the hood](docs/internals/README.md) |
