-- Prices shared by another player, brought in as a file. The game cannot
-- open files, so a .cg.json file is put here from outside the game: by
-- "Import CraftGraph data" (Windows) or sync/craftgraph_sync.py share-import.
-- The addon reads it at login. Until then there is none.
local _, ns = ...
ns.SharedFile = false
