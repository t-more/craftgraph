-- Draws pictures from a real saved file instead of the simulated market:
--   lua5.1 tools/render/real.lua <SavedVariables/CraftGraph.lua> <output folder> [item name] [seconds since the last scan]
-- Nothing is written back. The pictures show prices only: no seller names
-- and no character name (the Sales seen page is not drawn).
local saved, OUT, itemName, since = arg[1], arg[2] or "real-build", arg[3] or "Elixir of Lesser Agility", tonumber(arg[4] or "")
assert(saved, "give the path of the saved file")
local wow = dofile("tools/render/wowlayout.lua")
C_Item = { GetItemInfoInstant = function(id) return id, "", "", "", 0, 7, 0 end, GetItemCount = function() return 0 end }
C_Container = nil
C_AuctionHouse = {
  GetNumReplicateItems = function() return 0 end, ReplicateItems = function() end,
  IsThrottledMessageSystemReady = function() return true end, SendSearchQuery = function() end,
  SendBrowseQuery = function() end, MakeItemKey = function(id) return { itemID = id } end,
  GetBrowseResults = function() return {} end,
}
dofile(saved)                              -- sets CraftGraphDB
local db = CraftGraphDB
local key, realm = next(db.realms)
local best = 0
for k, r in pairs(db.realms) do            -- the realm with the most items
  local n = 0
  for _ in pairs(r.items or {}) do n = n + 1 end
  if n > best then key, realm, best = k, r, n end
end
local last = 0
for _, it in pairs(realm.items) do if it.lt and it.lt > last then last = it.lt end end
wow.now = since and (last + since) or os.time()
db.settings = db.settings or {}
db.settings.windowOpen, db.settings.reopen, db.settings.hudHidden = nil, nil, true
local ns = wow.load("CraftGraph.toc")
ns.Helper, ns.Online, ns.Latest, ns.SharedFile = false, false, false, false
wow.fire("ADDON_LOADED", "CraftGraph")
wow.fire("PLAYER_LOGIN")
ns.realm, ns.realmKey = realm, key
ns.db.vendor = db.vendor or {}
wow.itemName = function(id) return ns.ItemName(id) end
wow.itemColor = function(id) local r, g, b = ns.ItemColor(id) return { r, g, b } end
-- The character's own recipes, without the character.
local known, skills, list = {}, {}, {}
for _, char in pairs(db.chars or {}) do
  for spell in pairs(char.known or {}) do known[spell] = true end
end
for spell in pairs(known) do local r = ns.Data.recipes[spell] if r then skills[r[1]] = true end end
for id in pairs(skills) do list[#list + 1] = id end
table.sort(list)
GetProfessions = nil
GetNumSkillLines = function() return #list end
GetSkillLineInfo = function(i) return ns.Data.skills[list[i]], false, nil, 300 end
C_TradeSkillUI = { GetRecipeInfo = function(spell) return { learned = known[spell] or false } end }
ns.Player.version = ns.Player.version + 1
ns.generation = ns.generation + 1

local id
for item, d in pairs(ns.Data.items) do if d[1] == itemName then id = item end end
assert(id, "no item called " .. itemName)
local function settle() wow.runTimers() end
local function still(name, opts) wow.svg(OUT .. "/" .. name .. ".svg", opts) end
os.execute('mkdir -p "' .. OUT .. '"')
local s = ns.settings
s.showGuesses, s.sideChart, s.chartDays, s.chartDemand, s.chartFlow, s.chartGrid, s.chartBars, s.qty = false, "history", 0, true, true, true, false, 20
ns.Open(id) settle()
ns.UI.SetQuantity(20) settle()
still("real-graph", { zoom = 1.5 })
ns.UI.ShowTrends(true) settle()
still("real-trends", { zoom = 1.5 })
ns.UI.ShowWorth(true) settle()
for _, f in ipairs(wow.frames) do
  if f.filters and f.summary then f.filters.item.scripts.OnClick(f.filters.item) end
end
settle()
still("real-ways", { zoom = 1.5 })

-- The facts, for the text beside the pictures.
local M, S, O = ns.Market, ns.Stats, ns.Opt
local function coins(c) return string.format("%.2fs", c / 100) end
local info = M.Info(id)
local series = M.Series(id)
print(itemName, "id", id, "scans", #series, "now", os.date("%d %b %H:%M", wow.now), "last scan", os.date("%d %b %H:%M", last))
if info then print("price now", coins(info.price or 0), "age h", (info.age or 0) / 3600, "listed", info.qty, "turnover", info.turnover) end
local lo, hi = math.huge, 0
for _, p in ipairs(series) do if p[2] and p[2] > 0 then lo, hi = math.min(lo, p[2]), math.max(hi, p[2]) end end
print("range", coins(lo), coins(hi), "first", os.date("%d %b %H:%M", series[1][1]), coins(series[1][2]))
for _, q in ipairs({ 1, 20 }) do
  local e = O.Evaluate(id, q)
  print("make", q, "cost", e.cost and coins(e.cost), "revenue", e.revenue and coins(e.revenue), "profit", e.profit and coins(e.profit), "sd", e.sd and coins(e.sd))
end
local r = O.Recipe(O.BestRecipe(id))
for i = 1, #r[7], 2 do
  local m = M.Info(r[7][i])
  print("  material", ns.ItemName(r[7][i]), "x" .. r[7][i + 1], m and m.price and coins(m.price), "listed", m and m.qty, "vendor", M.VendorBuy(r[7][i]))
end
print("trust", S.Trust(id))
local wanted = {}
for key in pairs(wow.missingIcons) do wanted[#wanted + 1] = key end
table.sort(wanted)
local f = assert(io.open(OUT .. "/icons-wanted.txt", "w"))
f:write(table.concat(wanted, "\n"), "\n")
f:close()
local errors = 0
for _, line in ipairs(ns.db.log or {}) do
  if line:find("ERROR") then errors = errors + 1 if errors <= 3 then print(line:sub(1, 400)) end end
end
print("errors in the addon log: " .. errors)
