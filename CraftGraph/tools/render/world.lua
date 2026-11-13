-- A simulated market for pictures: three weeks of scans for the items of a
-- few professions, with habits a real auction house has (dearer in the
-- evening and at the weekend, slow drifts, the odd jump), and a character
-- who knows the recipes and holds some goods. Nothing here is real data.
local wow = dofile("tools/render/wowlayout.lua")
local World = { wow = wow }

local seed = 20261110
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
local function gauss() return math.sqrt(-2 * math.log(rnd() + 1e-12)) * math.cos(2 * math.pi * rnd()) end
World.rnd = rnd

local inventory, bank = {}, {}
C_Item = {
  GetItemInfoInstant = function(id) return id, "", "", "", 0, 7, 0 end,
  GetItemCount = function(id, includeBank)
    return (inventory[id] or 0) + (includeBank and (bank[id] or 0) or 0)
  end,
}
C_Container = nil
C_AuctionHouse = {
  GetNumReplicateItems = function() return 0 end, ReplicateItems = function() end,
  IsThrottledMessageSystemReady = function() return true end, SendSearchQuery = function() end,
  SendBrowseQuery = function() end, MakeItemKey = function(id) return { itemID = id } end,
  GetBrowseResults = function() return {} end,
}

local ns = wow.load("CraftGraph.toc")
World.ns = ns
wow.fire("ADDON_LOADED", "CraftGraph")
wow.fire("PLAYER_LOGIN")
wow.itemName = function(id) return ns.ItemName(id) end
wow.itemColor = function(id) local r, g, b = ns.ItemColor(id) return { r, g, b } end

-- The end of the story: a Thursday evening.
local END = os.time({ year = 2026, month = 11, day = 12, hour = 19, min = 40 })
local DAYS = 21
World.END = END

-- Which professions the character has.
local wanted = { Mining = true, Blacksmithing = true, Engineering = true, Alchemy = true }
local skillIds = {}
for id, name in pairs(ns.Data.skills) do if wanted[name] then skillIds[#skillIds + 1] = id end end
table.sort(skillIds)
GetProfessions = nil
GetNumSkillLines = function() return #skillIds end
GetSkillLineInfo = function(i) return ns.Data.skills[skillIds[i]], false, nil, 150 end
-- Most recipes are known; a few are not, to show how those look.
C_TradeSkillUI = { GetRecipeInfo = function(spell) return { learned = spell % 5 ~= 0 } end }
local skillSet = {}
for _, id in ipairs(skillIds) do skillSet[id] = true end

-- Items in play: everything those professions make or use.
local items, madeBy = {}, {}
for spell, r in pairs(ns.Data.recipes) do
  local product = ns.Data.items[r[3]]
  -- Low-level goods only: what a young server trades in.
  if skillSet[r[1]] and product and (product[2] or 1) <= 2 and (product[3] or 0) <= 2500 then
    items[r[3]] = true
    madeBy[r[3]] = madeBy[r[3]] or r
    for i = 1, #r[7], 2 do items[r[7][i]] = true end
  end
end

-- A base price for each: raw goods from what a vendor pays, made goods
-- from their materials, some worth making and some not.
local base = {}
local function BaseOf(id, depth)
  if base[id] then return base[id] end
  local d = ns.Data.items[id]
  local r = madeBy[id]
  local price
  if ns.Market.VendorBuy(id) then
    price = ns.Market.VendorBuy(id) * 1.6
  elseif r and (depth or 0) < 6 then
    local cost = 0
    for i = 1, #r[7], 2 do cost = cost + BaseOf(r[7][i], (depth or 0) + 1) * r[7][i + 1] end
    price = cost / math.max(1, r[4]) * math.exp(-0.10 + 0.24 * gauss())
  else
    price = math.max(15, (d and d[3] or 20) * (2.2 + 2.5 * rnd()))
  end
  -- Never under what a vendor pays: nobody lists below that for long.
  base[id] = math.max(12, price, (d and d[3] or 0) * (1.4 + 0.6 * rnd()))
  return base[id]
end
local ids = {}
for id in pairs(items) do if ns.Data.items[id] then ids[#ids + 1] = id end end
table.sort(ids)
for _, id in ipairs(ids) do BaseOf(id) end
World.ids = ids

-- Kinds of goods, roughly as the game would name them: goods by the
-- profession that makes them, raw materials by the one that uses them.
local usedBy = {}
for spell, r in pairs(ns.Data.recipes) do
  if skillSet[r[1]] then
    for i = 1, #r[7], 2 do usedBy[r[7][i]] = usedBy[r[7][i]] or ns.Data.skills[r[1]] end
  end
end
local MADE = { Alchemy = { 0, 1, "Consumable", "Potions" }, Mining = { 7, 7, "Trade Goods", "Metal & Stone" },
  Blacksmithing = { 4, 0, "Armor", "Miscellaneous" }, Engineering = { 7, 1, "Trade Goods", "Parts" } }
local RAW = { Alchemy = { 7, 9, "Trade Goods", "Herb" }, Mining = { 7, 7, "Trade Goods", "Metal & Stone" },
  Blacksmithing = { 7, 7, "Trade Goods", "Metal & Stone" }, Engineering = { 7, 11, "Trade Goods", "Other" } }
C_Item.GetItemInfoInstant = function(id)
  local r = madeBy[id]
  local k = r and MADE[ns.Data.skills[r[1]]] or RAW[usedBy[id] or ""] or { 7, 11, "Trade Goods", "Other" }
  return id, k[3], k[4], "", 0, k[1], k[2]
end

-- Each item's own character.
local traits = {}
for _, id in ipairs(ids) do
  traits[id] = {
    drift = math.max(-0.02, math.min(0.012, -0.006 + 0.01 * gauss())),   -- per day: a young market mostly gets cheaper
    stock = 0,
    evening = 0.02 + 0.06 * rnd(),              -- dearer around 20:00
    weekend = -0.01 + 0.06 * rnd(),
    wander = 0.02 + 0.03 * rnd(),
    level = 0,
    depth = math.floor(20 + 400 * rnd() * rnd()),
  }
end

-- One item tells a story, to show supply and demand at work: a quiet
-- week, then goods flood in and the price sinks, the flood dries up, a
-- weekend rush buys the market nearly empty and the price jumps, and
-- things settle again. Returns price, stock (both as multiples) and units
-- sold a day at a moment `d` days into the three weeks.
local function Story(d)
  local function ramp(a, b, from, to) return a + (b - a) * math.max(0, math.min(1, (d - from) / (to - from))) end
  if d < 7 then return 1, 1, 300 end
  if d < 11 then return ramp(1, 0.68, 7, 10), ramp(1, 3.1, 7, 9.5), ramp(300, 390, 7, 10) end
  if d < 14 then return ramp(0.68, 0.9, 11, 14), ramp(3.1, 0.9, 11, 13.5), ramp(390, 330, 11, 14) end
  if d < 18 then return ramp(0.9, 1.38, 14, 16.5), ramp(0.9, 0.35, 14, 16), ramp(330, 720, 14, 15.5) end
  return ramp(1.38, 1.15, 18, 21), ramp(0.35, 0.95, 18, 20.5), ramp(720, 320, 18, 20)
end
local STORY_ITEM = 2840          -- Copper Bar

local SELLERS = { "Anwen", "Borin", "Cass", "Dunmar", "Elsie", "Fenna", "Garrick", "Hilde", "Ivo", "Jessa" }

-- The price of an item at a moment, and a ladder of listings around it.
local function Ladder(id, t, tr)
  local tm = os.date("*t", t)
  local hour = tm.hour + tm.min / 60
  local season = tr.evening * math.cos((hour - 20) / 24 * 2 * math.pi)
    + ((tm.wday == 1 or tm.wday == 7) and tr.weekend or -tr.weekend * 0.4)
  local price = base[id] * math.exp(tr.level + season + 0.012 * gauss())
  local storyStock
  if id == STORY_ITEM then
    local p, stock = Story(DAYS - (END - t) / 86400)
    price = base[id] * p * math.exp(season * 0.5 + 0.012 * gauss())
    storyStock = stock
  end
  -- How much is listed drifts slowly, and is fuller in the evening.
  tr.stock = tr.stock * 0.97 + 0.07 * gauss()
  local amount = tr.depth * math.exp(tr.stock + 0.25 * math.cos((hour - 21) / 24 * 2 * math.pi))
  if storyStock then
    amount = 420 * storyStock * math.exp(0.12 * math.cos((hour - 21) / 24 * 2 * math.pi) + 0.05 * gauss())
  end
  local raw, p = {}, price
  local levels = 3 + id % 4
  for i = 1, levels do
    local share = 0.6 + 0.8 * ((i * 0.37 + id * 0.13) % 1)
    raw[#raw + 1] = { math.max(1, math.floor(p + 0.5)), math.max(1, math.floor(amount / levels * share)),
      SELLERS[1 + (id + i * 3) % #SELLERS] }
    p = p * (1.03 + 0.05 * ((i * 0.61 + id * 0.29) % 1))
  end
  return raw
end

-- Scans: hourly from morning to midnight, a few at night, some days thin.
local M = ns.Market
local scans = 0
for step = DAYS * 24, 0, -1 do
  local t = END - step * 3600 - math.floor(rnd() * 600)
  local hour = tonumber(os.date("%H", t))
  local day = math.floor(step / 24)
  local scanned = (hour >= 9 and rnd() < 0.8) or (hour < 9 and rnd() < 0.12)
  if day == 9 or day == 10 then scanned = scanned and rnd() < 0.2 end       -- a weekend away
  if step == 0 then scanned, t = true, END - 420 end
  for _, id in ipairs(ids) do
    local tr = traits[id]
    tr.level = tr.level + tr.drift / 24 + tr.wander * gauss() / math.sqrt(24)
    if rnd() < 0.0015 then tr.level = tr.level + (rnd() < 0.5 and -1 or 1) * (0.15 + 0.2 * rnd()) end
  end
  if scanned then
    scans = scans + 1
    wow.now = t
    for _, id in ipairs(ids) do
      local raw = Ladder(id, t, traits[id])
      local auctions = {}
      for _, level in ipairs(raw) do
        -- as separate auctions for the sales tracker: stacks of up to 20
        local left = level[2]
        while left > 0 and #auctions < 40 do
          local n = math.min(20, left)
          auctions[#auctions + 1] = { level[1], n, level[3], 3 }
          left = left - n
        end
      end
      if id ~= STORY_ITEM then M.TrackSales(id, auctions, t) end
      M.Record(id, raw, { full = true, t = t, perAuction = false })
      if id == STORY_ITEM then
        -- Its sales are written straight from the story: busier in the evening.
        local rec = ns.realm.items[id]
        local _, _, demand = Story(DAYS - (END - t) / 86400)
        local rate = demand * math.exp(0.3 * math.cos((hour - 20) / 24 * 2 * math.pi) + 0.25 * gauss())
        local gap = rec.storyLast and math.min((t - rec.storyLast) / 86400, 0.5) or 1 / 24
        rec.storyLast = t
        rec.sh = rec.sh or {}
        rec.sh[#rec.sh + 1], rec.sh[#rec.sh + 2] = t, math.floor(rate + 0.5)
        local fade = 0.5 ^ (gap / 7)
        rec.sa = (rec.sa or 0) * fade + rate * gap
        rec.sc = (rec.sc or 0) * fade + rate * gap / 20
        rec.sb = (rec.sb or 0) * fade + gap
      end
    end
  end
end
World.scans = scans
wow.now = END
ns.db.lastFullScan = END - 420
ns.generation = ns.generation + 1

-- What the character holds.
local held = 0
for _, id in ipairs(ids) do
  if rnd() < 0.06 and held < 14 then
    inventory[id] = 5 + math.floor(rnd() * 40)
    held = held + 1
  elseif rnd() < 0.03 then
    bank[id] = 20 + math.floor(rnd() * 60)
  end
end
-- Some bars in the bags, so that a few things can be made on the spot.
inventory[2841], inventory[2840], inventory[3576] = 48, 30, 26      -- bronze, copper, tin bars
bank[2841] = 60
World.inventory, World.bank = inventory, bank
ns.Player.version = ns.Player.version + 1

-- Finds an item by name.
function World.item(name)
  for _, id in ipairs(ids) do
    if ns.ItemName(id) == name then return id end
  end
  error("no item called " .. name)
end

-- A later scan: prices move on by `hours` and everything is recorded again.
function World.scan(hours)
  local t = wow.now + hours * 3600
  for _, id in ipairs(ids) do
    local tr = traits[id]
    tr.level = tr.level + tr.drift * hours / 24 + tr.wander * gauss() * math.sqrt(hours / 24)
  end
  wow.now = t
  for _, id in ipairs(ids) do
    M.Record(id, Ladder(id, t, traits[id]), { full = true, t = t })
  end
  ns.db.lastFullScan = t
  ns.Fire("MARKET_UPDATED")
  wow.runTimers()
end

------------------------------------------------------------------------------
-- An imaginary rush, to show what riding a wave looks like. `age` days ago
-- a crowd of new players arrived (negative: they have not come yet). They
-- all want the same potion, so it is bought nearly empty and its price
-- doubles; a day later their own gathering floods the market with herbs,
-- so the materials get cheap while the potion is still dear; within a
-- week other alchemists catch up and it is over. World.wave(nil) puts the
-- ordinary simulated history back.
------------------------------------------------------------------------------
local WAVE = { potion = 3390, herbs = { 2452, 3355 } }     -- Elixir of Lesser Agility; Swiftthistle, Wild Steelbloom
World.WAVE = WAVE
local original = {}
local function shape(d, points)
  -- points: { day, value, day, value, ... }; straight lines between them.
  if d <= points[1] then return points[2] end
  for i = 3, #points, 2 do
    if d <= points[i] then
      local d0, v0, d1, v1 = points[i - 2], points[i - 1], points[i], points[i + 1]
      return v0 + (v1 - v0) * (d - d0) / (d1 - d0)
    end
  end
  return points[#points]
end
local SHAPES = {
  potion = {
    price = { 0, 1, 1.5, 2.3, 4, 2.0, 9, 1.12, 13, 1.02 },
    stock = { 0, 1, 1, 0.15, 4, 0.6, 9, 1.6, 13, 1.1 },
    sold = { 0, 60, 1, 420, 4, 300, 9, 110, 13, 70 },
  },
  herb = {
    price = { 0, 1, 1, 1.45, 3, 0.8, 7, 0.68, 13, 0.97 },
    stock = { 0, 1, 1, 0.5, 4, 2.8, 10, 2.0, 14, 1.3 },
    sold = { 0, 200, 1, 700, 5, 500, 10, 260, 14, 220 },
  },
}

function World.wave(age)
  local all = { WAVE.potion, WAVE.herbs[1], WAVE.herbs[2] }
  for _, id in ipairs(all) do
    if original[id] == nil then original[id] = ns.realm.items[id] or false end
  end
  if age == nil then
    for _, id in ipairs(all) do ns.realm.items[id] = original[id] or nil end
    ns.generation = ns.generation + 1
    return
  end
  -- Steady prices to start from: the potion a little over its materials.
  local herbBase = { [WAVE.herbs[1]] = 310, [WAVE.herbs[2]] = 120 }
  local potionBase = (310 + 120 + 36) * 1.10 / 0.95
  local saveSeed = seed
  seed = 4242
  for _, id in ipairs(all) do
    ns.realm.items[id] = nil
    local kind = id == WAVE.potion and "potion" or "herb"
    local sh = SHAPES[kind]
    local start = id == WAVE.potion and potionBase or herbBase[id]
    local depth = id == WAVE.potion and 180 or 420
    local lastT
    for step = DAYS * 24, 0, -1 do
      local t = END - step * 3600 - math.floor(rnd() * 600)
      local hour = tonumber(os.date("%H", t))
      local scanned = (hour >= 9 and rnd() < 0.8) or (hour < 9 and rnd() < 0.12)
      if step == 0 then scanned, t = true, END - 420 end
      if scanned then
        local d = age - (END - t) / 86400            -- days since the crowd arrived
        local evening = math.cos((hour - 20) / 24 * 2 * math.pi)
        local price = start * shape(d, sh.price) * math.exp(0.02 * evening + 0.015 * gauss())
        local amount = depth * shape(d, sh.stock) * math.exp(0.12 * evening + 0.06 * gauss())
        local raw, p = {}, price
        for i = 1, 4 do
          raw[#raw + 1] = { math.max(1, math.floor(p + 0.5)), math.max(1, math.floor(amount / 4 * (0.7 + 0.2 * i))),
            SELLERS[1 + (id + i * 3) % #SELLERS] }
          p = p * (1.03 + 0.02 * i)
        end
        wow.now = t
        M.Record(id, raw, { full = true, t = t, perAuction = false })
        local rec = ns.realm.items[id]
        local rate = shape(d, sh.sold) * math.exp(0.3 * evening + 0.2 * gauss())
        local gap = lastT and math.min((t - lastT) / 86400, 0.5) or 1 / 24
        lastT = t
        rec.sh = rec.sh or {}
        rec.sh[#rec.sh + 1], rec.sh[#rec.sh + 2] = t, math.floor(rate + 0.5)
        local fade = 0.5 ^ (gap / 7)
        rec.sa = (rec.sa or 0) * fade + rate * gap
        rec.sc = (rec.sc or 0) * fade + rate * gap / 20
        rec.sb = (rec.sb or 0) * fade + gap
      end
    end
  end
  seed = saveSeed
  wow.now = END
  ns.generation = ns.generation + 1
end

return World
