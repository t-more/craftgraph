# CraftGraph: what we are making and how we decide

**Keep this file true. If a principle, a rule of thumb or the shape of the project changes,
change it here in the same piece of work.** It is short on purpose: it says how we deal with
things, not the details. Look those up in `docs/` and in the code.

## What it is
A World of Warcraft Forever addon that helps a player make gold at the auction house: what an
item is made of, every way to profit now, plans that follow the market, and when to sell.
Lua 5.1, the game's modern auction interface. Opened in game with `/cg`.

## Who it is for
A player who wants to act right away and spot patterns. Show every option that could pay and let
the human judge the effort. Friends get it as a zip, so it must work from the zip alone.

## Principles

1. **Here and now first.** Lead with what the latest scan saw and how old it is. Patterns and
   forecasts are a second opinion beside it, never in its place.
2. **The market is young and does not hold still.** Patterns firm up but keep shifting. Weight
   recent data, let old evidence fade, expect trends.
3. **Scans are sparse.** Never design something that only works with round-the-clock scanning.
4. **Say "I don't know".** If a forecast would be a guess, do not draw it; say why. Keep a switch
   to see it for curiosity. Simpler screen when we know less.
5. **Every number carries its doubt.** Ranges, margins, faint when unsure. Never a bare point
   estimate that looks certain.
6. **Measure before believing.** A model change is checked against real scans and simulated
   markets; where they disagree, real wins. Report what could not be checked.
7. **No dependencies.** The addon is complete with only the game; statistics are our own Lua.
   Anything outside the game (Python, a database, the internet) is optional and gets a basic
   in-game alternative.
8. **Every data source has a switch.** Outside data may be wrong. Own scans always count.
9. **Protect the player's gold.** One hardware click per purchase or post, price caps, fresh
   prices before buying, refuse rather than overpay.
10. **Nothing truncated, nothing mysterious.** Text must fit. Greyed buttons say why. Every
    hidden thing says why it is hidden.
11. **Plain words.** No jargon in the interface or the top of the docs. Depth lives further down.
12. **Small and fast inside the game.** One saved file, packed history, work spread over frames.

## How we work
- Source of truth: this repository. The game folder is an install target (`./install.sh`).
- `./test.sh` before anything is called done. Offline checks prove our logic, not that the game
  accepts a call; say which of the two a claim rests on.
- New file or TOC change needs a game restart; otherwise `/cg reload`.
- The in-game log (in the saved file) is the evidence of what really happened in game.
- Pictures are drawn from the real interface code on simulated data (`tools/render/`), and say so.
- Docs: `README.md` sells it in simple words; `docs/` goes deeper level by level.

## Versions and release notes
- The version is hardcoded: `ns.VERSION` in `Core.lua`, matched by the TOC and the readme. A
  GitHub release tagged `v<version>` carries the zip.
- The game cannot reach the internet. A newer version is noticed by the installer and by the
  optional sync tool, which tells the addon; never promise an in-game check without them.
- `release-notes/` has one file per released version. While working, note what was done in
  `release-notes/unreleased.md`. Write a version's notes only when the version is actually
  bumped, from those notes. The steps are in `release-notes/README.md`.

## Where to look
| For | Look at |
|---|---|
| what a player sees | `docs/README.md` |
| the price model, the sales estimate, storage | `docs/internals/` |
| how to test, install, package, draw pictures | `docs/internals/developing.md` |
| the game's interface facts for this client | the `wow-addon` and `wow-auction-house` skills |
