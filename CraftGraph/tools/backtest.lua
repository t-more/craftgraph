-- Compares the first price model with the current one on simulated markets
-- (falling prices, lasting jumps, stray listings, daily and weekly habits)
-- under three scanning habits. Run from the addon folder with Lua 5.1:
--   lua5.1 tools/backtest.lua . tools/stats_v1.lua 6
-- The simulated strays revert; the real scans so far do not (see
-- backtest_real.lua), so trust the real check over this one where they differ.
-- Walk-forward comparison of the old and new price models.
date, time = os.date, os.time
local ADDON_DIR = arg[1]
local function load(path)
  local ns = {}
  assert(loadfile(path))("CraftGraph", ns)
  return ns.Stats
end
local OLD = load(arg[2])
local NEW = load(ADDON_DIR .. "/Stats.lua")

local seed = 12345
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
local function gauss() return math.sqrt(-2 * math.log(rnd() + 1e-12)) * math.cos(2 * math.pi * rnd()) end

local T0 = os.time({ year = 2026, month = 11, day = 2, hour = 0 })   -- a Monday
local DAYS = 28
local function hourEff(h, amp) return amp * math.cos((h - 20) / 24 * 2 * math.pi) end      -- dearest at 20:00
local function dowEff(wday, amp) return (wday == 0 or wday == 6) and amp or -amp * 2 / 5 end -- weekend dearer

-- level(t in days) generators
local scenarios = {
  { name = "steady market", slope = function() return 0 end, walk = 0.04, hour = 0.04, dow = 0.03 },
  { name = "falling fast, then settling (fresh economy)", slope = function(d) return -0.08 * 0.5 ^ (d / 10) end, walk = 0.06, hour = 0.04, dow = 0.03 },
  { name = "rising 4% a day for two weeks, then flat", slope = function(d) return d < 14 and 0.04 or 0 end, walk = 0.04, hour = 0.04, dow = 0.03 },
  { name = "sudden lasting drop of 40%", slope = function() return 0 end, walk = 0.04, hour = 0.04, dow = 0.03, shift = -0.5 },
  { name = "strong daily and weekend habits", slope = function() return -0.01 end, walk = 0.03, hour = 0.10, dow = 0.06 },
  { name = "no habits at all, falling 3% a day", slope = function() return -0.03 end, walk = 0.05, hour = 0, dow = 0 },
}
local schedules = {
  { name = "hourly, round the clock", at = function(h, q) return q == 0 end },
  { name = "evenings only, every 15 min", at = function(h) return h >= 18 and h <= 22 end },
  { name = "three scans a day", at = function(h, q) return q == 0 and (h == 8 or h == 13 or h == 21) end },
}

local function simulate(sc, sched)
  local pts, truth = {}, {}
  local level = math.log(1000)
  local shiftAt = sc.shift and (10 + rnd() * 10) or nil
  local stray, strayLeft = 0, 0
  for step = 0, DAYS * 96 - 1 do
    local d = step / 96
    level = level + sc.slope(d) / 96 + sc.walk * gauss() / math.sqrt(96)
    if shiftAt and d >= shiftAt then level = level + sc.shift shiftAt = nil end
    local t = T0 + step * 900
    local tm = os.date("*t", t)
    local clean = level + hourEff(tm.hour + tm.min / 60, sc.hour) + dowEff(tm.wday - 1, sc.dow)
    -- A stray listing appears now and then and stays for a while.
    if strayLeft > 0 then strayLeft = strayLeft - 1 else stray = 0 end
    if stray == 0 and rnd() < 0.004 then
      stray = (rnd() < 0.5 and -1 or 1) * (0.3 + 0.7 * rnd())
      strayLeft = math.floor(1 + rnd() * 6)
    end
    truth[#truth + 1] = { t, clean }
    if sched.at(tm.hour, tm.min / 15) then
      local noise = rnd() < 0.5 and 0 or 0.025 * gauss()
      pts[#pts + 1] = { t, math.exp(clean + noise + stray), clean }
    end
  end
  return pts, truth
end

local HORIZONS = { { "next scan", nil }, { "1 day", 1 }, { "3 days", 3 }, { "7 days", 7 } }
local function evaluate(M, pts, truth, stat)
  -- forecast origins: every ~0.9 days after a 5 day warm-up
  local nextOrigin = T0 + 5 * 86400
  for i = 1, #pts do
    if pts[i][1] >= nextOrigin and pts[i][1] < T0 + (DAYS - 7.2) * 86400 then
      nextOrigin = pts[i][1] + 0.9 * 86400 + rnd() * 20000
      local sub = {}
      for j = 1, i do sub[j] = pts[j] end
      local now = pts[i][1]
      local model = M.Fit(sub, now)
      for hi, hz in ipairs(HORIZONS) do
        local target, tt
        if hz[2] then
          tt = now + hz[2] * 86400
          local idx = math.floor((tt - T0) / 900) + 1
          target = truth[idx] and truth[idx][2]
        elseif pts[i + 1] then
          tt, target = pts[i + 1][1], pts[i + 1][3]
        end
        if target then
          local mean, sd = M.Eval(model, (tt - now) / 86400)
          local err = mean - target
          local st = stat[hi]
          st.n = st.n + 1
          st.abs = st.abs + math.abs(err)
          st.sq = st.sq + err * err
          if math.abs(err) <= sd then st.in1 = st.in1 + 1 end
          if math.abs(err) <= 2 * sd then st.in2 = st.in2 + 1 end
        end
      end
    end
  end
end

local function newStat() local s = {} for i = 1, #HORIZONS do s[i] = { n = 0, abs = 0, sq = 0, in1 = 0, in2 = 0 } end return s end
local totalOld, totalNew = newStat(), newStat()
local REPS = tonumber(arg[3]) or 12
for _, sc in ipairs(scenarios) do
  for _, sched in ipairs(schedules) do
    local so, sn = newStat(), newStat()
    for rep = 1, REPS do
      local pts, truth = simulate(sc, sched)
      evaluate(OLD, pts, truth, so)
      evaluate(NEW, pts, truth, sn)
    end
    print(string.format("%-46s | %-26s", sc.name, sched.name))
    for hi, hz in ipairs(HORIZONS) do
      local a, b = so[hi], sn[hi]
      print(string.format("   %-9s  typical miss old %5.1f%%  new %5.1f%%   within range (should be 68%%) old %3.0f%% new %3.0f%%   within 2x (95%%) old %3.0f%% new %3.0f%%",
        hz[1], 100 * a.abs / a.n, 100 * b.abs / b.n, 100 * a.in1 / a.n, 100 * b.in1 / b.n, 100 * a.in2 / a.n, 100 * b.in2 / b.n))
      for _, pair in ipairs({ { totalOld[hi], a }, { totalNew[hi], b } }) do
        for k, v in pairs(pair[2]) do pair[1][k] = pair[1][k] + v end
      end
    end
  end
end
print("ALL SCENARIOS")
for hi, hz in ipairs(HORIZONS) do
  local a, b = totalOld[hi], totalNew[hi]
  print(string.format("   %-9s  typical miss old %5.1f%%  new %5.1f%%   rms old %5.1f%% new %5.1f%%   within range old %3.0f%% new %3.0f%%   within 2x old %3.0f%% new %3.0f%%",
    hz[1], 100 * a.abs / a.n, 100 * b.abs / b.n, 100 * math.sqrt(a.sq / a.n), 100 * math.sqrt(b.sq / b.n), 100 * a.in1 / a.n, 100 * b.in1 / b.n, 100 * a.in2 / a.n, 100 * b.in2 / b.n))
end
