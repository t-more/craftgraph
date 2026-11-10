-- CraftGraph price model. Prices are treated as a random walk in log space
-- that we observe with some noise. A Kalman filter and smoother give the
-- best estimate at every moment together with how sure it is: certainty is
-- high next to an observation and fades in the gaps and into the future.
local ADDON, ns = ...
local S = {}
ns.Stats = S

local log, exp, sqrt, max, min = math.log, math.exp, math.sqrt, math.max, math.min

S.SIGMA0 = 0.12        -- assumed daily drift (log units) before we have data
S.PRIOR_DAYS = 2       -- how strongly that assumption is held
S.TAU = 0.05           -- noise of one observation (log units)
S.DEFAULT_SD = 0.30    -- uncertainty of a price with no history at all
S.FEW_SD = 0.25        -- extra doubt about the price level after one scan;
                       -- it shrinks as scans add up (divided by sqrt(n))

-- points: array of {time in seconds, price}, sorted by time.
-- Times in the model are days relative to `now`.
function S.Fit(points, now)
  local n = #points
  if n == 0 then return nil end
  local t, x = {}, {}
  for i = 1, n do
    t[i] = (points[i][1] - now) / 86400
    x[i] = log(points[i][2])
  end

  local tau2 = S.TAU * S.TAU
  local sumR, sumDt = 0, 0
  for i = 2, n do
    local dt = t[i] - t[i - 1]
    if dt > 0.01 then
      local r = x[i] - x[i - 1]
      sumR = sumR + max(r * r - 2 * tau2, 0)
      sumDt = sumDt + dt
    end
  end
  local s2 = (S.SIGMA0 * S.SIGMA0 * S.PRIOR_DAYS + sumR) / (S.PRIOR_DAYS + sumDt)
  s2 = max(0.02 * 0.02, min(0.6 * 0.6, s2))

  -- Forward filter
  local m, P, Pp = {}, {}, {}
  m[1], P[1] = x[1], tau2
  for i = 2, n do
    local dt = max(t[i] - t[i - 1], 0)
    local pp = P[i - 1] + s2 * dt
    local k = pp / (pp + tau2)
    Pp[i] = pp
    m[i] = m[i - 1] + k * (x[i] - m[i - 1])
    P[i] = (1 - k) * pp
  end
  -- Backward smoother
  for i = n - 1, 1, -1 do
    local c = P[i] / Pp[i + 1]
    m[i] = m[i] + c * (m[i + 1] - m[i])
    P[i] = P[i] + c * c * (P[i + 1] - Pp[i + 1])
  end

  return { t = t, m = m, P = P, s2 = s2, n = n, now = now, few = S.FEW_SD * S.FEW_SD / n }
end

-- Estimate at a time given in days relative to the model's `now`.
-- Returns the mean and standard deviation in log space.
function S.Eval(model, day)
  local t, m, P, s2, n = model.t, model.m, model.P, model.s2, model.n
  local few = model.few or 0
  if day <= t[1] then
    return m[1], sqrt(P[1] + s2 * (t[1] - day) + few)
  end
  if day >= t[n] then
    return m[n], sqrt(P[n] + s2 * (day - t[n]) + few)
  end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if t[mid] <= day then lo = mid else hi = mid end
  end
  local span = t[hi] - t[lo]
  if span <= 0 then return m[hi], sqrt(P[hi] + few) end
  local a = (day - t[lo]) / span
  local mean = m[lo] + a * (m[hi] - m[lo])
  local var = (1 - a) * P[lo] + a * P[hi] + s2 * span * a * (1 - a)
  return mean, sqrt(var + few)
end

------------------------------------------------------------------------------
-- Per-item cache
------------------------------------------------------------------------------
local cache, cacheGen = {}, -1

function S.ForItem(id)
  if cacheGen ~= ns.generation then
    cache, cacheGen = {}, ns.generation
  end
  local entry = cache[id]
  if entry == nil then
    local series = ns.Market.Series(id)
    local now = time()
    entry = { series = series, model = S.Fit(series, now) or false, now = now }
    cache[id] = entry
  end
  return entry
end

-- Estimated price and its uncertainty `days` from now (0 = right now).
-- Returns price, sd (log units; roughly a fraction, 0.1 = about 10%).
function S.Estimate(id, days)
  local entry = S.ForItem(id)
  if not entry.model then return nil end
  local mean, sd = S.Eval(entry.model, days or 0)
  return exp(mean), sd
end

------------------------------------------------------------------------------
-- Trend facts for one item, in plain numbers:
--   now, usual (median of the last 14 days), vsUsual (fraction, -0.1 = 10%
--   under), perDay (fractional change a day over the last week, or nil when
--   there is too little to say), swing (typical daily move), scans.
------------------------------------------------------------------------------
function S.Trend(id)
  local entry = S.ForItem(id)
  local series = entry.series
  if not entry.model or #series == 0 then return nil end
  local now = entry.now
  local out = { scans = #series, swing = exp(sqrt(entry.model.s2)) - 1 }
  out.now = exp((S.Eval(entry.model, 0)))

  local recent = {}
  for i = 1, #series do
    if now - series[i][1] <= 14 * 86400 then recent[#recent + 1] = series[i][2] end
  end
  if #recent >= 3 then
    table.sort(recent)
    local mid = #recent / 2
    out.usual = (#recent % 2 == 1) and recent[math.ceil(mid)] or (recent[mid] + recent[mid + 1]) / 2
    out.vsUsual = out.now / out.usual - 1
  end

  -- Least-squares slope of log price over the last week.
  local n, sx, sy, sxx, sxy, first, last = 0, 0, 0, 0, 0, nil, nil
  for i = 1, #series do
    local days = (series[i][1] - now) / 86400
    if days >= -7 then
      local y = log(series[i][2])
      n, sx, sy, sxx, sxy = n + 1, sx + days, sy + y, sxx + days * days, sxy + days * y
      first, last = first or days, days
    end
  end
  if n >= 4 and last - first >= 1 then
    local denom = n * sxx - sx * sx
    if denom > 1e-9 then
      out.perDay = exp((n * sxy - sx * sy) / denom) - 1
      out.trendScans = n
    end
  end
  return out
end

-- The effect one hour (or weekday) has on the price, as a log deviation
-- from the usual price, with how far it can be trusted.
-- Returns effect, variance, scans behind it, how many slots away the
-- nearest real sample is (0 = this slot has its own; nil = no pattern at
-- all), and the average units listed.
local function SlotEffect(pattern, count, key, s2)
  if pattern.filled == 0 then return 0, s2, 0, nil, nil end
  -- A slot's average is pulled toward "no effect" while it rests on few scans.
  local function Shrunk(sl) return log(1 + sl.price) * sl.n / (sl.n + 1) end
  local sl = pattern.slots[key]
  if sl then return Shrunk(sl), s2 / sl.n, sl.n, 0, sl.listed end
  -- No scan at this time: fill in from the nearest sampled slots on each
  -- side (the clock and the week both wrap around).
  local left, right, dl, dr
  for d = 1, count - 1 do
    if not left and pattern.slots[(key - d) % count] then left, dl = pattern.slots[(key - d) % count], d end
    if not right and pattern.slots[(key + d) % count] then right, dr = pattern.slots[(key + d) % count], d end
  end
  local wl, wr = dr / (dl + dr), dl / (dl + dr)
  local near = min(dl, dr)
  return Shrunk(left) * wl + Shrunk(right) * wr, s2 * (1 + 0.5 * near), 0, near,
    left.listed * wl + right.listed * wr
end

-- Everything needed to estimate an item's price at a given time of the
-- week: its usual price and its hour-of-day and weekday patterns.
-- Returns nil when the item has no price yet.
function S.Week(id)
  local t = S.Trend(id)
  if not t then return nil end
  local entry = S.ForItem(id)
  local _, sd0 = S.Eval(entry.model, 0)
  local hourTally, hourOnline = ns.Market.Tally(id, "hd")
  local dayTally, dayOnline = ns.Market.Tally(id, "wd")
  -- The level the patterns swing around: the average (in ratio terms) of
  -- the last two weeks. A plain middle value would sit on one side when the
  -- price flips between a cheap and a dear time of day.
  local sum, n = 0, 0
  for i = 1, #entry.series do
    local pt = entry.series[i]
    if entry.now - pt[1] <= 14 * 86400 and pt[2] > 0 then sum, n = sum + log(pt[2]), n + 1 end
  end
  local w = {
    base = n >= 3 and exp(sum / n) or t.now,
    hours = S.Pattern(hourTally, 24),
    days = S.Pattern(dayTally, 7),
    s2 = entry.model.s2,             -- how much the price moves in a day
    sd0 = sd0,                       -- how sure we are of the price itself
    online = (hourOnline or dayOnline) and true or false,
  }
  sum, n = 0, 0
  for _, sl in pairs(w.days.slots) do sum, n = sum + sl.listed, n + 1 end
  w.dayListed = n > 0 and sum / n or nil
  return w
end

-- The estimated price at one time of the week. day: 0 = Sunday ... 6, or
-- nil for "any day". hour: 0 to 23, or nil for "the whole day".
-- The hour and the weekday are taken to act independently: Monday's effect
-- and the afternoon's effect are added. Returns
--   price, lo, hi   best estimate and the range it is likely within (about
--                   two times in three)
--   rel             the estimate relative to the usual price (fraction)
--   hourN, dayN     scans behind the hour and the weekday
--   hourGap, dayGap slots to the nearest real sample (0 = sampled here,
--                   nil = no pattern for it at all)
--   listed          expected units listed, or nil
function S.WeekAt(w, day, hour)
  local effect, var = 0, w.sd0 * w.sd0 + w.s2
  local out = {}
  local hourListed, dayListed
  if hour then
    local e, v, n, gap, listed = SlotEffect(w.hours, 24, hour, w.s2)
    effect, var = effect + e, var + v
    out.hourN, out.hourGap, hourListed = n, gap, listed
  end
  if day then
    local e, v, n, gap, listed = SlotEffect(w.days, 7, day, w.s2)
    effect, var = effect + e, var + v
    out.dayN, out.dayGap, dayListed = n, gap, listed
  end
  local sd = sqrt(var)
  out.rel = exp(effect) - 1
  out.price = w.base * exp(effect)
  out.lo, out.hi = out.price * exp(-sd), out.price * exp(sd)
  if hourListed and dayListed and w.dayListed and w.dayListed > 0 then
    out.listed = hourListed * dayListed / w.dayListed
  else
    out.listed = hourListed or dayListed
  end
  return out
end

-- A tally by hour or weekday turned into something to draw: for each slot
-- the number of scans, the price relative to the item's own average across
-- the slots (fraction), and the average units listed. `slots` is 24 or 7.
function S.Pattern(tally, slots)
  local out = { slots = {}, scans = 0, filled = 0 }
  if type(tally) ~= "table" then return out end
  local sumRel, sumN = 0, 0
  for key = 0, slots - 1 do
    local c = tally[key]
    if c and c[1] > 0 then
      sumRel, sumN = sumRel + c[2], sumN + c[1]
    end
  end
  if sumN == 0 then return out end
  local mean = sumRel / sumN
  for key = 0, slots - 1 do
    local c = tally[key]
    if c and c[1] > 0 then
      out.slots[key] = { n = c[1], price = exp(c[2] / c[1] - mean) - 1, listed = c[3] / c[1] }
      out.filled = out.filled + 1
    end
  end
  out.scans = sumN
  return out
end
