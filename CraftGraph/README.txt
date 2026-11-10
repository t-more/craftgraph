CraftGraph 0.1 - for World of Warcraft Forever (interface 16001)

What it does
  Shows every way to make money right now, with the amount worth doing, what it
  costs up front, the expected profit with its margin, and the steps it takes:
    - craft something you know the recipe for and sell it
    - buy the cheap end of the auction house and relist it
    - buy listings priced under what a vendor pays
    - buy from a vendor and auction it
    - list what is already in your bags
  A graph shows what an item is made from and used in, with Buy, Make and Sell
  buttons that light up for the step to do now and grey out (with the reason on
  hover) when a step makes no sense.

  Your plan: add items to it ("Add to plan" or "Plan it") and a small plan
  window shows each one's next step wherever you are: auction house, mailbox,
  bank, vendor, craft, post. You are told first if something is not expected
  to pay. Use - and + to change an amount, x to remove one item, Clear (press
  twice) to empty the plan. On the graph, each material shows what you own
  (bags and bank) and lets you set how much of it the plan may use; the rest
  is bought.

  Trends: for any item, its price or supply by hour of day or day of week,
  how listings are stacked, who sells it, and whether it is rising or falling.
  These fill in as you scan at different times.

Install
  1. Quit the game completely.
  2. Put the CraftGraph folder in:
       World of Warcraft/_forever_/Interface/AddOns/
  3. Start the game and tick CraftGraph under AddOns on the character screen.

First use
  1. Open the auction house, type /cg and press "Full scan" (allowed once every
     15 minutes; an Auctionator full scan is recorded too).
  2. Open each of your profession windows once so your recipes can be read.
  3. Press "Opportunities".
  Prices get steadier with every scan; after one scan margins are wide.

What needs what
  Everything in the game works with nothing else installed: scanning and
  auto scan, prices and their history, the price model (trend, hour and
  weekday habits, forecasts), opportunities, plans and their projections.
  Your price history is kept inside the game's saved file for good, packed
  small: every scan for two days, hourly for three weeks, six-hourly for
  four months, daily after that.
  Installing Python 3 is optional and adds what the game itself cannot do:
    - prices while you are away, from Blizzard's hourly auction data;
    - a database (SQLite) with every scan in full, for your own analysis;
    - room for heavier analysis later than is sensible to run in the game.
  Both are described below. Without Python nothing is missing in the game;
  the history is simply coarser once it is older than two days.

Planning and timing
  "Opportunities" lists every way to make money now. Two more filters there:
  "This item" shows every option that involves the item in focus (relisting
  it, a vendor, crafting with it), each with an example; "When" lists what
  you hold or can make with the best hour to sell it this week.
  "Plan it" puts an option in the small plan window. While it is there the
  plan's projected profit is worked out again after every scan, and the
  window shows it, how the last scan moved it, and its median and average
  since you planned it. Hover the plan for the profit by when it sells
  (right away, within the hour, this evening, in a week).
  The price chart's heading switches between the price history with its
  forecast, the scans folded onto one week, and folded onto one day.

Keeping every scan (optional, needs Python 3)
  The game only lets an addon keep its data in one saved file, which
  CraftGraph thins as it ages. To keep every scan in full, run
      python3 sync/craftgraph_sync.py archive
  after logging out or /reload. It needs no Blizzard account. It copies
  your scans into a SQLite database (table "scan") and keeps a compressed
  copy of each saved file beside it in a "raw" folder. A file that was
  imported before is not read again. Saved files from someone else can be
  dropped into the raw folder and are imported the same way.
  To have this happen by itself (Linux), run once
      python3 sync/craftgraph_sync.py install-watch
  It then imports when you log in to the computer and every time the game
  saves; "remove-watch" undoes it. "status" shows where the files are.

Auto scan
  While the auction house is open CraftGraph scans by itself: the whole
  auction house whenever the game allows it (every 15 minutes), and the items
  in your plan and on the graph every 10 minutes in between. Untick "Auto
  scan" beside the auction window, or type /cg auto, to switch it off.

Online prices (optional)
  The game cannot reach the internet, so a small program in the sync folder
  does it from outside. It downloads your auction house from Blizzard's own
  web API (updated hourly), keeps a history on your disk, estimates what sold
  between two hours, and writes Data/Online.lua, which the addon reads at the
  next login or /reload. With it the addon has prices around the clock, real
  time-of-day patterns, and sales per day, without you standing at the
  auction house. Nothing is uploaded.
    1. Install Python 3 (python.org) if you do not have it.
    2. Create a free API client at https://develop.battle.net/access/clients
    3. python3 sync/craftgraph_sync.py setup      (enter the client ID and secret)
    4. Do a full scan in the game, /reload, then within a few hours:
       python3 sync/craftgraph_sync.py run        (it finds which house is yours)
    5. Run it again whenever you like, or every hour:
       python3 sync/craftgraph_sync.py install-timer      (Linux; on Windows use Task Scheduler)
  Seller names and your own bank are not in Blizzard's data; those still come
  from the game.

Commands
  /cg              open or close the window        /cg deals    opportunities
  /cg <item name>  open on an item                 /cg sell     sell from bags
  /cg hud          show or hide the plan window    /cg reload   reload the interface
  /cg trends       trends for the item in view
  /cg log          show the addon's last log lines
  Alt-click an item in your bags to open it. The mouse's back and forward
  buttons move through what you looked at.

Things to know
  - Buying and posting use your gold. Each one starts from your own click, is
    checked against the expected price first (nothing is bought if the price
    rose more than 8%), and nothing is posted below vendor price. This part is
    new: try it on something cheap first.
  - The game allows one purchase or listing per click, so "Sell next" is
    pressed once per item.
  - Your bank is counted as stock you own, but things must be taken out of it
    before they can be crafted with or sold. Auction deposits are not counted.
  - Demand is estimated from what disappears between two scans. Until an item
    has been scanned twice, suggested amounts are kept small.
  - Auctionator is optional; if installed, its price history is used as well.
  - All data stays on your computer, in WTF/Account/<name>/SavedVariables/CraftGraph.lua.
