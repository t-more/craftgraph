-- Estimates whether each label fits its space, with real item names and
-- prices (character widths are estimates; the game's own truncation report
-- in the saved log is the final word). From the addon folder:
--   lua5.1 tools/qa_fit.lua <path to SavedVariables/CraftGraph.lua>
-- Layout QA: estimates the pixel width of every label on graph items, tracker rows and list rows
-- against the space it has, using the real saved scan for realistic prices.
local src = io.open("tools/test.lua"):read("*a"):gsub("os%.exit%b()", "")
src = src:gsub("function Widget:SetSize%(w, h%) self.w, self.h = w, h end", [[
function Widget:SetSize(w, h) self.w, self.h = w, h end
function Widget:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = { ... }; self.point = { ... } end
function Widget:ClearAllPoints() self.point = nil; self.points = nil end
]])
src = src:gsub("function Widget:CreateFontString%(%) return NewWidget%(\"FontString\"%) end",
  'function Widget:CreateFontString() local t = NewWidget("FontString"); t.owner = self; self.kids = self.kids or {}; self.kids[#self.kids+1] = t; return t end')
local realprint = print
print = function() end
assert(loadstring(src .. "\n_G.NS = ns; _G.FRAMES = frames; _G.RUNT = RunTimers"))()
print = realprint
local ns = NS
dofile(arg[1])
local key, realm = next(CraftGraphDB.realms)
ns.realm = realm
local scanTime = 0
for _, it in pairs(realm.items) do if it.lt and it.lt > scanTime then scanTime = it.lt end end
time = function() return scanTime + 600 end
local all = {}
for id in pairs(ns.Data.skills) do all[#all + 1] = id end
GetProfessions = nil
GetNumSkillLines = function() return #all end
GetSkillLineInfo = function(i) return ns.Data.skills[all[i]], false, nil, 300 end
C_TradeSkillUI = { GetRecipeInfo = function() return { learned = true } end }
C_Container = nil
C_Item.GetItemCount = function() return 3 end
ns.generation = ns.generation + 1
ns.Player.version = ns.Player.version + 1

local W = { [" "] = 3.0, i = 2.7, l = 2.7, j = 3, t = 3.6, f = 3.6, r = 3.9, m = 8.4, w = 7.8, M = 9, W = 9.4,
  ["."] = 2.6, [","] = 2.6, [":"] = 2.6, ["'"] = 2.2, ["("] = 3.4, [")"] = 3.4, ["+"] = 6, ["-"] = 3.6, ["%"] = 8 }
local function width(text, scale)
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  local px = 0
  text = text:gsub("|A:.-|a", function() px = px + 13 return "" end)
  text = text:gsub("\194\177", "+")
  for ch in text:gmatch(".") do
    local w = W[ch]
    if not w then
      if ch:match("%d") then w = 6.1 elseif ch:match("%u") then w = 7.3 else w = 5.6 end
    end
    px = px + w
  end
  return px * (scale or 1)
end


-- New labels: estimate the widest each gets on the real data against its space.
local RunTimers = RUNT
local frames = FRAMES
local SMALL = 0.92      -- the small fonts are a little narrower than the estimate's base
local results = {}
local function fit(where, text, avail, lines)
  local need = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do need = math.max(need, width(line, SMALL)) end
  -- wrapped text: total width over the lines allowed
  local total = width((text:gsub("\n", " ")), SMALL)
  local ratio = lines and (total / (avail * lines * 0.93)) or (need / avail)
  local r = results[where]
  if not r or ratio > r.ratio then results[where] = { ratio = ratio, text = text, avail = avail, lines = lines } end
end
local ids = {}
for id, it in pairs(realm.items) do if it.l and it.l[1] then ids[#ids + 1] = id end end
table.sort(ids)
ns.Open(ids[1]) RunTimers()
local side, trendsView, worthView
for _, f in ipairs(frames) do
  if f.week and f.chartMode then side = f end
  if f.options and f.facts then trendsView = f end
  if f.filters and f.summary then worthView = f end
end
local longest = {}
for _, id in ipairs(ids) do longest[#longest + 1] = id end
table.sort(longest, function(a, b) return #ns.ItemName(a) > #ns.ItemName(b) end)
local sample = {}
for i = 1, 40 do sample[#sample + 1] = longest[i] end
for i = 1, #ids, 12 do sample[#sample + 1] = ids[i] end
for _, id in ipairs(sample) do
  ns.UI.Focus(id) RunTimers()
  for _, mode in ipairs({ "week", "day" }) do
    ns.settings.sideChart = mode
    ns.UI.Refresh() RunTimers()
    for slot = 0, (mode == "day" and 23 or 167), 5 do
      side.week.Select(slot)
      for line in (side.week.readout.text .. "\n"):gmatch("(.-)\n") do fit("side strip readout line (3 lines of 322)", line, 322) end
    end
    fit("side strip legend", side.week.legend.text, 322)
  end
  ns.settings.sideChart = "history"
  ns.UI.ShowTrends(true) RunTimers()
  for _, k in ipairs({ "period:hour", "period:day", "period:week" }) do
    trendsView.options[k].scripts.OnClick()
    for slot = 1, (k == "period:week" and 168 or k == "period:day" and 7 or 24), 5 do
      trendsView.barHits[slot].scripts.OnMouseDown(trendsView.barHits[slot], "LeftButton")
      fit("trends readout (2 lines of 776)", trendsView.readout.text, 776, 2)
    end
    fit("trends facts (4 lines of 776)", trendsView.facts.text, 776, 4)
    fit("trends chart note", trendsView.chartNote.text, 776)
  end
  ns.UI.ShowTrends(false)
  ns.UI.ShowWorth(true)
  worthView.filters.item.scripts.OnClick(worthView.filters.item)
  fit("opportunities summary (This item)", worthView.summary.text, 375)
  fit("opportunities note (example)", worthView.note.text, 776)
  ns.UI.ShowWorth(false)
end
ns.UI.ShowWorth(true)
worthView.filters.later.scripts.OnClick(worthView.filters.later)
fit("opportunities summary (When)", worthView.summary.text, 375)
for _, row in ipairs(ns.Deals.Timing()) do fit("opportunity how (timing)", row.how, 150) end
worthView.filters.all.scripts.OnClick(worthView.filters.all)
fit("opportunities summary (All)", worthView.summary.text, 375)
-- plan profit line with large and small numbers
local pin = { track = {} }
for _, set in ipairs({ { 1234567, 1199900, 1250000, 1180000 }, { -52345, 81234, -99999, 123456 }, { 95, 80, 99, 70 } }) do
  pin.track = {}
  for i, v in ipairs(set) do pin.track[#pin.track + 1] = i * 300 pin.track[#pin.track + 1] = v end
  fit("plan window profit line", ns.UI.GoalText(pin), 350 - 12 - 38 - 4)
end
ns.settings.autoScan = true
for _, st in ipairs({ { false }, { true, 0 }, { true, 600 } }) do
  ns.Market.ahOpen = st[1]
  ns.db.lastFullScan = st[2] and (time() - 900 + st[2]) or nil
  ns.Market.sessionFullScans = 37
  fit("auto scan label", ns.UI.AutoText(), 262 - 22)
end
for _, t in ipairs({ "Price history", "Week pattern", "Day pattern" }) do fit("chart heading button", t, 112 - 16) end
local names = {}
for k in pairs(results) do names[#names + 1] = k end
table.sort(names, function(a, b) return results[a].ratio > results[b].ratio end)
for _, k in ipairs(names) do
  local r = results[k]
  local plain = r.text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|A:coin%-(%a)%a*:12:12|a", "%1"):gsub("\n", " / ")
  print(string.format("%s %3.0f%%  %-44s %s", r.ratio > 1 and "OVER" or "ok  ", r.ratio * 100, k, plain:sub(1, 150)))
end
