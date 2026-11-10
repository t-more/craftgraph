-- CraftGraph market data: records what the auction house shows, keeps a
-- price ladder (how many units at which price) and a price history per item,
-- and learns vendor prices from merchants.
local ADDON, ns = ...
local M = {}
ns.Market = M

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

local HISTORY_MERGE_SECONDS = 20 * 60   -- an online snapshot this close to an own scan is the same moment
local SAME_SCAN_SECONDS = 5 * 60        -- results this close together are one scan, not two
local TURNOVER_MIN_GAP = 10 * 60
local TURNOVER_MAX_GAP = 3 * 86400
M.SUMMARY_SLOPE = 0.6                   -- assumed price rise across a ladder we have not seen

------------------------------------------------------------------------------
-- Ladders. A ladder is a flat array {price1, qty1, price2, qty2, ...} with
-- prices rising. Up to MAX_LEVELS distinct prices are kept exactly. Longer
-- ladders are merged level by level where prices are nearly the same; the
-- third result of Compress is the tolerance used (nil when exact).
------------------------------------------------------------------------------
local MAX_LEVELS = 28

function M.Compress(raw)
  table.sort(raw, function(a, b) return a[1] < b[1] end)
  local flat, total = {}, 0
  for i = 1, #raw do
    local price, qty = floor(raw[i][1] + 0.5), raw[i][2]
    total = total + qty
    local n = #flat
    if n >= 2 and flat[n - 1] == price then
      flat[n] = flat[n] + qty
    else
      flat[n + 1], flat[n + 2] = price, qty
    end
  end
  if #flat <= MAX_LEVELS * 2 then
    return flat, total
  end
  -- Too many price levels to keep: merge neighbours whose prices are within
  -- a small tolerance of each other, widening it until the ladder is short
  -- enough. Listings a copper apart collapse into one level, while a real
  -- jump in price stays a jump (which is what a relist depends on).
  local tol = 0.02
  while true do
    local out = {}
    local start, qty, cost = nil, 0, 0
    for k = 1, #flat, 2 do
      local price, n = flat[k], flat[k + 1]
      if start and price > start * (1 + tol) then
        out[#out + 1] = floor(cost / qty + 0.5)
        out[#out + 1] = qty
        start, qty, cost = nil, 0, 0
      end
      start = start or price
      qty = qty + n
      cost = cost + price * n
    end
    if qty > 0 then
      out[#out + 1] = floor(cost / qty + 0.5)
      out[#out + 1] = qty
    end
    if #out <= MAX_LEVELS * 2 or tol > 4 then
      return out, total, tol
    end
    tol = tol * 2
  end
end

-- Cost of buying `qty` units after skipping the first `from` units.
-- Returns cost, units actually available, price of the last unit reached.
function M.Walk(flat, from, qty)
  local cost, got, last = 0, 0, nil
  local skipped = 0
  for i = 1, #flat, 2 do
    local price, n = flat[i], flat[i + 1]
    last = price
    local avail = n
    if skipped < from then
      local skip = min(n, from - skipped)
      skipped = skipped + skip
      avail = n - skip
    end
    if avail > 0 then
      local take = min(avail, qty - got)
      cost = cost + take * price
      got = got + take
      if got >= qty then break end
    end
  end
  return cost, got, last
end

-- Units listed strictly below `price`.
function M.QtyBelow(flat, price)
  local n = 0
  for i = 1, #flat, 2 do
    if flat[i] < price then n = n + flat[i + 1] else break end
  end
  return n
end

-- A steadier price than the single cheapest listing: the average of the
-- cheapest tenth of what is listed.
function M.RobustPrice(flat, total)
  if not flat[1] then return 0 end
  local k = max(1, min(50, ceil(total * 0.1)))
  local cost, got = M.Walk(flat, 0, k)
  if got <= 0 then return flat[1] end
  return floor(cost / got + 0.5)
end

------------------------------------------------------------------------------
-- Storage
------------------------------------------------------------------------------
local function ItemRecord(id, create)
  local items = ns.realm and ns.realm.items
  if not items then return nil end
  local it = items[id]
  if not it and create then
    it = { h = {} }
    items[id] = it
  end
  return it
end

function M.Get(id)
  return ItemRecord(id, false)
end

-- History, kept inside the game's one saved file and built to stay small
-- and quick however long it runs, the way a time-series database does it:
--
--   it.h    the recent points, every scan, as a flat array of 4 numbers
--           per point: time, cheapest price, robust price, units listed.
--           A price of 0 means nothing was listed.
--   it.hp   everything older, packed into one string and thinned by age:
--           one point an hour up to three weeks, one per six hours up to
--           four months, one a day for good. Nothing is dropped for being
--           old.
--
-- A packed point costs about 15 bytes in the saved file where four table
-- entries cost about 80, and a string loads far faster than a table. A run
-- of scans that all saw the same price is kept as its first and last point.
local HOT_SECONDS = 2 * 86400        -- every scan is kept this long
local HOURLY_SECONDS = 21 * 86400    -- then one an hour up to here
local SIXHOUR_SECONDS = 120 * 86400  -- then one per six hours; daily after
local COMPACT_EVERY = 40             -- tidy up after this many new points

local function Pack(flat)
  if not flat[1] then return nil end
  local parts, last = {}, 0
  for i = 1, #flat, 4 do
    local t = max(floor(flat[i]), last)        -- never a step back in time
    parts[#parts + 1] = (t - last) .. "," .. floor(flat[i + 1] + 0.5) .. ","
      .. floor(flat[i + 2] + 0.5) .. "," .. floor(flat[i + 3] + 0.5)
    last = t
  end
  return table.concat(parts, ";")
end
M.Pack = Pack

local function Unpack(packed)
  local flat, n, t = {}, 0, 0
  if type(packed) ~= "string" then return flat end
  for dt, price, robust, total in packed:gmatch("(%d+),(%d+),(%d+),(%d+)") do
    t = t + tonumber(dt)
    flat[n + 1], flat[n + 2], flat[n + 3], flat[n + 4] = t, tonumber(price), tonumber(robust), tonumber(total)
    n = n + 4
  end
  return flat
end
M.Unpack = Unpack

-- The packed part is unpacked once and remembered until it changes.
local coldCache = setmetatable({}, { __mode = "k" })
local function Cold(it)
  if not it.hp then return nil end
  local c = coldCache[it]
  if not c or c.hp ~= it.hp then
    c = { hp = it.hp, flat = Unpack(it.hp) }
    coldCache[it] = c
  end
  return c.flat
end

-- The whole history of an item record, oldest first, as one flat array.
-- Read it, do not change it.
function M.History(it)
  if not it then return {} end
  local cold = Cold(it)
  local h = it.h or {}
  if not cold then return h end
  local out, n = {}, #cold
  for i = 1, n do out[i] = cold[i] end
  for i = 1, #h do out[n + i] = h[i] end
  return out
end

local function ThinHistory(h, now)
  local out, lastKey = {}, nil
  for i = 1, #h, 4 do
    local t = h[i]
    local age = now - t
    local key
    if age > SIXHOUR_SECONDS then
      key = "d" .. floor(t / 86400)
    elseif age > HOURLY_SECONDS then
      key = "q" .. floor(t / 21600)
    elseif age > HOT_SECONDS then
      key = "h" .. floor(t / 3600)
    end
    local n = #out
    if key and key == lastKey then
      -- Same period: the later point wins, but "none listed" never
      -- replaces a real price.
      if h[i + 1] > 0 or out[n - 2] == 0 then
        out[n - 3], out[n - 2], out[n - 1], out[n] = t, h[i + 1], h[i + 2], h[i + 3]
      end
    else
      out[n + 1], out[n + 2], out[n + 3], out[n + 4] = t, h[i + 1], h[i + 2], h[i + 3]
    end
    lastKey = key
  end
  return out
end
M.ThinHistory = ThinHistory

-- Thins what has aged and moves it from the table into the packed string.
local function Compact(it, now)
  local all = ThinHistory(M.History(it), now)
  local cold, hot = {}, {}
  for i = 1, #all, 4 do
    local to = (now - all[i] > HOT_SECONDS) and cold or hot
    local n = #to
    to[n + 1], to[n + 2], to[n + 3], to[n + 4] = all[i], all[i + 1], all[i + 2], all[i + 3]
  end
  it.hp = Pack(cold)
  it.h = hot
  it.hn = #hot
end
M.Compact = Compact

local function Same(a, b, tolerance)
  return math.abs(a - b) <= tolerance * max(a, b)
end

local function AppendHistory(it, t, price, robust, total)
  local h = it.h
  local n = #h
  -- History runs forward: a result stamped earlier than the last point
  -- (a full scan stored after a later lookup) is put at that point's time.
  if n >= 4 and t < h[n - 3] then t = h[n - 3] end
  -- How many scans this item has had, whatever became of their points: a
  -- price that never moves is two points however often it was looked at.
  if not (it.ha and t - it.ha < SAME_SCAN_SECONDS) then
    it.hc = (it.hc or n / 4) + 1
  end
  -- "Still none listed" adds nothing new.
  if price == 0 and n >= 4 and h[n - 2] == 0 then return end
  -- it.ha is when the last point was first written. The window is counted
  -- from there, not from the point's latest time: otherwise scans a few
  -- minutes apart would each replace the one before and a whole session
  -- would shrink to a single point.
  if n >= 4 and it.ha and t - it.ha < SAME_SCAN_SECONDS and (price > 0) == (h[n - 2] > 0) then
    -- The same scan seen twice (a lookup and the full list, say): the
    -- later result replaces the earlier, but "none listed" never
    -- overwrites a real price (or the other way round).
    h[n - 3], h[n - 2], h[n - 1], h[n] = t, price, robust, total
  elseif n >= 8 and price > 0 and h[n - 2] == price and h[n - 6] == price
    and h[n - 1] == robust and h[n - 5] == robust
    and Same(h[n], total, 0.05) and Same(h[n - 4], total, 0.05) then
    -- The third scan in a row to see the same thing: the run keeps its
    -- first point and its last, which moves on to now.
    h[n - 3], h[n] = t, total
  else
    h[n + 1], h[n + 2], h[n + 3], h[n + 4] = t, price, robust, total
    it.ha = t
  end
  if #h >= (it.hn or 0) + 4 * COMPACT_EVERY or (h[1] and t - h[1] > HOT_SECONDS + 86400) then
    Compact(it, t)
  end
end

local function UpdateTurnover(it, newFlat, now)
  local old, oldTime = it.l, it.lt
  if not old or not oldTime or it.ls or not old[1] then return end
  local dt = now - oldTime
  if dt < TURNOVER_MIN_GAP or dt > TURNOVER_MAX_GAP then return end
  local sold
  if newFlat[1] then
    sold = M.QtyBelow(old, newFlat[1])
  else
    sold = it.ln or 0
  end
  local days = dt / 86400
  local rate = sold / days
  local w = min(days, 1)
  local vn = it.vn or 0
  it.v = ((it.v or 0) * vn + rate * w) / (vn + w)
  it.vn = min(vn + w, 5)
end

------------------------------------------------------------------------------
-- Patterns: beyond price and depth, each scan also adds to a few small
-- tallies per item that only show their worth over time.
--   hd / wd  by hour of day / day of week: scans, summed price relative to
--            the item's running average, summed units listed
--   bs       how listings are stacked: { size, weight, ... }, commonest first
--   sl / sn  sellers at the last scan: { name, units, ... } and how many
--   sp       how often each leading seller has been seen: { name = scans }
------------------------------------------------------------------------------
local PATTERN_GAP = 30 * 60      -- one tally per item per half hour at most
local SELLERS_KEPT, STACKS_KEPT, SELLER_MEMORY = 8, 6, 16

local function TopPairs(map, limit)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if map[a] ~= map[b] then return map[a] > map[b] end
    return tostring(a) < tostring(b)
  end)
  local flat = {}
  for i = 1, min(limit, #keys) do
    flat[#flat + 1] = keys[i]
    flat[#flat + 1] = map[keys[i]]
  end
  return flat, #keys
end

local function Tally(tbl, key, rel, total)
  local c = tbl[key]
  if not c then
    c = { 0, 0, 0 }
    tbl[key] = c
  end
  c[1], c[2], c[3] = c[1] + 1, c[2] + rel, c[3] + total
end

local function RecordPatterns(it, raw, total, robust, now, opts)
  -- Who is selling, when the scan names the sellers.
  local sellers, named = {}, false
  for i = 1, #raw do
    local owner = raw[i][3]
    if type(owner) == "string" and owner ~= "" then
      sellers[owner] = (sellers[owner] or 0) + raw[i][2]
      named = true
    end
  end
  if named then
    it.sl, it.sn = TopPairs(sellers, SELLERS_KEPT)
    it.sp = it.sp or {}
    for i = 1, #it.sl, 2 do
      it.sp[it.sl[i]] = (it.sp[it.sl[i]] or 0) + 1
    end
    local kept, count = TopPairs(it.sp, SELLER_MEMORY)
    if count > SELLER_MEMORY then
      local trimmed = {}
      for i = 1, #kept, 2 do trimmed[kept[i]] = kept[i + 1] end
      it.sp = trimmed
    end
  end

  -- How listings are stacked, when each entry is one auction. Older scans
  -- fade so the picture follows current habits.
  if opts.perAuction and #raw > 0 then
    local sizes = {}
    if it.bs then
      for i = 1, #it.bs, 2 do sizes[it.bs[i]] = it.bs[i + 1] * 0.7 end
    end
    for i = 1, #raw do
      local size = raw[i][2]
      sizes[size] = (sizes[size] or 0) + 1
    end
    it.bs = TopPairs(sizes, STACKS_KEPT)
  end

  -- Hour of day and day of week, from complete ladders only.
  if opts.full and robust > 0 and (not it.pt or now - it.pt >= PATTERN_GAP) then
    it.pt = now
    local logPrice = math.log(robust)
    local rel = it.e and (logPrice - it.e) or 0
    it.e = it.e and (it.e + 0.2 * (logPrice - it.e)) or logPrice
    it.hd = it.hd or {}
    it.wd = it.wd or {}
    Tally(it.hd, tonumber(date("%H", now)) or 0, rel, total)
    Tally(it.wd, tonumber(date("%w", now)) or 0, rel, total)
  end
end

-- Records a full or partial ladder for an item.
-- raw: array of {unit price, quantity, seller name or nil}.
-- opts.full: the ladder is complete. opts.perAuction: each entry is one auction.
function M.Record(id, raw, opts)
  opts = opts or {}
  local now = opts.t or time()
  local it = ItemRecord(id, true)
  if not it then return end
  local flat, total, blur = M.Compress(raw)
  if opts.total and opts.total > total then total = opts.total end
  if not flat[1] and not opts.full then return end
  if opts.full then UpdateTurnover(it, flat, now) end
  it.l, it.lt, it.ln, it.ls = flat, now, total, nil
  it.lz = blur       -- how far apart merged prices may be (nil = exact)
  it.lp = not opts.full or nil
  if flat[1] then
    local robust = M.RobustPrice(flat, total)
    AppendHistory(it, now, flat[1], robust, total)
    RecordPatterns(it, raw, total, robust, now, opts)
  else
    AppendHistory(it, now, 0, 0, 0)
  end
  ns.generation = ns.generation + 1
end

-- The hour-of-day ("hd") or weekday ("wd") tally with the most behind it:
-- the player's own scans or the online data.
function M.Tally(id, which)
  local it = ItemRecord(id, false)
  local own = it and it[which]
  local on = M.Online(id)
  local online = on and on[which]
  local function scans(tally)
    local n = 0
    for _, c in pairs(tally or {}) do n = n + c[1] end
    return n
  end
  if online and scans(online) > scans(own) then return online, true end
  return own, false
end

-- Records only "cheapest price and how many are listed" (from a browse list).
function M.RecordSummary(id, price, total, now)
  now = now or time()
  local it = ItemRecord(id, true)
  if not it or not price or price <= 0 then return end
  total = max(total or 1, 1)
  AppendHistory(it, now, price, price, total)
  if not it.lt or it.ls or now - it.lt > 30 * 60 then
    it.l, it.lt, it.ln, it.ls, it.lp = { price, total }, now, total, true, nil
  end
  ns.generation = ns.generation + 1
end

------------------------------------------------------------------------------
-- Reading prices
------------------------------------------------------------------------------
-- Data sources beyond the player's own scans can each be switched off, to
-- see what the numbers are without them: "Online", "Auctionator", "Sales".
function M.Source(name)
  return not ns.settings or ns.settings["src" .. name] ~= false
end

function M.SetSource(name, on)
  ns.settings["src" .. name] = on and true or false
  ns.generation = ns.generation + 1
  ns.Fire("SOURCES")
  ns.Fire("MARKET_UPDATED")
end

local function AuctionatorPrice(id)
  if not M.Source("Auctionator") then return nil end
  local A = _G.Auctionator
  if not (A and A.API and A.API.v1 and A.API.v1.GetAuctionPriceByItemID) then return nil end
  local ok, price = pcall(A.API.v1.GetAuctionPriceByItemID, ADDON, id)
  if ok and type(price) == "number" and price > 0 then
    local okAge, days = pcall(A.API.v1.GetAuctionAgeByItemID, ADDON, id)
    return price, (okAge and type(days) == "number") and days * 86400 or nil
  end
  return nil
end

-- Describes what is known about buying an item at auction.
-- Returns a table: price (cheapest), age (seconds), total (units listed),
-- ladder (flat array or nil), summary (depth is a guess), source.
-- Online data: Blizzard's hourly auction house snapshots, brought in from
-- outside the game by sync/craftgraph_sync.py. It is used only when it is
-- for the auction house the player is on.
function M.Online(id)
  local o = ns.Online
  local meta = (o and o.items and o.realm == ns.realmKey and M.Source("Online")) and o or nil
  local on = meta and meta.items[id] or nil
  -- Prices another player shared count the same way: whichever is newer.
  local shared = M.Shared(id)
  if shared and (not on or (shared.t or 0) > (on.t or 0)) then return shared, meta end
  return on, meta
end

------------------------------------------------------------------------------
-- Sharing prices between players
--
-- One player exports the prices of a recent scan as text; another imports
-- it. The text is plain JSON so that it can be read, checked and produced
-- by anything, and so that it can grow: fields that are not known are
-- ignored, and "version" says which shape it has.
--
--   { "format": "craftgraph-prices", "version": 1,
--     "realm": "<auction house>", "from": "<character>", "made": <time>,
--     "items": { "<item id>": { "t": <scan time>, "n": <units listed>,
--                               "l": [price, units, price, units, ...] } } }
--
-- Imported prices are a second opinion like any other source: used only
-- where they are newer than the player's own scan, switched off with one
-- tick, and never mixed into the player's own history.
------------------------------------------------------------------------------
M.SHARE_FORMAT, M.SHARE_VERSION = "craftgraph-prices", 1
local SHARE_LEVELS = 8                 -- price levels sent per item
local SHARE_MAX_AGE = 7 * 86400        -- older prices are not taken in

-- Shared prices are kept apart for each player they came from:
--   ns.realm.sharedBy[name] = { items = { [id] = { t, l, n } }, made, got, github }
-- "Shared" switches them all; ns.settings.sharedOff[name] switches one off.
function M.Contributors()
  local out = {}
  for name, c in pairs(ns.realm and ns.realm.sharedBy or {}) do
    local n = 0
    for _ in pairs(c.items or {}) do n = n + 1 end
    out[#out + 1] = { name = name, items = n, made = c.made, got = c.got, github = c.github,
      on = not (ns.settings.sharedOff and ns.settings.sharedOff[name]) }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function M.SetContributor(name, on)
  ns.settings.sharedOff = ns.settings.sharedOff or {}
  ns.settings.sharedOff[name] = (not on) or nil
  ns.generation = ns.generation + 1
  ns.Fire("SOURCES")
  ns.Fire("MARKET_UPDATED")
end

-- The newest shared price of an item among the players switched on, and
-- who it came from.
function M.Shared(id)
  local by = ns.realm and ns.realm.sharedBy
  if not by or not M.Source("Shared") then return nil end
  local off = ns.settings.sharedOff
  local best, who
  for name, c in pairs(by) do
    if not (off and off[name]) then
      local item = c.items and c.items[id]
      if item and (not best or item.t > best.t) then best, who = item, name end
    end
  end
  return best, who
end

-- Every item some switched-on player has shared a price for.
function M.SharedIds()
  local ids = {}
  if not M.Source("Shared") then return ids end
  local off = ns.settings.sharedOff
  for name, c in pairs(ns.realm and ns.realm.sharedBy or {}) do
    if not (off and off[name]) then
      for id in pairs(c.items or {}) do ids[id] = true end
    end
  end
  return ids
end

local function Quote(text)
  return '"' .. tostring(text):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

-- The player's own scans of the last day, as JSON text. Returns the text
-- and how many items it holds.
function M.Export()
  local now, parts = time(), {}
  local ids = {}
  for id, it in pairs(ns.realm and ns.realm.items or {}) do
    if type(it) == "table" and it.lt and it.l and it.l[1] and not it.ls and now - it.lt < 86400 then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local it = ns.realm.items[id]
    local levels = {}
    for i = 1, min(#it.l, SHARE_LEVELS * 2) do levels[i] = floor(it.l[i] + 0.5) end
    parts[#parts + 1] = string.format('"%d":{"t":%d,"n":%d,"l":[%s]}', id, it.lt, it.ln or 0, table.concat(levels, ","))
  end
  local text = '{"format":' .. Quote(M.SHARE_FORMAT) .. ',"version":' .. M.SHARE_VERSION
    .. ',"realm":' .. Quote(ns.realmKey or "") .. ',"from":' .. Quote(UnitName and UnitName("player") or "?")
    .. ',"made":' .. now .. ',"items":{' .. table.concat(parts, ",") .. "}}"
  return text, #ids
end

-- A small JSON reader: objects, arrays, strings, numbers, true, false, null.
function M.ParseJSON(text)
  local pos = 1
  local function fail(what) error("not valid JSON: " .. what .. " at character " .. pos, 0) end
  local function space() pos = text:find("%S", pos) or #text + 1 end
  local value
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local c = text:sub(pos, pos)
      if c == "" then fail("text that does not end") end
      if c == '"' then pos = pos + 1 return table.concat(out) end
      if c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        if e == "u" then
          local code = tonumber(text:sub(pos + 2, pos + 5), 16) or 63
          out[#out + 1] = code < 128 and string.char(code) or "?"
          pos = pos + 6
        else
          out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[e] or e
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end
  function value()
    space()
    local c = text:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      space()
      if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        space()
        if text:sub(pos, pos) ~= '"' then fail("a name was expected") end
        local key = str()
        space()
        if text:sub(pos, pos) ~= ":" then fail("a colon was expected") end
        pos = pos + 1
        obj[key] = value()
        space()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then fail("a comma was expected") end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      space()
      if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = value()
        space()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then fail("a comma was expected") end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then fail("something unexpected") end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local ok, result = pcall(value)
  if not ok then return nil, result end
  return result
end

-- Takes shared prices in. Returns a result table that says plainly what
-- happened: ok, a sentence, and counts (taken, older than what was already
-- held, too old, malformed). force: take it although it is for another
-- auction house.
function M.Import(text, force)
  local function no(why) return { ok = false, text = why } end
  if type(text) ~= "string" or not text:find("%S") then return no("Nothing to import: the box is empty.") end
  local data, problem = M.ParseJSON(text)
  if type(data) ~= "table" then return no("That is not CraftGraph data (" .. tostring(problem or "it is not JSON") .. ").") end
  if data.format ~= M.SHARE_FORMAT then return no("That is JSON, but not CraftGraph prices.") end
  if type(data.items) ~= "table" then return no("The data holds no items.") end
  if data.realm ~= ns.realmKey and not force then
    return { ok = false, otherRealm = true, text = "These prices are for another auction house (" .. tostring(data.realm)
      .. "), not yours (" .. tostring(ns.realmKey) .. "). Press Import again to take them anyway." }
  end
  local now = time()
  -- Each player's prices are kept under their in-game name.
  local who = tostring(data.from or "someone")
  if who == "" then who = "someone" end
  ns.realm.sharedBy = ns.realm.sharedBy or {}
  local shared = ns.realm.sharedBy[who] or { items = {} }
  shared.items = shared.items or {}
  local taken, older, tooOld, bad = 0, 0, 0, 0
  for key, entry in pairs(data.items) do
    local id = tonumber(key)
    local ladder = type(entry) == "table" and entry.l
    local okShape = id and type(entry.t) == "number" and type(ladder) == "table" and #ladder >= 2 and #ladder % 2 == 0
    if okShape then
      for i = 1, #ladder do
        if type(ladder[i]) ~= "number" or ladder[i] < 0 then okShape = false end
      end
    end
    if not okShape or entry.t > now + 900 then
      bad = bad + 1
    elseif now - entry.t > SHARE_MAX_AGE then
      tooOld = tooOld + 1
    else
      local have = shared.items[id]
      if have and have.t >= entry.t then
        older = older + 1
      else
        local total = type(entry.n) == "number" and entry.n or 0
        if total <= 0 then for i = 2, #ladder, 2 do total = total + ladder[i] end end
        shared.items[id] = { t = entry.t, l = ladder, n = total }
        taken = taken + 1
      end
    end
  end
  if taken > 0 then
    shared.made = type(data.made) == "number" and data.made or now
    shared.got = now
    shared.github = type(data.github) == "string" and data.github or shared.github
    ns.realm.sharedBy[who] = shared
    ns.generation = ns.generation + 1
    ns.Fire("SOURCES")
    ns.Fire("MARKET_UPDATED")
  end
  local parts = {}
  if older > 0 then parts[#parts + 1] = older .. " no newer than what you had" end
  if tooOld > 0 then parts[#parts + 1] = tooOld .. " over a week old" end
  if bad > 0 then parts[#parts + 1] = bad .. " unreadable" end
  local rest = #parts > 0 and (" Left out: " .. table.concat(parts, ", ") .. ".") or ""
  local newer = type(data.version) == "number" and data.version > M.SHARE_VERSION
  local result = { ok = taken > 0, taken = taken, older = older, tooOld = tooOld, bad = bad, from = who }
  if taken > 0 then
    result.text = "Imported " .. taken .. " prices from " .. tostring(data.from or "someone") .. ", scanned "
      .. ns.Age(now - (type(data.made) == "number" and data.made or now)) .. "." .. rest
      .. (newer and " It was made by a newer CraftGraph; anything this version does not know was skipped." or "")
  else
    result.text = "Nothing was imported." .. rest
  end
  ns.Log("share import: " .. result.text)
  return result
end

-- Forgets everything that was shared, or what one player shared.
function M.ClearShared(name)
  if ns.realm then
    if name and ns.realm.sharedBy then ns.realm.sharedBy[name] = nil else ns.realm.sharedBy = nil end
  end
  ns.generation = ns.generation + 1
  ns.Fire("SOURCES")
  ns.Fire("MARKET_UPDATED")
end

-- A .cg.json file put into Data/Shared.lua from outside the game is taken
-- in once at login, and the outcome is said in chat and kept for the window.
-- ns.SharedFile is one file's text, or a list of them (one per player).
ns.Listen("LOGIN", function()
  local files = ns.SharedFile
  if type(files) == "string" then files = { files } end
  if type(files) ~= "table" or not ns.realm then return end
  ns.realm.sharedFilesSeen = ns.realm.sharedFilesSeen or {}
  local seen, fresh = {}, 0
  for _, file in ipairs(files) do
    if type(file) == "string" then
      local mark = #file .. ":" .. file:sub(1, 120)
      seen[mark] = true
      if not ns.realm.sharedFilesSeen[mark] then
        local result = M.Import(file, false)
        M.lastImport = result
        fresh = fresh + 1
        ns.Print("shared prices: " .. (result.text:gsub(" Press Import again to take them anyway%.", "")))
      end
    end
  end
  ns.realm.sharedFilesSeen = seen
end)

------------------------------------------------------------------------------
-- Sales seen between full scans
--
-- A full scan lists every auction with its seller, stack, price and a
-- rough time left. An auction that was there at one full scan and is gone
-- at the next was sold, cancelled or ran out. None of the three is shown,
-- so each vanished auction is given a probability of having sold:
--   * it may have run out: its time-left band at the earlier scan says how
--     long it had (between a least and a most), and the chance that it ran
--     out within the gap is how much of that span the gap covers;
--   * it may have been cancelled: more likely when the same seller put up
--     new auctions of the item in the meantime (an undercut and relist);
--   * buyers take the cheapest first: one that vanished while cheaper ones
--     stayed was probably not bought.
-- The units sold are then a count over time, and the selling rate is
-- estimated the standard Bayesian way for counts: sales arrive at an
-- unknown rate (Poisson) whose belief is a Gamma distribution, sharpened
-- by every pair of scans. Old evidence fades (half of its weight a week),
-- because a young market's demand does not hold still.
-- Auctions posted and sold between two scans are never seen; the count is
-- scaled up for them from how quickly the cheap auctions that were seen
-- went. With scans many hours apart that correction is a guess and the
-- rate is better read as a floor. tools/backtest_sales.lua measures all of
-- this against a simulated item whose true rate is known.
------------------------------------------------------------------------------
local SALES_MAX_GAP = 12 * 3600       -- scans further apart say too little
local SALES_MIN_GAP = 4 * 60
local SALES_HALFLIFE = 7              -- days
-- Before anything is seen: a tenth of a sale in a tenth of a day, so that
-- a few minutes without a sale reads as "about one a day", not ten.
local SALES_PRIOR_UNITS, SALES_PRIOR_DAYS = 0.1, 0.1
local CANCEL_BASE, CANCEL_RELISTED = 0.10, 0.95
local SKIPPED_FACTOR = 0.25           -- cheaper ones were left: probably not bought
local SELLERS_SOLD_KEPT = 12
local SALES_HISTORY_KEPT = 160        -- gap-by-gap selling rates kept per item
local bandInfo = {}

-- The least and most seconds an auction in a time-left band has left.
local function BandSeconds(band)
  local b = bandInfo[band]
  if not b then
    local lo, hi
    if C_AuctionHouse and C_AuctionHouse.GetTimeLeftBandInfo then
      local ok, a, c = pcall(C_AuctionHouse.GetTimeLeftBandInfo, band)
      if ok and type(a) == "number" and type(c) == "number" then lo, hi = a, c end
    end
    if not lo then
      -- The game's usual bands: under 30 min, to 2 h, to 12 h, to 48 h.
      local known = { [0] = { 0, 1800 }, { 1800, 7200 }, { 7200, 43200 }, { 43200, 172800 } }
      local k = known[band] or known[3]
      lo, hi = k[1], k[2]
    end
    b = { lo, hi }
    bandInfo[band] = b
  end
  return b[1], b[2]
end

-- auctions: { unit price, count, owner or nil, band or nil } per auction.
-- Returns the snapshot: key -> { n, band, unit, count, owner }.
local function Snapshot(auctions)
  local snap = {}
  for i = 1, #auctions do
    local a = auctions[i]
    local owner = type(a[3]) == "string" and a[3] or ""
    local buyout = floor(a[1] * a[2] + 0.5)
    local key = owner .. "," .. a[2] .. "," .. buyout
    local s = snap[key]
    if not s then
      s = { n = 0, band = a[4] or 3, unit = a[1], count = a[2], owner = owner }
      snap[key] = s
    end
    s.n = s.n + 1
    -- Of identical auctions, remember the one nearest its end.
    if a[4] and a[4] < s.band then s.band = a[4] end
  end
  return snap
end

local function PackSnapshot(snap, t)
  local parts = { tostring(t) }
  for key, s in pairs(snap) do
    parts[#parts + 1] = key .. "," .. s.n .. "," .. s.band
  end
  return table.concat(parts, ";")
end

local function UnpackSnapshot(packed)
  if type(packed) ~= "string" then return nil end
  local t = tonumber(packed:match("^(%d+)"))
  if not t then return nil end
  local snap = {}
  for owner, count, buyout, n, band in packed:gmatch(";([^,;]*),(%d+),(%d+),(%d+),(%d+)") do
    count, buyout = tonumber(count), tonumber(buyout)
    snap[owner .. "," .. count .. "," .. buyout] = { n = tonumber(n), band = tonumber(band),
      unit = buyout / count, count = count, owner = owner }
  end
  return snap, t
end

-- Compares this full scan's auctions of an item with the last one's and
-- updates the belief about how fast it sells. Returns the units judged
-- sold in the gap (a fraction, since each is a probability), or nil when
-- the two scans could not be compared.
function M.TrackSales(id, auctions, now)
  local it = ItemRecord(id, true)
  if not it then return nil end
  local snap = Snapshot(auctions)
  local old, oldTime = UnpackSnapshot(it.au)
  it.au = next(snap) and PackSnapshot(snap, now) or tostring(now)
  if not old then return nil end
  local gap = now - oldTime
  if gap < SALES_MIN_GAP or gap > SALES_MAX_GAP then return nil end

  -- Cheapest price among auctions that are still there, and how many new
  -- auctions each seller put up since.
  local floorPrice, relisted = math.huge, {}
  for key, s in pairs(snap) do
    local before = old[key] and old[key].n or 0
    if before > 0 and s.unit < floorPrice then floorPrice = s.unit end
    if s.n > before and s.owner ~= "" then
      relisted[s.owner] = (relisted[s.owner] or 0) + (s.n - before)
    end
  end

  -- How likely an auction was to go for a reason other than running out,
  -- measured on the ones that could not have run out in this gap.
  local safe, safeGone, gone = 0, 0, {}
  for key, o in pairs(old) do
    local lo, hi = BandSeconds(o.band)
    local expire = hi > lo and max(0, min(1, (gap - lo) / (hi - lo))) or (gap >= lo and 1 or 0)
    local left = o.n - (snap[key] and snap[key].n or 0)
    if expire == 0 then
      safe = safe + o.n
      safeGone = safeGone + max(0, left)
    end
    for _ = 1, max(0, left) do
      gone[#gone + 1] = { unit = o.unit, count = o.count, owner = o.owner, expire = expire }
    end
  end
  local taken = (safeGone + 0.5) / (safe + 2)

  -- A seller's new auctions explain his vanished ones as relists, the
  -- dearest first: what gets undercut and pulled is what no longer sells.
  table.sort(gone, function(a, b)
    if a.unit ~= b.unit then return a.unit > b.unit end
    return a.owner < b.owner
  end)
  local sold, bySeller = 0, {}
  local soldStacks, marginal = 0, 0
  for _, g in ipairs(gone) do
    local cancel = CANCEL_BASE
    if g.owner ~= "" and (relisted[g.owner] or 0) > 0 then
      cancel = CANCEL_RELISTED
      relisted[g.owner] = relisted[g.owner] - 1
    end
    -- Given that it is gone: was it taken, or did its time run out?
    local notExpired = 1
    if g.expire >= 1 then
      notExpired = 0
    elseif g.expire > 0 then
      notExpired = (1 - g.expire) * taken / (g.expire + (1 - g.expire) * taken)
    end
    local skipped = g.unit > floorPrice * 1.05 and SKIPPED_FACTOR or 1
    local p = notExpired * (1 - cancel) * skipped
    g.p = p
    sold = sold + p * g.count
    soldStacks = soldStacks + p
    if p > 0.5 and g.unit > marginal then marginal = g.unit end
    if g.owner ~= "" and p > 0 then bySeller[g.owner] = (bySeller[g.owner] or 0) + p * g.count end
  end

  -- What the scans cannot see: auctions posted and sold inside the gap. If
  -- a share `hit` of the auctions cheap enough to sell went in this gap,
  -- and newcomers at those prices go as readily, then for every sale seen
  -- there were -ln(1 - hit) / hit sales in all.
  if soldStacks > 0 and marginal > 0 then
    local atRisk = 0
    for _, o in pairs(old) do
      if o.unit <= marginal then atRisk = atRisk + o.n end
    end
    local hit = min(0.9, soldStacks / (atRisk + 1))
    if hit > 0.01 then
      local scale = -math.log(1 - hit) / hit
      sold, soldStacks = sold * scale, soldStacks * scale
    end
  end
  -- How much of the whole listing was replaced between the two scans,
  -- lately. When most of it was, far more changed hands than can be seen
  -- and the rate is only a floor.
  local total = 0
  for _, o in pairs(old) do total = total + o.n end
  if total > 0 then
    local turned = #gone / total
    it.sf = (it.sf or turned) * 0.7 + turned * 0.3
  end

  -- Belief about the rate: units and days of evidence, older evidence fading.
  local days = gap / 86400
  local fade = 0.5 ^ (days / SALES_HALFLIFE)
  -- A short history of the rate itself, for the chart: time, units a day.
  local sh = it.sh or {}
  sh[#sh + 1], sh[#sh + 2] = now, floor(sold / days + 0.5)
  while #sh > 2 * SALES_HISTORY_KEPT do
    table.remove(sh, 1)
    table.remove(sh, 1)
  end
  it.sh = sh
  it.sa = (it.sa or 0) * fade + sold               -- units
  it.sc = (it.sc or 0) * fade + soldStacks         -- auctions: the events that are counted
  it.sb = (it.sb or 0) * fade + days
  if next(bySeller) or it.sq then
    local sq = it.sq or {}
    for name, units in pairs(sq) do sq[name] = units * fade end
    for name, units in pairs(bySeller) do sq[name] = (sq[name] or 0) + units end
    local kept, count = TopPairs(sq, SELLERS_SOLD_KEPT)
    if count > SELLERS_SOLD_KEPT then
      sq = {}
      for i = 1, #kept, 2 do sq[kept[i]] = kept[i + 1] end
    end
    it.sq = sq
  end
  return sold
end

-- The selling rate believed from the vanished auctions: units a day, the
-- range it is in with four chances in five, the days of watching behind it
-- and the units judged sold in that time. nil until two full scans within
-- twelve hours of each other have been compared.
function M.Sales(id)
  local it = ItemRecord(id, false)
  if not it or not it.sb or it.sb <= 0 or not M.Source("Sales") then return nil end
  -- What arrives at random is a sale of one auction, whatever its stack,
  -- so the belief is about auctions a day; units follow from the average
  -- stack that sold.
  local events = it.sc or 0
  local stack = events > 0.01 and (it.sa or 0) / events or 1
  local alpha, beta = SALES_PRIOR_UNITS + events, SALES_PRIOR_DAYS + it.sb
  -- Gamma quantiles by the Wilson-Hilferty cube: good from alpha of 1 up,
  -- rough below, where the range is wide anyway.
  local function Quantile(z)
    local c = 1 - 1 / (9 * alpha) + z / (3 * math.sqrt(alpha))
    return max(0, alpha * c * c * c / beta) * stack
  end
  return { rate = alpha / beta * stack, lo = Quantile(-1.2816), hi = Quantile(1.2816), days = it.sb,
    units = it.sa or 0, auctions = events, sellers = it.sq,
    -- Most of what could sell went between scans: more surely sold unseen.
    floor = (it.sf or 0) > 0.3 }
end

-- How many sell in a day according to the online data, or nil when it has
-- not watched for at least a day. Zero is an answer: none sold.
local function OnlineSold(id)
  local on, o = M.Online(id)
  if on and on.v and (o.soldDays or 0) >= 1 then return on.v end
  return nil
end

function M.Info(id)
  local it = ItemRecord(id, false)
  local now = time()
  local on = M.Online(id)
  if on and on.t and on.l and (not (it and it.lt) or on.t > it.lt) then
    -- The online snapshot is newer than the player's own last look.
    local info = {
      ladder = on.l, total = on.n or 0, age = now - on.t, source = "scan", online = true,
      blur = on.z, price = on.l[1], turnover = OnlineSold(id),
      shared = (M.Shared(id) == on) or nil,
    }
    if info.shared then info.sharedBy = select(2, M.Shared(id)) end
    info.soldKnown = info.turnover ~= nil
    if info.turnover == nil and it and (it.vn or 0) >= 0.4 then info.turnover = it.v end
    if not info.price and on.h then
      for i = #on.h - 2, 1, -3 do
        if on.h[i + 1] > 0 then
          info.lastPrice, info.lastAge = on.h[i + 1], now - on.h[i]
          break
        end
      end
    end
    return info
  end
  if it and it.lt then
    local info = {
      ladder = it.l, total = it.ln or 0, age = now - it.lt,
      summary = it.ls, partial = it.lp, source = "scan", blur = it.lz,
      price = it.l[1], turnover = (it.vn or 0) >= 0.4 and it.v or nil,
    }
    local sold = OnlineSold(id)
    if sold then
      info.turnover, info.soldKnown = sold, true
    else
      -- Sales seen between full scans, once at least an hour has been watched.
      local seen = M.Sales(id)
      if seen and seen.days >= 1 / 24 then
        info.turnover, info.sales = seen.rate, seen
        info.soldKnown = seen.days >= 0.5
      end
    end
    if not info.price then
      -- Nothing listed at the last scan; fall back to the last seen price.
      local h = M.History(it)
      for i = #h - 3, 1, -4 do
        if h[i + 1] > 0 then
          info.lastPrice, info.lastAge = h[i + 1], now - h[i]
          break
        end
      end
    end
    return info
  end
  local price, age = AuctionatorPrice(id)
  if price then
    return { price = price, age = age, source = "auctionator", flat = true }
  end
  return nil
end

-- Price history as an array of {time, price} for the price model.
function M.Series(id)
  local out = {}
  local it = ItemRecord(id, false)
  local first
  if it then
    local h = M.History(it)
    for i = 1, #h, 4 do
      local price = h[i + 2] > 0 and h[i + 2] or h[i + 1]
      if price > 0 then
        out[#out + 1] = { h[i], price }
        first = first or h[i]
      end
    end
  end
  -- Hourly prices from the online data, where the player has no scan of
  -- their own within twenty minutes.
  local on = M.Online(id)
  -- A price another player shared is one more point, unless a scan of the
  -- player's own stands at the same moment.
  local shared = M.Shared(id)
  if shared and shared.l and shared.l[1] and shared.l[1] > 0 then
    local clash = false
    for j = 1, #out do
      if math.abs(out[j][1] - shared.t) < HISTORY_MERGE_SECONDS then clash = true break end
    end
    if not clash then
      out[#out + 1] = { shared.t, shared.l[1] }
      if not first or shared.t < first then first = shared.t end
      table.sort(out, function(a, b) return a[1] < b[1] end)
    end
  end
  if on and on.h then
    local own = #out
    for i = 1, #on.h, 3 do
      local t, price = on.h[i], on.h[i + 1]
      if price and price > 0 then
        local clash = false
        for j = 1, own do
          if math.abs(out[j][1] - t) < HISTORY_MERGE_SECONDS then clash = true break end
        end
        if not clash then
          out[#out + 1] = { t, price }
          if not first or t < first then first = t end
        end
      end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
  end
  -- Older days from Auctionator's own history, if it has any.
  local A = M.Source("Auctionator") and _G.Auctionator
  if A and A.Database and A.Database.GetPriceHistory and A.Constants and A.Constants.SCAN_DAY_0 then
    local ok, hist = pcall(A.Database.GetPriceHistory, A.Database, tostring(id))
    if ok and type(hist) == "table" then
      local extra = {}
      for _, e in ipairs(hist) do
        local day = tonumber(e.rawDay)
        local lo, hi = e.minSeen, e.maxSeen
        if day and lo and hi and lo > 0 then
          local t = day * 86400 + A.Constants.SCAN_DAY_0 + 43200
          if t > time() then t = time() end
          if not first or t < first - 6 * 3600 then
            extra[#extra + 1] = { t, math.sqrt(lo * hi) }
          end
        end
      end
      for i = 1, #extra do out[#out + 1] = extra[i] end
      table.sort(out, function(a, b) return a[1] < b[1] end)
    end
  end
  return out
end

------------------------------------------------------------------------------
-- Vendors
------------------------------------------------------------------------------
-- Reagents that vendors are known to sell without limit. Prices come from
-- the game data; anything seen at a merchant overrides this.
local VENDOR_SEED = {
  2320, 2321, 4291, 8343, 14341,          -- threads
  2880, 3466, 3857,                       -- flux, coal
  3371, 3372, 8925, 18256,                -- vials
  2604, 2605, 4340, 4341, 4342, 6260, 6261, 2324, 2325, 10290, -- dyes and bleach
  4289, 2678, 2692, 3713, 159,            -- salt, spices, water
  4470, 4399, 4400, 11291, 10648,         -- wood, stocks, parchment
  2928, 8924, 8923, 2930, 5173,           -- poison reagents
  6530, 4536, 1179, 2596, 2894, 17034, 16583,
}
local seedSet

local function SeedPrice(id)
  if not seedSet then
    seedSet = {}
    for _, sid in ipairs(VENDOR_SEED) do
      local d = ns.Data.items[sid]
      if d and d[4] and d[4] > 0 then seedSet[sid] = d[4] end
    end
  end
  return seedSet[id]
end

-- What one costs from a vendor with unlimited stock, or nil.
function M.VendorBuy(id)
  local seen = ns.db and ns.db.vendor[id]
  if seen then return seen, "seen" end
  local cache = _G.AUCTIONATOR_VENDOR_PRICE_CACHE
  if type(cache) == "table" and type(cache[tostring(id)]) == "number" then
    return cache[tostring(id)], "auctionator"
  end
  local seed = SeedPrice(id)
  if seed then return seed, "known" end
  return nil
end

local function ScanMerchant()
  if not (GetMerchantNumItems and GetMerchantItemID and C_MerchantFrame and C_MerchantFrame.GetItemInfo) then
    return
  end
  local changed = false
  for i = 1, GetMerchantNumItems() do
    local id = GetMerchantItemID(i)
    local info = C_MerchantFrame.GetItemInfo(i)
    if id and info and (info.price or 0) > 0 and not info.hasExtendedCost
      and (info.stackCount or 0) > 0 and info.numAvailable == -1 then
      local unit = info.price / info.stackCount
      if ns.db.vendor[id] ~= unit then
        ns.db.vendor[id] = unit
        changed = true
      end
    end
  end
  if changed then
    ns.generation = ns.generation + 1
    ns.Fire("MARKET_UPDATED")
  end
end

ns.On("MERCHANT_SHOW", ScanMerchant)
ns.On("MERCHANT_UPDATE", ScanMerchant)

------------------------------------------------------------------------------
-- Auction house capture. Everything the auction house shows is recorded,
-- whoever asked for it (the standard window, Auctionator or CraftGraph).
------------------------------------------------------------------------------
M.ahOpen = false
M.itemResults = {}     -- [itemID] = { t, list of separate auctions } from the last search
local queue, waiting, waitStart, waitKind = {}, nil, 0, nil
local scanTotal, scanDone = 0, 0
local ticker

local function NotifySoon()
  if M.notifyPending then return end
  M.notifyPending = true
  C_Timer.After(0.3, function()
    M.notifyPending = false
    ns.Fire("MARKET_UPDATED")
  end)
end

local scanSilent = 0

local function FinishWaiting(id, silent)
  if waiting and waiting == id then
    waiting = nil
    scanDone = scanDone + 1
    if silent then scanSilent = scanSilent + 1 end
    ns.Fire("SCAN_PROGRESS", scanDone, scanTotal)
    C_Timer.After(0.05, function() ns.Safe(M.Pump) end)
  end
end

ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
  if not itemID then return end
  local raw = {}
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice and r.quantity and r.unitPrice > 0 and r.quantity > 0 then
      -- A row with a single seller can be credited to that seller.
      local owner = type(r.owners) == "table" and #r.owners == 1 and r.owners[1] or nil
      raw[#raw + 1] = { r.unitPrice, r.quantity, owner }
    end
  end
  local full = C_AuctionHouse.HasFullCommoditySearchResults(itemID)
  local total = C_AuctionHouse.GetCommoditySearchResultsQuantity
    and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) or nil
  M.Record(itemID, raw, { full = full, total = total })
  local it = M.Get(itemID)
  if it then it.k = "c" end       -- sold by the unit, any quantity
  NotifySoon()
  FinishWaiting(itemID)
end)

ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
  if not itemKey or not itemKey.itemID then return end
  local id = itemKey.itemID
  if (itemKey.itemSuffix or 0) == 0 and (itemKey.battlePetSpeciesID or 0) == 0 then
    local raw, listings = {}, {}
    local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    for i = 1, n do
      local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
      if r and r.buyoutAmount and r.buyoutAmount > 0 then
        local qty = max(r.quantity or 1, 1)
        raw[#raw + 1] = { r.buyoutAmount / qty, qty, type(r.owners) == "table" and r.owners[1] or nil }
        if r.auctionID and not r.containsOwnerItem then
          listings[#listings + 1] = { auctionID = r.auctionID, buyout = r.buyoutAmount, qty = qty }
        end
      end
    end
    table.sort(listings, function(a, b) return a.buyout / a.qty < b.buyout / b.qty end)
    M.itemResults[id] = { t = GetTime(), list = listings }
    M.Record(id, raw, { full = C_AuctionHouse.HasFullItemSearchResults(itemKey), perAuction = true })
    local it = M.Get(id)
    if it then it.k = "i" end     -- sold as separate auctions
    NotifySoon()
  end
  FinishWaiting(id)
end)

local function RecordBrowse(results)
  if type(results) ~= "table" then return nil end
  local seen = {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    if key and key.itemID and (key.itemSuffix or 0) == 0 and (key.battlePetSpeciesID or 0) == 0
      and r.minPrice and r.minPrice > 0 then
      local s = seen[key.itemID]
      if not s then
        s = { r.minPrice, 0 }
        seen[key.itemID] = s
      end
      s[1] = min(s[1], r.minPrice)
      s[2] = s[2] + (r.totalQuantity or 1)
    end
  end
  local now = time()
  for id, s in pairs(seen) do
    M.RecordSummary(id, s[1], s[2], now)
  end
  NotifySoon()
  return seen
end

ns.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
  local seen = RecordBrowse(C_AuctionHouse.GetBrowseResults())
  if waiting and waitKind == "browse" then
    local id = waiting
    if seen and not seen[id] then
      M.Record(id, {}, { full = true })
    end
    FinishWaiting(id)
  end
end)

ns.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added)
  RecordBrowse(added)
end)

------------------------------------------------------------------------------
-- Full scan results (the whole auction house at once). Auctionator's full
-- scan triggers this too, so one scan feeds both addons.
------------------------------------------------------------------------------
local replicateBusy, replicateLast = false, 0

local function ProcessReplicate()
  local n = C_AuctionHouse.GetNumReplicateItems() or 0
  M.fullPending = nil
  if n <= 0 then
    ns.Fire("FULLSCAN", "empty")
    return
  end
  -- The game repeats this event for a list we already read; only a list
  -- that differs is new data.
  local parts = { n }
  for _, idx in ipairs({ 0, floor(n / 3), floor(2 * n / 3), n - 1 }) do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
      C_AuctionHouse.GetReplicateItemInfo(idx)
    parts[#parts + 1] = tostring(itemID) .. "/" .. tostring(buyout) .. "/" .. tostring(count)
  end
  local fingerprint = table.concat(parts, ":")
  if fingerprint == M.lastFingerprint then return end
  M.lastFingerprint = fingerprint
  ns.Log("full scan list arrived: " .. n .. " auctions")
  replicateBusy = true
  replicateLast = time()
  ns.db.lastFullScan = time()
  ns.Fire("FULLSCAN", "reading", 0, n)
  local tracked = ns.Data.items
  local acc, i = {}, 0
  local function finish()
    -- The list must be the one that was read: if it grew or shrank while
    -- we were reading, nothing is recorded and it is read again.
    local after = C_AuctionHouse.GetNumReplicateItems() or 0
    if after ~= n then
      ns.Log("full scan list changed while reading (" .. n .. " to " .. after .. "); reading again")
      replicateBusy = false
      M.lastFingerprint = nil
      M.AwaitReplicate()
      return
    end
    ns.db.lastFullCount = n
    local ids = {}
    for id in pairs(tracked) do ids[#ids + 1] = id end
    local pos, now = 1, time()
    local function store()
      local stop = min(pos + 250, #ids)
      for j = pos, stop do
        local id = ids[j]
        M.TrackSales(id, acc[id] or {}, now)
        M.Record(id, acc[id] or {}, { full = true, t = now, perAuction = true })
      end
      pos = stop + 1
      if pos <= #ids then
        C_Timer.After(0, function() ns.Safe(store) end)
      else
        replicateBusy = false
        local listed = 0
        for _ in pairs(acc) do listed = listed + 1 end
        ns.Print("recorded the full auction scan: " .. n .. " auctions, "
          .. listed .. " recipe items on sale.")
        ns.Log("full scan recorded, " .. n .. " auctions, " .. listed .. " items")
        -- How busy the whole auction house was, for the market-wide pattern.
        local scans = ns.realm.scans or {}
        scans[#scans + 1] = now
        scans[#scans + 1] = n
        while #scans > 600 do
          table.remove(scans, 1)
          table.remove(scans, 1)
        end
        ns.realm.scans = scans
        ns.Fire("FULLSCAN", "done", n, listed)
        ns.Fire("MARKET_UPDATED")
      end
    end
    store()
  end
  local getBand = C_AuctionHouse.GetReplicateItemTimeLeft
  -- Reading is spread over frames. In the foreground a frame gets a few
  -- milliseconds of it; with the game in the background, where frames are
  -- seconds apart, each gets much more, so a scan does not take minutes.
  local clock = debugprofilestop
  local lastStep = clock and clock() or 0
  local function step()
    local began = clock and clock() or 0
    local budget = (clock and began - lastStep > 150) and 120 or 10
    lastStep = began
    local stop = clock and n or min(i + 500, n)
    while i < stop do
      if clock and i % 200 == 199 and clock() - began > budget then break end
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID =
        C_AuctionHouse.GetReplicateItemInfo(i)
      if itemID and tracked[itemID] and buyout and buyout > 0 and count and count > 0 then
        local a = acc[itemID]
        if not a then
          a = {}
          acc[itemID] = a
        end
        local band = getBand and getBand(i) or nil
        a[#a + 1] = { buyout / count, count, owner, type(band) == "number" and band or nil }
      end
      i = i + 1
    end
    if i < n then
      ns.Fire("FULLSCAN", "reading", i, n)
      C_Timer.After(0, function() ns.Safe(step) end)
    else
      ns.Fire("FULLSCAN", "storing")
      finish()
    end
  end
  step()
end

-- The game sends the list in pieces, with this event after each: a
-- thousand auctions, then tens of thousands, then the rest. A piece is not
-- a scan: anything not yet arrived would look like "none listed". So the
-- list is read only once it has stopped growing: the same length on three
-- looks a second apart with no event in between. A list much shorter than
-- the last complete one is given longer before it is believed.
local replicateWaiting, replicateTouched = false, false

function M.AwaitReplicate()
  replicateTouched = true
  if replicateWaiting then return end
  replicateWaiting = true
  local lastCount, steady, looks = -1, 0, 0
  local function look()
    local count = C_AuctionHouse.GetNumReplicateItems() or 0
    looks = looks + 1
    if replicateTouched or count ~= lastCount or replicateBusy then
      replicateTouched, lastCount, steady = false, count, 0
    else
      steady = steady + 1
    end
    local short = count < 0.6 * (ns.db.lastFullCount or 0)
      and time() - (ns.db.lastFullScan or 0) < 3600
    local needed = short and 20 or 3
    if steady >= needed or looks > 120 then
      replicateWaiting = false
      ns.Safe(ProcessReplicate)
    else
      C_Timer.After(1, function() ns.Safe(look) end)
    end
  end
  C_Timer.After(1, function() ns.Safe(look) end)
end

ns.On("REPLICATE_ITEM_LIST_UPDATE", function() M.AwaitReplicate() end)

-- Seconds until the game allows another full scan (0 = now).
-- The 15 minute limit is the game's and is shared with Auctionator.
function M.FullScanWait()
  local last = ns.db.lastFullScan or 0
  local A = _G.Auctionator
  if A and type(A.SavedState) == "table" and type(A.SavedState.TimeOfLastReplicateScan) == "number" then
    last = max(last, A.SavedState.TimeOfLastReplicateScan)
  end
  return max(0, 15 * 60 - (time() - last))
end

function M.FullScanBusy()
  return replicateBusy or M.fullPending ~= nil
end

-- Asks the server for the whole auction house. Allowed once per 15 minutes.
function M.FullScan()
  if not M.ahOpen then
    ns.Print("open the auction house to scan.")
    return false
  end
  if replicateBusy or M.fullPending then
    ns.Print("a full scan is already under way.")
    return false
  end
  local wait = M.FullScanWait()
  if wait > 0 then
    ns.Print("a full scan is allowed every 15 minutes; " .. ceil(wait / 60) .. " min left.")
    ns.Fire("FULLSCAN", "wait", ceil(wait / 60))
    return false
  end
  local started = time()
  M.fullPending = started
  ns.Log("full scan requested")
  ns.Print("full scan requested; waiting for the auction house to answer.")
  ns.Fire("FULLSCAN", "requested")
  C_AuctionHouse.ReplicateItems()
  C_Timer.After(60, function()
    if M.fullPending == started then
      M.fullPending = nil
      ns.Log("full scan: no answer after 60 s")
      ns.Print("the auction house did not answer the full scan. The game allows one every "
        .. "15 minutes per account, so an earlier scan may still be blocking it. "
        .. "\"Scan prices\" works meanwhile.")
      ns.Fire("FULLSCAN", "timeout")
    end
  end)
  return true
end

------------------------------------------------------------------------------
-- Targeted scan: look up a list of items one at a time.
------------------------------------------------------------------------------
local QUALITY_FILTERS

local function BrowseFilters()
  if not QUALITY_FILTERS then
    QUALITY_FILTERS = {}
    local f = Enum.AuctionHouseFilter
    for _, name in ipairs({ "ExactMatch", "PoorQuality", "CommonQuality", "UncommonQuality",
      "RareQuality", "EpicQuality", "LegendaryQuality", "ArtifactQuality" }) do
      if f[name] then QUALITY_FILTERS[#QUALITY_FILTERS + 1] = f[name] end
    end
  end
  return QUALITY_FILTERS
end

local function IsEquipment(id)
  if not (C_Item and C_Item.GetItemInfoInstant) then return false end
  local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(id)
  return classID == 2 or classID == 4
end

function M.IsScanning()
  return waiting ~= nil or #queue > 0
end

local function StopScan(reason)
  queue, waiting = {}, nil
  if ticker then
    ticker:Cancel()
    ticker = nil
  end
  local done, total, silent = scanDone, scanTotal, scanSilent
  scanDone, scanTotal, scanSilent = 0, 0, 0
  ns.Log("scan " .. (reason or "done") .. ": " .. done .. " of " .. total .. ", " .. silent .. " without an answer")
  ns.Fire("SCAN_PROGRESS", done, total, reason or "done", silent)
  ns.Fire("MARKET_UPDATED")
end

function M.Pump()
  if not M.ahOpen then
    StopScan("closed")
    return
  end
  if waiting then return end
  if #queue == 0 then
    if scanTotal > 0 then StopScan("done") end
    return
  end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    return
  end
  local id = table.remove(queue, 1)
  waiting, waitStart = id, GetTime()
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  if IsEquipment(id) then
    waitKind = "browse"
    C_AuctionHouse.SendBrowseQuery({
      searchString = ns.ItemName(id),
      sorts = sorts,
      filters = BrowseFilters(),
      itemClassFilters = {},
    })
  else
    waitKind = "search"
    C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(id), sorts, false)
  end
end

local function Watchdog()
  if not waiting then
    M.Pump()
    return
  end
  if GetTime() - waitStart > 5 then
    local id = waiting
    if waitKind == "search" and C_AuctionHouse.HasFullCommoditySearchResults(id)
      and (C_AuctionHouse.GetNumCommoditySearchResults(id) or 0) == 0 then
      M.Record(id, {}, { full = true })
      FinishWaiting(id)
    else
      FinishWaiting(id, true)
    end
  end
end

function M.ScanItems(ids)
  if not M.ahOpen then
    ns.Print("open the auction house to scan prices.")
    return false
  end
  local have = {}
  for _, id in ipairs(queue) do have[id] = true end
  if waiting then have[waiting] = true end
  for _, id in ipairs(ids) do
    if not have[id] then
      have[id] = true
      queue[#queue + 1] = id
      scanTotal = scanTotal + 1
    end
  end
  if not ticker then
    ticker = C_Timer.NewTicker(0.5, function() ns.Safe(Watchdog) end)
  end
  ns.Fire("SCAN_PROGRESS", scanDone, scanTotal)
  M.Pump()
  return true
end

------------------------------------------------------------------------------
-- Repairing data from before version 0.2. Full scans used to be recorded
-- piece by piece, which left "none listed" points between real prices and
-- made everything look sold; and the sales count shared a field with the
-- number of sellers. Those traces are removed once.
------------------------------------------------------------------------------
function M.Repair(db)
  if (db.dataVersion or 1) >= 2 then return 0 end
  local removed = 0
  for _, realm in pairs(db.realms or {}) do
    for _, it in pairs(realm.items or {}) do
      if type(it) == "table" and it.h then
        local h = M.History(it)
        local out = {}
        for i = 1, #h, 4 do
          -- "None listed" with a real price within forty minutes on either
          -- side was a piece of a scan, not an empty market.
          local bogus = h[i + 1] == 0 and h[i - 3] and h[i + 5]
            and h[i - 3] > 0 and h[i + 5] > 0
            and h[i] - h[i - 4] < 2400 and h[i + 4] - h[i] < 2400
          if bogus then
            removed = removed + 1
          else
            local n = #out
            out[n + 1], out[n + 2], out[n + 3], out[n + 4] = h[i], h[i + 1], h[i + 2], h[i + 3]
          end
        end
        it.h, it.hp, it.hn = out, nil, 0
        if out[1] then Compact(it, out[#out - 3]) end
        -- Turnover and sales were built on those pieces: start again.
        it.v, it.vn, it.sa, it.sc, it.sb, it.sf, it.sh, it.sq, it.au = nil, nil, nil, nil, nil, nil, nil, nil, nil
        it.sn = it.sl and #it.sl / 2 or nil
      end
    end
  end
  db.dataVersion = 2
  return removed
end

ns.Listen("LOGIN", function()
  local removed = M.Repair(ns.db)
  if removed > 0 then
    ns.Log("repaired history: " .. removed .. " false \"none listed\" points removed")
    ns.generation = ns.generation + 1
  end
end)

ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
  if #queue > 0 and not waiting then M.Pump() end
end)

------------------------------------------------------------------------------
-- Auto scan: while the auction house is open, keep prices fresh without a
-- click. A full scan runs whenever the game allows one (every 15 minutes);
-- in between, the items that matter now (the plan and the graph on screen)
-- are looked up again every settings.autoMinutes.
------------------------------------------------------------------------------
local AUTO_MAX_ITEMS = 60
local autoTicker

-- M.autoItems is set by the window: a function returning the item ids to
-- keep fresh.
local function AutoIds()
  local out, seen = {}, {}
  local ids = M.autoItems and M.autoItems() or {}
  for _, id in ipairs(ids) do
    -- Equipment is looked up through the browse list, which would replace
    -- what the player is looking at; the full scan covers it instead.
    if not seen[id] and not IsEquipment(id) and #out < AUTO_MAX_ITEMS then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

-- What the auto scan will do next and in how many seconds:
-- "full" or "items", or nil when it is off or the auction house is closed.
function M.AutoNext()
  if not ns.settings.autoScan or not M.ahOpen then return nil end
  local now = time()
  local full = max(M.FullScanWait(), (M.autoHold or 0) - now)
  local items = max(0, (ns.db.lastAutoScan or 0) + (ns.settings.autoMinutes or 10) * 60 - now)
  if full <= items then return "full", full end
  return "items", items
end

-- Is the standard auction window on one of its buy or sell pages?
function M.HandTrading()
  local f, modes = _G.AuctionHouseFrame, _G.AuctionHouseFrameDisplayMode
  if not f or not modes or not f.IsShown or not f:IsShown() or not f.GetDisplayMode then return false end
  local ok, mode = pcall(f.GetDisplayMode, f)
  if not ok or mode == nil then return false end
  return mode == modes.CommoditiesBuy or mode == modes.ItemBuy
    or mode == modes.CommoditiesSell or mode == modes.ItemSell
end

function M.AutoTick()
  if not ns.settings.autoScan or not M.ahOpen then return end
  if M.IsScanning() or M.FullScanBusy() then return end
  -- Never in the middle of a purchase or a listing.
  if ns.Jobs and ns.Jobs.Busy and ns.Jobs.Busy() then return end
  local what, wait = M.AutoNext()
  if not what or wait > 0 then return end
  -- While the player is buying or selling by hand in the auction window,
  -- item lookups wait: their results would land in the middle of it.
  if what == "items" and M.HandTrading() then return end
  if what == "full" then
    -- The item lookups keep their own clock: it moves only when a full
    -- scan really arrives, so one that gets no answer cannot hold them up.
    ns.Log("auto scan: full")
    M.FullScan()
    return
  end
  ns.db.lastAutoScan = time()
  local ids = AutoIds()
  if #ids > 0 then
    ns.Log("auto scan: " .. #ids .. " items")
    M.ScanItems(ids)
  end
end

-- A full scan the server did not answer (another character used the
-- allowance, say) is not asked for again straight away.
ns.Listen("FULLSCAN", function(stage)
  if stage == "timeout" or stage == "empty" then
    -- Wait longer after each miss: 5, 10, 20, then 30 minutes.
    M.autoMisses = (M.autoMisses or 0) + 1
    M.autoHold = time() + min(30, 5 * 2 ^ (M.autoMisses - 1)) * 60
  end
  if stage == "done" then
    M.autoMisses = 0
    ns.db.lastAutoScan = time()
    M.sessionFullScans = (M.sessionFullScans or 0) + 1
  end
end)

ns.On("AUCTION_HOUSE_SHOW", function()
  M.ahOpen = true
  ns.Fire("AH_STATE", true)
  if not autoTicker then
    autoTicker = C_Timer.NewTicker(10, function() ns.Safe(M.AutoTick) end)
  end
  -- A moment for the window to settle, then the first look.
  C_Timer.After(2, function() ns.Safe(M.AutoTick) end)
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  M.ahOpen = false
  M.fullPending = nil
  if autoTicker then
    autoTicker:Cancel()
    autoTicker = nil
  end
  if M.IsScanning() then StopScan("closed") end
  ns.Fire("AH_STATE", false)
end)
