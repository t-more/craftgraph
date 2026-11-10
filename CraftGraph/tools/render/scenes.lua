-- Draws the pictures for the readme and the docs from the simulated market:
-- stills, frame sequences for GIFs, and a captioned tour. From the addon
-- folder:  lua5.1 tools/render/scenes.lua <output folder>
-- then tools/render/make_media.sh turns the SVG frames into PNG, GIF and MP4.
local World = dofile("tools/render/world.lua")
local wow, ns = World.wow, World.ns
local OUT = arg[1] or "media-build"
local M, J, D = ns.Market, ns.Jobs, ns.Deals

local function find(pred)
  for _, f in ipairs(wow.frames) do if pred(f) then return f end end
end
local function sh(cmd) os.execute(cmd) end
sh('mkdir -p "' .. OUT .. '/stills"')

local sequences = {}
-- Adds a frame to a sequence, shown for `seconds`.
local function frame(seq, opts, seconds)
  local s = sequences[seq]
  if not s then
    s = { n = 0, list = {} }
    sequences[seq] = s
    sh('mkdir -p "' .. OUT .. "/" .. seq .. '"')
  end
  s.n = s.n + 1
  local name = string.format("%04d", s.n)
  wow.svg(OUT .. "/" .. seq .. "/" .. name .. ".svg", opts)
  s.list[#s.list + 1] = { name, seconds or 0.1 }
end
local function still(name, opts) wow.svg(OUT .. "/stills/" .. name .. ".svg", opts) end
local function tour(caption, seconds) frame("tour", { caption = caption, captionScale = 1.25 }, seconds or 3.5) end
local function settle() wow.runTimers() end
local function calm() wow.hover(nil) wow.cursor = nil GameTooltip:Hide() end

-- The auction house is open and a scan is seven minutes old.
M.ahOpen = true
ns.Fire("AH_STATE", true)
ns.settings.showGuesses = false
ns.settings.sideChart = "history"
local hero = World.item("Bronze Bar")
ns.Open(hero) settle()
local window = CraftGraphFrame
local side = find(function(f) return f.week and f.chartMode end)
local trends = find(function(f) return f.options and f.facts end)
local worth = find(function(f) return f.filters and f.summary end)
local search = CraftGraphSearchBox

------------------------------------------------------------------------------
-- 1. The graph and the side panel
------------------------------------------------------------------------------
still("overview", { zoom = 1.5 })
tour("Click any item: what it is made from, what it is used in, and what each step costs", 4.5)
frame("graph", {}, 1.8)
for _, name in ipairs({ "Copper Bar", "Copper Ore", "Bronze Bar" }) do
  ns.UI.Focus(World.item(name)) settle()
  frame("graph", {}, 1.8)
end

-- Lights drifting along the lines that earn, towards the product.
do
  ns.UI.Focus(hero) settle()
  local graphView = find(function(f) return f.canvas and f.flows end)
  local area = wow.viewOf(graphView, 4)
  for _ = 1, 30 do
    wow.clock = wow.clock + 0.1
    graphView.scripts.OnUpdate(graphView, 0.1)
    frame("flow", { view = area, zoom = 1.4 }, 0.1)
  end
  tour("Gold lines earn, red ones lose; small lights drift the way the money flows", 4)
end

-- What to make: the golden halo, and the slider for how much to buy.
do
  ns.UI.Focus(hero) settle()
  local graphView = find(function(f) return f.canvas and f.flows and f.slider end)
  local area = wow.viewOf(graphView, 4)
  still("rank", { view = area, zoom = 1.5 })
  tour("The most golden card is the best thing to make now; greyed ones need a recipe you lack", 4.5)
  for _, step in ipairs({ { 1, "Buying whatever it takes: ranked by the best amount the market allows" },
      { 0.5, "Willing to buy half of that" }, { 0, "Only what is in your bags and bank" },
      { 1, "Drag the slider: the ranking follows" } }) do
    graphView.SetRatio(step[1]) settle()
    wow.point(graphView.slider, step[1], 0.5)
    for _ = 1, 8 do
      wow.clock = wow.clock + 0.2
      graphView.scripts.OnUpdate(graphView, 0.2)
      frame("rank", { view = area, zoom = 1.3, caption = step[2], captionScale = 1.0 }, 0.2)
    end
  end
  calm()
  -- Something the character could make if the recipe were learned: the
  -- item that teaches it sits on the corner of its icon.
  local unlearned
  for _, id in ipairs(World.ids) do
    local spell, teacher = ns.Player.Unlearned(id)
    if spell and teacher and ns.Market.Info(id) then unlearned = id break end
  end
  if unlearned then
    ns.UI.Focus(unlearned) settle()
    local v = wow.viewOf(side, 0)
    still("unlearned", { view = { v[1], v[2], v[3], 150 }, zoom = 2 })
    wow.point(side.teach, 0.5, 0.5) wow.hover(side.teach)
    still("unlearned-tip", { view = { v[1] - 60, v[2], v[3] + 60, 190 }, zoom = 2 })
    calm()
    tour("A recipe you have not learned: the item that teaches it is shown on the icon", 4)
  else
    print("no unlearned recipe with a teaching item in the simulated market")
  end
  ns.UI.Focus(hero) settle()
end

-- The price box: history with forecast, then the week and the day folded.
local function boxView(captioned)
  local v = wow.viewOf(side.week, 8)
  v[2], v[4] = v[2] - 26, v[4] + 26
  -- room under the box for a caption, so that it covers nothing
  if captioned then v[4] = v[4] + 30 end
  return v
end
ns.UI.Focus(hero) settle()
frame("pictures", { view = boxView(true), zoom = 2, caption = "Price history, with a forecast when it is worth one", captionScale = 1.1 }, 2.4)
tour("Price history with the certainty drawn as a glow, and suns and moons for the time of day", 4)
ns.settings.chartFlow, ns.settings.chartDemand = true, true
ns.UI.Refresh() settle()
frame("pictures", { view = boxView(true), zoom = 2, caption = "Tick Supply and Demand: units listed (blue), sold a day (green)", captionScale = 1.1 }, 2.4)
ns.settings.chartFlow, ns.settings.chartDemand = false, false
ns.UI.Refresh() settle()

-- Reading sizes off the chart: the grid (on by default) and the change bars.
ns.settings.chartBars = true
ns.UI.Refresh() settle()
still("grid-bars", { view = boxView(), zoom = 2 })
frame("pictures", { view = boxView(true), zoom = 2, caption = "A grid with prices, and bars for how much it moved", captionScale = 1.1 }, 2.4)
ns.settings.chartBars = false
ns.UI.Refresh() settle()

-- Supply and demand telling a story: three weeks of Copper Bar.
ns.UI.Focus(World.item("Copper Bar")) settle()
ns.settings.chartDays = 0
side.range:SetText("All")
ns.settings.chartFlow, ns.settings.chartDemand, ns.settings.chartSmooth = true, true, 360
ns.UI.Refresh() settle()
still("supply-demand", { view = boxView(), zoom = 2 })
tour("Supply (blue) floods in and the price sinks; demand (green) surges and it jumps", 5)
local chartFrame = find(function(f) return f.plot and f.clocks and f.smooth end)
for _, step in ipairs({ { 0, "Left to itself the chart picks the smoothing" }, { 60, "Smoothed over an hour: every wiggle" },
    { 360, "Over six hours: the days show" }, { 1440, "Over a day: the story" } }) do
  ns.settings.chartSmooth = step[1]
  ns.UI.Refresh() settle()
  wow.point(chartFrame.smooth, 0.4, 0.5)
  frame("smoothing", { view = boxView(true), zoom = 2, caption = step[2], captionScale = 1.1 }, 2.2)
end
calm()
ns.settings.chartDays, ns.settings.chartSmooth = 14, 0
side.range:SetText("14 days")
ns.settings.chartFlow, ns.settings.chartDemand = false, false
ns.UI.Focus(hero) settle()
ns.settings.sideChart = "week" ns.UI.Refresh() settle()
side.week.Select(14)
frame("pictures", { view = boxView(true), zoom = 2, caption = "Every scan folded onto one week", captionScale = 1.1 }, 2.4)
tour("The same scans folded onto one week: the usual curve, and where next week is heading", 4)
-- Drag the selector across the week.
for slot = 2, 166, 3 do
  side.week.Select(slot)
  wow.point(side.week.plot, (slot + 0.5) / 168, 0.45)
  frame("week", { view = boxView(), zoom = 2 }, 0.09)
  if slot % 24 == 14 then
    frame("tour", { caption = "Drag across the week to read the price at any time, such as Monday afternoon", captionScale = 1.25 }, 0.5)
  end
end
side.week.Select(14)
wow.point(side.week.plot, 14.5 / 168, 0.45)
frame("week", { view = boxView(), zoom = 2 }, 1.5)
still("week", { view = boxView(), zoom = 2 })
calm()
ns.settings.sideChart = "day" ns.UI.Refresh() settle()
side.week.Select(20)
frame("pictures", { view = boxView(true), zoom = 2, caption = "... or onto one day", captionScale = 1.1 }, 2.4)
ns.settings.sideChart = "history" ns.UI.Refresh() settle()

------------------------------------------------------------------------------
-- 2. Opportunities
------------------------------------------------------------------------------
ns.UI.ShowWorth(true) settle()
still("opportunities", { zoom = 1.5 })
tour("Opportunities: every way to make money right now, surest first", 4)
-- The material that most paying crafts need: a good "this item" example.
local uses, best = {}, nil
for _, d in ipairs((D.All())) do
  if d.kind == "craft" then
    for item in pairs(ns.Opt.Evaluate(d.id, d.qty).plan.buy) do
      uses[item] = (uses[item] or 0) + 1
      if not best or uses[item] > uses[best] then best = item end
    end
  end
end
ns.UI.Focus(best or hero) settle()
ns.UI.ShowWorth(true) settle()
worth.filters.item.scripts.OnClick(worth.filters.item)
tour("\"This item\": everything you could do with one thing if you bought it now", 3.5)
local row = worth.rows[2] and worth.rows[2].data and worth.rows[2] or worth.rows[1]
wow.point(row, 0.25, 0.5) wow.hover(row)
still("this-item", { zoom = 1.5 })
tour("Hover an option: an example in plain words, and the profit by when it sells", 5)
calm()
worth.filters.later.scripts.OnClick(worth.filters.later)
still("when", { zoom = 1.5 })
tour("\"When\": what you hold or can make, and the best hour this week to sell it", 4)
worth.filters.all.scripts.OnClick(worth.filters.all)

------------------------------------------------------------------------------
-- 3. Trends
------------------------------------------------------------------------------
ns.UI.Focus(hero) settle()
ns.UI.ShowTrends(true) settle()
trends.options["period:week"].scripts.OnClick()
trends.barHits[15].scripts.OnMouseDown(trends.barHits[15], "LeftButton")
still("trends", { zoom = 1.5 })
tour("Trends: when it is cheap and dear, how fast it sells, and whose auctions sell", 4.5)
ns.UI.ShowTrends(false)

------------------------------------------------------------------------------
-- 4. A plan that keeps its numbers up to date
------------------------------------------------------------------------------
ns.UI.ShowWorth(true) settle()
local kinds, planned = {}, 0
for _, d in ipairs((D.All())) do
  if d.id and d.kind ~= "bags" and d.sure and not kinds[d.kind] and planned < 3 then
    kinds[d.kind] = true
    planned = planned + 1
    if d.kind == "craft" then J.Pin(d.id, d.qty) else
      J.Pin(d.id, d.qty, { kind = d.kind, qty = d.qty, outlay = d.outlay, sellEach = d.sellEach, profit = d.profit })
    end
  end
end
settle()
ns.UI.UpdateHUD() settle()
local hud = find(function(f) return f.rows and f.buy and f.mail end)
tour("Plan it: a small window lists each plan's next step and what it should earn", 4)
window:Hide()
local function hudView() return wow.viewOf(hud, 10) end
frame("plan", { view = hudView(), zoom = 2 }, 1.5)
for i = 1, 14 do
  World.scan(0.25)
  ns.UI.UpdateHUD() settle()
  frame("plan", { view = hudView(), zoom = 2 }, 0.7)
end
wow.point(hud.rows[1], 0.5, 0.5) wow.hover(hud.rows[1])
local tipView = hudView()
tipView[1], tipView[3] = tipView[1] - 360, tipView[3] + 360
tipView[4] = math.max(tipView[4], 470)
frame("plan", { view = hudView(), zoom = 2 }, 0.2)
still("plan", { view = hudView(), zoom = 2 })
still("plan-breakdown", { view = tipView, zoom = 1.6 })
calm()
window:Show() settle()
ns.UI.ShowWorth(false) settle()
tour("Each new scan updates the plan: profit now, how it moved, its median and average", 4.5)

------------------------------------------------------------------------------
-- 5. Honest about what it does not know
------------------------------------------------------------------------------
J.Clear()
ns.UI.UpdateHUD() settle()
local early = World.item("Tin Bar")
local rec = ns.realm.items[early]
do
  local h = M.History(rec)
  local keep = {}
  for i = #h - 11, #h do keep[#keep + 1] = h[i] end
  rec.h, rec.hp, rec.hn = keep, nil, #keep
  ns.generation = ns.generation + 1
end
ns.UI.Focus(early) settle()
ns.settings.sideChart = "week" ns.UI.Refresh() settle()
frame("guesses", { view = boxView(true), zoom = 2, caption = "Three scans: no pattern is drawn, and it says why", captionScale = 1.1 }, 2.6)
tour("With too few scans it shows only what was seen, and says so", 4)
ns.settings.showGuesses = true
ns.generation = ns.generation + 1
ns.UI.Refresh() settle()
frame("guesses", { view = boxView(true), zoom = 2, caption = "Curious anyway? One switch shows the guess", captionScale = 1.1 }, 2.6)
ns.settings.showGuesses = false
ns.generation = ns.generation + 1
ns.settings.sideChart = "history" ns.UI.Refresh() settle()

-- The Data page and its sub-pages.
do
  local function friend(name, github, age)
    local items = {}
    for i = 1, 40 do
      local item = World.ids[i * 7]
      local info = M.Info(item)
      if info and info.price then
        items[#items + 1] = '"' .. item .. '":{"t":' .. (wow.now - age) .. ',"n":' .. (info.total or 1) .. ',"l":[' .. math.floor(info.price * 0.97) .. ',' .. (info.total or 1) .. ']}'
      end
    end
    return '{"format":"craftgraph-prices","version":1,"realm":"' .. ns.realmKey .. '","from":"' .. name .. '","github":"' .. github
      .. '","made":' .. (wow.now - age) .. ',"items":{' .. table.concat(items, ",") .. '}}'
  end
  M.Import(friend("Anwen", "anwen-plays", 1500))
  M.Import(friend("Borin", "borin-ironfoot", 5400))
  M.Import(friend(UnitName("player"), "demo-account", 900))
  ns.UI.ShowData("sources") settle()
  still("sources", { view = wow.viewOf(ns.UI.sourcesFrame, 14), zoom = 2 })
  still("data-sources", { zoom = 1.5 })
  tour("Data: every extra source has a switch, and so has every player who shares with you", 4)
  ns.UI.ShowShare("export") settle()
  still("data-share", { zoom = 1.5 })
  tour("Import and export: your prices as text to send, or paste what a friend sent", 4)
  ns.UI.ShowData("github") settle()
  still("data-github", { zoom = 1.5 })
  tour("GitHub (optional): who shares, and how to connect from outside the game", 4)
  ns.Helper = false
  ns.UI.ShowData("blizzard") settle()
  still("data-blizzard", { zoom = 1.5 })
  tour("Blizzard prices (optional): a step-by-step setup that shows only what is left", 4)
  -- Half way: the helper is there with a key, and has just answered.
  ns.Helper = { written = wow.now, python = "3.12", key = true, watch = true, timer = false, windows = false,
    results = { { id = "demo", action = "archive", ok = true, t = wow.now - 20,
      text = "Imported 1 saved file: 412 new price points.\nDatabase: market.sqlite (1.4 MB)." } } }
  ns.db.asked = { id = "demo", a = "archive", t = wow.now - 30, loads = 1 }
  ns.db.lastFullScan = ns.db.lastFullScan or wow.now - 600
  ns.UI.UpdateBlizzard() settle()
  still("data-blizzard-fetch", { zoom = 1.5 })
  tour("Buttons in the game ask a helper outside it; the answer shows after a reload", 4)
  ns.Helper, ns.db.asked = false, nil
  ns.UI.ShowSales(false) settle()
  still("data-sales", { zoom = 1.5 })
  tour("Sales seen: the auctions judged sold between full scans", 4)
  M.ClearShared()
  ns.UI.ShowData()
end
------------------------------------------------------------------------------
-- An imaginary rush: a crowd of new players arrives, and what riding the
-- wave would have looked like in the window.
------------------------------------------------------------------------------
do
  local potion = World.WAVE.potion
  local oldDays, oldDemand, oldQty, oldFlow = ns.settings.chartDays, ns.settings.chartDemand, ns.settings.qty, ns.settings.chartFlow
  ns.settings.chartDays, ns.settings.chartDemand, ns.settings.chartFlow = 14, true, true
  local BATCH = 40
  local function caption(age)
    if age < 0 then return "An imaginary realm on a quiet week. Making " .. BATCH .. " elixirs barely pays" end
    if age < 1 then return "Day 1: a crowd of new players arrives. They all want the same elixir" end
    if age < 2 then return "The shelf is bought nearly empty and the price doubles" end
    if age < 5 then return "Their gathering floods the market with herbs: cheap materials, dear elixir. Make and sell now" end
    if age < 9 then return "Other alchemists catch up: more is listed, the price slides, the window closes" end
    return "Back to normal. The wave lasted a week; the window to ride it, about four days"
  end
  local profits = {}
  for step = -2, 26 do
    local age = step / 2
    World.wave(age)
    ns.UI.Focus(potion)
    ns.UI.SetQuantity(BATCH) settle()
    local e = ns.Opt.Evaluate(potion, BATCH)
    profits[age] = e.profit
    frame("wave", { caption = caption(age), captionScale = 1.25 }, (age == -1 or age == 13) and 2.5 or 0.7)
    if age == 3 then
      still("wave-ride", { zoom = 1.5 })
      tour("An imaginary rush of new players: cheap herbs, dear elixir. The window says make and sell now", 4.5)
      ns.UI.ShowTrends(true) settle()
      still("wave-trends", { zoom = 1.5 })
      ns.UI.ShowTrends(false) settle()
    end
    if age == 13 then still("wave-after", { zoom = 1.5 }) end
  end
  -- What it came to, for the guide: one batch each evening.
  local ride, late = 0, 0
  for day = 1, 5 do ride = ride + (profits[day] or 0) end
  for day = 9, 13 do late = late + (profits[day] or 0) end
  local f = assert(io.open(OUT .. "/wave.txt", "w"))
  f:write(string.format("batch %d\nquiet %.0f\n", BATCH, profits[-1] or 0))
  for day = 0, 13 do f:write(string.format("day %d profit %.0f\n", day, profits[day] or 0)) end
  f:write(string.format("ride days 1-5: %.0f\nlate days 9-13: %.0f\n", ride, late))
  f:close()
  World.wave(nil)
  ns.settings.chartDays, ns.settings.chartDemand, ns.settings.chartFlow = oldDays, oldDemand, oldFlow
  ns.UI.SetQuantity(oldQty or 1)
end
ns.UI.Focus(hero) settle()
tour("CraftGraph: /cg in game. Everything here was drawn from simulated data", 4)

-- Frame lists for ffmpeg, and the icons that were missing.
for name, s in pairs(sequences) do
  local f = assert(io.open(OUT .. "/" .. name .. "/frames.txt", "w"))
  for _, item in ipairs(s.list) do
    f:write("file '" .. item[1] .. ".png'\nduration " .. item[2] .. "\n")
  end
  f:write("file '" .. s.list[#s.list][1] .. ".png'\n")
  f:close()
  print(name .. ": " .. s.n .. " frames")
end
local wanted = {}
for key in pairs(wow.missingIcons) do wanted[#wanted + 1] = key end
table.sort(wanted)
local f = assert(io.open(OUT .. "/icons-wanted.txt", "w"))
f:write(table.concat(wanted, "\n"), "\n")
f:close()
local errors = 0
for _, line in ipairs(ns.db.log) do
  if line:find("ERROR") then
    errors = errors + 1
    if errors <= 3 then print(line:sub(1, 500)) end
  end
end
print(#wanted .. " icons not on disk; addon errors: " .. errors)
os.exit(errors == 0 and 0 or 1)
