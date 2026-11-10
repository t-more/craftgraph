-- CraftGraph price model.
--
-- A price (in log terms) is taken to be the sum of three things:
--   a level that wanders, with a trend that fades  (the market itself)
--   an effect of the hour of day and of the weekday (habits of the players)
--   scatter in what a single scan happens to see
--
-- Why this shape, for a young auction house:
--   * Prices drift for days on end while supply catches up with demand, so
--     the level carries a slope. The slope is damped: without fresh
--     evidence a trend is expected to fade, not to run on for ever.
--   * Real scans mostly repeat the last price and now and then jump by a
--     large factor. Measured on this realm's scans, those jumps stay: the
--     last scan predicts the next ones better than any smoothing of it. So
--     a scan is taken almost at its word (TAU is small) and a jump is the
--     new level at once. Doubting far-off scans (CLIP) made every forecast
--     of the real data worse and is switched off; tools/backtest.lua and
--     tools/backtest_real.lua measure it again when there is more history.
--   * Evening and weekend habits are learned from how each scan differs
--     from the other scans of the same day (hours) and from each day's
--     level against the days around it (weekdays). Old scans count for
--     less, and an effect seen once is mostly doubted.
-- A Kalman filter and smoother give the level and trend at every moment
-- with how sure they are: tight next to scans, fading in gaps and ahead.
local ADDON, ns = ...
local S = {}
ns.Stats = S

local log, exp, sqrt, max, min, floor, abs = math.log, math.exp, math.sqrt, math.max, math.min, math.floor, math.abs

S.SIGMA0 = 0.12        -- assumed daily wander of the level (log units) before we have data
S.PRIOR_DAYS = 2       -- how strongly that assumption is held
S.TAU = 0.01           -- scatter of one scan (log units); see the note above
S.DEFAULT_SD = 0.30    -- uncertainty of a price with no history at all
S.FEW_SD = 0.25        -- extra doubt about the price level after one scan;
                       -- it shrinks as scans add up (divided by sqrt(n))
S.PHI = 0.90           -- how much of a trend is left a day later
S.SLOPE0 = 0.04        -- how large a daily trend is expected to be (log units)
S.CLIP = math.huge     -- a scan further off than this many sd would be doubted (off)
S.SHIFT_DAYS = 0.125   -- ... unless the jump has lasted this long (3 hours)
S.SEASON_CLIP = 2.5    -- for the hour and weekday habits a far-off scan does count less
S.SEASON_HALFLIFE = 21 -- days after which a scan counts half for the patterns
S.HOUR_DOUBT = 3       -- an hour's effect counts as if this many scans said "no effect"
S.DAY_DOUBT = 4        -- the same for a weekday's effect, in days

local LNPHI = -log(S.PHI)

------------------------------------------------------------------------------
-- Patterns by hour of day and day of week
------------------------------------------------------------------------------
-- Which hour (0-23), weekday (0 = Sunday) and day number (0 = today,
-- -1 = yesterday) a moment falls on, by the player's clock.
local function Slot(season, epoch)
  local off = epoch - season.midnight
  local day = floor(off / 86400)
  return floor((off - day * 86400) / 3600), (season.wday + day) % 7, day
end

-- The effect of slot `key` out of `count`, its variance, and how many
-- slots away the nearest sampled one is (0 = this one; nil = none at all).
-- A slot nobody scanned is filled in from its sampled neighbours on both
-- sides (the clock and the week wrap around) and trusted less.
local function SlotEffect(eff, var, seen, count, key, spread)
  if (seen[key] or 0) > 0 then return eff[key], var[key], 0 end
  local left, right, dl, dr
  for d = 1, count - 1 do
    if not left and (seen[(key - d) % count] or 0) > 0 then left, dl = (key - d) % count, d end
    if not right and (seen[(key + d) % count] or 0) > 0 then right, dr = (key + d) % count, d end
  end
  if not left then return 0, spread, nil end
  local wl, wr = dr / (dl + dr), dl / (dl + dr)
  local near = min(dl, dr)
  return eff[left] * wl + eff[right] * wr,
    var[left] * wl + var[right] * wr + spread * min(1, near / (count / 4)), near
end

-- The combined hour and weekday effect at a moment: effect, variance.
function S.SeasonAt(season, epoch)
  if not season then return 0, 0 end
  local hour, dow = Slot(season, epoch)
  local e1, v1 = SlotEffect(season.h, season.hv, season.hn, 24, hour, season.spread)
  local e2, v2 = SlotEffect(season.d, season.dv, season.dn, 7, dow, season.spread)
  return e1 + e2, v1 + v2
end

-- points: {epoch, price}; x: their logs. Returns the season table:
--   h, hv, hn   effect, variance and days seen for each hour 0-23
--   d, dv, dn   the same for each weekday 0-6
local function FitSeason(points, x, now)
  local n = #points
  local today = date("*t", now)
  local season = {
    midnight = now - today.hour * 3600 - today.min * 60 - today.sec,
    wday = today.wday - 1,
    h = {}, hv = {}, hn = {}, d = {}, dv = {}, dn = {},
    spread = 0.03 * 0.03,
  }
  for k = 0, 23 do season.h[k], season.hv[k], season.hn[k] = 0, 0, 0 end
  for k = 0, 6 do season.d[k], season.dv[k], season.dn[k] = 0, 0, 0 end
  if n < 3 then return season end

  local decay = log(2) / (S.SEASON_HALFLIFE * 86400)
  local hour, day, frac, w, rw = {}, {}, {}, {}, {}
  local firstDay, lastDay = math.huge, -math.huge
  for i = 1, n do
    local hr, _, dy = Slot(season, points[i][1])
    hour[i], day[i] = hr, dy
    frac[i] = (points[i][1] - season.midnight) / 86400 - dy - 0.5
    w[i] = exp(-(now - points[i][1]) * decay)
    rw[i] = 1
    firstDay, lastDay = min(firstDay, dy), max(lastDay, dy)
  end

  -- Hours. Each day has its own level b and its own drift across the day;
  -- an hour's effect is what is left, averaged over the days that hour was
  -- scanned on. Only a day scanned at two or more different hours can say
  -- anything about hours.
  local b, bw, tilt, hoursSeen = {}, {}, {}, {}
  do
    local mark = {}
    for i = 1, n do
      local key = day[i] * 24 + hour[i]
      if not mark[key] then
        mark[key] = true
        hoursSeen[day[i]] = (hoursSeen[day[i]] or 0) + 1
      end
    end
  end
  local h = season.h
  local hs, hw = {}, {}
  local resVar = S.TAU * S.TAU
  for iter = 1, 6 do
    for dy = firstDay, lastDay do b[dy], bw[dy] = 0, 0 end
    for i = 1, n do
      local dy = day[i]
      local wi = w[i] * rw[i]
      b[dy] = b[dy] + wi * (x[i] - h[hour[i]] - (tilt[dy] or 0) * frac[i])
      bw[dy] = bw[dy] + wi
    end
    for dy = firstDay, lastDay do
      if bw[dy] > 0 then b[dy] = b[dy] / bw[dy] else b[dy] = nil end
    end
    -- How fast the level moves across each day, from the days around it.
    for dy = firstDay, lastDay do
      local prev, nxt = b[dy - 1], b[dy + 1]
      local slope = 0
      if b[dy] then
        if prev and nxt then slope = (nxt - prev) / 2
        elseif nxt then slope = nxt - b[dy]
        elseif prev then slope = b[dy] - prev end
      end
      tilt[dy] = max(-0.3, min(0.3, slope))
    end
    for k = 0, 23 do hs[k], hw[k] = 0, 0 end
    local sumRes, sumW = 0, 0
    for i = 1, n do
      local dy = day[i]
      if hoursSeen[dy] >= 2 then
        local wi = w[i] * rw[i]
        local res = x[i] - b[dy] - tilt[dy] * frac[i]
        hs[hour[i]] = hs[hour[i]] + wi * res
        hw[hour[i]] = hw[hour[i]] + wi
        local left = res - h[hour[i]]
        sumRes, sumW = sumRes + wi * left * left, sumW + wi
      end
    end
    local mean, meanW = 0, 0
    for k = 0, 23 do
      h[k] = hs[k] / (hw[k] + S.HOUR_DOUBT)
      mean, meanW = mean + h[k] * hw[k], meanW + hw[k]
    end
    if meanW > 0 then
      mean = mean / meanW
      for k = 0, 23 do if hw[k] > 0 then h[k] = h[k] - mean end end
    end
    if sumW > 0 then resVar = max(0.02 * 0.02, sumRes / sumW) end
    -- A scan far from its day and hour counts for less next time round.
    local limit = S.SEASON_CLIP * sqrt(resVar)
    for i = 1, n do
      local dy = day[i]
      local left = abs(x[i] - b[dy] - tilt[dy] * frac[i] - h[hour[i]])
      rw[i] = left > limit and limit / left or 1
    end
  end
  do
    local mark = {}
    for i = 1, n do
      local dy = day[i]
      if hoursSeen[dy] >= 2 then
        local key = dy * 24 + hour[i]
        if not mark[key] then
          mark[key] = true
          season.hn[hour[i]] = season.hn[hour[i]] + 1
        end
      end
    end
    for k = 0, 23 do
      season.hv[k] = resVar / (hw[k] + S.HOUR_DOUBT)
      if season.hn[k] == 0 then h[k] = 0 end
    end
  end

  -- Weekdays. Each day's level is set against a straight line through the
  -- week around it (three days either side), so a market that is rising or
  -- falling does not pass for a weekday habit.
  local d = season.d
  local dayW = {}
  for dy = firstDay, lastDay do
    if b[dy] then dayW[dy] = min(1, bw[dy]) * exp(dy * 86400 * decay) end
  end
  local ds, dwt, dayVar = {}, {}, S.TAU * S.TAU
  for iter = 1, 3 do
    for k = 0, 6 do ds[k], dwt[k] = 0, 0 end
    local sumRes, sumW = 0, 0
    for dy = firstDay, lastDay do
      if b[dy] then
        local sw, sx, sy, sxx, sxy, count, before, after = 0, 0, 0, 0, 0, 0, 0, 0
        for other = dy - 3, dy + 3 do
          if b[other] then
            local wo = dayW[other]
            local y = b[other] - d[(season.wday + other) % 7]
            local xo = other - dy
            sw, sx, sy, sxx, sxy = sw + wo, sx + wo * xo, sy + wo * y, sxx + wo * xo * xo, sxy + wo * xo * y
            count = count + 1
            if other < dy then before = before + 1 elseif other > dy then after = after + 1 end
          end
        end
        local denom = sw * sxx - sx * sx
        if count >= 5 and before >= 1 and after >= 1 and denom > 1e-9 then
          local slope = (sw * sxy - sx * sy) / denom
          local line = (sy - slope * sx) / sw          -- the line's value at this day
          local dow = (season.wday + dy) % 7
          local res = b[dy] - line
          ds[dow] = ds[dow] + dayW[dy] * res
          dwt[dow] = dwt[dow] + dayW[dy]
          local left = res - d[dow]
          sumRes, sumW = sumRes + dayW[dy] * left * left, sumW + dayW[dy]
          if iter == 3 then season.dn[dow] = season.dn[dow] + 1 end
        end
      end
    end
    local mean, meanW = 0, 0
    for k = 0, 6 do
      d[k] = ds[k] / (dwt[k] + S.DAY_DOUBT)
      mean, meanW = mean + d[k] * dwt[k], meanW + dwt[k]
    end
    if meanW > 0 then
      mean = mean / meanW
      for k = 0, 6 do if dwt[k] > 0 then d[k] = d[k] - mean end end
    end
    if sumW > 0 then dayVar = max(0.02 * 0.02, sumRes / sumW) end
  end
  for k = 0, 6 do
    season.dv[k] = dayVar / (dwt[k] + S.DAY_DOUBT)
    if season.dn[k] == 0 then d[k] = 0 end
  end
  return season
end

------------------------------------------------------------------------------
-- Level and trend
------------------------------------------------------------------------------
-- How far a trend of 1 a day carries the level in `dt` days, and what is
-- left of the trend afterwards.
local function Carry(dt)
  if dt <= 0 then return 0, 1 end
  local a = exp(-LNPHI * dt)
  return (1 - a) / LNPHI, a
end

-- points: array of {time in seconds, price}, sorted by time.
-- Times in the model are days relative to `now`.
-- season: hour and weekday effects worked out earlier, to save the work.
function S.Fit(points, now, season)
  local n = #points
  if n == 0 then return nil end
  local t, x = {}, {}
  for i = 1, n do
    t[i] = (points[i][1] - now) / 86400
    x[i] = log(points[i][2])
  end
  season = season or FitSeason(points, x, now)
  -- What is left once the hour and weekday effects are taken out.
  local y = {}
  for i = 1, n do
    y[i] = x[i] - (S.SeasonAt(season, points[i][1]))
  end

  -- How much the level wanders in a day. Scan-to-scan moves are no guide:
  -- most are zero and a few are huge (a stray listing), so their average
  -- says more about strays than about the market. Instead take moves over
  -- about a day and use their middle value, which a few strays cannot shift.
  local tau2 = S.TAU * S.TAU
  local moves, j = {}, 1
  for i = 1, n do
    if j < i then j = i end
    while j < n and t[j] - t[i] < 0.75 do j = j + 1 end
    local dt = t[j] - t[i]
    if dt >= 0.75 and dt <= 3 then
      moves[#moves + 1] = abs(y[j] - y[i]) / sqrt(dt)
    end
  end
  local span = t[n] - t[1]
  local s2 = S.SIGMA0 * S.SIGMA0
  if #moves >= 3 then
    table.sort(moves)
    local mid = moves[floor((#moves + 1) / 2)] * 1.4826      -- middle value to sd
    local seen = max(mid * mid - 2 * tau2, 0)
    s2 = (s2 * S.PRIOR_DAYS + seen * span) / (S.PRIOR_DAYS + span)
  end
  s2 = max(0.02 * 0.02, min(0.6 * 0.6, s2))
  local slopeVar = S.SLOPE0 * S.SLOPE0

  -- Forward filter. State: level m, trend b; covariance p11, p12, p22.
  -- F* are the filtered values, Q* the predicted ones (kept for the smoother).
  local Fm, Fb, F11, F12, F22 = {}, {}, {}, {}, {}
  local Qm, Qb, Q11, Q12, Q22, G, A = {}, {}, {}, {}, {}, {}, {}
  local m, b, p11, p12, p22 = y[1], 0, tau2, 0, slopeVar
  Fm[1], Fb[1], F11[1], F12[1], F22[1] = m, b, p11, p12, p22
  local streakSign, streakStart, streakCount = 0, 0, 0
  for i = 2, n do
    local dt = max(t[i] - t[i - 1], 0)
    local g, a = Carry(dt)
    local qm, qb = m + g * b, a * b
    local q11 = p11 + 2 * g * p12 + g * g * p22 + s2 * dt
    local q12 = a * (p12 + g * p22)
    local q22 = a * a * p22 + slopeVar * (1 - a * a)
    Qm[i], Qb[i], Q11[i], Q12[i], Q22[i], G[i], A[i] = qm, qb, q11, q12, q22, g, a

    local v = y[i] - qm
    local sv = q11 + tau2
    local z = v / sqrt(sv)
    local trust = 1
    if abs(z) > S.CLIP then
      local sign = v > 0 and 1 or -1
      if sign ~= streakSign then
        streakSign, streakStart, streakCount = sign, t[i], 0
      end
      streakCount = streakCount + 1
      if streakCount >= 2 and t[i] - streakStart >= S.SHIFT_DAYS then
        -- The jump has lasted: it is the new level, not a stray scan.
        q11 = q11 + v * v
        sv = q11 + tau2
        streakSign, streakCount = 0, 0
      else
        trust = S.CLIP / abs(z)
      end
    else
      streakSign, streakCount = 0, 0
    end
    local k1, k2 = q11 / sv, q12 / sv
    m, b = qm + trust * k1 * v, qb + trust * k2 * v
    p11, p12, p22 = q11 - trust * k1 * q11, q12 - trust * k1 * q12, q22 - trust * k2 * q12
    Fm[i], Fb[i], F11[i], F12[i], F22[i] = m, b, p11, p12, p22
  end

  -- Backward smoother (Rauch-Tung-Striebel) for the two-part state.
  local M, B, P = {}, {}, {}
  M[n], B[n], P[n] = Fm[n], Fb[n], F11[n]
  local s11, s12, s22 = F11[n], F12[n], F22[n]
  local sm, sb = Fm[n], Fb[n]
  for i = n - 1, 1, -1 do
    local g, a = G[i + 1], A[i + 1]
    local q11, q12, q22 = Q11[i + 1], Q12[i + 1], Q22[i + 1]
    local det = q11 * q22 - q12 * q12
    if det > 1e-18 then
      -- C = F * transition' * inverse(predicted)
      local f11, f12, f22 = F11[i], F12[i], F22[i]
      local c11r, c12r = f11 + g * f12, a * f12          -- F * transition', row 1
      local c21r, c22r = f12 + g * f22, a * f22          -- row 2
      local i11, i12, i22 = q22 / det, -q12 / det, q11 / det
      local c11, c12 = c11r * i11 + c12r * i12, c11r * i12 + c12r * i22
      local c21, c22 = c21r * i11 + c22r * i12, c21r * i12 + c22r * i22
      local dm, db = sm - Qm[i + 1], sb - Qb[i + 1]
      sm, sb = Fm[i] + c11 * dm + c12 * db, Fb[i] + c21 * dm + c22 * db
      local d11, d12, d22 = s11 - q11, s12 - q12, s22 - q22
      -- F + C * D * C'
      local e11, e12 = c11 * d11 + c12 * d12, c11 * d12 + c12 * d22
      local e21, e22 = c21 * d11 + c22 * d12, c21 * d12 + c22 * d22
      s11 = f11 + e11 * c11 + e12 * c12
      s12 = f12 + e11 * c21 + e12 * c22
      s22 = f22 + e21 * c21 + e22 * c22
      if s11 < 1e-9 then s11 = 1e-9 end
      if s22 < 1e-9 then s22 = 1e-9 end
    else
      sm, sb, s11, s12, s22 = Fm[i], Fb[i], F11[i], F12[i], F22[i]
    end
    M[i], B[i], P[i] = sm, sb, s11
  end

  return {
    t = t, m = M, P = P, s2 = s2, n = n, now = now, few = S.FEW_SD * S.FEW_SD / n,
    slope = Fb[n], slopeVar = F22[n], cross = F12[n], season = season,
  }
end

-- Estimate at a time given in days relative to the model's `now`.
-- Returns the mean and standard deviation in log space. With `level` set
-- the hour and weekday effects are left out: the underlying market level.
function S.Eval(model, day, level)
  local t, m, P, s2, n = model.t, model.m, model.P, model.s2, model.n
  local few = model.few or 0
  local mean, var
  if day <= t[1] then
    mean, var = m[1], P[1] + s2 * (t[1] - day)
  elseif day >= t[n] then
    -- Ahead of the last scan the trend carries on, fading as it goes.
    local dt = day - t[n]
    local g = Carry(dt)
    local slope, slopeVar, cross = model.slope or 0, model.slopeVar or 0, model.cross or 0
    mean = m[n] + g * slope
    var = P[n] + 2 * g * cross + g * g * slopeVar + s2 * dt
  else
    local lo, hi = 1, n
    while hi - lo > 1 do
      local mid = floor((lo + hi) / 2)
      if t[mid] <= day then lo = mid else hi = mid end
    end
    local span = t[hi] - t[lo]
    if span <= 0 then
      mean, var = m[hi], P[hi]
    else
      local a = (day - t[lo]) / span
      mean = m[lo] + a * (m[hi] - m[lo])
      var = (1 - a) * P[lo] + a * P[hi] + s2 * span * a * (1 - a)
    end
  end
  if not level and model.season then
    local e, v = S.SeasonAt(model.season, model.now + day * 86400)
    mean, var = mean + e, var + v
  end
  return mean, sqrt(max(var, 0) + few)
end

------------------------------------------------------------------------------
-- Per-item cache
------------------------------------------------------------------------------
local cache, cacheGen = {}, -1
-- The hour and weekday effects change slowly, so they are worked out again
-- only every couple of hours or after a batch of new scans.
local seasons = {}

function S.ForItem(id)
  if cacheGen ~= ns.generation then
    cache, cacheGen = {}, ns.generation
  end
  local entry = cache[id]
  if entry == nil then
    local series = ns.Market.Series(id)
    local now = time()
    local kept = seasons[id]
    if kept and (now - kept.at > 7200 or #series - kept.n > 12 or #series < kept.n) then kept = nil end
    local model = S.Fit(series, now, kept and kept.season)
    if model and not kept then seasons[id] = { at = now, n = #series, season = model.season } end
    entry = { series = series, model = model or false, now = now }
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
      -- The hour and weekday habits are taken out first, so that scanning
      -- at a dear hour today does not pass for a rise.
      local y = log(series[i][2]) - (S.SeasonAt(entry.model.season, series[i][1]))
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

-- Everything needed to estimate an item's price at a given time of the
-- week: its level now, its trend, and its hour and weekday habits.
-- Returns nil when the item has no price yet.
--   base            today's underlying level (habits taken out)
--   hours, days     for drawing: slots[key] = { n = days it was seen on,
--                   price = effect as a fraction, listed = average units }
--   slope           trend per day (fraction), slopeSd its uncertainty
function S.Week(id)
  local entry = S.ForItem(id)
  local model = entry.model
  if not model then return nil end
  local level, sd0 = S.Eval(model, 0, true)
  local season = model.season
  local hourTally, hourOnline = ns.Market.Tally(id, "hd")
  local dayTally, dayOnline = ns.Market.Tally(id, "wd")
  local hourListed, dayListed = S.Pattern(hourTally, 24), S.Pattern(dayTally, 7)
  local function Slots(eff, seen, count, listed)
    local out = { slots = {}, filled = 0, scans = model.n }
    for key = 0, count - 1 do
      if (seen[key] or 0) > 0 then
        local l = listed.slots[key]
        out.slots[key] = { n = seen[key], price = exp(eff[key]) - 1, listed = l and l.listed or 0 }
        out.filled = out.filled + 1
      end
    end
    return out
  end
  local w = {
    id = id, model = model, season = season,
    base = exp(level), sd0 = sd0, s2 = model.s2,
    hours = Slots(season.h, season.hn, 24, hourListed),
    days = Slots(season.d, season.dn, 7, dayListed),
    hourListed = hourListed, dayListed = dayListed,
    slope = exp(model.slope or 0) - 1, slopeSd = sqrt(model.slopeVar or 0),
    online = (hourOnline or dayOnline) and true or false,
  }
  local sum, n = 0, 0
  for _, sl in pairs(dayListed.slots) do sum, n = sum + sl.listed, n + 1 end
  w.meanListed = n > 0 and sum / n or nil
  return w
end

-- Units usually listed at a slot, filled in from its neighbours if need be.
local function ListedAt(pattern, count, key)
  if pattern.filled == 0 then return nil end
  if pattern.slots[key] then return pattern.slots[key].listed end
  for d = 1, count - 1 do
    local l, r = pattern.slots[(key - d) % count], pattern.slots[(key + d) % count]
    if l and r then return (l.listed + r.listed) / 2 end
    if l or r then return (l or r).listed end
  end
end

-- The estimated price at one time of the week, at today's level. day:
-- 0 = Sunday ... 6, or nil for "any day". hour: 0 to 23, or nil for "the
-- whole day". The hour and the weekday are taken to act independently:
-- Monday's effect and the afternoon's effect are added. Returns
--   price, lo, hi   best estimate and the range it is likely within (about
--                   two times in three)
--   rel             the estimate relative to today's level (fraction)
--   hourN, dayN     days on which that hour, and weeks in which that
--                   weekday, were seen
--   hourGap, dayGap slots to the nearest real sample (0 = sampled here,
--                   nil = no pattern for it at all)
--   listed          expected units listed, or nil
--   next            when both are given: the next time that slot comes
--                   round, with the trend carried forward:
--                   { days, price, lo, hi }
function S.WeekAt(w, day, hour)
  local season = w.season
  local effect, var = 0, w.sd0 * w.sd0 + w.s2
  local out = {}
  local hourListed, dayListed
  if hour then
    local e, v, gap = SlotEffect(season.h, season.hv, season.hn, 24, hour, season.spread)
    effect, var = effect + e, var + v
    out.hourN, out.hourGap = season.hn[hour] or 0, gap
    hourListed = ListedAt(w.hourListed, 24, hour)
  end
  if day then
    local e, v, gap = SlotEffect(season.d, season.dv, season.dn, 7, day, season.spread)
    effect, var = effect + e, var + v
    out.dayN, out.dayGap = season.dn[day] or 0, gap
    dayListed = ListedAt(w.dayListed, 7, day)
  end
  local sd = sqrt(var)
  out.rel = exp(effect) - 1
  out.price = w.base * exp(effect)
  out.lo, out.hi = out.price * exp(-sd), out.price * exp(sd)
  if hourListed and dayListed and w.meanListed and w.meanListed > 0 then
    out.listed = hourListed * dayListed / w.meanListed
  else
    out.listed = hourListed or dayListed
  end
  if day and hour then
    -- Hours until that weekday and hour next start, by the player's clock.
    local nowHour, nowDow = Slot(season, w.model.now)
    local ahead = ((day - nowDow) % 7) * 24 + (hour - nowHour)
    if ahead <= 0 then ahead = ahead + 168 end
    local days = (season.midnight + (floor((w.model.now - season.midnight) / 3600) + ahead) * 3600 + 1800
      - w.model.now) / 86400
    local mean, sdNext = S.Eval(w.model, days)
    local price = exp(mean)
    out.next = { days = days, price = price, lo = price * exp(-sdNext), hi = price * exp(sdNext) }
  end
  return out
end

-- The forecast for a moment `days` from now: price, lo, hi (the range it is
-- likely within about two times in three), or nil without a price.
function S.Forecast(id, days)
  local entry = S.ForItem(id)
  if not entry.model then return nil end
  local mean, sd = S.Eval(entry.model, days)
  local price = exp(mean)
  return price, price * exp(-sd), price * exp(sd), sd
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
