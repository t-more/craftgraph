-- Checks the price model against the scans really recorded: for every item,
-- fit on the first k scans and predict the ones after. Run from the addon
-- folder with plain Lua 5.1:
--   lua5.1 tools/backtest_real.lua . tools/stats_v1.lua <path to SavedVariables/CraftGraph.lua>
-- "just the last scan" is the guess to beat.
date, time = os.date, os.time
local function load(path, over) local ns = {} assert(loadfile(path))("CraftGraph", ns)
  for kv in (over or ""):gmatch("[^,]+") do local k, v = kv:match("(%w+)=(.+)") ns.Stats[k] = tonumber(v) end
  return ns.Stats end
local N = arg[1] .. "/Stats.lua"
local models = {
  { "first model (tools/stats_v1.lua)", load(arg[2]) },
  { "current model", load(N) },
  { "current, doubting far-off scans", load(N, "CLIP=2.5") },
  { "current, scan scatter 0.05", load(N, "TAU=0.05") },
}
dofile(arg[3])
local series = {}
for _, realm in pairs(CraftGraphDB.realms) do
  for id, it in pairs(realm.items or {}) do
    local pts = {}
    for i = 1, #(it.h or {}), 4 do
      local p = it.h[i + 2] > 0 and it.h[i + 2] or it.h[i + 1]
      if p > 0 then pts[#pts + 1] = { it.h[i], p } end
    end
    if #pts >= 7 then series[#series + 1] = pts end
  end
end
print("items", #series)
for _, ahead in ipairs({ 1, 2, 4 }) do
  print("scans ahead: " .. ahead)
  local naive, nn = 0, 0
  for mi, def in ipairs(models) do
    local n, abs, in1 = 0, 0, 0
    for _, pts in ipairs(series) do
      for k = 4, #pts - ahead do
        local sub = {} for j = 1, k do sub[j] = pts[j] end
        local target = math.log(pts[k + ahead][2])
        local model = def[2].Fit(sub, pts[k][1])
        local mean, sd = def[2].Eval(model, (pts[k + ahead][1] - pts[k][1]) / 86400)
        local e = math.abs(mean - target)
        n, abs = n + 1, abs + e
        if e <= sd then in1 = in1 + 1 end
        if mi == 1 then naive, nn = naive + math.abs(math.log(pts[k][2]) - target), nn + 1 end
      end
    end
    print(string.format("  %-28s mean miss %.2f%%  inside range %d%%", def[1], 100 * abs / n, 100 * in1 / n))
  end
  print(string.format("  %-28s mean miss %.2f%%", "just the last scan", 100 * naive / nn))
end
