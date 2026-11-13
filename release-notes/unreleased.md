# Not released yet

Notes on what has been done since the last release. They become the next version's release notes
when the version is bumped; see [README.md](README.md).

- **News** (`/cg news`, the first page button): what moved over the day and the week, overall,
  the biggest single moves, by kind of goods and by profession and rank (Apprentice to Master),
  materials and goods apart, each with a range. Up or down only at three chances in four. Items
  with only one or two on sale are left out. The main moves are said in chat once a day (can be
  switched off).
- **Base data**: the addon now ships two days of the author's own scans of CAMWOW EU4 Realm 2 PvP
  (Alliance), packed into 394 KB: prices, depth, stacks, sales, vendor prices. On that auction
  house a new install has history from the start; per item it is used only before your own first
  scan, and it has its own switch on the Data sources page. No seller or character names, none of
  Blizzard's data.
- **Fixed**: a full scan list read while only part of it had come (when the last complete one was
  over an hour old) was recorded as a full scan, making prices look dearer and everything missing
  look sold. Such lists now wait longer and, if still far too short, keep their prices but count
  as nothing more. Part scans already saved are taken out once at login.
- A new file was added: the game needs a full restart once, `/reload` is not enough.
- **Readout under the mouse** on the price chart (on to start with, under **Show ...**): a line at
  the moment under the mouse, its time at the foot, a mark on each line, and beside the chart the
  numbers then: the scan, the estimate with its range, against now, average, supply, demand,
  margin, and what making and selling one would have left.
- The price chart now says what it shows: each dot is the cheapest tenth on sale, averaged (at
  most the 50 cheapest), and the readout gives the cheapest beside it and where the dot came from.
  Prices shared by another player are drawn the same way now (they were the single cheapest).
