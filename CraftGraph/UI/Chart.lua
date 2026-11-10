-- CraftGraph price chart: price over time with the certainty of the
-- estimate drawn as a glow seen from above. Where we have observations the
-- glow is tight and bright; in gaps and into the future it spreads and fades.
local ADDON, ns = ...
local C = {}
ns.Chart = C

local exp, max, min, floor = math.exp, math.max, math.min, math.floor

local COLS = 64
-- Band edges in standard deviations; the glow follows a bell curve.
local EDGES = { -2.6, -1.8, -1.2, -0.6, 0, 0.6, 1.2, 1.8, 2.6 }
local SEGS = #EDGES - 1

-- Height of the row of sun and moon icons between the plot and its labels.
local CLOCK_ROW = 16
-- The minimap's day and night indicator: sun in the left half, moon in the right.
local CLOCK_TEXTURE = "Interface\\Minimap\\UI-TOD-Indicator"
-- The game's own dawn and dusk (05:30 and 21:00), to the nearest hour.
local DAWN, DUSK = 6, 21
local CLOCK_STEPS = { 1, 2, 3, 6, 12, 24, 48, 96, 168, 336, 720 }

local function Bell(k)
  return exp(-k * k / 2)
end

local function Acquire(pool, index, make)
  local obj = pool[index]
  if not obj then
    obj = make()
    pool[index] = obj
  end
  return obj
end

local function HideFrom(pool, index)
  for i = index, #pool do pool[i]:Hide() end
end

function C.Create(parent)
  local f = CreateFrame("Frame", nil, parent)
  local plot = CreateFrame("Frame", nil, f)
  plot:SetPoint("TOPLEFT", 2, -2)
  plot:SetPoint("BOTTOMRIGHT", -2, CLOCK_ROW + 14)
  plot:SetClipsChildren(true)
  f.plot = plot

  local bg = plot:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.45)

  f.bands, f.lines, f.dots = {}, {}, {}
  f.nights, f.clocks, f.clockLabels = {}, {}, {}

  local function Label(point, x, y, font)
    local fs = plot:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint(point, x, y)
    return fs
  end
  f.yTop = Label("TOPLEFT", 4, -3)
  f.yBottom = Label("BOTTOMLEFT", 4, 3)
  f.refLabel = Label("TOPRIGHT", -4, -3, "GameFontNormalSmall")
  f.vendorLabel = Label("BOTTOMRIGHT", -4, 3, "GameFontDisableSmall")

  f.xLeft = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.xLeft:SetPoint("BOTTOMLEFT", 2, 0)
  f.xNow = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.xNow:SetText("now")
  f.xRight = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.xRight:SetPoint("BOTTOMRIGHT", -2, 0)
  f.xRight:SetText("forecast")

  f.note = plot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.note:SetPoint("TOP", 0, -18)

  f.empty = plot:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.empty:SetPoint("CENTER")
  f.empty:SetWidth(240)
  f.empty:SetText("No price history yet.\nScan this item at the auction house.")

  f.Update = C.Update
  return f
end

local function MakeBand(plot)
  return function()
    local t = plot:CreateTexture(nil, "BORDER")
    t:SetColorTexture(1, 1, 1, 1)
    return t
  end
end

local function MakeNight(plot)
  return function()
    local t = plot:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetColorTexture(0.10, 0.16, 0.50, 0.20)
    return t
  end
end

local function MakeClock(f)
  return function()
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetTexture(CLOCK_TEXTURE)
    t:SetSize(CLOCK_ROW, CLOCK_ROW)
    return t
  end
end

local function MakeClockLabel(f)
  return function()
    return f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  end
end

local function HourOf(epoch)
  return tonumber(date("%H", epoch)) or 0
end

-- The first moment at or after `from` that falls on a whole hour for which
-- want(hour) holds, by the player's clock.
local function NextHour(from, want)
  local e = from - (tonumber(date("%M", from)) or 0) * 60 - (tonumber(date("%S", from)) or 0)
  if e < from then e = e + 3600 end
  for _ = 1, 48 do
    if want(HourOf(e)) then return e end
    e = e + 3600
  end
  return e
end

-- Shades the nights behind the plot and lays a row of sun and moon icons
-- under it, so it is plain what time of day each scan was taken.
-- startAt/endAt are the chart's edges as clock times; W is its width.
function C.DrawClock(f, startAt, endAt, W, H)
  local plot = f.plot
  local nNight, nClock, nLabel = 0, 0, 0
  local perHour = W / max((endAt - startAt) / 3600, 0.01)
  local function X(epoch) return (epoch - startAt) / (endAt - startAt) * W end

  -- Nights, where a night is wide enough to see.
  if perHour * (24 - DUSK + DAWN) >= 3 then
    local dusk = NextHour(startAt - 86400, function(h) return h == DUSK end)
    while dusk < endAt do
      local x1 = max(0, X(dusk))
      local x2 = min(W, X(dusk + (24 - DUSK + DAWN) * 3600))
      if x2 - x1 >= 1 then
        nNight = nNight + 1
        local tex = Acquire(f.nights, nNight, MakeNight(plot))
        tex:ClearAllPoints()
        tex:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x1, 0)
        tex:SetSize(x2 - x1, H)
        tex:Show()
      end
      dusk = dusk + 86400
    end
  end

  -- Icons: as close together as still reads, on round hours.
  local step = CLOCK_STEPS[#CLOCK_STEPS]
  for _, hours in ipairs(CLOCK_STEPS) do
    -- Hour icons carry a number beside them and need the room; day icons do not.
    if hours * perHour >= (hours < 24 and 34 or 18) then step = hours break end
  end
  local spacing = step * perHour
  local at
  if step < 24 then
    at = NextHour(startAt, function(h) return h % step == 0 end)
  else
    at = NextHour(startAt, function(h) return h == 12 end)
  end
  local guard = 0
  while at <= endAt and guard < 200 do
    guard = guard + 1
    local x, hour = X(at), HourOf(at)
    if x >= CLOCK_ROW / 2 and x <= W - CLOCK_ROW / 2 then
      nClock = nClock + 1
      local icon = Acquire(f.clocks, nClock, MakeClock(f))
      if hour >= DAWN and hour < DUSK then
        icon:SetTexCoord(0, 0.5, 0, 1)
      else
        icon:SetTexCoord(0.5, 1, 0, 1)
      end
      icon:ClearAllPoints()
      icon:SetPoint("CENTER", f, "BOTTOMLEFT", 2 + x, 14 + CLOCK_ROW / 2)
      icon:Show()
      -- The hour beside the icon, or the weekday when icons are a day apart.
      local text
      if step < 24 then
        text = tostring(hour)
      elseif step == 24 and spacing >= 46 then
        text = date("%a", at)
      end
      if text and x + CLOCK_ROW / 2 + 22 <= W then
        nLabel = nLabel + 1
        local label = Acquire(f.clockLabels, nLabel, MakeClockLabel(f))
        label:ClearAllPoints()
        label:SetPoint("LEFT", icon, "RIGHT", 0, 0)
        label:SetText(text)
        label:Show()
      end
    end
    at = at + step * 3600
  end

  HideFrom(f.nights, nNight + 1)
  HideFrom(f.clocks, nClock + 1)
  HideFrom(f.clockLabels, nLabel + 1)
  return nClock, nNight, step
end

local function MakeLine(plot)
  return function()
    return plot:CreateLine(nil, "ARTWORK")
  end
end

local function MakeDot(plot)
  return function()
    local t = plot:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(1, 1, 1, 0.95)
    t:SetSize(4, 4)
    t:SetRotation(math.rad(45))
    return t
  end
end

-- opts.days: how far back to look (nil or 0 = everything).
-- opts.band: draw the certainty glow. opts.craft: cost to make one (drawn
-- as a reference line). opts.vendor: vendor price reference.
function C.Update(f, id, opts)
  opts = opts or {}
  local plot = f.plot
  local W, H = plot:GetWidth(), plot:GetHeight()
  local entry = id and ns.Stats.ForItem(id)
  local model = entry and entry.model
  local nBand, nLine, nDot = 0, 0, 0

  local function Finish()
    HideFrom(f.bands, nBand + 1)
    HideFrom(f.lines, nLine + 1)
    HideFrom(f.dots, nDot + 1)
  end

  if not model or not W or W < 10 or H < 10 then
    f.empty:SetShown(not model)
    f.yTop:SetText("")
    f.yBottom:SetText("")
    f.refLabel:SetText("")
    f.vendorLabel:SetText("")
    f.xLeft:SetText("")
    f.note:SetText("")
    f.xNow:Hide()
    f.xRight:Hide()
    HideFrom(f.nights, 1)
    HideFrom(f.clocks, 1)
    HideFrom(f.clockLabels, 1)
    Finish()
    return
  end
  f.empty:Hide()

  local series = entry.series
  local firstDay = (series[1][1] - entry.now) / 86400
  local limit = (opts.days and opts.days > 0) and opts.days or math.huge
  -- The chart starts at the first scan: before it we know nothing. With
  -- little history the window is filled out with forecast instead.
  local past = min(limit, -firstDay)
  local span = max(past * 1.04, 0.08)
  local fwd = max(0.25, span * 0.2, 1 - span)
  local t0, t1 = -span, fwd
  local known = max(t0, firstDay)
  local function X(day) return (day - t0) / (t1 - t0) * W end

  C.DrawClock(f, entry.now + t0 * 86400, entry.now + t1 * 86400, W, H)

  -- Sample the model once per column. The hour-of-day habits are drawn
  -- only when a column is narrow enough to show them (under three hours);
  -- on longer ranges the line is the underlying level and its trend.
  local levelOnly = (t1 - t0) / COLS > 0.125
  local means, sds = {}, {}
  local lo, hi = math.huge, 0
  for c = 1, COLS do
    local day = t0 + (c - 0.5) / COLS * (t1 - t0)
    local m, s = ns.Stats.Eval(model, day, levelOnly)
    means[c], sds[c] = m, s
    lo = min(lo, exp(m - 1.2 * s))
    hi = max(hi, exp(m + 1.2 * s))
  end
  for i = 1, #series do
    local day = (series[i][1] - entry.now) / 86400
    if day >= t0 then
      lo = min(lo, series[i][2])
      hi = max(hi, series[i][2])
    end
  end
  -- The cost to make one is drawn as a line when it is near the prices;
  -- when it is far off it is only named, so it does not squash the chart.
  local craft, craftFar = opts.craft, nil
  if craft and craft > lo * 0.55 and craft < hi * 1.6 then
    lo = min(lo, craft)
    hi = max(hi, craft)
  elseif craft then
    craftFar = craft < lo and "below" or "above"
    craft = nil
  end
  local range = max(hi - lo, hi * 0.06)
  lo = max(0, lo - range * 0.10)
  hi = hi + range * 0.10
  local function Y(price) return (price - lo) / (hi - lo) * H end
  local function Clamp(y) return max(0, min(H, y)) end

  -- Certainty glow
  local colW = W / COLS
  if opts.band then
    for c = 1, COLS do
      local m, s = means[c], sds[c]
      local day = t0 + (c - 0.5) / COLS * (t1 - t0)
      local strength = max(0.10, min(0.80, 0.045 / s))
      local r, g, b = 1.0, 0.78, 0.10
      if day > 0 then r, g, b = 0.55, 0.75, 1.0 end
      if day + (t1 - t0) / COLS < known then strength = 0 end
      for j = 1, SEGS do
        local ya = Clamp(Y(exp(m + EDGES[j] * s)))
        local yb = Clamp(Y(exp(m + EDGES[j + 1] * s)))
        if yb - ya >= 0.5 and strength > 0 then
          nBand = nBand + 1
          local tex = Acquire(f.bands, nBand, MakeBand(plot))
          tex:ClearAllPoints()
          tex:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (c - 1) * colW, ya)
          tex:SetSize(colW + 0.5, yb - ya)
          tex:SetGradient("VERTICAL",
            CreateColor(r, g, b, strength * Bell(EDGES[j])),
            CreateColor(r, g, b, strength * Bell(EDGES[j + 1])))
          tex:Show()
        end
      end
    end
  end

  local function Line(x1, y1, x2, y2, r, g, b, a, thickness)
    nLine = nLine + 1
    local line = Acquire(f.lines, nLine, MakeLine(plot))
    line:SetColorTexture(r, g, b, a)
    line:SetThickness(thickness or 1)
    line:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
    line:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
    line:Show()
  end

  -- Reference lines: cost to make one, and what a vendor pays.
  f.refLabel:SetText("")
  f.vendorLabel:SetText("")
  if craft then
    local y = Y(craft)
    local nowPrice = exp(ns.Stats.Eval(model, 0))
    local good = craft < nowPrice
    local r, g, b = 0.35, 1, 0.35
    if not good then r, g, b = 1, 0.35, 0.3 end
    Line(0, y, W, y, r, g, b, 0.7, 1)
    f.refLabel:SetText("make " .. ns.Money(craft))
    f.refLabel:SetTextColor(r, g, b)
  elseif craftFar then
    f.refLabel:SetText("make " .. ns.Money(opts.craft) .. " (" .. craftFar .. " the chart)")
    if craftFar == "below" then
      f.refLabel:SetTextColor(0.35, 1, 0.35)
    else
      f.refLabel:SetTextColor(1, 0.35, 0.3)
    end
  end
  local vendor = opts.vendor
  if vendor and vendor > lo and vendor < hi then
    local y = Y(vendor)
    Line(0, y, W, y, 0.6, 0.6, 0.6, 0.5, 1)
    f.vendorLabel:SetText("vendor " .. ns.Money(vendor))
  end

  -- "Now" marker and the best-estimate line
  local xNow = X(0)
  Line(xNow, 0, xNow, H, 1, 1, 1, 0.25, 1)
  local px, py
  for c = 1, COLS do
    local x = (c - 0.5) * colW
    local y = Clamp(Y(exp(means[c])))
    local day = t0 + (c - 0.5) / COLS * (t1 - t0)
    if day < known then
      px, py = nil, nil
    else
      if px then
        -- The surer the estimate, the bolder the line; a guess is a faint thread.
        local sure = max(0.18, min(1, 0.07 / sds[c]))
        local future = x > xNow
        Line(px, py, x, y, 1, future and 0.9 or 0.82, future and 0.7 or 0,
          (future and 0.7 or 1) * sure, 0.9 + 0.9 * sure)
      end
      px, py = x, y
    end
  end

  -- Observations
  for i = 1, #series do
    local day = (series[i][1] - entry.now) / 86400
    if day >= t0 then
      nDot = nDot + 1
      local dot = Acquire(f.dots, nDot, MakeDot(plot))
      local size = #series <= 3 and 7 or 4
      dot:SetSize(size, size)
      dot:ClearAllPoints()
      dot:SetPoint("CENTER", plot, "BOTTOMLEFT", X(day), Clamp(Y(series[i][2])))
      dot:Show()
    end
  end

  f.yTop:SetText(ns.Money(hi))
  f.yBottom:SetText(ns.Money(lo))
  f.xLeft:SetText(past < 0.02 and "" or ns.Age(past * 86400))
  local scans = #series
  if scans == 1 then
    f.note:SetText("1 scan so far: a first guess")
  elseif scans < 5 then
    f.note:SetText(scans .. " scans so far: still rough")
  else
    f.note:SetText("")
  end
  f.xNow:ClearAllPoints()
  f.xNow:SetPoint("BOTTOM", f, "BOTTOMLEFT", 2 + xNow, 0)
  f.xNow:Show()
  f.xRight:Hide()
  Finish()
end
