-- Do priors taken from the market beat the fixed ones? On the simulated
-- market: keep only the first few days of every item's scans, fit each item
-- with the fixed assumptions and with the market's, and see how well the
-- next day's scans are predicted. From the addon folder:
--   lua5.1 tools/backtest_priors.lua
-- Reported per amount of history: the typical error (log units; 0.05 is
-- about 5%), and how often the truth fell within one and two margins
-- (an honest margin gives 68% and 95%).
--   lua5.1 tools/backtest_priors.lua <SavedVariables/CraftGraph.lua>   the same on real scans:
--   the last quarter of the history is held back and predicted from the rest.
local ns, S, M, END, START
local DAY = 86400
local all = {}
if arg[1] then
  local wow = dofile("tools/render/wowlayout.lua")
  C_Item = { GetItemInfoInstant = function(id) return id end, GetItemCount = function() return 0 end }
  C_AuctionHouse = { GetNumReplicateItems = function() return 0 end }
  dofile(arg[1])
  local db = CraftGraphDB
  local realm, best = nil, 0
  for _, r in pairs(db.realms) do
    local n = 0
    for _ in pairs(r.items or {}) do n = n + 1 end
    if n > best then realm, best = r, n end
  end
  CraftGraphDB = nil
  ns = wow.load("CraftGraph.toc")
  wow.fire("ADDON_LOADED", "CraftGraph")
  wow.fire("PLAYER_LOGIN")
  ns.realm = realm
  S, M = ns.Stats, ns.Market
  S.usePrior = false
  END, START = 0, math.huge
  for id, it in pairs(realm.items) do
    if type(it) == "table" and (it.hc or 0) >= 6 then
      local series = M.Series(id)
      if #series >= 6 then
        all[id] = series
        END, START = math.max(END, series[#series][1]), math.min(START, series[1][1])
      end
    end
  end
  wow.now = END
else
  local World = dofile("tools/render/world.lua")
  ns, S, M = World.ns, World.ns.Stats, World.ns.Market
  END, START = World.END, World.END - 21 * DAY
  for _, id in ipairs(World.ids) do all[id] = M.Series(id) end
end

local function run(days, ahead)
  local cut = START + days * DAY
  local train, test = {}, {}
  local list = {}
  for id, series in pairs(all) do
    local a, b = {}, {}
    for _, p in ipairs(series) do
      if p[1] <= cut then a[#a + 1] = p elseif p[1] <= cut + ahead * DAY then b[#b + 1] = p end
    end
    if #a >= 2 and #b >= 1 then train[id], test[id] = a, b list[#list + 1] = a end
  end
  local prior = S.PriorFrom(list, cut)
  local out = {}
  for name, use in pairs({ fixed = false, market = prior }) do
    local err, n, in1, in2 = 0, 0, 0, 0
    for id, a in pairs(train) do
      local model = S.Fit(a, cut, nil, use)
      for _, p in ipairs(test[id]) do
        local mean, sd = S.Eval(model, (p[1] - cut) / DAY)
        local e = math.abs(math.log(p[2]) - mean)
        err, n = err + e, n + 1
        if e <= sd then in1 = in1 + 1 end
        if e <= 2 * sd then in2 = in2 + 1 end
      end
    end
    out[name] = { err = err / n, in1 = in1 / n, in2 = in2 / n, n = n }
  end
  print(string.format("%4.1f days of history, %d items: market says wander %.3f a day (fixed %.2f), hours from %d item-days",
    days, #list, prior.sigma0, S.SIGMA0, prior.hourDays or 0))
  for _, name in ipairs({ "fixed", "market" }) do
    local r = out[name]
    print(string.format("    %-7s error %.4f   within one margin %2.0f%%   within two %2.0f%%   (%d predictions)",
      name, r.err, r.in1 * 100, r.in2 * 100, r.n))
  end
end
if arg[1] then
  local span = (END - START) / DAY
  print(string.format("real scans: %.1f hours of history", span * 24))
  run(span * 0.5, span * 0.25)
  run(span * 0.75, span * 0.25)
else
  for _, days in ipairs({ 0.6, 1, 2, 4, 8, 14 }) do run(days, 1) end
end
