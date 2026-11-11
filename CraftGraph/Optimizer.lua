-- CraftGraph planner: the cheapest way to end up with N of an item.
-- Every unit can come from the auction house (walking up the price ladder,
-- so buying more costs more), from a vendor, or from crafting, which needs
-- its own reagents in turn. The plan is built in small steps; each step
-- takes whichever source is cheapest given what earlier steps already used.
local ADDON, ns = ...
local O = {}
ns.Opt = O

local ceil, min, max, sqrt = math.ceil, math.min, math.max, math.sqrt

local BIG = 1e11          -- price of a unit that cannot be had at all
local SHORT_PENALTY = 1.25 -- price factor for units beyond the listed supply
local MAX_DEPTH = 6
local STEPS = 40

------------------------------------------------------------------------------
-- Recipe index
------------------------------------------------------------------------------
-- Recipe rows: { skillLine, minSkill, product, yield, cooldown, name, reagents }
O.byProduct, O.uses = {}, {}

local function BuildIndex()
  for spell, r in pairs(ns.Data.recipes) do
    local product = r[3]
    O.byProduct[product] = O.byProduct[product] or {}
    table.insert(O.byProduct[product], spell)
    local reagents = r[7]
    for i = 1, #reagents, 2 do
      local item = reagents[i]
      O.uses[item] = O.uses[item] or {}
      table.insert(O.uses[item], spell)
    end
  end
  for _, list in pairs(O.byProduct) do table.sort(list) end
  for _, list in pairs(O.uses) do table.sort(list) end
end
BuildIndex()

function O.Recipe(spell)
  return ns.Data.recipes[spell]
end

function O.IsCraftable(id)
  return O.byProduct[id] ~= nil
end

------------------------------------------------------------------------------
-- Plan state with an undo journal, so options can be tried and rolled back.
------------------------------------------------------------------------------
local function NewState()
  return {
    used = {},      -- units taken from each item's auction ladder
    surplus = {},   -- spare units left over from crafts that make several
    buy = {}, buyCost = {},
    vend = {}, vendCost = {},
    casts = {},     -- [spell] = times crafted
    missing = {},   -- units with no source at all
    short = {},     -- units wanted beyond what is listed
    guess = {},     -- items whose price depth is a guess
    journal = {},
    info = {},      -- market info cache
  }
end

local function Add(st, tbl, key, delta)
  tbl[key] = (tbl[key] or 0) + delta
  local j = st.journal
  local n = #j
  j[n + 1], j[n + 2], j[n + 3] = tbl, key, delta
end

local function Rollback(st, mark)
  local j = st.journal
  for n = #j, mark + 1, -3 do
    local tbl, key, delta = j[n - 2], j[n - 1], j[n]
    local v = (tbl[key] or 0) - delta
    if v > -1e-9 and v < 1e-9 then v = nil end
    tbl[key] = v
    j[n], j[n - 1], j[n - 2] = nil, nil, nil
  end
end

local function Info(st, id)
  local info = st.info[id]
  if info == nil then
    info = ns.Market.Info(id) or false
    st.info[id] = info
  end
  return info
end

-- Cost of buying k more units at auction, or nil if it cannot be bought.
-- Second result: units beyond the listed supply.
local function BuyCost(st, id, k)
  local info = Info(st, id)
  if not info then return nil end
  local used = st.used[id] or 0
  if info.flat then
    return k * info.price, 0, true
  end
  local ladder = info.ladder
  if not ladder or not ladder[1] then
    if info.lastPrice then
      -- Nothing listed right now; price it at the last seen price, flagged.
      return k * info.lastPrice * SHORT_PENALTY, k
    end
    return nil
  end
  if info.summary then
    -- Only the cheapest price and the total are known: assume prices rise
    -- steadily across the listed supply.
    local n, p = max(info.total, 1), info.price
    local a, b = min(used, n), min(used + k, n)
    local cost = p * ((b - a) + ns.Market.SUMMARY_SLOPE * 0.5 * (b * b - a * a) / n)
    local short = k - (b - a)
    if short > 0 then
      cost = cost + short * p * (1 + ns.Market.SUMMARY_SLOPE) * SHORT_PENALTY
    end
    return cost, max(short, 0), true
  end
  local cost, got, last = ns.Market.Walk(ladder, used, k)
  local short = k - got
  if short > 0 then
    cost = cost + short * (last or info.price) * SHORT_PENALTY
  end
  return cost, short
end

local Acquire

local function TryRecipe(st, spell, id, k, depth, path)
  local r = ns.Data.recipes[spell]
  local yield = r[4]
  local casts = ceil(k / yield - 1e-9)
  local extra = casts * yield - k
  local cost = 0
  local reagents = r[7]
  path[id] = true
  for i = 1, #reagents, 2 do
    cost = cost + Acquire(st, reagents[i], reagents[i + 1] * casts, depth + 1, path)
  end
  path[id] = nil
  Add(st, st.casts, spell, casts)
  if extra > 0 then Add(st, st.surplus, id, extra) end
  return cost
end

local function Apply(st, id, k, option, depth, path)
  if option == "buy" then
    local cost, short, guess = BuyCost(st, id, k)
    Add(st, st.used, id, k)
    Add(st, st.buy, id, k)
    Add(st, st.buyCost, id, cost)
    if short and short > 0 then Add(st, st.short, id, short) end
    if guess then Add(st, st.guess, id, 1) end
    return cost
  elseif option == "vendor" then
    local cost = k * ns.Market.VendorBuy(id)
    Add(st, st.vend, id, k)
    Add(st, st.vendCost, id, cost)
    return cost
  elseif option == "missing" then
    Add(st, st.missing, id, k)
    return k * BIG
  else
    return TryRecipe(st, option, id, k, depth, path)
  end
end

-- Gets k units of an item by the cheapest means and returns the cost.
-- craftOnly: the item must be crafted (used for the item being planned).
Acquire = function(st, id, k, depth, path, craftOnly)
  local spare = st.surplus[id]
  if spare and spare > 0 then
    local useSpare = min(spare, k)
    Add(st, st.surplus, id, -useSpare)
    k = k - useSpare
    if k <= 0 then return 0 end
  end

  local options = {}
  if not craftOnly then
    if BuyCost(st, id, k) then options[#options + 1] = "buy" end
    if ns.Market.VendorBuy(id) then options[#options + 1] = "vendor" end
  end
  local recipes = O.byProduct[id]
  if recipes and depth < MAX_DEPTH and not path[id] then
    for i = 1, #recipes do options[#options + 1] = recipes[i] end
  end
  if #options == 0 then
    return Apply(st, id, k, "missing", depth, path)
  end
  if #options == 1 then
    return Apply(st, id, k, options[1], depth, path)
  end

  local best, bestCost
  for i = 1, #options do
    local mark = #st.journal
    local cost = Apply(st, id, k, options[i], depth, path)
    Rollback(st, mark)
    if not bestCost or cost < bestCost then
      best, bestCost = options[i], cost
    end
  end
  return Apply(st, id, k, best, depth, path)
end

------------------------------------------------------------------------------
-- Public: plans and derived numbers
------------------------------------------------------------------------------
local planCache, planGen = {}, -1

local function CacheTable()
  if planGen ~= ns.generation then
    planCache, planGen = {}, ns.generation
  end
  return planCache
end

local function Copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- Plans making `qty` of an item. Returns a table:
--   qty, produced, cost, casts, buy, buyCost, vend, vendCost, missing,
--   short, guess, complete, craftable
function O.Plan(id, qty)
  qty = max(1, ns.Round(qty))
  local cache = CacheTable()
  local key = id .. ":" .. qty
  if cache[key] then return cache[key] end

  local st = NewState()
  local craftable = O.IsCraftable(id)
  local cost = 0
  local step = max(1, ceil(qty / STEPS))
  local left = qty
  while left > 0 do
    local k = min(step, left)
    cost = cost + Acquire(st, id, k, 0, {}, craftable)
    left = left - k
  end

  local missingUnits = 0
  for _, n in pairs(st.missing) do missingUnits = missingUnits + n end
  local plan = {
    item = id, qty = qty, craftable = craftable,
    produced = qty + (st.surplus[id] or 0),
    cost = cost - missingUnits * BIG,
    casts = Copy(st.casts),
    buy = Copy(st.buy), buyCost = Copy(st.buyCost),
    vend = Copy(st.vend), vendCost = Copy(st.vendCost),
    missing = Copy(st.missing), short = Copy(st.short), guess = Copy(st.guess),
  }
  plan.complete = next(plan.missing) == nil
  cache[key] = plan
  return plan
end

-- Cheapest cost of one unit by any means (buying included), or nil.
function O.UnitCost(id)
  local cache = CacheTable()
  local key = "u" .. id
  local hit = cache[key]
  if hit ~= nil then return hit or nil end
  local st = NewState()
  local cost = Acquire(st, id, 1, 0, {}, false)
  local result = (next(st.missing) == nil) and cost or false
  cache[key] = result
  return result or nil
end

-- The recipe the plan would use for one unit, or nil.
-- The margin of making one and selling it, over time: at each scan of the
-- product, its price after the auction house's cut less what its materials
-- cost then (each at its latest price up to that moment; vendor goods at
-- the vendor's price). Returns { points = { {t, margin, sale, cost}, ... },
-- now, perDay (coins a day), slope (share a day), sure (0-1), word }, or
-- nil when the item is not made or prices are missing.
-- The direction is believed, not read off two points: the ratio of sale to
-- cost goes through the same model as a price, which gives a trend and how
-- sure it is. "rising" or "falling" is said only at three chances in four.
O.MARGIN_SURE = 0.75
O.MARGIN_MIN_SLOPE = 0.01        -- a share a day; less than this is not worth calling a direction
O.MARGIN_PRIOR_SLOPE = 0.05      -- before any data: no trend, give or take 5% a day
O.MARGIN_STEP = 0.5              -- days between the readings the direction is judged from
local marginCache, marginGen = {}, -1
function O.MarginTrend(id)
  if marginGen ~= ns.generation then marginCache, marginGen = {}, ns.generation end
  if marginCache[id] ~= nil then return marginCache[id] or nil end
  marginCache[id] = false
  local Mk, St = ns.Market, ns.Stats
  local spell = O.byProduct[id] and O.BestRecipe(id)
  local r = spell and ns.Data.recipes[spell]
  if not r then return nil end
  local product = Mk.Series(id)
  if #product < 2 then return nil end
  local cut = ns.settings and ns.settings.cut or 0.05
  local mats = {}
  -- Every moment anything changed: a price that stood still for days is
  -- kept as two points, so the product's own scans are not enough.
  local times, seen = {}, {}
  local function note(t)
    if t >= product[1][1] and not seen[t] then seen[t] = true times[#times + 1] = t end
  end
  for _, p in ipairs(product) do note(p[1]) end
  for i = 1, #r[7], 2 do
    local item, qty = r[7][i], r[7][i + 1]
    local vendor = Mk.VendorBuy(item)
    local series = Mk.Series(item)
    if #series == 0 and not vendor then return nil end
    for _, p in ipairs(series) do note(p[1]) end
    mats[#mats + 1] = { qty = qty, vendor = vendor, series = series, at = 1 }
  end
  table.sort(times)
  local points, at = {}, 1
  for _, t in ipairs(times) do
    while at < #product and product[at + 1][1] <= t do at = at + 1 end
    local cost = 0
    for _, m in ipairs(mats) do
      local price
      if #m.series > 0 then
        while m.at < #m.series and m.series[m.at + 1][1] <= t do m.at = m.at + 1 end
        price = m.series[m.at][2]
      end
      -- A vendor's price is a ceiling: nobody pays more at auction.
      if m.vendor and (not price or m.vendor < price) then price = m.vendor end
      cost = cost + price * m.qty
    end
    cost = cost / max(1, r[4])
    local sale = product[at][2] * (1 - cut)
    if cost > 0 and sale > 0 then points[#points + 1] = { t, sale - cost, sale, cost } end
  end
  if #points < 2 then return nil end
  local out = { points = points, now = points[#points][2], word = "no clear direction", sure = 0.5, perDay = 0, slope = 0 }
  -- The direction: is the ratio of sale to cost drifting, or only wandering?
  -- Read it every half day. The drift is the average move a day; how far
  -- that can be trusted depends on how much the moves differ from one
  -- another (the wander) and on how many days there are. Before any data
  -- the belief is "no trend, give or take 5% a day", and the wander is
  -- taken to be the market's.
  local span = (points[#points][1] - points[1][1]) / 86400
  if span < 1 then
    out.word = "too little history for a direction"
  else
    local step = O.MARGIN_STEP
    local n = math.floor(span / step)
    local readings, k = {}, 1
    for i = 0, n do
      local t = points[#points][1] - (n - i) * step * 86400
      while k < #points and points[k + 1][1] <= t do k = k + 1 end
      readings[#readings + 1] = math.log(points[k][3] / points[k][4])
    end
    local drift = (readings[#readings] - readings[1]) / (n * step)
    local sum = 0
    for i = 2, #readings do
      local off = readings[i] - readings[i - 1] - drift * step
      sum = sum + off * off / step
    end
    local prior = St.MarketPrior()
    local wander0 = prior and prior.sigma0 or St.SIGMA0
    local wander2 = (wander0 * wander0 * 2 + sum) / (2 + max(0, n - 1))
    local data, before = (n * step) / wander2, 1 / (O.MARGIN_PRIOR_SLOPE * O.MARGIN_PRIOR_SLOPE)
    local slope, sd = drift * data / (data + before), math.sqrt(1 / (data + before))
    out.slope, out.slopeSd = slope, sd
    out.sure = St.Phi(math.abs(slope) / sd)
    -- A share a day of the ratio is that share of the sale price in coins.
    out.perDay = slope * points[#points][3]
    if out.sure >= O.MARGIN_SURE and math.abs(slope) >= O.MARGIN_MIN_SLOPE then
      out.word = slope > 0 and "rising" or "falling"
    end
  end
  marginCache[id] = out
  return out
end

function O.BestRecipe(id)
  local recipes = O.byProduct[id]
  if not recipes then return nil end
  if #recipes == 1 then return recipes[1] end
  local plan = O.Plan(id, 1)
  local best, bestCasts
  for _, spell in ipairs(recipes) do
    local c = plan.casts[spell]
    if c and (not bestCasts or c > bestCasts) then best, bestCasts = spell, c end
  end
  return best or recipes[1]
end

-- What one unit sells for at auction right now, before the cut, or nil.
function O.SalePrice(id)
  local info = ns.Market.Info(id)
  if info and info.price then return info.price, info end
  local est = ns.Stats.Estimate(id, 0)
  if est then return est, info end
  if info and info.lastPrice then return info.lastPrice, info end
  return nil, info
end

-- Full picture of making `qty`: plan, sale value, profit and its margin.
function O.Evaluate(id, qty)
  local plan = O.Plan(id, qty)
  local e = { plan = plan, qty = plan.qty, produced = plan.produced, cost = plan.cost }
  local price, info = O.SalePrice(id)
  local cut = ns.settings and ns.settings.cut or 0.05
  e.turnover = info and info.turnover or nil
  e.soldKnown = info and info.soldKnown or nil
  e.listed = info and info.source == "scan" and info.price and info.total or nil
  if e.turnover and e.turnover > 0 then
    e.daysToSell = plan.produced / e.turnover
  end
  if price then
    e.unitSale = price * (1 - cut)
    e.revenue = e.unitSale * plan.produced
    if plan.craftable and plan.complete then
      e.profit = e.revenue - e.cost
    end
  end

  -- Error margin: every price carries its own uncertainty; they add in
  -- quadrature. The sale happens later, so its uncertainty looks ahead.
  local var = 0
  if e.revenue then
    local ahead = min((e.daysToSell or 1) / 2, 7)
    local _, sd = ns.Stats.Estimate(id, ahead)
    sd = sd or ns.Stats.DEFAULT_SD
    -- A price set by one or two listings is an asking price, not proof of
    -- what the item sells for: the fewer listed, the less it is trusted.
    local thin = e.listed and 0.5 / sqrt(max(e.listed, 1)) or 0
    var = var + e.revenue * e.revenue * (sd * sd + thin * thin)
  end
  for item, c in pairs(plan.buyCost) do
    local _, sd = ns.Stats.Estimate(item, 0)
    sd = sd or ns.Stats.DEFAULT_SD
    if plan.guess[item] then sd = sqrt(sd * sd + 0.15 * 0.15) end
    var = var + (c * sd) ^ 2
  end
  e.sd = sqrt(var)
  return e
end

-- Quantity with the highest profit. It never asks for more materials than
-- are listed, and it is limited to what the market is seen to absorb within
-- the configured number of days. Until demand is known (two scans of the
-- item) it is limited to one stack and to no more than is listed now. A
-- recipe with a cooldown is limited to one. Returns qty, evaluation,
-- demandKnown.
local GRID = { 1, 2, 3, 5, 8, 12, 20, 30, 50, 80, 120, 200, 300, 500 }

function O.BestQuantity(id)
  local cache = CacheTable()
  local key = "b" .. id
  if cache[key] then return cache[key][1], cache[key][2], cache[key][3] end
  local first = O.Evaluate(id, 1)
  local cap, known
  if first.turnover and first.turnover > 0 then
    cap = max(1, math.floor(first.turnover * (ns.settings.horizonDays or 2)))
    known = true
  elseif first.soldKnown then
    cap, known = 1, true       -- watched for a day and none sold
  else
    local d = ns.Data.items[id]
    cap = max(1, d and d[6] or 1)
    if first.listed then cap = max(1, min(cap, first.listed)) end
    known = false
  end
  local recipe = O.BestRecipe(id)
  if recipe and ns.Data.recipes[recipe][5] > 0 then cap = 1 end
  local bestQty, best = 1, first
  local worse = 0
  for i = 2, #GRID do
    local q = min(GRID[i], cap)
    local e = O.Evaluate(id, q)
    if next(e.plan.short) then break end
    if e.profit and best.profit and e.profit > best.profit then
      bestQty, best, worse = q, e, 0
    else
      worse = worse + 1
    end
    if worse >= 2 or q >= cap then break end
  end
  cache[key] = { bestQty, best, known }
  return bestQty, best, known
end

------------------------------------------------------------------------------
-- The player: professions, skill levels and known recipes
------------------------------------------------------------------------------
local P = {}
ns.Player = P
P.version = 0
P.lines = {}

local skillByName

local function SkillIdByName(name)
  if type(name) ~= "string" then return nil end
  if not skillByName then
    skillByName = {}
    for id, n in pairs(ns.Data.skills) do skillByName[n:lower()] = id end
  end
  return skillByName[name:lower()]
end

-- Returns { [skill line] = current skill level } for the player's professions.
function P.Skills()
  local out = {}
  if GetProfessions and GetProfessionInfo then
    local a, b, c, d, e, f = GetProfessions()
    for _, index in pairs({ a, b, c, d, e, f }) do
      local ok, name, _, rank, _, _, _, skillLine, _, _, _, lineName = pcall(GetProfessionInfo, index)
      if ok and type(rank) == "number" then
        local id = (skillLine and ns.Data.skills[skillLine] and skillLine)
          or SkillIdByName(lineName) or SkillIdByName(name)
        if id then
          out[id] = rank
          -- The game's own id for this profession, needed to open its window.
          P.lines[id] = type(skillLine) == "number" and skillLine or id
        end
      end
    end
  end
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local ok, name, header, _, rank = pcall(GetSkillLineInfo, i)
      local id = ok and not header and SkillIdByName(name)
      if id and not out[id] and type(rank) == "number" then out[id] = rank end
    end
  end
  return out
end

local function Character()
  if not ns.db then return nil end
  local name = (UnitName and UnitName("player")) or "Unknown"
  local key = name .. " - " .. ((GetRealmName and GetRealmName()) or "Unknown")
  ns.db.chars = ns.db.chars or {}
  ns.db.chars[key] = ns.db.chars[key] or { known = {} }
  ns.db.chars[key].known = ns.db.chars[key].known or {}
  return ns.db.chars[key]
end

local knownCache, knownVersion = {}, -1

-- Whether the player has learned a recipe. What the profession window
-- showed is remembered; otherwise the game is asked directly.
function P.Knows(spell)
  if knownVersion ~= P.version then knownCache, knownVersion = {}, P.version end
  local hit = knownCache[spell]
  if hit ~= nil then return hit end
  local char = Character()
  local known = char and char.known[spell] or false
  if not known and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spell)
    if ok and type(info) == "table" and info.learned then known = true end
  end
  if not known and IsPlayerSpell then
    local ok, result = pcall(IsPlayerSpell, spell)
    if ok and result then known = true end
  end
  if known and char then char.known[spell] = true end
  knownCache[spell] = known
  return known
end

-- Reads the open profession window: the surest list of learned recipes.
local function ReadTradeSkill()
  local T = C_TradeSkillUI
  if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return end
  if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
    or (T.IsNPCCrafting and T.IsNPCCrafting()) then
    return
  end
  local char = Character()
  local ids = T.GetAllRecipeIDs()
  if not char or type(ids) ~= "table" then return end
  local learned, added = 0, 0
  for _, id in ipairs(ids) do
    local info = T.GetRecipeInfo(id)
    if info and info.learned then
      learned = learned + 1
      if not char.known[id] then
        char.known[id] = true
        added = added + 1
      end
    end
  end
  if added > 0 then
    ns.Log("profession window: " .. #ids .. " recipes, " .. learned .. " learned, " .. added .. " new")
    P.version = P.version + 1
    ns.Fire("PLAYER_UPDATED")
  end
end

local function PlayerChanged()
  P.version = P.version + 1
  ns.Fire("PLAYER_UPDATED")
end

ns.On("TRADE_SKILL_SHOW", ReadTradeSkill)
ns.On("TRADE_SKILL_LIST_UPDATE", ReadTradeSkill)
ns.On("NEW_RECIPE_LEARNED", function(spell)
  local char = Character()
  if char and type(spell) == "number" then char.known[spell] = true end
  PlayerChanged()
end)
ns.On("SKILL_LINES_CHANGED", PlayerChanged)

-- Colour for how likely a craft is to raise the skill: orange, yellow,
-- green or grey, as in the profession window.
function P.Difficulty(rank, yellow, grey)
  if not yellow or yellow == 0 or not grey or grey == 0 then return 1, 0.82, 0 end
  if rank < yellow then return 1, 0.5, 0.25 end
  if rank < (yellow + grey) / 2 then return 1, 1, 0 end
  if rank < grey then return 0.25, 0.75, 0.25 end
  return 0.5, 0.5, 0.5
end

-- Everything the player can craft now that makes money, best first.
-- Returns the list and a summary table.
local worthCache, worthKey

function P.Worth()
  local key = ns.generation .. ":" .. P.version
  if worthKey == key then return worthCache.list, worthCache.info end
  local skills = P.Skills()
  local known, maybe, knownIn = {}, {}, {}
  for spell, r in pairs(ns.Data.recipes) do
    local rank = skills[r[1]]
    if rank then
      if P.Knows(spell) then
        known[#known + 1] = spell
        knownIn[r[1]] = (knownIn[r[1]] or 0) + 1
      else
        maybe[#maybe + 1] = spell
      end
    end
  end
  -- A profession whose recipes could not be read at all: go by skill level
  -- until its window has been opened once.
  local unverified, guess = {}, {}
  for _, spell in ipairs(maybe) do
    local r = ns.Data.recipes[spell]
    if not knownIn[r[1]] then
      unverified[r[1]] = true
      local need = r[2] > 1 and r[2] or max(1, (r[8] or 0) - 25)
      if need <= skills[r[1]] then
        known[#known + 1] = spell
        guess[spell] = true
      end
    end
  end

  local best, considered, unpriced, losing = {}, 0, 0, 0
  for _, spell in ipairs(known) do
    local r = ns.Data.recipes[spell]
    local product = r[3]
    local d = ns.Data.items[product]
    if not (d and d[7] == 1) then          -- skip items that bind when made
      considered = considered + 1
      local e = O.Evaluate(product, 1)
      if not e.plan.complete then
        unpriced = unpriced + 1
      else
        local unitCost = e.cost / e.produced
        local each = e.profit and e.profit / e.produced
        local mode = "auction"
        local vendorEach = ns.VendorSell(product) - unitCost
        if vendorEach > 0 and (not each or vendorEach > each) then
          each, mode = vendorEach, "vendor"
        end
        if not each then
          unpriced = unpriced + 1
        elseif each <= 0 then
          losing = losing + 1
        else
          local row = {
            id = product, spell = spell, skill = r[1], rank = skills[r[1]],
            yellow = r[8], grey = r[9], guess = guess[spell], mode = mode,
            each = each, sd = e.sd / e.produced, cost = unitCost, turnover = e.turnover,
            qty = 1, batch = each * e.produced, batchSd = e.sd,
            listed = e.listed, cooldown = r[5] > 0,
          }
          if mode == "auction" then
            local qty, be = O.BestQuantity(product)
            if be.profit and be.profit > row.batch then
              row.qty, row.batch, row.batchSd = be.produced, be.profit, be.sd
            end
          end
          -- What the batch is worth if prices turn out a margin worse.
          row.safe = row.batch - row.batchSd
          row.thin = mode == "auction" and (row.listed or 0) <= 2
          row.sure = row.safe > 0 and not row.thin
          if not best[product] or best[product].each < row.each then best[product] = row end
        end
      end
    end
  end
  local list = {}
  for _, row in pairs(best) do list[#list + 1] = row end
  -- Certain earners first: ranked by the profit that remains after taking
  -- the error margin off, with thinly traded items after the rest.
  table.sort(list, function(a, b)
    if a.sure ~= b.sure then return a.sure end
    if a.safe ~= b.safe then return a.safe > b.safe end
    return a.id < b.id
  end)
  worthCache = { list = list, info = {
    skills = skills, unverified = unverified, considered = considered,
    unpriced = unpriced, losing = losing,
  } }
  worthKey = key
  return list, worthCache.info
end

------------------------------------------------------------------------------
-- Crafting from the list
------------------------------------------------------------------------------
local function ItemCount(id)
  if C_Item and C_Item.GetItemCount then
    local ok, count = pcall(C_Item.GetItemCount, id)
    if ok and type(count) == "number" then return count end
  end
  if GetItemCount then
    local ok, count = pcall(GetItemCount, id)
    if ok and type(count) == "number" then return count end
  end
  return 0
end
P.ItemCount = ItemCount

-- How many of an item sit in the bank. The game keeps this count even when
-- the bank is closed, so it is asked directly.
function P.BankCount(id)
  if not (C_Item and C_Item.GetItemCount) then return 0 end
  local ok, total = pcall(C_Item.GetItemCount, id, true, false, true)
  if not ok or type(total) ~= "number" then return 0 end
  return max(0, total - ItemCount(id))
end

-- Everything in the bank that the addon knows a price or recipe for, as
-- { item = count }. Rebuilt after the bags or bank change, and saved with
-- the character so it can be looked at later.
local bankCache, bankDirty = nil, true

function P.Bank()
  if bankCache and not bankDirty then return bankCache end
  local out = {}
  local function look(id)
    if out[id] == nil then
      local n = P.BankCount(id)
      out[id] = n > 0 and n or false
    end
  end
  for id in pairs(ns.Data.items) do look(id) end
  for id in pairs(ns.realm and ns.realm.items or {}) do look(id) end
  for id, n in pairs(out) do
    if not n then out[id] = nil end
  end
  bankCache, bankDirty = out, false
  local char = Character()
  if char then char.bank = out end
  return out
end

local function BankChanged()
  bankDirty = true
end
ns.On("BAG_UPDATE_DELAYED", BankChanged)
ns.On("PLAYERBANKSLOTS_CHANGED", BankChanged)
ns.On("PLAYER_ENTERING_WORLD", BankChanged)

-- How many times a recipe can be crafted from what is in the bags.
function P.CanMake(spell)
  local r = ns.Data.recipes[spell]
  if not r then return 0 end
  local n = math.huge
  for i = 1, #r[7], 2 do
    n = min(n, math.floor(ItemCount(r[7][i]) / r[7][i + 1]))
  end
  return n == math.huge and 0 or n
end

local pending

local function CraftBegan()
  if pending and not pending.began then
    pending.began = true
    ns.Log("craft began: " .. pending.name .. " x" .. pending.casts)
  end
end

ns.On("TRADE_SKILL_CRAFT_BEGIN", CraftBegan)
ns.On("UNIT_SPELLCAST_START", function(unit, _, spellID)
  if unit == "player" and pending and spellID == pending.spell then CraftBegan() end
end)
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
  if unit == "player" and pending and spellID == pending.spell then CraftBegan() end
end)

-- Crafts a recipe `casts` times. Must be called from a button click. The
-- profession's window has to be open first; if it is not, this opens it
-- and the button is pressed again.
function P.Craft(spell, casts)
  local T = C_TradeSkillUI
  local r = ns.Data.recipes[spell]
  if not r then return false end
  local name = r[6]
  local profession = ns.Data.skills[r[1]] or "profession"
  if InCombatLockdown and InCombatLockdown() then
    ns.Print("crafting has to wait until you are out of combat.")
    return false
  end
  if not (T and T.CraftRecipe) then
    ns.Print("this game version does not let addons start a craft.")
    return false
  end
  local can = P.CanMake(spell)
  casts = min(casts or 1, can)
  if casts < 1 then
    ns.Print("you do not have the materials for " .. name .. " in your bags.")
    return false
  end

  P.Skills()
  local want = P.lines[r[1]] or r[1]
  local ready = T.IsTradeSkillReady and T.IsTradeSkillReady()
  local base = ready and T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
  local openId = type(base) == "table" and base.professionID or nil
  local match = openId ~= nil and (openId == want or openId == r[1]
    or SkillIdByName(base.professionName) == r[1] or SkillIdByName(base.parentProfessionName) == r[1])
  if not match then
    local ok, opened = false, false
    if T.OpenTradeSkill then ok, opened = pcall(T.OpenTradeSkill, want) end
    ns.Log("craft " .. name .. ": window not ready (open id " .. tostring(openId) .. ", want "
      .. tostring(want) .. "), OpenTradeSkill -> " .. tostring(ok) .. "/" .. tostring(opened))
    if ok and opened then
      ns.Print("opened your " .. profession .. " window. Press Make again to craft " .. name .. ".")
    else
      ns.Print("open your " .. profession .. " window, then press Make again.")
    end
    return false
  end

  pending = { spell = spell, casts = casts, name = name }
  local this = pending
  local ok, err = pcall(T.CraftRecipe, spell, casts)
  ns.Log("craft " .. name .. " x" .. casts .. ": CraftRecipe -> " .. tostring(ok) .. " " .. tostring(err or ""))
  if not ok then
    pending = nil
    ns.Print("the game refused to start " .. name .. ": " .. tostring(err))
    return false
  end
  ns.Print("crafting " .. name .. " x" .. casts .. ".")
  C_Timer.After(2, function()
    if pending == this and not this.began then
      pending = nil
      ns.Log("craft " .. name .. ": nothing began within 2 s")
      if T.OpenRecipe then pcall(T.OpenRecipe, spell) end
      ns.Print("the craft did not start. " .. name .. " is now selected in your " .. profession
        .. " window: press Create there.")
    end
  end)
  return true
end

------------------------------------------------------------------------------
-- Jobs: pinned items, what each still needs, and the next step for it.
-- A job runs: buy materials at auction -> collect them from the mailbox ->
-- buy the rest from a vendor -> craft -> post the result at auction.
------------------------------------------------------------------------------
local J = {}
ns.Jobs = J
J.MAX_PINS = 5
J.place = nil          -- "merchant", "mail" or nil; the auction house is ns.Market.ahOpen

local M = ns.Market

local function PinList()
  local char = Character()
  if not char then return {} end
  char.pins = char.pins or {}
  return char.pins
end

local function Ordered()
  local char = Character()
  if not char then return {} end
  char.ordered = char.ordered or {}
  return char.ordered
end

function J.Pins()
  return PinList()
end

function J.IsPinned(id)
  for i, pin in ipairs(PinList()) do
    if pin.id == id then return i, pin end
  end
  return nil
end

-- goal: what the plan is for when it is not plain crafting:
-- { kind = "flip" | "tovendor" | "fromvendor", qty, outlay, sellEach }.
function J.Pin(id, qty, goal)
  local pins = PinList()
  local _, pin = J.IsPinned(id)
  qty = max(1, ns.Round(qty or 1))
  if pin then
    pin.qty = qty
    pin.track = nil
    if goal then pin.goal = goal end
  elseif #pins >= J.MAX_PINS then
    ns.Print("you can pin " .. J.MAX_PINS .. " items; unpin one first.")
    return false
  else
    pins[#pins + 1] = { id = id, qty = qty, posted = 0, goal = goal, since = time() }
  end
  if ns.settings then ns.settings.hudHidden = nil end
  if J.Track then ns.Safe(J.Track, true) end
  ns.Fire("JOBS")
  return true
end

function J.Unpin(id)
  local pins = PinList()
  for i = #pins, 1, -1 do
    if pins[i].id == id then table.remove(pins, i) end
  end
  ns.Fire("JOBS")
end

-- Changes how many a planned item should make.
function J.SetQty(id, qty)
  local _, pin = J.IsPinned(id)
  if not pin then return end
  pin.qty = max(1, ns.Round(qty))
  -- Another amount is another plan: its profit history starts again.
  pin.track = nil
  if J.Track then ns.Safe(J.Track, true) end
  ns.Fire("JOBS")
end

-- Limits how many of the player's own stock of `item` a table of limits
-- allows (nil = use all of it).
function J.SetUse(useTable, item, n)
  useTable[item] = n and max(0, ns.Round(n)) or nil
  ns.Fire("JOBS")
end

-- Empties the plan: every planned item, its progress, and the count of
-- purchases thought to be waiting in the mailbox.
function J.Clear()
  local char = Character()
  if not char then return end
  char.pins = {}
  char.ordered = {}
  ns.Fire("JOBS")
end

-- The player has emptied the mailbox: nothing is waiting there any more.
function J.MailCollected()
  local char = Character()
  if char then char.ordered = {} end
  ns.Fire("JOBS")
end

-- Is it worth planning to make `qty` of an item? Returns a verdict
-- ("good", "gamble", "loss", "unknown"), a sentence about it, and the
-- evaluation.
function J.Verdict(id, qty)
  local e = O.Evaluate(id, qty)
  local name = ns.Round(e.produced) .. " x " .. ns.ItemName(id)
  if not e.plan.craftable then
    return "unknown", name .. " is not something you craft; the plan will only track buying it.", e
  end
  if not e.plan.complete then
    return "unknown", "some materials for " .. name .. " have no price yet, so the profit is unknown.", e
  end
  if not e.profit then
    return "unknown", name .. " has no auction price yet, so the profit is unknown.", e
  end
  local money = ns.Money(e.profit) .. " \194\177" .. ns.Money(e.sd)
  if e.profit <= 0 then
    return "loss", "making " .. name .. " is expected to lose " .. ns.Money(-e.profit) .. ".", e
  end
  if e.profit - e.sd <= 0 then
    return "gamble", "making " .. name .. " is a gamble: +" .. money .. ", so it may well lose money.", e
  end
  return "good", "making " .. name .. " should earn +" .. money .. ".", e
end

-- Works out what a job still lacks, given what is in the bags.
-- inv: a working copy of the bags, shared when several jobs are worked out
-- in a row so two jobs do not both count on the same materials.
-- Returns { ah = {item = n}, mail = {...}, vendor = {...}, missing = {...},
--           crafts = { {spell, casts, product}, deepest first } }.
-- use: { item = n } limits how many of the player's own stock of an item
-- this job may use (missing = all of it); the rest is bought.
-- Own stock is what is in the bags plus, unless switched off, the bank; what
-- has to come out of the bank is listed in `bank`, and everything taken
-- from own stock in `own`.
function J.Needs(id, qty, inv, ord, use, goal)
  inv = inv or {}
  ord = ord or {}
  inv.total = inv.total or {}
  inv.bags = inv.bags or {}
  use = use or {}
  local useBank = not ns.settings or ns.settings.useBank ~= false
  local recipes = ns.Data.recipes
  local n = { id = id, qty = qty, ah = {}, mail = {}, vendor = {}, missing = {}, crafts = {},
    bank = {}, own = {} }
  local useLeft = {}
  local function add(tbl, item, k)
    tbl[item] = (tbl[item] or 0) + k
  end
  local function have(item)
    if inv.total[item] == nil then
      local bags = ItemCount(item)
      inv.bags[item] = bags
      inv.total[item] = bags + (useBank and P.BankCount(item) or 0)
    end
    return inv.total[item]
  end
  local function take(item, k)
    local owned = have(item)
    if useLeft[item] == nil then useLeft[item] = use[item] or math.huge end
    local used = max(0, min(owned, useLeft[item], k))
    if used > 0 then
      inv.total[item] = owned - used
      useLeft[item] = useLeft[item] - used
      local fromBags = min(inv.bags[item], used)
      inv.bags[item] = inv.bags[item] - fromBags
      n.own[item] = (n.own[item] or 0) + used
      if used > fromBags then n.bank[item] = (n.bank[item] or 0) + (used - fromBags) end
    end
    return k - used
  end
  if qty <= 0 then return n end
  -- A trade (relist, sell to a vendor, buy from one) buys the item itself
  -- at what the trade was planned for; only crafting makes it.
  if goal and goal.kind ~= "craft" then
    local bought = goal.kind == "fromvendor" and "vendor" or "ah"
    n.plan = { item = id, qty = qty, produced = qty, craftable = false, complete = true, casts = {},
      buy = bought == "ah" and { [id] = goal.qty or qty } or {},
      buyCost = bought == "ah" and goal.outlay and { [id] = goal.outlay } or {},
      vend = bought == "vendor" and { [id] = qty } or {}, vendCost = {}, missing = {}, short = {}, guess = {} }
    add(n[bought], id, qty)
    if bought == "ah" then
      if ord[id] == nil then ord[id] = Ordered()[id] or 0 end
      local m = min(qty, ord[id])
      if m > 0 then
        ord[id] = ord[id] - m
        n.mail[id] = m
        n.ah[id] = qty - m > 0 and qty - m or nil
      end
    end
    return n
  end
  local plan = O.Plan(id, qty)
  n.plan = plan
  local buyLeft = {}
  for item, k in pairs(plan.buy) do buyLeft[item] = k end
  local craftIndex = {}

  local function expand(item, k, depth, top)
    local short = top and k or take(item, k)
    -- What is already held counts against what the plan meant to buy.
    if not top and buyLeft[item] then
      buyLeft[item] = max(0, buyLeft[item] - (k - short))
    end
    if short <= 0 then return end
    local spell
    for _, sp in ipairs(O.byProduct[item] or {}) do
      if plan.casts[sp] then spell = sp break end
    end
    if top and not spell then spell = O.BestRecipe(item) end
    if spell and not top and buyLeft[item] and buyLeft[item] > 0 then
      -- The plan buys some of these and makes the rest.
      local part = min(short, buyLeft[item])
      buyLeft[item] = buyLeft[item] - part
      add(n.ah, item, part)
      short = short - part
      if short <= 0 then return end
    end
    if spell and depth < MAX_DEPTH then
      local r = recipes[spell]
      local casts = ceil(short / r[4] - 1e-9)
      for i = 1, #r[7], 2 do
        expand(r[7][i], r[7][i + 1] * casts, depth + 1, false)
      end
      local at = craftIndex[spell]
      if at then
        n.crafts[at].casts = n.crafts[at].casts + casts
      else
        n.crafts[#n.crafts + 1] = { spell = spell, casts = casts, product = item }
        craftIndex[spell] = #n.crafts
      end
    elseif plan.vend[item] or (not plan.buy[item] and M.VendorBuy(item)) then
      add(n.vendor, item, short)
    elseif plan.buy[item] or M.Info(item) then
      add(n.ah, item, short)
    else
      add(n.missing, item, short)
    end
  end

  if plan.craftable then
    expand(id, qty, 0, true)
  else
    add(n.ah, id, qty)
  end

  -- What was already bought at auction is waiting in the mailbox.
  for item, k in pairs(n.ah) do
    if ord[item] == nil then ord[item] = Ordered()[item] or 0 end
    local m = min(k, ord[item])
    if m > 0 then
      ord[item] = ord[item] - m
      n.mail[item] = m
      n.ah[item] = (k - m > 0) and (k - m) or nil
    end
  end
  return n
end

local function NameList(map, limit)
  local names = {}
  for item, k in pairs(map) do names[#names + 1] = ns.ItemName(item) .. " x" .. ns.Round(k) end
  table.sort(names)
  local extra = #names - limit
  while #names > limit do table.remove(names) end
  return table.concat(names, ", ") .. (extra > 0 and (" +" .. extra) or "")
end

local function Total(map)
  local t = 0
  for _, k in pairs(map) do t = t + k end
  return t
end

-- The next step for a job, as text and a kind: "sell", "done", "stuck",
-- "ah", "mail", "vendor" or "craft". Where the player stands decides which
-- of several open steps is shown first.
function J.Status(n, remaining, inBags, posted)
  if remaining <= 0 then
    if inBags > 0 then
      return "Post " .. ns.Round(inBags) .. " at the auction house", "sell"
    end
    return "Done: " .. ns.Round(posted or 0) .. " posted", "done"
  end
  if next(n.missing) then
    return "No source for " .. NameList(n.missing, 1), "stuck"
  end
  local steps = {}
  if next(n.ah) then steps.ah = "Buy at auction: " .. NameList(n.ah, 2) end
  if next(n.mail) then steps.mail = "Collect " .. ns.Round(Total(n.mail)) .. " from the mailbox" end
  if next(n.vendor) then steps.vendor = "Buy from a vendor: " .. NameList(n.vendor, 2) end
  if next(n.bank) then steps.bank = "Take from the bank: " .. NameList(n.bank, 2) end
  local order = { "ah", "mail", "vendor", "bank" }
  if J.place == "merchant" then order = { "vendor", "ah", "mail", "bank" } end
  if J.place == "mail" then order = { "mail", "ah", "vendor", "bank" } end
  if J.place == "bank" then order = { "bank", "ah", "mail", "vendor" } end
  if M.ahOpen then order = { "ah", "mail", "vendor", "bank" } end
  for _, kind in ipairs(order) do
    if steps[kind] then return steps[kind], kind end
  end
  local first = n.crafts[1]
  if first then
    return "Craft " .. ns.Data.recipes[first.spell][6] .. " x" .. ns.Round(first.casts), "craft"
  end
  return "Ready", "craft"
end

-- Every step of making `qty` of an item, in the order to do them: buy at
-- the auction house, pick up from the mailbox, buy from vendors (with where),
-- take from the bank, craft, post. `job` (from J.All) gives the steps still
-- open for a planned item; without it they are worked out from what the
-- player holds now. Each step: { kind, text, where, cost, gain, now }.
function J.Steps(id, qty, job)
  local needs, remaining, inBags, pin
  if job then
    needs, remaining, inBags, pin = job.needs, job.remaining, job.inBags, job.pin
    if pin then id, qty = pin.id, pin.qty end
  else
    needs, remaining, inBags = J.Needs(id, qty), qty, 0
  end
  local steps = {}
  local plan = needs.plan
  local function costOf(map, costs, bought)
    local total = 0
    for item, k in pairs(map) do
      if costs and costs[item] and bought[item] and bought[item] > 0 then
        total = total + costs[item] * min(1, k / bought[item])
      else
        local info = M.Info(item)
        total = total + (info and info.price or 0) * k
      end
    end
    return total
  end
  if next(needs.missing) then
    steps[#steps + 1] = { kind = "stuck", key = "stuck", text = "No source for " .. NameList(needs.missing, 2),
      where = "Not at auction in the last scan and not sold by a vendor. Scan again, or farm it." }
  end
  if next(needs.ah) then
    steps[#steps + 1] = { kind = "ah", key = "ah", items = needs.ah, text = "Buy at auction: " .. NameList(needs.ah, 3),
      where = "At any auction house. The plan window has a Buy button there.",
      cost = costOf(needs.ah, plan and plan.buyCost, plan and plan.buy or {}) }
  end
  if next(needs.ah) or next(needs.mail) then
    steps[#steps + 1] = { kind = "mail", key = "mail", text = "Pick up " .. ns.Round(Total(needs.ah) + Total(needs.mail))
      .. " from the mailbox", where = "What you buy at auction arrives by mail, at any mailbox." }
  end
  -- One step for each place a vendor item is sold.
  local places, order = {}, {}
  for item, k in pairs(needs.vendor) do
    local where = M.VendorWhere(item)
    if not places[where] then
      places[where] = {}
      order[#order + 1] = where
    end
    places[where][item] = k
  end
  table.sort(order)
  for _, where in ipairs(order) do
    local cost = 0
    for item, k in pairs(places[where]) do cost = cost + (M.VendorBuy(item) or 0) * k end
    steps[#steps + 1] = { kind = "vendor", key = "vendor:" .. where, items = places[where],
      text = "Buy from a vendor: " .. NameList(places[where], 3),
      where = "At " .. where .. ".", cost = cost }
  end
  if next(needs.bank) then
    steps[#steps + 1] = { kind = "bank", key = "bank", text = "Take from the bank: " .. NameList(needs.bank, 3), where = "At any bank." }
  end
  for _, c in ipairs(needs.crafts) do
    steps[#steps + 1] = { kind = "craft", key = "craft:" .. c.spell,
      text = "Craft " .. ns.Data.recipes[c.spell][6] .. " x" .. ns.Round(c.casts), spell = c.spell, casts = c.casts }
  end
  -- The last step: where the money comes back.
  local goal = pin and pin.goal
  local cut = ns.settings and ns.settings.cut or 0.05
  if goal and goal.kind == "tovendor" then
    steps[#steps + 1] = { kind = "sell", key = "sell", toVendor = true, text = "Sell " .. ns.Round(qty) .. " to a vendor",
      where = "Any vendor buys it. No auction cut.", gain = ns.VendorSell(id) * qty }
  elseif goal or (plan and plan.craftable) then
    local each = goal and goal.sellEach or (M.Info(id) and M.Info(id).price)
    -- A recipe that makes several at a time may make more than was asked for.
    local units = qty
    if not goal then units = max(qty, O.Plan(id, qty).produced or qty) end
    local gross = each and each * units or nil
    steps[#steps + 1] = { kind = "sell", key = "sell", item = id, text = "Post " .. ns.Round(units) .. " at the auction house",
      where = gross and ("The auction house keeps " .. ns.Round(cut * 100) .. "% of the sale: "
        .. ns.Money(gross * cut) .. " of " .. ns.Money(gross) .. ".") or "No auction price is known yet.",
      gain = gross and gross * (1 - cut) or nil, cutPaid = gross and gross * cut or nil }
  end
  -- Which one is next.
  local kind = job and job.kind
  if job and remaining <= 0 then kind = inBags > 0 and "sell" or "done" end
  for _, step in ipairs(steps) do
    if kind and step.kind == kind then step.now = true break end
  end
  if not kind and steps[1] then steps[1].now = true end
  return steps
end

-- What a planned item costs and brings, for each unit and in all:
--   cost      what the plan's steps cost when nothing is held yet
--   toSpend   what the steps still open will cost (auction and vendors)
--   sellEach  what one unit brings when sold, after the auction house cut
--   income    sellEach for every unit made; profit = income - cost
--   trade     bought rather than made; toVendor: sold to a vendor, no cut
-- `units` can be more than asked for when a recipe makes several at once.
-- Any figure is nil when no price is known for it.
local ZERO = { __index = function() return 0 end }

-- Every step of a planned item as if nothing were held or done yet.
local function WholeSteps(job)
  local pin = job.pin
  local whole = J.Needs(pin.id, pin.qty, { total = setmetatable({}, ZERO), bags = setmetatable({}, ZERO) },
    setmetatable({}, ZERO), pin.use, pin.goal)
  return J.Steps(nil, nil, { needs = whole, remaining = pin.qty, inBags = 0, pin = pin, kind = "none" })
end

function J.Money(job)
  local pin = job.pin
  local cut = ns.settings and ns.settings.cut or 0.05
  local m = { qty = pin.qty, units = pin.qty, toSpend = 0,
    trade = pin.goal and pin.goal.kind ~= "craft" or false, toVendor = pin.goal and pin.goal.kind == "tovendor" or false }
  for _, step in ipairs(J.Steps(nil, nil, job)) do
    if step.cost then m.toSpend = m.toSpend + step.cost end
  end
  -- The same route as the steps, so what is left never exceeds the whole.
  local cost = 0
  for _, step in ipairs(WholeSteps(job)) do
    if step.kind == "stuck" then cost = nil break end
    if step.cost then cost = cost + step.cost end
  end
  m.cost = cost
  local goal = pin.goal
  if goal then
    m.cost = m.cost or goal.outlay
    if goal.sellEach then
      m.sellEach = goal.kind == "tovendor" and goal.sellEach or goal.sellEach * (1 - cut)
    end
  else
    local e = O.Evaluate(pin.id, pin.qty)
    m.units = max(pin.qty, e.produced or pin.qty)
    m.sellEach = e.unitSale
  end
  if m.sellEach then m.income = m.sellEach * m.units end
  if m.cost then m.costEach = m.cost / max(m.units, 1) end
  if m.cost and m.income then m.profit = m.income - m.cost end
  return m
end

-- The same for the whole plan. `unknown` counts the items with no cost or
-- no sale price, which the sums leave out.
function J.MoneyAll(jobs)
  local all = { cost = 0, toSpend = 0, income = 0, profit = 0, unknown = 0, items = {} }
  for _, job in ipairs(jobs or J.All()) do
    local m = J.Money(job)
    all.items[#all.items + 1] = m
    all.toSpend = all.toSpend + m.toSpend
    if m.profit then
      all.cost, all.income, all.profit = all.cost + m.cost, all.income + m.income, all.profit + m.profit
    else
      all.unknown = all.unknown + 1
    end
  end
  return all
end

-- The steps of a planned item that are finished: those the whole plan has
-- (worked out as if nothing were held) that are no longer open. Something
-- half done stays open with what is left.
function J.StepsDone(job)
  local pin = job and job.pin
  if not pin then return {} end
  local all = WholeSteps(job)
  local open = {}
  for _, step in ipairs(J.Steps(nil, nil, job)) do open[step.key] = true end
  local done = {}
  local finished = job.remaining <= 0 and job.inBags <= 0          -- everything is posted
  for _, step in ipairs(all) do
    if step.key ~= "stuck" and (not open[step.key] or finished) and (step.key ~= "sell" or finished) then
      step.done, step.now = true, nil
      done[#done + 1] = step
    end
  end
  return done
end

-- Takes the things bought at auction out of the mailbox, one letter at a
-- time. Only letters that are a won auction are touched. Must be at a
-- mailbox. Returns false with the reason when it cannot.
local taking = false
function J.TakeMail()
  if J.place ~= "mail" then return false, "Open a mailbox first." end
  if not (GetInboxNumItems and GetInboxInvoiceInfo and AutoLootMailItem) then
    return false, "This game version does not let addons take mail. Take it yourself."
  end
  if taking then return false, "Already taking the mail." end
  taking = true
  local function nextLetter()
    if J.place ~= "mail" then taking = false return end
    for i = GetInboxNumItems(), 1, -1 do
      if GetInboxInvoiceInfo(i) == "buyer" then
        AutoLootMailItem(i)
        C_Timer.After(0.6, nextLetter)
        return
      end
    end
    taking = false
    ns.Fire("JOBS")
  end
  nextLetter()
  return true
end

-- What a step's button does here and now: { text, enabled, tip, fn }, or
-- nil when the step has nothing to press. A button is live only where the
-- step can be done: at the auction house, at a vendor that sells it, at a
-- mailbox, or with the materials in the bags.
function J.StepAction(step, job)
  if not step or step.done then return nil end
  local a = { enabled = false }
  if step.kind == "ah" then
    local names = {}
    for item in pairs(step.items or {}) do names[#names + 1] = item end
    table.sort(names, function(x, y) return ns.ItemName(x) < ns.ItemName(y) end)
    local item = names[1]
    local qty = item and ns.Round(step.items[item]) or 0
    a.text = "Buy"
    if not item then return nil end
    if not M.ahOpen then
      a.tip = "Go to an auction house. This then buys " .. ns.ItemName(item) .. " x" .. qty .. "."
    elseif J.Busy() then
      a.tip = "Still busy with the last purchase."
    else
      a.enabled = true
      a.tip = "Buys " .. ns.ItemName(item) .. " x" .. qty .. " at the price the plan expects; if it has risen by more "
        .. "than a few percent nothing is bought." .. (#names > 1 and " One item for each press." or "")
      a.fn = function() J.BuyAuction(item, qty) end
    end
  elseif step.kind == "mail" then
    a.text = "Take"
    if J.place ~= "mail" then
      a.tip = "Go to a mailbox. This then takes what you bought at auction."
    else
      a.enabled = true
      a.tip = "Takes the auctions you won out of the mailbox, one letter at a time. Other mail is left alone."
      a.fn = function()
        local ok, why = J.TakeMail()
        if not ok then ns.Print(why) end
      end
    end
  elseif step.kind == "vendor" then
    a.text = "Buy"
    local want = {}
    for item, k in pairs(step.items or {}) do want[item] = ns.Round(k) end
    if J.place ~= "merchant" then
      a.tip = "Go to a vendor that sells it. " .. (step.where or "")
    elseif #J.MerchantOffer(want, true) == 0 then
      a.tip = "This vendor does not sell it. " .. (step.where or "")
    else
      a.enabled = true
      a.tip = "Buys what this step needs from the vendor you are talking to."
      a.fn = function() J.BuyFromMerchant(want, true) end
    end
  elseif step.kind == "craft" then
    a.text = "Make"
    local can = P.Knows(step.spell) and P.CanMake(step.spell) or 0
    if not P.Knows(step.spell) then
      a.tip = "You have not learned this recipe."
    elseif can <= 0 then
      a.tip = "The materials are not all in your bags yet."
    else
      local casts = min(can, max(1, ns.Round(step.casts or 1)))
      a.enabled = true
      a.tip = "Makes " .. casts .. " now. Your profession window must be open: the first press opens it."
      a.fn = function() P.Craft(step.spell, casts) end
    end
  elseif step.kind == "sell" and step.item then
    a.text = "Post"
    local have = ItemCount(step.item)
    local price, why = J.PostPrice(step.item)
    if have <= 0 then
      a.tip = "There is none in your bags yet."
    elseif not price then
      a.tip = "Not worth posting: " .. tostring(why) .. "."
    elseif not M.ahOpen then
      a.tip = "Go to an auction house. This then posts " .. have .. " at about " .. ns.Money(price) .. " each."
    else
      a.enabled = true
      a.tip = "Posts the " .. have .. " in your bags at " .. ns.Money(price) .. " each, just under the cheapest listing."
      a.fn = function() J.SellAuction(step.item) end
    end
  else
    return nil
  end
  return a
end

-- Every pinned job with its needs and next step.
function J.All()
  local out = {}
  local inv, ord = {}, {}
  for _, pin in ipairs(PinList()) do
    local inBags = ItemCount(pin.id)
    local remaining = max(0, pin.qty - (pin.posted or 0) - inBags)
    local needs = J.Needs(pin.id, remaining, inv, ord, pin.use, pin.goal)
    local text, kind = J.Status(needs, remaining, inBags, pin.posted)
    out[#out + 1] = { pin = pin, needs = needs, remaining = remaining, inBags = inBags,
      text = text, kind = kind }
  end
  return out
end

------------------------------------------------------------------------------
-- Vendor: buy everything the pinned jobs need that this merchant sells.
------------------------------------------------------------------------------
-- extra: more items to want, { item = n }. only: want nothing but `extra`.
function J.MerchantOffer(extra, only)
  local wants = {}
  if not only then
    for _, job in ipairs(J.All()) do
      for item, k in pairs(job.needs.vendor) do wants[item] = (wants[item] or 0) + k end
    end
  end
  for item, k in pairs(extra or {}) do
    if not wants[item] then wants[item] = k end
  end
  local offer, total = {}, 0
  if not next(wants) or not (GetMerchantNumItems and GetMerchantItemID and C_MerchantFrame) then
    return offer, total
  end
  for i = 1, GetMerchantNumItems() do
    local id = GetMerchantItemID(i)
    local q = id and wants[id]
    if q then
      local info = C_MerchantFrame.GetItemInfo(i)
      if info and not info.hasExtendedCost and (info.price or 0) > 0
        and (info.numAvailable == -1 or (info.numAvailable or 0) >= q) then
        local per = max(info.stackCount or 1, 1)
        local buys = ceil(q / per)
        offer[#offer + 1] = { index = i, id = id, qty = q, per = per, buys = buys, cost = buys * info.price }
        total = total + buys * info.price
        wants[id] = nil
      end
    end
  end
  return offer, total
end

function J.BuyFromMerchant(extra, only)
  local offer, total = J.MerchantOffer(extra, only)
  if #offer == 0 then
    ns.Print("this vendor sells nothing that is still needed.")
    return false
  end
  if GetMoney and GetMoney() < total then
    ns.Print("that costs " .. ns.Money(total) .. " and you do not have enough.")
    return false
  end
  local names = {}
  for _, o in ipairs(offer) do
    if o.per > 1 then
      for _ = 1, min(o.buys, 60) do BuyMerchantItem(o.index, 1) end
    else
      local maxStack = (GetMerchantItemMaxStack and GetMerchantItemMaxStack(o.index)) or 20
      local left, guard = o.qty, 0
      while left > 0 and guard < 60 do
        local k = min(left, max(maxStack, 1))
        BuyMerchantItem(o.index, k)
        left = left - k
        guard = guard + 1
      end
    end
    names[#names + 1] = ns.ItemName(o.id) .. " x" .. ns.Round(o.buys * o.per)
  end
  ns.Log("vendor: bought " .. table.concat(names, ", ") .. " for " .. total)
  ns.Print("bought " .. table.concat(names, ", ") .. " for " .. ns.Money(total) .. ".")
  return true
end

------------------------------------------------------------------------------
-- Auction house: buying and posting. Every purchase and every post starts
-- from a click (the game requires it) and is checked against the plan's
-- price first, so a price that moved is never paid blindly.
------------------------------------------------------------------------------
local deal            -- the one purchase or post in flight
local PRICE_SLACK = 1.08
local FRESH_SECONDS = 10 * 60

function J.Busy()
  return deal ~= nil
end

local function EndDeal(message)
  deal = nil
  if message then ns.Print(message) end
  ns.Fire("JOBS")
end

local function NoteOrdered(item, qty)
  local ord = Ordered()
  ord[item] = (ord[item] or 0) + qty
  J.bagSeen = J.bagSeen or {}
  J.bagSeen[item] = ItemCount(item)
end

-- Items arriving in the bags are taken off the "waiting in the mailbox" count.
local function WatchBags()
  local ord = Ordered()
  J.bagSeen = J.bagSeen or {}
  local changed = false
  for item, waiting in pairs(ord) do
    local now = ItemCount(item)
    local before = J.bagSeen[item] or now
    if now > before then
      local left = waiting - (now - before)
      ord[item] = left > 0 and left or nil
      changed = true
    end
    J.bagSeen[item] = now
  end
  if changed then ns.Fire("JOBS") end
end
ns.On("BAG_UPDATE_DELAYED", WatchBags)

local function Refresh(id, what)
  M.ScanItems({ id })
  ns.Print("looked up " .. ns.ItemName(id) .. " again. Press " .. what .. " once more.")
end

-- Buys `qty` of an item at auction, at no more than the plan expected.
-- limit: the most the whole amount may cost (what the offer on screen
-- counted on). Without it the only guard is the usual small slack over the
-- listings as they stand.
function J.BuyAuction(id, qty, limit)
  local A = C_AuctionHouse
  local name = ns.ItemName(id)
  if not M.ahOpen then
    ns.Print("open the auction house to buy.")
    return false
  end
  if deal then
    if deal.stage == "confirm" and deal.kind == "commodity" and deal.id == id then
      deal.stage = "confirming"
      pcall(A.ConfirmCommoditiesPurchase, deal.id, deal.qty)
      return true
    end
    ns.Print("still busy with " .. ns.ItemName(deal.id) .. ".")
    return false
  end
  local info = M.Info(id)
  local it = M.Get(id)
  if not info or not info.price or not info.ladder or (info.age or 0) > FRESH_SECONDS
    or info.summary or not (it and it.k) then
    -- The price must be current and we must know how this item is sold.
    if it and J.lookedUp == id and GetTime() - (J.lookedUpAt or 0) < 30 and info and info.price then
      -- Looked up just now and still unsure how it is sold: try by the unit.
    else
      J.lookedUp, J.lookedUpAt = id, GetTime()
      Refresh(id, "Buy")
      return false
    end
  end
  if not info.ladder then
    ns.Print("the price of " .. name .. " is not known well enough to buy. Scan it first.")
    return false
  end
  qty = max(1, ns.Round(qty))
  local cost, got = M.Walk(info.ladder, 0, qty)
  if got <= 0 then
    ns.Print("no " .. name .. " is listed right now.")
    return false
  end
  if limit and cost > limit * (got / qty) * 1.02 + 1 then
    ns.Print("the listings have moved: " .. got .. " x " .. name .. " now cost " .. ns.Money(cost)
      .. ", more than the " .. ns.Money(limit * (got / qty)) .. " this offer counted on. Not bought.")
    return false
  end
  if got < qty then qty = got end
  local cap = math.floor(cost * PRICE_SLACK) + 1
  if GetMoney and GetMoney() < cost then
    ns.Print(qty .. " x " .. name .. " costs " .. ns.Money(cost) .. " and you do not have enough.")
    return false
  end

  if it and it.k == "i" then
    -- Sold as separate auctions: one click buys the cheapest one.
    local results = M.itemResults[id]
    if not results or GetTime() - results.t > 60 or not results.list[1] then
      Refresh(id, "Buy")
      return false
    end
    local entry = results.list[1]
    local unitCap = cap / qty
    if entry.buyout / entry.qty > unitCap then
      ns.Print("the cheapest " .. name .. " is now " .. ns.Money(entry.buyout / entry.qty)
        .. " each, more than the plan allows (" .. ns.Money(unitCap) .. "). Not bought.")
      return false
    end
    deal = { kind = "item", id = id, qty = entry.qty, total = entry.buyout, auctionID = entry.auctionID,
      stage = "bid" }
    local this = deal
    local ok, err = pcall(A.PlaceBid, entry.auctionID, entry.buyout)
    ns.Log("buy " .. name .. ": PlaceBid " .. entry.buyout .. " -> " .. tostring(ok) .. " " .. tostring(err or ""))
    if not ok then
      EndDeal("the game refused the purchase: " .. tostring(err))
      return false
    end
    table.remove(results.list, 1)
    C_Timer.After(8, function()
      if deal == this then EndDeal("no answer from the auction house for " .. name .. ".") end
    end)
    return true
  end

  deal = { kind = "commodity", id = id, qty = qty, cap = cap, stage = "quote" }
  local this = deal
  local ok, err = pcall(A.StartCommoditiesPurchase, id, qty)
  ns.Log("buy " .. name .. " x" .. qty .. ": cap " .. cap .. ", start -> " .. tostring(ok) .. " " .. tostring(err or ""))
  if not ok then
    EndDeal("the game refused the purchase: " .. tostring(err))
    return false
  end
  C_Timer.After(10, function()
    if deal == this and this.stage ~= "confirm" then
      pcall(A.CancelCommoditiesPurchase)
      EndDeal("no answer from the auction house for " .. name .. ".")
    end
  end)
  return true
end

ns.On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
  if not deal or deal.kind ~= "commodity" or deal.stage ~= "quote" then return end
  local name = ns.ItemName(deal.id)
  if type(totalPrice) ~= "number" or totalPrice > deal.cap then
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    ns.Log("buy " .. name .. ": quote " .. tostring(totalPrice) .. " over cap " .. deal.cap)
    local id = deal.id
    EndDeal(deal.qty .. " x " .. name .. " now costs " .. ns.Money(totalPrice)
      .. ", more than the plan allows (" .. ns.Money(deal.cap) .. "). Not bought.")
    M.ScanItems({ id })
    return
  end
  deal.total = totalPrice
  deal.stage = "confirming"
  local this = deal
  pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, deal.id, deal.qty)
  -- If the game wants the confirmation to come from a click, ask for one.
  C_Timer.After(3, function()
    if deal == this and this.stage == "confirming" then
      this.stage = "confirm"
      ns.Print("press Buy again to confirm " .. this.qty .. " x " .. name .. " for " .. ns.Money(this.total) .. ".")
      ns.Fire("JOBS")
      C_Timer.After(20, function()
        if deal == this then
          pcall(C_AuctionHouse.CancelCommoditiesPurchase)
          EndDeal("the purchase of " .. name .. " was not confirmed and has been dropped.")
        end
      end)
    end
  end)
end)

ns.On("COMMODITY_PRICE_UNAVAILABLE", function()
  if deal and deal.kind == "commodity" then
    EndDeal("the auction house could not quote " .. ns.ItemName(deal.id) .. ". Scan it and try again.")
  end
end)

ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
  if not deal or deal.kind ~= "commodity" then return end
  NoteOrdered(deal.id, deal.qty)
  ns.Log("bought " .. ns.ItemName(deal.id) .. " x" .. deal.qty .. " for " .. tostring(deal.total))
  local id = deal.id
  EndDeal("bought " .. deal.qty .. " x " .. ns.ItemName(deal.id) .. " for " .. ns.Money(deal.total)
    .. ". It is in your mailbox.")
  M.ScanItems({ id })
end)

ns.On("COMMODITY_PURCHASE_FAILED", function()
  if deal and deal.kind == "commodity" then
    EndDeal("the purchase of " .. ns.ItemName(deal.id) .. " failed. Scan it and try again.")
  end
end)

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
  if not deal or deal.kind ~= "item" or deal.auctionID ~= auctionID then return end
  NoteOrdered(deal.id, deal.qty)
  ns.Log("bought " .. ns.ItemName(deal.id) .. " x" .. deal.qty .. " for " .. tostring(deal.total))
  EndDeal("bought " .. deal.qty .. " x " .. ns.ItemName(deal.id) .. " for " .. ns.Money(deal.total)
    .. ". It is in your mailbox.")
end)

ns.On("AUCTION_HOUSE_SHOW_ERROR", function(code)
  if deal then
    ns.Log("auction house error " .. tostring(code) .. " during " .. deal.kind .. " of " .. ns.ItemName(deal.id))
    EndDeal("the auction house refused that (" .. ns.ItemName(deal.id) .. ").")
  end
end)

local function FindInBags(id)
  if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemID) then
    return nil
  end
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = 0, last do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      if C_Container.GetContainerItemID(bag, slot) == id then return bag, slot end
    end
  end
  return nil
end

-- The price to post at and whether it pays, or nil and a reason.
-- anyGain: accept any price that beats a vendor, even below the cost to
-- make it (for things already sitting in the bags).
function J.PostPrice(id, commodity, anyGain)
  local info = M.Info(id)
  local reference = info and info.price
  local listed = reference ~= nil
  if not reference then
    reference = ns.Stats.Estimate(id, 0) or (info and info.lastPrice)
  end
  if not reference then return nil, "there is no price to go by" end
  local price = listed and (reference - 1) or reference
  if commodity == false then
    -- Separate auctions take whole silver only.
    price = math.floor(price / 100) * 100
    if price <= 0 then return nil, "it sells for less than one silver" end
  else
    price = math.floor(price)
    if price <= 0 then price = math.floor(reference) end
  end
  local cut = ns.settings and ns.settings.cut or 0.05
  local vendor = ns.VendorSell(id)
  if price * (1 - cut) <= vendor then
    return nil, "a vendor pays as much (" .. ns.Money(vendor) .. ")"
  end
  if O.IsCraftable(id) and not anyGain then
    local e = O.Evaluate(id, 1)
    if e.plan.complete and price * (1 - cut) <= e.cost / e.produced then
      return nil, "it would sell for less than it costs to make (" .. ns.Money(e.cost / e.produced) .. ")"
    end
  end
  return price
end

-- Posts an item from the bags at just under the cheapest listing.
-- Returns true when a post was started. On false the second result is
-- "retry" when pressing again will work, or "no" when it will not.
function J.SellAuction(id, limit, anyGain)
  local A = C_AuctionHouse
  local name = ns.ItemName(id)
  if not M.ahOpen then
    ns.Print("open the auction house to sell.")
    return false
  end
  if deal then
    if deal.kind == "post" and deal.stage == "confirm" and deal.id == id then
      deal.stage = "posting"
      if deal.commodity then
        pcall(A.ConfirmPostCommodity, deal.loc, 3, deal.qty, deal.price)
      else
        pcall(A.ConfirmPostItem, deal.loc, 3, 1, nil, deal.price)
      end
      return true
    end
    ns.Print("still busy with " .. ns.ItemName(deal.id) .. ".")
    return false, "retry"
  end
  local bag, slot = FindInBags(id)
  if not bag or not ItemLocation then
    ns.Print("there is no " .. name .. " in your bags.")
    return false, "no"
  end
  local info = M.Info(id)
  if not info or info.source ~= "scan" or (info.age or 0) > FRESH_SECONDS then
    Refresh(id, "Sell")
    return false, "retry"
  end
  local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
  local status = A.GetItemCommodityStatus(loc)
  if status ~= 1 and status ~= 2 then
    ns.Print("the game is still loading " .. name .. ". Press Sell again.")
    return false, "retry"
  end
  local commodity = status == 2
  local price, why = J.PostPrice(id, commodity, anyGain)
  if not price then
    ns.Print("not posting " .. name .. ": " .. why .. ".")
    return false, "no"
  end
  local qty = 1
  if commodity then
    local available = (A.GetAvailablePostCount and A.GetAvailablePostCount(loc)) or ItemCount(id)
    qty = max(1, min(available, limit or available))
  end
  deal = { kind = "post", id = id, qty = qty, price = price, commodity = commodity, loc = loc, stage = "posting" }
  local this = deal
  local ok, needsConfirm
  if commodity then
    ok, needsConfirm = pcall(A.PostCommodity, loc, 3, qty, price)
  else
    ok, needsConfirm = pcall(A.PostItem, loc, 3, 1, nil, price)
  end
  ns.Log("post " .. name .. " x" .. qty .. " at " .. price .. " -> " .. tostring(ok) .. " " .. tostring(needsConfirm))
  if not ok then
    EndDeal("the game refused to post " .. name .. ": " .. tostring(needsConfirm))
    return false, "no"
  end
  if needsConfirm == true then
    deal.stage = "confirm"
    ns.Print("the game asks for confirmation. Press Sell again to post " .. qty .. " x " .. name .. ".")
    ns.Fire("JOBS")
  end
  C_Timer.After(10, function()
    if deal == this and this.stage == "posting" then
      EndDeal("no answer from the auction house when posting " .. name .. ".")
    end
  end)
  return true
end

ns.On("AUCTION_HOUSE_POST_WARNING", function()
  if deal and deal.kind == "post" then
    deal.stage = "confirm"
    ns.Print("the game asks for confirmation. Press Sell again.")
    ns.Fire("JOBS")
  end
end)

ns.On("AUCTION_HOUSE_POST_ERROR", function()
  if deal and deal.kind == "post" then
    EndDeal("the auction house refused to post " .. ns.ItemName(deal.id) .. ".")
  end
end)

ns.On("AUCTION_HOUSE_AUCTION_CREATED", function()
  if not deal or deal.kind ~= "post" then return end
  local _, pin = J.IsPinned(deal.id)
  if pin then pin.posted = (pin.posted or 0) + deal.qty end
  ns.Log("posted " .. ns.ItemName(deal.id) .. " x" .. deal.qty .. " at " .. deal.price)
  EndDeal("posted " .. deal.qty .. " x " .. ns.ItemName(deal.id) .. " at " .. ns.Money(deal.price) .. " each.")
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  if deal then EndDeal() end
end)

ns.On("MERCHANT_SHOW", function() J.place = "merchant" ns.Fire("JOBS") end)
ns.On("MERCHANT_CLOSED", function() J.place = nil ns.Fire("JOBS") end)
ns.On("MAIL_SHOW", function() J.place = "mail" ns.Fire("JOBS") end)
ns.On("MAIL_CLOSED", function() J.place = nil ns.Fire("JOBS") end)
ns.On("BANKFRAME_OPENED", function() J.place = "bank" ns.Fire("JOBS") end)
ns.On("BANKFRAME_CLOSED", function() J.place = nil ns.Fire("JOBS") end)

------------------------------------------------------------------------------
-- Selling what is in the bags
------------------------------------------------------------------------------
-- Items the pinned jobs still need as materials; these are not offered for sale.
function J.Reserved()
  local reserved = {}
  for _, pin in ipairs(PinList()) do
    local plan = O.Plan(pin.id, max(1, pin.qty))
    for item in pairs(plan.buy) do reserved[item] = true end
    for item in pairs(plan.vend) do reserved[item] = true end
    for spell in pairs(plan.casts) do
      local r = ns.Data.recipes[spell]
      if r[3] ~= pin.id then reserved[r[3]] = true end
      for i = 1, #r[7], 2 do reserved[r[7][i]] = true end
    end
  end
  return reserved
end

-- Everything in the bags that would fetch more at auction than from a
-- vendor. Returns the rows (best first) and a summary.
function J.BagSales()
  local counts = {}
  if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo then
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do
      for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID and not info.isBound then
          counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
        end
      end
    end
  end
  -- What is in the bank is listed too: it has to be taken out before it
  -- can be posted, so it is shown apart and not counted in the total.
  local banked = P.Bank()
  for id in pairs(banked) do
    if counts[id] == nil then counts[id] = 0 end
  end
  local reserved = J.Reserved()
  local cut = ns.settings and ns.settings.cut or 0.05
  local rows = {}
  local sum = { total = 0, var = 0, count = 0, vendorItems = 0, vendorTotal = 0, unknown = 0,
    bankItems = 0, bankTotal = 0 }
  for id, n in pairs(counts) do
    local info = M.Info(id)
    local price = info and (info.price or info.lastPrice)
    local vendor = ns.VendorSell(id)
    if not price then
      if n > 0 then sum.unknown = sum.unknown + 1 end
    elseif price * (1 - cut) <= vendor * 1.02 then
      if vendor > 0 and n > 0 then
        sum.vendorItems = sum.vendorItems + 1
        sum.vendorTotal = sum.vendorTotal + vendor * n
      end
    else
      local net = price * (1 - cut) * n
      local _, sd = ns.Stats.Estimate(id, 0)
      sd = sd or ns.Stats.DEFAULT_SD
      local listed = info.source == "scan" and info.price and info.total or nil
      local thin = listed and 0.5 / sqrt(max(listed, 1)) or 0.3
      local row = {
        id = id, count = n, price = price, net = net, gain = net - vendor * n,
        sd = net * sqrt(sd * sd + thin * thin), listed = listed,
        none = info.price == nil, old = info.source ~= "scan" or (info.age or 0) > FRESH_SECONDS,
        reserved = reserved[id] or false,
        bank = banked[id] or 0,
      }
      rows[#rows + 1] = row
      if row.bank > 0 and not row.reserved then
        sum.bankItems = sum.bankItems + 1
        sum.bankTotal = sum.bankTotal + price * (1 - cut) * row.bank
      end
      if not row.reserved and n > 0 then
        sum.total = sum.total + net
        sum.var = sum.var + row.sd * row.sd
        sum.count = sum.count + 1
      end
    end
  end
  -- What can be posted now first, then what is only in the bank, then
  -- what is kept back for the plan.
  local function rank(d) return d.reserved and 3 or (d.count > 0 and 1 or 2) end
  table.sort(rows, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    local va, vb = a.net + a.price * a.bank, b.net + b.price * b.bank
    if va ~= vb then return va > vb end
    return a.id < b.id
  end)
  sum.sd = sqrt(sum.var)
  return rows, sum
end

------------------------------------------------------------------------------
-- Opportunities: every way to make money right now, whatever it takes.
-- Nothing is left out for being small or laborious; each row says what it
-- costs, what it should earn, how sure that is and which steps it needs,
-- and the player judges the effort.
--   craft       make something you know the recipe for and sell it
--   flip        buy the cheap end of a price ladder and relist it higher
--   tovendor    buy listings priced under what a vendor pays
--   fromvendor  buy from a vendor with endless stock and auction it
--   bags        list what is already in the bags
------------------------------------------------------------------------------
local D = {}
ns.Deals = D
D.KIND = {
  later = "Sell at a better time",
  craft = "Craft and sell",
  flip = "Buy low, relist",
  tovendor = "Buy at auction, vendor it",
  fromvendor = "Buy at vendor, auction it",
  bags = "Sell from your bags",
}
local STALE_SECONDS = 2 * 3600

local function DemandCap(id, info)
  local d = ns.Data.items[id]
  local stack = max(1, d and d[6] or 1)
  if info.turnover and info.turnover > 0 then
    return max(1, math.floor(info.turnover * (ns.settings and ns.settings.horizonDays or 2))), true
  end
  -- The online data watched for a day and saw none sell: one is plenty.
  if info.soldKnown then return 1, true end
  return stack, false
end

local function Finish(row)
  row.safe = row.profit - row.sd
  row.sure = row.safe > 0 and not row.thin and not row.stale and not row.assumed
  row.effort = #row.steps
  return row
end

local function CraftRows(out)
  local list = P.Worth()
  for _, w in ipairs(list) do
    local e = O.Evaluate(w.id, w.qty)
    local plan = e.plan
    local steps = {}
    if next(plan.buy) then
      steps[#steps + 1] = "auction house (buy)"
      steps[#steps + 1] = "mailbox"
    end
    if next(plan.vend) then steps[#steps + 1] = "vendor (buy)" end
    local kinds = 0
    for _ in pairs(plan.casts) do kinds = kinds + 1 end
    steps[#steps + 1] = kinds > 1 and ("craft, " .. kinds .. " recipes") or "craft"
    steps[#steps + 1] = w.mode == "vendor" and "vendor (sell)" or "auction house (sell)"
    out[#out + 1] = Finish({
      kind = "craft", id = w.id, qty = w.qty, outlay = e.cost, profit = w.batch, sd = w.batchSd,
      thin = w.thin, steps = steps, craft = w, spell = w.spell, guess = w.guess,
    })
  end
end

-- Market rows need only the price data, so they are cached until it changes.
local marketCache, marketGen

local MarketRows
function D.MarketRows() return MarketRows() end
function MarketRows()
  if marketGen == ns.generation and marketCache then return marketCache end
  local rows = {}
  local cut = ns.settings and ns.settings.cut or 0.05
  -- Everything with a price: the player's own scans and the online data.
  local items = {}
  for id in pairs(ns.realm and ns.realm.items or {}) do items[id] = true end
  local _, online = M.Online(0)
  for id in pairs(online and online.items or {}) do items[id] = true end
  for id in pairs(M.SharedIds()) do items[id] = true end
  for id in pairs(items) do
    local info = M.Info(id)
    local ladder = info and info.source == "scan" and info.ladder
    if ladder and ladder[1] then
      local stale = (info.age or 0) > STALE_SECONDS
      local vendorSell = ns.VendorSell(id)
      local total = info.total or 0

      -- Listings under what a vendor pays: money with no risk but the walk.
      local blur = info.blur or 0
      if vendorSell > 0 and not info.summary and ladder[1] < vendorSell then
        -- A merged level may hold prices a little above its average.
        local qty = M.QtyBelow(ladder, vendorSell / (1 + blur))
        local cost = M.Walk(ladder, 0, qty)
        local profit = qty * vendorSell - cost
        if qty > 0 and profit > 0 then
          rows[#rows + 1] = Finish({
            kind = "tovendor", id = id, qty = qty, outlay = cost, profit = profit, sd = 0, stale = stale,
            steps = { "auction house (buy)", "mailbox", "vendor (sell)" }, sellEach = vendorSell,
          })
        end
      end

      -- Buy the cheap end of the ladder and relist under the next price.
      if not info.summary and ladder[3] then
        local cap, known = DemandCap(id, info)
        local est, sdm = ns.Stats.Estimate(id, 0)
        local scans = ns.Stats.ForItem(id).model and ns.Stats.ForItem(id).model.n or 0
        local units, cost, best = 0, 0, nil
        for i = 1, #ladder - 2, 2 do
          local take = min(ladder[i + 1], cap - units)
          if take <= 0 then break end
          units = units + take
          cost = cost + take * ladder[i]
          if take == ladder[i + 1] then
            -- Relist just under the cheapest of what is left; a merged
            -- level's cheapest price may be a little under its average.
            local target = ladder[i + 2] * (1 - blur) - 1
            -- With some history, do not count on more than the usual price.
            if est and scans >= 3 then target = min(target, est) end
            local profit = units * target * (1 - cut) - cost
            if profit > 0 and (not best or profit > best.profit) then
              best = { qty = units, cost = cost, target = target, profit = profit, above = total - units }
            end
          end
        end
        if best then
          local thinSd = 0.5 / sqrt(max(best.above, 1))
          local sd = best.qty * best.target * (1 - cut) * sqrt((sdm or ns.Stats.DEFAULT_SD) ^ 2 + thinSd ^ 2)
          rows[#rows + 1] = Finish({
            kind = "flip", id = id, qty = best.qty, outlay = best.cost, profit = best.profit, sd = sd,
            thin = best.above <= 2, stale = stale, demandKnown = known, sellEach = best.target,
            steps = { "auction house (buy)", "mailbox", "auction house (sell)" },
          })
        end
      end

      -- Vendors with endless stock sell it for less than it fetches at auction.
      local vendorBuy, vendorSource = M.VendorBuy(id)
      if vendorBuy and ladder[1] * (1 - cut) > vendorBuy then
        local cap, known = DemandCap(id, info)
        local qty = known and cap or max(1, min(cap, total))
        local each = (ladder[1] - 1) * (1 - cut) - vendorBuy
        if each > 0 then
          local _, sdm = ns.Stats.Estimate(id, 0)
          local thinSd = 0.5 / sqrt(max(total, 1))
          rows[#rows + 1] = Finish({
            kind = "fromvendor", id = id, qty = qty, outlay = qty * vendorBuy, profit = qty * each,
            sd = qty * ladder[1] * (1 - cut) * sqrt((sdm or ns.Stats.DEFAULT_SD) ^ 2 + thinSd ^ 2),
            thin = total <= 2, stale = stale, demandKnown = known, sellEach = ladder[1] - 1,
            steps = { "vendor (buy)", "auction house (sell)" },
            -- A vendor price from the built-in list has not been seen in this game yet.
            assumed = vendorSource == "known",
          })
        end
      end
    end
  end
  marketCache, marketGen = rows, ns.generation
  return rows
end

-- Returns every opportunity, surest first, and the worth-crafting summary.
function D.All()
  local out = {}
  local _, info = P.Worth()
  CraftRows(out)
  for _, row in ipairs(MarketRows()) do out[#out + 1] = row end
  local _, sum = J.BagSales()
  if sum.count > 0 then
    out[#out + 1] = Finish({
      kind = "bags", id = nil, qty = sum.count, outlay = 0, profit = sum.total, sd = sum.sd,
      steps = { "auction house (sell)" },
    })
  end
  table.sort(out, function(a, b)
    if a.sure ~= b.sure then return a.sure end
    if a.safe ~= b.safe then return a.safe > b.safe end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return (a.id or 0) < (b.id or 0)
  end)
  return out, info
end


------------------------------------------------------------------------------
-- When a sale happens, and what a plan is expected to earn
--
-- Profit depends on when the goods sell. The price seen now is moved by
-- the change the price model expects by each moment (trend, hour of day,
-- weekday), and the range widens the further ahead the moment is.
------------------------------------------------------------------------------
local EVENING = 20
local exp = math.exp

-- Moments a sale might happen, from now to a week out: { key, label, days }.
function J.SellMoments()
  local d = date("*t", time())
  local toEvening = (EVENING - (d.hour + d.min / 60)) / 24
  local out = {
    { key = "now", label = "right away", days = 0 },
    { key = "30m", label = "within 30 minutes", days = 0.5 / 24 },
    { key = "1h", label = "within the hour", days = 1 / 24 },
  }
  if toEvening > 1.5 / 24 then
    out[#out + 1] = { key = "evening", label = "this evening (20:00)", days = toEvening }
  end
  out[#out + 1] = { key = "tomorrow", label = "tomorrow evening", days = toEvening + 1 }
  out[#out + 1] = { key = "3d", label = "in 3 days", days = 3 }
  out[#out + 1] = { key = "7d", label = "in a week", days = 7 }
  return out
end

-- What one unit should fetch `days` from now, starting from the price seen
-- now (or given). Returns price, lo, hi, sd; lo to hi is where it is likely
-- to land about two times in three.
function J.PriceAt(id, days, priceNow)
  local base = priceNow or O.SalePrice(id)
  if not base then return nil end
  local entry = ns.Stats.ForItem(id)
  if not entry.model then
    local sd = ns.Stats.DEFAULT_SD
    return base, base * exp(-sd), base * exp(sd), sd
  end
  local m0 = ns.Stats.Eval(entry.model, 0)
  local m, sd = ns.Stats.Eval(entry.model, days)
  local price = base * exp(m - m0)
  return price, price * exp(-sd), price * exp(sd), sd
end

-- The best hour to sell within a week. A later hour has to beat an earlier
-- one by more than the extra doubt that waiting brings, so a small uncertain
-- gain far ahead does not win over a sure one tonight.
-- Returns { days, price, lo, hi, sd, label, gain (fraction over now) } or nil.
function J.BestMoment(id, priceNow)
  local base = priceNow or O.SalePrice(id)
  local entry = ns.Stats.ForItem(id)
  if not base or not entry.model then return nil end
  -- No best hour is named for a price that cannot be forecast.
  if not ns.Stats.Show(id) then return nil end
  local m0, sd0 = ns.Stats.Eval(entry.model, 0)
  local bestH, bestScore, bestM, bestSd = 0, 0, m0, sd0
  for h = 1, 168 do
    local m, sd = ns.Stats.Eval(entry.model, h / 24)
    local score = (m - m0) - 0.5 * (sd - sd0)
    if score > bestScore then bestH, bestScore, bestM, bestSd = h, score, m, sd end
  end
  local price = base * exp(bestM - m0)
  local label = "now"
  if bestH > 0 then
    local at = time() + bestH * 3600
    local sameDay = date("%j", at) == date("%j", time())
    label = (sameDay and "today " or (date("%a", at) .. " ")) .. date("%H", at) .. ":00"
  end
  return { days = bestH / 24, hours = bestH, price = price, lo = price * exp(-bestSd), hi = price * exp(bestSd),
    sd = bestSd, sd0 = sd0, label = label, gain = price / base - 1 }
end

-- The market row of one kind for one item, if that opportunity still exists.
function D.Find(id, kind)
  for _, row in ipairs(D.MarketRows()) do
    if row.id == id and row.kind == kind then return row end
  end
end

-- What a plan is expected to earn, by when its goods sell.
--   cost, units, priceNow   what it takes and what one unit fetches now
--   now                     the profit if it sold right away
--   rows                    { label, days, profit, lo, hi } per moment
--   best                    the best moment within a week, same fields
--   fixed                   the sale price cannot move (a vendor pays it)
function J.Projection(id, qty, goal)
  local cut = ns.settings and ns.settings.cut or 0.05
  local kind = goal and goal.kind or "craft"
  local out = { kind = kind, rows = {}, id = id }
  local cost, units, priceNow
  if kind == "craft" then
    local e = O.Evaluate(id, qty)
    if not (e.plan.craftable and e.plan.complete) then
      -- Not something to craft: the plan buys it and sells it on.
      kind = "hold"
    end
    cost, units, priceNow = e.cost, e.produced, O.SalePrice(id)
  end
  if kind ~= "craft" then
    units = qty
    local info = M.Info(id)
    local ladder = info and info.source == "scan" and info.ladder
    -- What is already bought cost what the plan said; the rest costs what
    -- the listings ask now.
    local held = min(qty, ItemCount(id) + (Ordered()[id] or 0))
    local planned = goal and goal.outlay and goal.qty and goal.qty > 0 and goal.outlay / goal.qty or nil
    local row = goal and D.Find(id, goal.kind)
    if kind == "fromvendor" then
      local each = M.VendorBuy(id) or planned
      cost = each and each * qty or nil
      priceNow = info and info.price and info.price - 1 or nil
    else
      local rest = qty - held
      local restCost = 0
      if rest > 0 then
        if ladder and ladder[1] then
          -- Fewer listed than the plan wants: the rest is counted at the
          -- dearest listed price, and the projection says it is short.
          local cost, got, last = M.Walk(ladder, 0, rest)
          restCost = cost + (rest - got) * (last or 0)
          if got < rest then out.short = rest - got end
        else
          restCost = planned and planned * rest or nil
        end
      end
      if restCost then cost = (planned or (ladder and ladder[1]) or 0) * held + restCost end
      if kind == "tovendor" then
        priceNow = ns.VendorSell(id)
        out.fixed = true
      elseif row and held < qty then
        priceNow = row.sellEach
      else
        -- Bought: it relists just under the cheapest listing left.
        priceNow = info and info.price and info.price - 1 or (goal and goal.sellEach)
      end
    end
  end
  if not cost or not units or not priceNow then return out end
  out.cost, out.units, out.priceNow = cost, units, priceNow
  local keep = out.fixed and 1 or (1 - cut)
  local function Row(label, days, price, lo, hi)
    return { label = label, days = days, each = price, profit = units * price * keep - cost,
      lo = units * lo * keep - cost, hi = units * hi * keep - cost }
  end
  if out.fixed then
    out.rows[1] = Row("at any vendor", 0, priceNow, priceNow, priceNow)
    out.now = out.rows[1].profit
    return out
  end
  for _, mo in ipairs(J.SellMoments()) do
    local price, lo, hi = J.PriceAt(id, mo.days, priceNow)
    out.rows[#out.rows + 1] = Row(mo.label, mo.days, price, lo, hi)
  end
  out.now = out.rows[1].profit
  local best = J.BestMoment(id, priceNow)
  if best and best.hours > 0 then
    out.best = Row(best.label, best.days, best.price, best.lo, best.hi)
  end
  return out
end

-- Notes what each planned item is expected to earn, each time the prices
-- change (at most every four minutes), so a plan shows how its outlook has
-- moved since it was made.
local TRACK_GAP, TRACK_KEPT = 240, 200
function J.Track(force)
  local now = time()
  for _, pin in ipairs(PinList()) do
    local p = J.Projection(pin.id, pin.qty, pin.goal)
    if p.now then
      local tr = pin.track or {}
      pin.track = tr
      local n = #tr
      if n == 0 or now - tr[n - 1] >= TRACK_GAP then
        tr[n + 1], tr[n + 2] = now, ns.Round(p.now)
        while #tr > TRACK_KEPT * 2 do
          table.remove(tr, 1)
          table.remove(tr, 1)
        end
      elseif force then
        tr[n] = ns.Round(p.now)
      end
    end
  end
end

-- A plan's profit history in a few numbers: n, first, last, prev (the
-- reading before the last), median, mean, low, high, since (when it began).
function J.TrackStats(pin)
  local tr = pin.track
  if not tr or #tr < 2 then return nil end
  local values, sum = {}, 0
  for i = 2, #tr, 2 do
    values[#values + 1] = tr[i]
    sum = sum + tr[i]
  end
  local n = #values
  local out = { n = n, first = values[1], last = values[n], prev = values[n - 1], mean = sum / n,
    since = tr[1], at = tr[#tr - 1] }
  table.sort(values)
  out.low, out.high = values[1], values[n]
  out.median = n % 2 == 1 and values[(n + 1) / 2] or (values[n / 2] + values[n / 2 + 1]) / 2
  return out
end

ns.Listen("MARKET_UPDATED", function() ns.Safe(J.Track) end)

------------------------------------------------------------------------------
-- Options for one item, and what to sell when
------------------------------------------------------------------------------
-- One opportunity as a sentence with its numbers.
function D.Example(row)
  local q, gain = ns.Round(row.qty), ": |cff40ff40+" .. ns.Money(row.profit) .. "|r"
  if row.kind == "craft" then
    local e = O.Evaluate(row.id, row.qty)
    return "Get the materials for " .. ns.Money(e.cost) .. ", make " .. ns.Round(e.produced) .. " x "
      .. ns.ItemName(row.id) .. ", sell them for about " .. ns.Money(e.revenue or 0) .. " after the cut" .. gain
  elseif row.kind == "flip" then
    return "Buy the " .. q .. " cheapest for " .. ns.Money(row.outlay) .. ", list them again at "
      .. ns.Money(row.sellEach) .. " each" .. gain
  elseif row.kind == "tovendor" then
    return "Buy " .. q .. " at auction for " .. ns.Money(row.outlay) .. ", sell them to a vendor for "
      .. ns.Money(row.sellEach) .. " each" .. gain
  elseif row.kind == "fromvendor" then
    return "Buy " .. q .. " from a vendor for " .. ns.Money(row.outlay) .. ", post them at "
      .. ns.Money(row.sellEach) .. " each" .. gain
  elseif row.kind == "later" then
    if row.when.hours == 0 then
      return "Sell your " .. q .. " now, at about " .. ns.Money(row.nowEach) .. " each: no better hour is in sight this week"
    end
    return (row.craft and "Make and sell " or "Sell your ") .. q .. " " .. row.when.label .. " at about "
      .. ns.Money(row.sellEach) .. " each instead of " .. ns.Money(row.nowEach) .. " now" .. gain
  end
  return ""
end

-- Every way to profit that involves one item: trading the item itself, and
-- crafting something from it. Best first.
function D.ForItem(id)
  local out = {}
  for _, row in ipairs((D.All())) do
    if row.id == id then
      out[#out + 1] = row
    elseif row.kind == "craft" then
      local plan = O.Evaluate(row.id, row.qty).plan
      if plan.buy[id] or plan.vend[id] or (plan.own and plan.own[id]) then
        out[#out + 1] = row
      end
    end
  end
  return out
end

-- What the player holds, or can make now, with the best hour to sell each
-- within a week and what waiting for it should add over selling now.
function D.Timing()
  local cut = ns.settings and ns.settings.cut or 0.05
  local rows = {}
  local leftOut = 0
  local function Add(id, units, priceNow, craft)
    local best = J.BestMoment(id, priceNow)
    if not best and units > 0 then leftOut = leftOut + 1 end
    if not best or units <= 0 then return end
    local extra = math.sqrt(max(best.sd * best.sd - best.sd0 * best.sd0, 0))
    local row = Finish({
      kind = "later", id = id, qty = units, outlay = 0,
      profit = units * (best.price - priceNow) * (1 - cut),
      sd = units * best.price * (1 - cut) * extra,
      steps = craft and { "craft", "auction house (sell)" } or { "auction house (sell)" },
      when = best, nowEach = priceNow, sellEach = best.price, craft = craft,
    })
    row.how = (craft and "Make, sell " or "Sell ") .. best.label
    rows[#rows + 1] = row
  end
  for _, s in ipairs((J.BagSales())) do
    if not s.reserved and not s.none and s.price and s.count + s.bank > 0 then
      Add(s.id, s.count + s.bank, s.price, false)
    end
  end
  for _, w in ipairs((P.Worth())) do
    local price = O.SalePrice(w.id)
    if price and w.mode ~= "vendor" then
      Add(w.id, O.Evaluate(w.id, w.qty).produced, price, w)
    end
  end
  table.sort(rows, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.id < b.id
  end)
  return rows, leftOut
end


------------------------------------------------------------------------------
-- Ranking what to make
--
-- To compare the things on screen each craftable one gets a score, and the
-- best of them is the recommendation. Two ways to score, the player's
-- choice:
--   per craft   what one craft earns
--   in all      what the whole amount earns that could be made now
-- Either is taken cautiously: the estimate less its margin (one standard
-- deviation, so the true figure is above it about five times in six). A
-- craft that looks good only because its prices are unsure scores low.
--
-- "The amount that could be made now" runs from what the player's own
-- stock covers to the best quantity the market allows (which already minds
-- how much is listed and how much sells). settings.buyRatio says how far
-- along that the player is willing to go by buying at auction: 0 = only
-- own stock, 1 = buy whatever it takes.
--
-- Groups: "ready" (own stock covers at least one craft), "buy" (materials
-- must be bought first), "unknown" (the recipe is not known).
------------------------------------------------------------------------------
local rankCache, rankKey

function O.Rank(id)
  local ratio = max(0, min(1, ns.settings and ns.settings.buyRatio or 1))
  local by = ns.settings and ns.settings.rankBy or "total"
  local key = ns.generation .. ":" .. P.version .. ":" .. ratio .. ":" .. by
  if rankKey ~= key then rankCache, rankKey = {}, key end
  local hit = rankCache[id]
  if hit ~= nil then return hit or nil end
  local out = false
  if O.IsCraftable(id) then
    local spell = O.BestRecipe(id)
    local r = O.Recipe(spell)
    local one = O.Evaluate(id, 1)
    if r and one.profit then
      local yield = max(1, r[4] or 1)
      -- Crafts the player's own stock (bags and bank) covers.
      local ownCasts = math.huge
      for i = 1, #r[7], 2 do
        local have = P.ItemCount(r[7][i]) + P.BankCount(r[7][i])
        ownCasts = min(ownCasts, math.floor(have / r[7][i + 1]))
      end
      if ownCasts == math.huge then ownCasts = 0 end
      local ownUnits = ownCasts * yield
      local bestQty = O.BestQuantity(id)
      local reach = max(bestQty or 0, ownUnits)
      local qty = ownUnits + ratio * (reach - ownUnits)
      -- Whole crafts only; anything above nothing is at least one craft.
      qty = (qty > 0) and max(1, math.floor(qty / yield + 0.5)) * yield or 0
      local total, totalSd, buyCost = 0, 0, 0
      if qty > 0 then
        local e = O.Evaluate(id, qty)
        total, totalSd = e.profit or 0, e.sd or 0
        for _, c in pairs(e.plan.buyCost or {}) do buyCost = buyCost + c end
      end
      local known = P.Knows(spell)
      out = {
        perCraft = one.profit, sdCraft = one.sd or 0, safeCraft = one.profit - (one.sd or 0),
        own = ownUnits, best = reach, qty = qty, total = total, totalSd = totalSd, safeTotal = total - totalSd,
        buyCost = buyCost, known = known, yield = yield,
        group = (not known) and "unknown" or (ownCasts >= 1 and "ready" or "buy"),
      }
      out.score = max(0, by == "craft" and out.safeCraft or out.safeTotal)
    end
  end
  rankCache[id] = out
  return out or nil
end

O.RANK_GROUPS = { ready = 1, buy = 2, unknown = 3 }


------------------------------------------------------------------------------
-- Recipes the player has not learned
------------------------------------------------------------------------------
-- Where the player stands with a recipe:
--   "known"      learned
--   "unlearned"  has the profession, its recipes have been read, this one
--                is not among them: it could be made once learned
--   "unread"     has the profession, but its window was never opened, so
--                which recipes are learned is not known yet
--   "noskill"    does not have the profession
function P.RecipeState(spell)
  local r = ns.Data.recipes[spell]
  if not r then return "noskill" end
  if P.Knows(spell) then return "known" end
  if not P.Skills()[r[1]] then return "noskill" end
  local _, info = P.Worth()
  if info and info.unverified and info.unverified[r[1]] then return "unread" end
  return "unlearned"
end

-- For an item the player could make if only the recipe were learned: the
-- recipe's spell and the item that teaches it (nil when a trainer does).
-- Returns nil when the item is not in that position.
function P.Unlearned(id)
  if not O.IsCraftable(id) then return nil end
  local spell = O.BestRecipe(id)
  if not spell or P.RecipeState(spell) ~= "unlearned" then return nil end
  return spell, ns.Data.teaches and ns.Data.teaches[spell] or nil
end

-- What is known about getting the item that teaches a recipe, in words.
function P.TeacherText(teacher)
  if not teacher then return "Taught by a profession trainer." end
  local name = ns.ItemName(teacher)
  local vendor = M.VendorBuy(teacher)
  local info = M.Info(teacher)
  if info and info.price then
    return name .. " teaches it: cheapest " .. ns.Money(info.price) .. " at auction"
      .. (vendor and (", " .. ns.Money(vendor) .. " from a vendor") or "") .. "."
  elseif vendor then
    return name .. " teaches it: " .. ns.Money(vendor) .. " from a vendor."
  elseif info then
    return name .. " teaches it: none at auction when last scanned."
  end
  return name .. " teaches it: no price seen yet."
end
