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
C_TradeSkillUI = { GetRecipeInfo = function() return { learned = true } end }
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

local SELLERS = { "Anwen", "Borin", "Cass", "Dunmar", "Elsie", "Fenna", "Garrick", "Hilde", "Ivo", "Jessa" }

-- The price of an item at a moment, and a ladder of listings around it.
local function Ladder(id, t, tr)
  local tm = os.date("*t", t)
  local hour = tm.hour + tm.min / 60
  local season = tr.evening * math.cos((hour - 20) / 24 * 2 * math.pi)
    + ((tm.wday == 1 or tm.wday == 7) and tr.weekend or -tr.weekend * 0.4)
  local price = base[id] * math.exp(tr.level + season + 0.012 * gauss())
  -- How much is listed drifts slowly, and is fuller in the evening.
  tr.stock = tr.stock * 0.97 + 0.07 * gauss()
  local amount = tr.depth * math.exp(tr.stock + 0.25 * math.cos((hour - 21) / 24 * 2 * math.pi))
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
      M.TrackSales(id, auctions, t)
      M.Record(id, raw, { full = true, t = t, perAuction = false })
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

return World
