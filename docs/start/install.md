# Installing

[Guide](../README.md) › Getting started

CraftGraph is for **World of Warcraft Forever**. It needs nothing else.

## Windows
1. Unzip the download.
2. Quit the game.
3. Double-click **Install CraftGraph**. It finds the game and copies the addon in.

Windows may ask whether to run it. The installer is a plain script, `install.ps1`, that you can
open in Notepad to see what it does. It has not been tested on a Windows machine yet; if it fails,
install by hand.

## By hand, on any system
1. Quit the game.
2. Copy the `CraftGraph` folder into `World of Warcraft/_forever_/Interface/AddOns/`.
3. Start the game and tick CraftGraph under AddOns on the character screen.

## Updates
Type `/cg version` to see which version you have. The game cannot look for updates by itself:
the Windows installer says when a newer one exists, and so does the optional Python tool
(`check-update`), after which the addon tells you at login. New versions and what changed in
each are on the [releases page](https://github.com/t-more/craftgraph/releases); the notes are
also in [`release-notes/`](../../release-notes/README.md).

## Optional extras
Installing Python 3 adds two things the game itself cannot do: prices while you are away (from
Blizzard's hourly data) and a database of every scan. Neither is needed. See
[Data sources](../understand/data-sources.md).

Next: [Your first session](first-session.md)
