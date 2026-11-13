-- Builds Data/Base.lua, the base data shipped with the addon, from a saved
-- file of the player's own scans. Run from the addon folder:
--
--   lua5.1 tools/make_base.lua <SavedVariables/CraftGraph.lua> [auction house] [out file]
--
-- The auction house is a key like "CAMWOW EU4 Realm 2 PvP - Alliance"; by
-- default the one with the most items. The out file defaults to
-- Data/Base.lua.
--
-- What goes in: per item the price history (one point an hour), the last
-- ladder, how listings were stacked and the selling-rate belief, plus the
-- vendor prices seen at merchants and the market's share of stock sold.
-- What never goes in: seller names, character names, the log, settings,
-- and anything from Blizzard's web service (the saved file holds none of
-- it; that lives in Data/Online.lua, which is not read here).
--
-- Every item is unpacked again with the game's own reader (Market.lua) and
-- compared with what went in; the build stops if anything is off.
local savedPath, realmKey, outPath = arg[1], arg[2], arg[3] or "Data/Base.lua"
if not savedPath then
  io.stderr:write("usage: lua5.1 tools/make_base.lua <SavedVariables/CraftGraph.lua> [auction house] [out file]\n")
  os.exit(2)
end

local P = dofile("tools/basepack.lua")

-- The addon's own Market.lua, for its history and pricing functions.
local ns = { generation = 1, Data = { items = {} }, settings = {} }
function ns.On() end
function ns.Listen() end
function ns.Fire() end
function ns.Log(msg) io.stderr:write("log: " .. tostring(msg) .. "\n") end
date, time = os.date, os.time
assert(loadfile("Market.lua"))("CraftGraph", ns)
local M = ns.Market

dofile(savedPath)
local db = assert(CraftGraphDB, "no CraftGraphDB in " .. savedPath)
if not realmKey or realmKey == "" then
  local best = -1
  for key, r in pairs(db.realms or {}) do
    local n = 0
    for _ in pairs(r.items or {}) do n = n + 1 end
    if n > best then realmKey, best = key, n end
  end
end
local realm = assert(db.realms and db.realms[realmKey], "no auction house " .. tostring(realmKey))
ns.realm, ns.realmKey = realm, realmKey

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local HOUR_THINNING_AGE = 2 * 86400 + 3600     -- ThinHistory makes hourly what is older than this

-- Cleaning. A full scan read before the whole list had come in is only
-- part of the auction house: its cheapest prices are too high and
-- comparing with it makes everything that did not come look sold. The
-- addon's own repair (Market.lua, M.PartScans and M.CleanSales) finds such
-- scans by their auction count against the scans around them; their
-- points, their ladders and the sales worked out across them are left out.
local scanList = {}
do
  local list = realm.scans or {}
  for i = 1, #list, 2 do scanList[#scanList + 1] = { t = list[i], n = list[i + 1] } end
end
local fragments, prevScan = M.PartScans(realm.scans)
local fragmentCount = 0
for _ in pairs(fragments) do fragmentCount = fragmentCount + 1 end
local salesCut = { items = 0 }
local function CleanSales(it)
  if M.CleanSales(it, fragments, prevScan) then salesCut.items = salesCut.items + 1 end
end
local priorBefore = M.SalesPrior()

-- Every item's history without the part scans, thinned to one point an hour.
local ids, histories, from, to = {}, {}, nil, nil
local dropped = 0
for id, it in pairs(realm.items) do
  if type(id) == "number" and type(it) == "table" then
    local h = {}
    local all = M.History(it)
    for i = 1, #all, 4 do
      if fragments[all[i]] then
        dropped = dropped + 1
      else
        h[#h + 1], h[#h + 2], h[#h + 3], h[#h + 4] = all[i], all[i + 1], all[i + 2], all[i + 3]
      end
    end
    CleanSales(it)
    local priced = false
    for i = 1, #h, 4 do if h[i + 1] > 0 then priced = true break end end
    if priced then
      ids[#ids + 1] = id
      histories[id] = h
      from = min(from or h[1], h[1])
      to = max(to or h[#h - 3], h[#h - 3], it.lt or 0)
    end
  end
end
table.sort(ids)
assert(#ids > 0, "no priced items in " .. realmKey)
for _, id in ipairs(ids) do
  histories[id] = M.ThinHistory(histories[id], to + HOUR_THINNING_AGE)
end
local t0 = floor(from / P.SLOT) * P.SLOT

local function Record(id)
  local it = realm.items[id]
  -- A ladder from a part scan is left out.
  local ladderOk = it.lt and not fragments[it.lt]
  return {
    h = histories[id], l = ladderOk and it.l or nil, lt = ladderOk and it.lt or nil, ln = it.ln,
    ls = (it.ls or it.lp) and true or nil,
    bs = it.bs, sa = it.sa, sc = it.sc, sb = it.sb, sf = it.sf,
  }
end

-- The check: unpack with the game's reader and compare.
local worst = { time = 0, price = 0, units = 0, ladder = 0, sales = 0, over = -1 }
-- A price comes back within a tenth of a percent, plus rounding to a copper.
local function Price(back, went)
  worst.price = max(worst.price, abs(back / went - 1))
  worst.over = max(worst.over, abs(back - went) - (0.001001 * went + 0.5))
end
local function Compare(id, rec, back)
  local h, b = rec.h, back.h
  assert(#h == #b, id .. ": " .. #h / 4 .. " points went in, " .. #b / 4 .. " came out")
  for i = 1, #h, 4 do
    worst.time = max(worst.time, abs(h[i] - b[i]))
    if h[i + 1] > 0 then
      Price(b[i + 1], h[i + 1])
      Price(b[i + 2], max(h[i + 2], h[i + 1]))
      worst.units = max(worst.units, abs(b[i + 3] - max(1, floor(h[i + 3] + 0.5))))
    else
      assert(b[i + 1] == 0 and b[i + 3] == 0, id .. ": a 'none listed' point came out priced")
    end
  end
  if rec.l and rec.l[1] and rec.lt then
    local sumIn, sumOut = 0, 0
    for i = 2, #rec.l, 2 do sumIn = sumIn + rec.l[i] end
    for i = 2, #back.l, 2 do sumOut = sumOut + back.l[i] end
    worst.ladder = max(worst.ladder, abs(sumIn - sumOut), abs((rec.ln or sumIn) - back.ln))
    Price(back.l[1], rec.l[1])
  end
  if rec.sb and rec.sb > 0 then
    worst.sales = max(worst.sales, abs(back.sa - (rec.sa or 0)), abs(back.sc - (rec.sc or 0)),
      abs(back.sb - rec.sb) * 1000)
  end
end

local lines, points, bytes = {}, 0, 0
for _, id in ipairs(ids) do
  local rec = Record(id)
  local s = P.Item(rec, t0)
  Compare(id, rec, M.BaseUnpack(s, t0))
  lines[#lines + 1] = "[" .. id .. "]=\"" .. s .. "\","
  points, bytes = points + #rec.h / 4, bytes + #s
end
assert(worst.time <= P.SLOT / 2, "times moved by " .. worst.time .. " s")
assert(worst.over <= 0, "a price moved by more than a tenth of a percent and a copper")
assert(worst.units == 0, "units listed changed by " .. worst.units)
assert(worst.ladder == 0, "ladder units changed by " .. worst.ladder)
assert(worst.sales <= 0.06, "sales changed by " .. worst.sales)

-- How much of what is listed sells in a day, over the whole market: the
-- starting point for items a new install has not watched.
ns.generation = ns.generation + 1
local prior = M.SalesPrior()

-- Full scans within the time covered, part scans not counted.
local scans = 0
for _, s in ipairs(scanList) do
  if s.t >= from and s.t <= to and not fragments[s.t] then scans = scans + 1 end
end

-- Vendor prices and where (the merchant's name and zone; not players).
local vendor, vendorAt = {}, {}
local vids = {}
for id in pairs(db.vendor or {}) do vids[#vids + 1] = id end
table.sort(vids)
for _, id in ipairs(vids) do
  local price = db.vendor[id]
  if type(id) == "number" and type(price) == "number" and price > 0 then
    vendor[#vendor + 1] = "[" .. id .. "]=" .. string.format("%.10g", price) .. ","
    local at = db.vendorAt and db.vendorAt[id]
    if type(at) == "table" and (at.n or at.z) then
      vendorAt[#vendorAt + 1] = string.format("[%d]={n=%q,z=%q},", id, tostring(at.n or ""), tostring(at.z or ""))
        :gsub(',n=""', ""):gsub(',z=""', ""):gsub("{n=\"\",", "{")
    end
  end
end

local out = assert(io.open(outPath, "w"))
out:write("-- Base data: the author's own auction house scans, shipped so that a new install on\n",
  "-- this auction house starts with some history. Prices, depth, stack sizes and sales\n",
  "-- estimates only: no seller or character names, and none of Blizzard's web data.\n",
  "-- Written by tools/make_base.lua (format in tools/basepack.lua). Do not edit.\n",
  "local _, ns = ...\n",
  "ns.Base = {\n",
  string.format("  version = 1, realm = %q, made = %d, from = %d, to = %d, t0 = %d,\n", realmKey, os.time(), from, to, t0),
  string.format("  scans = %d, points = %d,\n", scans, points))
if prior then
  out:write(string.format("  salesPrior = { share = %.6g, stack = %.4g, items = %d },\n", prior.share, prior.stack, prior.items))
end
out:write("  vendor = {", table.concat(vendor), "},\n")
out:write("  vendorAt = {\n", table.concat(vendorAt, "\n"), "\n  },\n")
out:write("  items = {\n", table.concat(lines, "\n"), "\n  },\n}\n")
out:close()

local size = io.open(outPath):seek("end")
print(string.format("%s: %d items, %d points (one an hour at most), %d full scans, %s to %s",
  outPath, #ids, points, scans, os.date("%Y-%m-%d %H:%M", from), os.date("%Y-%m-%d %H:%M", to)))
print(string.format("  %.0f KB in all; item strings %.0f KB, %.1f bytes a point", size / 1024, bytes / 1024, bytes / points))
print(string.format("  unpacked again and compared: times within %d s, prices within 0.1%% and a copper (at most %.2f%%), units exact, ladders exact",
  worst.time, worst.price * 100))
print(string.format("  cleaned: %d part scans found (%s); %d points from them dropped; sales of %d items cut to the clean gaps",
  fragmentCount, (function()
    local list = {}
    for _, s in ipairs(scanList) do
      if fragments[s.t] then list[#list + 1] = os.date("%d %b %H:%M", s.t) .. " " .. s.n end
    end
    return table.concat(list, ", ")
  end)(), dropped, salesCut.items))
print(string.format("  %d vendor prices; sales prior: %s (before cleaning: %s)", #vendor,
  prior and string.format("%.1f%% of what is listed sells a day, from %d items", prior.share * 100, prior.items) or "none",
  priorBefore and string.format("%.1f%%", priorBefore.share * 100) or "none"))
