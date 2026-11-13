-- CraftGraph news: what moved in the market lately, said plainly.
--
-- For every item with prices (the player's own scans, the base data from
-- before them, Blizzard's hourly data and shared prices where those are
-- switched on), its usual price over the newest day of data is compared
-- with the day before and with a week before. Items are then gathered:
--   by kind of goods   (the game's own item kinds: Herb, Cloth, Potion, ...)
--   by profession and rank: for each profession and each rank (Apprentice,
--                      Journeyman, ...), the materials its recipes use and
--                      the goods they make
-- A group's change is the middle of its items' changes, with a range that
-- holds it four times in five. "Up" or "down" is said only at three chances
-- in four; otherwise "steady" (the range stays within 2%) or "unclear".
--
-- The day is the 24 hours up to the newest data, not the calendar day: with
-- scans now and then, that is the last day anything was seen. The week
-- compares with the day a week before; with less history it compares with
-- the earliest day there is and says how many days that spans.
--
-- Working through thousands of items is spread over frames.
local ADDON, ns = ...
local N = {}
ns.News = N

local floor, max, min, abs, exp, log, sqrt = math.floor, math.max, math.min, math.abs, math.exp, math.log, math.sqrt
local DAY = 86400

N.MIN_ITEMS = 4            -- a group needs this many items with a change to be judged
N.STEADY = 0.02            -- a range within this either side of nothing is "steady"
N.SURE_Z = 0.6745          -- three chances in four that the direction is right
N.RANGE_Z = 1.2816         -- the range holds four times in five
N.SCAN_SCATTER = 0.04      -- what one scan's price may be off by (log), at the least
N.FRESH = 10 * 60          -- news younger than this is not worked out again
N.THIN_UNITS = 2           -- this few on sale is an asking price, not a market: left out
N.MOVER_UNITS = 5          -- a single mover must have at least this many on sale

-- Ranks by the skill at which a recipe is learned. The game data gives the
-- skill where a recipe turns yellow; it is learned roughly 15 below that.
N.RANKS = {
  { name = "Apprentice", from = 1, to = 74 },
  { name = "Journeyman", from = 75, to = 149 },
  { name = "Expert", from = 150, to = 224 },
  { name = "Artisan", from = 225, to = 299 },
  { name = "Master", from = 300, to = 1000 },
}
N.LEARN_BELOW_YELLOW = 15

function N.RankOf(recipe)
  local yellow = recipe[8] or 0
  if yellow <= 0 then return nil end
  local learn = max(1, yellow - N.LEARN_BELOW_YELLOW)
  for i, r in ipairs(N.RANKS) do
    if learn <= r.to then return i end
  end
  return #N.RANKS
end

------------------------------------------------------------------------------
-- Groups
------------------------------------------------------------------------------
local groups

-- The professions worth a section: those with at least ten recipes that
-- have a skill level, so not class skills or test entries.
local function Professions()
  local count = {}
  for _, r in pairs(ns.Data.recipes) do
    if (r[8] or 0) > 0 then count[r[1]] = (count[r[1]] or 0) + 1 end
  end
  local list = {}
  for skill, n in pairs(count) do
    local name = ns.Data.skills[skill]
    if n >= 10 and name and not name:find("%[") then list[#list + 1] = { skill = skill, name = name } end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- Which items each profession's rank uses and makes: per profession a list
-- of ranks, each { mats = set, goods = set }.
local function ProfessionGroups()
  local out = {}
  local byskill = {}
  for _, p in ipairs(Professions()) do
    p.ranks = {}
    for i = 1, #N.RANKS do p.ranks[i] = { mats = {}, goods = {} } end
    byskill[p.skill] = p
    out[#out + 1] = p
  end
  for _, r in pairs(ns.Data.recipes) do
    local p = byskill[r[1]]
    local rank = p and N.RankOf(r)
    if rank then
      local g = p.ranks[rank]
      if r[3] and r[3] > 0 then g.goods[r[3]] = true end
      local reagents = r[7] or {}
      for i = 1, #reagents, 2 do g.mats[reagents[i]] = true end
    end
  end
  return out
end

-- The game's own kind of an item: a key and a name, or nil when the game
-- cannot say. Trade goods and consumables by their sub-kind (Herb, Cloth,
-- Potion), everything else by its main kind (Armor, Weapon, Recipe).
function N.KindOf(id)
  if not (C_Item and C_Item.GetItemInfoInstant) then return nil end
  local ok, _, itemType, subType, _, _, classID, subClassID = pcall(C_Item.GetItemInfoInstant, id)
  if not ok or not classID then return nil end
  if (classID == 7 or classID == 0) and subType and subType ~= "" then
    return classID .. ":" .. (subClassID or 0), subType, classID, itemType
  end
  if itemType and itemType ~= "" then return tostring(classID), itemType, classID, itemType end
  return nil
end

local function Groups()
  if not groups then groups = { professions = ProfessionGroups() } end
  return groups
end
N.Groups = Groups

------------------------------------------------------------------------------
-- Per item
------------------------------------------------------------------------------
-- Every item some source has a price for.
local function Candidates()
  local ids, seen = {}, {}
  local function add(id)
    if type(id) == "number" and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  for id in pairs(ns.realm and ns.realm.items or {}) do add(id) end
  for id in pairs(ns.Market.BaseItems()) do add(id) end
  local _, online = ns.Market.Online(0)
  if online and online.items then
    for id in pairs(online.items) do add(id) end
  end
  table.sort(ids)
  return ids
end

-- The newest moment any used source has data for, and which one it is.
function N.Anchor()
  local best, from = nil, nil
  local function consider(t, what)
    if t and (not best or t > best) then best, from = t, what end
  end
  for _, it in pairs(ns.realm and ns.realm.items or {}) do
    if type(it) == "table" then consider(it.lt, "own") end
  end
  local _, online = ns.Market.Online(0)
  if online then consider(online.updated, "online") end
  local base = ns.Market.BaseMeta()
  if base then consider(base.to, "base") end
  return best, from
end

local function Middle(sorted)
  local n = #sorted
  return n % 2 == 1 and sorted[(n + 1) / 2] or (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

-- Middle and spread of the log prices of a series' points in (a, b], and
-- the middle of the units listed where they are known.
local function Window(series, a, b)
  local xs, us = {}, {}
  for i = #series, 1, -1 do
    local t = series[i][1]
    if t <= a then break end
    if t <= b then
      xs[#xs + 1] = log(series[i][2])
      if series[i][3] then us[#us + 1] = series[i][3] end
    end
  end
  local n = #xs
  if n == 0 then return nil end
  table.sort(xs)
  table.sort(us)
  local mid = Middle(xs)
  local var = 0
  for i = 1, n do var = var + (xs[i] - mid) ^ 2 end
  var = n > 1 and var / (n - 1) or 0
  return mid, n, var, us[1] and Middle(us) or nil
end

-- The changes of one item: day and week (log), their doubt, the week's span.
function N.ItemChange(series, anchor)
  if #series == 0 or series[#series][1] <= anchor - DAY then return nil end
  local m0, n0, v0, listed = Window(series, anchor - DAY, anchor)
  if not m0 then return nil end
  local floorVar = N.SCAN_SCATTER ^ 2
  local function Doubt(n1, v1)
    return sqrt(max(v0, floorVar) / n0 + max(v1, floorVar) / n1)
  end
  local out = { now = exp(m0), n0 = n0, listed = listed,
    thin = listed ~= nil and listed <= N.THIN_UNITS or nil }
  local m1, n1, v1 = Window(series, anchor - 2 * DAY, anchor - DAY)
  if m1 then
    out.day, out.daySd, out.n1 = m0 - m1, Doubt(n1, v1), n1
  end
  -- A week back; failing that, the earliest day there is, if it is at
  -- least a day and a half back (else it is no more than the day).
  local m7, n7, v7 = Window(series, anchor - 8 * DAY, anchor - 6 * DAY)
  local span = 7
  if not m7 then
    local first = series[1][1]
    if first + DAY <= anchor - 1.5 * DAY then
      m7, n7, v7 = Window(series, first - 1, first + DAY)
      span = (anchor - (first + DAY / 2)) / DAY
    end
  end
  if m7 then
    out.week, out.weekSd, out.span, out.n7 = m0 - m7, Doubt(n7, v7), span, n7
  end
  return out
end

------------------------------------------------------------------------------
-- Groups summed up
------------------------------------------------------------------------------
local Median = Middle

-- A group's change from its items' changes (log): the middle, a range that
-- holds four times in five, the direction when it is three chances in four.
-- { n, change, lo, hi, dir (1, -1 or 0), word ("up", "down", "steady",
-- "unclear") } or { n, word = "few" } with too few items.
function N.Sum(values)
  local n = #values
  if n < N.MIN_ITEMS then return { n = n, word = "few" } end
  local xs = {}
  for i = 1, n do xs[i] = values[i] end
  table.sort(xs)
  local mid = Median(xs)
  local dev = {}
  for i = 1, n do dev[i] = abs(xs[i] - mid) end
  table.sort(dev)
  -- The doubt of a middle: the spread of the items (robustly) over the
  -- square root of how many there are, never below what scans can tell.
  local spread = max(1.4826 * Median(dev), N.SCAN_SCATTER)
  local se = 1.2533 * spread / sqrt(n)
  local z = mid / se
  local s = { n = n, change = exp(mid) - 1, lo = exp(mid - N.RANGE_Z * se) - 1, hi = exp(mid + N.RANGE_Z * se) - 1, z = z }
  if z >= N.SURE_Z then
    s.dir, s.word = 1, "up"
  elseif z <= -N.SURE_Z then
    s.dir, s.word = -1, "down"
  elseif s.lo >= -N.STEADY and s.hi <= N.STEADY then
    s.dir, s.word = 0, "steady"
  else
    s.dir, s.word = 0, "unclear"
  end
  return s
end

-- Sums a set of items for both spans. With `members` given, the items in
-- it, else all. Also the median week span. Returns { day, week, span, items }.
local function SumSet(changes, members)
  local d, w, spans, items = {}, {}, {}, {}
  for id in pairs(members or changes) do
    local c = changes[id]
    if c and not c.thin then
      if c.day then d[#d + 1] = c.day end
      if c.week then
        w[#w + 1] = c.week
        spans[#spans + 1] = c.span
      end
      if c.day or c.week then items[#items + 1] = id end
    end
  end
  table.sort(items)
  table.sort(spans)
  return { day = N.Sum(d), week = N.Sum(w), span = spans[1] and Median(spans) or nil, items = items }
end

------------------------------------------------------------------------------
-- Working it out, a share each frame
------------------------------------------------------------------------------
local job
N.result = nil

local function Finish(j)
  local changes = j.changes
  local r = {
    at = time(), anchor = j.anchor, anchorFrom = j.anchorFrom, gen = j.gen,
    items = j.counted, all = SumSet(changes), kinds = {}, professions = {}, rising = {}, falling = {},
  }
  -- By kind of goods.
  local kinds, names, classOf, mainName = {}, {}, {}, {}
  for id in pairs(changes) do
    local key, name, classID, main = N.KindOf(id)
    if key then
      kinds[key] = kinds[key] or {}
      kinds[key][id] = true
      names[key], classOf[key], mainName[key] = name, classID, main
    end
  end
  local thin = 0
  for _, c in pairs(changes) do if c.thin then thin = thin + 1 end end
  r.thin = thin
  -- The same name for two kinds ("Other"): add the main kind.
  local seenName = {}
  for key, name in pairs(names) do seenName[name] = (seenName[name] or 0) + 1 end
  for key, name in pairs(names) do
    if seenName[name] > 1 and mainName[key] then names[key] = name .. " (" .. mainName[key] .. ")" end
  end
  local left = 0
  for key, members in pairs(kinds) do
    local s = SumSet(changes, members)
    s.key, s.name, s.class = key, names[key], classOf[key]
    if s.day.word ~= "few" or s.week.word ~= "few" then
      r.kinds[#r.kinds + 1] = s
    else
      left = left + 1
    end
  end
  -- Trade goods first, then consumables, then the rest; larger groups first.
  local order = { [7] = 1, [0] = 2 }
  table.sort(r.kinds, function(a, b)
    local oa, ob = order[a.class] or 3, order[b.class] or 3
    if oa ~= ob then return oa < ob end
    if #a.items ~= #b.items then return #a.items > #b.items end
    return a.name < b.name
  end)
  r.kindsLeft = left
  r.kindsKnown = next(kinds) ~= nil
  -- By profession and rank.
  for _, p in ipairs(Groups().professions) do
    local entry = { name = p.name, skill = p.skill, ranks = {} }
    for i, g in ipairs(p.ranks) do
      entry.ranks[i] = { name = N.RANKS[i].name, mats = SumSet(changes, g.mats), goods = SumSet(changes, g.goods) }
    end
    r.professions[#r.professions + 1] = entry
  end
  -- Single items that moved most over the day, among those seen at least
  -- twice in both days and sure of their direction.
  local movers = {}
  for id, c in pairs(changes) do
    if c.day and c.n0 >= 2 and c.n1 >= 2 and abs(c.day) >= N.SURE_Z * c.daySd and c.now >= 100
      and (c.listed or 0) >= N.MOVER_UNITS then
      movers[#movers + 1] = { id = id, change = exp(c.day) - 1, lo = exp(c.day - N.RANGE_Z * c.daySd) - 1,
        hi = exp(c.day + N.RANGE_Z * c.daySd) - 1, now = c.now, n = c.n0 + c.n1, log = c.day }
    end
  end
  table.sort(movers, function(a, b) return a.log > b.log end)
  for i = 1, #movers do
    if movers[i].log <= 0 then break end
    r.rising[#r.rising + 1] = movers[i]
  end
  for i = #movers, 1, -1 do
    if movers[i].log >= 0 then break end
    r.falling[#r.falling + 1] = movers[i]
  end
  r.changes = changes
  return r
end

local function Step()
  local j = job
  if not j then return end
  local started = type(debugprofilestop) == "function" and debugprofilestop()
  local done = 0
  while j.next <= #j.ids do
    local id = j.ids[j.next]
    j.next = j.next + 1
    local c = N.ItemChange(ns.Market.Series(id), j.anchor)
    if c then
      j.changes[id] = c
      j.counted = j.counted + 1
    end
    done = done + 1
    -- A few milliseconds a frame; without a clock, a fixed share.
    if started then
      if debugprofilestop() - started > j.budget then break end
    elseif done >= 150 then
      break
    end
  end
  if j.next > #j.ids then
    job = nil
    N.result = Finish(j)
    ns.Fire("NEWS")
    for _, fn in ipairs(j.done) do ns.Safe(fn, N.result) end
  else
    C_Timer.After(0, Step)
  end
end

-- Works the news out again (unless it is fresh), then calls done(result).
-- force: even when fresh.
function N.Refresh(done, force)
  local r = N.result
  local anchor, from = N.Anchor()
  if not anchor then
    N.result = { at = time(), empty = true }
    if done then ns.Safe(done, N.result) end
    ns.Fire("NEWS")
    return
  end
  if not force and r and not r.empty and r.anchor == anchor and time() - r.at < N.FRESH then
    if done then ns.Safe(done, r) end
    return
  end
  if job then
    if done then job.done[#job.done + 1] = done end
    return
  end
  job = { ids = Candidates(), next = 1, changes = {}, counted = 0, anchor = anchor, anchorFrom = from,
    gen = ns.generation, done = { done }, budget = 8 }
  ns.Fire("NEWS")
  C_Timer.After(0, Step)
end

-- How far along the working out is (0 to 1), or nil when it is not running.
function N.Progress()
  if not job then return nil end
  return (job.next - 1) / max(1, #job.ids)
end

------------------------------------------------------------------------------
-- Words
------------------------------------------------------------------------------
local function Pct(x)
  local p = floor(abs(x) * 100 + 0.5)
  return p .. "%"
end

local function Signed(x)
  local p = floor(x * 100 + 0.5)
  return (p > 0 and "+" or (p < 0 and "-" or "")) .. abs(p)
end

-- "x2.5" for a price that went to two and a half times what it was.
local TIMES = "\195\151"
local function Times(x)
  local f = 1 + x
  return (f >= 10 and tostring(floor(f + 0.5)) or string.format("%.1f", f)) .. TIMES
end

-- A change in words with its range, coloured when the direction is sure:
-- "up 4% (+2 to +6%)", or for a price that more than doubled "up 3.1\195\151
-- (2.4 to 3.9\195\151)". plain: no colours.
function N.Words(s, plain)
  if not s or s.word == "few" then
    return (plain and "" or "|cff808080") .. "too few items" .. (plain and "" or "|r")
  end
  local range = "(" .. Signed(s.lo) .. " to " .. Signed(s.hi) .. "%)"
  local text
  if s.word == "up" and s.change >= 1 then
    range = "(" .. Times(s.lo):gsub(TIMES, "") .. " to " .. Times(s.hi) .. ")"
    text = (plain and "" or "|cff4dd94d") .. "up " .. Times(s.change) .. (plain and " " or "|r |cff808080") .. range
  elseif s.word == "up" then
    text = (plain and "" or "|cff4dd94d") .. "up " .. Pct(s.change) .. (plain and " " or "|r |cff808080") .. range
  elseif s.word == "down" then
    text = (plain and "" or "|cffff6659") .. "down " .. Pct(s.change) .. (plain and " " or "|r |cff808080") .. range
  else
    text = (plain and "" or "|cffb3b3b3") .. s.word .. (plain and " " or " |cff808080") .. range
  end
  return text .. (plain and "" or "|r")
end

-- "over the day", "over 7 days", "over 3 days".
function N.SpanWords(span)
  if not span then return "over the week" end
  local d = floor(span + 0.5)
  return "over " .. d .. (d == 1 and " day" or " days")
end

-- One line for chat, once a day: the market overall and the kinds of goods
-- that moved surely, or nil when there is nothing sure to say.
function N.Headline(r)
  r = r or N.result
  if not r or r.empty or not r.all then return nil end
  local parts = {}
  if r.all.day.word ~= "few" then parts[#parts + 1] = "prices overall " .. N.Words(r.all.day, true) .. " over the day" end
  local moved = {}
  for _, k in ipairs(r.kinds) do
    if k.day.dir ~= 0 and k.day.dir then moved[#moved + 1] = k end
  end
  table.sort(moved, function(a, b) return abs(a.day.z) > abs(b.day.z) end)
  for i = 1, min(3, #moved) do
    local ch = moved[i].day.change
    parts[#parts + 1] = moved[i].name .. " " .. moved[i].day.word .. " " .. (ch >= 1 and Times(ch) or Pct(ch))
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "; ")
end

-- Once a day, a little after logging in: the headline in chat.
ns.Listen("LOGIN", function()
  C_Timer.After(20, function()
    if not ns.settings or ns.settings.newsChat == false then return end
    local today = date("%Y-%m-%d")
    if ns.settings.newsDay == today then return end
    N.Refresh(function(r)
      local line = N.Headline(r)
      if not line then return end
      ns.settings.newsDay = today
      local old = r.anchor and time() - r.anchor > DAY
      ns.Print("news: " .. line .. "." .. (old and " |cffff8c33(newest data " .. ns.Age(time() - r.anchor) .. ")|r" or "")
        .. " |cff808080/cg news|r")
    end)
  end)
end)
