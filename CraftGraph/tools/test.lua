-- Offline test for CraftGraph. Runs the addon against a mock of the game's
-- interface so the logic and every window code path execute without the
-- game. Run from the addon folder:  lua5.1 tools/test.lua
-- It cannot check that the real game accepts each call, only that our own
-- code is consistent and the numbers come out right.

local failures, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. what)
  end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

------------------------------------------------------------------------------
-- Mock game interface
------------------------------------------------------------------------------
local now = 1794300000
local clock = 0
time = function() return now end
date = os.date
GetTime = function() return clock end
debugstack = function() return debug.traceback("", 2) end

-- The game's xpcall passes extra arguments on; plain Lua 5.1 does not.
local rawxpcall = xpcall
xpcall = function(f, handler, ...)
  local args, n = { ... }, select("#", ...)
  return rawxpcall(function() return f(unpack(args, 1, n)) end, handler)
end

local unknownCalls = {}
local Widget = {}
Widget.__index = function(self, key)
  local v = rawget(Widget, key)
  if v ~= nil then return v end
  -- Any method we did not model (the game's methods start with a capital):
  -- accept the call and return nothing. Plain fields stay nil.
  if type(key) == "string" and key:match("^%u") then
    return function() unknownCalls[key] = true end
  end
  return nil
end
local function NewWidget(kind)
  return setmetatable({ kind = kind, scripts = {}, shown = true, text = "", w = 0, h = 0 }, Widget)
end
function Widget:SetScript(name, fn) self.scripts[name] = fn end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:HookScript(name, fn)
  local old = self.scripts[name]
  self.scripts[name] = function(...)
    if old then old(...) end
    fn(...)
  end
end
function Widget:Show()
  local was = self.shown
  self.shown = true
  if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Widget:Hide()
  local was = self.shown
  self.shown = false
  if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Widget:SetShown(s) if s then self:Show() else self:Hide() end end
function Widget:IsShown() return self.shown end
function Widget:SetText(t) self.text = tostring(t) end
function Widget:GetText() return self.text end
function Widget:SetSize(w, h) self.w, self.h = w, h end
function Widget:SetWidth(w) self.w = w end
function Widget:SetHeight(h) self.h = h end
function Widget:GetWidth() return self.w > 0 and self.w or 800 end
function Widget:GetHeight() return self.h > 0 and self.h or 600 end
function Widget:GetEffectiveScale() return 1 end
function Widget:SetChecked(c) self.checked = c end
function Widget:GetChecked() return self.checked end
function Widget:HasFocus() return self.focus or false end
function Widget:SetEnabled(e) self.enabled = e end
function Widget:CreateTexture() return NewWidget("Texture") end
function Widget:CreateFontString() return NewWidget("FontString") end
function Widget:CreateLine() return NewWidget("Line") end
function Widget:RegisterEvent(event) self.events = self.events or {}; self.events[event] = true end
function Widget.StartMoving() end
function Widget.StopMovingOrSizing() end

local frames = {}
function CreateFrame(kind, name, parent, template)
  local f = NewWidget(kind)
  f.template = template
  frames[#frames + 1] = f
  if name then _G[name] = f end
  return f
end
UIParent = NewWidget("Frame")
UIParent.w, UIParent.h = 1365, 768
GameTooltip = NewWidget("GameTooltip")
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) print("  [chat] " .. msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|A.-|a", "")) end }
UISpecialFrames = {}
tinsert = table.insert
SlashCmdList = {}
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function hooksecurefunc() end
function IsAltKeyDown() return false end
function IsShiftKeyDown() return false end
function IsControlKeyDown() return false end
function IsMouseButtonDown() return false end
function GetCursorPosition() return 0, 0 end
function GetRealmName() return "TestRealm" end
function UnitFactionGroup() return "Alliance" end

local timers = {}
C_Timer = {
  After = function(delay, fn) timers[#timers + 1] = fn end,
  NewTicker = function(delay, fn)
    local t = { cancelled = false }
    function t:Cancel() self.cancelled = true end
    t.fn = fn
    return t
  end,
}
local function RunTimers()
  local guard = 0
  while #timers > 0 and guard < 100000 do
    guard = guard + 1
    table.remove(timers, 1)()
  end
end

C_Item = {
  GetItemInfoInstant = function(id) return id, "", "", "", 0, 7, 0 end,
  GetItemNameByID = function(id) return "Item" .. id end,
}
C_Texture = { GetAtlasInfo = function() return nil end }
ChatFrameUtil = { InsertLink = function() end }
HandleModifiedItemClick = function() end
Enum = {
  AuctionHouseSortOrder = { Price = 0 },
  AuctionHouseFilter = { ExactMatch = 5, PoorQuality = 6, CommonQuality = 7, UncommonQuality = 8,
    RareQuality = 9, EpicQuality = 10, LegendaryQuality = 11, ArtifactQuality = 12 },
}

-- A fake auction house: listings[itemID] = { {unitPrice, quantity}, ... }
local listings = {}
local sentQueries = {}
C_AuctionHouse = {
  GetNumCommoditySearchResults = function(id) return listings[id] and #listings[id] or 0 end,
  GetCommoditySearchResultInfo = function(id, i)
    local l = listings[id][i]
    return { unitPrice = l[1], quantity = l[2] }
  end,
  HasFullCommoditySearchResults = function() return true end,
  GetCommoditySearchResultsQuantity = function(id)
    local n = 0
    for _, l in ipairs(listings[id] or {}) do n = n + l[2] end
    return n
  end,
  IsThrottledMessageSystemReady = function() return true end,
  MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
  SendSearchQuery = function(key) sentQueries[#sentQueries + 1] = key.itemID end,
  SendBrowseQuery = function() end,
  GetBrowseResults = function() return {} end,
  GetNumReplicateItems = function() return 0 end,
  ReplicateItems = function() end,
}

------------------------------------------------------------------------------
-- Load the addon in the order the TOC lists it
------------------------------------------------------------------------------
local ns = {}
local files = {}
for line in io.lines("CraftGraph.toc") do
  if line:match("%.lua%s*$") and not line:match("^#") then
    files[#files + 1] = (line:gsub("\\", "/"):gsub("%s+$", ""))
  end
end
for _, file in ipairs(files) do
  local chunk, err = loadfile(file)
  if not chunk then error(err) end
  chunk("CraftGraph", ns)
end

local eventFrame = frames[1]
local function FireEvent(event, ...)
  eventFrame.scripts.OnEvent(eventFrame, event, ...)
end
FireEvent("ADDON_LOADED", "CraftGraph")
FireEvent("PLAYER_LOGIN")
-- Most checks below look at forecasts built from little data; the check
-- that such guesses are hidden by default has its own section.
ns.settings.showGuesses = true
check(ns.db ~= nil and ns.realm ~= nil, "saved data initialised")

-- Version: the number in the code and the one in the TOC agree, and a
-- newer release is only announced when one is known of.
do
  local toc
  for line in io.lines("CraftGraph.toc") do toc = toc or line:match("^## Version:%s*(%S+)") end
  check(ns.VERSION == toc, "the version in Core.lua matches the TOC: " .. tostring(ns.VERSION) .. " and " .. tostring(toc))
  check(ns.VersionLater("0.10", "0.9") and ns.VersionLater("1.0", "0.9.9") and ns.VersionLater("0.1.1", "0.1")
    and not ns.VersionLater("0.1", "0.1") and not ns.VersionLater("0.1", "0.1.0") and not ns.VersionLater("0.9", "0.10"),
    "versions are compared number by number")
  check(ns.Latest == false and ns.NewerVersion() == nil, "nothing is known of a newer version until the outside tool says so")
  ns.Latest = { version = "9.9", url = "https://example.invalid/r", checked = now - 3600 }
  check(ns.NewerVersion() and ns.NewerVersion().version == "9.9", "a newer release is noticed")
  SlashCmdList.CRAFTGRAPH("version")
  ns.Latest = { version = ns.VERSION, checked = now - 3600 }
  check(ns.NewerVersion() == nil, "the same version is not newer")
  SlashCmdList.CRAFTGRAPH("version")
  ns.Latest = false
  SlashCmdList.CRAFTGRAPH("version")
end

local M, S, O, G = ns.Market, ns.Stats, ns.Opt, ns.Graph

------------------------------------------------------------------------------
-- Ladders
------------------------------------------------------------------------------
do
  local flat, total = M.Compress({ { 30, 5 }, { 10, 1 }, { 20, 2 }, { 40, 100 } })
  check(total == 108, "compress keeps the total")
  check(flat[1] == 10 and flat[2] == 1, "cheapest unit stays exact")
  local sum = 0
  for i = 1, #flat, 2 do sum = sum + flat[i] * flat[i + 1] end
  check(near(sum, 10 + 40 + 150 + 4000, 60), "compress keeps the total value (within rounding), got " .. sum)
  local cost, got = M.Walk(flat, 0, 3)
  check(got == 3 and near(cost, 50, 0.5), "walk 3 units costs 10+20+20, got " .. cost)
  local cost2, got2 = M.Walk(flat, 3, 5)
  check(got2 == 5 and near(cost2, 150, 0.5), "walk the next 5 costs 5x30, got " .. cost2)
  local _, got3 = M.Walk(flat, 0, 1000)
  check(got3 == 108, "walk stops at the supply")
  check(M.QtyBelow(flat, 30) == 3, "three units are below 30")
  -- A long ladder is shortened without losing a real jump in price.
  local long = {}
  for i = 0, 59 do long[#long + 1] = { 1000 + i, 2 } end        -- 120 units a copper apart
  for i = 0, 59 do long[#long + 1] = { 5000 + i * 3, 1 } end    -- then a jump to 50s
  local short, sum2, blur = M.Compress(long)
  check(#short / 2 <= 28 and sum2 == 180 and blur and blur > 0, "a ladder of 120 price levels is shortened: " .. #short / 2)
  check(M.QtyBelow(short, 2000) == 120, "all 120 cheap units stay below the jump")
  local c120 = M.Walk(short, 0, 120)
  check(near(c120, 120 * 1029.5, 120 * 1029.5 * 0.001), "and their total cost is kept")
  local nextPrice
  for i = 1, #short, 2 do if short[i] >= 2000 then nextPrice = short[i] break end end
  check(nextPrice and nextPrice >= 5000 and nextPrice * (1 - blur) <= 5000 + 1,
    "the first level above the jump, less the tolerance, does not overstate the cheapest dear listing")
end

------------------------------------------------------------------------------
-- Price model
------------------------------------------------------------------------------
do
  local pts = {}
  for d = 10, 0, -1 do
    if d ~= 5 and d ~= 6 and d ~= 4 then pts[#pts + 1] = { now - d * 86400, 100 } end
  end
  local model = S.Fit(pts, now)
  local m0, s0 = S.Eval(model, 0)
  local mGap, sGap = S.Eval(model, -5)
  local mFut, sFut = S.Eval(model, 3)
  check(near(math.exp(m0), 100, 0.5), "flat series estimates 100, got " .. math.exp(m0))
  check(sGap > s0 * 1.08, "uncertainty is wider in a gap (" .. sGap .. " vs " .. s0 .. ")")
  check(sFut > s0 * 1.25, "uncertainty grows into the future (" .. sFut .. ")")
  check(near(math.exp(mGap), 100, 0.5), "gap is interpolated")
  local one = S.Fit({ { now - 3600, 250 } }, now)
  local m1, s1 = S.Eval(one, 0)
  check(near(math.exp(m1), 250, 0.1) and s1 > 0, "a single observation works")
  -- The same price seen once, a few times, or many times: more scans, more sure.
  local function sdAfter(count)
    local p = {}
    for i = count, 1, -1 do p[#p + 1] = { now - (i - 1) * 7200, 250 } end
    return select(2, S.Eval(S.Fit(p, now), 0))
  end
  local sd1, sd4, sd30 = sdAfter(1), sdAfter(4), sdAfter(30)
  check(sd1 > 0.2 and sd1 > sd4 * 1.6 and sd4 > sd30 * 1.6,
    string.format("one scan is much less sure than many (%.2f, %.2f, %.2f)", sd1, sd4, sd30))
  local rising = S.Fit({ { now - 4 * 86400, 100 }, { now - 2 * 86400, 150 }, { now, 225 } }, now)
  local mid = math.exp((S.Eval(rising, -3)))
  check(mid > 100 and mid < 150, "interpolates between observations, got " .. mid)
end

------------------------------------------------------------------------------
-- Planner, with a small hand-checkable market.
-- Items: 2770 Copper Ore, 2840 Copper Bar, 3576 Tin Bar, 2841 Bronze Bar.
-- Smelt Copper: 1 ore -> 1 bar. Smelt Bronze: 1 copper bar + 1 tin bar -> 2 bronze.
------------------------------------------------------------------------------
do
  check(O.IsCraftable(2841) and O.IsCraftable(2840) and not O.IsCraftable(2770), "recipe index")
  M.Record(2770, { { 10, 5 }, { 20, 5 }, { 100, 50 } }, { full = true })   -- ore
  M.Record(2840, { { 15, 4 }, { 60, 100 } }, { full = true })              -- copper bar
  M.Record(3576, { { 30, 1000 } }, { full = true })                        -- tin bar
  M.Record(2841, { { 80, 20 } }, { full = true })                          -- bronze bar

  -- One copper bar: smelting ore (10) beats buying (15).
  check(near(O.UnitCost(2840), 10), "cheapest copper bar is smelted, got " .. tostring(O.UnitCost(2840)))

  -- 2 bronze = 1 cast = 1 copper bar (10 via ore) + 1 tin (30) = 40.
  local p = O.Plan(2841, 2)
  check(near(p.cost, 40), "2 bronze cost 40, got " .. p.cost)
  check(p.produced == 2 and p.complete, "2 bronze produced")

  -- 20 bronze = 10 casts: needs 10 copper bars + 10 tin (300).
  -- Copper bars, cheapest sources: 5 ore at 10, then bars at 15 (4 of them),
  -- then ore at 20. Best: 5x10 + 4x15 + 1x20 = 130. Total 430.
  local p20 = O.Plan(2841, 20)
  check(near(p20.cost, 430), "20 bronze cost 430 mixing ore and bars, got " .. p20.cost)
  check(p20.buy[2840] == 4, "buys the 4 cheap copper bars, got " .. tostring(p20.buy[2840]))
  check(p20.buy[2770] == 6, "smelts 6 ore, got " .. tostring(p20.buy[2770]))

  -- Yield: 1 bronze still takes a whole cast and makes 2.
  local p1 = O.Plan(2841, 1)
  check(p1.produced == 2 and near(p1.cost, 40), "1 bronze makes 2, got " .. p1.produced)

  local e = O.Evaluate(2841, 20)
  check(near(e.revenue, 20 * 80 * 0.95), "revenue after the cut, got " .. tostring(e.revenue))
  check(near(e.profit, 1520 - 430), "profit, got " .. tostring(e.profit))
  check(e.sd > 0, "profit has an error margin")

  -- Vendor: thread from a vendor should be used when cheaper than auction.
  ns.db.vendor[2320] = 10
  M.Record(2320, { { 50, 10 } }, { full = true })
  check(near(O.UnitCost(2320), 10), "vendor price wins over auction")

  -- Missing prices are reported, not silently treated as free.
  local unknown = O.Plan(2841, 2)
  check(unknown.complete, "plan with all prices is complete")
  ns.realm.items[3576] = nil
  ns.generation = ns.generation + 1
  local tinSpell = O.byProduct[3576] and O.byProduct[3576][1]
  local pm = O.Plan(2841, 2)
  if tinSpell then
    check(pm.complete == (next(pm.missing) == nil), "missing flag is consistent")
  else
    check(not pm.complete and pm.missing[3576] == 1, "missing tin is reported")
  end
  M.Record(3576, { { 30, 1000 } }, { full = true })

  -- Best quantity stops where extra units stop paying.
  local bq, be = O.BestQuantity(2841)
  check(bq >= 1 and be.profit ~= nil, "best quantity found: " .. tostring(bq))
  local worst = O.Evaluate(2841, 500)
  check(be.profit >= (O.Evaluate(2841, 1).profit or 0), "best is at least as good as one")
  check(next(worst.plan.short) ~= nil, "making far too many reports a shortage")
  check(next(be.plan.short) == nil, "the best quantity never needs more than is listed")
  check(bq <= 20, "with demand unknown the best quantity stays within one stack, got " .. bq)
end

------------------------------------------------------------------------------
-- Turnover from two scans
------------------------------------------------------------------------------
do
  local t0 = now - 86400
  M.Record(2589, { { 10, 100 }, { 20, 100 } }, { full = true, t = t0 })   -- linen
  M.Record(2589, { { 20, 80 } }, { full = true, t = now })
  local info = M.Info(2589)
  check(info.turnover and near(info.turnover, 100, 1), "100 cheap units went in a day, got " .. tostring(info.turnover))
  local series = M.Series(2589)
  check(#series == 2, "two history points")
end

------------------------------------------------------------------------------
-- History is kept for good: a year of scans, six a day, loses no day.
------------------------------------------------------------------------------
do
  local id = 2592
  for step = 365 * 6, 0, -1 do
    local t = now - step * 14400
    local raw = { { 100 + (step % 7), 10 } }
    if step % 50 == 3 then raw = {} end       -- now and then nothing is listed
    M.Record(id, raw, { full = true, t = t })
  end
  local series = M.Series(id)
  local days = {}
  for _, pt in ipairs(series) do days[math.floor((now - pt[1]) / 86400)] = true end
  local missing = 0
  for d = 0, 364 do if not days[d] then missing = missing + 1 end end
  check(missing == 0, "every one of 365 days still has a price point (" .. missing .. " missing)")
  check(series[1][1] <= now - 364 * 86400, "the oldest point is a year old")
  local rec = M.Get(id)
  local points = #M.History(rec) / 4
  check(points < 900, "history stays compact: " .. points .. " points for a year")
  check(rec.hp and #rec.h / 4 <= 60, "only the last days stay unpacked: " .. #rec.h / 4 .. " points")
  check(#rec.hp < 20 * points, "the packed part is small: " .. #rec.hp .. " bytes for " .. points .. " points")
  local again = M.Unpack(M.Pack(M.History(rec)))
  local same = #again == #M.History(rec)
  for i = 1, #again do if again[i] ~= M.History(rec)[i] then same = false end end
  check(same, "packing and unpacking gives back the same history")
  -- Hourly detail survives three weeks: needed to learn hours of the day.
  do
    local hid = 2593
    ns.realm.items[hid] = nil
    for step = 30 * 24, 0, -1 do
      M.Record(hid, { { 200 + (step % 24), 10 + step } }, { full = true, t = now - step * 3600 })
    end
    local hours = {}
    for _, pt in ipairs(M.Series(hid)) do
      local age = now - pt[1]
      if age < 20 * 86400 then hours[math.floor(age / 3600)] = true end
    end
    local kept = 0
    for _ in pairs(hours) do kept = kept + 1 end
    check(kept >= 20 * 24 - 2, "twenty days of hourly scans keep every hour: " .. kept)
    local total = #M.History(M.Get(hid)) / 4
    check(total < 600, "older than three weeks is thinned to six-hourly: " .. total .. " points in all")
  end
  -- A price that does not move is kept as the ends of the run.
  do
    local sid = 2594
    ns.realm.items[sid] = nil
    for step = 40, 0, -1 do
      M.Record(sid, { { 500, 100 } }, { full = true, t = now - step * 1800 })
    end
    local n = #M.History(M.Get(sid)) / 4
    local series = M.Series(sid)
    check(n == 2, "forty unchanged scans are kept as two points: " .. n)
    check(series[1][1] == now - 40 * 1800 and series[#series][1] == now, "the run's first and last moments are exact")
    M.Record(sid, { { 510, 100 } }, { full = true, t = now + 1800 })
    check(#M.History(M.Get(sid)) / 4 == 3, "a change adds a point")
    ns.realm.items[sid] = nil
  end
  local recent = 0
  for _, pt in ipairs(series) do if now - pt[1] < 6 * 86400 then recent = recent + 1 end end
  check(recent >= 30, "the last week keeps every scan: " .. recent)
  ns.settings.chartDays = 0
  ns.Open(id)
  ns.settings.chartDays = 14
end

------------------------------------------------------------------------------
-- Capture through the game's events
------------------------------------------------------------------------------
do
  listings[2835] = { { 7, 20 }, { 9, 40 } }
  FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2835)
  local info = M.Info(2835)
  check(info and info.price == 7 and info.total == 60, "commodity results recorded")
  RunTimers()

  FireEvent("AUCTION_HOUSE_SHOW")
  check(M.ahOpen, "auction house open state")
  sentQueries = {}
  M.ScanItems({ 2835, 2836 })
  check(sentQueries[1] == 2835, "scan sends the first query")
  FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2835)
  RunTimers()
  check(sentQueries[2] == 2836, "scan moves on to the next item")
  listings[2836] = {}
  FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2836)
  RunTimers()
  check(not M.IsScanning(), "scan finishes")
  local none = M.Info(2836)
  check(none and none.price == nil and none.total == 0, "an empty result is recorded as none listed")

  -- Browse summaries
  C_AuctionHouse.GetBrowseResults = function()
    return { { itemKey = { itemID = 2318, itemSuffix = 0, battlePetSpeciesID = 0 }, minPrice = 44, totalQuantity = 300 } }
  end
  FireEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  RunTimers()
  local s = M.Info(2318)
  check(s and s.price == 44 and s.summary, "browse summary recorded")

  -- Full scan
  local rep = { { 2770, 3, 90 }, { 2770, 1, 12 }, { 999999, 1, 5 } }
  C_AuctionHouse.GetNumReplicateItems = function() return #rep end
  C_AuctionHouse.GetReplicateItemInfo = function(i)
    local r = rep[i + 1]
    return "n", 1, r[2], 1, true, 1, "", 0, 0, r[3], 0, nil, nil, nil, nil, 0, r[1], true
  end
  FireEvent("REPLICATE_ITEM_LIST_UPDATE")
  RunTimers()
  local ore = M.Info(2770)
  check(ore.price == 12 and ore.total == 4, "full scan recorded ore at 12 x1 and 30 x3, got "
    .. tostring(ore.price) .. " / " .. tostring(ore.total))
  local gone = M.Info(2841)
  check(gone.price == nil and gone.lastPrice == 80, "full scan marks unlisted items, keeps last price")
  FireEvent("AUCTION_HOUSE_CLOSED")

  -- Merchant
  GetMerchantNumItems = function() return 2 end
  GetMerchantItemID = function(i) return i == 1 and 2880 or 4289 end
  C_MerchantFrame = { GetItemInfo = function(i)
    if i == 1 then return { price = 500, stackCount = 5, numAvailable = -1, hasExtendedCost = false } end
    return { price = 50, stackCount = 1, numAvailable = 3, hasExtendedCost = false }
  end }
  FireEvent("MERCHANT_SHOW")
  check(ns.db.vendor[2880] == 100, "vendor price learned per unit")
  check(ns.db.vendor[4289] == nil, "limited stock is not treated as a supply")
end

------------------------------------------------------------------------------
-- Graph
------------------------------------------------------------------------------
do
  M.Record(2841, { { 80, 20 } }, { full = true })
  local g = G.Build(2841, { plan = O.Plan(2841, 20) })
  check(g.byId[2841].col == 0, "centre in the middle")
  check(g.byId[2840] and g.byId[2840].col == 1, "copper bar is one step right")
  check(g.byId[2770] and g.byId[2770].col == 2, "copper ore is two steps right")
  local left = 0
  for _, n in ipairs(g.nodes) do
    if n.side == -1 and n.id then left = left + 1 end
    check(n.x ~= nil and n.y ~= nil, "every node is placed")
  end
  check(left > 0, "bronze bar has things made from it: " .. left)
  local seen = {}
  for _, n in ipairs(g.nodes) do
    if n.id then
      check(not seen[n.id], "item appears once: " .. n.id)
      seen[n.id] = true
    end
  end
  for _, e in ipairs(g.edges) do
    check(g.byId[e.from].x < g.byId[e.to].x, "edges run left to right")
  end
  -- Positions in a column do not collide.
  local spots = {}
  for _, n in ipairs(g.nodes) do
    local key = n.x .. ":" .. n.y
    check(not spots[key], "no two nodes share a spot")
    spots[key] = true
  end
  -- Every craftable item can be laid out without error, with every node placed.
  local built, unplaced = 0, 0
  for id in pairs(O.byProduct) do
    local g2 = G.Build(id, { plan = O.Plan(id, 1) })
    for _, n in ipairs(g2.nodes) do
      if not n.x or not n.y then unplaced = unplaced + 1 end
    end
    built = built + 1
  end
  check(unplaced == 0, "no node is left unplaced in any graph (" .. unplaced .. ")")
  check(built > 1000, "built a graph for every craftable item: " .. built)
end

------------------------------------------------------------------------------
-- Window code paths
------------------------------------------------------------------------------
do
  local before = #ns.db.log
  ns.Open(2841)
  check(CraftGraphFrame and CraftGraphFrame:IsShown(), "window opens")
  ns.UI.Focus(2840)
  ns.UI.Focus(2770)
  ns.UI.Back()
  ns.UI.ToggleExpandLeft()
  ns.UI.SetQuantity(50)
  ns.settings.certainty = false
  ns.UI.Refresh()
  ns.settings.certainty = true
  ns.UI.Focus(999999)          -- an item the data file does not know
  ns.UI.Focus(2589)
  SlashCmdList["CRAFTGRAPH"]("bronze bar")
  SlashCmdList["CRAFTGRAPH"]("item:2840")
  SlashCmdList["CRAFTGRAPH"]("")
  SlashCmdList["CRAFTGRAPH"]("")
  check(ns.UI.FindByName("copper bar") == 2840, "search finds copper bar")
  check(#ns.UI.Search("bar", 12) > 3, "search lists several bars")
  FireEvent("AUCTION_HOUSE_SHOW")
  FireEvent("ADDON_LOADED", "Blizzard_AuctionHouseUI")
  -- Exercise every node button's handlers.
  for _, f in ipairs(frames) do
    if f.node and f.scripts.OnEnter then
      f.scripts.OnEnter(f)
      f.scripts.OnLeave(f)
    end
  end
  RunTimers()
  local errors = 0
  for i = before + 1, #ns.db.log do
    if ns.db.log[i]:find("ERROR") then
      errors = errors + 1
      print(ns.db.log[i])
    end
  end
  check(errors == 0, "no errors logged while using the window")
end

------------------------------------------------------------------------------
-- Whole-market stress: every item priced at random, every craftable planned.
------------------------------------------------------------------------------
do
  math.randomseed(7)
  for id, d in pairs(ns.Data.items) do
    local base = math.max(5, d[3] * (2 + math.random() * 6))
    local raw = {}
    for i = 1, 40 do raw[i] = { base * (1 + i * 0.03), math.random(1, 20) } end
    M.Record(id, raw, { full = true })
  end
  local planned, bad = 0, 0
  for id in pairs(O.byProduct) do
    local p1, p50 = O.Plan(id, 1), O.Plan(id, 50)
    planned = planned + 1
    if not (p1.complete and p50.complete and p1.cost > 0 and p50.cost >= p1.cost
      and p1.produced >= 1 and p50.produced >= 50) then
      bad = bad + 1
    end
    -- Crafting is never dearer than buying every direct reagent at auction.
    local spell = O.BestRecipe(id)
    local r = O.Recipe(spell)
    local direct = 0
    for i = 1, #r[7], 2 do
      direct = direct + M.Walk(M.Info(r[7][i]).ladder, 0, r[7][i + 1])
    end
    if p1.cost > direct + 1e-6 then bad = bad + 1 end
    for _, n in pairs(p50.buy) do if n <= 0 then bad = bad + 1 end end
    for _, n in ipairs(G.Build(id, { plan = p50, expandLeft = true }).nodes) do
      if not n.x or not n.y then bad = bad + 1 end
    end
    O.BestQuantity(id)
  end
  check(bad == 0, "all " .. planned .. " craftable items plan sensibly (" .. bad .. " bad)")
  ns.UI.Focus(14341)
  RunTimers()
  local errors = 0
  for _, line in ipairs(ns.db.log) do
    if line:find("ERROR") then errors = errors + 1; print(line) end
  end
  check(errors == 0, "no errors logged in the stress run")
end

------------------------------------------------------------------------------
-- Worth crafting: professions, known recipes, ranking.
------------------------------------------------------------------------------
do
  local P = ns.Player
  -- A miner at 80 and a blacksmith at 100 who knows three recipes.
  GetProfessions = function() return 1, 2, nil, nil, nil, nil end
  GetProfessionInfo = function(i)
    if i == 1 then return "Mining", 0, 80, 150, 0, 0, 186, 0, 0, 0, "Mining" end
    return "Blacksmithing", 0, 100, 150, 0, 0, 164, 0, 0, 0, "Blacksmithing"
  end
  local learned = { [2657] = true, [2659] = true, [2665] = true }
  C_TradeSkillUI = {
    GetRecipeInfo = function(id) return { learned = learned[id] or false } end,
    GetAllRecipeIDs = function() return { 2657, 2659, 2665, 2672 } end,
  }
  UnitName = function() return "Tester" end
  P.version = P.version + 1
  local skills = P.Skills()
  check(skills[186] == 80 and skills[164] == 100, "profession levels are read")
  check(P.Knows(2659) and not P.Knows(2672), "known recipes are told apart")
  local list, info = P.Worth()
  check(info.considered == 3, "only the three known recipes are considered, got " .. info.considered)
  local ok = true
  for i, row in ipairs(list) do
    if row.each <= 0 or not learned[row.spell] then ok = false end
    if i > 1 and list[i - 1].sure == row.sure and list[i - 1].safe < row.safe then ok = false end
    if i > 1 and row.sure and not list[i - 1].sure then ok = false end
  end
  check(ok, "the list holds only known, profitable recipes, surest earners first")
  -- A lone listing is not trusted as a sale price.
  M.Record(2863, { { 990000, 1 } }, { full = true })
  M.Record(2836, { { 10, 500 } }, { full = true })
  P.version = P.version + 1
  local lone
  for _, row in ipairs((P.Worth())) do if row.id == 2863 then lone = row end end
  check(lone and lone.thin and not lone.sure and lone.qty == 1, "a single listing is flagged thin and kept to one")
  check(#list + info.losing + info.unpriced == info.considered, "every recipe is accounted for")

  -- The profession window teaches it a new recipe.
  learned[2672] = true
  FireEvent("TRADE_SKILL_LIST_UPDATE")
  check(P.Knows(2672), "a recipe seen in the profession window is remembered")
  check(ns.db.chars["Tester - TestRealm"].known[2672], "known recipes are saved per character")

  -- A profession nothing could be read from falls back to skill level.
  C_TradeSkillUI.GetRecipeInfo = function() return nil end
  ns.db.chars["Tester - TestRealm"].known = {}
  P.version = P.version + 1
  local list2, info2 = P.Worth()
  check(info2.unverified[164] and info2.unverified[186], "unread professions are flagged")
  local allGuess, tooHard = true, false
  for _, row in ipairs(list2) do
    if not row.guess then allGuess = false end
    local r = O.Recipe(row.spell)
    if r[2] > 1 and r[2] > row.rank then tooHard = true end
  end
  check(#list2 > 0 and allGuess and not tooHard, "the fallback goes by skill level and marks its rows")
  local r, g, b = P.Difficulty(50, 65, 115)
  check(r == 1 and g == 0.5, "below yellow is orange")
  check(select(1, P.Difficulty(120, 65, 115)) == 0.5, "past grey is grey")

  C_TradeSkillUI.GetRecipeInfo = function(id) return { learned = learned[id] or false } end
  P.version = P.version + 1

  -- Crafting: materials in bags, window closed, then open.
  local bags = { [2840] = 7, [3576] = 3 }          -- copper bars, tin bars
  C_Item.GetItemCount = function(id) return bags[id] or 0 end
  check(P.CanMake(2659) == 3, "bags allow three casts of Smelt Bronze, got " .. P.CanMake(2659))
  check(P.CanMake(2657) == 0, "no ore, no Smelt Copper")
  local crafted, openedLine, ready
  C_TradeSkillUI.IsTradeSkillReady = function() return ready end
  C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 186, professionName = "Mining" } end
  C_TradeSkillUI.OpenTradeSkill = function(line) openedLine = line; return true end
  C_TradeSkillUI.CraftRecipe = function(spell, casts) crafted = { spell, casts } end
  C_TradeSkillUI.OpenRecipe = function() end
  check(P.Craft(2659, 10) == false and openedLine == 186 and not crafted, "first press opens the profession window")
  ready = true
  check(P.Craft(2659, 10) == true and crafted[1] == 2659 and crafted[2] == 3, "second press crafts what the bags allow")
  FireEvent("UNIT_SPELLCAST_START", "player", "guid", 2659)
  RunTimers()
  crafted = nil
  check(P.Craft(2657, 1) == false and not crafted, "nothing is crafted without materials")
  C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 164, professionName = "Blacksmithing" } end
  openedLine = nil
  check(P.Craft(2659, 1) == false and openedLine == 186, "the wrong profession window is switched, not crafted in")
  C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 186, professionName = "Mining" } end
  FireEvent("BAG_UPDATE_DELAYED")
  RunTimers()

  SlashCmdList["CRAFTGRAPH"]("worth")
  RunTimers()
  local shown = 0
  for _, f in ipairs(frames) do
    if f.data and f.shown and f.scripts.OnEnter then
      shown = shown + 1
      f.scripts.OnEnter(f)
      f.scripts.OnLeave(f)
    end
  end
  check(shown > 0, "the worth-crafting list shows rows: " .. shown)
  for _, f in ipairs(frames) do
    if f.data and f.shown and f.scripts.OnClick then
      f.scripts.OnClick(f)
      break
    end
  end
  check(CraftGraphFrame:IsShown(), "clicking a row goes to the graph")
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1; print(line) end end
  check(errors == 0, "no errors in the worth-crafting list")
end

------------------------------------------------------------------------------
-- Jobs: pin, buy at auction, mailbox, vendor, craft, post.
------------------------------------------------------------------------------
do
  local J, P = ns.Jobs, ns.Player
  local bags = {}
  C_Item.GetItemCount = function(id) return bags[id] or 0 end
  local function price(id, ladder, kind)
    M.Record(id, ladder, { full = true })
    M.Get(id).k = kind or "c"
  end
  price(2770, { { 10, 5 }, { 20, 5 }, { 100, 50 } })       -- copper ore
  price(2840, { { 15, 4 }, { 60, 100 } })                  -- copper bar
  price(3576, { { 30, 1000 } })                            -- tin bar
  price(2841, { { 80, 20 } })                              -- bronze bar
  price(2771, { { 500, 10 } })                             -- tin ore: dearer than bars
  check(J.Pin(2841, 20), "an item can be pinned")
  check(J.IsPinned(2841) == 1 and #J.Pins() == 1, "the pin is stored")
  local job = J.All()[1]
  check(job.kind == "ah" and job.remaining == 20, "the first step is buying at auction: " .. job.text)
  check(job.needs.ah[2840] == 4 and job.needs.ah[2770] == 6 and job.needs.ah[3576] == 10,
    "the shopping list matches the plan (4 bars, 6 ore, 10 tin)")

  -- Buying 10 tin bars: quoted within the plan's price, so it goes through.
  local started, confirmed, cancelled = nil, nil, 0
  C_AuctionHouse.StartCommoditiesPurchase = function(id, qty) started = { id, qty } end
  C_AuctionHouse.ConfirmCommoditiesPurchase = function(id, qty) confirmed = { id, qty } end
  C_AuctionHouse.CancelCommoditiesPurchase = function() cancelled = cancelled + 1 end
  GetMoney = function() return 1000000 end
  FireEvent("AUCTION_HOUSE_CLOSED")
  check(J.BuyAuction(3576, 10) == false, "buying needs the auction house open")
  FireEvent("AUCTION_HOUSE_SHOW")
  check(J.BuyAuction(3576, 10) == true and started[1] == 3576 and started[2] == 10, "a purchase is started")
  check(J.BuyAuction(2770, 6) == false, "only one purchase runs at a time")
  FireEvent("COMMODITY_PRICE_UPDATED", 30, 300)
  check(confirmed and confirmed[2] == 10, "a quote within the plan is confirmed")
  FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
  check(ns.db.chars["Tester - TestRealm"].ordered[3576] == 10, "the purchase is noted as waiting in the mailbox")
  RunTimers()

  -- Buying ore: the price has jumped, so nothing is bought.
  started, confirmed = nil, nil
  J.BuyAuction(2770, 6)
  FireEvent("COMMODITY_PRICE_UPDATED", 90, 540)        -- the plan expected 5x10 + 1x20 = 70
  check(confirmed == nil and cancelled >= 1, "a quote above the plan is cancelled, not paid")
  check(not J.Busy(), "the failed purchase is cleared")
  RunTimers()
  price(2770, { { 10, 5 }, { 20, 5 }, { 100, 50 } })
  price(2840, { { 15, 4 }, { 60, 100 } })
  J.BuyAuction(2770, 6); FireEvent("COMMODITY_PRICE_UPDATED", 12, 70); FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
  J.BuyAuction(2840, 4); FireEvent("COMMODITY_PRICE_UPDATED", 15, 60); FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
  RunTimers()
  job = J.All()[1]
  check(job.kind == "mail", "with everything bought the next step is the mailbox: " .. job.text)

  -- An old price is looked up again instead of trusted.
  local old = M.Get(2771)
  old.lt = now - 3600
  started = nil
  check(J.BuyAuction(2771, 1) == false and started == nil, "a stale price is refreshed, not bought on")
  RunTimers()

  -- The mail is collected.
  FireEvent("AUCTION_HOUSE_CLOSED")
  bags[3576], bags[2770], bags[2840] = 10, 6, 4
  FireEvent("BAG_UPDATE_DELAYED")
  RunTimers()
  check(next(ns.db.chars["Tester - TestRealm"].ordered) == nil, "collected mail clears the waiting count")
  job = J.All()[1]
  check(job.kind == "craft" and next(job.needs.ah) == nil, "then it is time to craft: " .. job.text)
  check(job.needs.crafts[1].spell == 2657 and job.needs.crafts[1].casts == 6
    and job.needs.crafts[2].spell == 2659 and job.needs.crafts[2].casts == 10,
    "crafts come in order: smelt copper x6, then bronze x10")

  -- Crafted: 20 bronze bars in the bags, time to post.
  bags = { [2841] = 20 }
  job = J.All()[1]
  check(job.kind == "sell", "with the goods made the next step is posting: " .. job.text)
  C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
    GetContainerItemID = function(bag, slot) return slot == 2 and 2841 or nil end,
  }
  ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
  local posted
  C_AuctionHouse.GetItemCommodityStatus = function() return 2 end
  C_AuctionHouse.GetAvailablePostCount = function() return 20 end
  C_AuctionHouse.PostCommodity = function(loc, duration, qty, unit) posted = { qty, unit, duration } return false end
  FireEvent("AUCTION_HOUSE_SHOW")
  price(2841, { { 80, 20 } })
  check(J.SellAuction(2841) == true and posted[1] == 20 and posted[2] == 79 and posted[3] == 3,
    "all 20 are posted one copper under the cheapest, for the longest time")
  FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 555)
  check(J.Pins()[1].posted == 20, "the post is counted on the pin")
  bags = {}
  job = J.All()[1]
  check(job.kind == "done", "the job is done: " .. job.text)

  -- Never post below cost.
  bags = { [2841] = 5 }
  price(2841, { { 18, 20 } })
  posted = nil
  check(J.SellAuction(2841) == false and posted == nil, "nothing is posted below what it costs to make")
  check(J.PostPrice(2841) == nil, "and no Sell button is offered then")
  price(2841, { { 12345, 20 } })
  check(J.PostPrice(2841, false) == 12300, "separate auctions are priced in whole silver")
  price(2841, { { 80, 20 } })
  check(J.PostPrice(2841, false) == nil, "and not offered under one silver")

  -- Separate auctions: one click buys the cheapest listing within the plan.
  local bid
  C_AuctionHouse.PlaceBid = function(auctionID, amount) bid = { auctionID, amount } end
  price(2318, { { 100, 1 }, { 120, 1 }, { 900, 1 } }, "i")
  M.itemResults[2318] = { t = GetTime(), list = {
    { auctionID = 71, buyout = 100, qty = 1 }, { auctionID = 72, buyout = 120, qty = 1 } } }
  check(J.BuyAuction(2318, 2) == true and bid[1] == 71 and bid[2] == 100, "the cheapest single auction is bought")
  FireEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 71)
  check(ns.db.chars["Tester - TestRealm"].ordered[2318] == 1, "and counted as waiting in the mailbox")
  RunTimers()
  FireEvent("AUCTION_HOUSE_CLOSED")
  J.Unpin(2841)

  -- Vendor: a recipe that needs Coarse Thread.
  local threadSpell
  for _, sp in ipairs(O.uses[2320]) do
    if not threadSpell or sp < threadSpell then threadSpell = sp end
  end
  local r = O.Recipe(threadSpell)
  for i = 1, #r[7], 2 do
    if r[7][i] ~= 2320 then price(r[7][i], { { 50, 500 } }) end
  end
  price(r[3], { { 5000, 30 } })
  ns.db.vendor[2320] = 10
  ns.db.chars["Tester - TestRealm"].ordered = {}
  bags = {}
  for i = 1, #r[7], 2 do
    if r[7][i] ~= 2320 then bags[r[7][i]] = 1000 end
  end
  J.Pin(r[3], 3)
  local threadNeed
  for i = 1, #r[7], 2 do if r[7][i] == 2320 then threadNeed = r[7][i + 1] * math.ceil(3 / r[4]) end end
  job = J.All()[1]
  check(job.kind == "vendor" and job.needs.vendor[2320] == threadNeed, "the missing thread comes from a vendor: " .. job.text)
  local bought = {}
  GetMerchantNumItems = function() return 2 end
  GetMerchantItemID = function(i) return i == 1 and 4289 or 2320 end
  GetMerchantItemMaxStack = function() return 20 end
  C_MerchantFrame.GetItemInfo = function(i)
    return { price = 10, stackCount = 1, numAvailable = -1, hasExtendedCost = false }
  end
  BuyMerchantItem = function(index, qty) bought[#bought + 1] = { index, qty } end
  FireEvent("MERCHANT_SHOW")
  local offer, total = J.MerchantOffer()
  check(#offer == 1 and offer[1].id == 2320 and total == threadNeed * 10, "this vendor's offer is the thread, priced")
  check(J.BuyFromMerchant() == true, "buy all goes through")
  local units = 0
  for _, b in ipairs(bought) do
    if b[1] == 2 then units = units + b[2] end
  end
  check(units == threadNeed, "exactly the needed thread is bought, got " .. units)
  RunTimers()

  -- The tracker and the graph buttons.
  ns.UI.UpdateHUD()
  check(CraftGraphHUD and CraftGraphHUD:IsShown(), "the tracker shows while something is pinned")
  local hudRow
  for _, f in ipairs(frames) do if f.job and f.shown then hudRow = f end end
  check(hudRow ~= nil, "the tracker has a row for the pin")
  hudRow.scripts.OnEnter(hudRow)
  hudRow.scripts.OnClick(hudRow, "LeftButton")
  check(ns.settings.lastItem == r[3] and ns.settings.qty == 3, "clicking it opens that item's graph at its quantity")
  local acts = ns.UI.NodeActions({ id = 2320 })
  check(acts[2] and acts[2].text == "Buy " .. threadNeed and acts[2].enabled and acts[2].glow,
    "the graph lights up buying the thread at this vendor")
  check(acts[1] and not acts[1].enabled and acts[1].tip:find("vendor"),
    "and greys the auction button, saying a vendor is cheaper")
  FireEvent("MERCHANT_CLOSED")
  ns.UI.Refresh()
  acts = ns.UI.NodeActions({ id = 2320 })
  check(acts[2] and not acts[2].enabled and acts[2].tip:find("Visit"), "away from the vendor it is greyed with the reason")
  ns.db.chars["Tester - TestRealm"].known[threadSpell] = true
  P.version = P.version + 1
  ns.UI.Refresh()
  local centre = ns.UI.NodeActions({ id = r[3] })
  check(centre[1] and centre[1].text == "Sell" and not centre[1].enabled, "nothing to sell yet, so Sell is greyed")
  check(centre[3] and not centre[3].enabled and centre[3].tip:find("materials"), "Make is greyed until the thread is bought")
  bags[2320] = threadNeed
  ns.UI.Refresh()
  centre = ns.UI.NodeActions({ id = r[3] })
  check(centre[3] and centre[3].enabled and centre[3].glow, "with everything in the bags Make lights up")
  check(ns.UI.NodeActions({ id = r[3], side = -1 })[1] == nil, "items on the used-in side carry no buttons")
  bags[2320] = nil
  ns.UI.Refresh()
  hudRow.scripts.OnClick(hudRow, "RightButton")
  RunTimers()
  check(#J.Pins() == 0 and not CraftGraphHUD:IsShown(), "right-click unpins and the empty tracker hides")
  for i = 1, 5 do J.Pin(2000 + i, 1) end
  check(J.Pin(2840, 1) == false, "no more than five pins")
  for i = 1, 5 do J.Unpin(2000 + i) end
  C_Item.GetItemCount = function() return 0 end
  RunTimers()
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1; print(line) end end
  check(errors == 0, "no errors in the job flow")
end

------------------------------------------------------------------------------
-- Sell bags: what is worth listing, and posting it one click at a time.
------------------------------------------------------------------------------
do
  local J = ns.Jobs
  local function price(id, ladder) M.Record(id, ladder, { full = true }) M.Get(id).k = "c" end
  -- Bags: 20 bronze bars, 10 copper ore, 5 of a bound item, 3 linen (vendor is better), 1 unknown item.
  local slots = {
    { itemID = 2841, stackCount = 20 }, { itemID = 2770, stackCount = 10 },
    { itemID = 2589, stackCount = 3 }, { itemID = 2318, stackCount = 5, isBound = true },
    { itemID = 987654, stackCount = 1 },
  }
  C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and #slots or 0 end,
    GetContainerItemInfo = function(bag, slot) return slots[slot] end,
    GetContainerItemID = function(bag, slot) return slots[slot] and slots[slot].itemID end,
  }
  C_Item.GetItemInfo = function() return "x", nil, 1, 1, 1, "", "", 1, "", 1, 0 end
  price(2841, { { 80, 50 } })
  price(2770, { { 12, 300 } })
  price(2589, { { 1, 900 } })            -- linen at 1 copper: a vendor pays more
  local rows, sum = J.BagSales()
  check(#rows == 2 and rows[1].id == 2841 and rows[2].id == 2770, "bars and ore are worth listing, best first")
  check(near(rows[1].net, 20 * 80 * 0.95) and rows[1].gain > 0, "proceeds are after the cut and beat the vendor")
  check(sum.count == 2 and near(sum.total, 1520 + 114) and sum.sd > 0, "the total has a margin")
  check(sum.vendorItems == 1 and sum.unknown == 1, "vendor fodder and unpriced items are counted, bound ones ignored")

  -- A pin that needs copper ore keeps it out of the sale.
  price(2840, { { 60, 100 } })
  price(3576, { { 30, 1000 } })
  J.Pin(2841, 10)
  rows, sum = J.BagSales()
  local ore
  for _, d in ipairs(rows) do if d.id == 2770 then ore = d end end
  check(ore and ore.reserved and sum.count == 1, "materials for a pinned item are kept back")
  J.Unpin(2841)

  -- Posting from the list: below cost is allowed here, below vendor is not.
  local posts = {}
  C_AuctionHouse.GetItemCommodityStatus = function() return 2 end
  C_AuctionHouse.GetAvailablePostCount = function(loc) return slots[loc.slot].stackCount end
  C_AuctionHouse.PostCommodity = function(loc, duration, qty, unit) posts[#posts + 1] = { slots[loc.slot].itemID, qty, unit } return false end
  FireEvent("AUCTION_HOUSE_SHOW")
  price(2841, { { 25, 50 } })            -- below what bronze costs to make, above vendor (50c? no: 50)
  check(J.PostPrice(2841, true) == nil and J.PostPrice(2841, true, true) == nil, "at or under vendor price nothing is offered")
  price(2841, { { 70, 50 } })
  price(3576, { { 300, 1000 } })         -- tin got dear: bronze now costs more than 70 to make
  check(J.PostPrice(2841, true) == nil, "a crafter would not post at a loss")
  check(J.PostPrice(2841, true, true) == 69, "but stock already in the bags may still be sold")
  ns.UI.OpenSell()
  RunTimers()
  local list
  for _, f in ipairs(frames) do if f.rows and f.next then list = f end end
  check(list and list:IsShown() and list.next.row and list.next.row.id == 2841, "the sell list is up with a next item")
  list.next.scripts.OnClick(list.next)
  check(#posts == 1 and posts[1][1] == 2841 and posts[1][2] == 20 and posts[1][3] == 69, "Sell next posts the whole stack of the first item")
  FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 1)
  table.remove(slots, 1)
  RunTimers()
  ns.UI.UpdateSell()
  check(list.next.row and list.next.row.id == 2770, "then it moves on to the next item")
  list.next.scripts.OnClick(list.next)
  check(#posts == 2 and posts[2][1] == 2770 and posts[2][3] == 11, "and posts that one under the cheapest")
  FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 2)
  table.remove(slots, 1)
  RunTimers()
  ns.UI.UpdateSell()
  check(list.next.row == nil, "until nothing is left")
  ns.UI.Back()
  check(not list:IsShown(), "back leaves the sell list")
  FireEvent("AUCTION_HOUSE_CLOSED")
  price(3576, { { 30, 1000 } })
  price(2841, { { 80, 20 } })
  C_Container.GetContainerNumSlots = function() return 0 end
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1; print(line) end end
  check(errors == 0, "no errors in the sell list")
end

------------------------------------------------------------------------------
-- Opportunities: every way to make money, with amount, outlay and steps.
------------------------------------------------------------------------------
do
  local Deals, J = ns.Deals, ns.Jobs
  local function price(id, ladder) M.Record(id, ladder, { full = true }) M.Get(id).k = "c" end
  local function find(kind, id)
    for _, d in ipairs((Deals.All())) do
      if d.kind == kind and d.id == id then return d end
    end
  end
  -- Copper bars: a vendor pays 10. Three are listed at 5.
  price(2840, { { 5, 3 }, { 60, 100 } })
  local v = find("tovendor", 2840)
  check(v and v.qty == 3 and v.outlay == 15 and v.profit == 15 and v.sd == 0 and v.sure,
    "listings under vendor price: buy 3 for 15, certain profit 15")
  check(v and #v.steps == 3, "and it lists the three steps it takes")
  -- The same ladder is also a relist: buy the 3 at 5, relist under 60.
  local f = find("flip", 2840)
  check(f and f.qty == 3 and near(f.profit, 3 * 59 * 0.95 - 15, 0.01), "the same item also shows as buy low, relist")
  check(f and f.sd > 0, "which, unlike the vendor route, carries a margin")
  -- A ladder with no gap offers no relist.
  price(2771, { { 100, 10 }, { 101, 10 }, { 102, 10 } })
  check(find("flip", 2771) == nil, "a smooth ladder is not a relist")
  -- A lone dear listing above is flagged thin, not trusted.
  price(2836, { { 10, 5 }, { 99999, 1 } })
  local t = find("flip", 2836)
  check(t and t.thin and not t.sure, "a relist against one dear listing is shown but not trusted")
  -- Thread: a vendor sells it for 10 and it is listed at 50.
  ns.db.vendor[2320] = 10
  price(2320, { { 50, 10 } })
  local fv = find("fromvendor", 2320)
  check(fv and fv.qty == 10 and near(fv.profit, 10 * (49 * 0.95 - 10), 0.01) and #fv.steps == 2,
    "vendor goods that fetch more at auction: 10, in two steps")
  -- Crafting rows come through too, with what they cost up front.
  local crafts = 0
  for _, d in ipairs((Deals.All())) do
    if d.kind == "craft" then
      crafts = crafts + 1
      check(d.outlay > 0 and d.effort >= 2, "a crafting row shows its outlay and steps")
    end
  end
  check(crafts > 0, "crafting opportunities are listed: " .. crafts)
  -- Old prices are shown but not trusted.
  M.Get(2840).lt = now - 3 * 3600
  ns.generation = ns.generation + 1
  local old = find("tovendor", 2840)
  check(old and old.stale and not old.sure, "prices over two hours old are marked, not trusted")
  price(2840, { { 5, 3 }, { 60, 100 } })
  -- Everything is ordered surest first.
  local list = (Deals.All())
  local ordered = true
  for i = 2, #list do
    if list[i].sure and not list[i - 1].sure then ordered = false end
  end
  check(ordered, "certain rows come before uncertain ones")

  -- The list on screen, its filter, sort and Buy button.
  SlashCmdList["CRAFTGRAPH"]("deals")
  RunTimers()
  local view
  for _, fr in ipairs(frames) do if fr.rows and fr.filters then view = fr end end
  check(view and view:IsShown(), "the opportunities list opens")
  view.filters.vendor.scripts.OnClick(view.filters.vendor)
  local onlyVendor, shown = true, 0
  for _, row in ipairs(view.rows) do
    if row.shown and row.data then
      shown = shown + 1
      if row.data.kind ~= "tovendor" and row.data.kind ~= "fromvendor" then onlyVendor = false end
    end
  end
  check(shown >= 2 and onlyVendor, "the Vendor filter shows only vendor routes: " .. shown)
  local started
  C_AuctionHouse.StartCommoditiesPurchase = function(id, qty) started = { id, qty } end
  local buyRow
  for _, row in ipairs(view.rows) do
    if row.shown and row.data and row.data.kind == "tovendor" then buyRow = row end
  end
  check(buyRow and buyRow.act.text == "Plan it" and buyRow.act.enabled ~= false, "away from the auction house a trade can be planned")

  -- Planning a trade: its goal, its projected profit, and how that moves.
  do
    local J, D = ns.Jobs, ns.Deals
    local d = buyRow.data
    local example = D.Example(d)
    check(example:find("sell them to a vendor", 1, true) ~= nil, "each option comes with an example: " .. example)
    buyRow.act.scripts.OnClick(buyRow.act)
    local _, pin = J.IsPinned(d.id)
    check(pin and pin.goal and pin.goal.kind == "tovendor" and pin.qty == d.qty, "Plan it puts the trade in the plan with its goal")
    local proj = J.Projection(pin.id, pin.qty, pin.goal)
    check(proj.fixed and near(proj.now, d.profit, 1), "its projected profit is the opportunity's: " .. tostring(proj.now))
    local st = J.TrackStats(pin)
    check(st and st.n == 1 and near(st.first, d.profit, 1), "the plan starts a profit history")
    check(ns.UI.GoalText(pin):find("Profit", 1, true) ~= nil, "the plan window shows the projected profit")
    -- The cheap listings get dearer: the next scan corrects the projection.
    local ladderBefore = M.Info(d.id).ladder[1]
    now = now + 300
    price(d.id, { { ladderBefore + 2, d.qty }, { ladderBefore + 30, 50 } })
    ns.Fire("MARKET_UPDATED")
    RunTimers()
    st = J.TrackStats(pin)
    check(st.n == 2 and st.last < st.first, string.format("a dearer scan lowers the projection (%d to %d)", st.first, st.last))
    check(ns.UI.GoalText(pin):find("fell", 1, true) ~= nil, "and the plan window says it fell: " .. ns.UI.GoalText(pin))
    now = now + 300
    price(d.id, { { ladderBefore + 1, d.qty }, { ladderBefore + 30, 50 } })
    ns.Fire("MARKET_UPDATED")
    RunTimers()
    st = J.TrackStats(pin)
    check(st.n == 3 and st.median and st.mean and st.low <= st.median and st.median <= st.high,
      "with three readings it has a median and an average")
    check(ns.UI.GoalText(pin):find("med", 1, true) ~= nil and ns.UI.GoalText(pin):find("avg", 1, true) ~= nil,
      "both are shown: " .. ns.UI.GoalText(pin))
    now = now + 10
    price(d.id, { { ladderBefore, d.qty }, { ladderBefore + 30, 50 } })
    ns.Fire("MARKET_UPDATED")
    RunTimers()
    check(J.TrackStats(pin).n == 3, "scans seconds apart do not flood the history")
    J.SetQty(pin.id, pin.qty + 1)
    check(J.TrackStats(pin).n == 1, "changing the amount starts the history again")
    J.Unpin(d.id)
    ns.UI.UpdateWorth()

    -- Sell-time projection for a craft.
    local craftRow
    for _, row in ipairs((D.All())) do if row.kind == "craft" then craftRow = row break end end
    check(craftRow ~= nil, "there is a craft to project")
    local cp = J.Projection(craftRow.id, craftRow.qty)
    check(cp.now and near(cp.now, craftRow.profit, math.max(2, math.abs(craftRow.profit) * 0.02)),
      "a craft's profit if sold right away matches the list: " .. tostring(cp.now) .. " vs " .. tostring(craftRow.profit))
    check(#cp.rows >= 6 and cp.rows[1].label == "right away" and cp.rows[2].label == "within 30 minutes",
      "the projection is broken down by when it sells (" .. #cp.rows .. " moments)")
    local last = cp.rows[#cp.rows]
    check(last.label == "in a week" and (last.hi - last.lo) > (cp.rows[1].hi - cp.rows[1].lo),
      "the further ahead, the wider the range")
    local labels = {}
    for _, r in ipairs(cp.rows) do labels[#labels + 1] = r.label end
    check(table.concat(labels, "|"):find("evening", 1, true) ~= nil, "an evening sale is among them: " .. table.concat(labels, ", "))

    -- Options for one item: trading it and crafting with it.
    local options = D.ForItem(d.id)
    local own = false
    for _, row in ipairs(options) do if row.id == d.id then own = true end end
    check(#options >= 1 and own, "the item's own trades are among its options (" .. #options .. ")")
    local mat
    for item in pairs(ns.Opt.Evaluate(craftRow.id, craftRow.qty).plan.buy) do mat = item break end
    if mat then
      local viaCraft = false
      for _, row in ipairs(D.ForItem(mat)) do if row.kind == "craft" and row.id == craftRow.id then viaCraft = true end end
      check(viaCraft, "a material lists the crafts it pays to buy it for")
    end
    ns.Open(d.id)
    ns.UI.ShowWorth(true)
    view.filters.item.scripts.OnClick(view.filters.item)
    check(view.summary.text:find("Ways to profit from", 1, true) ~= nil, "the This item filter names the item: " .. view.summary.text)
    for _, row in ipairs(view.rows) do
      if row.shown and row.scripts.OnEnter then row.scripts.OnEnter(row) row.scripts.OnLeave(row) end
    end
    -- When to sell what is held.
    view.filters.later.scripts.OnClick(view.filters.later)
    check(view.summary.text:find("When to sell", 1, true) ~= nil, "the When filter lists sell times")
    for _, row in ipairs(D.Timing()) do
      check(row.when and row.when.label and row.profit >= -1, "a timing row names its hour: " .. row.how)
      break
    end
    for _, row in ipairs(view.rows) do
      if row.shown and row.scripts.OnEnter then row.scripts.OnEnter(row) row.scripts.OnLeave(row) end
    end
    view.filters.vendor.scripts.OnClick(view.filters.vendor)
    price(d.id, { { ladderBefore, d.qty }, { ladderBefore + 30, 50 } })
    RunTimers()
    ns.UI.UpdateWorth()
  end
  FireEvent("AUCTION_HOUSE_SHOW")
  ns.UI.UpdateWorth()
  for _, row in ipairs(view.rows) do
    if row.shown and row.data and row.data.kind == "tovendor" and row.data.id == 2840 then buyRow = row end
  end
  buyRow.act.scripts.OnClick(buyRow.act)
  check(started and started[1] == 2840 and started[2] == 3, "at the auction house Buy starts the purchase of exactly 3")
  FireEvent("COMMODITY_PRICE_UPDATED", 5, 15)
  FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
  RunTimers()
  FireEvent("AUCTION_HOUSE_CLOSED")
  view.filters.all.scripts.OnClick(view.filters.all)
  for _, row in ipairs(view.rows) do
    if row.shown and row.scripts.OnEnter then row.scripts.OnEnter(row) row.scripts.OnLeave(row) end
  end
  ns.db.chars["Tester - TestRealm"].ordered = {}
  price(2836, { { 10, 500 } })
  price(2771, { { 500, 10 } })
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1; print(line) end end
  check(errors == 0, "no errors in the opportunities list")
end

------------------------------------------------------------------------------
-- The plan: own stock, the bank, changing amounts, clearing, worth-it check.
------------------------------------------------------------------------------
do
  local J, P = ns.Jobs, ns.Player
  local function price(id, ladder) M.Record(id, ladder, { full = true }) M.Get(id).k = "c" end
  local bags, bank = {}, {}
  C_Item.GetItemCount = function(id, includeBank)
    return (bags[id] or 0) + (includeBank and (bank[id] or 0) or 0)
  end
  FireEvent("BAG_UPDATE_DELAYED")
  RunTimers()
  price(2770, { { 10, 500 } })      -- copper ore
  price(2840, { { 60, 100 } })      -- copper bar: dearer than smelting
  price(3576, { { 30, 1000 } })     -- tin bar
  price(2841, { { 200, 50 } })      -- bronze bar
  J.Clear()
  check(#J.Pins() == 0, "clearing empties the plan")

  -- 3 tin bars in the bags and 30 in the bank; the plan needs 10.
  bags[3576], bank[3576] = 3, 30
  check(P.BankCount(3576) == 30, "the bank count is read")
  J.Pin(2841, 20)
  local job = J.All()[1]
  check(job.needs.own[3576] == 10 and job.needs.bank[3576] == 7 and job.needs.ah[3576] == nil,
    "own tin is used first: 3 from the bags, 7 from the bank, none bought")
  check(job.needs.ah[2770] == 10, "the ore is still bought")
  FireEvent("AUCTION_HOUSE_CLOSED")
  FireEvent("BANKFRAME_OPENED")
  job = J.All()[1]
  check(job.kind == "bank" and job.text:find("bank"), "at the bank the step is to take it out: " .. job.text)
  FireEvent("BANKFRAME_CLOSED")

  -- Limit own use to 4: the other 6 are bought instead.
  local pin = J.Pins()[1]
  pin.use = {}
  J.SetUse(pin.use, 3576, 4)
  job = J.All()[1]
  check(job.needs.own[3576] == 4 and job.needs.bank[3576] == 1 and job.needs.ah[3576] == 6,
    "limiting own use to 4 buys the other 6")
  J.SetUse(pin.use, 3576, 0)
  job = J.All()[1]
  check(job.needs.own[3576] == nil and job.needs.ah[3576] == 10, "using none of it buys everything")
  J.SetUse(pin.use, 3576, nil)

  -- Changing the amount reworks the whole plan.
  J.SetQty(2841, 40)
  job = J.All()[1]
  check(job.pin.qty == 40 and job.needs.ah[2770] == 20 and job.needs.own[3576] == 20,
    "doubling the amount doubles what is needed")
  J.SetQty(2841, 0)
  check(J.Pins()[1].qty == 1, "the amount never goes below one")
  J.SetQty(2841, 20)

  -- The graph shows own stock and the bank, with working steppers.
  ns.settings.qty = 20
  ns.Open(2841)
  if ns.UI.ShowWorth then ns.UI.ShowWorth(false, true) end
  ns.UI.Refresh()
  local stock = ns.UI.NodeStock({ id = 3576, side = 1 })
  check(stock and stock.text:find("Own 3") and stock.text:find("30 in bank") and stock.adjust,
    "a graph item shows what is owned and what is in the bank")
  check(stock.less and not stock.more, "with everything in use there is only a 'fewer' step")
  stock.less()
  RunTimers()
  ns.UI.Refresh()
  check(J.Pins()[1].use[3576] == 9, "pressing fewer lowers the own use by one")
  stock = ns.UI.NodeStock({ id = 3576, side = 1 })
  check(stock.more ~= nil, "and now there is a 'more' step")
  stock.more()
  RunTimers()
  ns.UI.Refresh()
  check(J.Pins()[1].use[3576] == 10 and J.All()[1].needs.ah[3576] == nil, "pressing more brings it back to all that is needed")
  check(ns.UI.NodeStock({ id = 3576, side = 1 }).more == nil, "and with nothing bought any more there is no 'more' step")
  check(ns.UI.NodeStock({ id = 2770, side = 1 }) == nil, "an item not owned at all has no stock line")

  -- Worth-it check when adding to the plan.
  J.Clear()
  local v = J.Verdict(2841, 20)
  check(v == "good", "bronze at 2s is worth planning: " .. v)
  check(ns.UI.AddToPlan(2841, 20) == true and J.IsPinned(2841), "a good plan is added straight away")
  J.Clear()
  price(2841, { { 21, 50 } })
  v = J.Verdict(2841, 20)
  check(v == "loss", "bronze at 21c is a loss: " .. v)
  check(ns.UI.AddToPlan(2841, 20) == false and not J.IsPinned(2841), "a losing plan is not added on the first press")
  check(ns.UI.AddToPlan(2841, 20) == true and J.IsPinned(2841), "but is on the second, if wanted")
  price(2841, { { 200, 50 } })

  -- Mail counted as waiting can be cleared by hand.
  ns.db.chars["Tester - TestRealm"].ordered = { [2770] = 10 }
  job = J.All()[1]
  check(next(job.needs.mail) ~= nil, "a purchase is counted as waiting in the mailbox")
  ns.UI.UpdateHUD()
  local mailButton
  for _, f in ipairs(frames) do if f.text == "I have collected the mail" then mailButton = f end end
  check(mailButton and mailButton:IsShown(), "the plan window offers to mark the mail as collected")
  mailButton.scripts.OnClick(mailButton)
  check(next(J.All()[1].needs.mail) == nil, "pressing it clears the waiting count")

  -- Clear needs two presses.
  local clear
  for _, f in ipairs(frames) do if f.text == "Clear" and f.template == "UIPanelButtonTemplate" then clear = f end end
  clear.scripts.OnClick(clear)
  check(#J.Pins() == 1 and clear.text == "Sure?", "the first press on Clear only asks")
  clear.scripts.OnClick(clear)
  check(#J.Pins() == 0, "the second press clears the plan")
  RunTimers()

  -- The sell list shows what is in the bank, apart from what can be posted.
  local slots = { { itemID = 2841, stackCount = 5 } }
  C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and #slots or 0 end,
    GetContainerItemInfo = function(bag, slot) return slots[slot] end,
    GetContainerItemID = function(bag, slot) return slots[slot] and slots[slot].itemID end,
  }
  bags = { [2841] = 5 }
  bank = { [2841] = 40, [2840] = 12 }
  FireEvent("BAG_UPDATE_DELAYED")
  RunTimers()
  local rows, sum = J.BagSales()
  local bronze, bars
  for _, d in ipairs(rows) do
    if d.id == 2841 then bronze = d end
    if d.id == 2840 then bars = d end
  end
  check(bronze and bronze.count == 5 and bronze.bank == 40, "bronze shows 5 in bags and 40 in the bank")
  check(bars and bars.count == 0 and bars.bank == 12, "copper bars only in the bank are listed too")
  check(sum.count == 1 and near(sum.total, 5 * 200 * 0.95), "only what is in the bags counts towards the total")
  check(sum.bankItems == 2 and near(sum.bankTotal, (40 * 200 + 12 * 60) * 0.95), "the bank's worth is given apart")
  ns.UI.OpenSell()
  RunTimers()
  local list
  for _, f in ipairs(frames) do if f.rows and f.next then list = f end end
  check(list.next.row and list.next.row.id == 2841, "Sell next only offers what is in the bags")
  for _, row in ipairs(list.rows) do
    if row.shown and row.scripts.OnEnter then row.scripts.OnEnter(row) row.scripts.OnLeave(row) end
  end
  bags, bank = {}, {}
  C_Container.GetContainerNumSlots = function() return 0 end
  C_Item.GetItemCount = function() return 0 end
  FireEvent("BAG_UPDATE_DELAYED")
  RunTimers()
  ns.UI.ShowSell(false)
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1; print(line) end end
  check(errors == 0, "no errors in the plan controls")
end

------------------------------------------------------------------------------
-- Graph lines carry the amount and value that flows along them.
------------------------------------------------------------------------------
do
  local function price(id, ladder) M.Record(id, ladder, { full = true }) M.Get(id).k = "c" end
  ns.Jobs.Clear()
  price(2770, { { 10, 500 } })
  price(2840, { { 60, 100 } })
  price(3576, { { 30, 1000 } })
  price(2841, { { 200, 50 } })
  ns.settings.qty = 20
  ns.Open(2841)
  ns.UI.ShowTrends(false, true)
  ns.UI.Refresh()
  local function strip(t) return (t:gsub("|A:coin%-(%a)%a*:%d+:%d+|a", "%1")) end
  -- 20 bronze = 10 casts: 10 tin bars at 30c = 3s, 10 copper bars smelted from ore at 10c = 1s.
  local tin = ns.UI.EdgeLabel({ from = 2841, to = 3576, qty = 1, spell = 2659 })
  check(strip(tin) == "x10  3s 0c", "the line to tin shows the plan's amount and its cost: " .. strip(tin))
  local bar = ns.UI.EdgeLabel({ from = 2841, to = 2840, qty = 1, spell = 2659 })
  check(strip(bar) == "x10  1s 0c", "the line to copper bars is valued at the cost of making them: " .. strip(bar))
  -- A line on the used-in side: one of that item takes this many of the centre item.
  local dep = ns.UI.EdgeLabel({ from = 2868, to = 2841, qty = 5, spell = 2672, left = true })
  check(strip(dep):match("^x5  ") ~= nil, "a used-in line shows what one craft takes: " .. strip(dep))
  ns.settings.qty = 1
end

------------------------------------------------------------------------------
-- Trends: hour and weekday patterns, stack sizes, sellers, direction.
------------------------------------------------------------------------------
do
  local id = 2775
  check(ns.Data.items[id] ~= nil, "the test item exists in the data")
  ns.realm.items[id] = nil
  -- Two weeks of scans at 03:00 (cheap, little listed) and 20:00 (dear, much listed).
  local start = os.date("*t", now - 14 * 86400)
  start.hour, start.min, start.sec = 0, 0, 0
  local t0 = os.time(start)
  for day = 0, 13 do
    for _, hour in ipairs({ 3, 20 }) do
      local t = t0 + day * 86400 + hour * 3600
      if t <= now then
        local price = hour == 3 and 100 or 120
        local raw = {}
        local stacks = hour == 3 and 2 or 8
        for i = 1, stacks do raw[#raw + 1] = { price + i, 20, i % 3 == 0 and "Bo" or "Anna" } end
        raw[#raw + 1] = { price, 5, "Anna" }
        M.Record(id, raw, { full = true, t = t, perAuction = true })
      end
    end
  end
  local it = M.Get(id)
  local byHour = S.Pattern(it.hd, 24)
  check(byHour.filled == 2 and byHour.slots[3] and byHour.slots[20], "two hours of the day have samples")
  check(byHour.slots[3].price < -0.05 and byHour.slots[20].price > 0.05,
    string.format("03:00 is cheaper and 20:00 dearer than usual (%.2f, %.2f)", byHour.slots[3].price, byHour.slots[20].price))
  check(near(byHour.slots[3].listed, 45) and near(byHour.slots[20].listed, 165), "supply by hour is averaged")
  check(byHour.slots[3].n >= 13, "each hour has about two weeks of scans: " .. byHour.slots[3].n)
  local byDay = S.Pattern(it.wd, 7)
  check(byDay.filled == 7, "every weekday has samples")
  check(it.bs[1] == 20 and it.bs[3] == 5, "stacks of 20 are the commonest, then 5")
  check(it.sl[1] == "Anna" and it.sl[3] == "Bo" and it.sn == 2, "sellers are ranked by what they list")
  check(it.sp.Anna >= 26, "and how often a seller has been seen is counted: " .. tostring(it.sp.Anna))
  local trend = S.Trend(id)
  check(trend and trend.usual and trend.vsUsual and trend.perDay and math.abs(trend.perDay) < 0.03,
    "a price that only swings by time of day has no direction: " .. tostring(trend and trend.perDay))

  -- A scan repeated within half an hour is not counted twice.
  local before = it.hd[20][1]
  M.Record(id, { { 120, 5, "Anna" } }, { full = true, t = now - 600, perAuction = true })
  M.Record(id, { { 120, 5, "Anna" } }, { full = true, t = now - 300, perAuction = true })
  local hourNow = tonumber(os.date("%H", now - 600))
  check((it.hd[hourNow] and it.hd[hourNow][1] or 0) <= (hourNow == 20 and before + 1 or 1),
    "repeated scans within half an hour add one sample, not several")

  -- A price rising 5% a day is seen as rising.
  local rising = 2776
  ns.realm.items[rising] = nil
  for step = 28, 0, -1 do
    local t = now - step * 21600
    M.Record(rising, { { 1000 * 1.05 ^ ((28 - step) / 4), 10 } }, { full = true, t = t })
  end
  local up = S.Trend(rising)
  check(up and up.perDay and near(up.perDay, 0.05, 0.012), "a 5% a day rise is measured: " .. tostring(up and up.perDay))

  -- The view: every option, every bar's hover text, and the empty states.
  ns.Open(id)
  ns.UI.ShowTrends(true)
  RunTimers()
  local view
  for _, f in ipairs(frames) do if f.options and f.facts then view = f end end
  check(view and view:IsShown(), "the trends view opens")
  check(view.facts.text:find("cheapest around 03:00") ~= nil, "it names the cheap hour: " .. view.facts.text)
  check(view.sellerRows[1] and view.sellerRows[1].label.text == "Anna", "it lists the leading seller")

  -- The estimate for a time of the week. The item is about 100 at 03:00 and
  -- about 120 at 20:00, the same every day.
  do
    local week = S.Week(id)
    check(week and week.base > 100 and week.base < 126, "the week starts from the usual price: " .. tostring(week and week.base))
    local night, evening = S.WeekAt(week, nil, 3), S.WeekAt(week, nil, 20)
    check(evening.price / night.price > 1.10 and evening.price / night.price < 1.25,
      string.format("03:00 is estimated cheaper than 20:00 (%.0f, %.0f)", night.price, evening.price))
    check(night.lo < night.price and night.hi > night.price and night.hourN >= 13 and night.hourGap == 0,
      "a sampled hour comes with a range and its scan count")
    local noon = S.WeekAt(week, nil, 11)
    check(noon.hourN == 0 and noon.hourGap and noon.hourGap >= 1 and noon.price > night.price and noon.price < evening.price,
      string.format("an hour without scans is filled in between its neighbours (%.0f)", noon.price))
    check(noon.hi / noon.lo > night.hi / night.lo, "and its range is wider than a sampled hour's")
    local midnight = S.WeekAt(week, nil, 0)
    check(midnight.hourGap == 3 and midnight.price < noon.price, "the clock wraps: midnight leans on 03:00 and 20:00")
    local monday = S.WeekAt(week, 1, 20)
    check(monday.dayN >= 1 and math.abs(monday.price / evening.price - 1) < 0.05,
      string.format("with no weekday effect, Monday 20:00 is like any 20:00 (%.0f)", monday.price))
    check(monday.listed and monday.listed > 100, "the amount listed is estimated too: " .. tostring(monday.listed))
    check(S.Week(999999) == nil, "an item without prices has no week")

    -- The selector: drag to a bar, scroll, switch views; the readout follows.
    view.options["period:hour"].scripts.OnClick()
    view.barHits[21].scripts.OnMouseDown(view.barHits[21], "LeftButton")
    check(view.readout.text:find("20:00 to 21:00, any day", 1, true) ~= nil, "selecting the 20:00 bar reads it out: " .. view.readout.text)
    check(view.readout.text:find("scans at this hour", 1, true) ~= nil, "and says what it rests on")
    view.barHits[21].scripts.OnMouseWheel(view.barHits[21], -1)
    check(view.readout.text:find("21:00 to 22:00", 1, true) ~= nil, "the wheel steps to the next hour")
    check(view.readout.text:find("filled in", 1, true) ~= nil, "an unsampled hour is called filled in")
    view.options["period:week"].scripts.OnClick()
    check(view.barHits[168] and view.barHits[168]:IsShown(), "the week view has a bar for each of 168 hours")
    view.barHits[15].scripts.OnMouseDown(view.barHits[15], "LeftButton")
    check(view.readout.text:find("Monday 14:00 to 15:00", 1, true) ~= nil, "Monday afternoon can be selected: " .. view.readout.text)
    check(view.readout.text:find("likely between", 1, true) ~= nil, "with a likely range")
    view.barHits[1].scripts.OnMouseWheel(view.barHits[1], 1)
    check(view.readout.text:find("Monday 13:00", 1, true) ~= nil, "scrolling up steps back an hour")
    view.options["period:day"].scripts.OnClick()
    check(view.readout.text:find("Mondays, whole day", 1, true) ~= nil, "the day view keeps the chosen day")
    check(not view.barHits[8]:IsShown(), "bars the day view does not need are hidden")

    -- The same picture in the side panel, switched in from the chart header.
    local side
    for _, fr in ipairs(frames) do if fr.week and fr.chartMode then side = fr end end
    check(side and not side.week:IsShown(), "the side panel shows the price history by default")
    side.chartMode.scripts.OnClick()
    RunTimers()
    check(side.week:IsShown() and side.chartMode.text == "Week pattern", "its header switches to the week pattern")
    check(not side.range:IsShown() and not side.showButton:IsShown(), "the history's own options are hidden meanwhile")
    check(side.week.bars[168] and side.week.bars[168]:IsShown(), "the strip has all 168 hours")
    check(side.week.readout.text:find("Monday 13:00", 1, true) ~= nil, "it starts on the time already selected: " .. side.week.readout.text)
    side.week.Select(2 * 24 + 20)
    check(side.week.readout.text:find("Wednesday 20:00", 1, true) ~= nil and side.week.readout.text:find("usually", 1, true) ~= nil,
      "picking Wednesday evening reads its price: " .. side.week.readout.text)
    side.week.plot.scripts.OnMouseWheel(side.week.plot, -1)
    check(side.week.readout.text:find("Wednesday 21:00", 1, true) ~= nil, "the wheel steps the strip an hour on")
    view.options["period:week"].scripts.OnClick()
    check(view.readout.text:find("Wednesday 21:00", 1, true) ~= nil, "the Trends view follows the same selector")
    view.barHits[1].scripts.OnMouseDown(view.barHits[1], "LeftButton")
    check(side.week.readout.text:find("Monday 00:00", 1, true) ~= nil, "and the strip follows the Trends view")
    check(side.week.nLine >= 167 and side.week.nDot >= 20, "the folded week draws the usual curve and the scans as dots (" .. side.week.nLine .. " lines, " .. side.week.nDot .. " dots)")
    side.chartMode.scripts.OnClick()
    RunTimers()
    check(side.week:IsShown() and side.chartMode.text == "Day pattern" and side.week.mode == "day", "the next press folds onto one day")
    side.week.Select(20)
    check(side.week.readout.text:find("20:00, any day", 1, true) ~= nil, "and reads an hour of any day: " .. side.week.readout.text)
    check(side.week.bars[24]:IsShown() and not side.week.bars[25]:IsShown(), "with 24 columns")
    side.chartMode.scripts.OnClick()
    RunTimers()
    check(not side.week:IsShown() and side.range:IsShown(), "the header switches back to the history")

    view.options["measure:listed"].scripts.OnClick()
    view.options["period:week"].scripts.OnClick()
    view.options["measure:price"].scripts.OnClick()
    view.options["period:hour"].scripts.OnClick()
  end
  check(view.stackRows[1] and view.stackRows[1].label.text == "x20", "it lists the commonest stack size")
  for key, button in pairs(view.options) do
    button.scripts.OnClick(button)
    for _, hit in ipairs(view.barHits) do
      if hit.shown and hit.scripts.OnEnter then hit.scripts.OnEnter(hit) hit.scripts.OnLeave(hit) end
    end
  end
  local shownBars = 0
  for _, bar in ipairs(view.bars) do if bar.shown then shownBars = shownBars + 1 end end
  check(shownBars >= 1, "bars are drawn")
  ns.realm.items[2777] = nil
  M.Record(2777, { { 500, 3 } }, { full = true })
  ns.UI.Focus(2777)
  ns.UI.ShowTrends(true)
  check(view.facts.text:find("Too few scans") ~= nil, "one scan is not called a trend")
  check(view.stackNote.text ~= "" and view.sellerNote.text ~= "", "missing stack and seller data is explained, not drawn")
  ns.UI.Back()
  ns.UI.ShowTrends(false)
  SlashCmdList["CRAFTGRAPH"]("trends")
  check(view:IsShown(), "/cg trends opens it")
  ns.UI.ShowTrends(false)
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1; print(line) end end
  check(errors == 0, "no errors in the trends view")
end

------------------------------------------------------------------------------
-- History: back and forward through items and the worth-crafting list.
------------------------------------------------------------------------------
do
  local function at() return ns.settings.lastItem end
  ns.UI.ShowWorth(false)
  ns.UI.Focus(2841)
  ns.UI.Focus(2840)
  ns.UI.Focus(2770)
  ns.UI.Back()
  check(at() == 2840, "back goes to the previous item")
  ns.UI.Back()
  check(at() == 2841, "back again goes one further")
  ns.UI.Forward()
  check(at() == 2840, "forward returns")
  ns.UI.NavButton("Button5")
  check(at() == 2770, "the mouse forward button works")
  ns.UI.Forward()
  check(at() == 2770, "forward at the end does nothing")
  ns.UI.NavButton("Button4")
  ns.UI.Focus(3576)
  ns.UI.Forward()
  check(at() == 3576, "a new step drops the old forward steps")
  ns.UI.ShowWorth(true)
  local listShown
  for _, f in ipairs(frames) do if f.rows and f.summary and not f.next then listShown = f end end
  check(listShown and listShown:IsShown(), "the worth-crafting list is showing")
  ns.UI.Back()
  check(not listShown:IsShown() and at() == 3576, "back leaves the list for the graph")
  ns.UI.Forward()
  check(listShown:IsShown(), "forward returns to the list")
  -- A node button clicked with the mouse back button goes back, not to the item.
  ns.UI.ShowWorth(false)
  ns.UI.Focus(2841)
  for _, f in ipairs(frames) do
    if f.node and f.node.id and f.node.id ~= 2841 and f.shown and f.scripts.OnClick then
      f.scripts.OnClick(f, "Button4")
      break
    end
  end
  check(at() ~= 2841, "a side-button click on an item goes back instead of opening it")
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1; print(line) end end
  check(errors == 0, "no errors while moving through history")
end

------------------------------------------------------------------------------
-- Reload: the window comes back on the same item.
------------------------------------------------------------------------------
do
  local reloaded = false
  ReloadUI = function() reloaded = true end
  ns.UI.Focus(2841)
  SlashCmdList["CRAFTGRAPH"]("reload")
  check(reloaded and ns.settings.reopen == true, "/cg reload asks the game to reload and remembers the window")
  CraftGraphFrame:Hide()
  ns.settings.reopen = true
  FireEvent("PLAYER_ENTERING_WORLD", false, true)
  RunTimers()
  check(CraftGraphFrame:IsShown() and ns.settings.lastItem == 2841, "window reopens after a reload")
  CraftGraphFrame:Hide()
  FireEvent("PLAYER_ENTERING_WORLD", true, false)
  RunTimers()
  check(not CraftGraphFrame:IsShown(), "a normal login does not open the window")
end

------------------------------------------------------------------------------
-- Auto scan
do
  local M = ns.Market
  local asked = 0
  local oldReplicate = C_AuctionHouse.ReplicateItems
  C_AuctionHouse.ReplicateItems = function() asked = asked + 1 end
  FireEvent("AUCTION_HOUSE_CLOSED")
  RunTimers()
  ns.settings.autoScan = true
  ns.db.lastFullScan, ns.db.lastAutoScan, M.autoHold, M.fullPending = nil, nil, nil, nil
  M.autoItems = function() return { 2835, 2836, 2835 } end

  check(M.AutoNext() == nil, "auto scan does nothing with the auction house closed")
  M.AutoTick()
  check(asked == 0, "no scan is asked for while it is closed")

  M.ahOpen = true
  local what, wait = M.AutoNext()
  check(what == "full" and wait == 0, "first thing with the auction house open: a full scan")
  M.AutoTick()
  check(asked == 1, "the full scan is asked for once")
  M.AutoTick()
  check(asked == 1, "and not again while the answer is awaited")

  -- The scan was answered and recorded 1 minute ago.
  M.fullPending = nil
  ns.db.lastFullScan, ns.db.lastAutoScan = now - 60, now - 60
  sentQueries = {}
  M.AutoTick()
  check(asked == 1 and #sentQueries == 0, "nothing more for the next minutes")
  what, wait = M.AutoNext()
  check(what == "items" and wait == 540, "next: the plan's items, 9 minutes from now (" .. tostring(what) .. " " .. tostring(wait) .. ")")

  -- 10 minutes after the last scan the watched items are looked up, once each.
  ns.db.lastAutoScan = now - 601
  M.AutoTick()
  check(sentQueries[1] == 2835 and M.IsScanning(), "after 10 minutes the watched items are looked up")
  FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2835) RunTimers()
  FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2836) RunTimers()
  check(#sentQueries == 2 and not M.IsScanning(), "each watched item once, duplicates dropped (" .. #sentQueries .. ")")
  ns.db.lastFullScan = now - 660
  what, wait = M.AutoNext()
  check(what == "full" and wait == 240, "then the full scan when its 15 minutes are up (" .. tostring(what) .. " " .. tostring(wait) .. ")")

  -- Full scan allowed again.
  ns.db.lastFullScan = now - 901
  M.AutoTick()
  check(asked == 2, "a full scan again once the game allows it")
  -- No answer: wait before trying again.
  M.fullPending = nil
  ns.Fire("FULLSCAN", "timeout")
  ns.db.lastAutoScan = now
  M.AutoTick()
  check(asked == 2, "an unanswered full scan is not asked for again straight away")

  -- The switch in the main window and the words beside it.
  ns.Open(2835)
  RunTimers()
  M.autoHold, M.fullPending = nil, nil
  ns.db.lastFullScan = now - 300
  check(ns.UI.AutoText():find("full scan in 10 min", 1, true) ~= nil, "the window says when the next full scan comes: " .. ns.UI.AutoText())
  ns.db.lastFullScan = now - 901
  check(ns.UI.AutoText():find("any moment", 1, true) ~= nil, "and when it is due")
  ns.Fire("FULLSCAN", "done", 10, 5)
  check(ns.UI.AutoText():find("done)", 1, true) ~= nil, "finished full scans are counted: " .. ns.UI.AutoText())
  M.ahOpen = false
  check(ns.UI.AutoText():find("open the auction house", 1, true) ~= nil, "closed: it asks for the auction house")
  M.ahOpen = true
  ns.UI.autoMain:SetChecked(false)
  ns.UI.autoMain.scripts.OnClick(ns.UI.autoMain)
  check(ns.settings.autoScan == false and ns.UI.AutoText():find("off", 1, true) ~= nil, "unticking it in the window switches auto scan off")
  M.fullPending = nil
  ns.db.lastFullScan, ns.db.lastAutoScan = now, now
  ns.UI.autoMain:SetChecked(true)
  ns.UI.autoMain.scripts.OnClick(ns.UI.autoMain)
  check(ns.settings.autoScan == true, "ticking it switches it on again")

  -- Switched off.
  M.autoHold = nil
  ns.settings.autoScan = false
  M.AutoTick()
  check(asked == 2 and M.AutoNext() == nil, "switched off, nothing is scanned")
  SlashCmdList.CRAFTGRAPH("auto")
  check(ns.settings.autoScan == true, "/cg auto switches it on")

  M.fullPending = nil
  ns.db.lastFullScan = now
  C_AuctionHouse.ReplicateItems = oldReplicate
  FireEvent("AUCTION_HOUSE_CLOSED")
  RunTimers()
end

------------------------------------------------------------------------------
-- Found in review: each of these was a real fault once.
do
  local M, S, J = ns.Market, ns.Stats, ns.Jobs
  -- Scans ten minutes apart with moving prices must each keep their point.
  local id = 2595
  ns.realm.items[id] = nil
  for step = 36, 0, -1 do
    M.Record(id, { { 300 + step * 3, 40 + step } }, { full = true, t = now - step * 600 })
  end
  local kept = #M.History(M.Get(id)) / 4
  check(kept == 37, "37 scans ten minutes apart keep 37 points, not one: " .. kept)
  -- The same scan arriving twice within minutes is still one point.
  M.Record(id, { { 301, 40 } }, { full = true, t = now + 60 })
  M.Record(id, { { 302, 40 } }, { full = true, t = now + 120 })
  check(#M.History(M.Get(id)) / 4 == 37, "results a minute apart are one scan")
  -- A result stamped earlier than the last point does not run time backwards.
  M.Record(id, { { 310, 40 } }, { full = true, t = now - 5000 })
  local h = M.History(M.Get(id))
  local ordered = true
  for i = 5, #h, 4 do if h[i] < h[i - 4] then ordered = false end end
  check(ordered, "history never steps back in time")
  local round = M.Unpack(M.Pack({ 1000, 5, 5, 1, 990, 6, 6, 1, 1200, 7, 7, 1 }))
  check(round[5] == 1000 and round[9] == 1200, "packing a step back keeps the later times right")
  ns.realm.items[id] = nil

  -- The model's "now" follows the clock even when no price changes.
  local mid = 2596
  ns.realm.items[mid] = nil
  M.Record(mid, { { 400, 10 } }, { full = true, t = now - 100 })
  local before = S.ForItem(mid).now
  now = now + 7200
  check(S.ForItem(mid).now == before + 7200, "two idle hours later the estimate is worked out from the present")
  now = now - 7200
  ns.generation = ns.generation + 1
  ns.realm.items[mid] = nil

  -- Buying from an offer refuses when the listings cost more than the offer counted on.
  local bid = 2597
  ns.realm.items[bid] = nil
  M.Record(bid, { { 50, 10 }, { 90, 10 } }, { full = true, t = now })
  M.Get(bid).k = "c"
  local started
  local oldStart = C_AuctionHouse.StartCommoditiesPurchase
  C_AuctionHouse.StartCommoditiesPurchase = function(item, qty) started = { item, qty } end
  local wasOpen = M.ahOpen
  M.ahOpen = true
  check(J.BuyAuction(bid, 10, 300) == false and started == nil,
    "an offer made at 30 each is not bought at 50 each")
  check(J.BuyAuction(bid, 10, 500) ~= false and started and started[2] == 10,
    "the same offer goes through when the listings still cost what it counted on")
  FireEvent("AUCTION_HOUSE_CLOSED") RunTimers()
  M.ahOpen = wasOpen
  C_AuctionHouse.StartCommoditiesPurchase = oldStart
  -- A plan for more than is listed says so and does not count the rest as free.
  local proj = J.Projection(bid, 30, { kind = "flip", qty = 30, outlay = 1500, sellEach = 80 })
  check(proj.short == 10 and proj.cost >= 10 * 50 + 10 * 90 + 10 * 90,
    "units that are not listed are counted at the dearest price: " .. tostring(proj.cost))
  ns.realm.items[bid] = nil

  -- A full scan that gets no answer does not hold up the item lookups.
  local asked = 0
  local oldReplicate = C_AuctionHouse.ReplicateItems
  C_AuctionHouse.ReplicateItems = function() asked = asked + 1 end
  ns.settings.autoScan = true
  ns.db.lastFullScan, ns.db.lastAutoScan, M.autoHold, M.fullPending, M.autoMisses = nil, now - 3600, nil, nil, nil
  M.autoItems = function() return { 2835 } end
  M.ahOpen = true
  M.AutoTick()
  check(asked == 1, "the full scan is asked for")
  M.fullPending = nil
  ns.Fire("FULLSCAN", "timeout")
  sentQueries = {}
  M.AutoTick()
  check(asked == 1 and sentQueries[1] == 2835, "after no answer, the item lookups still run")
  FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2835) RunTimers()
  local firstHold = M.autoHold - now
  ns.Fire("FULLSCAN", "timeout")
  check(firstHold == 300 and M.autoHold - now == 600, "each miss waits longer before asking again")
  -- Hand trading in the standard window holds the lookups back.
  AuctionHouseFrameDisplayMode = { CommoditiesBuy = {}, ItemBuy = {}, CommoditiesSell = {}, ItemSell = {}, Buy = {} }
  local page = AuctionHouseFrameDisplayMode.CommoditiesBuy
  AuctionHouseFrame = { IsShown = function() return true end, GetDisplayMode = function() return page end }
  ns.db.lastAutoScan = now - 3600
  sentQueries = {}
  M.AutoTick()
  check(#sentQueries == 0, "no lookups while you are on a buy page of the auction window")
  page = AuctionHouseFrameDisplayMode.Buy
  M.AutoTick()
  check(sentQueries[1] == 2835, "they resume on the browse page")
  FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2835) RunTimers()
  AuctionHouseFrame, AuctionHouseFrameDisplayMode = nil, nil
  C_AuctionHouse.ReplicateItems = oldReplicate
  M.autoHold, M.autoMisses, M.fullPending = nil, nil, nil
  ns.db.lastFullScan = now
  FireEvent("AUCTION_HOUSE_CLOSED") RunTimers()
end

------------------------------------------------------------------------------
-- Sales seen between full scans
do
  local M = ns.Market
  local id = 2598
  ns.realm.items[id] = nil
  local function auctions(list)
    local out = {}
    for _, a in ipairs(list) do
      for _ = 1, a.n do out[#out + 1] = { a.unit, a.count, a.owner, a.band } end
    end
    return out
  end
  local t0 = now - 3600
  check(M.TrackSales(id, auctions({
    { n = 10, unit = 100, count = 20, owner = "Anna", band = 3 },
    { n = 5, unit = 150, count = 20, owner = "Bo", band = 3 },
    { n = 2, unit = 90, count = 20, owner = "Cy", band = 0 },
  }), t0) == nil, "the first full scan has nothing to compare with")
  check(M.Sales(id) == nil, "so there is no selling rate yet")
  -- An hour later: 4 of Anna's are gone; Bo took his 5 down and put 5 up
  -- cheaper; Cy's 2 had under half an hour left and are gone.
  local sold = M.TrackSales(id, auctions({
    { n = 6, unit = 100, count = 20, owner = "Anna", band = 3 },
    { n = 5, unit = 140, count = 20, owner = "Bo", band = 3 },
  }), now)
  check(sold and sold > 70 and sold < 95, string.format("Anna's 4 stacks count as sold, the rest hardly: %.1f units", sold or -1))
  local s = M.Sales(id)
  check(s and near(s.units, sold) and near(s.days, 1 / 24, 1e-6) and s.auctions > 3 and s.auctions < 5,
    "the belief holds the units, the auctions and the hour watched")
  check(s.lo < s.rate and s.rate < s.hi and s.lo > 0, string.format("it gives a rate with a range: %.0f a day (%.0f to %.0f)", s.rate, s.lo, s.hi))
  check(s.sellers.Anna and s.sellers.Anna > 70 and (s.sellers.Bo or 0) < 5 and not s.sellers.Cy,
    "sales are credited to the seller whose auctions went")
  -- Nothing vanishes for six more hours: the rate comes down and the range tightens.
  local before = s.rate
  for h = 1, 6 do
    M.TrackSales(id, auctions({
      { n = 6, unit = 100, count = 20, owner = "Anna", band = 3 },
      { n = 5, unit = 140, count = 20, owner = "Bo", band = 3 },
    }), now + h * 3600)
  end
  s = M.Sales(id)
  check(s.rate < before / 2.5 and near(s.days, 7 / 24, 0.01), string.format("six quiet hours bring the rate down: %.0f a day", s.rate))
  -- A dear auction that vanishes while cheaper ones stay is hardly counted.
  local dear = M.TrackSales(id, auctions({
    { n = 6, unit = 100, count = 20, owner = "Anna", band = 3 },
    { n = 4, unit = 140, count = 20, owner = "Bo", band = 3 },
  }), now + 7 * 3600)
  check(dear < 6, string.format("one of Bo's dearer stacks going is mostly not a sale: %.1f", dear))
  -- Scans too far apart are not compared.
  check(M.TrackSales(id, auctions({ { n = 1, unit = 100, count = 20, owner = "Anna", band = 3 } }), now + 40 * 3600) == nil,
    "scans more than twelve hours apart are not compared")
  -- An item nobody watched for a day with no sales still gets an answer, and names with spaces or none survive.
  local quiet = 2599
  ns.realm.items[quiet] = nil
  M.TrackSales(quiet, auctions({ { n = 3, unit = 50, count = 1, band = 3 } }), now - 7200)
  M.TrackSales(quiet, auctions({ { n = 3, unit = 50, count = 1, band = 3 } }), now)
  local q = M.Sales(quiet)
  check(q and q.units == 0 and q.rate < 6 and q.lo >= 0, string.format("no sales in two hours: a low rate, not none (%.1f a day)", q and q.rate or -1))
  -- The chart can draw supply and demand lines, by a checkbox in the side panel.
  do
    check(M.Get(id).sh and #M.Get(id).sh >= 2 * 8, "the selling rate between scans is kept as a short history")
    for step = 12, 0, -1 do
      M.Record(id, { { 100 + step, 100 + step * 10 } }, { full = true, t = now - step * 1800 })
    end
    ns.Open(id) RunTimers()
    local side, chartFrame
    for _, fr in ipairs(frames) do
      if fr.week and fr.chartMode then side = fr end
      if fr.plot and fr.clocks then chartFrame = fr end
    end
    check(side.flow and side.flow:GetChecked() == false and (chartFrame.flowLines or 0) == 0
      and side.demand and side.demand:GetChecked() == false and (chartFrame.demandLines or 0) == 0,
      "the supply and demand lines are off to start with")
    side.flow:SetChecked(true)
    side.flow.scripts.OnClick(side.flow)
    RunTimers()
    check(ns.settings.chartFlow == true and chartFrame.flowLines >= 8 and chartFrame.demandLines == 0,
      "ticking Supply draws the listed line only: " .. tostring(chartFrame.flowLines) .. " segments")
    check(chartFrame.flowLabel.text:find("listed, most", 1, true) ~= nil, "with its scale named: " .. chartFrame.flowLabel.text)
    side.flow:SetChecked(false)
    side.flow.scripts.OnClick(side.flow)
    side.demand:SetChecked(true)
    side.demand.scripts.OnClick(side.demand)
    RunTimers()
    check(ns.settings.chartDemand == true and chartFrame.demandLines >= 3 and chartFrame.flowLines == 0,
      "ticking Demand draws the sold-a-day line only: " .. tostring(chartFrame.demandLines) .. " segments")
    local scale = chartFrame.demandScale
    local digit = scale and scale / 10 ^ math.floor(math.log(scale) / math.log(10) + 1e-9)
    check(scale and (near(digit, 1, 1e-6) or near(digit, 2, 1e-6) or near(digit, 5, 1e-6) or near(digit, 10, 1e-6)),
      "its scale tops out at a round figure: " .. tostring(scale))
    check(chartFrame.demandTop.text:find("/d", 1, true) ~= nil and chartFrame.demandMid.text:find("/d", 1, true) ~= nil,
      "the scale is written in units a day: " .. chartFrame.demandTop.text .. " and " .. chartFrame.demandMid.text)
    check(chartFrame.flowLabel.text:find("sold a day, about", 1, true) ~= nil, "and the label gives the rate: " .. chartFrame.flowLabel.text)
    -- The figure under the chart is the one the card and the panel show.
    do
      local turnover = M.Info(id).turnover
      local shown = turnover >= 10 and tostring(ns.Round(turnover)) or (string.format("%.1f", turnover):gsub("%.0$", ""))
      check(chartFrame.flowLabel.text:find("about " .. shown, 1, true) ~= nil,
        "the chart's demand figure is the item's turnover (" .. shown .. "): " .. chartFrame.flowLabel.text)
    end
    -- An item with a believed rate but no rate history yet gets a level line; one with nothing says what it needs.
    local keep = M.Get(id).sh
    M.Get(id).sh = nil
    ns.UI.Refresh() RunTimers()
    check(chartFrame.demandLines == 1 and chartFrame.flowLabel.text:find("about", 1, true) ~= nil,
      "with one figure so far the demand is a level line: " .. chartFrame.flowLabel.text)
    local sa, sn, sb = M.Get(id).sa, M.Get(id).sn, M.Get(id).sb
    M.Get(id).sa, M.Get(id).sn, M.Get(id).sb = nil, nil, nil
    ns.generation = ns.generation + 1
    ns.UI.Refresh() RunTimers()
    check(chartFrame.demandLines == 0 and chartFrame.flowLabel.text:find("needs two full scans", 1, true) ~= nil,
      "with no sales seen yet it says what it needs: " .. chartFrame.flowLabel.text)
    M.Get(id).sh, M.Get(id).sa, M.Get(id).sn, M.Get(id).sb = keep, sa, sn, sb
    ns.generation = ns.generation + 1
    -- Reading sizes off the chart: a grid (on to start with) and change bars, each with a tick box.
    do
      check(ns.settings.chartGrid == true and ns.settings.chartBars == false, "a new install has the grid on and the bars off")
      check(chartFrame.gridLines >= 1 and chartFrame.gridLabels[1].text ~= "", "the grid draws lines with their prices: " .. chartFrame.gridLabels[1].text)
      check(side.showButton:IsShown() and not side.chartOptions:IsShown(), "the tick boxes sit behind a Show button")
      side.showButton.scripts.OnClick(side.showButton)
      check(side.chartOptions:IsShown() and side.grid:GetChecked() == true and side.bars:GetChecked() == false, "which opens the panel with them")
      side.grid:SetChecked(false)
      side.grid.scripts.OnClick(side.grid) RunTimers()
      check(ns.settings.chartGrid == false and chartFrame.gridLines == 0, "unticking Grid removes it")
      side.bars:SetChecked(true)
      side.bars.scripts.OnClick(side.bars) RunTimers()
      check(ns.settings.chartBars == true and chartFrame.changeBars >= 1, "ticking Change bars draws them: " .. chartFrame.changeBars)
      local labelled = false
      for _, l in ipairs(chartFrame.barLabels) do if l.shown and l.text:find("%", 1, true) then labelled = true end end
      check(labelled, "the latest change carries its figure")
      side.bars:SetChecked(false)
      side.bars.scripts.OnClick(side.bars)
      side.grid:SetChecked(true)
      side.grid.scripts.OnClick(side.grid) RunTimers()
      side.showButton.scripts.OnClick(side.showButton)
    end
    -- The smoothing period: click to step through; every scanned line follows it.
    do
      local C = ns.Chart
      check(chartFrame.smoothText.text == "smooth: auto" and chartFrame.averageLines == 0, "the chart starts on its own choice of smoothing")
      local flat = C.Smooth({ { 0, 10 }, { 600, 20 }, { 1200, 30 }, { 100000, 99 } }, 1500)
      check(near(flat[2][2], 20) and near(flat[1][2], 15) and flat[4][2] == 99, "a point is averaged with those within half the period either side")
      local weighted = C.Smooth({ { 0, 0 }, { 600, 100 } }, 3000, { 3, 1 })
      check(near(weighted[1][2], 25), "weights are honoured: " .. tostring(weighted[1][2]))
      local raw = chartFrame.demandScale
      chartFrame.smooth.scripts.OnClick(chartFrame.smooth, "LeftButton") RunTimers()
      check(ns.settings.chartSmooth == 15 and chartFrame.smoothText.text == "smooth: 15 min", "a click moves to 15 minutes: " .. chartFrame.smoothText.text)
      check(chartFrame.averageLines >= 3, "the scanned prices get an average line: " .. chartFrame.averageLines)
      for _ = 1, 2 do chartFrame.smooth.scripts.OnClick(chartFrame.smooth, "LeftButton") end
      RunTimers()
      check(ns.settings.chartSmooth == 60 and chartFrame.smoothText.text == "smooth: 1 h" and chartFrame.demandLines >= 3, "then 30 minutes, then an hour")
      chartFrame.smooth.scripts.OnClick(chartFrame.smooth, "RightButton") RunTimers()
      check(ns.settings.chartSmooth == 30, "a right-click goes back")
      for _ = 1, 6 do chartFrame.smooth.scripts.OnClick(chartFrame.smooth, "LeftButton") end
      RunTimers()
      check(ns.settings.chartSmooth == 0 and chartFrame.averageLines == 0 and chartFrame.smoothText.text == "smooth: auto",
        "past a day it wraps round to auto: " .. chartFrame.smoothText.text)
      chartFrame.smooth.scripts.OnEnter(chartFrame.smooth) chartFrame.smooth.scripts.OnLeave(chartFrame.smooth)
    end
    side.demand:SetChecked(false)
    side.demand.scripts.OnClick(side.demand)
    RunTimers()
    check(chartFrame.demandLines == 0 and chartFrame.flowLabel.text == "" and chartFrame.demandTop.text == "", "unticking removes it")
  end
  -- A graph card says in short how many sell a day.
  do
    local card
    for _, fr in ipairs(frames) do if fr.node and fr.node.id == id and fr.line1 then card = fr end end
    check(card and card.line1.text:find("/d", 1, true) ~= nil, "the item's card shows sales a day in short: " .. tostring(card and card.line1.text))
  end
  -- The source can be switched off.
  ns.Market.Record(id, { { 100, 120 } }, { full = true, t = now })
  local info = M.Info(id)
  check(info.sales ~= nil and info.turnover == M.Sales(id).rate, "the selling rate feeds the item's turnover")
  M.SetSource("Sales", false)
  check(M.Sales(id) == nil and M.Info(id).sales == nil, "switched off, the tracked sales are not used")
  check(ns.UI.SourcesText() and ns.UI.SourcesText():find("Sales seen", 1, true) ~= nil, "and the window says which source is off")
  M.SetSource("Sales", true)
  check(M.Sales(id) ~= nil and ns.UI.SourcesText() == nil, "switched on again, they are")
  ns.UI.ToggleSources()
  check(ns.UI.sourcesFrame:IsShown() and #ns.UI.sourcesFrame.rows == 4, "the data sources window opens with its four switches")
  local row = ns.UI.sourcesFrame.rows[3]
  row.check:SetChecked(false)
  row.check.scripts.OnClick(row.check)
  check(M.Source("Auctionator") == false, "unticking Auctionator switches it off")
  row.check:SetChecked(true)
  row.check.scripts.OnClick(row.check)
  ns.UI.ToggleSources()
  SlashCmdList.CRAFTGRAPH("sources")
  check(ns.UI.sourcesFrame:IsShown(), "/cg sources opens it too")
  ns.UI.ToggleSources()
  -- Trends names the rate.
  ns.Open(id)
  ns.UI.ShowTrends(true) RunTimers()
  local view
  for _, f in ipairs(frames) do if f.options and f.facts then view = f end end
  check(view.facts.text:find("Sells:", 1, true) ~= nil and view.facts.text:find("a day", 1, true) ~= nil, "Trends says how fast it sells: " .. view.facts.text)
  ns.UI.ShowTrends(false)
  ns.realm.items[id], ns.realm.items[quiet] = nil, nil
end

------------------------------------------------------------------------------
-- Forecasts that would only be guesses are held back, with the reason.
do
  local M, S, J = ns.Market, ns.Stats, ns.Jobs
  ns.settings.showGuesses = false
  ns.generation = ns.generation + 1
  local early, wild, steady = 2601, 2602, 2603
  for _, id in ipairs({ early, wild, steady }) do ns.realm.items[id] = nil end
  -- Three scans in an afternoon.
  for step = 2, 0, -1 do M.Record(early, { { 100 + step, 10 } }, { full = true, t = now - step * 3600 }) end
  -- Five days of scans with the price all over the place.
  local jump = { 1, 2.2, 0.6, 1.9, 0.5, 2.4, 0.7, 1.6, 0.4, 2.0 }
  for step = 30, 0, -1 do
    M.Record(wild, { { 1000 * jump[step % #jump + 1], 10 } }, { full = true, t = now - step * 14400 })
  end
  -- Six days, three scans a day at the same hours, a calm price.
  local startDay = os.date("*t", now - 6 * 86400)
  startDay.hour, startDay.min, startDay.sec = 0, 0, 0
  local base = os.time(startDay)
  for day = 0, 6 do
    for _, hour in ipairs({ 9, 14, 20 }) do
      local t = base + day * 86400 + hour * 3600
      if t <= now then M.Record(steady, { { 500 + (hour == 20 and 25 or 0) + day, 50 } }, { full = true, t = t }) end
    end
  end
  local te, tw, ts = S.Trust(early), S.Trust(wild), S.Trust(steady)
  check(te.state == "early" and not te.forecast and te.short:find("Too early", 1, true), "three scans: too early to forecast (" .. te.short .. ")")
  check(tw.state == "chaotic" and not tw.forecast and tw.short:find("unsettled", 1, true), "a wild price: too unsettled to forecast (" .. tostring(tw.short) .. ")")
  check(ts.state == "ok" and ts.forecast and ts.pattern, "a calm price scanned at the same hours for six days: forecast and pattern shown")
  check(S.Trust(999998).state == "none", "an item without prices is neither")

  -- The side panel: history chart stops at now, the folded view keeps its dots and drops its curves.
  ns.Open(early) RunTimers()
  local side
  for _, fr in ipairs(frames) do if fr.week and fr.chartMode then side = fr end end
  ns.settings.sideChart = "history"
  ns.UI.Refresh() RunTimers()
  local chartFrame
  for _, fr in ipairs(frames) do if fr.plot and fr.clocks then chartFrame = fr end end
  check(chartFrame.held == true and chartFrame.note.text:find("Too early", 1, true) ~= nil, "the price chart says why it has no forecast: " .. chartFrame.note.text)
  ns.settings.sideChart = "week"
  ns.UI.Refresh() RunTimers()
  check(side.week.held and side.week.nLine == 0 and side.week.nDot == 3, "the folded view shows the three scans and no curves")
  check(side.week.readout.text:find("Too early", 1, true) ~= nil and side.week.readout.text:find("/cg guesses", 1, true) ~= nil,
    "its readout gives the reason and the way to see the guess")
  check(J.BestMoment(early, 100) == nil, "no best selling hour is named for it")
  ns.UI.Focus(wild) RunTimers()
  check(side.week.held and side.week.readout.text:find("unsettled", 1, true) ~= nil, "the wild price is held back as unsettled")
  ns.UI.Focus(steady) RunTimers()
  check(not side.week.held and side.week.nLine >= 167, "the calm price gets its curves")
  check(J.BestMoment(steady, 500) ~= nil, "and a best selling hour")
  ns.settings.sideChart = "history"
  ns.UI.Refresh() RunTimers()
  check(chartFrame.held == false, "and a forecast on its chart")
  -- Trends says it in the facts and in the readout.
  ns.UI.Focus(early) RunTimers()
  ns.UI.ShowTrends(true) RunTimers()
  local view
  for _, fr in ipairs(frames) do if fr.options and fr.facts then view = fr end end
  check(view.facts.text:find("Too early to forecast", 1, true) ~= nil, "Trends says it is too early")
  check(view.readout.text:find("would be a guess", 1, true) ~= nil, "and gives no estimate for the selected time")
  -- For curiosity: everything is shown again.
  SlashCmdList.CRAFTGRAPH("guesses") RunTimers()
  check(ns.settings.showGuesses == true and view.readout.text:find("about", 1, true) ~= nil, "/cg guesses shows the estimate anyway")
  ns.UI.ShowTrends(false)
  ns.settings.sideChart = "week"
  ns.UI.Refresh() RunTimers()
  check(not side.week.held and side.week.nLine >= 167 and J.BestMoment(early, 100) ~= nil, "and the curves and the best hour")
  ns.UI.ToggleSources()
  check(ns.UI.sourcesFrame.guess:GetChecked() == true, "the data window has the same switch, ticked")
  ns.UI.sourcesFrame.guess:SetChecked(false)
  ns.UI.sourcesFrame.guess.scripts.OnClick(ns.UI.sourcesFrame.guess)
  check(ns.settings.showGuesses == false, "unticking it hides the guesses again")
  ns.UI.ToggleSources()
  ns.settings.sideChart = "history"
  ns.settings.showGuesses = true
  ns.generation = ns.generation + 1
  for _, id in ipairs({ early, wild, steady }) do ns.realm.items[id] = nil end
end

------------------------------------------------------------------------------
-- Graph lines are coloured by whether the step they lead to earns money.
do
  local V, O = ns.GraphView, ns.Opt
  local product, mat
  for _, row in ipairs((ns.Deals.All())) do
    if row.kind == "craft" then product = row.id break end
  end
  check(product ~= nil, "there is a paying craft to look at")
  local ev = O.Evaluate(product, 1)
  local lean = V.EdgeLean({ from = product })
  check(lean and lean > 0 and near(lean, math.min(1, ev.profit / ev.cost / 0.25), 1e-9), "a paying craft leans to gold: " .. tostring(lean))
  check(V.EdgeLean({ from = 2770 }) == nil, "a line to something that is not crafted keeps its plain colour")
  -- Make the product nearly worthless: the lines to it turn towards red.
  local was = ns.Market.Info(product)
  ns.Market.Record(product, { { 1, 500 } }, { full = true, t = now + 5 })
  local losing = V.EdgeLean({ from = product })
  check(losing and losing < 0, "a craft that loses money leans to red: " .. tostring(losing))
  ns.Open(product) RunTimers()
  local reds = 0
  for _, fr in ipairs(frames) do
    if fr.lines and fr.canvas then
      for _, line in ipairs(fr.lines) do reds = reds + 1 end
    end
  end
  check(reds > 0, "the graph draws its lines")
  -- Lights drift along the lines that earn, towards the product.
  do
    local paying
    for _, row in ipairs((ns.Deals.All())) do
      if row.kind == "craft" and row.id ~= product and (V.EdgeLean({ from = row.id }) or 0) >= 0.3 then paying = row.id break end
    end
    if paying then
      ns.Open(paying) RunTimers()
      local gv
      for _, fr in ipairs(frames) do if fr.lines and fr.canvas and fr.flows then gv = fr end end
      check(gv and #gv.flows > 0 and gv.pulses[1] and gv.pulses[1].dot:IsShown(), "a paying step has a light on its line (" .. (gv and #gv.flows or 0) .. ")")
      local x0 = gv.pulses[1].x
      clock = clock + 0.4
      gv.scripts.OnUpdate(gv, 0.4)
      check(gv.pulses[1].x ~= x0, "the light moves with time")
      local f = gv.flows[1]
      clock = 0
      f.offset = 0.1
      V.Animate(gv)
      local early = gv.pulses[1].x
      f.offset = 0.6
      V.Animate(gv)
      check(gv.pulses[1].x < early, "it travels from the material towards the thing made of it")
      -- Each line says what one craft of the thing it leads to earns.
      do
        local one = ns.Opt.Evaluate(paying, 1)
        local text = ns.UI.EdgeProfit({ from = paying })
        check(text and text:find("/craft", 1, true) and text:find("+", 1, true) and one.profit > 0, "a paying craft's line shows its profit per craft: " .. tostring(text))
        check(ns.UI.EdgeProfit({ from = 2770 }) == nil, "a raw material has none")
        local function count()
          local onLines, onCards, compactCards = 0, 0, 0
          for _, label in ipairs(gv.labels) do
            if label.shown and label.text:find("/craft", 1, true) then onLines = onLines + 1 end
          end
          for _, fr in ipairs(frames) do
            if fr.node and fr.shown and fr.bigLine and fr.compact then
              compactCards = compactCards + 1
              if fr.bigLine.text:find("/craft", 1, true) then onCards = onCards + 1 end
            end
          end
          return onLines, onCards, compactCards
        end
        -- Zoom all the way in: full cards, profit on the lines.
        for _ = 1, 12 do gv.scripts.OnMouseWheel(gv, 1) end
        local onLines, onCards, compactCards = count()
        check(gv.scale >= V.DENSE_BELOW and onLines >= 1 and compactCards == 0, "zoomed in, it is written on the lines (" .. onLines .. ") and cards are full")
        -- Zoom out: cards show the name and one line with the profit; lines only the amount.
        for _ = 1, 12 do gv.scripts.OnMouseWheel(gv, -1) end
        onLines, onCards, compactCards = count()
        check(gv.scale < V.DENSE_BELOW and compactCards >= 2 and onCards >= 1 and onLines == 0,
          "zoomed out, cards show less and carry the profit themselves (" .. compactCards .. " cards, " .. onCards .. " with profit)")
        local bare = true
        for _, label in ipairs(gv.labels) do
          if label.shown and label.text ~= "" and not label.text:match("^x[%d%.]+$") then bare = false end
        end
        check(bare, "and the lines carry only the amount")
        for _ = 1, 4 do gv.scripts.OnMouseWheel(gv, 1) end
      end
      -- Lines towards the biggest earner on screen are the thickest.
      do
        local graph = ns.Graph.Build(paying, {})
        local gains, top, topId, lowId = {}, 0, nil, nil
        for _, e in ipairs(graph.edges) do
          local g = V.EdgeGain(e)
          gains[e.from] = g
          if g > top then top, topId = g, e.from end
        end
        for id, g in pairs(gains) do
          if g > 0 and g < top * 0.5 then lowId = id end
        end
        check(top > 0 and V.EdgeGain({ from = 2770 }) == 0, "what a line's product earns in all is known, and nothing for a raw material")
        local shares = {}
        for _, fl in ipairs(gv.flows) do shares[#shares + 1] = fl.share end
        table.sort(shares)
        check(#shares > 0 and shares[#shares] <= 1 and shares[1] >= 0, "each lit line knows its share of the best earner")
        if lowId then
          check(math.sqrt(gains[lowId] / top) < 0.75, "a smaller earner gets a clearly thinner line")
        end
      end
      SlashCmdList.CRAFTGRAPH("flow") RunTimers()
      check(ns.settings.flowGlow == false and #gv.flows == 0 and not gv.pulses[1].dot:IsShown(), "/cg flow switches the lights off")
      SlashCmdList.CRAFTGRAPH("flow") RunTimers()
      check(ns.settings.flowGlow == true and #gv.flows > 0, "and on again")
    end
  end
  if was and was.ladder then
    local raw = {}
    for i = 1, #was.ladder, 2 do raw[#raw + 1] = { was.ladder[i], was.ladder[i + 1] } end
    ns.Market.Record(product, raw, { full = true, t = now + 400 })
  end
end

------------------------------------------------------------------------------
-- Found in the game's own saved data: a full scan arrives in pieces, and a
-- piece must not be recorded as a scan.
do
  local M = ns.Market
  local a, b = 2604, 2605
  ns.realm.items[a], ns.realm.items[b] = nil, nil
  M.Record(b, { { 77, 9 } }, { full = true, t = now - 3600 })
  local list = { { a, 5, 50 } }
  local oldNum, oldInfo = C_AuctionHouse.GetNumReplicateItems, C_AuctionHouse.GetReplicateItemInfo
  C_AuctionHouse.GetNumReplicateItems = function() return #list end
  C_AuctionHouse.GetReplicateItemInfo = function(i)
    local r = list[i + 1]
    return "n", 1, r[2], 1, true, 1, "", 0, 0, r[3], 0, nil, nil, r[4], nil, 0, r[1], true
  end
  M.lastFingerprint = nil
  ns.db.lastFullCount = nil
  local before = #ns.db.log
  -- The first piece arrives, then the rest, before the list has settled.
  FireEvent("REPLICATE_ITEM_LIST_UPDATE")
  list = { { a, 5, 50, "Anna" }, { a, 5, 55, "Anna" }, { b, 9, 693, "Bo" }, { b, 3, 240, "Bo" }, { b, 3, 240, "Cy" } }
  FireEvent("REPLICATE_ITEM_LIST_UPDATE")
  RunTimers()
  local arrivals = 0
  for i = before + 1, #ns.db.log do
    if ns.db.log[i]:find("full scan list arrived", 1, true) then arrivals = arrivals + 1 end
  end
  check(arrivals == 1, "a list that arrives in two pieces is read once, when it has settled (" .. arrivals .. ")")
  local infoB = M.Info(b)
  check(infoB.price == 77 and infoB.total == 15, "the item in the later piece has its price, not \"none listed\": " .. tostring(infoB.price))
  local zeros = 0
  local h = M.History(M.Get(b))
  for i = 1, #h, 4 do if h[i + 1] == 0 then zeros = zeros + 1 end end
  check(zeros == 0, "no false \"none listed\" point is written")
  check(M.Get(b).sn == 2, "the number of sellers is kept apart from the sales count: " .. tostring(M.Get(b).sn))
  check(ns.db.lastFullCount == 5, "the length of the last complete list is remembered")
  C_AuctionHouse.GetNumReplicateItems, C_AuctionHouse.GetReplicateItemInfo = oldNum, oldInfo
  M.lastFingerprint = nil

  -- Old data: false "none listed" points between real prices are removed once.
  local db = { realms = { R = { items = {
    [1] = { h = { now - 40000, 3900, 3900, 27, now - 39100, 0, 0, 0, now - 39000, 3900, 3900, 28,
                  now - 38100, 0, 0, 0, now - 38000, 3900, 3900, 28,
                  now - 20000, 0, 0, 0, now, 4000, 4000, 5 },
            v = 343, vn = 0.5, sa = 0, sn = 2.99, sb = 0.01, sl = { "Anna", 5, "Bo", 2 } },
  } } } }
  local removed = M.Repair(db)
  local fixed = db.realms.R.items[1]
  local all = M.History(fixed)
  check(removed == 2 and #all / 4 == 5, "two false points go, the real ones stay: " .. removed .. " removed, " .. #all / 4 .. " left")
  local keptEmpty = false
  for i = 1, #all, 4 do if all[i] == now - 20000 and all[i + 1] == 0 then keptEmpty = true end end
  check(keptEmpty, "a \"none listed\" far from any price is believed and kept")
  check(fixed.v == nil and fixed.sa == nil and fixed.sb == nil and fixed.sn == 2, "turnover built on the pieces starts again; sellers are counted afresh")
  check(M.Repair(db) == 0 and db.dataVersion == 2, "the repair runs once")
  ns.realm.items[a], ns.realm.items[b] = nil, nil
end

------------------------------------------------------------------------------
-- Is now a good time to sell? Lightly smoothed scans against the week.
do
  local M, S = ns.Market, ns.Stats
  local id = 2606
  local function fill(lastHours)
    ns.realm.items[id] = nil
    -- Five days at 100, every three hours; then the last hours as given.
    for step = 40, 2, -1 do M.Record(id, { { 100, 20 } }, { full = true, t = now - step * 10800 }) end
    for i, price in ipairs(lastHours) do
      M.Record(id, { { price, 20 } }, { full = true, t = now - (#lastHours - i) * 2400 })
    end
    ns.generation = ns.generation + 1
    return S.SellSignal(id)
  end
  local up = fill({ 118, 122, 120 })
  check(up.verdict == "good" and near(up.usual, 100) and up.ratio > 0.06 and up.ratio < 0.22,
    string.format("a price that rose a fifth an hour ago is a good time to sell (%.0f%% over %s)", (up.ratio or 0) * 100, tostring(up.usual)))
  check(up.recent > 106 and up.recent < 121, "\"now\" is the last three hours averaged, each price for as long as it stood: " .. tostring(up.recent))
  local down = fill({ 84, 80, 82 })
  check(down.verdict == "poor", "a price a fifth under is not")
  local flat = fill({ 101, 99, 102 })
  check(flat.verdict == "fair", "a price about where it usually is is fair")
  local spike = fill({ 100, 100, 160 })
  check(spike.recent < 125, "one high scan among three does not swing it far: " .. tostring(spike.recent))
  -- Too little to compare, or too old.
  ns.realm.items[id] = nil
  for step = 3, 0, -1 do M.Record(id, { { 100, 20 } }, { full = true, t = now - step * 1800 }) end
  ns.generation = ns.generation + 1
  local few = S.SellSignal(id)
  check(few.verdict == nil and few.why:find("Too few scans", 1, true), "four scans in two hours give no verdict: " .. tostring(few.why))
  ns.realm.items[id] = nil
  for step = 30, 20, -1 do M.Record(id, { { 100, 20 } }, { full = true, t = now - step * 7200 }) end
  ns.generation = ns.generation + 1
  check(S.SellSignal(id).verdict == nil and S.SellSignal(id).why:find("over a day old", 1, true), "a scan over a day old gives none either")
  check(S.SellSignal(999997).verdict == nil, "nor does an item without prices")
  -- In the list and in its tooltip.
  fill({ 118, 122, 120 })
  check(ns.UI.SellSignalText({ id = id, kind = "flip" }):find("now", 1, true) ~= nil, "the list says \"now\"")
  check(ns.UI.SellSignalText({ id = id, kind = "tovendor" }) == "", "a sale to a vendor has no such signal")
  local lines = ns.UI.SellSignalLines(id)
  check(lines[1][1]:find("A good time to sell", 1, true) ~= nil and lines[1][1]:find("% over", 1, true) ~= nil,
    "the tooltip gives the reason: " .. lines[1][1])
  fill({ 84, 80, 82 })
  check(ns.UI.SellSignalText({ id = id, kind = "craft" }):find("wait", 1, true) ~= nil, "a poor time reads \"wait\"")
  ns.realm.items[id] = nil
  ns.generation = ns.generation + 1
  ns.UI.ShowWorth(true) RunTimers()
  local view
  for _, f in ipairs(frames) do if f.filters and f.summary then view = f end end
  local seen = false
  for _, row in ipairs(view.rows) do
    if row.shown and row.data and row.signal then seen = true end
  end
  check(seen, "every row of the list carries the signal")
  ns.UI.ShowWorth(false)
end

------------------------------------------------------------------------------
-- Sharing prices between players as JSON text.
do
  local M = ns.Market
  local a, b, c = 2607, 2608, 2609
  for _, id in ipairs({ a, b, c }) do ns.realm.items[id] = nil end
  ns.realm.sharedBy = nil
  M.Record(a, { { 50, 10 }, { 60, 5 } }, { full = true, t = now - 600 })
  M.Record(b, { { 200, 3 } }, { full = true, t = now - 600 })
  M.Record(c, { { 9, 1 } }, { full = true, t = now - 3 * 86400 })           -- too old to send
  local text, count = M.Export()
  check(count >= 2 and text:find('"format":"craftgraph-prices"', 1, true) and text:find('"version":1', 1, true),
    "export is JSON that names its format and version (" .. count .. " items)")
  check(text:find('"' .. a .. '":{"t":' .. (now - 600) .. ',"n":15,"l":[50,10,60,5]}', 1, true) ~= nil, "an item carries its scan time, amount and ladder")
  check(text:find('"' .. c .. '":', 1, true) == nil, "scans over a day old are not sent")
  local parsed = M.ParseJSON(text)
  check(type(parsed) == "table" and parsed.realm == ns.realmKey and parsed.items[tostring(b)].l[1] == 200, "the text reads back as JSON")
  check(M.ParseJSON('{"a":[1,2.5,-3e2,"x\\"y",true,false,null],"b":{}}').a[4] == 'x"y', "the reader copes with the usual JSON")
  check(M.ParseJSON("{oops") == nil, "and says so when it is not JSON")

  -- From here on the text plays the part of what a friend sent.
  text = text:gsub('"from":"[^"]*"', '"from":"Friend"')
  -- The friend's side: none of these items scanned here.
  for _, id in ipairs({ a, b }) do ns.realm.items[id] = nil end
  ns.generation = ns.generation + 1
  check(M.Info(a) == nil, "before importing, the item is unknown here")
  local result = M.Import(text)
  check(result.ok and result.taken == count and result.text:find("Imported " .. count .. " prices from", 1, true),
    "importing says how many prices came in and from whom: " .. result.text)
  local info = M.Info(a)
  check(info and info.price == 50 and info.total == 15 and info.shared and info.age == 600, "an imported price is used, marked as shared, with its real age")
  check(#M.Series(a) == 1 and M.Get(a) == nil, "it shows as a price point without entering your own history")
  -- Importing the same again changes nothing, and says so.
  local again = M.Import(text)
  check(not again.ok and again.older == count and again.text:find("no newer than what you had", 1, true), "the same data twice: " .. again.text)
  -- Your own newer scan wins.
  M.Record(a, { { 44, 7 } }, { full = true, t = now - 60 })
  check(M.Info(a).price == 44 and not M.Info(a).shared, "your own newer scan takes precedence")
  -- The switch.
  M.SetSource("Shared", false)
  check(M.Info(b) == nil, "switched off, shared prices are not used")
  M.SetSource("Shared", true)
  check(M.Info(b).price == 200, "switched on, they are")
  -- Things that must be refused, each with a reason.
  check(not M.Import("").ok and M.Import("").text:find("empty", 1, true), "an empty box is refused")
  check(M.Import("hello there").text:find("not CraftGraph data", 1, true) ~= nil, "text that is not JSON is refused")
  check(M.Import('{"format":"something-else","items":{}}').text:find("not CraftGraph prices", 1, true) ~= nil, "other JSON is refused")
  local other = text:gsub('"realm":"[^"]*"', '"realm":"Elsewhere - Horde"')
  local refused = M.Import(other)
  check(not refused.ok and refused.otherRealm and refused.text:find("another auction house", 1, true), "prices for another auction house are refused at first")
  local future = '{"format":"craftgraph-prices","version":2,"realm":"' .. ns.realmKey .. '","from":"Zed","made":' .. now
    .. ',"extra":{"x":1},"items":{"' .. c .. '":{"t":' .. (now - 100) .. ',"l":[70,2],"colour":"blue"},"bad":{"t":1},"'
    .. b .. '":{"t":' .. (now - 30 * 86400) .. ',"l":[1,1]}}}'
  local mixed = M.Import(future)
  check(mixed.ok and mixed.taken == 1 and mixed.bad == 1 and mixed.tooOld == 1 and mixed.text:find("newer CraftGraph", 1, true),
    "a newer format with unknown fields is read as far as it is understood: " .. mixed.text)

  -- The window: export fills the box, import reports under it.
  ns.UI.ShowShare("export")
  local f = ns.UI.shareFrame
  check(f:IsShown() and f.box.text:find("craftgraph-prices", 1, true) and f.result.text:find("Exported", 1, true), "the share window exports into its box: " .. f.result.text)
  f.box:SetText("not json at all")
  ns.UI.ShareImport()
  check(f.result.text:find("not CraftGraph data", 1, true) ~= nil, "a failed import says why under the box")
  f.box:SetText(other)
  ns.UI.ShareImport()
  check(f.result.text:find("Press Import again", 1, true) ~= nil, "another auction house: asked to confirm")
  M.ClearShared()
  ns.UI.ShareImport()
  check(f.result.text:find("Imported", 1, true) ~= nil and ns.realm.sharedBy ~= nil, "pressing Import again takes it: " .. f.result.text)
  SlashCmdList.CRAFTGRAPH("import")
  check(f.box.text == "" and f.result.text:find("Last time", 1, true) ~= nil, "/cg import opens an empty box and recalls the last result")

  -- A file brought in from outside the game is imported once at login.
  M.ClearShared()
  ns.realm.sharedFilesSeen = nil
  ns.SharedFile = text
  ns.Fire("LOGIN")
  check(ns.realm.sharedBy and M.lastImport and M.lastImport.taken == count, "a shared file is taken in at login")
  M.ClearShared()
  ns.Fire("LOGIN")
  check(ns.realm.sharedBy == nil, "and not a second time")

  -- Several players: each is a source of their own, by in-game name.
  local function from(name, github, price, age)
    return '{"format":"craftgraph-prices","version":1,"realm":"' .. ns.realmKey .. '","from":"' .. name .. '","github":"' .. github
      .. '","made":' .. (now - age) .. ',"items":{"' .. b .. '":{"t":' .. (now - age) .. ',"n":4,"l":[' .. price .. ',4]}}}'
  end
  ns.realm.sharedFilesSeen = nil
  ns.SharedFile = { from("Anwen", "anwen-gh", 210, 3600), from("Borin", "borin-gh", 190, 600) }
  ns.Fire("LOGIN")
  local people = M.Contributors()
  check(#people == 2 and people[1].name == "Anwen" and people[2].name == "Borin" and people[2].github == "borin-gh",
    "two players' files give two sources, by in-game name")
  check(M.Info(b).price == 190 and M.Info(b).sharedBy == "Borin", "the newest of them is used and named: " .. tostring(M.Info(b).sharedBy))
  M.SetContributor("Borin", false)
  check(M.Info(b).price == 210 and M.Info(b).sharedBy == "Anwen", "switch one player off and the other's price shows")
  ns.UI.ToggleSources()
  local sf = ns.UI.sourcesFrame
  check(sf.people[1].name == "Anwen" and sf.people[2].name == "Borin" and sf.people[2].check:GetChecked() == false
    and sf.people[2].label.text:find("github: borin-gh", 1, true), "the data sources window lists each player with a switch")
  sf.people[2].check:SetChecked(true)
  sf.people[2].check.scripts.OnClick(sf.people[2].check)
  check(M.Info(b).price == 190, "ticking the player there switches them on again")
  ns.UI.ToggleSources()
  M.ClearShared("Borin")
  check(#M.Contributors() == 1, "one player's prices can be forgotten on their own")
  -- Your own prices are never imported, but you are shown as being there.
  do
    local me = UnitName("player")
    local mine = from(me, "my-gh", 150, 300)
    local r = M.Import(mine)
    check(not r.ok and r.own and r.text:find("your own prices", 1, true), "your own shared prices are refused: " .. r.text)
    check(M.Info(b).price == 210 and M.Info(b).sharedBy == "Anwen", "and change no price")
    local list = M.Contributors()
    check(list[1].self and list[1].name == me and list[1].items == 1 and #list == 2, "you are listed first, as yourself")
    ns.realm.sharedFilesSeen = nil
    ns.SharedFile = { mine, from("Anwen", "anwen-gh", 205, 100) }
    ns.Fire("LOGIN")
    check(M.Info(b).price == 205 and #M.Contributors() == 2, "a fetched set that includes your own file takes in only the others")
    ns.UI.ToggleSources()
    local sf2 = ns.UI.sourcesFrame
    check(sf2.people[1].label.text:find("You (" .. me .. ")", 1, true) and sf2.people[1].check.enabled == false,
      "the window shows you without a switch: " .. sf2.people[1].label.text)
    ns.UI.ToggleSources()
  end
  M.ClearShared()
  ns.SharedFile = false
  f:Hide()
  for _, id in ipairs({ a, b, c }) do ns.realm.items[id] = nil end
  ns.generation = ns.generation + 1
end

------------------------------------------------------------------------------
-- The Data page: sources, import and export, GitHub, and the sales seen.
do
  local M = ns.Market
  local id = 2610
  ns.realm.items[id] = nil
  ns.realm.sharedBy, ns.realm.sharedSelf = nil, nil
  local function auctions(list)
    local out = {}
    for _, a in ipairs(list) do
      for _ = 1, a.n do out[#out + 1] = { a.unit, a.count, a.owner, a.band } end
    end
    return out
  end
  M.TrackSales(id, auctions({ { n = 6, unit = 100, count = 20, owner = "Anna", band = 3 }, { n = 2, unit = 90, count = 5, owner = "Cy", band = 0 } }), now - 1800)
  M.TrackSales(id, auctions({ { n = 3, unit = 100, count = 20, owner = "Anna", band = 3 } }), now)
  ns.generation = ns.generation + 1
  local log = M.SalesLog(id)
  check(#log == 3 and log[1].owner == "Anna" and log[1].count == 20 and log[1].unit == 100 and log[1].sure > 0.8 and log[1].t == now,
    "the three stacks of Anna's that vanished are listed as sold, with seller, size, price and how sure (" .. #log .. ")")
  local everything = M.SalesLog()
  local mine = 0
  for _, e in ipairs(everything) do if e.id == id then mine = mine + 1 end end
  check(mine == 3, "the list of everything includes them")
  -- Cy's two, with under half an hour left, ran out: not listed.
  local cy = 0
  for _, e in ipairs(log) do if e.owner == "Cy" then cy = cy + 1 end end
  check(cy == 0, "auctions that ran out are not listed as sales")

  ns.Open(id) RunTimers()
  local page
  for _, f in ipairs(frames) do if f.tabs and f.panes and f.tabs.github then page = f end end
  check(page ~= nil and not page:IsShown(), "the Data page exists and starts closed")
  ns.UI.ShowData()
  check(page:IsShown() and page.panes.sources:IsShown() and ns.UI.sourcesFrame:IsShown(), "the Data button opens it on the data sources")
  page.tabs.share.scripts.OnClick(page.tabs.share)
  check(page.panes.share:IsShown() and not page.panes.sources:IsShown() and ns.UI.shareFrame:IsShown(), "Import and export is a page of its own")
  page.tabs.github.scripts.OnClick(page.tabs.github)
  local gh = ns.UI.githubPane
  check(page.panes.github:IsShown() and gh.status.text:find("Not connected", 1, true) and gh.boxes[2].text:find("data-pull", 1, true),
    "GitHub is a page of its own; with nothing fetched it says so and gives the commands: " .. gh.status.text)
  local function from(name, github, age)
    return '{"format":"craftgraph-prices","version":1,"realm":"' .. ns.realmKey .. '","from":"' .. name .. '","github":"' .. github
      .. '","made":' .. (now - age) .. ',"items":{"' .. id .. '":{"t":' .. (now - age) .. ',"n":4,"l":[95,4]}}}'
  end
  M.Import(from("Anwen", "anwen-gh", 600))
  RunTimers()
  check(gh.status.text:find("fetching what others share", 1, true) and gh.people.text:find("Anwen", 1, true), "with another player's prices it names them: " .. gh.people.text)
  M.Import(from(UnitName("player"), "me-gh", 300))
  RunTimers()
  check(gh.status.text:find("You are sharing", 1, true) and gh.status.text:find("me-gh", 1, true), "and when your own are out there it says you are sharing: " .. gh.status.text)
  -- Sales seen: all items, then only the one in focus (also from the side panel).
  page.tabs.sales.scripts.OnClick(page.tabs.sales)
  local sp = ns.UI.salesPane
  check(page.panes.sales:IsShown() and sp.count >= 3 and sp.summary.text:find("Sales seen", 1, true), "Sales seen lists them (" .. sp.count .. ")")
  local side
  for _, f in ipairs(frames) do if f.week and f.chartMode then side = f end end
  ns.UI.ShowData()
  check(not page:IsShown(), "the Data button puts the page away again")
  side.salesHit.scripts.OnClick(side.salesHit)
  check(page:IsShown() and page.panes.sales:IsShown() and sp.count == 3 and sp.rows[1].seller.text == "Anna" and sp.rows[1].count.text == "x20",
    "clicking supply and demand in the side panel lists this item's sales: " .. sp.count)
  sp.filter.scripts.OnClick(sp.filter)
  check(sp.count >= 3 and sp.filter.text == "This item only", "the filter switches back to everything")
  sp.rows[1].scripts.OnClick(sp.rows[1], "LeftButton")
  check(not page:IsShown(), "clicking a sale opens its item on the graph")
  SlashCmdList.CRAFTGRAPH("sales")
  check(page:IsShown() and page.panes.sales:IsShown(), "/cg sales opens the list")
  SlashCmdList.CRAFTGRAPH("github")
  check(page.panes.github:IsShown(), "/cg github opens that page")
  M.SetSource("Sales", false)
  check(#M.SalesLog(id) == 0, "with the sales source off the list is empty")
  M.SetSource("Sales", true)
  ns.UI.ShowData()
  M.ClearShared()
  ns.realm.items[id] = nil
  ns.generation = ns.generation + 1
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1 print(line) end end
  check(errors == 0, "no errors on the Data page")
end

------------------------------------------------------------------------------
-- Ranking what to make: score, groups, the golden halo, the buy slider.
do
  local O, P, V = ns.Opt, ns.Player, ns.GraphView
  ns.settings.buyRatio, ns.settings.rankBy = 1, "total"
  local product, mat
  for _, row in ipairs((ns.Deals.All())) do
    local one = row.kind == "craft" and O.Evaluate(row.id, 1)
    if one and one.profit and one.profit > 0 then
      product, mat = row.id, nil
      for item in pairs(O.Evaluate(row.id, row.qty).plan.buy) do mat = item break end
      if mat then break end
    end
  end
  check(product and mat, "there is a craft that pays per craft, with a material to buy")
  local oldCount, oldBank = P.ItemCount, P.BankCount
  P.ItemCount, P.BankCount = function() return 0 end, function() return 0 end
  P.version = P.version + 1
  local rank = O.Rank(product)
  check(rank and rank.perCraft > 0 and rank.safeCraft <= rank.perCraft and rank.safeTotal <= rank.total,
    "a craft is scored cautiously: the estimate less its margin")
  check(rank.group == "buy" and rank.own == 0 and rank.qty >= rank.best and rank.qty % rank.yield == 0 and rank.qty > 0 and rank.buyCost > 0,
    "with nothing in the bags it needs buying, and at 100% the best amount is planned (" .. rank.qty .. ")")
  check(O.Rank(2770) == nil, "a raw material has no rank")
  -- Own stock for exactly three crafts.
  local r = O.Recipe(O.BestRecipe(product))
  local need = {}
  for i = 1, #r[7], 2 do need[r[7][i]] = r[7][i + 1] * 3 end
  P.ItemCount = function(id) return need[id] or 0 end
  P.version = P.version + 1
  local ready = O.Rank(product)
  check(ready.group == "ready" and ready.own == 3 * ready.yield, "with materials for three crafts it is ready: makes " .. ready.own)
  ns.settings.buyRatio = 0
  local own = O.Rank(product)
  check(own.qty == own.own and own.buyCost >= 0 and own.total <= ready.total + 1,
    "at 0% only what the bags cover is counted (" .. own.qty .. ")")
  ns.settings.buyRatio = 0.5
  local half = O.Rank(product)
  check(half.qty >= own.qty and half.qty <= math.max(ready.best, own.own), "at 50% the amount lies between the two (" .. half.qty .. ")")
  ns.settings.rankBy = "craft"
  check(O.Rank(product).score == math.max(0, O.Rank(product).safeCraft), "ranked per craft, the score is the cautious profit of one craft")
  ns.settings.rankBy, ns.settings.buyRatio = "total", 1
  check(O.Rank(product).score == math.max(0, O.Rank(product).safeTotal), "ranked in all, the cautious profit of the whole amount")

  -- The graph: ready things first, then what needs buying, then unknown recipes; the best is the most golden.
  local graph = ns.Graph.Build(mat, {})
  local order, lastGroup, sorted = {}, 0, true
  local lastScore = math.huge
  for _, n in ipairs(graph.nodes) do
    if n.id and n.side == -1 and n.layer == 1 then
      local rk = O.Rank(n.id)
      local g = rk and O.RANK_GROUPS[rk.group] or 4
      if g < lastGroup then sorted = false end
      if g == lastGroup and rk and rk.score > lastScore + 1e-6 then sorted = false end
      lastGroup, lastScore = g, rk and rk.score or -1
      order[#order + 1] = n.id
    end
  end
  check(#order >= 1 and sorted, "the things made from it are grouped and then sorted by score (" .. #order .. ")")
  ns.Open(mat) RunTimers()
  local gv
  for _, fr in ipairs(frames) do if fr.lines and fr.canvas and fr.slider then gv = fr end end
  local top, golds, ok = gv.topCard, 0, true
  for _, fr in ipairs(frames) do
    if fr.node and fr.shown and fr.gild and fr.rank then
      if fr.gold > 1 + 1e-9 or fr.gold < 0 then ok = false end
      if fr.gold > 0 then golds = golds + 1 end
    end
  end
  check(top and near(top.gold, 1) and ok and golds >= 1, "the best card on screen is the most golden (" .. golds .. " gilded)")
  local before = top.gild.alpha
  clock = clock + 0.7
  gv.scripts.OnUpdate(gv, 0.7)
  check(top.gild.alpha ~= before and top.gild.alpha >= 0.6 and top.gild.alpha <= 1, "its halo breathes: " .. tostring(top.gild.alpha))
  clock = 3.4 * 100 + 0.5
  V.Animate(gv)
  local first = top.glint
  clock = clock + 0.3
  V.Animate(gv)
  check(first and top.glint and top.glint > first, "a glint crosses the best card, left to right")
  clock = 3.4 * 100 + 2.5
  V.Animate(gv)
  check(top.glint == nil, "and rests between passes")
  -- The slider and the rank button.
  check(gv.sliderValue.text:find("100%", 1, true) ~= nil and gv.rankButton.text == "Rank: in all", "the controls show the setting: " .. gv.sliderValue.text)
  gv.SetRatio(0.52)
  check(ns.settings.buyRatio == 0.5 and gv.sliderValue.text:find("50%", 1, true) ~= nil, "the slider moves in steps: " .. gv.sliderValue.text)
  gv.SetRatio(0)
  check(gv.sliderValue.text:find("own stock only", 1, true) ~= nil, "at nothing it says own stock only")
  gv.rankButton.scripts.OnClick(gv.rankButton) RunTimers()
  check(ns.settings.rankBy == "craft" and gv.rankButton.text == "Rank: per craft", "the button switches to per craft")
  gv.rankButton.scripts.OnClick(gv.rankButton) RunTimers()
  gv.SetRatio(1)
  for _, fr in ipairs(frames) do
    if fr.node and fr.shown and fr.scripts.OnEnter and fr.rank then fr.scripts.OnEnter(fr) fr.scripts.OnLeave(fr) end
  end
  -- A recipe that is not known is greyed but still ranked among its like.
  local oldKnows = P.Knows
  P.Knows = function() return false end
  P.version = P.version + 1
  local unknown = O.Rank(product)
  check(unknown.group == "unknown" and unknown.score >= 0, "a recipe you do not know is in a group of its own, still scored")
  ns.UI.Refresh() RunTimers()
  local greyed = false
  for _, fr in ipairs(frames) do
    if fr.node and fr.shown and fr.rank and fr.rank.group == "unknown" and fr.greyed then greyed = true end
  end
  check(greyed, "and its card is greyed")
  P.Knows, P.ItemCount, P.BankCount = oldKnows, oldCount, oldBank
  P.version = P.version + 1
  ns.UI.Refresh() RunTimers()
  local errors = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then errors = errors + 1 print(line) end end
  check(errors == 0, "no errors in the ranking")
end

------------------------------------------------------------------------------
-- A recipe not learned: marked on the icon with the item that teaches it.
do
  local O, P = ns.Opt, ns.Player
  local taught = 0
  for _ in pairs(ns.Data.teaches) do taught = taught + 1 end
  check(taught > 1000, "the data knows which item teaches a recipe (" .. taught .. " recipes)")
  -- A profession the player has and has read; one of its recipes, with a teaching item, not learned.
  local skills = P.Skills()
  local _, info = P.Worth()
  local spell, product, teacher
  for s2, r in pairs(ns.Data.recipes) do
    if skills[r[1]] and not info.unverified[r[1]] and ns.Data.teaches[s2] and O.BestRecipe(r[3]) == s2
      and ns.Data.items[ns.Data.teaches[s2]] then
      spell, product, teacher = s2, r[3], ns.Data.teaches[s2]
      break
    end
  end
  check(spell ~= nil, "there is a recipe of a read profession that an item teaches")
  local oldKnows = P.Knows
  P.Knows = function(sp) if sp == spell then return false end return oldKnows(sp) end
  P.version = P.version + 1
  check(P.RecipeState(spell) == "unlearned", "a recipe of your profession that you lack is \"unlearned\": " .. P.RecipeState(spell))
  local sp, t = P.Unlearned(product)
  check(sp == spell and t == teacher, "its product names the recipe and the item that teaches it")
  check(P.Unlearned(2770) == nil, "a raw material has nothing to learn")
  check(P.TeacherText(teacher):find(ns.ItemName(teacher), 1, true) ~= nil and P.TeacherText(nil):find("trainer", 1, true) ~= nil,
    "where to get it is said in words: " .. P.TeacherText(teacher))
  ns.Market.Record(teacher, { { 12345, 1 } }, { full = true, t = now })
  check(P.TeacherText(teacher):find("at auction", 1, true) ~= nil, "with its auction price when it has one: " .. P.TeacherText(teacher))
  -- On the graph card and in the side panel.
  ns.Open(product) RunTimers()
  local card, side
  for _, fr in ipairs(frames) do
    if fr.node and fr.node.id == product and fr.teach then card = fr end
    if fr.week and fr.chartMode then side = fr end
  end
  check(card and card.teach:IsShown() and card.teach.teacher == teacher, "the card carries the mark, showing the teaching item")
  check(side.teach:IsShown() and side.teach.teacher == teacher, "and so does the side panel")
  card.teach.scripts.OnEnter(card.teach) card.teach.scripts.OnLeave(card.teach)
  card.teach.scripts.OnClick(card.teach)
  RunTimers()
  local focused = false
  for _, fr in ipairs(frames) do if fr.node and fr.shown and fr.node.id == teacher then focused = true end end
  check(focused, "clicking the mark looks the teaching item up")
  -- Learned: the mark goes.
  P.Knows = oldKnows
  P.version = P.version + 1
  ns.Open(product) RunTimers()
  check(P.RecipeState(spell) ~= "unlearned" or not oldKnows(spell), "state follows what is learned")
  if oldKnows(spell) then
    check(not card.teach:IsShown() and not side.teach:IsShown(), "once learned the mark is gone")
  end
  -- A profession the player does not have is not marked.
  local foreign
  for s2, r in pairs(ns.Data.recipes) do
    if not skills[r[1]] then foreign = s2 break end
  end
  if foreign then check(P.RecipeState(foreign) == "noskill", "a recipe of a profession you lack is not \"unlearned\"") end
  ns.realm.items[teacher] = nil
  ns.generation = ns.generation + 1
end

------------------------------------------------------------------------------
-- The chart's row of sun and moon icons
do
  local f = ns.Chart.Create(UIParent)
  -- Midnight today by this machine's clock, so the hours below are local.
  local t = os.date("*t", 1794300000)
  local midnight = os.time({ year = t.year, month = t.month, day = t.day, hour = 0 })
  local function Suns(pool, n)
    local suns, moons = 0, 0
    for i = 1, n do
      local a = pool[i].coord
      if a == 0 then suns = suns + 1 else moons = moons + 1 end
    end
    return suns, moons
  end
  -- Record the half of the texture each icon shows.
  local function Watch()
    for _, icon in ipairs(f.clocks) do
      if not icon.watched then
        icon.watched = true
        icon.SetTexCoord = function(self, left) self.coord = left end
      end
    end
  end
  -- One day, 320 wide: an icon every 3 hours, nights shaded at both ends.
  ns.Chart.DrawClock(f, midnight, midnight + 86400, 320, 100) Watch()
  local n, nights, step = ns.Chart.DrawClock(f, midnight, midnight + 86400, 320, 100)
  check(step == 3, "one day across 320px puts an icon every 3 hours (" .. step .. ")")
  check(n == 7, "icons at 3, 6 ... 21 o'clock; the edges are left clear (" .. n .. ")")
  local suns, moons = Suns(f.clocks, n)
  check(suns == 5 and moons == 2, "6 to 18 are suns, 3 and 21 are moons (" .. suns .. "/" .. moons .. ")")
  check(nights == 2, "the night before and the night after are shaded (" .. nights .. ")")
  check(f.clockLabels[1]:GetText() == "3", "each hour icon has its hour beside it")
  -- Two weeks: one sun per day at noon, no moons.
  n, nights, step = ns.Chart.DrawClock(f, midnight, midnight + 14 * 86400, 320, 100)
  Watch()
  n, nights, step = ns.Chart.DrawClock(f, midnight, midnight + 14 * 86400, 320, 100)
  suns, moons = Suns(f.clocks, n)
  check(step == 24 and n == 14 and moons == 0, "two weeks: a sun at each noon (" .. n .. ", step " .. step .. ")")
  check(nights == 15, "two weeks: every night shaded (" .. nights .. ")")
  check(not f.clocks[15] or not f.clocks[15]:IsShown(), "icons no longer needed are hidden")
  -- Three months: too tight for nights, icons thin out.
  n, nights, step = ns.Chart.DrawClock(f, midnight, midnight + 90 * 86400, 320, 100)
  check(nights == 0 and step == 168 and n >= 12 and n <= 13, "90 days: weekly suns, no shading (" .. n .. ", step " .. step .. ")")
  -- Two hours: hourly icons.
  n, nights, step = ns.Chart.DrawClock(f, midnight + 13 * 3600 + 600, midnight + 15 * 3600 + 600, 320, 100)
  check(step == 1 and n == 2, "two hours: an icon on each hour (" .. n .. ")")
end

local names = {}
for k in pairs(unknownCalls) do names[#names + 1] = k end
table.sort(names)
print("widget methods used but not modelled by the mock (" .. #names .. "):")
print("  " .. table.concat(names, " "))
print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
