-- CraftGraph main window: search, the item graph, and a side panel with
-- prices, the price chart and the cheapest way to make a chosen quantity.
local ADDON, ns = ...
local UI = {}
ns.UI = UI

local max, min, floor = math.max, math.min, math.floor

local FRAME_W, FRAME_H, PANEL_W = 1180, 700, 350
local GREY = "|cff9d9d9d"
local GOLD = "|cffffd100"
local RESULT_ROWS = 12

local frame, view, chart, panel, search, results, qtyBox, statusText, scanButton, fullButton
local state = { center = nil, hist = {}, pos = 0, expandLeft = false, graph = nil, needs = nil, job = nil,
  use = nil, tempUse = {}, tempFor = nil }

------------------------------------------------------------------------------
-- Search
------------------------------------------------------------------------------
local index

local function BuildIndex()
  index = {}
  for id, d in pairs(ns.Data.items) do
    index[#index + 1] = { id = id, name = d[1], lower = d[1]:lower() }
  end
  table.sort(index, function(a, b)
    if #a.lower ~= #b.lower then return #a.lower < #b.lower end
    return a.lower < b.lower
  end)
end

function UI.Search(text, limit)
  if not index then BuildIndex() end
  text = text:lower()
  local starts, contains = {}, {}
  if text == "" then return starts end
  for _, e in ipairs(index) do
    local pos = e.lower:find(text, 1, true)
    if pos == 1 then
      starts[#starts + 1] = e
    elseif pos then
      contains[#contains + 1] = e
    end
    if #starts >= limit then break end
  end
  for _, e in ipairs(contains) do
    if #starts >= limit then break end
    starts[#starts + 1] = e
  end
  return starts
end

function UI.FindByName(text)
  local list = UI.Search(text, 1)
  return list[1] and list[1].id or nil
end

------------------------------------------------------------------------------
-- Small widget helpers
------------------------------------------------------------------------------
local function Button(parent, text, width)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  return b
end

local function Text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  ns.Watch(fs, "window")
  return fs
end

local function Tip(widget, title, body)
  widget:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(title)
    if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

------------------------------------------------------------------------------
-- Side panel
------------------------------------------------------------------------------
local rows = {}

local function CreatePanel(parent)
  local p = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
  p:SetPoint("TOPRIGHT", -8, -62)
  p:SetPoint("BOTTOMRIGHT", -8, 8)
  p:SetWidth(PANEL_W)

  p:EnableMouse(true)
  p:SetScript("OnMouseUp", function(_, button) UI.NavButton(button) end)

  p.icon = p:CreateTexture(nil, "ARTWORK")
  p.icon:SetSize(40, 40)
  p.icon:SetPoint("TOPLEFT", 12, -12)
  p.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  p.iconBorder = p:CreateTexture(nil, "OVERLAY")
  p.iconBorder:SetTexture("Interface\\Common\\WhiteIconFrame")
  p.iconBorder:SetAllPoints(p.icon)
  p.name = Text(p, "GameFontNormalLarge")
  p.name:SetPoint("TOPLEFT", p.icon, "TOPRIGHT", 10, -2)
  p.name:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -14)
  p.name:SetWordWrap(false)
  p.sub = Text(p, "GameFontHighlightSmall")
  p.sub:SetPoint("TOPLEFT", p.name, "BOTTOMLEFT", 0, -4)
  p.sub:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -34)
  p.sub:SetWordWrap(false)

  local y = -62
  local rowY = {}
  local function Row(key, label, font, height, rightInset)
    local l = Text(p, "GameFontNormalSmall")
    l:SetPoint("TOPLEFT", 14, y)
    l:SetText(label)
    local v = Text(p, font or "GameFontHighlightSmall", "RIGHT")
    v:SetPoint("TOPLEFT", l, "TOPRIGHT", 6, 0)
    v:SetPoint("TOPRIGHT", p, "TOPRIGHT", -(rightInset or 14), y)
    v:SetWordWrap(false)
    rows[key] = v
    rows[key .. "Label"] = l
    rowY[key] = y
    y = y - (height or 17)
  end
  local function Divider()
    local d = p:CreateTexture(nil, "ARTWORK")
    d:SetColorTexture(1, 0.82, 0, 0.25)
    d:SetHeight(1)
    d:SetPoint("TOPLEFT", 12, y - 3)
    d:SetPoint("TOPRIGHT", -12, y - 3)
    y = y - 10
  end

  Row("auction", "Auction price")
  Row("supply", "Supply and demand")
  Row("vendor", "Vendor")
  Divider()

  p.makeHeader = Text(p, "GameFontNormal")
  p.makeHeader:SetPoint("TOPLEFT", 14, y)
  p.pin = Button(p, "Add to plan", 104)
  p.pin:SetHeight(19)
  p.pin:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, y + 3)
  p.pin:SetScript("OnClick", function()
    local id = state.center
    if not id then return end
    if ns.Jobs.IsPinned(id) then ns.Jobs.Unpin(id) else UI.AddToPlan(id, ns.settings.qty or 1) end
  end)
  Tip(p.pin, "Your plan", "Adds this item, at this quantity, to your plan. The small plan window "
    .. "then shows its next step wherever you are: auction house, mailbox, bank, vendor, craft, post. "
    .. "If it is not expected to pay you are told first. Removing it also forgets its progress.")
  p.makeNow = Button(p, "Make", 84)
  p.makeNow:SetHeight(19)
  p.makeNow:SetPoint("RIGHT", p.pin, "LEFT", -4, 0)
  p.makeNow:Hide()
  p.makeNow:SetScript("OnClick", function(self)
    if self.spell and self.casts then ns.Safe(ns.Player.Craft, self.spell, self.casts) end
  end)
  Tip(p.makeNow, "Make from your bags",
    "Crafts this with the materials in your bags. Your profession window must be open: "
    .. "the first press opens it.")
  y = y - 20
  Row("cost", "Materials")
  Row("sale", "Sale")
  Row("profit", "Profit", "GameFontHighlightLarge", 24)
  Row("best", "Best quantity", nil, nil, 62)
  Row("time", "Time to sell")

  p.useBest = Button(p, "Use", 42)
  p.useBest:SetHeight(18)
  p.useBest:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, rowY.best + 4)
  p.useBest:SetScript("OnClick", function(self)
    if self.qty then UI.SetQuantity(self.qty) end
  end)
  Tip(p.useBest, "Use the best quantity",
    "The quantity with the highest profit that the listed materials allow, limited to what this "
    .. "market is seen to buy within " .. (ns.settings.horizonDays or 2)
    .. " days. Until the item has been scanned twice the demand is unknown: it is then limited to one stack "
    .. "and to no more than is listed now. A recipe with a cooldown counts once.")

  p.warn = Text(p, "GameFontNormalSmall")
  p.warn:SetPoint("TOPLEFT", 14, y)
  p.warn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, y)
  p.warn:SetTextColor(1, 0.55, 0.2)
  p.warn:SetWordWrap(true)
  p.warn:SetMaxLines(2)
  y = y - 28
  Divider()

  -- One box, two pictures: the price over time, or the price by time of week.
  local chartHeader = Button(p, "Price history", 112)
  chartHeader:SetHeight(18)
  chartHeader:SetPoint("TOPLEFT", 12, y + 3)
  chartHeader:SetScript("OnClick", function()
    local order = { history = "week", week = "day", day = "history" }
    ns.settings.sideChart = order[ns.settings.sideChart or "history"] or "history"
    UI.Refresh()
  end)
  Tip(chartHeader, "Price history, week pattern or day pattern",
    "Switches this box between three pictures: the price over time with its forecast; every scan "
    .. "folded onto one week, with the usual curve and the projection for the coming week; and the "
    .. "same folded onto one day. In the folded pictures, drag or scroll to pick a time, such as "
    .. "Monday afternoon, and read its price.")
  p.chartMode = chartHeader
  local RANGES = { 14, 90, 0 }
  local function RangeText()
    local d = ns.settings.chartDays or 14
    return d > 0 and (d .. " days") or "All"
  end
  p.range = Button(p, RangeText(), 66)
  p.range:SetHeight(18)
  p.range:SetPoint("LEFT", chartHeader, "RIGHT", 8, 0)
  p.range:SetScript("OnClick", function(self)
    local current, nextIndex = ns.settings.chartDays or 14, 1
    for i, d in ipairs(RANGES) do
      if d == current then nextIndex = i % #RANGES + 1 end
    end
    ns.settings.chartDays = RANGES[nextIndex]
    self:SetText(RangeText())
    UI.Refresh()
  end)
  Tip(p.range, "Chart range",
    "How far back the chart looks: 14 days, 90 days, or everything recorded for this item.")
  p.certainty = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
  p.certainty:SetSize(22, 22)
  p.certainty:SetPoint("TOPRIGHT", -84, y + 5)
  local label = Text(p, "GameFontHighlightSmall")
  label:SetPoint("LEFT", p.certainty, "RIGHT", 2, 0)
  label:SetText("Certainty")
  p.certaintyLabel = label
  p.certainty:SetScript("OnClick", function(self)
    ns.settings.certainty = self:GetChecked() and true or false
    UI.Refresh()
  end)
  Tip(p.certainty, "Certainty",
    "Shades the chart by how sure the price estimate is: tight and bright near real scans, "
    .. "wide and faint in gaps and in the forecast.")
  y = y - 20

  chart = ns.Chart.Create(p)
  chart:SetPoint("TOPLEFT", 12, y)
  chart:SetSize(PANEL_W - 24, 174)
  p.week = UI.CreateWeekStrip(p)
  p.week:SetPoint("TOPLEFT", 12, y)
  p.week:SetSize(PANEL_W - 24, 174)
  y = y - 180
  Divider()

  local planHeader = Text(p, "GameFontNormal")
  planHeader:SetPoint("TOPLEFT", 14, y)
  planHeader:SetText("Cheapest way")
  y = y - 18
  p.plan = Text(p, "GameFontHighlightSmall")
  p.plan:SetPoint("TOPLEFT", 14, y)
  p.plan:SetPoint("BOTTOMRIGHT", -12, 8)
  p.plan:SetJustifyV("TOP")
  p.plan:SetSpacing(3)
  p.plan:SetWordWrap(true)
  return p
end

local function ListItems(map, limit)
  local names = {}
  for id, n in pairs(map) do
    names[#names + 1] = ns.Round(n) .. " x " .. ns.ItemName(id)
  end
  table.sort(names)
  local extra = #names - limit
  while #names > limit do table.remove(names) end
  local text = table.concat(names, ", ")
  if extra > 0 then text = text .. " and " .. extra .. " more" end
  return text
end

local function PlanText(plan, graph)
  local lines = {}
  local buys = {}
  for id, n in pairs(plan.buy) do
    buys[#buys + 1] = { id = id, n = n, cost = plan.buyCost[id] or 0, where = "Auction" }
  end
  for id, n in pairs(plan.vend) do
    buys[#buys + 1] = { id = id, n = n, cost = plan.vendCost[id] or 0, where = "Vendor" }
  end
  table.sort(buys, function(a, b) return a.cost > b.cost end)
  for _, b in ipairs(buys) do
    local r, g, bl = ns.ItemColor(b.id)
    lines[#lines + 1] = string.format("%s%s:|r %d |cff%02x%02x%02x%s|r  %s",
      GREY, b.where, ns.Round(b.n), r * 255, g * 255, bl * 255, ns.ItemName(b.id), ns.Money(b.cost))
  end
  local crafts = {}
  for spell, n in pairs(plan.casts) do
    local r = ns.Opt.Recipe(spell)
    local node = graph and graph.byId[r[3]]
    crafts[#crafts + 1] = { name = r[6], n = n, layer = node and node.layer or 0 }
  end
  table.sort(crafts, function(a, b)
    if a.layer ~= b.layer then return a.layer > b.layer end
    return a.name < b.name
  end)
  for _, c in ipairs(crafts) do
    lines[#lines + 1] = "|cffffd100Craft:|r " .. c.name .. " x" .. ns.Round(c.n)
  end
  -- The space under the chart holds about nine lines, one of them "Next:".
  local limit = 8
  if #lines > limit then
    local extra = #lines - limit + 1
    while #lines > limit - 1 do table.remove(lines) end
    lines[#lines + 1] = GREY .. "... and " .. extra .. " more steps|r"
  end
  return table.concat(lines, "\n")
end

local function UpdatePanel()
  local id = state.center
  local p = panel
  if not id then
    p:Hide()
    return
  end
  p:Show()
  local r, g, b = ns.ItemColor(id)
  p.icon:SetTexture(ns.ItemIcon(id))
  p.iconBorder:SetVertexColor(r, g, b)
  -- A long name drops to the smaller font rather than being cut off.
  p.name:SetFontObject("GameFontNormalLarge")
  p.name:SetText(ns.ItemName(id))
  if p.name.GetStringWidth and (p.name:GetStringWidth() or 0) > PANEL_W - 62 - 10 - 6 then
    p.name:SetFontObject("GameFontNormal")
  end
  p.name:SetTextColor(r, g, b)

  p.pin:SetText(ns.Jobs.IsPinned(id) and "Remove from plan" or "Add to plan")

  local craftable = ns.Opt.IsCraftable(id)
  if craftable then
    local rec = ns.Opt.Recipe(ns.Opt.BestRecipe(id))
    local sub = (ns.Data.skills[rec[1]] or "?") .. " " .. rec[2]
    if rec[4] > 1 then sub = sub .. ", makes " .. rec[4] end
    if rec[5] > 0 then sub = sub .. ", has a cooldown" end
    p.sub:SetText(sub)
  else
    p.sub:SetText(GREY .. "Not crafted: a base resource|r")
  end

  local info = ns.Market.Info(id)
  local _, sd = ns.Stats.Estimate(id, 0)
  if info and info.price then
    local text = ns.Money(info.price)
    if sd then text = text .. GREY .. " \194\177" .. ns.Round(sd * 100) .. "%|r" end
    rows.auction:SetText(text .. GREY .. ", " .. ns.Age(info.age) .. "|r")
  elseif info then
    rows.auction:SetText(GREY .. "none listed " .. ns.Age(info.age) .. "|r")
  else
    rows.auction:SetText(GREY .. "not scanned yet|r")
  end
  if info and info.total and info.source == "scan" then
    local text = info.total .. " listed"
    if info.turnover then
      text = text .. string.format(", sells about %.0f a day", info.turnover)
    else
      text = text .. GREY .. ", demand unknown yet|r"
    end
    rows.supply:SetText(text)
  else
    rows.supply:SetText(GREY .. "unknown|r")
  end
  local vendorBuy = ns.Market.VendorBuy(id)
  local vendorText = "pays " .. ns.Money(ns.VendorSell(id))
  if vendorBuy then vendorText = vendorText .. ", sells for " .. ns.Money(vendorBuy) end
  rows.vendor:SetText(vendorText)

  local qty = ns.settings.qty or 1
  local e = ns.Opt.Evaluate(id, qty)
  local plan = e.plan
  local unitCraft
  if craftable then
    p.makeHeader:SetText("Make " .. ns.Round(e.produced))
    rows.costLabel:SetText("Materials")
  else
    p.makeHeader:SetText("Buy " .. ns.Round(e.produced))
    rows.costLabel:SetText("Cost")
  end
  if plan.complete then
    rows.cost:SetText(ns.Money(e.cost) .. GREY .. "  (" .. "|r" .. ns.Money(e.cost / e.produced) .. GREY .. " each)|r")
    if craftable then unitCraft = ns.Opt.Evaluate(id, 1).cost / ns.Opt.Evaluate(id, 1).produced end
  else
    rows.cost:SetText(GREY .. "incomplete: prices missing|r")
  end
  if e.revenue then
    rows.sale:SetText(ns.Money(e.revenue) .. GREY .. "  after the "
      .. ns.Round((ns.settings.cut or 0.05) * 100) .. "% cut|r")
  else
    rows.sale:SetText(GREY .. "no auction price|r")
  end
  if e.profit then
    local color = e.profit >= 0 and "|cff40ff40+" or "|cffff5040"
    rows.profit:SetText(color .. ns.Money(e.profit) .. "|r" .. GREY .. " \194\177|r" .. ns.Money(e.sd))
  else
    rows.profit:SetText(GREY .. "--|r")
  end

  p.useBest:Hide()
  if craftable and e.profit then
    local bestQty, best, demandKnown = ns.Opt.BestQuantity(id)
    if best.profit and best.profit > 0 then
      rows.best:SetText(bestQty .. " for |cff40ff40+" .. ns.Money(best.profit) .. "|r"
        )
      p.useBest.qty = bestQty
      p.useBest:SetShown(bestQty ~= qty)
    else
      rows.best:SetText(GREY .. "none: it loses money|r")
    end
  else
    rows.best:SetText(GREY .. "--|r")
  end
  if e.daysToSell then
    local d = e.daysToSell
    local text
    if d < 1 then text = "within a day" elseif d < 1.5 then text = "about a day"
    else text = "about " .. ns.Round(d) .. " days" end
    rows.time:SetText(text)
  else
    rows.time:SetText(GREY .. "unknown until it has been scanned twice|r")
  end

  p.makeNow:Hide()
  if craftable then
    local spell = ns.Opt.BestRecipe(id)
    local can = ns.Player.Knows(spell) and ns.Player.CanMake(spell) or 0
    if can > 0 then
      local yield = ns.Opt.Recipe(spell)[4]
      local casts = min(can, max(1, math.ceil(qty / yield - 1e-9)))
      p.makeNow.spell, p.makeNow.casts = spell, casts
      p.makeNow:SetText("Make " .. ns.Round(casts * yield))
      p.makeNow:Show()
    end
  end

  local warn = {}
  if next(plan.missing) then warn[#warn + 1] = "No price for " .. ListItems(plan.missing, 3) .. "." end
  if next(plan.short) then warn[#warn + 1] = "More than is listed: " .. ListItems(plan.short, 2) .. "." end
  if #warn == 0 and next(plan.guess) then
    warn[#warn + 1] = "Some prices are a single figure without depth; scan here for exact costs."
  end
  p.warn:SetText(table.concat(warn, " "))

  p.certainty:SetChecked(ns.settings.certainty)
  local picture = ns.settings.sideChart or "history"
  local weekPicture = picture == "week" or picture == "day"
  p.chartMode:SetText(picture == "week" and "Week pattern" or picture == "day" and "Day pattern" or "Price history")
  p.week.mode = picture == "day" and "day" or "week"
  p.range:SetShown(not weekPicture)
  p.certainty:SetShown(not weekPicture)
  p.certaintyLabel:SetShown(not weekPicture)
  chart:SetShown(not weekPicture)
  p.week:SetShown(weekPicture)
  if weekPicture then
    UI.UpdateWeekStrip(p.week, id)
  else
    chart:Update(id, { band = ns.settings.certainty, craft = unitCraft, vendor = ns.VendorSell(id),
      days = ns.settings.chartDays })
  end
  local nextStep = ""
  if state.job and state.job.text then
    nextStep = "|cffffd100Next:|r " .. state.job.text .. "\n"
  end
  p.plan:SetText(nextStep .. PlanText(plan, state.graph))
end

------------------------------------------------------------------------------
-- Status line and scanning
------------------------------------------------------------------------------
local statusHold = 0

-- progress: text to show now. hold: keep it this many seconds before the
-- usual summary may replace it.
local function UpdateStatus(progress, hold)
  if not statusText then return end
  if progress then
    statusText:SetText(progress)
    statusHold = GetTime() + (hold or 0)
    return
  end
  if GetTime() < statusHold then return end
  local graph = state.graph
  if not graph then
    statusText:SetText("")
    return
  end
  local known, total, oldest = 0, 0, 0
  for _, n in ipairs(graph.nodes) do
    if n.id then
      total = total + 1
      local info = ns.Market.Info(n.id)
      if info then
        known = known + 1
        oldest = max(oldest, info.age or 0)
      end
    end
  end
  -- Say when Blizzard's hourly data is in use, and how old it is.
  local online = ""
  local _, o = ns.Market.Online(0)
  if o then
    online = "  |cff73bfffOnline prices from " .. ns.Age(time() - (o.updated or 0)) .. " ("
      .. (o.snapshots or 0) .. " hourly snapshots).|r"
  elseif ns.Online and ns.Online.realm then
    online = GREY .. "  Online prices are for another auction house and are not used.|r"
  end
  local switchedOff = UI.SourcesText()
  if switchedOff then online = "  " .. switchedOff end
  if known == 0 then
    statusText:SetText(GREY .. "No prices yet. Open the auction house and press Scan prices.|r" .. online)
  else
    statusText:SetText(GREY .. "Prices for " .. known .. " of " .. total
      .. " items, oldest " .. ns.Age(oldest) .. ".|r" .. online)
  end
end

local function UpdateButtons()
  if not scanButton then return end
  local open = ns.Market.ahOpen
  scanButton:SetEnabled(open and state.graph ~= nil)
  fullButton:SetEnabled(open)
end

local function ScanView()
  local graph = state.graph
  if not graph then return end
  local ids = {}
  for _, n in ipairs(graph.nodes) do
    if n.id then ids[#ids + 1] = n.id end
  end
  ns.Market.ScanItems(ids)
end

------------------------------------------------------------------------------
-- Search results list
------------------------------------------------------------------------------
local function HideResults()
  if results then results:Hide() end
end

local function ShowResults(text)
  local list = UI.Search(text or "", RESULT_ROWS)
  if #list == 0 then
    HideResults()
    return
  end
  for i = 1, RESULT_ROWS do
    local row = results.rows[i]
    local e = list[i]
    if e then
      local r, g, b = ns.ItemColor(e.id)
      row.id = e.id
      row.icon:SetTexture(ns.ItemIcon(e.id))
      row.text:SetText(e.name)
      row.text:SetTextColor(r, g, b)
      row.tag:SetText(ns.Opt.IsCraftable(e.id) and "crafted" or "")
      row:Show()
    else
      row:Hide()
    end
  end
  results:SetHeight(#list * 20 + 10)
  results.first = list[1].id
  results:Show()
end

local function CreateResults(parent)
  local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  f:SetFrameStrata("DIALOG")
  f:SetWidth(300)
  f:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -6, -2)
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  f:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
  f:SetBackdropBorderColor(0.8, 0.7, 0.45, 1)
  f.rows = {}
  for i = 1, RESULT_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(20)
    row:SetPoint("TOPLEFT", 5, -5 - (i - 1) * 20)
    row:SetPoint("TOPRIGHT", -5, -5 - (i - 1) * 20)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.text = Text(row, "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.tag = Text(row, "GameFontDisableSmall", "RIGHT")
    row.tag:SetPoint("RIGHT", -4, 0)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.15)
    row:SetScript("OnClick", function(self)
      if self.id then
        search:SetText("")
        search:ClearFocus()
        HideResults()
        UI.Focus(self.id)
      end
    end)
    f.rows[i] = row
  end
  f:Hide()
  return f
end

------------------------------------------------------------------------------
-- Opportunities: every way to make money now, in one list. The player
-- judges the effort, so nothing profitable is hidden; each row shows the
-- amount worth doing, what it costs up front, the profit with its margin
-- and how many steps it takes.
------------------------------------------------------------------------------
local WORTH_ROWS = 23
local worth, worthButton
local worthSort = "safe"
local worthFilter = "all"
local KIND_TINT = {
  craft = { 1, 0.6, 0.25 }, flip = { 1, 0.82, 0 }, tovendor = { 0.4, 1, 0.4 },
  fromvendor = { 0.45, 0.75, 1 }, bags = { 0.85, 0.85, 0.85 }, later = { 0.75, 0.6, 1 },
}
-- "This item" lists every option that involves the item in focus; "When"
-- lists what you hold or can make with the best hour to sell it.
local FILTERS = {
  { key = "all", text = "All" }, { key = "craft", text = "Craft" }, { key = "flip", text = "Relist" },
  { key = "vendor", text = "Vendor" }, { key = "bags", text = "Bags" },
  { key = "item", text = "This item" }, { key = "later", text = "When" },
}

-- A profit or loss in colour, with its sign.
local function Signed(copper)
  return (copper < 0 and "|cffff5040-" or "|cff40ff40+") .. ns.Money(math.abs(copper)) .. "|r"
end

-- Adds "if it sells ..." lines to the tooltip: the profit by when the goods sell.
local function AddProjection(proj)
  if not proj or not proj.now then return end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(proj.fixed and "Profit" or "Profit if it sells ...", 1, 0.82, 0)
  for _, row in ipairs(proj.rows) do
    local range = row.lo ~= row.hi and (GREY .. "  (" .. ns.Money(row.lo) .. " to " .. ns.Money(row.hi) .. ")|r") or ""
    GameTooltip:AddDoubleLine(row.label, Signed(row.profit) .. range, 1, 1, 1, 1, 1, 1)
  end
  if proj.best then
    GameTooltip:AddDoubleLine("best hour this week: " .. proj.best.label, Signed(proj.best.profit),
      0.45, 0.75, 1, 1, 1, 1)
  end
  GameTooltip:AddLine("Costs " .. ns.Money(proj.cost) .. " for " .. ns.Round(proj.units) .. ", at "
    .. ns.Money(proj.priceNow) .. " each now. The ranges hold about two times in three.", 0.6, 0.6, 0.6, true)
  if proj.short then
    GameTooltip:AddLine("Only part of this is listed: " .. ns.Round(proj.short)
      .. " more are counted at the dearest listed price.", 1, 0.55, 0.2, true)
  end
  if proj.id then GameTooltip:AddLine("Prices: " .. UI.ScanAgeText(proj.id), 1, 1, 1) end
end
UI.AddProjection = AddProjection

-- What a market opportunity is planned as.
local function GoalOf(d)
  return { kind = d.kind, qty = d.qty, outlay = d.outlay, sellEach = d.sellEach, profit = d.profit }
end

local function InFilter(d)
  if worthFilter == "all" or worthFilter == "item" or worthFilter == "later" then return true end
  if worthFilter == "vendor" then return d.kind == "tovendor" or d.kind == "fromvendor" end
  return d.kind == worthFilter
end

local function DealName(d)
  if d.kind == "bags" then return d.qty .. " items in your bags" end
  return ns.ItemName(d.id)
end

local function WorthTooltip(row)
  local d = row.data
  if not d then return end
  local Deals = ns.Deals
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if d.id then
    if not pcall(GameTooltip.SetItemByID, GameTooltip, d.id) then GameTooltip:SetText(ns.ItemName(d.id)) end
    GameTooltip:AddLine(" ")
  else
    GameTooltip:SetText(DealName(d))
  end
  GameTooltip:AddLine(Deals.KIND[d.kind], 1, 0.82, 0)
  GameTooltip:AddLine(Deals.Example(d), 1, 1, 1, true)
  if d.kind == "later" then
    GameTooltip:AddDoubleLine("Now", ns.Money(d.nowEach) .. " each", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine(d.when.hours > 0 and d.when.label or "Best hour", d.when.hours > 0
      and (ns.Money(d.sellEach) .. " each" .. GREY .. " (" .. ns.Money(d.when.lo) .. " to " .. ns.Money(d.when.hi) .. ")|r")
      or "now", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine("From this item's trend and its hour and weekday habits. A later hour is only "
      .. "named when it beats now by more than the doubt that waiting adds.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
    return
  end
  if d.kind == "craft" then
    local r = ns.Opt.Recipe(d.spell)
    GameTooltip:AddDoubleLine("Recipe", r[6], 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Make", ns.Round(d.qty), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Profit each", ns.Money(d.craft.each), 1, 0.82, 0, 1, 1, 1)
  elseif d.kind == "flip" then
    GameTooltip:AddDoubleLine("Buy", d.qty .. " for " .. ns.Money(d.outlay), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Relist at", ns.Money(d.sellEach) .. " each", 1, 0.82, 0, 1, 1, 1)
    if not d.demandKnown then
      GameTooltip:AddLine("How fast this sells is not known yet, so the amount is kept to one stack.", 1, 1, 1, true)
    end
  elseif d.kind == "tovendor" then
    GameTooltip:AddDoubleLine("Buy", d.qty .. " for " .. ns.Money(d.outlay), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("A vendor pays", ns.Money(d.sellEach) .. " each", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine("No price risk: the vendor always pays this. Only the listing can be gone.", 1, 1, 1, true)
  elseif d.kind == "fromvendor" then
    GameTooltip:AddDoubleLine("Buy from a vendor", d.qty .. " for " .. ns.Money(d.outlay), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Post at", ns.Money(d.sellEach) .. " each", 1, 0.82, 0, 1, 1, 1)
  elseif d.kind == "bags" then
    GameTooltip:AddLine("List what you already hold. Opens the Sell bags list.", 1, 1, 1, true)
  end
  GameTooltip:AddDoubleLine("Expected profit", ns.Money(d.profit) .. " \194\177" .. ns.Money(d.sd), 1, 0.82, 0, 0.25, 1, 0.25)
  if d.id and d.kind ~= "bags" then
    AddProjection(ns.Jobs.Projection(d.id, d.qty, d.kind ~= "craft" and GoalOf(d) or nil))
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Steps: " .. table.concat(d.steps, ", then "), 0.8, 0.8, 0.8, true)
  if d.thin then
    GameTooltip:AddLine("Very few are listed, so the selling price is an asking price, not proof it sells.",
      1, 0.55, 0.2, true)
  elseif d.stale then
    GameTooltip:AddLine("These prices are over two hours old. Scan again before acting.", 1, 0.55, 0.2, true)
  elseif d.assumed then
    GameTooltip:AddLine("The vendor price is from a built-in list and has not been seen in this game yet. "
      .. "It is confirmed the first time you open a vendor that sells it.", 1, 0.55, 0.2, true)
  elseif not d.sure then
    GameTooltip:AddLine("The margin is wider than the profit: a gamble until prices are better known.",
      1, 0.55, 0.2, true)
  end
  if d.guess then
    GameTooltip:AddLine("Not confirmed as learned. Open this profession's window once.", 1, 0.55, 0.2, true)
  end
  if d.id then GameTooltip:AddLine("Click to open it in the graph.", 0.6, 0.6, 0.6) end
  GameTooltip:Show()
end

-- The one action a row offers, by kind and by where the player stands.
local function DealAction(d)
  local J, M = ns.Jobs, ns.Market
  if d.kind == "craft" then
    local pinned = J.IsPinned(d.id)
    return pinned and "Remove" or "Plan it", true, function()
      if J.IsPinned(d.id) then J.Unpin(d.id) else UI.AddToPlan(d.id, d.qty) end
    end, pinned and "Takes this out of your plan and forgets its progress."
      or "Adds this to your plan; the small plan window then shows its next step wherever you are."
  elseif d.kind == "later" then
    return "Trends", true, function()
      UI.Remember()
      UI.Focus(d.id)
      UI.ShowTrends(true)
    end, "Opens this item's trends: its price by hour and weekday."
  elseif d.kind == "flip" or d.kind == "tovendor" or d.kind == "fromvendor" then
    -- Planned: the plan window carries it from here. Otherwise buy on the
    -- spot where that is possible, or plan it for later.
    if J.IsPinned(d.id) then
      return "Remove", true, function() J.Unpin(d.id) end, "Takes this out of your plan and forgets its progress."
    end
    local plan = function() UI.AddToPlan(d.id, d.qty, GoalOf(d)) end
    local planTip = "Adds this to your plan: the small plan window then lists its steps, keeps its "
      .. "projected profit up to date with every scan, and shows how that has moved."
    if d.kind == "fromvendor" then
      local want = { [d.id] = d.qty }
      if J.place == "merchant" and #J.MerchantOffer(want, true) > 0 then
        return "Buy " .. ns.Round(d.qty), true, function()
          if IsShiftKeyDown() then plan() else J.BuyFromMerchant(want, true) end
        end, "Buys this amount from the vendor you are talking to. Shift-click to add it to your plan instead."
      end
    elseif M.ahOpen and not d.stale then
      return "Buy " .. ns.Round(d.qty), true, function()
        if IsShiftKeyDown() then plan() else J.BuyAuction(d.id, d.qty, d.outlay) end
      end, "Buys this amount at the price shown; nothing is bought if the price has moved up. "
        .. "Shift-click to add it to your plan instead."
    end
    return "Plan it", true, plan, planTip
  end
  return "Open", true, function() UI.ShowSell(true) end, "Opens the Sell bags list."
end

local function CreateWorth(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetPoint("TOPLEFT", 3, -3)
  f:SetPoint("BOTTOMRIGHT", -3, 3)
  f:Hide()
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.04, 0.03, 0.92)

  f.summary = Text(f, "GameFontNormal")
  f.summary:SetPoint("TOPLEFT", 14, -12)
  f.note = Text(f, "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", 14, -32)
  f.note:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -32)
  f.note:SetWordWrap(false)

  -- Filter by kind of opportunity.
  f.filters = {}
  local prev
  for i = #FILTERS, 1, -1 do
    local def = FILTERS[i]
    local b = Button(f, def.text, def.key == "item" and 70 or 52)
    b:SetHeight(19)
    if prev then b:SetPoint("RIGHT", prev, "LEFT", -3, 0) else b:SetPoint("TOPRIGHT", -12, -9) end
    b:SetScript("OnClick", function()
      worthFilter = def.key
      f.offset = 0
      UI.UpdateWorth()
    end)
    f.filters[def.key] = b
    prev = b
  end

  local COLS = {
    { key = "name", text = "What", x = 14, justify = "LEFT", width = 190 },
    { key = "kind", text = "How", x = 232, justify = "LEFT", width = 150 },
    { key = "qty", text = "Amount", right = 446, justify = "RIGHT", width = 60 },
    { key = "outlay", text = "Costs up front", right = 548, justify = "RIGHT", width = 96 },
    { key = "profit", text = "Profit", right = 668, justify = "RIGHT", width = 100 },
    { key = "effort", text = "Steps", right = 716, justify = "RIGHT", width = 44 },
  }
  for _, c in ipairs(COLS) do
    local h = CreateFrame("Button", nil, f)
    h:SetHeight(18)
    h:SetWidth(c.width)
    h.text = Text(h, "GameFontNormalSmall", c.justify)
    h.text:SetAllPoints()
    h.text:SetText(c.text)
    if c.x then h:SetPoint("TOPLEFT", c.x, -54) else h:SetPoint("TOPRIGHT", f, "TOPLEFT", c.right, -54) end
    h:SetScript("OnClick", function()
      -- Clicking the same header again returns to "surest first".
      worthSort = (worthSort == c.key) and "safe" or c.key
      UI.UpdateWorth()
    end)
  end
  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.3)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT", 10, -74)
  line:SetPoint("TOPRIGHT", -10, -74)

  f.rows = {}
  for i = 1, WORTH_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(21)
    local y = -78 - (i - 1) * 21
    row:SetPoint("TOPLEFT", 8, y)
    row:SetPoint("TOPRIGHT", -8, y)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(17, 17)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = Text(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(190)
    row.name:SetWordWrap(false)
    row.kind = Text(row, "GameFontHighlightSmall")
    row.kind:SetPoint("LEFT", row, "LEFT", 224, 0)
    row.kind:SetWidth(158)
    row.kind:SetWordWrap(false)
    row.qty = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.qty:SetPoint("RIGHT", row, "LEFT", 438, 0)
    row.outlay = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.outlay:SetPoint("RIGHT", row, "LEFT", 540, 0)
    row.profit = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.profit:SetPoint("RIGHT", row, "LEFT", 660, 0)
    row.effort = Text(row, "GameFontDisableSmall", "RIGHT")
    row.effort:SetPoint("RIGHT", row, "LEFT", 708, 0)
    row.act = Button(row, "", 66)
    row.act:SetHeight(19)
    row.act:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    if row.act.SetMotionScriptsWhileDisabled then row.act:SetMotionScriptsWhileDisabled(true) end
    row.act:SetScript("OnClick", function(self)
      if self.fn then
        ns.Safe(self.fn)
        UI.UpdateWorth()
      end
    end)
    row.act:SetScript("OnEnter", function(self)
      if not self.tip then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText(self:GetText() or "")
      GameTooltip:AddLine(self.tip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    row.act:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    row:SetScript("OnEnter", function(self) ns.Safe(WorthTooltip, self) end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:RegisterForClicks("LeftButtonUp", "Button4Up", "Button5Up")
    row:SetScript("OnClick", function(self, button)
      if UI.NavButton(button) then return end
      local d = self.data
      if not d then return end
      if not d.id then
        UI.ShowSell(true)
        return
      end
      UI.Remember()
      UI.ShowWorth(false, true)
      if d.kind == "craft" then UI.SetQuantity(d.qty) end
      UI.Focus(d.id)
    end)
    f.rows[i] = row
  end

  f.more = Text(f, "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 14, 8)
  f.offset = 0
  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function(_, button) UI.NavButton(button) end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(self, delta)
    self.offset = max(0, self.offset - delta * 3)
    UI.UpdateWorth()
  end)
  return f
end

function UI.UpdateWorth()
  if not worth or not worth:IsShown() then return end
  local Deals = ns.Deals
  local list, info = Deals.All()
  local focus = state.center
  if worthFilter == "item" then
    list = focus and Deals.ForItem(focus) or {}
  elseif worthFilter == "later" then
    list = Deals.Timing()
  end
  local sorted, counts = {}, {}
  for _, d in ipairs(list) do
    counts[d.kind] = (counts[d.kind] or 0) + 1
    if InFilter(d) then sorted[#sorted + 1] = d end
  end
  local by = worthSort
  if by == "name" then
    table.sort(sorted, function(a, b) return DealName(a) < DealName(b) end)
  elseif by == "kind" then
    table.sort(sorted, function(a, b)
      if a.kind ~= b.kind then return a.kind < b.kind end
      return a.safe > b.safe
    end)
  elseif by == "qty" or by == "outlay" or by == "profit" then
    table.sort(sorted, function(a, b)
      if a[by] ~= b[by] then return a[by] > b[by] end
      return a.safe > b.safe
    end)
  elseif by == "effort" then
    table.sort(sorted, function(a, b)
      if a.effort ~= b.effort then return a.effort < b.effort end
      return a.safe > b.safe
    end)
  end

  for key, b in pairs(worth.filters) do
    if key == worthFilter then b:LockHighlight() else b:UnlockHighlight() end
  end
  local sure = 0
  for _, d in ipairs(list) do if d.sure then sure = sure + 1 end end
  if worthFilter == "item" then
    worth.summary:SetText("Ways to profit from " .. (focus and ns.ItemName(focus) or "an item")
      .. ": |cffffffff" .. #list .. "|r")
  elseif worthFilter == "later" then
    worth.summary:SetText("When to sell what you have or can make: |cffffffff" .. #list .. "|r")
  else
    worth.summary:SetText("Ways to make money now: |cffffffff" .. #list .. "|r"
      .. GREY .. "  (" .. sure .. " look certain)|r")
  end
  local note
  if worthFilter == "item" then
    if not focus then
      note = "|cffff8c33Pick an item first: search for it, or click one in the graph or a list.|r"
    elseif #list == 0 then
      note = GREY .. "Nothing pays right now: not relisting it, not a vendor, not crafting with it (from recipes you know).|r"
    else
      note = Deals.Example(sorted[1] or list[1])
    end
  elseif worthFilter == "later" then
    note = #list == 0 and (GREY .. "Nothing in your bags or bank is worth listing, and nothing you know pays to make.|r")
      or (GREY .. "Profit is what waiting for that hour should add over selling now. Hover a row for the numbers.|r")
  elseif next(info.unverified) then
    local names = {}
    for id in pairs(info.unverified) do names[#names + 1] = ns.Data.skills[id] or "?" end
    table.sort(names)
    note = "|cffff8c33Open your " .. table.concat(names, " and ")
      .. " window once so your learned recipes can be read. Until then crafting goes by skill level.|r"
  elseif #list == 0 then
    note = "|cffff8c33Nothing yet. Run a full scan at the auction house.|r"
  else
    local parts = {}
    for _, def in ipairs({ "craft", "flip", "tovendor", "fromvendor" }) do
      if counts[def] then parts[#parts + 1] = counts[def] .. " " .. Deals.KIND[def]:lower() end
    end
    note = GREY .. table.concat(parts, ", ") .. ". Surest first; click a column to sort by it.|r"
  end
  worth.note:SetText(note)

  worth.offset = min(worth.offset, max(0, #sorted - WORTH_ROWS))
  for i = 1, WORTH_ROWS do
    local row = worth.rows[i]
    local d = sorted[i + worth.offset]
    row.data = d
    if d then
      if d.id then
        local r, g, b = ns.ItemColor(d.id)
        row.icon:SetTexture(ns.ItemIcon(d.id))
        row.name:SetTextColor(r, g, b)
      else
        row.icon:SetTexture(133784)
        row.name:SetTextColor(1, 1, 1)
      end
      row.name:SetText(DealName(d) .. (d.guess and " |cffff8c33?|r" or ""))
      local t = KIND_TINT[d.kind]
      row.kind:SetText(d.how or Deals.KIND[d.kind])
      row.kind:SetTextColor(t[1], t[2], t[3])
      row.qty:SetText(d.kind == "bags" and "" or ("x" .. ns.Round(d.qty)))
      row.outlay:SetText(d.outlay > 0 and ns.Money(d.outlay) or (GREY .. "nothing|r"))
      row.profit:SetText((d.kind == "later" and d.when.hours == 0) and (GREY .. "sell now|r")
        or "|cff40ff40+" .. ns.Money(d.profit) .. "|r"
        .. (d.sd > 0 and (GREY .. " \194\177" .. min(999, ns.Round(100 * d.sd / max(d.profit, 1))) .. "%|r") or ""))
      row.effort:SetText(d.effort)
      local text, enabled, fn, tip = DealAction(d)
      row.act:SetText(text)
      row.act:SetEnabled(enabled and true or false)
      row.act.fn = enabled and fn or nil
      row.act.tip = tip
      row:SetAlpha(d.sure and 1 or 0.55)
      row:Show()
    else
      row:Hide()
    end
  end
  if #sorted > WORTH_ROWS then
    worth.more:SetText((worth.offset + 1) .. " to " .. min(#sorted, worth.offset + WORTH_ROWS)
      .. " of " .. #sorted .. ". Scroll for more.")
  else
    worth.more:SetText("Faded rows are not certain to pay. Hover a row for the steps it takes.")
  end
end

------------------------------------------------------------------------------
-- Sell bags: what in the bags is worth listing, and a button to list it.
------------------------------------------------------------------------------
local SELL_ROWS = 24
local sell, sellButton
local sellSkip = {}

local function SellRowNote(d)
  if d.reserved then return GREY .. " (kept for your plan)|r" end
  if d.count <= 0 then return " |cff73bfff(in the bank)|r" end
  if d.bank > 0 then return " |cff73bfff(+" .. d.bank .. " in bank)|r" end
  if d.none then return " |cffff8c33(none listed now)|r" end
  if d.listed and d.listed <= 2 then return " |cffff8c33(only " .. d.listed .. " listed)|r" end
  return ""
end

local function SellOne(d)
  local ok, why = ns.Jobs.SellAuction(d.id, nil, true)
  if not ok and why == "no" then sellSkip[d.id] = true end
  UI.UpdateSell()
end

local function CreateSell(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetPoint("TOPLEFT", 3, -3)
  f:SetPoint("BOTTOMRIGHT", -3, 3)
  f:Hide()
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.04, 0.03, 0.92)

  f.summary = Text(f, "GameFontNormal")
  f.summary:SetPoint("TOPLEFT", 14, -12)
  f.note = Text(f, "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", 14, -32)
  f.note:SetPoint("TOPRIGHT", f, "TOPRIGHT", -170, -32)
  f.note:SetWordWrap(false)

  f.next = Button(f, "Sell next", 150)
  f.next:SetPoint("TOPRIGHT", -12, -10)
  f.next:SetScript("OnClick", function(self)
    if self.row then ns.Safe(SellOne, self.row) end
  end)
  Tip(f.next, "Sell next",
    "Posts the next item in the list at just under the cheapest listing. The game allows one "
    .. "listing per click, so keep pressing to work down the list.")

  local function Header(text, right, x)
    local h = Text(f, "GameFontNormalSmall", right and "RIGHT" or "LEFT")
    if right then
      h:SetPoint("TOPRIGHT", f, "TOPLEFT", right, -56)
    else
      h:SetPoint("TOPLEFT", x, -56)
    end
    h:SetText(text)
  end
  Header("Item", nil, 14)
  Header("Price each", 430)
  Header("You get", 560)
  Header("Over vendor", 690)
  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.3)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT", 10, -74)
  line:SetPoint("TOPRIGHT", -10, -74)

  f.rows = {}
  for i = 1, SELL_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(21)
    local y = -78 - (i - 1) * 21
    row:SetPoint("TOPLEFT", 8, y)
    row:SetPoint("TOPRIGHT", -8, y)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(17, 17)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = Text(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(290)
    row.name:SetWordWrap(false)
    row.each = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.each:SetPoint("RIGHT", row, "LEFT", 422, 0)
    row.get = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.get:SetPoint("RIGHT", row, "LEFT", 552, 0)
    row.gain = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.gain:SetPoint("RIGHT", row, "LEFT", 682, 0)
    row.sell = Button(row, "Sell", 66)
    row.sell:SetHeight(19)
    row.sell:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.sell:SetScript("OnClick", function()
      if row.data then ns.Safe(SellOne, row.data) end
    end)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    row:RegisterForClicks("LeftButtonUp", "Button4Up", "Button5Up")
    row:SetScript("OnClick", function(self, button)
      if UI.NavButton(button) then return end
      if self.data then UI.Focus(self.data.id) UI.ShowSell(false) end
    end)
    row:SetScript("OnEnter", function(self)
      local d = self.data
      if not d then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if not pcall(GameTooltip.SetItemByID, GameTooltip, d.id) then GameTooltip:SetText(ns.ItemName(d.id)) end
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("In your bags", d.count, 1, 0.82, 0, 1, 1, 1)
      if d.bank > 0 then
        GameTooltip:AddDoubleLine("In your bank", d.bank, 1, 0.82, 0, 0.45, 0.75, 1)
        GameTooltip:AddLine("What is in the bank must be taken out before it can be posted.", 1, 1, 1, true)
      end
      GameTooltip:AddDoubleLine("After the auction cut", ns.Money(d.net) .. " \194\177" .. ns.Money(d.sd), 1, 0.82, 0, 1, 1, 1)
      GameTooltip:AddDoubleLine("A vendor would pay", ns.Money(d.net - d.gain), 1, 0.82, 0, 1, 1, 1)
      if d.reserved then
        GameTooltip:AddLine("Your plan needs this as a material, so it is left out of Sell next.", 1, 1, 1, true)
      elseif d.none then
        GameTooltip:AddLine("None is listed now; the price is the last one seen.", 1, 0.55, 0.2, true)
      elseif d.listed and d.listed <= 2 then
        GameTooltip:AddLine("Very few are listed: this is an asking price, not proof it sells.", 1, 0.55, 0.2, true)
      end
      GameTooltip:AddLine("Click to open it in the graph.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.rows[i] = row
  end

  f.more = Text(f, "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 14, 8)
  f.offset = 0
  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function(_, button) UI.NavButton(button) end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(self, delta)
    self.offset = max(0, self.offset - delta * 3)
    UI.UpdateSell()
  end)
  return f
end

function UI.UpdateSell()
  if not sell or not sell:IsShown() then return end
  local rows, sum = ns.Jobs.BagSales()
  local open = ns.Market.ahOpen
  if sum.count == 0 then
    sell.summary:SetText("Nothing in your bags is worth listing right now.")
  else
    sell.summary:SetText("Worth listing: |cffffffff" .. sum.count .. " items for about|r "
      .. ns.Money(sum.total) .. GREY .. " \194\177|r" .. ns.Money(sum.sd))
  end
  local parts = {}
  if sum.vendorItems > 0 then
    parts[#parts + 1] = sum.vendorItems .. " others do better at a vendor (" .. ns.Money(sum.vendorTotal) .. ")"
  end
  if sum.unknown > 0 then parts[#parts + 1] = sum.unknown .. " have no auction price yet" end
  if sum.bankItems > 0 then
    parts[#parts + 1] = "|cff73bfff" .. sum.bankItems .. " more in the bank worth about "
      .. ns.Money(sum.bankTotal) .. "|r" .. GREY
  end
  if not open then parts[#parts + 1] = "open the auction house to sell" end
  sell.note:SetText(GREY .. table.concat(parts, ". ") .. (#parts > 0 and "." or "") .. "|r")

  local nextRow, left = nil, 0
  for _, d in ipairs(rows) do
    if not d.reserved and not sellSkip[d.id] and d.count > 0 then
      left = left + 1
      nextRow = nextRow or d
    end
  end
  sell.next.row = nextRow
  sell.next:SetEnabled(open and nextRow ~= nil)
  if ns.Jobs.Busy() then
    sell.next:SetText("Working ...")
  elseif nextRow then
    sell.next:SetText("Sell next (" .. left .. " left)")
  else
    sell.next:SetText("Sell next")
  end

  sell.offset = min(sell.offset, max(0, #rows - SELL_ROWS))
  for i = 1, SELL_ROWS do
    local row = sell.rows[i]
    local d = rows[i + sell.offset]
    row.data = d
    if d then
      local r, g, b = ns.ItemColor(d.id)
      row.icon:SetTexture(ns.ItemIcon(d.id))
      local shownCount = d.count > 0 and d.count or d.bank
      row.name:SetText(ns.ItemName(d.id) .. " |cffffffffx" .. shownCount .. "|r" .. SellRowNote(d))
      row.name:SetTextColor(r, g, b)
      row.each:SetText(ns.Money(d.price))
      if d.count > 0 then
        row.get:SetText(ns.Money(d.net))
        row.gain:SetText("|cff40ff40+" .. ns.Money(d.gain) .. "|r")
      else
        -- Only in the bank: what it would fetch once taken out.
        local cut = ns.settings.cut or 0.05
        row.get:SetText("|cff73bfff" .. ns.Money(d.price * (1 - cut) * d.bank) .. "|r")
        row.gain:SetText(GREY .. "take out first|r")
      end
      row.sell:SetShown(open and not d.reserved and d.count > 0)
      row.sell:SetEnabled(not sellSkip[d.id])
      row:SetAlpha((d.reserved or sellSkip[d.id]) and 0.5 or (d.count > 0 and 1 or 0.8))
      row:Show()
    else
      row:Hide()
    end
  end
  if #rows > SELL_ROWS then
    sell.more:SetText((sell.offset + 1) .. " to " .. min(#rows, sell.offset + SELL_ROWS) .. " of " .. #rows
      .. ". Scroll for more.")
  else
    sell.more:SetText("Prices are just under the cheapest listing. Bound items and materials for your plan are left out.")
  end
end

------------------------------------------------------------------------------
-- Trends: patterns for one item that only show over time. Price or supply
-- by hour of day or day of week, how listings are stacked, and who sells.
-- Bars resting on few scans are drawn faint, and every panel says what it
-- still lacks rather than drawing a pattern out of one sample.
------------------------------------------------------------------------------
local trends, trendsButton
local trendPeriod, trendMeasure = "hour", "price"
-- The time the selector sits on: weekday (0 = Sunday) and hour. Starts at now.
local trendSel
local DAY_ORDER = { 1, 2, 3, 4, 5, 6, 0 }
local DAY_NAME = { [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local DAY_LONG = { [0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

local function Percent(fraction)
  local p = ns.Round(math.abs(fraction) * 100)
  if p == 0 then return "about its usual price" end
  return p .. "% " .. (fraction < 0 and "under" or "over") .. " its usual price"
end

local function HourText(h)
  return string.format("%02d:00", h)
end

local function CreateTrends(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetPoint("TOPLEFT", 3, -3)
  f:SetPoint("BOTTOMRIGHT", -3, 3)
  f:Hide()
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.04, 0.03, 0.92)
  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function(_, button) UI.NavButton(button) end)

  f.title = Text(f, "GameFontNormalLarge")
  f.title:SetPoint("TOPLEFT", 14, -12)
  f.facts = Text(f, "GameFontHighlightSmall")
  f.facts:SetPoint("TOPLEFT", 14, -36)
  f.facts:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -36)
  f.facts:SetWordWrap(true)
  f.facts:SetMaxLines(4)
  f.facts:SetSpacing(3)
  f.facts:SetJustifyV("TOP")

  -- Options: what to group by, and what to measure.
  f.options = {}
  local function Option(group, key, text, x, width)
    local b = Button(f, text, width)
    b:SetHeight(19)
    b:SetPoint("TOPLEFT", x, -102)
    b:SetScript("OnClick", function()
      if group == "period" then trendPeriod = key else trendMeasure = key end
      UI.UpdateTrends()
    end)
    f.options[group .. ":" .. key] = b
    return b
  end
  Option("period", "hour", "Hour of day", 14, 96)
  Option("period", "day", "Day of week", 114, 96)
  Option("period", "week", "Whole week", 214, 96)
  Option("measure", "price", "Price", 336, 70)
  Option("measure", "listed", "Amount listed", 410, 104)
  f.optionNote = Text(f, "GameFontDisableSmall", "RIGHT")
  f.optionNote:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -106)

  -- The bar chart.
  local chartBox = CreateFrame("Frame", nil, f)
  chartBox:SetPoint("TOPLEFT", 14, -128)
  chartBox:SetPoint("TOPRIGHT", -14, -128)
  chartBox:SetHeight(200)
  local cbg = chartBox:CreateTexture(nil, "BACKGROUND")
  cbg:SetAllPoints()
  cbg:SetColorTexture(0, 0, 0, 0.45)
  f.chart = chartBox
  f.baseline = chartBox:CreateTexture(nil, "ARTWORK")
  f.baseline:SetColorTexture(1, 1, 1, 0.25)
  f.baseline:SetHeight(1)
  f.bars, f.barLabels, f.barHits = {}, {}, {}
  f.nowMark = chartBox:CreateTexture(nil, "BORDER")
  f.nowMark:SetColorTexture(1, 0.82, 0, 0.10)
  -- The selector: drag it, or turn the mouse wheel, to read off any time.
  f.selMark = chartBox:CreateTexture(nil, "OVERLAY")
  f.selMark:SetColorTexture(1, 1, 1, 0.16)
  f.selLine = chartBox:CreateTexture(nil, "OVERLAY")
  f.selLine:SetColorTexture(1, 0.82, 0, 0.9)
  f.daySeps = {}
  for i = 1, 6 do
    f.daySeps[i] = chartBox:CreateTexture(nil, "BORDER")
    f.daySeps[i]:SetColorTexture(1, 1, 1, 0.12)
  end
  f.readout = Text(f, "GameFontHighlightSmall")
  f.readout:SetPoint("TOPLEFT", 14, -332)
  f.readout:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -332)
  f.readout:SetWordWrap(true)
  f.readout:SetMaxLines(2)
  f.readout:SetSpacing(2)
  f.readout:SetJustifyV("TOP")
  f.scaleTop = Text(chartBox, "GameFontDisableSmall")
  f.scaleTop:SetPoint("TOPLEFT", 4, -3)
  f.scaleBottom = Text(chartBox, "GameFontDisableSmall")
  f.scaleBottom:SetPoint("BOTTOMLEFT", 4, 16)
  f.chartEmpty = Text(chartBox, "GameFontDisable", "CENTER")
  f.chartEmpty:SetPoint("CENTER")
  f.chartEmpty:SetWidth(520)
  f.chartNote = Text(f, "GameFontDisableSmall")
  f.chartNote:SetPoint("TOPLEFT", 14, -364)
  f.chartNote:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -364)
  f.chartNote:SetWordWrap(false)

  -- Stack sizes (left) and sellers (right).
  f.stackTitle = Text(f, "GameFontNormal")
  f.stackTitle:SetPoint("TOPLEFT", 14, -388)
  f.stackTitle:SetText("Listed in stacks of")
  f.stackNote = Text(f, "GameFontDisableSmall")
  f.stackNote:SetPoint("TOPLEFT", 14, -408)
  f.stackNote:SetWidth(340)
  f.stackNote:SetWordWrap(true)
  f.stackNote:SetJustifyV("TOP")
  f.stackRows = {}
  f.sellerTitle = Text(f, "GameFontNormal")
  f.sellerTitle:SetPoint("TOPLEFT", 400, -388)
  f.sellerTitle:SetText("Sellers at the last scan")
  f.sellerNote = Text(f, "GameFontDisableSmall")
  f.sellerNote:SetPoint("TOPLEFT", 400, -408)
  f.sellerNote:SetWidth(380)
  f.sellerNote:SetWordWrap(true)
  f.sellerNote:SetJustifyV("TOP")
  f.sellerRows = {}

  local function ShareRow(list, i, x, labelWidth, barWidth)
    local row = list[i]
    if row then return row end
    row = {}
    local y = -428 - (i - 1) * 20
    row.label = Text(f, "GameFontHighlightSmall")
    row.label:SetPoint("TOPLEFT", x, y)
    row.label:SetWidth(labelWidth)
    row.label:SetWordWrap(false)
    row.track = f:CreateTexture(nil, "BORDER")
    row.track:SetColorTexture(1, 1, 1, 0.06)
    row.track:SetPoint("TOPLEFT", x + labelWidth + 6, y - 1)
    row.track:SetSize(barWidth, 11)
    row.bar = f:CreateTexture(nil, "ARTWORK")
    row.bar:SetPoint("TOPLEFT", x + labelWidth + 6, y - 1)
    row.bar:SetHeight(11)
    row.value = Text(f, "GameFontHighlightSmall")
    row.value:SetPoint("TOPLEFT", x + labelWidth + barWidth + 14, y)
    row.barWidth = barWidth
    list[i] = row
    return row
  end
  f.ShareRow = ShareRow
  return f
end

local function HideShareRows(list, from)
  for i = from, #list do
    local row = list[i]
    row.label:SetText("")
    row.value:SetText("")
    row.track:Hide()
    row.bar:Hide()
  end
end

local function DayPosition(day)
  for index, d in ipairs(DAY_ORDER) do
    if d == day then return index - 1 end
  end
  return 0
end

local function TrendSelection()
  if not trendSel then
    trendSel = { day = tonumber(date("%w")) or 0, hour = tonumber(date("%H")) or 0 }
  end
  return trendSel
end

-- Where the selector sits among the bars of the current view (0-based).
local function SelectedSlot()
  local sel = TrendSelection()
  if trendPeriod == "hour" then return sel.hour end
  if trendPeriod == "day" then return DayPosition(sel.day) end
  return DayPosition(sel.day) * 24 + sel.hour
end

-- Moves the selector to a bar of the current view.
function UI.SelectTrendSlot(index)
  local sel = TrendSelection()
  local count = trendPeriod == "hour" and 24 or trendPeriod == "day" and 7 or 168
  index = index % count
  if trendPeriod == "hour" then
    sel.hour = index
  elseif trendPeriod == "day" then
    sel.day = DAY_ORDER[index + 1]
  else
    sel.day, sel.hour = DAY_ORDER[floor(index / 24) + 1], index % 24
  end
  UI.UpdateTrends()
  if panel and panel.week and panel.week:IsShown() then UI.MoveStripSelector(panel.week, state.center) end
end

------------------------------------------------------------------------------
-- The week strip: the Trends view's whole-week picture in small, for the
-- side panel. One bar per hour from Monday to Sunday, green where the item
-- is cheaper than usual and orange where dearer, with the same selector.
------------------------------------------------------------------------------
local STRIP_PLOT_H = 96

-- Moves the shared selector to an hour of the week (0 = Monday 00:00).
local function SelectWeekHour(strip, index)
  local sel = TrendSelection()
  if strip.mode == "day" then
    sel.hour = index % 24
  else
    index = index % 168
    sel.day, sel.hour = DAY_ORDER[floor(index / 24) + 1], index % 24
  end
  UI.MoveStripSelector(strip, state.center)
  if trends and trends:IsShown() then UI.UpdateTrends() end
end

function UI.CreateWeekStrip(parent)
  local f = CreateFrame("Frame", nil, parent)
  local plot = CreateFrame("Frame", nil, f)
  plot:SetPoint("TOPLEFT", 2, -2)
  plot:SetPoint("TOPRIGHT", -2, -2)
  plot:SetHeight(STRIP_PLOT_H)
  f.plot = plot
  local bg = plot:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.45)
  f.bars, f.seps, f.dayLabels, f.lines, f.dots = {}, {}, {}, {}, {}
  f.mode = "week"
  f.nowMark = plot:CreateTexture(nil, "BORDER")
  f.nowMark:SetColorTexture(1, 0.82, 0, 0.35)
  f.selLine = plot:CreateTexture(nil, "OVERLAY")
  f.selLine:SetColorTexture(1, 1, 1, 0.95)
  for i = 1, 6 do
    f.seps[i] = plot:CreateTexture(nil, "BORDER")
    f.seps[i]:SetColorTexture(1, 1, 1, 0.12)
  end
  for i = 1, 7 do
    f.dayLabels[i] = Text(f, "GameFontDisableSmall", "CENTER")
    f.dayLabels[i]:SetText(DAY_NAME[DAY_ORDER[i]])
  end
  f.scaleTop = Text(plot, "GameFontDisableSmall")
  f.scaleTop:SetPoint("TOPLEFT", 4, -3)
  f.scaleBottom = Text(plot, "GameFontDisableSmall")
  f.scaleBottom:SetPoint("BOTTOMLEFT", 4, 3)
  f.empty = Text(plot, "GameFontDisable", "CENTER")
  f.empty:SetPoint("CENTER")
  f.empty:SetWidth(260)
  f.legend = Text(f, "GameFontDisableSmall")
  f.legend:SetPoint("TOPLEFT", 2, -(STRIP_PLOT_H + 16))
  f.readout = Text(f, "GameFontHighlightSmall")
  f.readout:SetPoint("TOPLEFT", 2, -(STRIP_PLOT_H + 31))
  f.readout:SetPoint("TOPRIGHT", -2, -(STRIP_PLOT_H + 31))
  f.readout:SetWordWrap(true)
  f.readout:SetMaxLines(3)
  f.readout:SetSpacing(2)
  f.readout:SetJustifyV("TOP")

  -- The hour of the week under the mouse.
  local function SlotUnderCursor()
    local left, scale = plot:GetLeft(), plot:GetEffectiveScale()
    if not left or not scale or scale == 0 then return nil end
    local x = GetCursorPosition() / scale - left
    local count = f.mode == "day" and 24 or 168
    return max(0, min(count - 1, floor(x / plot:GetWidth() * count)))
  end
  plot:EnableMouse(true)
  plot:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then return end
    f.dragging = true
    local slot = SlotUnderCursor()
    if slot then ns.Safe(SelectWeekHour, f, slot) end
  end)
  plot:SetScript("OnMouseUp", function(_, button)
    f.dragging = false
    if button ~= "LeftButton" then UI.NavButton(button) end
  end)
  plot:SetScript("OnHide", function() f.dragging = false end)
  plot:SetScript("OnUpdate", function()
    if not f.dragging then return end
    if not IsMouseButtonDown("LeftButton") then
      f.dragging = false
      return
    end
    local slot = SlotUnderCursor()
    if slot and slot ~= f.selected then ns.Safe(SelectWeekHour, f, slot) end
  end)
  plot:EnableMouseWheel(true)
  plot:SetScript("OnMouseWheel", function(_, delta)
    ns.Safe(SelectWeekHour, f, (f.selected or 0) + (delta > 0 and -1 or 1))
  end)
  Tip(plot, "Price by time of week or day",
    "Every recent scan is placed on its hour and moved to today's price level (dots; newer are "
    .. "brighter). The gold curve is the usual price at each time with its likely range behind it. "
    .. "The blue curve, when it differs, is the projection for the coming week or day with the "
    .. "current trend carried on. Click, drag or scroll to pick a time.")
  f.Select = function(index) SelectWeekHour(f, index) end
  return f
end

-- Moves the strip's selector and reads the selected time; nothing is redrawn.
local function MoveStripSelector(f, id)
  local sel = TrendSelection()
  local dayMode = f.mode == "day"
  local count = dayMode and 24 or 168
  f.selected = dayMode and sel.hour or (DayPosition(sel.day) * 24 + sel.hour)
  local slotW = f.plot:GetWidth() / count
  f.selLine:ClearAllPoints()
  f.selLine:SetPoint("BOTTOM", f.plot, "BOTTOMLEFT", (f.selected + 0.5) * slotW, 0)
  f.selLine:SetSize(1.5, STRIP_PLOT_H)
  f.readout:SetText(id and (UI.TrendReadout(id, dayMode and "hour" or "week", true)) or "")
end
UI.MoveStripSelector = MoveStripSelector

-- Draws the folded picture: every recent scan placed on its hour of the
-- week (or of the day) at today's price level, the usual curve through
-- them with its likely range, and the projection for the coming week (or
-- day) with the current trend carried forward.
function UI.UpdateWeekStrip(f, id)
  local plot = f.plot
  local dayMode = f.mode == "day"
  local count = dayMode and 24 or 168
  local W, H = plot:GetWidth(), STRIP_PLOT_H
  local slotW = W / count
  for i = 1, 7 do
    local label = f.dayLabels[i]
    label:ClearAllPoints()
    if dayMode then
      label:SetText(i <= 4 and HourText((i - 1) * 6) or "")
      label:SetPoint("TOP", plot, "BOTTOMLEFT", ((i - 1) * 6 + 0.5) * slotW, -3)
    else
      label:SetText(DAY_NAME[DAY_ORDER[i]])
      label:SetPoint("TOP", plot, "BOTTOMLEFT", (i - 0.5) * 24 * slotW, -3)
    end
  end
  for i = 1, 6 do
    f.seps[i]:ClearAllPoints()
    f.seps[i]:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", i * 24 * slotW, 0)
    f.seps[i]:SetSize(1, H)
    f.seps[i]:SetShown(not dayMode)
  end

  local week = id and ns.Stats.Week(id)
  local usual, lows, highs, nexts = {}, {}, {}, {}
  local lo, hi = math.huge, 0
  local nowHour, today = tonumber(date("%H")) or 0, tonumber(date("%w")) or 0
  local differs = false
  if week then
    for index = 0, count - 1 do
      local est, projected
      if dayMode then
        est = ns.Stats.WeekAt(week, nil, index)
        local ahead = (index - nowHour) % 24
        projected = ns.Stats.Forecast(id, (ahead + 0.5) / 24)
      else
        est = ns.Stats.WeekAt(week, DAY_ORDER[floor(index / 24) + 1], index % 24)
        projected = est.next and est.next.price
      end
      usual[index], lows[index], highs[index], nexts[index] = est.price, est.lo, est.hi, projected or est.price
      lo, hi = min(lo, est.lo, nexts[index]), max(hi, est.hi, nexts[index])
      if math.abs(nexts[index] / est.price - 1) > 0.015 then differs = true end
    end
  end
  -- Recent scans, moved to today's level so that old and new can be compared.
  local dots = {}
  if week then
    local entry = ns.Stats.ForItem(id)
    local levelNow = ns.Stats.Eval(entry.model, 0, true)
    local series = entry.series
    for i = #series, max(1, #series - 139), -1 do
      local age = (entry.now - series[i][1]) / 86400
      if age > 28 then break end
      local level = ns.Stats.Eval(entry.model, -age, true)
      local price = series[i][2] * math.exp(levelNow - level)
      local tm = date("*t", series[i][1])
      local slot = dayMode and (tm.hour + tm.min / 60) or (DayPosition(tm.wday - 1) * 24 + tm.hour + tm.min / 60)
      dots[#dots + 1] = { slot, price, age }
      lo, hi = min(lo, price), max(hi, price)
    end
  end
  local nLine, nDot = 0, 0
  if week and hi > 0 then
    local pad = max(hi - lo, hi * 0.04) * 0.08
    lo, hi = max(0, lo - pad), hi + pad
    local function Y(price) return max(0, min(H, (price - lo) / (hi - lo) * H)) end
    local function Line(x1, y1, x2, y2, r, g, b, a, thickness)
      nLine = nLine + 1
      local line = f.lines[nLine]
      if not line then
        line = plot:CreateLine(nil, "ARTWORK")
        f.lines[nLine] = line
      end
      line:SetColorTexture(r, g, b, a)
      line:SetThickness(thickness)
      line:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
      line:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
      line:Show()
    end
    for index = 0, count - 1 do
      -- The likely range as a faint column behind the curve.
      local bar = f.bars[index + 1]
      if not bar then
        bar = plot:CreateTexture(nil, "BORDER")
        f.bars[index + 1] = bar
      end
      local y1, y2 = Y(lows[index]), Y(highs[index])
      bar:ClearAllPoints()
      bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", index * slotW, y1)
      bar:SetSize(slotW + 0.5, max(1, y2 - y1))
      bar:SetColorTexture(1, 0.82, 0, 0.10)
      bar:Show()
      if index > 0 then
        local x1, x2 = (index - 0.5) * slotW, (index + 0.5) * slotW
        Line(x1, Y(usual[index - 1]), x2, Y(usual[index]), 1, 0.82, 0, 0.95, 1.4)
        if differs then
          Line(x1, Y(nexts[index - 1]), x2, Y(nexts[index]), 0.45, 0.75, 1, 0.9, 1.2)
        end
      end
    end
    for _, dot in ipairs(dots) do
      nDot = nDot + 1
      local tex = f.dots[nDot]
      if not tex then
        tex = plot:CreateTexture(nil, "OVERLAY")
        tex:SetSize(3, 3)
        f.dots[nDot] = tex
      end
      -- The newer the scan, the brighter its dot.
      tex:SetColorTexture(1, 1, 1, max(0.2, 0.95 - dot[3] / 28 * 0.75))
      tex:ClearAllPoints()
      tex:SetPoint("CENTER", plot, "BOTTOMLEFT", dot[1] * slotW, Y(dot[2]))
      tex:Show()
    end
    f.empty:Hide()
    f.scaleTop:SetText(ns.Money(hi))
    f.scaleBottom:SetText(ns.Money(lo))
    f.legend:SetText(GOLD .. "usual|r" .. (differs and "  |cff73bfffnext " .. (dayMode and "24 h" or "7 days") .. "|r" or "")
      .. "  " .. GREY .. "dots: scans,|r " .. UI.ScanAgeText(id))
  else
    f.empty:SetText("No price recorded yet.")
    f.empty:Show()
    f.scaleTop:SetText("")
    f.scaleBottom:SetText("")
    f.legend:SetText("")
  end
  for i = (week and hi > 0) and (count + 1) or 1, #f.bars do f.bars[i]:Hide() end
  for i = nLine + 1, #f.lines do f.lines[i]:Hide() end
  for i = nDot + 1, #f.dots do f.dots[i]:Hide() end
  f.nLine, f.nDot, f.differs = nLine, nDot, differs

  local nowSlot = dayMode and nowHour or (DayPosition(today) * 24 + nowHour)
  f.nowMark:ClearAllPoints()
  f.nowMark:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", nowSlot * slotW, 0)
  f.nowMark:SetSize(max(slotW, 1), H)
  MoveStripSelector(f, id)
end

-- How old the newest scan of an item is, in words; orange once it is old
-- enough that the picture may have moved on.
function UI.ScanAgeText(id)
  local info = ns.Market.Info(id)
  if not info or info.source ~= "scan" or not info.age then
    return "|cffff8c33never scanned by you|r"
  end
  local text = "latest " .. ns.Age(info.age)
  if info.age > 2 * 3600 then return "|cffff8c33" .. text .. "|r" end
  return GREY .. text .. "|r"
end

-- "in 3 h", "in 2 days": how far ahead a moment is.
function UI.AheadText(days)
  local hours = days * 24
  if hours < 1 then return "within the hour" end
  if hours < 36 then return "in " .. ns.Round(hours) .. " h" end
  return "in " .. ns.Round(days) .. " days"
end

-- The selected time in words, and the estimate for it.
-- Returns the readout text and the estimate (nil without a price).
-- mode: "hour", "day" or "week" (default: the Trends view's). compact: the
-- short form for the side panel.
function UI.TrendReadout(id, mode, compact)
  mode = mode or trendPeriod
  local sel = TrendSelection()
  local day = mode ~= "hour" and sel.day or nil
  local hour = mode ~= "day" and sel.hour or nil
  if compact then
    local when = day and (DAY_LONG[day] .. " " .. HourText(hour)) or (HourText(hour) .. ", any day")
    local week = ns.Stats.Week(id)
    if not week then return GOLD .. when .. "|r\n" .. GREY .. "No price recorded yet.|r", nil end
    local est = ns.Stats.WeekAt(week, day, hour)
    local text = GOLD .. when .. ":|r usually " .. ns.Money(est.price) .. GREY .. " (" .. ns.Money(est.lo)
      .. " to " .. ns.Money(est.hi) .. ")|r\n"
    if est.next then
      text = text .. "|cff73bfffNext one, " .. UI.AheadText(est.next.days) .. ":|r " .. ns.Money(est.next.price)
        .. GREY .. " (" .. ns.Money(est.next.lo) .. " to " .. ns.Money(est.next.hi) .. ")|r\n"
    else
      text = text .. "That is " .. Percent(est.rel) .. ".\n"
    end
    text = text .. GREY
    if not est.hourGap and not est.dayGap then
      return text .. "No time pattern yet: this is today's level.|r", est
    end
    local function Basis(n, gap, one, many, none)
      if n and n > 0 then return "seen " .. (n == 1 and one or (n .. " " .. many)) end
      return gap and (none .. " (filled in)") or ("no pattern " .. none)
    end
    local basis = Basis(est.hourN, est.hourGap, "on 1 day at this hour", "days at this hour", "this hour not seen")
    if day then
      basis = basis .. ", " .. Basis(est.dayN, est.dayGap, "1 " .. DAY_LONG[day], DAY_LONG[day] .. "s",
        DAY_LONG[day] .. "s not seen")
    end
    return text .. basis:sub(1, 1):upper() .. basis:sub(2) .. ".|r", est
  end
  local when
  if day and hour then
    when = DAY_LONG[day] .. " " .. HourText(hour) .. " to " .. HourText((hour + 1) % 24)
  elseif hour then
    when = HourText(hour) .. " to " .. HourText((hour + 1) % 24) .. ", any day"
  else
    when = DAY_LONG[day] .. "s, whole day"
  end
  local week = ns.Stats.Week(id)
  if not week then return GOLD .. when .. ":|r no price recorded yet.", nil end
  local est = ns.Stats.WeekAt(week, day, hour)
  local function Basis(n, gap, one, many, around)
    if n and n > 0 then return n .. " " .. (n == 1 and one or many) end
    if gap then return "no scan " .. around .. " yet (filled in from the nearest that have one)" end
    return nil
  end
  local basis = {}
  if hour then basis[#basis + 1] = Basis(est.hourN, est.hourGap, "day with scans at this hour", "days with scans at this hour", "at this hour") end
  if day then
    local name = DAY_LONG[day] .. "s"
    basis[#basis + 1] = Basis(est.dayN, est.dayGap, DAY_LONG[day] .. " compared with its week", name .. " compared with their weeks", "on " .. name)
  end
  local text = GOLD .. when .. ":|r about " .. ns.Money(est.price) .. ", likely between "
    .. ns.Money(est.lo) .. " and " .. ns.Money(est.hi) .. ". "
  if #basis == 0 then
    text = text .. GREY .. "No time pattern yet, so this is just its usual price.|r"
  else
    text = text .. "That is " .. Percent(est.rel) .. " of " .. ns.Money(week.base) .. ". "
    if est.next and math.abs(est.next.price / est.price - 1) >= 0.02 then
      text = text .. "|cff73bfffWith the current trend, the next one (" .. UI.AheadText(est.next.days) .. ") is nearer "
        .. ns.Money(est.next.price) .. ".|r "
    end
    text = text .. GREY .. "From " .. table.concat(basis, " and ") .. ".|r"
  end
  return text, est
end

function UI.UpdateTrends()
  if not trends or not trends:IsShown() then return end
  local f = trends
  local id = state.center
  for key, b in pairs(f.options) do
    local on = key == ("period:" .. trendPeriod) or key == ("measure:" .. trendMeasure)
    if on then b:LockHighlight() else b:UnlockHighlight() end
  end
  if not id then
    f.title:SetText("Trends")
    f.title:SetTextColor(1, 0.82, 0)
    f.facts:SetText("Pick an item first: search for it, or click one in the graph or a list.")
    f.chart:Hide()
    f.chartNote:SetText("")
    f.readout:SetText("")
    f.optionNote:SetText("")
    f.stackNote:SetText("")
    f.sellerNote:SetText("")
    HideShareRows(f.stackRows, 1)
    HideShareRows(f.sellerRows, 1)
    return
  end
  f.chart:Show()
  local r, g, b = ns.ItemColor(id)
  f.title:SetText(ns.ItemName(id))
  f.title:SetTextColor(r, g, b)

  -- Facts in words.
  local it = ns.Market.Get(id)
  local t = ns.Stats.Trend(id)
  local facts = {}
  if not t then
    facts[#facts + 1] = "No price has been recorded for this yet. Scan it at the auction house."
  else
    -- What the last scan actually saw comes first; the estimates follow.
    local info = ns.Market.Info(id)
    if info and info.source == "scan" and info.age then
      facts[#facts + 1] = (info.price and ("Cheapest listed " .. ns.Money(info.price) .. " (" .. (info.total or 0) .. " on sale)")
        or "None on sale") .. ", " .. UI.ScanAgeText(id) .. "."
    end
    local line = "Estimate now about " .. ns.Money(t.now)
    if t.vsUsual then
      line = line .. ", " .. Percent(t.vsUsual) .. " of " .. ns.Money(t.usual) .. " (last 14 days)"
    end
    facts[#facts + 1] = line .. "."
    if t.perDay then
      local p = ns.Round(math.abs(t.perDay) * 100)
      facts[#facts + 1] = (p == 0 and "Steady over the last week"
        or ((t.perDay > 0 and "Rising" or "Falling") .. " about " .. p .. "% a day over the last week"))
        .. " (" .. t.trendScans .. " scans). It typically moves about \194\177" .. ns.Round(t.swing * 100) .. "% a day."
    else
      facts[#facts + 1] = "Too few scans over the last week to call a direction yet (" .. t.scans
        .. " in all). A direction needs four scans over at least a day."
    end
  end

  -- How fast it sells, from the auctions that vanished between full scans.
  do
    local sales = ns.Market.Sales(id)
    if sales then
      local function N(x) return x >= 10 and ns.Round(x) or string.format("%.1f", x) end
      local watched = sales.days >= 1 and (N(sales.days) .. " days") or (ns.Round(sales.days * 24 * 10) / 10 .. " h")
      if sales.floor then
        facts[#facts + 1] = "Sells at least " .. N(sales.lo) .. " a day: most of what was cheap enough went between "
          .. "full scans, so more sold unseen (" .. watched .. " watched). Scan more often for a real figure."
      else
        facts[#facts + 1] = "Sells about " .. N(sales.rate) .. " a day (" .. N(sales.lo) .. " to " .. N(sales.hi)
          .. "), judged from " .. N(sales.units) .. " sold over " .. watched .. " between full scans."
      end
    end
  end

  -- The bar chart.
  local weekMode = trendPeriod == "week"
  local slots = trendPeriod == "hour" and 24 or weekMode and 168 or 7
  local tally, fromOnline = ns.Market.Tally(id, trendPeriod == "day" and "wd" or "hd")
  local pattern = ns.Stats.Pattern(tally, trendPeriod == "day" and 7 or 24)
  local W, H = f.chart:GetWidth(), f.chart:GetHeight()
  local slotW = W / slots
  local nowHour, today = tonumber(date("%H")) or 0, tonumber(date("%w")) or 0
  local nowSlot
  if trendPeriod == "hour" then
    nowSlot = nowHour
  elseif weekMode then
    nowSlot = DayPosition(today) * 24 + nowHour
  else
    nowSlot = DayPosition(today)
  end
  -- The whole week is an estimate for every hour of every day, built from
  -- the hour-of-day and weekday patterns together.
  local week = ns.Stats.Week(id)
  if week and not weekMode then
    -- The same hour and weekday effects the estimates use.
    pattern = trendPeriod == "day" and week.days or week.hours
  end
  if weekMode then
    local dayPattern = ns.Stats.Pattern((ns.Market.Tally(id, "wd")), 7)
    local combined = { slots = {}, scans = max(pattern.scans, dayPattern.scans), filled = 0,
      hours = pattern.filled, days = dayPattern.filled }
    if week and (pattern.filled > 0 or dayPattern.filled > 0) then
      for index = 0, 167 do
        local est = ns.Stats.WeekAt(week, DAY_ORDER[floor(index / 24) + 1], index % 24)
        -- Solid only where both the hour and the weekday have real scans.
        local n = min(est.hourN or 0, (est.dayN or 0) * 2)
        combined.slots[index] = { n = n, price = est.rel, listed = est.listed or 0, est = est }
        combined.filled = combined.filled + 1
      end
    end
    pattern = combined
  end
  local maxAbs, maxListed = 0.05, 1
  for _, sl in pairs(pattern.slots) do
    maxAbs = max(maxAbs, math.abs(sl.price))
    maxListed = max(maxListed, sl.listed)
  end
  local priceMode = trendMeasure == "price"
  local base = priceMode and (H - 18) / 2 + 18 or 18
  local span = priceMode and (H - 18) / 2 - 14 or (H - 18 - 16)
  f.baseline:ClearAllPoints()
  f.baseline:SetPoint("BOTTOMLEFT", f.chart, "BOTTOMLEFT", 0, base)
  f.baseline:SetPoint("BOTTOMRIGHT", f.chart, "BOTTOMRIGHT", 0, base)
  f.baseline:SetShown(pattern.filled > 0)
  local cheapest, dearest
  for index = 0, slots - 1 do
    local key = trendPeriod == "day" and DAY_ORDER[index + 1] or index
    local sl = pattern.slots[key]
    local bar = f.bars[index + 1]
    if not bar then
      bar = f.chart:CreateTexture(nil, "ARTWORK")
      f.bars[index + 1] = bar
      local label = Text(f.chart, "GameFontDisableSmall", "CENTER")
      f.barLabels[index + 1] = label
      local hit = CreateFrame("Frame", nil, f.chart)
      hit:EnableMouse(true)
      hit:SetScript("OnEnter", function(self)
        if not self.title then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.title)
        for _, text in ipairs(self.lines or {}) do GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
      end)
      hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
      -- Click or drag across the bars to move the selector; the wheel steps it.
      hit:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then ns.Safe(UI.SelectTrendSlot, self.index) end
      end)
      hit:HookScript("OnEnter", function(self)
        if IsMouseButtonDown("LeftButton") then ns.Safe(UI.SelectTrendSlot, self.index) end
      end)
      hit:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then UI.NavButton(button) end
      end)
      hit:EnableMouseWheel(true)
      hit:SetScript("OnMouseWheel", function(_, delta)
        ns.Safe(UI.SelectTrendSlot, SelectedSlot() + (delta > 0 and -1 or 1))
      end)
      f.barHits[index + 1] = hit
    end
    local label, hit = f.barLabels[index + 1], f.barHits[index + 1]
    hit.index = index
    local x = index * slotW
    local inset, fill = 0.15, 0.7
    if weekMode then inset, fill = 0.05, 0.9 end
    label:ClearAllPoints()
    label:SetPoint("BOTTOM", f.chart, "BOTTOMLEFT", x + slotW / 2, 3)
    if trendPeriod == "hour" then
      label:SetText(index % 3 == 0 and tostring(index) or "")
    elseif weekMode then
      label:SetText(index % 24 == 12 and DAY_NAME[DAY_ORDER[floor(index / 24) + 1]] or "")
    else
      label:SetText(DAY_NAME[key])
    end
    label:Show()
    hit:ClearAllPoints()
    hit:SetPoint("BOTTOMLEFT", f.chart, "BOTTOMLEFT", x, 0)
    hit:SetSize(slotW, H)
    hit:Show()
    local slotName
    if trendPeriod == "hour" then
      slotName = HourText(key) .. " to " .. HourText((key + 1) % 24)
    elseif weekMode then
      slotName = DAY_LONG[DAY_ORDER[floor(index / 24) + 1]] .. " " .. HourText(index % 24)
    else
      slotName = DAY_LONG[key]
    end
    hit.title = slotName
    bar:ClearAllPoints()
    if sl then
      -- The more scans a bar rests on, the more solid it is drawn.
      local alpha = 0.3 + 0.7 * min(1, sl.n / 5)
      local height
      if priceMode then
        height = sl.price / maxAbs * span
        if sl.price < 0 then
          bar:SetColorTexture(0.35, 0.9, 0.35, alpha)      -- cheaper than usual
          bar:SetPoint("TOPLEFT", f.chart, "BOTTOMLEFT", x + slotW * inset, base)
        else
          bar:SetColorTexture(1, 0.5, 0.25, alpha)         -- dearer than usual
          bar:SetPoint("BOTTOMLEFT", f.chart, "BOTTOMLEFT", x + slotW * inset, base)
        end
        if not cheapest or sl.price < pattern.slots[cheapest].price then cheapest = key end
        if not dearest or sl.price > pattern.slots[dearest].price then dearest = key end
      else
        height = sl.listed / maxListed * span
        bar:SetColorTexture(0.45, 0.75, 1, alpha)
        bar:SetPoint("BOTTOMLEFT", f.chart, "BOTTOMLEFT", x + slotW * inset, base)
      end
      bar:SetSize(slotW * fill, max(1.5, math.abs(height)))
      bar:Show()
      if sl.est then
        hit.lines = {
          "About " .. ns.Money(sl.est.price) .. " (" .. ns.Money(sl.est.lo) .. " to " .. ns.Money(sl.est.hi) .. ")",
          "Price: " .. Percent(sl.price),
          "Listed: about " .. ns.Round(sl.listed),
          "Estimated from the hour and the weekday together. Click to select.",
        }
      else
        hit.lines = {
          "Price: " .. Percent(sl.price),
          "Listed: about " .. ns.Round(sl.listed),
          "Seen on " .. sl.n .. (sl.n == 1 and " day (too few to trust)" or " days"),
          "Click to select.",
        }
      end
    else
      bar:Hide()
      hit.lines = { "No scan at this time yet.", "Click to select and see a filled-in estimate." }
    end
  end
  for index = slots + 1, #f.bars do
    f.bars[index]:Hide()
    f.barLabels[index]:Hide()
    f.barHits[index]:Hide()
  end
  f.nowMark:ClearAllPoints()
  if nowSlot then
    f.nowMark:SetPoint("BOTTOMLEFT", f.chart, "BOTTOMLEFT", nowSlot * slotW, 0)
    f.nowMark:SetSize(slotW, H)
    f.nowMark:Show()
  else
    f.nowMark:Hide()
  end
  -- The selector and what it reads.
  local selSlot = SelectedSlot()
  f.selMark:ClearAllPoints()
  f.selMark:SetPoint("BOTTOMLEFT", f.chart, "BOTTOMLEFT", selSlot * slotW, 0)
  f.selMark:SetSize(max(slotW, 2), H)
  f.selLine:ClearAllPoints()
  f.selLine:SetPoint("BOTTOM", f.chart, "BOTTOMLEFT", (selSlot + 0.5) * slotW, 0)
  f.selLine:SetSize(weekMode and 1.5 or 2, H)
  for i, sep in ipairs(f.daySeps) do
    sep:ClearAllPoints()
    sep:SetPoint("BOTTOMLEFT", f.chart, "BOTTOMLEFT", i * 24 * slotW, 0)
    sep:SetSize(1, H)
    sep:SetShown(weekMode)
  end
  f.readout:SetText((UI.TrendReadout(id)))
  if pattern.filled == 0 then
    f.scaleTop:SetText("")
    f.scaleBottom:SetText("")
  elseif priceMode then
    f.scaleTop:SetText("+" .. ns.Round(maxAbs * 100) .. "% dearer")
    f.scaleBottom:SetText("-" .. ns.Round(maxAbs * 100) .. "% cheaper")
  else
    f.scaleTop:SetText(ns.Round(maxListed) .. " listed")
    f.scaleBottom:SetText("")
  end
  local unit = trendPeriod == "day" and "days" or "hours"
  if pattern.filled == 0 then
    f.chartEmpty:SetText("No pattern yet. Each full scan adds one sample for the hour and day it is made.")
    f.chartEmpty:Show()
    f.chartNote:SetText("")
  else
    f.chartEmpty:Hide()
    if weekMode then
      f.chartNote:SetText("Each hour of the week, estimated from " .. pattern.hours .. " of 24 hours and "
        .. pattern.days .. " of 7 weekdays with scans. Faint bars are filled in. Drag or scroll to move the selector.")
    else
      f.chartNote:SetText("From " .. pattern.scans .. " price points covering " .. pattern.filled .. " different " .. unit
        .. ". Faint bars rest on few days. Drag or scroll to move the selector.")
    end
    if weekMode then
      if priceMode and cheapest and dearest and cheapest ~= dearest then
        local function name(index) return DAY_LONG[DAY_ORDER[floor(index / 24) + 1]] .. " around " .. HourText(index % 24) end
        facts[#facts + 1] = "Over the week it looks cheapest on " .. name(cheapest) .. " (about "
          .. ns.Money(pattern.slots[cheapest].est.price) .. ") and dearest on " .. name(dearest) .. " (about "
          .. ns.Money(pattern.slots[dearest].est.price) .. ")."
      end
    elseif priceMode and pattern.filled >= 2 and cheapest ~= dearest then
      local function name(key) return trendPeriod == "hour" and ("around " .. HourText(key)) or ("on " .. DAY_LONG[key] .. "s") end
      facts[#facts + 1] = "So far cheapest " .. name(cheapest) .. " (" .. Percent(pattern.slots[cheapest].price)
        .. ") and dearest " .. name(dearest) .. " (" .. Percent(pattern.slots[dearest].price) .. ")."
    elseif pattern.filled < 2 then
      facts[#facts + 1] = "Scans so far cover " .. pattern.filled .. " of " .. slots .. " " .. unit
        .. ", too few to compare times. Scan at other times to fill it in."
    end
  end
  f.optionNote:SetText(priceMode and "green = cheaper than usual, orange = dearer" or "average units listed")
  f.facts:SetText(table.concat(facts, " "))

  -- Stack sizes.
  local stacks = it and it.bs
  local nStack = 0
  if stacks and stacks[1] then
    local total = 0
    for i = 2, #stacks, 2 do total = total + stacks[i] end
    f.stackNote:SetText("")
    for i = 1, #stacks, 2 do
      nStack = nStack + 1
      local row = f.ShareRow(f.stackRows, nStack, 14, 56, 200)
      local share = stacks[i + 1] / total
      row.label:SetText("x" .. stacks[i])
      row.track:Show()
      row.bar:SetColorTexture(1, 0.82, 0, 0.75)
      row.bar:SetWidth(max(1.5, row.barWidth * share))
      row.bar:Show()
      row.value:SetText(ns.Round(share * 100) .. "%")
    end
  else
    f.stackNote:SetText("Not known yet. Stack sizes come from full scans, which see each auction separately.")
  end
  HideShareRows(f.stackRows, nStack + 1)

  -- Sellers.
  local salesSeen = ns.Market.Sales(id)
  local sellers = it and it.sl
  local nSeller = 0
  if sellers and sellers[1] then
    local listed = max(1, it.ln or 0)
    local named = 0
    for i = 2, #sellers, 2 do named = named + sellers[i] end
    listed = max(listed, named)
    f.sellerTitle:SetText("Sellers at the last scan: " .. (it.sn or 0))
    f.sellerNote:SetText("")
    for i = 1, #sellers, 2 do
      nSeller = nSeller + 1
      local row = f.ShareRow(f.sellerRows, nSeller, 400, 120, 120)
      local share = sellers[i + 1] / listed
      local seen = it.sp and it.sp[sellers[i]] or 1
      row.label:SetText(sellers[i])
      row.track:Show()
      row.bar:SetColorTexture(0.45, 0.75, 1, 0.75)
      row.bar:SetWidth(max(1.5, row.barWidth * min(1, share)))
      row.bar:Show()
      local soldBy = salesSeen and salesSeen.sellers and salesSeen.sellers[sellers[i]]
      row.value:SetText(ns.Round(sellers[i + 1]) .. GREY .. " (" .. ns.Round(share * 100) .. "%), seen " .. seen .. "x|r"
        .. ((soldBy and soldBy >= 0.5) and (" |cff40ff40sold ~" .. ns.Round(soldBy) .. "|r") or ""))
    end
  else
    f.sellerTitle:SetText("Sellers at the last scan")
    f.sellerNote:SetText("Not known yet. Seller names come with a scan when the game provides them; "
      .. "looking the item up with Scan prices usually does.")
  end
  HideShareRows(f.sellerRows, nSeller + 1)
  ns.QueueTruncationCheck()
end

-- The main area shows one of four things: "graph", "worth", "sell" or "trends".
local function CurrentMode()
  if worth and worth:IsShown() then return "worth" end
  if sell and sell:IsShown() then return "sell" end
  if trends and trends:IsShown() then return "trends" end
  return "graph"
end

local function SetMode(mode)
  if not worth then return end
  worth:SetShown(mode == "worth")
  sell:SetShown(mode == "sell")
  trends:SetShown(mode == "trends")
  view:SetShown(mode == "graph")
  worthButton:SetText(mode == "worth" and "Show graph" or "Opportunities")
  sellButton:SetText(mode == "sell" and "Show graph" or "Sell bags")
  trendsButton:SetText(mode == "trends" and "Show graph" or "Trends")
  if mode == "trends" then ns.Safe(UI.UpdateTrends) end
  if mode == "worth" then
    worth.offset = 0
    ns.Safe(UI.UpdateWorth)
  elseif mode == "sell" then
    sell.offset = 0
    sellSkip = {}
    ns.Safe(UI.UpdateSell)
    -- At the auction house, bring the prices of what is listed up to date.
    if ns.Market.ahOpen then
      local ids = {}
      for _, d in ipairs((ns.Jobs.BagSales())) do
        if d.old and not d.reserved and #ids < 40 then ids[#ids + 1] = d.id end
      end
      if #ids > 0 then ns.Market.ScanItems(ids) end
    end
  end
end

local function SetWorthShown(show)
  SetMode(show and "worth" or "graph")
end

function UI.ShowTrends(show, quiet)
  if not trends then return end
  if show == nil then show = not trends:IsShown() end
  SetMode(show and "trends" or "graph")
  if not quiet then UI.Remember() end
end

function UI.ShowSell(show, quiet)
  if not sell then return end
  if show == nil then show = not sell:IsShown() end
  SetMode(show and "sell" or "graph")
  if not quiet then UI.Remember() end
end

-- quiet: do not add a history step (the caller is about to move on).
function UI.ShowWorth(show, quiet)
  if not worth then return end
  if show == nil then show = not worth:IsShown() end
  SetWorthShown(show)
  if not quiet then UI.Remember() end
end

------------------------------------------------------------------------------
-- History: every view visited (an item's graph, or the worth-crafting list)
-- can be stepped through with Back and Forward or the mouse's side buttons.
------------------------------------------------------------------------------
local function UpdateNav()
  if not frame then return end
  frame.back:SetEnabled(state.pos > 1)
  frame.forward:SetEnabled(state.pos < #state.hist)
end

function UI.Remember()
  local v = { id = state.center, mode = CurrentMode() }
  if not v.id and v.mode == "graph" then return end
  local cur = state.hist[state.pos]
  if cur and cur.id == v.id and cur.mode == v.mode then return end
  for i = #state.hist, state.pos + 1, -1 do state.hist[i] = nil end
  state.hist[#state.hist + 1] = v
  if #state.hist > 60 then table.remove(state.hist, 1) end
  state.pos = #state.hist
  UpdateNav()
end

local function ShowView(v)
  state.center = v.id
  state.expandLeft = false
  if v.id then ns.settings.lastItem = v.id end
  SetMode(v.mode)
  UI.Refresh(true)
end

function UI.Back()
  if state.pos > 1 then
    state.pos = state.pos - 1
    ShowView(state.hist[state.pos])
  end
end

function UI.Forward()
  if state.pos < #state.hist then
    state.pos = state.pos + 1
    ShowView(state.hist[state.pos])
  end
end

-- Handles the mouse's side buttons. Returns true when it was one of them.
function UI.NavButton(button)
  if button == "Button4" then
    UI.Back()
    return true
  elseif button == "Button5" then
    UI.Forward()
    return true
  end
  return false
end

------------------------------------------------------------------------------
-- Pins and the small tracker (HUD). Each pinned item shows its next step:
-- buy at auction, collect mail, buy from a vendor, craft, post.
------------------------------------------------------------------------------
local hud
local HUD_W, HUD_ROW = 370, 66
local KIND_COLOR = {
  ah = { 1, 0.82, 0 }, mail = { 0.45, 0.75, 1 }, vendor = { 0.4, 1, 0.4 }, craft = { 1, 0.6, 0.25 },
  sell = { 0.4, 1, 0.4 }, done = { 0.6, 0.6, 0.6 }, stuck = { 1, 0.35, 0.3 },
}

local function OpenPinned(pin)
  UI.SetQuantity(pin.qty)
  ns.Open(pin.id)
  if CurrentMode() ~= "graph" then UI.ShowWorth(false) end
end

local function CreateHUD()
  hud = CreateFrame("Frame", "CraftGraphHUD", UIParent, "BackdropTemplate")
  hud:SetSize(HUD_W, 60)
  hud:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  hud:SetBackdropColor(0.05, 0.04, 0.03, 0.9)
  hud:SetBackdropBorderColor(0.8, 0.68, 0.4, 0.9)
  local pos = ns.settings.hudPos or { "RIGHT", -60, 80 }
  hud:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3])
  hud:SetFrameStrata("MEDIUM")
  hud:SetClampedToScreen(true)
  hud:SetMovable(true)
  hud:EnableMouse(true)
  hud:RegisterForDrag("LeftButton")
  hud:SetScript("OnDragStart", hud.StartMoving)
  hud:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    if point then ns.settings.hudPos = { point, x, y } end
  end)

  hud.title = Text(hud, "GameFontNormalSmall")
  hud.title:SetPoint("TOPLEFT", 10, -8)
  hud.title:SetText("Your plan")
  hud.where = Text(hud, "GameFontDisableSmall", "RIGHT")
  hud.where:SetPoint("TOPRIGHT", -84, -8)
  -- Clearing asks once more, so a slip does not wipe the plan.
  hud.clear = Button(hud, "Clear", 54)
  hud.clear:SetHeight(17)
  hud.clear:SetPoint("TOPRIGHT", -26, -5)
  hud.clear:SetScript("OnClick", function(self)
    if self.armed and GetTime() - self.armed < 5 then
      self.armed = nil
      self:SetText("Clear")
      ns.Jobs.Clear()
      ns.Print("plan cleared: nothing is planned, and no purchases are counted as waiting in the mail.")
    else
      self.armed = GetTime()
      self:SetText("Sure?")
      C_Timer.After(5, function()
        if self.armed and GetTime() - self.armed >= 4.9 then
          self.armed = nil
          self:SetText("Clear")
        end
      end)
    end
  end)
  Tip(hud.clear, "Clear the plan", "Removes every planned item with its progress, and forgets purchases "
    .. "counted as waiting in the mailbox. Press twice to confirm.")
  local close = CreateFrame("Button", nil, hud, "UIPanelCloseButton")
  close:SetSize(22, 22)
  close:SetPoint("TOPRIGHT", 1, 1)
  close:SetScript("OnClick", function()
    ns.settings.hudHidden = true
    hud:Hide()
    ns.Print("tracker hidden. /cg hud shows it again.")
  end)

  hud.rows = {}
  for i = 1, ns.Jobs.MAX_PINS do
    local row = CreateFrame("Button", nil, hud)
    row:SetHeight(HUD_ROW - 2)
    local y = -24 - (i - 1) * HUD_ROW
    row:SetPoint("TOPLEFT", 6, y)
    row:SetPoint("TOPRIGHT", -6, y)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = Text(row, "GameFontNormalSmall")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 38, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -66, -4)
    row.name:SetWordWrap(false)
    local function Small(text, x, title, body, fn)
      local sb = Button(row, text, 19)
      sb:SetHeight(16)
      sb:SetPoint("TOPRIGHT", row, "TOPRIGHT", x, -2)
      sb:SetScript("OnClick", function()
        if row.job then ns.Safe(fn, row.job.pin) end
      end)
      Tip(sb, title, body)
      return sb
    end
    Small("-", -44, "Make fewer", "Lowers how many this plan makes. Hold Shift for steps of 10. "
      .. "Everything it still needs is worked out again.", function(pin)
        ns.Jobs.SetQty(pin.id, pin.qty - (IsShiftKeyDown() and 10 or 1))
      end)
    Small("+", -23, "Make more", "Raises how many this plan makes. Hold Shift for steps of 10. "
      .. "Everything it still needs is worked out again.", function(pin)
        ns.Jobs.SetQty(pin.id, pin.qty + (IsShiftKeyDown() and 10 or 1))
      end)
    Small("x", -2, "Remove from the plan", "Takes this item out of your plan and forgets its progress.",
      function(pin) ns.Jobs.Unpin(pin.id) end)
    row.status = Text(row, "GameFontHighlightSmall")
    row.status:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.status:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -3)
    row.status:SetWordWrap(true)
    row.status:SetMaxLines(2)
    -- The goal: what the plan should earn now, how that has moved, and
    -- what it has been over the time the plan has run.
    row.goal = Text(row, "GameFontHighlightSmall")
    row.goal:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 38, 3)
    row.goal:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 3)
    row.goal:SetWordWrap(false)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
      local job = self.job
      if not job then return end
      if button == "RightButton" then
        ns.Jobs.Unpin(job.pin.id)
      else
        ns.Safe(OpenPinned, job.pin)
      end
    end)
    row:SetScript("OnEnter", function(self)
      local job = self.job
      if not job then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText(ns.ItemName(job.pin.id) .. " x" .. job.pin.qty)
      GameTooltip:AddLine(job.text, 1, 1, 1, true)
      if job.inBags > 0 then GameTooltip:AddLine(job.inBags .. " made and in your bags.", 0.7, 0.7, 0.7) end
      if (job.pin.posted or 0) > 0 then GameTooltip:AddLine(job.pin.posted .. " posted at auction.", 0.7, 0.7, 0.7) end
      local pin = job.pin
      if pin.goal then
        GameTooltip:AddLine("Goal: " .. ns.Deals.KIND[pin.goal.kind]:lower() .. ", planned for "
          .. Signed(pin.goal.profit or 0) .. ".", 1, 0.82, 0, true)
      end
      AddProjection(ns.Jobs.Projection(pin.id, pin.qty, pin.goal))
      local st = ns.Jobs.TrackStats(pin)
      if st then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Projected profit since " .. date("%H:%M", st.since) .. " (" .. st.n
          .. (st.n == 1 and " reading)" or " readings)"), 1, 0.82, 0)
        GameTooltip:AddDoubleLine("when planned", Signed(st.first), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("now", Signed(st.last), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("median", Signed(st.median), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("average", Signed(st.mean), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("lowest to highest", Signed(st.low) .. " to " .. Signed(st.high), 1, 1, 1, 1, 1, 1)
      end
      GameTooltip:AddLine("Click to open its graph. Use - and + to change the amount, x to remove it.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    hud.rows[i] = row
  end

  hud.buy = Button(hud, "Buy all", HUD_W - 16)
  hud.buy:SetPoint("BOTTOM", 0, 8)
  hud.buy:SetScript("OnClick", function() ns.Safe(ns.Jobs.BuyFromMerchant) end)
  Tip(hud.buy, "Buy all", "Buys from this vendor everything your pinned items still need.")
  hud.buy:Hide()

  hud.mail = Button(hud, "I have collected the mail", HUD_W - 16)
  hud.mail:SetScript("OnClick", function() ns.Jobs.MailCollected() end)
  Tip(hud.mail, "Mail collected", "The plan counts what you bought at auction as waiting in the mailbox "
    .. "until it reaches your bags. Press this if you have emptied the mailbox and it still says to collect.")
  hud.mail:Hide()
end

-- One line on what a planned item should earn: now, how the last scan
-- moved it, and its median and average since the plan began.
function UI.GoalText(pin)
  local st = ns.Jobs.TrackStats(pin)
  if not st then return GREY .. "Profit: no prices to project from yet|r" end
  -- Whole silver from one gold up, so the line fits the window.
  local function Short(c) return math.abs(c) >= 10000 and ns.Round(c / 100) * 100 or ns.Round(c) end
  local text = "Profit " .. Signed(Short(st.last))
  local moved = st.last - (st.n >= 2 and st.prev or st.first)
  if st.n >= 2 and math.abs(moved) >= 1 then
    text = text .. (moved < 0 and " |cffff5040down " or " |cff40ff40up ") .. ns.Money(math.abs(Short(moved))) .. "|r"
  end
  if st.n >= 3 then
    text = text .. GREY .. "  med|r " .. Signed(Short(st.median)) .. GREY .. "  avg|r " .. Signed(Short(st.mean))
  end
  return text
end

function UI.UpdateHUD()
  if not ns.settings then return end
  local jobs = ns.Jobs.All()
  if #jobs == 0 or ns.settings.hudHidden then
    if hud then hud:Hide() end
    return
  end
  if not hud then CreateHUD() end
  for i, row in ipairs(hud.rows) do
    local job = jobs[i]
    row.job = job
    if job then
      local r, g, b = ns.ItemColor(job.pin.id)
      row.icon:SetTexture(ns.ItemIcon(job.pin.id))
      row.name:SetText(ns.ItemName(job.pin.id) .. " |cffffffffx" .. job.pin.qty .. "|r")
      row.name:SetTextColor(r, g, b)
      local c = KIND_COLOR[job.kind] or KIND_COLOR.ah
      row.status:SetText(job.text)
      row.status:SetTextColor(c[1], c[2], c[3])
      row.goal:SetText(UI.GoalText(job.pin))
      row:Show()
    else
      row:Hide()
    end
  end
  local where = ""
  if ns.Market.ahOpen then where = "at the auction house"
  elseif ns.Jobs.place == "merchant" then where = "at a vendor"
  elseif ns.Jobs.place == "mail" then where = "at the mailbox" end
  hud.where:SetText(where)
  local height = 30 + #jobs * HUD_ROW
  hud.buy:Hide()
  if ns.Jobs.place == "merchant" then
    local offer, total = ns.Jobs.MerchantOffer()
    if #offer > 0 then
      hud.buy:SetText("Buy all here: " .. ns.Money(total))
      hud.buy:Show()
      height = height + 28
    end
  end
  -- Offer to forget the mailbox count when a step is waiting on it.
  local waiting = false
  for _, job in ipairs(jobs) do
    if next(job.needs.mail) then waiting = true end
  end
  hud.mail:Hide()
  if waiting then
    hud.mail:ClearAllPoints()
    hud.mail:SetPoint("BOTTOM", 0, hud.buy:IsShown() and 34 or 8)
    hud.mail:Show()
    height = height + 26
  end
  hud:SetHeight(height)
  hud:Show()
  ns.QueueTruncationCheck()
end

local hudPending = false
local function QueueHUD()
  if hudPending then return end
  hudPending = true
  C_Timer.After(0.2, function()
    hudPending = false
    ns.Safe(UI.UpdateHUD)
  end)
end

function UI.ToggleHUD()
  ns.settings.hudHidden = not ns.settings.hudHidden or nil
  UI.UpdateHUD()
  if ns.settings.hudHidden then
    ns.Print("tracker hidden.")
  elseif #ns.Jobs.Pins() == 0 then
    ns.Print("nothing is pinned yet. Use a Pin button in the window.")
  end
end

-- Adds an item to the plan, saying first whether it is expected to pay.
-- Something that looks like a loss or a gamble needs a second press.
local confirmPlan = {}

function UI.AddToPlan(id, qty, goal)
  if goal then
    -- A trade, not a craft: it was only offered because it pays.
    if ns.Jobs.Pin(id, qty, goal) then
      ns.Print("added to your plan: " .. ns.Deals.Example({ kind = goal.kind, id = id, qty = qty,
        outlay = goal.outlay, sellEach = goal.sellEach, profit = goal.profit or 0 }) .. ".")
      return true
    end
    return false
  end
  local verdict, sentence = ns.Jobs.Verdict(id, qty)
  if verdict ~= "good" then
    local key = id .. ":" .. qty
    if not confirmPlan[key] or GetTime() - confirmPlan[key] > 8 then
      confirmPlan[key] = GetTime()
      ns.Print("|cffff8c33not added yet:|r " .. sentence .. " Press again to plan it anyway.")
      return false
    end
    confirmPlan[key] = nil
  end
  if ns.Jobs.Pin(id, qty) then
    ns.Print("added to your plan: " .. sentence)
    return true
  end
  return false
end

-- Line 4 of a graph item: what the player owns of it (bags and bank) and
-- how much of that this plan uses, with the functions that change it.
function UI.NodeStock(node)
  local id = node.id
  if not id or node.side ~= 1 or not state.job then return nil end
  local P, J = ns.Player, ns.Jobs
  local bags, bank = P.ItemCount(id), P.BankCount(id)
  local owned = bags + ((ns.settings.useBank ~= false) and bank or 0)
  if bags + bank <= 0 then return nil end
  local using = ns.Round(state.job.needs.own[id] or 0)
  local text = "Own " .. bags
  if bank > 0 then text = text .. " |cff73bfff+" .. bank .. " in bank|r" end
  text = text .. GREY .. ", using|r " .. using
  local use = state.use
  local out = { text = text, adjust = use ~= nil and owned > 0 }
  if out.adjust then
    local function step() return IsShiftKeyDown() and 10 or 1 end
    if using > 0 then
      out.less = function()
        J.SetUse(use, id, IsControlKeyDown() and 0 or max(0, using - step()))
      end
    end
    -- More only makes sense while some of it is still being bought.
    local needs = state.job.needs
    if use[id] ~= nil and (needs.ah[id] or needs.mail[id] or needs.vendor[id]) then
      out.more = function()
        local want = using + step()
        -- At or past everything owned, drop the limit altogether.
        J.SetUse(use, id, (IsControlKeyDown() or want >= owned) and nil or want)
      end
    end
  end
  return out
end

-- What one unit of an item is worth to the plan: what the plan pays for it
-- where it buys it, otherwise the cheapest way to get one.
local function UnitValue(id, plan)
  if plan then
    if plan.buy[id] and plan.buy[id] > 0 and plan.buyCost[id] then return plan.buyCost[id] / plan.buy[id] end
    if plan.vend[id] and plan.vend[id] > 0 and plan.vendCost[id] then return plan.vendCost[id] / plan.vend[id] end
  end
  return ns.Opt.UnitCost(id) or ns.Opt.SalePrice(id)
end

-- The text on a line of the graph: how many go along it and what they are
-- worth. To the right, the amount is what the whole plan sends into that
-- craft (or one craft's worth when the plan does not use the recipe). To
-- the left, it is what one of that item takes of the item it hangs on.
function UI.EdgeLabel(e)
  if not e.qty or e.qty <= 0 then return nil end
  local plan = state.job and state.job.needs and state.job.needs.plan
  local amount = e.qty
  local id = e.to
  if not e.left and plan and plan.casts[e.spell] then
    amount = e.qty * plan.casts[e.spell]
  end
  local unit = UnitValue(id, (not e.left) and plan or nil)
  local text = "x" .. ns.Round(amount)
  if unit then text = text .. "  " .. ns.Money(unit * amount) end
  return text
end

-- The step buttons for a graph item, as { [1] = auction, [2] = vendor,
-- [3] = make }. Each is { text, enabled, title, tip, fn, glow } or nil.
-- A button that makes no sense right now is greyed and says why; the one
-- that is the step to do now glows.
function UI.NodeActions(node)
  local id = node.id
  local job = state.job
  if not id or not job or node.side == -1 then return {} end
  local J, M, P = ns.Jobs, ns.Market, ns.Player
  local needs = job.needs
  local out = {}
  local isCenter = id == state.center
  local kind = job.kind

  -- Which recipe, if any, the plan uses to make this item.
  local craft
  for _, c in ipairs(needs.crafts) do
    if c.product == id then craft = c end
  end

  -- Line 1: the auction house. The centre item is sold there, the rest bought.
  if isCenter then
    local have = P.ItemCount(id)
    local a = { text = "Sell", title = "Sell at auction", enabled = false }
    if have <= 0 then
      a.tip = "There is none in your bags yet. Make it first."
    else
      a.text = "Sell " .. have
      local price, why = J.PostPrice(id)
      if not price then
        a.tip = "Not worth posting: " .. why .. "."
      elseif not M.ahOpen then
        a.tip = "Open the auction house to post " .. have .. " at about " .. ns.Money(price) .. " each."
      else
        a.enabled = true
        a.tip = "Posts what is in your bags at " .. ns.Money(price)
          .. " each, just under the cheapest listing."
        a.fn = function() J.SellAuction(id) end
        a.glow = kind == "sell" or (have > 0 and job.remaining <= 0)
      end
    end
    out[1] = a
  else
    local a = { text = "Buy", title = "Buy at auction", enabled = false }
    local qty = needs.ah[id]
    if qty then
      qty = ns.Round(qty)
      a.text = "Buy " .. qty
      if not M.ahOpen then
        a.tip = "The plan buys " .. qty .. " at auction. Open the auction house."
      else
        a.enabled = true
        a.tip = "Buys " .. qty .. " at the price the plan expects. If the price has moved up by "
          .. "more than a few percent nothing is bought."
        a.fn = function() J.BuyAuction(id, qty) end
        a.glow = kind == "ah"
      end
    elseif needs.mail[id] then
      a.text = "In mail"
      a.tip = ns.Round(needs.mail[id]) .. " already bought. Collect them from the mailbox."
    elseif needs.vendor[id] then
      a.tip = "A vendor sells this for less than the auction house."
    elseif craft then
      a.tip = "Cheaper to make than to buy at current prices."
    elseif not M.Info(id) then
      a.tip = "No auction price is known for this. Scan it first."
    else
      a.tip = "You already hold what the plan needs."
    end
    out[1] = a
  end

  -- Line 2: a vendor, for things vendors sell.
  if not isCenter and M.VendorBuy(id) then
    local a = { text = "Buy", title = "Buy from a vendor", enabled = false }
    local qty = needs.vendor[id]
    if qty then
      qty = ns.Round(qty)
      a.text = "Buy " .. qty
      local want = { [id] = qty }
      if J.place == "merchant" and #J.MerchantOffer(want, true) > 0 then
        a.enabled = true
        a.tip = "Buys " .. qty .. " from the vendor you are talking to."
        a.fn = function() J.BuyFromMerchant(want, true) end
        a.glow = kind == "vendor"
      elseif J.place == "merchant" then
        a.tip = "This vendor does not sell it. Find one that does."
      else
        a.tip = "The plan buys " .. qty .. " from a vendor. Visit one that sells it."
      end
    else
      a.tip = "Nothing more is needed from a vendor."
    end
    out[2] = a
  end

  -- Line 3: crafting.
  if ns.Opt.IsCraftable(id) then
    local a = { text = "Make", title = "Make", enabled = false }
    if craft then
      local r = ns.Opt.Recipe(craft.spell)
      local can = P.CanMake(craft.spell)
      local casts = max(1, ns.Round(craft.casts))
      a.text = "Make " .. ns.Round(casts * r[4])
      a.title = r[6]
      if not P.Knows(craft.spell) then
        a.tip = "You have not learned this recipe (" .. (ns.Data.skills[r[1]] or "?") .. ")."
      elseif can <= 0 then
        a.tip = "The materials are not all in your bags yet."
      else
        local now = min(can, casts)
        a.text = "Make " .. ns.Round(now * r[4])
        a.enabled = true
        a.tip = "Crafts " .. now .. " time" .. (now == 1 and "" or "s")
          .. " from your bags. Your profession window must be open: the first press opens it."
        a.fn = function() P.Craft(craft.spell, now) end
        a.glow = kind == "craft" and job.nextCraft == craft.spell
      end
    elseif needs.ah[id] or needs.mail[id] then
      a.tip = "Cheaper to buy than to make at current prices."
    elseif isCenter then
      a.tip = "Nothing more to make: the quantity is reached."
    else
      a.tip = "You already hold what the plan needs."
    end
    out[3] = a
  end
  return out
end

------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------
local function Create()
  frame = CreateFrame("Frame", "CraftGraphFrame", UIParent, "PortraitFrameTemplate")
  frame:SetSize(FRAME_W, FRAME_H)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  if frame.SetTitle then frame:SetTitle("CraftGraph") end
  if frame.SetPortraitToAsset then frame:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Coin_02") end
  tinsert(UISpecialFrames, "CraftGraphFrame")

  local available = UIParent:GetWidth()
  if available and available > 0 and available < FRAME_W + 20 then
    frame:SetScale(available / (FRAME_W + 20))
  end

  -- Top bar
  local back = Button(frame, "Back", 54)
  back:SetPoint("TOPLEFT", 66, -32)
  back:SetScript("OnClick", function() UI.Back() end)
  frame.back = back
  Tip(back, "Back", "Goes to the previous view. The mouse's back button does the same.")
  local forward = Button(frame, "Forward", 68)
  forward:SetPoint("LEFT", back, "RIGHT", 4, 0)
  forward:SetScript("OnClick", function() UI.Forward() end)
  frame.forward = forward
  Tip(forward, "Forward", "Goes forward again after going back. The mouse's forward button does the same.")
  frame:HookScript("OnMouseUp", function(_, button) UI.NavButton(button) end)

  search = CreateFrame("EditBox", "CraftGraphSearchBox", frame, "SearchBoxTemplate")
  search:SetSize(180, 20)
  search:SetPoint("LEFT", forward, "RIGHT", 14, 0)
  search:SetAutoFocus(false)
  search:HookScript("OnTextChanged", function(self, userInput)
    if userInput then ns.Safe(ShowResults, self:GetText()) end
  end)
  search:HookScript("OnEnterPressed", function(self)
    local id = ns.ItemIDFromText(self:GetText()) or (results:IsShown() and results.first)
    if id then
      self:SetText("")
      self:ClearFocus()
      HideResults()
      UI.Focus(id)
    end
  end)
  search:HookScript("OnEscapePressed", function(self)
    self:ClearFocus()
    HideResults()
  end)
  search:HookScript("OnEditFocusLost", function()
    C_Timer.After(0.2, HideResults)
  end)
  results = CreateResults(frame)

  local makeLabel = Text(frame, "GameFontNormal")
  makeLabel:SetPoint("LEFT", search, "RIGHT", 22, 0)
  makeLabel:SetText("Quantity")
  qtyBox = CreateFrame("EditBox", "CraftGraphQuantityBox", frame, "InputBoxTemplate")
  qtyBox:SetSize(48, 20)
  qtyBox:SetPoint("LEFT", makeLabel, "RIGHT", 10, 0)
  qtyBox:SetAutoFocus(false)
  qtyBox:SetNumeric(true)
  qtyBox:SetMaxLetters(5)
  local function CommitQty(self)
    UI.SetQuantity(tonumber(self:GetText()) or 1)
  end
  qtyBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  qtyBox:SetScript("OnEditFocusLost", CommitQty)
  qtyBox:SetScript("OnEscapePressed", function(self)
    self:SetText(tostring(ns.settings.qty or 1))
    self:ClearFocus()
  end)

  scanButton = Button(frame, "Scan prices", 104)
  scanButton:SetPoint("LEFT", qtyBox, "RIGHT", 20, 0)
  scanButton:SetScript("OnClick", function() ns.Safe(ScanView) end)
  Tip(scanButton, "Scan prices",
    "Looks up every item shown in the graph at the auction house. The auction house must be open.")
  fullButton = Button(frame, "Full scan", 84)
  fullButton:SetPoint("LEFT", scanButton, "RIGHT", 6, 0)
  fullButton:SetScript("OnClick", function() ns.Safe(ns.Market.FullScan) end)
  Tip(fullButton, "Full scan",
    "Reads the whole auction house at once. The game allows this once every 15 minutes. "
    .. "A full scan in Auctionator is recorded here too. With Auto scan ticked (under the graph, "
    .. "or beside the auction window) this happens by itself while the auction house is open.")

  -- The status line has the full width under the graph, where it cannot be cut off.
  statusText = Text(frame, "GameFontHighlightSmall", "LEFT")
  statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 10)
  statusText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PANEL_W + 16 + 270), 10)
  statusText:SetWordWrap(false)

  -- Clicking the status line opens the data sources.
  local statusHit = CreateFrame("Button", nil, frame)
  statusHit:SetPoint("TOPLEFT", statusText, "TOPLEFT", 0, 4)
  statusHit:SetPoint("BOTTOMRIGHT", statusText, "BOTTOMRIGHT", 0, -4)
  statusHit:SetScript("OnClick", function() ns.Safe(UI.ToggleSources) end)
  Tip(statusHit, "Data sources", "Click to switch data sources on and off: Blizzard's hourly data, "
    .. "Auctionator's prices, and sales seen between full scans. Also /cg sources.")

  -- Auto scan: the switch, and beside it what it is doing or waiting for.
  local auto = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  auto:SetSize(22, 22)
  auto:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", -(PANEL_W + 16 + 262), 4)
  auto:SetScript("OnClick", function(self)
    ns.settings.autoScan = self:GetChecked() and true or false
    ns.Fire("AUTOSCAN")
    if ns.settings.autoScan then ns.Safe(ns.Market.AutoTick) end
  end)
  Tip(auto, "Auto scan",
    "Collects prices by itself for as long as the auction house window stays open: a full scan the "
    .. "moment the game allows another (every 15 minutes), and your plan's and the graph's items in "
    .. "between. Leave the auction house open and this window can stay open or closed. The game "
    .. "still logs an idle character out after about half an hour.")
  local autoLabel = Text(frame, "GameFontHighlightSmall", "LEFT")
  autoLabel:SetPoint("LEFT", auto, "RIGHT", 0, 1)
  autoLabel:SetPoint("RIGHT", frame, "BOTTOMRIGHT", -(PANEL_W + 16), 15)
  autoLabel:SetWordWrap(false)
  UI.autoMain, UI.autoLabel = auto, autoLabel
  local sinceLabel = 0
  frame:HookScript("OnUpdate", function(_, elapsed)
    sinceLabel = sinceLabel + (elapsed or 0)
    if sinceLabel >= 2 then
      sinceLabel = 0
      UI.UpdateAutoLabel()
    end
  end)
  UI.UpdateAutoLabel()
  worthButton = Button(frame, "Opportunities", 112)
  worthButton:SetPoint("LEFT", fullButton, "RIGHT", 6, 0)
  worthButton:SetScript("OnClick", function() UI.ShowWorth() end)
  Tip(worthButton, "Opportunities",
    "Every way to make money right now: crafting what you know, buying low to relist, buying under "
    .. "vendor price, vendor goods that fetch more at auction, and selling from your bags. Each shows "
    .. "the amount, the cost up front, the profit and the steps, so you can judge the effort.")
  sellButton = Button(frame, "Sell bags", 84)
  sellButton:SetPoint("LEFT", worthButton, "RIGHT", 6, 0)
  sellButton:SetScript("OnClick", function() UI.ShowSell() end)
  trendsButton = Button(frame, "Trends", 76)
  trendsButton:SetPoint("LEFT", sellButton, "RIGHT", 6, 0)
  trendsButton:SetScript("OnClick", function() UI.ShowTrends() end)
  Tip(trendsButton, "Trends",
    "Patterns for the chosen item that show over time: its price or supply by hour of day or day of "
    .. "week, how listings are stacked, and who sells it.")
  Tip(sellButton, "Sell bags",
    "Lists what in your bags would fetch more at auction than from a vendor, with what you can "
    .. "expect to get, and lets you post it.")
  statusText:SetWordWrap(false)

  -- Graph area
  local inset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
  inset:SetPoint("TOPLEFT", 8, -62)
  inset:SetPoint("BOTTOMRIGHT", -(PANEL_W + 12), 28)
  view = ns.GraphView.Create(inset)
  view:SetPoint("TOPLEFT", 3, -3)
  view:SetPoint("BOTTOMRIGHT", -3, 3)
  worth = CreateWorth(inset)
  sell = CreateSell(inset)
  trends = CreateTrends(inset)

  panel = CreatePanel(frame)

  frame:SetScript("OnHide", function()
    ns.settings.wasOpen = false
  end)
  frame:SetScript("OnShow", function()
    ns.settings.wasOpen = true
    qtyBox:SetText(tostring(ns.settings.qty or 1))
    UpdateButtons()
    ns.Safe(UI.Refresh, true)
    UI.Remember()
  end)
end

------------------------------------------------------------------------------
-- Public actions
------------------------------------------------------------------------------
function UI.Refresh(refit)
  if not frame or not frame:IsShown() then return end
  ns.QueueTruncationCheck()
  UI.UpdateWorth()
  UI.UpdateSell()
  UI.UpdateTrends()
  local id = state.center
  if not id then
    state.graph = nil
    view:SetGraph(nil)
    panel:Hide()
    UpdateNav()
    UpdateStatus()
    UpdateButtons()
    return
  end
  local plan = ns.Opt.Plan(id, ns.settings.qty or 1)
  -- What is still missing for this item: a pinned item keeps its own count.
  state.needs, state.job = nil, nil
  local _, pin = ns.Jobs.IsPinned(id)
  if pin then
    pin.use = pin.use or {}
    state.use = pin.use
    for _, job in ipairs(ns.Jobs.All()) do
      if job.pin == pin then state.job = job end
    end
  else
    -- Not in the plan: the limits last while this item stays in view.
    if state.tempFor ~= id then state.tempUse, state.tempFor = {}, id end
    state.use = state.tempUse
  end
  if not state.job then
    local qty = ns.settings.qty or 1
    local needs = ns.Jobs.Needs(id, qty, nil, nil, state.use)
    local text, kind = ns.Jobs.Status(needs, qty, ns.Player.ItemCount(id), 0)
    state.job = { needs = needs, remaining = qty, inBags = ns.Player.ItemCount(id), text = text, kind = kind }
  end
  state.needs = state.job.needs
  -- The craft to do first: the deepest one whose materials are in the bags.
  for _, c in ipairs(state.needs.crafts) do
    if not state.job.nextCraft and ns.Player.Knows(c.spell) and ns.Player.CanMake(c.spell) > 0 then
      state.job.nextCraft = c.spell
    end
  end
  state.graph = ns.Graph.Build(id, { expandLeft = state.expandLeft, plan = plan })
  view:SetGraph(state.graph, refit)
  UpdatePanel()
  UpdateNav()
  if frame.SetPortraitToAsset then frame:SetPortraitToAsset(ns.ItemIcon(id)) end
  if not ns.Market.IsScanning() then UpdateStatus() end
  UpdateButtons()
end

function UI.Focus(id)
  if not id then return end
  UI.Remember()          -- make sure the view being left is in the history
  state.center = id
  state.expandLeft = false
  ns.settings.lastItem = id
  UI.Refresh(true)
  UI.Remember()
end

function UI.ToggleExpandLeft()
  state.expandLeft = not state.expandLeft
  UI.Refresh(true)
end

function UI.SetQuantity(qty)
  qty = max(1, min(10000, floor((tonumber(qty) or 1) + 0.5)))
  if qtyBox then qtyBox:SetText(tostring(qty)) end
  if ns.settings.qty ~= qty then
    ns.settings.qty = qty
    UI.Refresh()
  end
end

-- Opens the window on the sell-bags list.
function UI.OpenSell()
  if not frame then Create() end
  if not frame:IsShown() then
    if not state.center and ns.settings.lastItem then state.center = ns.settings.lastItem end
    frame:Show()
  end
  UI.ShowSell(true)
  frame:Raise()
end

-- Opens the window on the worth-crafting list.
function UI.OpenWorth()
  if not frame then Create() end
  if not frame:IsShown() then
    if not state.center and ns.settings.lastItem then state.center = ns.settings.lastItem end
    frame:Show()
  end
  UI.ShowWorth(true)
  frame:Raise()
end

function UI.IsOpen()
  return frame ~= nil and frame:IsShown()
end

function UI.Open(item)
  if not frame then Create() end
  if item then
    frame:Show()
    UI.Focus(item)
  else
    if frame:IsShown() then
      frame:Hide()
      return
    end
    if not state.center and ns.settings.lastItem then state.center = ns.settings.lastItem end
    frame:Show()
  end
  frame:Raise()
end

------------------------------------------------------------------------------
-- Keeping the window current
------------------------------------------------------------------------------
local refreshPending = false

local function QueueRefresh()
  QueueHUD()
  if not frame or not frame:IsShown() or refreshPending then return end
  refreshPending = true
  C_Timer.After(ns.Market.IsScanning() and 1.5 or 0.2, function()
    refreshPending = false
    ns.Safe(UI.Refresh)
  end)
end

ns.Listen("MARKET_UPDATED", QueueRefresh)
ns.Listen("JOBS", QueueRefresh)
ns.Listen("LOGIN", QueueHUD)
ns.On("MERCHANT_UPDATE", QueueHUD)

ns.Listen("SCAN_PROGRESS", function(done, total, reason, silent)
  if reason then
    if reason == "done" and total and total > 0 then
      local text = "Scanned " .. done .. " items"
      if silent and silent > 0 then text = text .. ", " .. silent .. " gave no answer" end
      ns.Print(text:lower() .. ".")
      UpdateStatus("|cff40ff40" .. text .. ".|r", 6)
    else
      UpdateStatus("Scan stopped: the auction house was closed.", 6)
    end
  else
    UpdateStatus("Scanning " .. done .. " of " .. total .. " ...", 8)
  end
end)

ns.Listen("FULLSCAN", function(stage, a, b)
  if stage == "requested" then
    UpdateStatus("Full scan: waiting for the auction house ...", 60)
  elseif stage == "reading" then
    UpdateStatus("Full scan: reading " .. a .. " of " .. b .. " auctions ...", 30)
  elseif stage == "storing" then
    UpdateStatus("Full scan: storing prices ...", 30)
  elseif stage == "done" then
    UpdateStatus("|cff40ff40Full scan done: " .. a .. " auctions, " .. b .. " recipe items on sale.|r", 10)
  elseif stage == "empty" then
    UpdateStatus("|cffff8040Full scan came back empty.|r", 10)
  elseif stage == "wait" then
    UpdateStatus("|cffff8040Full scan allowed again in " .. a .. " min.|r", 8)
  elseif stage == "timeout" then
    UpdateStatus("|cffff8040No answer to the full scan. Try Scan prices.|r", 12)
  end
end)

ns.Listen("AH_STATE", function()
  UpdateButtons()
  QueueRefresh()
end)

ns.Listen("PLAYER_UPDATED", function()
  if worth and worth:IsShown() then ns.Safe(UI.UpdateWorth) end
end)

-- Bags changed (bought materials, finished a craft): refresh the Make buttons.
local bagsPending = false
ns.On("BAG_UPDATE_DELAYED", function()
  QueueHUD()
  if bagsPending or not frame or not frame:IsShown() then return end
  bagsPending = true
  C_Timer.After(0.5, function()
    bagsPending = false
    if frame:IsShown() then ns.Safe(UI.Refresh) end
  end)
end)

-- After an interface reload, bring the window back on the item it showed.
ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if not ns.settings then return end
  local reopen = ns.settings.reopen or (isReload and ns.settings.wasOpen)
  ns.settings.reopen = nil
  if isLogin and not isReload then ns.settings.wasOpen = false end
  if reopen and isReload and not UI.IsOpen() then
    C_Timer.After(0.1, function()
      if ns.settings.lastItem then ns.Open(ns.settings.lastItem) else ns.Open() end
    end)
  end
end)

------------------------------------------------------------------------------
-- Ways in: Alt-click an item, shift-click into the search box, and a button
-- on the auction house window.
------------------------------------------------------------------------------
ns.Listen("READY", function()
  if type(HandleModifiedItemClick) == "function" then
    hooksecurefunc("HandleModifiedItemClick", function(link)
      if link and IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown() then
        local id = ns.ItemIDFromText(link)
        if id then ns.Open(id) end
      end
    end)
  end
  if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
    hooksecurefunc(ChatFrameUtil, "InsertLink", function(link)
      if search and search:HasFocus() and type(link) == "string" then
        local id = ns.ItemIDFromText(link)
        if id then
          search:SetText("")
          search:ClearFocus()
          HideResults()
          UI.Focus(id)
        end
      end
    end)
  end
end)

local function AddAuctionHouseButton()
  if UI.ahButton or not AuctionHouseFrame then return end
  local b = CreateFrame("Button", nil, AuctionHouseFrame, "UIPanelButtonTemplate")
  b:SetSize(96, 22)
  b:SetText("CraftGraph")
  b:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, -36)
  b:SetScript("OnClick", function() ns.Open() end)
  UI.ahButton = b

  local auto = CreateFrame("CheckButton", nil, AuctionHouseFrame, "UICheckButtonTemplate")
  auto:SetSize(22, 22)
  auto:SetPoint("TOPLEFT", b, "BOTTOMLEFT", -2, -2)
  local label = auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", auto, "RIGHT", 0, 1)
  label:SetText("Auto scan")
  auto:SetChecked(ns.settings.autoScan and true or false)
  auto:SetScript("OnClick", function(self)
    ns.settings.autoScan = self:GetChecked() and true or false
    ns.Fire("AUTOSCAN")
    if ns.settings.autoScan then ns.Safe(ns.Market.AutoTick) end
  end)
  auto:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Auto scan")
    GameTooltip:AddLine("While this window is open, CraftGraph scans by itself: the whole auction "
      .. "house whenever the game allows it (every 15 minutes), and the items in your plan and "
      .. "on the graph every " .. (ns.settings.autoMinutes or 10) .. " minutes in between.", 1, 1, 1, true)
    local what, wait = ns.Market.AutoNext()
    if what then
      local when = wait <= 0 and "any moment" or ("in " .. math.ceil(wait / 60) .. " min")
      GameTooltip:AddLine("Next: " .. (what == "full" and "full scan " or "plan and graph items ") .. when .. ".",
        0.4, 1, 0.4, true)
    end
    GameTooltip:Show()
  end)
  auto:SetScript("OnLeave", function() GameTooltip:Hide() end)
  UI.autoCheck = auto

  local src = CreateFrame("Button", nil, AuctionHouseFrame, "UIPanelButtonTemplate")
  src:SetSize(96, 22)
  src:SetText("Data sources")
  src:SetPoint("TOPLEFT", auto, "BOTTOMLEFT", 2, -2)
  src:SetScript("OnClick", function() ns.Safe(UI.ToggleSources) end)
end

------------------------------------------------------------------------------
-- Data sources: switch each one off and on to see what it changes. Your
-- own scans are always used; the rest are second opinions that may be wrong.
------------------------------------------------------------------------------
local sourcesFrame
local SOURCES = {
  { key = "Online", text = "Blizzard's hourly data",
    note = function()
      local _, o = ns.Market.Online(0)
      if o then return "from " .. ns.Age(time() - (o.updated or 0)) end
      if ns.Online and ns.Online.realm and ns.Online.realm ~= ns.realmKey then return "for another auction house" end
      if ns.Online then return "switched off" end
      return "not set up (optional, needs Python)"
    end,
    tip = "Prices, depth and sales from Blizzard's hourly auction data, brought in by the optional sync "
      .. "tool. Used where it is newer than your own scan." },
  { key = "Auctionator", text = "Auctionator's prices",
    note = function() return _G.Auctionator and "installed" or "not installed" end,
    tip = "Auctionator's last price for items you have not scanned here, and its older daily history." },
  { key = "Sales", text = "Sales seen between full scans",
    note = function()
      local n = 0
      for _, it in pairs(ns.realm and ns.realm.items or {}) do if it.sb then n = n + 1 end end
      return n > 0 and (n .. " items watched") or "needs two full scans within 12 hours"
    end,
    tip = "How fast things sell, judged from auctions that vanish between two full scans (not the ones "
      .. "that ran out or were relisted). Off, the cruder guess from price levels is used." },
}

function UI.SourcesText()
  local off = {}
  for _, def in ipairs(SOURCES) do
    if not ns.Market.Source(def.key) then off[#off + 1] = def.text end
  end
  if #off == 0 then return nil end
  return "|cffff8c33Switched off: " .. table.concat(off, ", ") .. ".|r"
end

local function UpdateSources()
  if not sourcesFrame then return end
  for _, row in ipairs(sourcesFrame.rows) do
    row.check:SetChecked(ns.Market.Source(row.def.key))
    row.note:SetText(GREY .. row.def.note() .. "|r")
  end
end

function UI.ToggleSources()
  if not sourcesFrame then
    local f = CreateFrame("Frame", "CraftGraphSources", UIParent, "BackdropTemplate")
    f:SetSize(330, 62 + #SOURCES * 38)
    f:SetPoint("CENTER", 0, 80)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local title = Text(f, "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Data sources")
    local own = Text(f, "GameFontHighlightSmall")
    own:SetPoint("TOPLEFT", 12, -30)
    own:SetText("Your own scans are always used. Untick one to see the numbers without it.")
    own:SetPoint("TOPRIGHT", -12, -30)
    own:SetWordWrap(true)
    own:SetMaxLines(2)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    f.rows = {}
    for i, def in ipairs(SOURCES) do
      local y = -58 - (i - 1) * 38
      local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
      check:SetSize(24, 24)
      check:SetPoint("TOPLEFT", 10, y)
      check:SetScript("OnClick", function(self)
        ns.Market.SetSource(def.key, self:GetChecked() and true or false)
      end)
      Tip(check, def.text, def.tip)
      local label = Text(f, "GameFontHighlight")
      label:SetPoint("TOPLEFT", check, "TOPRIGHT", 2, -2)
      label:SetText(def.text)
      local note = Text(f, "GameFontDisableSmall")
      note:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
      f.rows[i] = { check = check, note = note, def = def }
    end
    tinsert(UISpecialFrames, "CraftGraphSources")
    f:Hide()
    sourcesFrame = f
    UI.sourcesFrame = f
  end
  sourcesFrame:SetShown(not sourcesFrame:IsShown())
  UpdateSources()
end

ns.Listen("SOURCES", function()
  UpdateSources()
end)

-- What the auto scan is doing, in a few words, beside its switch.
function UI.AutoText()
  local M = ns.Market
  if not ns.settings.autoScan then return "Auto scan" .. GREY .. " off|r" end
  if not M.ahOpen then return "Auto scan" .. GREY .. ": open the auction house|r" end
  local done = M.sessionFullScans or 0
  local tally = done > 0 and (" (" .. done .. " done)") or ""
  if M.FullScanBusy() then return "Auto scan|cff40ff40: full scan running|r" .. tally end
  if M.IsScanning() then return "Auto scan|cff40ff40: looking up items|r" .. tally end
  -- The next full scan, whatever comes before it.
  local wait = max(M.FullScanWait(), (M.autoHold or 0) - time())
  if wait <= 0 then return "Auto scan|cff40ff40: full scan any moment|r" .. tally end
  return "Auto scan|cff40ff40: full scan in " .. math.ceil(wait / 60) .. " min|r" .. tally
end

function UI.UpdateAutoLabel()
  if UI.autoMain then UI.autoMain:SetChecked(ns.settings.autoScan and true or false) end
  if UI.autoLabel then UI.autoLabel:SetText(UI.AutoText()) end
end

ns.Listen("AUTOSCAN", function()
  if UI.autoCheck then UI.autoCheck:SetChecked(ns.settings.autoScan and true or false) end
  UI.UpdateAutoLabel()
end)
ns.Listen("AH_STATE", function() UI.UpdateAutoLabel() end)
ns.Listen("FULLSCAN", function() UI.UpdateAutoLabel() end)

-- The items the auto scan keeps fresh: everything on the graph in view and
-- everything the plan makes, uses or buys.
ns.Market.autoItems = function()
  local ids, seen = {}, {}
  local function Add(graph)
    for _, n in ipairs(graph and graph.nodes or {}) do
      if n.id and not seen[n.id] then
        seen[n.id] = true
        ids[#ids + 1] = n.id
      end
    end
  end
  -- The plan first, so it is kept when the list is cut short.
  for _, pin in ipairs(ns.Jobs.Pins()) do
    Add(ns.Graph.Build(pin.id, {}))
  end
  Add(state.graph)
  return ids
end

ns.On("ADDON_LOADED", function(name)
  if name == "Blizzard_AuctionHouseUI" then AddAuctionHouseButton() end
end)
ns.On("AUCTION_HOUSE_SHOW", AddAuctionHouseButton)
