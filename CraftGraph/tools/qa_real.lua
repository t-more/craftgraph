-- Runs the whole addon on a real saved file: every item through the price
-- model, every list, view and plan, with timings. From the addon folder:
--   lua5.1 tools/qa_real.lua <path to SavedVariables/CraftGraph.lua> [seconds since the last scan]
-- Whole-addon run on the real saved data: every view, every item.
local src = io.open("tools/test.lua"):read("*a"):gsub("os%.exit%b()", "")
local realprint = print
print = function() end
assert(loadstring(src .. "\n_G.NS = ns _G.FRAMES = frames _G.RUNT = RunTimers"))()
print = realprint
local ns, frames, RunTimers = NS, FRAMES, RUNT
dofile(arg[1])
local db = CraftGraphDB
local key, realm = next(db.realms)
ns.realm = realm
ns.db.vendor = db.vendor or {}
local _, char = next(db.chars or {})
local scanTime = 0
for _, it in pairs(realm.items) do if it.lt and it.lt > scanTime then scanTime = it.lt end end
local offset = tonumber(arg[2] or "600")
local NOW = scanTime + offset
time = function() return NOW end
ns.generation = ns.generation + 1
local known, skills = char and char.known or {}, {}
for spell in pairs(known) do local r = ns.Data.recipes[spell]; if r then skills[r[1]] = true end end
local list = {}
for id in pairs(skills) do list[#list + 1] = id end
GetProfessions = nil
GetNumSkillLines = function() return #list end
GetSkillLineInfo = function(i) return ns.Data.skills[list[i]], false, nil, 300 end
C_TradeSkillUI = { GetRecipeInfo = function(id) return { learned = known[id] or false } end }
UnitName = function() return "X" end
ns.db.chars = { ["X - TestRealm"] = { known = known, pins = {}, ordered = {} } }
ns.Player.version = ns.Player.version + 1
ns.db.log = {}
local function errors()
  local n = 0
  for _, line in ipairs(ns.db.log) do if line:find("ERROR") then n = n + 1 if n <= 6 then print("   LOG: " .. line:sub(1, 400)) end end end
  return n
end
local function timed(label, fn)
  local c = os.clock()
  local a, b = fn()
  print(string.format("%-58s %7.0f ms", label, (os.clock() - c) * 1000))
  return a, b
end
print("realm " .. key .. ", data read as if " .. offset .. " s after the last scan")

-- 1. every item through the model and the week estimate
local ids = {}
for id in pairs(realm.items) do ids[#ids + 1] = id end
table.sort(ids)
local bad, nan = 0, 0
timed("price model for all " .. #ids .. " items", function()
  for _, id in ipairs(ids) do
    local ok, err = pcall(function()
      local p, sd = ns.Stats.Estimate(id, 0)
      if p and (p ~= p or sd ~= sd or p <= 0 or sd < 0 or p == math.huge) then nan = nan + 1 end
      local w = ns.Stats.Week(id)
      if w then
        for _, slot in ipairs({ { 1, 14 }, { 0, 0 }, { 6, 23 } }) do
          local e = ns.Stats.WeekAt(w, slot[1], slot[2])
          if e.price ~= e.price or e.lo > e.price or e.hi < e.price or (e.next and e.next.price ~= e.next.price) then nan = nan + 1 end
        end
      end
      local f = ns.Stats.Forecast(id, 3)
      if f and f ~= f then nan = nan + 1 end
    end)
    if not ok then bad = bad + 1 if bad <= 3 then print("   item " .. id .. ": " .. tostring(err)) end end
  end
end)
print("   errors: " .. bad .. ", impossible numbers: " .. nan)

-- 2. lists
local all = timed("opportunities (all kinds)", function() return ns.Deals.All() end)
local timing = timed("when-to-sell list", function() return ns.Deals.Timing() end)
print("   opportunities: " .. #all .. ", timing rows: " .. #timing)
local projBad = 0
timed("projection and example for every opportunity", function()
  for _, d in ipairs(all) do
    if d.id and d.kind ~= "bags" then
      local ok, err = pcall(function()
        local goal = d.kind ~= "craft" and { kind = d.kind, qty = d.qty, outlay = d.outlay, sellEach = d.sellEach, profit = d.profit } or nil
        local p = ns.Jobs.Projection(d.id, d.qty, goal)
        local ex = ns.Deals.Example(d)
        if p.now and (p.now ~= p.now) then error("nan profit") end
        -- the projection "right away" should agree with the list within 3% (or 5 copper)
        if p.now and math.abs(p.now - d.profit) > math.max(5, math.abs(d.profit) * 0.03) then
          projBad = projBad + 1
          if projBad <= 5 then print(string.format("   differs: %s %s list %+d projection %+d", ns.ItemName(d.id), d.kind, d.profit, p.now)) end
        end
      end)
      if not ok then bad = bad + 1 print("   " .. tostring(d.id) .. " " .. d.kind .. ": " .. tostring(err)) end
    end
  end
end)
print("   rows where the projection disagrees with the list: " .. projBad)

-- 3. the window: focus many items, every view
ns.Open(ids[1]) RunTimers()
local side, trendsView, worthView
for _, f in ipairs(frames) do
  if f.week and f.chartMode then side = f end
  if f.options and f.facts then trendsView = f end
  if f.filters and f.summary then worthView = f end
end
local sample = {}
for i = 1, #ids, math.max(1, math.floor(#ids / 150)) do sample[#sample + 1] = ids[i] end
for _, d in ipairs(all) do if d.id and #sample < 260 then sample[#sample + 1] = d.id end end
timed("focus " .. #sample .. " items x 3 side pictures + trends (3 views)", function()
  for _, id in ipairs(sample) do
    ns.UI.Focus(id) RunTimers()
    for _ = 1, 3 do side.chartMode.scripts.OnClick() RunTimers() end
    ns.UI.ShowTrends(true) RunTimers()
    for _, k in ipairs({ "period:hour", "period:day", "period:week", "measure:listed", "measure:price" }) do
      trendsView.options[k].scripts.OnClick()
    end
    ns.UI.ShowTrends(false)
  end
end)
ns.UI.ShowWorth(true)
for _, k in ipairs({ "all", "craft", "flip", "vendor", "bags", "item", "later" }) do
  worthView.filters[k].scripts.OnClick(worthView.filters[k])
  for _, row in ipairs(worthView.rows) do
    if row.shown and row.scripts.OnEnter then row.scripts.OnEnter(row) row.scripts.OnLeave(row) end
  end
end
-- 4. plan a few of each kind, track, HUD
local planned = {}
for _, d in ipairs(all) do
  if d.id and d.kind ~= "bags" and not planned[d.kind] and #ns.Jobs.Pins() < ns.Jobs.MAX_PINS then
    planned[d.kind] = d.id
    if d.kind == "craft" then ns.Jobs.Pin(d.id, d.qty) else ns.Jobs.Pin(d.id, d.qty, { kind = d.kind, qty = d.qty, outlay = d.outlay, sellEach = d.sellEach, profit = d.profit }) end
  end
end
RunTimers()
for i = 1, 3 do NOW = NOW + 300 ns.generation = ns.generation + 1 ns.Fire("MARKET_UPDATED") RunTimers() end
ns.UI.UpdateHUD()
for _, pin in ipairs(ns.Jobs.Pins()) do
  local st = ns.Jobs.TrackStats(pin)
  print(string.format("   plan %-26s %-10s %s", ns.ItemName(pin.id):sub(1, 26), pin.goal and pin.goal.kind or "craft",
    (ns.UI.GoalText(pin):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|A:coin%-(%a)%a*:12:12|a", "%1"))))
end
-- 5. history compaction of the real data as it ages
local before, after, bytes = 0, 0, 0
timed("compact all history as if 30 days later", function()
  for _, id in ipairs(ids) do
    local it = realm.items[id]
    before = before + #ns.Market.History(it) / 4
    ns.Market.Compact(it, NOW + 30 * 86400)
    after = after + #ns.Market.History(it) / 4
    bytes = bytes + #(it.hp or "")
  end
end)
print(string.format("   points %d -> %d, packed bytes %d (%.1f per point)", before, after, bytes, bytes / math.max(1, after)))
print("errors logged by the addon: " .. errors())
