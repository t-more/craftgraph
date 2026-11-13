-- Checks the base data and the news on real files. From the addon folder:
--   lua5.1 tools/qa_base.lua <SavedVariables/CraftGraph.lua> [item kinds .lua]
-- The item kinds file is optional: { [itemID] = { classID, subClassID,
-- kind name, sub-kind name } }, made from the game's ItemClass, ItemSubClass
-- and Item tables; without it the news has no "by kind of goods" part here
-- (in the game, the game itself names the kinds).
--
-- 1. The author's own install (the saved file the base was built from):
--    with the base switched on, every item's prices, sales and the news
--    must be exactly what they are with it off.
-- 2. A friend's new install on the same auction house, three days after
--    the base ends: what the base gives them, and the news from it alone.
local src = io.open("tools/test.lua"):read("*a"):gsub("os%.exit%b()", "")
local realprint = print
print = function() end
assert(loadstring(src .. "\n_G.NS = ns _G.FRAMES = frames _G.RUNT = RunTimers"))()
print = realprint
local ns, RunTimers = NS, RUNT
local M, N = ns.Market, ns.News
local base = assert(ns.Base and ns.Base.items and ns.Base, "no base data in Data/Base.lua")

if arg[2] then
  local kinds = dofile(arg[2])
  C_Item.GetItemInfoInstant = function(id)
    local k = kinds[id]
    if k then return id, k[3], k[4], "", 0, k[1], k[2] end
    return id
  end
end

dofile(assert(arg[1], "usage: lua5.1 tools/qa_base.lua <saved file> [item kinds .lua]"))
local db = CraftGraphDB
local NOW
time = function() return NOW end
ns.db.log = {}
local function errors()
  local n = 0
  for _, line in ipairs(ns.db.log) do
    if line:find("ERROR") then n = n + 1 if n <= 5 then print("   LOG: " .. line:sub(1, 300)) end end
  end
  return n
end
local function Pct(x) return string.format("%+.1f%%", x * 100) end

local function News(label)
  N.result = nil
  local t = os.clock()
  local got
  N.Refresh(function(r) got = r end, true)
  RunTimers()
  local took = os.clock() - t
  print(string.format("%s: news over %d items in %.2f s of work (spread over frames in the game)", label, got and got.items or 0, took))
  if not got or got.empty then print("  no news") return got end
  print("  newest data " .. ns.Age(NOW - got.anchor) .. " (" .. got.anchorFrom .. ")")
  print("  overall: day " .. N.Words(got.all.day, true) .. "; " .. N.SpanWords(got.all.span) .. " " .. N.Words(got.all.week, true))
  print("  headline: " .. tostring(N.Headline(got)))
  for i = 1, math.min(12, #got.kinds) do
    local k = got.kinds[i]
    print(string.format("  %-16s %4d items  day %-28s week %s", k.name, #k.items, N.Words(k.day, true), N.Words(k.week, true)))
  end
  for _, side in ipairs({ "rising", "falling" }) do
    local names = {}
    for i = 1, math.min(5, #got[side]) do
      names[#names + 1] = ns.ItemName(got[side][i].id) .. " " .. Pct(got[side][i].change)
    end
    print("  " .. side .. ": " .. table.concat(names, ", "))
  end
  for _, p in ipairs(got.professions) do
    local cells = {}
    for _, r in ipairs(p.ranks) do
      cells[#cells + 1] = r.name:sub(1, 4) .. " " .. (r.mats.day.word or "-") .. "/" .. (r.goods.day.word or "-")
    end
    print(string.format("  %-15s %s", p.name, table.concat(cells, "  ")))
  end
  return got
end

------------------------------------------------------------------------------
-- 1. The author's own install.
local realm = assert(db.realms[base.realm], "the saved file has no data for " .. base.realm)
ns.realm, ns.realmKey = realm, base.realm
ns.db.vendor, ns.db.vendorAt = db.vendor or {}, db.vendorAt
local last = 0
for _, it in pairs(realm.items) do if it.lt and it.lt > last then last = it.lt end end
NOW = last + 600
ns.Online, ns.SharedFile = false, false
local ids = {}
for id in pairs(realm.items) do ids[#ids + 1] = id end
table.sort(ids)
local function Snapshot(id)
  local s = M.Series(id)
  local info = M.Info(id) or {}
  local sales = M.Sales(id)
  local parts = { #s, info.price or "-", info.total or "-", info.base and "base" or "", sales and string.format("%.6f", sales.rate) or "-" }
  for i = 1, #s do parts[#parts + 1] = s[i][1] .. ":" .. s[i][2] end
  return table.concat(parts, ",")
end
M.SetSource("Base", false)
local off = {}
for _, id in ipairs(ids) do off[id] = Snapshot(id) end
local newsOff = News("own install, base off")
M.SetSource("Base", true)
local differ = 0
for _, id in ipairs(ids) do
  if Snapshot(id) ~= off[id] then
    differ = differ + 1
    if differ <= 3 then print("  differs: " .. id .. " " .. ns.ItemName(id)) end
  end
end
local newsOn = News("own install, base on")
local same = newsOff and newsOn and N.Words(newsOff.all.day, true) == N.Words(newsOn.all.day, true)
  and newsOff.items == newsOn.items
print(string.format("CHECK own install: %d of %d items change with the base on (want 0); news the same: %s; errors: %d",
  differ, #ids, tostring(same), errors()))

------------------------------------------------------------------------------
-- 2. A friend's new install, three days after the base ends.
ns.realm = { items = {} }
ns.db.vendor, ns.db.vendorAt = {}, nil
NOW = base.to + 3 * 86400
ns.generation = ns.generation + 1
local priced, withSales, withLadder, n = 0, 0, 0, 0
local t = os.clock()
for id in pairs(base.items) do
  n = n + 1
  local info = M.Info(id)
  if info and info.base and (info.price or info.lastPrice) then priced = priced + 1 end
  if info and info.turnover then withSales = withSales + 1 end
  if info and info.ladder and #info.ladder >= 4 then withLadder = withLadder + 1 end
end
local vendors = 0
for id in pairs(base.vendor or {}) do if M.VendorBuy(id) then vendors = vendors + 1 end end
print(string.format("new install: %d of %d items have a price from the base (%d with depth, %d with a selling rate), %d vendor prices; %.2f s",
  priced, n, withLadder, withSales, vendors, os.clock() - t))
local prior = ns.Stats.MarketPrior()
print("new install: market prior from " .. tostring(prior and prior.sampled) .. " sampled items; sales prior "
  .. tostring(M.SalesPrior() and M.SalesPrior().base and "from the base" or "none"))
News("new install, base only")
ns.UI.ShowWorth(true) RunTimers()
ns.UI.ShowNews(true) RunTimers()
print(string.format("CHECK new install: errors: %d", errors()))
