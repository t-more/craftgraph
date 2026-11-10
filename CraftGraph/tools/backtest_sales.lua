-- Checks the sales estimate (Market.TrackSales) against a simulated item
-- whose true selling rate is known. Buyers take the cheapest stack; sellers
-- post, undercut (cancel and relist) and let auctions run out. Full scans
-- come at a fixed spacing. From the addon folder:
--   lua5.1 tools/backtest_sales.lua
local wow = dofile("tools/wowmock.lua")
wow.quiet = true
C_Item = { GetItemInfoInstant = function(id) return id, "", "", "", 0, 7, 0 end, GetItemCount = function() return 0 end }
C_Texture = { GetAtlasInfo = function() return nil end }
C_AuctionHouse = {}
local ns = wow.load("CraftGraph.toc")
wow.fire("ADDON_LOADED", "CraftGraph")
wow.fire("PLAYER_LOGIN")
local M = ns.Market

local seed = 4242
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
local function poisson(mean)
  local l, k, p = math.exp(-mean), 0, 1
  repeat k = k + 1 p = p * rnd() until p <= l
  return k - 1
end
local function band(left)
  if left < 1800 then return 0 elseif left < 7200 then return 1 elseif left < 43200 then return 2 end
  return 3
end

-- stacksPerDay: true sales (stacks a day). cancelPerDay: how often a seller pulls and relists an auction.
local function run(stacksPerDay, gapMinutes, cancelPerDay, days, id)
  ns.realm.items[id] = nil
  local t0 = 1794300000
  local book, sellers = {}, { "Anna", "Bo", "Cy", "Dee", "Eli", "Fay" }
  local price = 100
  local function post(now, owner)
    price = math.max(40, price + (rnd() < 0.5 and -1 or 1) * math.floor(rnd() * 4))
    local hours = ({ 12, 24, 48 })[1 + math.floor(rnd() * 3)]
    book[#book + 1] = { unit = price + math.floor(rnd() * 12), count = 20, owner = owner, ends = now + hours * 3600 }
  end
  for i = 1, 30 do post(t0 - math.floor(rnd() * 20000), sellers[1 + i % #sellers]) end
  local soldUnits, minutes = 0, days * 1440
  for minute = 1, minutes do
    local now = t0 + minute * 60
    -- buyers
    for _ = 1, poisson(stacksPerDay / 1440) do
      local best
      for i, a in ipairs(book) do if not best or a.unit < book[best].unit then best = i end end
      if best then soldUnits = soldUnits + book[best].count table.remove(book, best) end
    end
    -- sellers keep about 30 stacks listed
    if #book < 30 and rnd() < 0.5 then post(now, sellers[1 + math.floor(rnd() * #sellers)]) end
    -- undercut: pull one and relist it
    for _ = 1, poisson(cancelPerDay * #book / 1440) do
      local i = 1 + math.floor(rnd() * #book)
      if book[i] then local owner = book[i].owner table.remove(book, i) post(now, owner) end
    end
    -- run out
    for i = #book, 1, -1 do if book[i].ends <= now then table.remove(book, i) end end
    if minute % gapMinutes == 0 then
      local list = {}
      for _, a in ipairs(book) do list[#list + 1] = { a.unit, a.count, a.owner, band(a.ends - now) } end
      M.TrackSales(id, list, now)
    end
  end
  local s = M.Sales(id)
  return soldUnits / days, s
end

print("true sales a day vs the estimate (20 units a stack, about 30 stacks listed, 4 simulated days)")
print(string.format("%-34s %10s %10s %18s %8s", "case", "true", "estimate", "range (4 in 5)", "ratio"))
local id = 2600
for _, case in ipairs({
  { "busy item, scans every 15 min", 60, 15, 0.3 },
  { "busy item, scans every hour", 60, 60, 0.3 },
  { "busy item, scans every 3 h", 60, 180, 0.3 },
  { "busy item, scans every 8 h", 60, 480, 0.3 },
  { "slow item, scans every 15 min", 3, 15, 0.3 },
  { "slow item, scans every 3 h", 3, 180, 0.3 },
  { "nothing sells, scans every hour", 0, 60, 0.3 },
  { "nothing sells, heavy undercutting", 0, 60, 3 },
  { "busy item, heavy undercutting", 60, 60, 3 },
}) do
  local truth, s = run(case[2], case[3], case[4], 4, id)
  print(string.format("%-34s %10.0f %10.0f %8.0f to %-7.0f %8s %s", case[1], truth, s.rate, s.lo, s.hi,
    truth > 0 and string.format("%.2f", s.rate / truth) or "-", s.floor and "shown as \"at least\"" or ""))
  id = id + 1
end
