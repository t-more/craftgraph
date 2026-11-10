-- CraftGraph core: saved data, events, logging and small shared helpers.
local ADDON, ns = ...
ns.name = ADDON
_G.CraftGraph = ns

local floor, abs = math.floor, math.abs

------------------------------------------------------------------------------
-- Logging. Errors and notes are kept in the saved file so they can be read
-- after a /reload or logout.
------------------------------------------------------------------------------
local LOG_MAX = 300
local seenErrors = {}

function ns.Print(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100CraftGraph|r: " .. tostring(msg))
  end
end

function ns.Log(msg)
  local db = ns.db
  if not db then return end
  local log = db.log
  log[#log + 1] = date("%m-%d %H:%M:%S ") .. tostring(msg)
  while #log > LOG_MAX do table.remove(log, 1) end
end

local function OnError(err)
  local text = tostring(err)
  local stack = debugstack and debugstack(2, 6, 0) or ""
  ns.Log("ERROR " .. text .. "\n" .. stack)
  if not seenErrors[text] then
    seenErrors[text] = true
    ns.Print("|cffff5555error|r " .. text)
  end
  return text
end

-- Runs fn(...) and records any error instead of breaking the caller.
function ns.Safe(fn, ...)
  return xpcall(fn, OnError, ...)
end

------------------------------------------------------------------------------
-- Truncation watch. Text that does not fit its space is cut off by the game
-- with "...". Every label the addon draws is registered here, and after the
-- screen updates any label the game reports as cut off is written to the
-- log (once each), so layout problems show up without anyone having to
-- spot them.
------------------------------------------------------------------------------
local watched, reported, reportCount = {}, {}, 0
local checkPending = false

function ns.Watch(fontString, where)
  watched[#watched + 1] = { fontString, where or "label" }
  return fontString
end

local function CheckTruncation()
  for i = 1, #watched do
    local fs, where = watched[i][1], watched[i][2]
    if reportCount >= 40 then return end
    if fs.IsTruncated and fs.IsVisible and fs:IsVisible() and fs:IsTruncated() then
      local text = tostring(fs:GetText() or "")
      local key = where .. "|" .. text
      if not reported[key] then
        reported[key] = true
        reportCount = reportCount + 1
        ns.Log("TRUNCATED " .. where .. ": " .. text:sub(1, 140))
      end
    end
  end
end

function ns.QueueTruncationCheck()
  if checkPending or not C_Timer then return end
  checkPending = true
  C_Timer.After(1, function()
    checkPending = false
    ns.Safe(CheckTruncation)
  end)
end

------------------------------------------------------------------------------
-- Game events and internal messages
------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}
local listeners = {}

function ns.On(event, fn)
  if not handlers[event] then
    if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
      return false
    end
    handlers[event] = {}
  end
  table.insert(handlers[event], fn)
  return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if list then
    for i = 1, #list do ns.Safe(list[i], ...) end
  end
end)

function ns.Listen(message, fn)
  listeners[message] = listeners[message] or {}
  table.insert(listeners[message], fn)
end

function ns.Fire(message, ...)
  local list = listeners[message]
  if list then
    for i = 1, #list do ns.Safe(list[i], ...) end
  end
end

------------------------------------------------------------------------------
-- Saved data
------------------------------------------------------------------------------
local DEFAULTS = {
  certainty = true,   -- draw the certainty shading on the price chart
  qty = 1,            -- how many to make
  cut = 0.05,         -- auction house cut on a sale
  horizonDays = 2,    -- how long a batch may take to sell
  chartDays = 14,     -- how far back the price chart looks; 0 = everything
  chartSmooth = 0,    -- minutes the chart's lines are averaged over; 0 = chosen by the chart
  chartFlow = false,  -- draw supply (units listed) on the price chart
  chartDemand = false, -- draw demand (units sold a day) on the price chart
  showGuesses = false, -- show forecasts and patterns even where they are only guesses
  srcOnline = true,   -- use Blizzard's hourly data when the sync tool has brought it in
  srcAuctionator = true, -- use Auctionator's prices and history where we have none
  srcSales = true,    -- use sales worked out from auctions that vanish between full scans
  autoScan = true,    -- scan by itself while the auction house is open
  autoMinutes = 10,   -- how often the items you care about are looked up again
}

ns.generation = 0     -- bumped whenever prices change; caches key on it

local function InitDB()
  CraftGraphDB = CraftGraphDB or {}
  local db = CraftGraphDB
  db.version = 1
  db.realms = db.realms or {}
  db.vendor = db.vendor or {}
  db.settings = db.settings or {}
  db.log = db.log or {}
  for k, v in pairs(DEFAULTS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  ns.db = db
  ns.settings = db.settings
end

local function InitRealm()
  local realm = (GetRealmName and GetRealmName()) or "Unknown"
  local faction = (UnitFactionGroup and UnitFactionGroup("player")) or "Neutral"
  local key = realm .. " - " .. tostring(faction)
  ns.db.realms[key] = ns.db.realms[key] or { items = {} }
  ns.realm = ns.db.realms[key]
  ns.realm.items = ns.realm.items or {}
  ns.realmKey = key
end

ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  InitDB()
  InitRealm()
  ns.Log("loaded, data build " .. tostring(ns.Data and ns.Data.build))
  ns.Fire("READY")
end)

ns.On("PLAYER_LOGIN", function()
  if not ns.db then return end
  InitRealm()
  ns.Fire("LOGIN")
  -- Say once, a little after logging in, if a newer version is known of.
  C_Timer.After(8, function()
    local newer = ns.NewerVersion()
    if newer then
      ns.Print("version " .. newer.version .. " is out (you have " .. ns.VERSION .. "): "
        .. (newer.url or "https://github.com/t-more/craftgraph/releases/latest"))
    end
  end)
end)

------------------------------------------------------------------------------
-- Version. The number below and "## Version" in CraftGraph.toc must agree
-- (the offline checks compare them). An addon cannot look anything up
-- online, so whether a newer version exists is only known when something
-- outside the game has written Data/Latest.lua: the optional sync tool does.
------------------------------------------------------------------------------
ns.VERSION = "0.1"
ns.RELEASES = "https://github.com/t-more/craftgraph/releases/latest"

-- Is version a later than version b? Compared number by number: 0.10 > 0.9.
function ns.VersionLater(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

-- The newer version known of, { version, url, checked }, or nil.
function ns.NewerVersion()
  local latest = ns.Latest
  if type(latest) == "table" and latest.version and ns.VersionLater(latest.version, ns.VERSION) then
    return latest
  end
  return nil
end

------------------------------------------------------------------------------
-- Item helpers. Static data comes from Data/Recipes.lua; the game is asked
-- only for items the data file does not know.
------------------------------------------------------------------------------
local QUALITY = {
  [0] = { 0.62, 0.62, 0.62 },
  [1] = { 1.00, 1.00, 1.00 },
  [2] = { 0.12, 1.00, 0.00 },
  [3] = { 0.00, 0.44, 0.87 },
  [4] = { 0.64, 0.21, 0.93 },
  [5] = { 1.00, 0.50, 0.00 },
}

function ns.ItemName(id)
  local d = ns.Data.items[id]
  if d then return d[1] end
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  return name or ("Item " .. tostring(id))
end

function ns.ItemQuality(id)
  local d = ns.Data.items[id]
  if d then return d[2] end
  local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  return q or 1
end

function ns.QualityColor(q)
  local c = QUALITY[q] or QUALITY[1]
  return c[1], c[2], c[3]
end

function ns.ItemColor(id)
  return ns.QualityColor(ns.ItemQuality(id))
end

function ns.ItemIcon(id)
  local d = ns.Data.items[id]
  if d and d[5] and d[5] > 0 then return d[5] end
  local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
  return icon or 134400
end

-- What a vendor pays for one.
function ns.VendorSell(id)
  local d = ns.Data.items[id]
  if d then return d[3] end
  if C_Item and C_Item.GetItemInfo then
    local price = select(11, C_Item.GetItemInfo(id))
    return price or 0
  end
  return 0
end

function ns.ItemLink(id)
  local r, g, b = ns.ItemColor(id)
  return string.format("|cff%02x%02x%02x|Hitem:%d::::::::::::|h[%s]|h|r",
    r * 255, g * 255, b * 255, id, ns.ItemName(id))
end

function ns.ItemIDFromText(text)
  if type(text) == "number" then return text end
  if type(text) ~= "string" then return nil end
  local id = text:match("item:(%d+)")
  if id then return tonumber(id) end
  id = text:match("^%s*(%d+)%s*$")
  if id then return tonumber(id) end
  return nil
end

------------------------------------------------------------------------------
-- Money and number formatting
------------------------------------------------------------------------------
local GOLD = "|A:coin-gold:12:12|a"
local SILVER = "|A:coin-silver:12:12|a"
local COPPER = "|A:coin-copper:12:12|a"

local function Thousands(n)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- Compact money text: the two most significant coin types.
function ns.Money(copper)
  if not copper then return "|cff808080--|r" end
  local neg = copper < 0
  local c = floor(abs(copper) + 0.5)
  local g, s, k = floor(c / 10000), floor(c / 100) % 100, c % 100
  local out
  if g >= 100 then
    out = Thousands(g) .. GOLD
  elseif g > 0 then
    out = g .. GOLD .. " " .. s .. SILVER
  elseif s > 0 then
    out = s .. SILVER .. " " .. k .. COPPER
  else
    out = k .. COPPER
  end
  return (neg and "-" or "") .. out
end

function ns.Age(seconds)
  if not seconds then return "never" end
  if seconds < 90 then return "just now" end
  if seconds < 5400 then return floor(seconds / 60 + 0.5) .. " min ago" end
  if seconds < 129600 then return floor(seconds / 3600 + 0.5) .. " h ago" end
  return floor(seconds / 86400 + 0.5) .. " days ago"
end

function ns.Round(x)
  return floor(x + 0.5)
end

------------------------------------------------------------------------------
-- Slash command and entry points
------------------------------------------------------------------------------
function ns.Open(item)
  if not ns.UI then return end
  ns.Safe(ns.UI.Open, item)
end

SLASH_CRAFTGRAPH1 = "/cg"
SLASH_CRAFTGRAPH2 = "/craftgraph"
SlashCmdList["CRAFTGRAPH"] = function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "version" or msg == "v" then
    ns.Print("version " .. ns.VERSION .. ".")
    local newer = ns.NewerVersion()
    if newer then
      ns.Print("version " .. newer.version .. " is out: " .. (newer.url or ns.RELEASES))
    elseif type(ns.Latest) == "table" and ns.Latest.checked then
      ns.Print("that was the newest when last checked, " .. ns.Age(time() - ns.Latest.checked) .. ".")
    else
      ns.Print("the game cannot look for updates by itself. See " .. ns.RELEASES
        .. " or run the optional sync tool with check-update.")
    end
    return
  end
  if msg == "log" then
    local log = ns.db and ns.db.log or {}
    for i = math.max(1, #log - 15), #log do ns.Print(log[i]) end
    return
  end
  if msg == "reload" or msg == "rl" then
    -- Reloads the interface, which re-reads every addon script from disk,
    -- and brings the window back where it was.
    if ns.settings and ns.UI and ns.UI.IsOpen then ns.settings.reopen = ns.UI.IsOpen() end
    ReloadUI()
    return
  end
  if msg == "trends" or msg == "t" then
    if ns.UI and ns.UI.Open then
      if not (ns.UI.IsOpen and ns.UI.IsOpen()) then ns.Open() end
      ns.Safe(ns.UI.ShowTrends, true)
    end
    return
  end
  if msg == "sell" then
    if ns.UI and ns.UI.OpenSell then ns.Safe(ns.UI.OpenSell) end
    return
  end
  if msg == "guesses" then
    ns.settings.showGuesses = not ns.settings.showGuesses
    ns.Print(ns.settings.showGuesses and "forecasts and patterns are shown everywhere, also where they are only guesses."
      or "forecasts and patterns are shown only where there is enough to go on.")
    ns.generation = ns.generation + 1
    ns.Fire("SOURCES")
    ns.Fire("MARKET_UPDATED")
    return
  end
  if msg == "sources" or msg == "data" then
    if ns.UI and ns.UI.ToggleSources then ns.Safe(ns.UI.ToggleSources) end
    return
  end
  if msg == "auto" then
    ns.settings.autoScan = not ns.settings.autoScan
    ns.Print("auto scan is " .. (ns.settings.autoScan and "on: prices are refreshed by themselves while the auction house is open."
      or "off."))
    ns.Fire("AUTOSCAN")
    if ns.settings.autoScan then ns.Safe(ns.Market.AutoTick) end
    return
  end
  if msg == "hud" then
    if ns.UI and ns.UI.ToggleHUD then ns.Safe(ns.UI.ToggleHUD) end
    return
  end
  if msg == "worth" or msg == "w" or msg == "deals" or msg == "o" then
    if ns.UI and ns.UI.OpenWorth then ns.Safe(ns.UI.OpenWorth) end
    return
  end
  if msg == "" then
    ns.Open()
    return
  end
  local id = ns.ItemIDFromText(msg)
  if not id and ns.UI then id = ns.UI.FindByName(msg) end
  if id then
    ns.Open(id)
  else
    ns.Print("No item found for \"" .. msg .. "\".")
  end
end

function CraftGraph_OnAddonCompartmentClick()
  ns.Open()
end
