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

-- The mark for "you could make this if you learned the recipe": a small
-- button on the top right corner of an item's icon, showing the item that
-- teaches the recipe (or a book when a trainer does). Hover for where to
-- get it; click to look the teaching item up.
local BOOK_ICON = "Interface\\Icons\\INV_Misc_Book_09"

function UI.CreateTeachMark(parent, icon, size)
  local mark = CreateFrame("Button", nil, parent)
  mark:SetSize(size, size)
  mark:SetPoint("CENTER", icon, "TOPRIGHT", -1, -1)
  mark.rim = mark:CreateTexture(nil, "BACKGROUND")
  mark.rim:SetPoint("TOPLEFT", -1, 1)
  mark.rim:SetPoint("BOTTOMRIGHT", 1, -1)
  mark.rim:SetColorTexture(0.45, 0.75, 1, 1)
  mark.icon = mark:CreateTexture(nil, "ARTWORK")
  mark.icon:SetAllPoints()
  mark.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  mark:SetScript("OnEnter", function(self)
    if not self.item then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Recipe not learned", 0.45, 0.75, 1)
    GameTooltip:AddLine("You have the profession for " .. ns.ItemName(self.item) .. " but have not learned to make it.",
      1, 1, 1, true)
    GameTooltip:AddLine(ns.Player.TeacherText(self.teacher), 1, 0.82, 0, true)
    if self.teacher then GameTooltip:AddLine("Click to look the recipe up.", 0.6, 0.6, 0.6) end
    GameTooltip:Show()
  end)
  mark:SetScript("OnLeave", function() GameTooltip:Hide() end)
  mark:SetScript("OnClick", function(self)
    if self.teacher then
      UI.Remember()
      UI.ShowGraph()
      UI.Focus(self.teacher)
    end
  end)
  mark:Hide()
  return mark
end

-- Shows the mark for an item, or hides it when the item is not one the
-- player could make by learning a recipe.
function UI.SetTeachMark(mark, id)
  local spell, teacher
  if id then spell, teacher = ns.Player.Unlearned(id) end
  mark.item, mark.teacher = spell and id or nil, teacher
  if spell then
    mark.icon:SetTexture(teacher and ns.ItemIcon(teacher) or BOOK_ICON)
    mark:Show()
  else
    mark:Hide()
  end
  return spell ~= nil
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
  p.teach = UI.CreateTeachMark(p, p.icon, 18)
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

  p.makeHeader = Text(p, "GameFontNormal")
  p.makeHeader:SetPoint("TOPLEFT", 14, y)
  p.pin = Button(p, "Plan it", 104)
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
  y = y - 22
  -- How many: a slider for a quick pick, a box for an exact number. It is
  -- the amount everything below is worked out for, and what "Plan it" plans.
  local AW = 150
  local amountLabel = Text(p, "GameFontNormalSmall")
  amountLabel:SetPoint("TOPLEFT", 14, y)
  amountLabel:SetText("Amount")
  local amount = CreateFrame("Button", nil, p)
  amount:SetSize(AW, 16)
  amount:SetPoint("TOPLEFT", 70, y + 2)
  local track = amount:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("LEFT", 0, 0)
  track:SetPoint("RIGHT", 0, 0)
  track:SetHeight(4)
  track:SetColorTexture(1, 1, 1, 0.18)
  local fill = amount:CreateTexture(nil, "BORDER")
  fill:SetPoint("LEFT", 0, 0)
  fill:SetHeight(4)
  fill:SetColorTexture(1, 0.82, 0, 0.8)
  local thumb = amount:CreateTexture(nil, "ARTWORK")
  thumb:SetSize(8, 14)
  thumb:SetColorTexture(1, 0.9, 0.5, 1)
  local mark = amount:CreateTexture(nil, "BORDER")       -- where the best amount is
  mark:SetSize(2, 10)
  mark:SetColorTexture(0.25, 1, 0.25, 0.9)
  local box = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
  box:SetSize(44, 18)
  box:SetPoint("LEFT", amount, "RIGHT", 14, 0)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(5)
  amount.max = 20
  p.amount, p.amountBox = amount, box
  -- Sets the amount: for the whole window, and for the plan when this item is planned.
  function p.SetAmount(qty)
    qty = max(1, min(10000, floor((tonumber(qty) or 1) + 0.5)))
    local id = state.center
    if id and ns.Jobs.IsPinned(id) then ns.Jobs.SetQty(id, qty) end
    UI.SetQuantity(qty)
  end
  -- Shows the amount on the slider. The range grows with the best amount
  -- and with what is typed, in round steps.
  function p.ShowAmount(qty, best)
    local top = max(20, (best or 0) * 2, qty)
    for _, round in ipairs({ 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 }) do
      if top <= round then top = round break end
    end
    amount.max = top
    local share = (qty - 1) / max(1, top - 1)
    fill:SetWidth(max(0.5, AW * share))
    thumb:ClearAllPoints()
    thumb:SetPoint("CENTER", amount, "LEFT", AW * share, 0)
    mark:SetShown(best ~= nil and best > 0)
    if best and best > 0 then
      mark:ClearAllPoints()
      mark:SetPoint("CENTER", amount, "LEFT", AW * (best - 1) / max(1, top - 1), 0)
    end
    amount.best = best
    if not box:HasFocus() then box:SetText(tostring(qty)) end
  end
  local function FromCursor()
    local left, scale = amount:GetLeft(), amount:GetEffectiveScale()
    if not left or not scale or scale == 0 then return nil end
    local share = max(0, min(1, (GetCursorPosition() / scale - left) / AW))
    return 1 + share * (amount.max - 1)
  end
  amount:SetScript("OnMouseDown", function()
    amount.dragging = true
    local q = FromCursor()
    if q then p.SetAmount(q) end
  end)
  amount:SetScript("OnMouseUp", function() amount.dragging = false end)
  amount:SetScript("OnHide", function() amount.dragging = false end)
  amount:SetScript("OnUpdate", function()
    if not amount.dragging then return end
    if not IsMouseButtonDown("LeftButton") then amount.dragging = false return end
    local q = FromCursor()
    if q then p.SetAmount(q) end
  end)
  amount:EnableMouseWheel(true)
  amount:SetScript("OnMouseWheel", function(_, delta)
    p.SetAmount((ns.settings.qty or 1) + delta * (IsShiftKeyDown() and 10 or 1))
  end)
  Tip(amount, "How many",
    "Drag, or scroll for steps of one (hold Shift for ten), or type a number in the box. Profit, cost and "
    .. "the steps below are worked out for this amount, and \"Plan it\" plans this many. For an item already "
    .. "in your plan it changes the plan. The green mark is the best amount.")
  box:SetScript("OnEnterPressed", function(self)
    p.SetAmount(self:GetText())
    self:ClearFocus()
  end)
  box:SetScript("OnEditFocusLost", function(self) p.SetAmount(self:GetText()) end)
  box:SetScript("OnEscapePressed", function(self)
    self:SetText(tostring(ns.settings.qty or 1))
    self:ClearFocus()
  end)
  y = y - 22
  -- The answer first: what making it earns. Then what that rests on.
  Row("profit", "Profit", "GameFontHighlightLarge", 24)
  Row("bad", "If prices turn")
  Row("cost", "Materials")
  Row("sale", "Sale")
  Row("best", "Best amount", nil, nil, 62)
  Row("time", "Time to sell")

  -- What the bad-case line means, on hover.
  local badHit = CreateFrame("Button", nil, p)
  badHit:SetPoint("TOPLEFT", p, "TOPLEFT", 12, rowY.bad + 2)
  badHit:SetPoint("BOTTOMRIGHT", p, "TOPRIGHT", -12, rowY.bad - 15)
  Tip(badHit, "If prices turn against you",
    "The profit above is the best estimate, with the auction house's cut already taken off the sale. "
    .. "This line is a bad case: the estimate less twice its margin. Things end worse than this about "
    .. "one time in ten, measured on real scans (prices here jump more than a tidy curve allows). Red means you could end with less money than you started with. Not counted: "
    .. "the listing deposit, which you lose if an auction runs out unsold.")

  p.useBest = Button(p, "Set", 42)
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

  -- The market facts the answer is built on.
  Row("auction", "Auction price")
  Row("supply", "Supply and demand")
  Row("vendor", "Vendor")
  -- Click the supply and demand line to list this item's sales seen.
  local salesHit = CreateFrame("Button", nil, p)
  salesHit:SetPoint("TOPLEFT", p, "TOPLEFT", 12, rowY.supply + 2)
  salesHit:SetPoint("BOTTOMRIGHT", p, "TOPRIGHT", -12, rowY.supply - 15)
  salesHit:SetScript("OnClick", function() ns.Safe(UI.ShowSales, true) end)
  Tip(salesHit, "Sales seen", "Click to list the auctions of this item that were judged sold between full scans.")
  p.salesHit = salesHit
  Divider()


  -- One box, two pictures: the price over time, or the price by time of week.
  local chartHeader = Button(p, "Price history", 104)
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
    .. "Monday afternoon, and read its price. The price in all three is the cheapest tenth on sale, "
    .. "averaged (at most the 50 cheapest), which one lone listing cannot set; the Auction price "
    .. "above is the single cheapest. Both are asking prices: the game never shows what anything sold for.")
  p.chartMode = chartHeader
  local RANGES = { 14, 90, 0 }
  local function RangeText()
    local d = ns.settings.chartDays or 14
    return d > 0 and (d .. " days") or "All"
  end
  p.range = Button(p, RangeText(), 62)
  p.range:SetHeight(18)
  p.range:SetPoint("LEFT", chartHeader, "RIGHT", 4, 0)
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
  -- What the chart draws is chosen in a small panel behind the "Show"
  -- button, so that the row above the chart stays short. The defaults suit
  -- a first look: the certainty glow and a grid to read sizes off.
  p.showButton = Button(p, "Show ...", 70)
  p.showButton:SetHeight(18)
  p.showButton:SetPoint("LEFT", p.range, "RIGHT", 4, 0)
  Tip(p.showButton, "What the chart shows",
    "Tick what to draw: the certainty glow, a grid to read prices off, bars for how much the price moved "
    .. "from one period to the next, and the supply and demand lines.")
  local options = CreateFrame("Frame", nil, p, "BackdropTemplate")
  options:SetSize(186, 12 + 7 * 22)
  options:SetPoint("TOPRIGHT", p, "TOPRIGHT", -12, y - 18)
  options:SetFrameStrata("DIALOG")
  options:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  options:EnableMouse(true)
  options:Hide()
  p.chartOptions = options
  p.showButton:SetScript("OnClick", function() options:SetShown(not options:IsShown()) end)
  local optionRow = 0
  local function Option(setting, text, title, body)
    local check = CreateFrame("CheckButton", nil, options, "UICheckButtonTemplate")
    check:SetSize(22, 22)
    check:SetPoint("TOPLEFT", 6, -6 - optionRow * 22)
    optionRow = optionRow + 1
    local label = Text(options, "GameFontHighlightSmall")
    label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    label:SetText(text)
    check.setting = setting
    check:SetScript("OnClick", function(self)
      ns.settings[setting] = self:GetChecked() and true or false
      UI.Refresh()
    end)
    Tip(check, title, body)
    return check, label
  end
  p.grid = Option("chartGrid", "Grid with prices", "Grid",
    "Faint lines at round prices, each with its price and how far it is from the price now, so that "
    .. "the size of a move can be read off the chart.")
  p.bars = Option("chartBars", "Change bars", "Change bars",
    "Small bars along the bottom, one per period: green when the price rose from the period before, "
    .. "red when it fell, taller for a bigger change. The latest and the biggest carry their figure.")
  local label
  p.certainty, label = Option("certainty", "Certainty glow", "Certainty glow",
    "Shades the chart by how sure the price estimate is: tight and bright near real scans, "
    .. "wide and faint in gaps and in the forecast.")
  p.certaintyLabel = label
  p.flow, p.flowLabel = Option("chartFlow", "Supply (units listed)", "Supply",
    "Adds a blue line to the price chart: how many were listed at each scan, on its own scale from "
    .. "nothing to the most seen. A price that falls while this line climbs is goods piling up.")
  p.demand, p.demandLabel = Option("chartDemand", "Demand (sold a day)", "Demand",
    "Adds a green line to the price chart: how many sold a day, judged from the auctions that "
    .. "vanished between full scans and evened out over a stretch of time. Its scale is at the "
    .. "right edge in units a day. It needs two full scans within twelve hours to start.")
  p.margin, p.marginLabel = Option("chartMargin", "Margin (profit each)", "Margin over time",
    "Adds a pink line to the price chart: what making one and selling it would have left at each scan, "
    .. "after the auction house's cut, with the materials at their prices of that moment. The faint line "
    .. "at its foot is nothing: above it pays, below it loses. Under the chart: the margin now and where "
    .. "it is heading, said only when that is at least three chances in four. Only for things you can make.")
  p.hover = Option("chartHover", "Readout under the mouse", "Readout under the mouse",
    "Hover the chart: a line marks that moment, with its time at the foot and a mark where it crosses "
    .. "each line, and beside the chart the numbers of that moment: the scan there, the estimate with "
    .. "its range, supply, demand and margin when they are drawn, and what making and selling one "
    .. "would have left.")
  p.chartChecks = { p.grid, p.bars, p.certainty, p.flow, p.demand, p.margin, p.hover }
  y = y - 20

  chart = ns.Chart.Create(p)
  UI.sideChart = chart
  chart:SetPoint("TOPLEFT", 12, y)
  chart:SetSize(PANEL_W - 24, 160)
  p.week = UI.CreateWeekStrip(p)
  p.week:SetPoint("TOPLEFT", 12, y)
  p.week:SetSize(PANEL_W - 24, 160)
  y = y - 166
  Divider()

  local planHeader = Text(p, "GameFontNormal")
  planHeader:SetPoint("TOPLEFT", 14, y)
  planHeader:SetText("Steps, cheapest way")
  p.planHeader = planHeader
  y = y - 18
  p.stepLines = UI.CreateStepLines(p, 6, 50)
  for i, line in ipairs(p.stepLines) do
    line:SetPoint("TOPLEFT", 14, y - (i - 1) * 17)
    line:SetPoint("TOPRIGHT", -12, y - (i - 1) * 17)
  end
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

-- The steps of a plan as lines, each with a button for what can be done
-- from here: what to do, what it costs or brings, and where to go. Used by
-- the side panel and the plan window.
--   opts.limit   the most lines to show
--   opts.where   add a line saying where to go, while there is room
-- A planned item marks the step that is next, and folds what is finished
-- away under "Completed".
function UI.StepEntries(id, qty, job, opts)
  opts = opts or {}
  local limit = opts.limit or 6
  local J = ns.Jobs
  local pin = job and job.pin
  local planned = pin ~= nil
  local steps = J.Steps(id, qty, job)
  local done = planned and J.StepsDone(job) or {}
  local room = limit - (#done > 0 and 1 or 0)
  local entries = {}
  for i, step in ipairs(steps) do
    local money = ""
    if step.cost and step.cost > 0 then money = GREY .. "  costs |r" .. ns.Money(step.cost) end
    if step.gain then
      money = GREY .. "  brings |r" .. ns.Money(step.gain) .. (step.cutPaid and (GREY .. " after the cut|r") or "")
    end
    local head = (planned and step.now) and "|cffffd100Next: " or ("|cffffd100" .. i .. ". ")
    entries[#entries + 1] = { text = head .. "|r" .. step.text .. money, step = step,
      action = J.StepAction(step, job), tip = step.where }
  end
  if #steps == 0 and #done == 0 then
    entries[1] = { text = GREY .. "Nothing to do: you hold everything.|r" }
  end
  if #entries > room then
    local extra = #entries - room + 1
    while #entries > room - 1 do table.remove(entries) end
    entries[#entries + 1] = { text = GREY .. "... and " .. extra .. " more steps|r" }
  end
  -- Where to go, while there is room: for a missing source, for the step
  -- that is next, and for anything bought from a vendor.
  if opts.where then
    local left, chosen = room - #entries, {}
    local function pick(want)
      for _, e in ipairs(entries) do
        if left > 0 and e.step and e.step.where and not chosen[e] and want(e.step) then
          chosen[e] = true
          left = left - 1
        end
      end
    end
    pick(function(step) return step.kind == "stuck" end)
    pick(function(step) return planned and step.now end)
    pick(function(step) return step.kind == "vendor" end)
    local out = {}
    for _, e in ipairs(entries) do
      out[#out + 1] = e
      if chosen[e] then out[#out + 1] = { text = GREY .. "    " .. e.step.where .. "|r" } end
    end
    entries = out
  end
  -- What is finished: one line to fold it open, then the steps in grey.
  if #done > 0 then
    entries[#entries + 1] = { fold = pin, text = GREY .. (pin.showDone and "- " or "+ ") .. "Completed (" .. #done .. ")|r",
      tip = "Click to " .. (pin.showDone and "fold away" or "show") .. " the steps that are finished." }
    if pin.showDone then
      for _, step in ipairs(done) do
        if #entries < limit + #done then
          entries[#entries + 1] = { text = GREY .. "    done: " .. step.text .. "|r", done = true }
        end
      end
    end
  end
  return entries, steps, done
end

-- `count` lines for step entries, stacked downwards from (x, y) in `parent`.
function UI.CreateStepLines(parent, count, buttonWidth)
  local lines = {}
  for i = 1, count do
    local line = CreateFrame("Button", nil, parent)
    line:SetHeight(17)
    line.text = Text(line, "GameFontHighlightSmall")
    line.text:SetPoint("LEFT", 0, 0)
    line.text:SetPoint("RIGHT", -(buttonWidth + 6), 0)
    line.text:SetWordWrap(false)
    line.button = Button(line, "", buttonWidth)
    line.button:SetHeight(16)
    line.button:SetPoint("RIGHT", 0, 0)
    -- A greyed button still says, on hover, where it will work.
    if line.button.SetMotionScriptsWhileDisabled then line.button:SetMotionScriptsWhileDisabled(true) end
    line.button:SetScript("OnClick", function(self)
      if self.fn then ns.Safe(self.fn) end
    end)
    line.button:SetScript("OnEnter", function(self)
      if not self.tip then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText(self.title or "This step")
      GameTooltip:AddLine(self.tip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    line.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    line:SetScript("OnClick", function(self)
      local e = self.entry
      if e and e.fold then
        e.fold.showDone = not e.fold.showDone or nil
        ns.Fire("JOBS")
      end
    end)
    line:SetScript("OnEnter", function(self)
      local e = self.entry
      if not e then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText(e.step and e.step.text or (e.fold and "Completed" or "Step"), 1, 0.82, 0, 1, true)
      if e.tip then GameTooltip:AddLine(e.tip, 1, 1, 1, true) end
      GameTooltip:Show()
    end)
    line:SetScript("OnLeave", function() GameTooltip:Hide() end)
    lines[i] = line
  end
  return lines
end

-- Shows entries on lines; returns how many lines are in use.
function UI.FillStepLines(lines, entries)
  for i, line in ipairs(lines) do
    local e = entries[i]
    line.entry = e
    if e then
      line.text:SetText(e.text)
      local a = e.action
      line.button:SetShown(a ~= nil)
      if a then
        line.button:SetText(a.text)
        line.button:SetEnabled(a.enabled and true or false)
        line.button.fn, line.button.tip, line.button.title = a.enabled and a.fn or nil, a.tip, e.step and e.step.text
      end
      line:Show()
    else
      line:Hide()
    end
  end
  return math.min(#entries, #lines)
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
  UI.SetTeachMark(p.teach, id)
  -- A long name drops to the smaller font rather than being cut off.
  p.name:SetFontObject("GameFontNormalLarge")
  p.name:SetText(ns.ItemName(id))
  if p.name.GetStringWidth and (p.name:GetStringWidth() or 0) > PANEL_W - 62 - 10 - 6 then
    p.name:SetFontObject("GameFontNormal")
  end
  p.name:SetTextColor(r, g, b)

  p.pin:SetText(ns.Jobs.IsPinned(id) and "Remove from plan" or "Plan it")

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
    rows.auction:SetText(text .. GREY .. ", " .. ns.Age(info.age) .. (info.base and " (base data)" or "") .. "|r")
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
    local cut = ns.settings.cut or 0.05
    rows.sale:SetText(ns.Money(e.revenue) .. GREY .. "  after the " .. ns.Round(cut * 100) .. "% cut of |r"
      .. ns.Money(e.revenue * cut / (1 - cut)))
  else
    rows.sale:SetText(GREY .. "no auction price|r")
  end
  if e.profit then
    local color = e.profit >= 0 and "|cff40ff40+" or "|cffff5040"
    rows.profit:SetText(color .. ns.Money(e.profit) .. "|r" .. GREY .. " \194\177|r" .. ns.Money(e.sd))
  else
    rows.profit:SetText(GREY .. "--|r")
  end
  -- The bad case: two margins below the estimate (roughly one time in ten
  -- it ends lower still). What you stand to lose is said as a loss.
  if e.profit then
    local bad = e.profit - 2 * (e.sd or 0)
    p.badCase = bad
    if bad < 0 then
      rows.bad:SetText("|cffff5040could lose " .. ns.Money(-bad) .. "|r")
    else
      rows.bad:SetText("|cff40ff40still +" .. ns.Money(bad) .. "|r")
    end
  else
    p.badCase = nil
    rows.bad:SetText(GREY .. "--|r")
  end

  p.ShowAmount(qty, nil)
  p.useBest:Hide()
  if craftable and e.profit then
    local bestQty, best, demandKnown = ns.Opt.BestQuantity(id)
    if best.profit and best.profit > 0 then
      rows.best:SetText(bestQty .. " for |cff40ff40+" .. ns.Money(best.profit) .. "|r"
        )
      p.useBest.qty = bestQty
      p.useBest:SetShown(bestQty ~= qty)
      p.ShowAmount(qty, bestQty)
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

  for _, check in ipairs(p.chartChecks) do
    check:SetChecked(ns.settings[check.setting] and true or false)
  end
  local picture = ns.settings.sideChart or "history"
  local weekPicture = picture == "week" or picture == "day"
  p.chartMode:SetText(picture == "week" and "Week pattern" or picture == "day" and "Day pattern" or "Price history")
  p.week.mode = picture == "day" and "day" or "week"
  p.range:SetShown(not weekPicture)
  p.showButton:SetShown(not weekPicture)
  if weekPicture then p.chartOptions:Hide() end
  chart:SetShown(not weekPicture)
  p.week:SetShown(weekPicture)
  if weekPicture then
    UI.UpdateWeekStrip(p.week, id)
  else
    chart:Update(id, { band = ns.settings.certainty, craft = unitCraft, vendor = ns.VendorSell(id),
      days = ns.settings.chartDays, flow = ns.settings.chartFlow, demand = ns.settings.chartDemand,
      margin = ns.settings.chartMargin and craftable and ns.Opt.MarginTrend(id) or nil,
      grid = ns.settings.chartGrid, bars = ns.settings.chartBars })
  end
  local planned = state.job and state.job.pin and state.job.pin.id == id
  p.planHeader:SetText(planned and "Your plan, step by step" or "Steps, cheapest way")
  p.steps = ns.Jobs.Steps(id, qty, state.job)
  p.stepEntries = UI.StepEntries(id, qty, state.job, { limit = 6, where = true })
  UI.FillStepLines(p.stepLines, p.stepEntries)
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
local CoarseMoney
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

-- Is now a good time to sell what a row ends in? One short word for the
-- list ("now", "ok", "wait", or a dash when there is too little to say or
-- the sale is to a vendor), and sentences for the tooltip.
function UI.SellSignalText(d)
  if not d.id or d.kind == "tovendor" or d.kind == "bags" or d.kind == "later" then return "" end
  local signal = ns.Stats.SellSignal(d.id)
  if signal.verdict == "good" then return "|cff40ff40now|r" end
  if signal.verdict == "poor" then return "|cffff8c33wait|r" end
  if signal.verdict == "fair" then return GREY .. "any time|r" end
  return GREY .. "-|r"
end

function UI.SellSignalLines(id)
  local signal = ns.Stats.SellSignal(id)
  if not signal.verdict then return { { "Selling now: " .. signal.why, 0.6, 0.6, 0.6 } } end
  local over = signal.ratio >= 0
  local pct = ns.Round(math.abs(signal.ratio) * 100)
  local period = signal.span >= 2 * 86400 and (ns.Round(signal.span / 86400) .. " days")
    or (ns.Round(signal.span / 3600) .. " h")
  local head = signal.verdict == "good" and { "A good time to sell", 0.25, 1, 0.25 }
    or signal.verdict == "poor" and { "Not a good time to sell", 1, 0.55, 0.2 }
    or { "A fair time to sell", 0.8, 0.8, 0.8 }
  local lines = { { head[1] .. ": the last three hours average " .. ns.Money(signal.recent) .. ", "
    .. (pct == 0 and "right at" or (pct .. "% " .. (over and "over" or "under"))) .. " its usual price of "
    .. ns.Money(signal.usual) .. " over the last " .. period .. " (" .. signal.scans .. " scans).", head[2], head[3], head[4] } }
  -- A better hour ahead, where a forecast is worth having.
  local best = ns.Jobs.BestMoment(id)
  if best and best.hours > 0 and best.gain >= signal.margin then
    lines[#lines + 1] = { "The forecast names a better hour: " .. best.label .. ", about "
      .. ns.Round(best.gain * 100) .. "% more.", 0.45, 0.75, 1 }
  end
  return lines
end

-- An amount rounded to its largest coin, for a margin beside a figure:
-- 6g 31s 4c of doubt reads as 6g.
function CoarseMoney(copper)
  copper = math.abs(copper)
  if copper >= 10000 then return ns.Round(copper / 10000) * 10000 end
  if copper >= 100 then return ns.Round(copper / 100) * 100 end
  return ns.Round(copper)
end

-- A profit or loss in colour, with its sign.
local function Signed(copper)
  return (copper < 0 and "|cffff5040-" or "|cff40ff40+") .. ns.Money(math.abs(copper)) .. "|r"
end

-- Adds "if it sells ..." lines to the tooltip: the profit by when the goods sell.
local function AddProjection(proj)
  if not proj or not proj.now then return end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(proj.fixed and "Profit" or "Profit if it sells ...", 1, 0.82, 0)
  -- Later moments are shown only when this price can be forecast.
  local showForecast, _, _, why = true, true, nil, nil
  if proj.id and not proj.fixed then showForecast, _, _, why = ns.Stats.Show(proj.id) end
  for i, row in ipairs(proj.rows) do
    if i == 1 or showForecast then
      local range = row.lo ~= row.hi and (GREY .. "  (" .. ns.Money(row.lo) .. " to " .. ns.Money(row.hi) .. ")|r") or ""
      GameTooltip:AddDoubleLine(row.label, Signed(row.profit) .. range, 1, 1, 1, 1, 1, 1)
    end
  end
  if not showForecast then
    GameTooltip:AddLine((why or "") .. " Later sale times are left out. /cg guesses shows them.", 1, 0.55, 0.2, true)
  end
  if proj.best and showForecast then
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
    for _, line in ipairs(UI.SellSignalLines(d.id)) do
      GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
    end
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
  -- What could be lost, and that the auction house's share is already off.
  if (d.sd or 0) > 0 then
    local bad = d.profit - 2 * d.sd
    GameTooltip:AddDoubleLine("If prices turn", bad < 0 and ("could lose " .. ns.Money(-bad)) or ("still +" .. ns.Money(bad)),
      1, 0.82, 0, bad < 0 and 1 or 0.25, bad < 0 and 0.31 or 1, 0.25)
  end
  if d.kind ~= "tovendor" then
    GameTooltip:AddLine("The auction house's " .. ns.Round((ns.settings.cut or 0.05) * 100)
      .. "% cut of each sale is already taken off.", 0.6, 0.6, 0.6, true)
  end
  if d.id and d.kind ~= "tovendor" and d.kind ~= "bags" then
    for _, line in ipairs(UI.SellSignalLines(d.id)) do
      GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
    end
  end
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
    { key = "kind", text = "How", x = 232, justify = "LEFT", width = 124 },
    { key = "qty", text = "Amount", right = 420, justify = "RIGHT", width = 56 },
    { key = "outlay", text = "Costs up front", right = 522, justify = "RIGHT", width = 96 },
    { key = "profit", text = "Profit", right = 642, justify = "RIGHT", width = 100 },
    { key = "effort", text = "Steps", right = 680, justify = "RIGHT", width = 36 },
    { key = "signal", text = "Sell when", right = 722, justify = "RIGHT", width = 52 },
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
    row.teach = UI.CreateTeachMark(row, row.icon, 10)
    row.name = Text(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(190)
    row.name:SetWordWrap(false)
    row.kind = Text(row, "GameFontHighlightSmall")
    row.kind:SetPoint("LEFT", row, "LEFT", 224, 0)
    row.kind:SetWidth(132)
    row.kind:SetWordWrap(false)
    row.qty = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.qty:SetPoint("RIGHT", row, "LEFT", 412, 0)
    row.outlay = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.outlay:SetPoint("RIGHT", row, "LEFT", 514, 0)
    row.profit = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.profit:SetPoint("RIGHT", row, "LEFT", 634, 0)
    row.effort = Text(row, "GameFontDisableSmall", "RIGHT")
    row.effort:SetPoint("RIGHT", row, "LEFT", 672, 0)
    -- Is now a good time to sell it: "now", "ok" or "wait".
    row.signal = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.signal:SetPoint("RIGHT", row, "LEFT", 708, 0)
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
      .. GREY .. "  (" .. sure .. " look sure)|r")
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
    local _, left = Deals.Timing()
    local leftOut = (left or 0) > 0 and (" " .. left .. " left out: too early or too unsettled to time (/cg guesses shows them).") or ""
    note = #list == 0 and (GREY .. "Nothing to time yet." .. leftOut .. "|r")
      or (GREY .. "Profit is what waiting for that hour should add over selling now." .. leftOut .. "|r")
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
      UI.SetTeachMark(row.teach, (d.kind == "craft" or d.craft) and d.id or nil)
      row.name:SetText(DealName(d) .. (d.guess and " |cffff8c33?|r" or ""))
      local t = KIND_TINT[d.kind]
      row.kind:SetText(d.how or Deals.KIND[d.kind])
      row.kind:SetTextColor(t[1], t[2], t[3])
      row.qty:SetText(d.kind == "bags" and "" or ("x" .. ns.Round(d.qty)))
      row.outlay:SetText(d.kind == "later" and "" or (d.outlay > 0 and ns.Money(d.outlay) or (GREY .. "nothing|r")))
      row.profit:SetText((d.kind == "later" and d.when.hours == 0) and (GREY .. "sell now|r")
        or "|cff40ff40+" .. ns.Money(d.profit) .. "|r"
        -- The margin turns orange when a bad case would be a loss.
        .. (d.sd > 0 and (((d.profit - 2 * d.sd < 0) and "|cffff8c33" or GREY) .. " \194\177|r" .. ns.Money(CoarseMoney(d.sd))) or ""))
      row.effort:SetText(d.effort)
      row.signal:SetText(UI.SellSignalText(d))
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
    worth.more:SetText("Faded rows are not sure to pay. Sell when: now = the price is high, wait = it is low, "
      .. "any time = about usual. Hover a row for the steps.")
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
      for _, line in ipairs(UI.SellSignalLines(d.id)) do
        GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
      end
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
  -- The curves are drawn only where a pattern is worth showing; the scans
  -- themselves are always drawn.
  local _, showPattern, held = false, false, nil
  if week then _, showPattern, held = ns.Stats.Show(id) end
  local curves = week and showPattern
  f.held = week and not showPattern or false
  if curves then
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
    for index = 0, (curves and count - 1 or -1) do
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
    f.legend:SetText((curves and (GOLD .. "usual|r" .. (differs and "  |cff73bfffnext " .. (dayMode and "24 h" or "7 days") .. "|r" or "")
      .. "  ") or "") .. GREY .. "dots: scans,|r " .. UI.ScanAgeText(id))
  else
    f.empty:SetText("No price recorded yet.")
    f.empty:Show()
    f.scaleTop:SetText("")
    f.scaleBottom:SetText("")
    f.legend:SetText("")
  end
  for i = (curves and hi > 0) and (count + 1) or 1, #f.bars do f.bars[i]:Hide() end
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
  if info.base then
    return "|cffff8c33not scanned by you; the base data saw it " .. ns.Age(info.age) .. "|r"
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
    local _, showPattern, held = ns.Stats.Show(id)
    if not showPattern then
      return GOLD .. when .. "|r\n|cffff8c33" .. (held or "") .. "|r\n" .. GREY
        .. "Not shown: it would be a guess. /cg guesses shows it.|r", nil
    end
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
  do
    local _, showPattern, _, why = ns.Stats.Show(id)
    if not showPattern then
      return GOLD .. when .. ":|r |cffff8c33" .. (why or "") .. "|r " .. GREY
        .. "An estimate for this time would be a guess, so none is shown. Type /cg guesses to see it anyway.|r", nil
    end
  end
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
  -- The facts, as up to four short labelled lines: what it costs now,
  -- where it is heading, how fast it sells, and when it is cheap and dear.
  local facts = {}
  if not t then
    facts.none = "No price has been recorded for this yet. Scan it at the auction house."
  else
    -- What the last scan actually saw comes first; the estimate follows.
    local info = ns.Market.Info(id)
    local now = ""
    if info and info.source == "scan" and info.age then
      now = (info.price and ("Cheapest listed " .. ns.Money(info.price) .. " (" .. (info.total or 0) .. " on sale)")
        or "None on sale") .. ", " .. UI.ScanAgeText(id) .. ". "
    end
    now = now .. "Estimate " .. ns.Money(t.now)
    if t.vsUsual then
      now = now .. ", " .. Percent(t.vsUsual) .. " of " .. ns.Money(t.usual)
    end
    facts.now = now .. "."
    local _, _, _, why = ns.Stats.Show(id)
    if why then
      -- Say so when this price cannot be forecast yet.
      facts.trend = "|cffff8c33" .. why .. "|r"
    elseif t.perDay then
      local p = ns.Round(math.abs(t.perDay) * 100)
      facts.trend = (p == 0 and "Steady over the last week"
        or ((t.perDay > 0 and "Rising" or "Falling") .. " about " .. p .. "% a day over the last week"))
        .. ", typically moving \194\177" .. ns.Round(t.swing * 100) .. "% a day."
    else
      facts.trend = "Too few scans over the last week to call a direction (" .. t.scans
        .. " so far); it needs four over at least a day."
    end
  end

  -- How fast it sells, from the auctions that vanished between full scans.
  do
    local sales = ns.Market.Sales(id)
    if sales then
      local function N(x) return x >= 10 and ns.Round(x) or string.format("%.1f", x) end
      local watched = sales.days >= 1 and (N(sales.days) .. " days") or (ns.Round(sales.days * 24 * 10) / 10 .. " h")
      if sales.floor then
        facts.sells = "at least " .. N(sales.lo) .. " a day: most of the cheap ones went between full scans ("
          .. watched .. " watched). Scan more often for a real figure."
      else
        facts.sells = "about " .. N(sales.rate) .. " a day (" .. N(sales.lo) .. " to " .. N(sales.hi)
          .. "), from " .. N(sales.units) .. " judged sold over " .. watched .. " of full scans"
          .. (sales.base and ((sales.base >= sales.days - 0.01) and ", all of it in the base data."
            or ", partly in the base data.") or ".")
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
        facts.when = "cheapest " .. name(cheapest) .. " (about "
          .. ns.Money(pattern.slots[cheapest].est.price) .. "), dearest " .. name(dearest) .. " (about "
          .. ns.Money(pattern.slots[dearest].est.price) .. ")."
      end
    elseif priceMode and pattern.filled >= 2 and cheapest ~= dearest then
      local function name(key) return trendPeriod == "hour" and ("around " .. HourText(key)) or ("on " .. DAY_LONG[key] .. "s") end
      facts.when = "so far cheapest " .. name(cheapest) .. " (" .. Percent(pattern.slots[cheapest].price)
        .. "), dearest " .. name(dearest) .. " (" .. Percent(pattern.slots[dearest].price) .. ")."
    elseif pattern.filled < 2 then
      facts.when = "scans so far cover " .. pattern.filled .. " of " .. slots .. " " .. unit
        .. ", too few to compare times. Scan at other times to fill it in."
    end
  end
  f.optionNote:SetText(priceMode and "green = cheaper than usual, orange = dearer" or "average units listed")
  local lines = {}
  if facts.none then lines[#lines + 1] = facts.none end
  for _, part in ipairs({ { "now", "Now" }, { "trend", "Trend" }, { "sells", "Sells" }, { "when", "When" } }) do
    if facts[part[1]] then lines[#lines + 1] = GOLD .. part[2] .. ":|r " .. facts[part[1]] end
  end
  f.facts:SetText(table.concat(lines, "\n"))

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

------------------------------------------------------------------------------
-- News: what moved in the market over the day and the week, by kind of
-- goods and by profession and rank (News.lua works it out).
------------------------------------------------------------------------------
local news, newsButton
local newsTab = "kinds"
local NEWS_ROWS, NEWS_MOVERS = 17, 5

-- A group's items for a tooltip: the ones that moved most over the day.
local function NewsItemLines(r, items, limit)
  local list = {}
  for _, id in ipairs(items or {}) do
    local c = r.changes[id]
    if c and c.day and not c.thin then list[#list + 1] = { id = id, d = c.day } end
  end
  table.sort(list, function(a, b) return math.abs(a.d) > math.abs(b.d) end)
  for i = 1, math.min(limit, #list) do
    local d = list[i].d
    local p = ns.Round((math.exp(d) - 1) * 100)
    local cr, cg, cb = ns.ItemColor(list[i].id)
    GameTooltip:AddDoubleLine(ns.ItemName(list[i].id), (p > 0 and "+" or "") .. p .. "% over the day",
      cr, cg, cb, d > 0 and 0.3 or 1, d > 0 and 0.85 or 0.4, d > 0 and 0.3 or 0.35)
  end
  if #list > limit then GameTooltip:AddLine("and " .. (#list - limit) .. " more", 0.6, 0.6, 0.6) end
end

local function NewsSumLine(label, s)
  if not s or s.word == "few" then
    GameTooltip:AddDoubleLine(label, "too few items (" .. (s and s.n or 0) .. ")", 1, 0.82, 0, 0.6, 0.6, 0.6)
  else
    GameTooltip:AddDoubleLine(label, ns.News.Words(s, true) .. ", " .. s.n .. " items", 1, 0.82, 0, 1, 1, 1)
  end
end

-- "Over the week", or "Over 3 days" while there is less than a week to compare with.
local function NewsSpanHead(span)
  if not span or span >= 6.5 then return "Over the week" end
  local d = math.floor(span + 0.5)
  return "Over " .. d .. (d == 1 and " day" or " days")
end

-- "week", or "3 days" while there is less than a week to compare with.
local function NewsSpanShort(span)
  if not span or span >= 6.5 then return "week" end
  local d = math.floor(span + 0.5)
  return d .. (d == 1 and " day" or " days")
end

local function CreateNews(parent)
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
  f.title:SetText("Market news")
  local titleHit = CreateFrame("Frame", nil, f)
  titleHit:SetAllPoints(f.title)
  titleHit:EnableMouse(true)
  Tip(titleHit, "How the news is made",
    "Each item's usual price over the newest day of data is compared with the day before and with a "
    .. "week before. A group's change is the middle of its items' changes; the range beside it holds "
    .. "four times in five. It says up or down only when that is three chances in four; otherwise "
    .. "steady (the range stays within 2%) or unclear. Ranks go by the skill where a recipe turns "
    .. "yellow, less 15: roughly where it is learned (the game data does not say).")

  -- In chat once a day.
  local chat = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  chat:SetSize(22, 22)
  chat:SetPoint("TOPRIGHT", -190, -9)
  chat:SetScript("OnClick", function(self) ns.settings.newsChat = self:GetChecked() and true or false end)
  Tip(chat, "Headline in chat", "Once a day, a little after you log in, the day's main moves in one line of chat.")
  local chatLabel = Text(f, "GameFontHighlightSmall")
  chatLabel:SetPoint("LEFT", chat, "RIGHT", 0, 1)
  chatLabel:SetText("Headline in chat once a day")
  f.chat = chat

  f.when = Text(f, "GameFontHighlightSmall")
  f.when:SetPoint("TOPLEFT", 14, -34)
  f.when:SetPoint("TOPRIGHT", -14, -34)
  f.when:SetWordWrap(true)
  f.when:SetMaxLines(2)
  f.lead = Text(f, "GameFontNormal")
  f.lead:SetPoint("TOPLEFT", 14, -62)
  f.lead:SetPoint("TOPRIGHT", -14, -62)
  f.lead:SetWordWrap(true)
  f.lead:SetMaxLines(2)

  -- The biggest single moves of the day, rising on the left, falling on the right.
  f.moverTitles, f.movers = {}, {}
  for side = 1, 2 do
    local x = side == 1 and 14 or 404
    local t = Text(f, "GameFontNormalSmall")
    t:SetPoint("TOPLEFT", x, -98)
    t:SetText(side == 1 and "Rising most over the day" or "Falling most over the day")
    f.moverTitles[side] = t
    f.movers[side] = {}
    for i = 1, NEWS_MOVERS do
      local row = CreateFrame("Button", nil, f)
      row:SetSize(380, 18)
      row:SetPoint("TOPLEFT", x - 4, -114 - (i - 1) * 18)
      row.icon = row:CreateTexture(nil, "ARTWORK")
      row.icon:SetSize(15, 15)
      row.icon:SetPoint("LEFT", 4, 0)
      row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
      row.name = Text(row, "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
      row.name:SetWidth(170)
      row.name:SetWordWrap(false)
      row.change = Text(row, "GameFontHighlightSmall")
      row.change:SetPoint("LEFT", row, "LEFT", 196, 0)
      row.change:SetWidth(180)
      row.change:SetWordWrap(false)
      local hl = row:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 0.82, 0, 0.12)
      row:RegisterForClicks("LeftButtonUp", "Button4Up", "Button5Up")
      row:SetScript("OnClick", function(self, button)
        if UI.NavButton(button) then return end
        if self.data then
          UI.Remember()
          UI.Focus(self.data.id)
          UI.ShowGraph()
        end
      end)
      row:SetScript("OnEnter", function(self)
        local d = self.data
        if not d then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(ns.ItemName(d.id), ns.ItemColor(d.id))
        GameTooltip:AddDoubleLine("Usual price over the day", ns.Money(d.now), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Change from the day before", ns.News.Words(d, true), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddLine("From " .. d.n .. " prices seen over the two days.", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Click to open it in the graph.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      f.movers[side][i] = row
    end
  end

  -- The groups: by kind of goods, or by profession and rank.
  local tabY = -114 - NEWS_MOVERS * 18 - 10
  f.tabs = {}
  local tabDefs = {
    { key = "kinds", text = "By kind of goods", width = 130,
      tip = "Groups by the game's own kinds: Herb, Cloth, Metal & Stone, Potion and so on." },
    { key = "professions", text = "By profession and rank", width = 164,
      tip = "For each profession and rank: the materials its recipes use and the goods they make." },
  }
  local tx = 12
  for _, def in ipairs(tabDefs) do
    local b = Button(f, def.text, def.width)
    b:SetHeight(21)
    b:SetPoint("TOPLEFT", tx, tabY)
    b:SetScript("OnClick", function()
      newsTab = def.key
      f.offset = 0
      ns.Safe(UI.UpdateNews)
    end)
    Tip(b, def.text, def.tip)
    f.tabs[def.key] = b
    tx = tx + def.width + 4
  end
  f.tabNote = Text(f, "GameFontDisableSmall")
  f.tabNote:SetPoint("TOPLEFT", f.tabs.professions, "TOPRIGHT", 10, -5)
  f.tabNote:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, tabY - 5)
  f.tabNote:SetWordWrap(false)

  local headY = tabY - 30
  -- Column positions: the first column, then four.
  f.cols = { 14, 300, 470, 640 }
  f.heads = {}
  for i = 1, 5 do
    local h = Text(f, "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", i == 1 and 14 or (i == 2 and 196 or (i == 3 and 352 or (i == 4 and 508 or 664))), headY)
    f.heads[i] = h
  end
  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.3)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT", 10, headY - 16)
  line:SetPoint("TOPRIGHT", -10, headY - 16)

  f.rows = {}
  for i = 1, NEWS_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(18)
    local y = headY - 20 - (i - 1) * 18
    row:SetPoint("TOPLEFT", 8, y)
    row:SetPoint("TOPRIGHT", -8, y)
    row.cells = {}
    local xs = { 6, 188, 344, 500, 656 }
    local ws = { 178, 152, 152, 152, 140 }
    for c = 1, 5 do
      local fs = Text(row, "GameFontHighlightSmall")
      fs:SetPoint("LEFT", row, "LEFT", xs[c], 0)
      fs:SetWidth(ws[c])
      fs:SetWordWrap(false)
      row.cells[c] = fs
    end
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    row:RegisterForClicks("LeftButtonUp", "Button4Up", "Button5Up")
    row:SetScript("OnClick", function(_, button) UI.NavButton(button) end)
    row:SetScript("OnEnter", function(self)
      local d, r = self.data, ns.News and ns.News.result
      if not d or not r or not r.changes then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if d.kind then
        GameTooltip:SetText(d.kind.name)
        NewsSumLine("Over the day", d.kind.day)
        NewsSumLine(NewsSpanHead(d.kind.span), d.kind.week)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Moved most:", 1, 0.82, 0)
        NewsItemLines(r, d.kind.items, 10)
      elseif d.rank then
        GameTooltip:SetText(d.profession .. ", " .. d.rank.name)
        GameTooltip:AddLine("Materials its recipes use", 1, 0.82, 0)
        NewsSumLine("  over the day", d.rank.mats.day)
        NewsSumLine("  " .. NewsSpanHead(d.rank.mats.span):lower(), d.rank.mats.week)
        NewsItemLines(r, d.rank.mats.items, 6)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Goods its recipes make", 1, 0.82, 0)
        NewsSumLine("  over the day", d.rank.goods.day)
        NewsSumLine("  " .. NewsSpanHead(d.rank.goods.span):lower(), d.rank.goods.week)
        NewsItemLines(r, d.rank.goods.items, 6)
      else
        GameTooltip:Hide()
        return
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.rows[i] = row
  end
  f.more = Text(f, "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 14, 8)
  f.offset = 0
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(self, delta)
    self.offset = math.max(0, self.offset - delta * 3)
    ns.Safe(UI.UpdateNews)
  end)
  return f
end

-- What the newest data is and how old, in words.
local function NewsWhen(r)
  local age = time() - r.anchor
  local from = r.anchorFrom == "own" and "your scans" or (r.anchorFrom == "online" and "Blizzard's hourly data"
    or "the base data shipped with the addon")
  local text = "Newest data " .. ns.Age(age) .. " (" .. from .. "). The day is the 24 hours up to it, against "
    .. "the 24 hours before; the week against a week before."
  if age > 86400 then
    return "|cffff8c33" .. text .. " This is not today's news: scan at the auction house to bring it up to date.|r"
  end
  return GREY .. text .. "|r"
end

function UI.UpdateNews()
  if not news or not news:IsShown() then return end
  local f = news
  f.chat:SetChecked(ns.settings.newsChat ~= false)
  for key, b in pairs(f.tabs) do
    if key == newsTab then b:LockHighlight() else b:UnlockHighlight() end
  end
  if not ns.News then
    -- News.lua is new: the game reads a new file only when it starts.
    f.when:SetText("|cffff8c33The news needs a full restart of the game (a new file was added); /reload is not enough.|r")
    f.lead:SetText("")
    return
  end
  local r = ns.News.result
  local progress = ns.News.Progress()
  local function Clear()
    for side = 1, 2 do
      for _, row in ipairs(f.movers[side]) do row.data = nil row:Hide() end
    end
    for _, row in ipairs(f.rows) do row.data = nil row:Hide() end
    for _, h in ipairs(f.heads) do h:SetText("") end
    f.more:SetText("")
    f.tabNote:SetText("")
  end
  if not r or r.empty then
    Clear()
    if progress then
      f.when:SetText(GREY .. "Working it out ... " .. ns.Round(progress * 100) .. "%|r")
      f.lead:SetText("")
    else
      f.when:SetText(GREY .. "No prices yet.|r")
      f.lead:SetText("Scan at the auction house (Full scan). The news compares days, so it starts the day "
        .. "after your first scan; the week needs a week.")
    end
    return
  end
  f.when:SetText(NewsWhen(r) .. (progress and (GREY .. "  Updating ... " .. ns.Round(progress * 100) .. "%|r") or ""))
  local lead = {}
  if r.all.day.word ~= "few" then lead[#lead + 1] = "over the day " .. ns.News.Words(r.all.day) end
  if r.all.week.word ~= "few" then
    lead[#lead + 1] = ns.News.SpanWords(r.all.span) .. " " .. ns.News.Words(r.all.week)
  end
  if #lead == 0 then
    f.lead:SetText("Prices overall: " .. GREY .. "too little history to compare yet (it needs two days).|r")
  else
    f.lead:SetText("Prices overall: " .. table.concat(lead, "; ") .. GREY .. ". " .. (r.items - (r.thin or 0)) .. " items"
      .. ((r.thin or 0) > 0 and ("; " .. r.thin .. " with only one or two on sale are left out (asking prices, not a market)") or "")
      .. ".|r")
  end

  -- Single movers.
  for side = 1, 2 do
    local list = side == 1 and r.rising or r.falling
    for i, row in ipairs(f.movers[side]) do
      local d = list[i]
      row.data = d
      row:SetShown(d ~= nil)
      if d then
        row.icon:SetTexture(ns.ItemIcon(d.id))
        row.name:SetText(ns.ItemName(d.id))
        row.name:SetTextColor(ns.ItemColor(d.id))
        d.word = d.change > 0 and "up" or "down"
        row.change:SetText(ns.News.Words(d))
      end
    end
    if #list == 0 then
      f.moverTitles[side]:SetText((side == 1 and "Rising" or "Falling") .. " most over the day" .. GREY .. ": none surely|r")
    else
      f.moverTitles[side]:SetText(side == 1 and "Rising most over the day" or "Falling most over the day")
    end
  end

  -- The table.
  local lines = {}
  if newsTab == "kinds" then
    f.heads[1]:SetText("Kind of goods")
    f.heads[2]:SetText("Items")
    f.heads[3]:SetText("Over the day")
    f.heads[4]:SetText(NewsSpanHead(r.all.span))
    f.heads[5]:SetText("")
    for _, k in ipairs(r.kinds) do
      lines[#lines + 1] = { kind = k, cells = { k.name, tostring(#k.items), ns.News.Words(k.day), ns.News.Words(k.week), "" } }
    end
    if not r.kindsKnown then
      f.tabNote:SetText("The game did not say the kinds of items yet; try again in a moment.")
    elseif r.kindsLeft > 0 then
      f.tabNote:SetText(r.kindsLeft .. (r.kindsLeft == 1 and " smaller kind" or " smaller kinds") .. " left out: fewer than "
        .. ns.News.MIN_ITEMS .. " items with a change.")
    else
      f.tabNote:SetText("")
    end
  else
    f.heads[1]:SetText("Profession, rank")
    f.heads[2]:SetText("Materials: day")
    f.heads[3]:SetText("Materials: " .. NewsSpanShort(r.all.span))
    f.heads[4]:SetText("Goods: day")
    f.heads[5]:SetText("Goods: " .. NewsSpanShort(r.all.span))
    for _, p in ipairs(r.professions) do
      lines[#lines + 1] = { header = true, cells = { GOLD .. p.name .. "|r", "", "", "", "" } }
      for _, rank in ipairs(p.ranks) do
        if #rank.mats.items + #rank.goods.items > 0 then
          lines[#lines + 1] = { rank = rank, profession = p.name, cells = { "   " .. rank.name,
            ns.News.Words(rank.mats.day), ns.News.Words(rank.mats.week),
            ns.News.Words(rank.goods.day), ns.News.Words(rank.goods.week) } }
        end
      end
    end
    f.tabNote:SetText("Hover a row for the items behind it. Ranks by where a recipe turns yellow, less 15.")
  end
  f.offset = math.min(f.offset, math.max(0, #lines - NEWS_ROWS))
  for i, row in ipairs(f.rows) do
    local line = lines[f.offset + i]
    row.data = line
    row:SetShown(line ~= nil)
    if line then
      for c = 1, 5 do row.cells[c]:SetText(line.cells[c]) end
    end
  end
  if #lines > NEWS_ROWS then
    f.more:SetText("Rows " .. (f.offset + 1) .. " to " .. math.min(#lines, f.offset + NEWS_ROWS) .. " of " .. #lines
      .. ": scroll for more.")
  else
    f.more:SetText("")
  end
end

ns.Listen("NEWS", function() ns.Safe(UI.UpdateNews) end)

-- The main area shows one of these: "graph", "worth", "sell", "trends", "news" or "data".
-- The Data page: its sub-pages are picked with the buttons along its top.
local dataPage, dataButton, graphButton
local dataTab = "sources"
local DATA_TABS = {
  { key = "sources", text = "Data sources", width = 108 },
  { key = "blizzard", text = "Blizzard prices", width = 112 },
  { key = "share", text = "Share prices", width = 100 },
  { key = "github", text = "Online sharing", width = 108 },
  { key = "sales", text = "Sales seen", width = 92 },
}

local function CreateDataPage(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetPoint("TOPLEFT", 3, -3)
  f:SetPoint("BOTTOMRIGHT", -3, 3)
  f:Hide()
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.04, 0.03, 0.92)
  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function(_, button) UI.NavButton(button) end)
  f.tabs, f.panes = {}, {}
  local x = 12
  for _, def in ipairs(DATA_TABS) do
    local b = Button(f, def.text, def.width)
    b:SetHeight(21)
    b:SetPoint("TOPLEFT", x, -10)
    b:SetScript("OnClick", function() ns.Safe(UI.SelectDataTab, def.key) end)
    f.tabs[def.key] = b
    x = x + def.width + 4
    local pane = CreateFrame("Frame", nil, f)
    pane:SetPoint("TOPLEFT", 0, -38)
    pane:SetPoint("BOTTOMRIGHT", 0, 0)
    pane:Hide()
    f.panes[def.key] = pane
  end
  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.3)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT", 10, -35)
  line:SetPoint("TOPRIGHT", -10, -35)
  return f
end

local function CurrentMode()
  if dataPage and dataPage:IsShown() then return "data" end
  if worth and worth:IsShown() then return "worth" end
  if sell and sell:IsShown() then return "sell" end
  if trends and trends:IsShown() then return "trends" end
  if news and news:IsShown() then return "news" end
  return "graph"
end

local function SetMode(mode)
  if not worth then return end
  worth:SetShown(mode == "worth")
  sell:SetShown(mode == "sell")
  trends:SetShown(mode == "trends")
  news:SetShown(mode == "news")
  dataPage:SetShown(mode == "data")
  if mode == "data" then ns.Safe(UI.SelectDataTab, dataTab) end
  view:SetShown(mode == "graph")
  -- The page buttons keep their names; the one in view is lit.
  for key, button in pairs({ graph = graphButton, worth = worthButton, sell = sellButton, trends = trendsButton,
    news = newsButton, data = dataButton }) do
    if key == mode then button:LockHighlight() else button:UnlockHighlight() end
  end
  UI.mode = mode
  if mode == "trends" then ns.Safe(UI.UpdateTrends) end
  if mode == "news" then
    news.offset = 0
    ns.Safe(UI.UpdateNews)
    if ns.News then ns.News.Refresh() end
  end
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

function UI.ShowNews(show, quiet)
  if not news then return end
  if show == nil then show = not news:IsShown() end
  SetMode(show and "news" or "graph")
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
local HUD_W, HUD_ROW, HUD_HEAD, HUD_FOOT = 370, 66, 48, 34
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
  hud.lines = {}          -- step lines, made as they are needed
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
    -- What one costs and brings, and the same for all of them.
    row.status = Text(row, "GameFontHighlightSmall")
    row.status:SetPoint("TOPLEFT", row, "TOPLEFT", 38, -19)
    row.status:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -19)
    row.status:SetWordWrap(false)
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
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Step by step", 1, 0.82, 0)
      for i, step in ipairs(ns.Jobs.Steps(nil, nil, job)) do
        local money = step.cost and step.cost > 0 and ("costs " .. ns.Money(step.cost))
          or step.gain and ("brings " .. ns.Money(step.gain)) or " "
        if step.now then
          GameTooltip:AddDoubleLine("> " .. step.text, money, 1, 0.82, 0, 1, 1, 1)
        else
          GameTooltip:AddDoubleLine(i .. ". " .. step.text, money, 1, 1, 1, 1, 1, 1)
        end
        if step.where then GameTooltip:AddLine("    " .. step.where, 0.6, 0.6, 0.6, true) end
      end
      local pin = job.pin
      local m = ns.Jobs.Money(job)
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("Money", "each / all " .. ns.Round(m.units), 1, 0.82, 0, 1, 0.82, 0)
      local function Pair(label, each, all)
        GameTooltip:AddDoubleLine(label, ns.Money(each) .. "  /  " .. ns.Money(all), 1, 1, 1, 1, 1, 1)
      end
      Pair(m.trade and "Costs to buy" or "Costs to make", m.costEach, m.cost)
      Pair(m.toVendor and "A vendor pays" or "Sells for, after the cut",
        m.sellEach, m.income)
      GameTooltip:AddDoubleLine("Still to spend", ns.Money(m.toSpend), 1, 1, 1, 1, 1, 1)
      if m.units > m.qty then
        GameTooltip:AddLine("The recipe makes " .. ns.Round(m.units) .. ", so the extra are counted as sold too.",
          0.6, 0.6, 0.6, true)
      end
      if pin.goal then
        GameTooltip:AddLine("Goal: " .. ns.Deals.KIND[pin.goal.kind]:lower() .. ", planned for "
          .. Signed(pin.goal.profit or 0) .. ".", 1, 0.82, 0, true)
      end
      -- What the auction house keeps, and what could be lost.
      if not pin.goal then
        local e = ns.Opt.Evaluate(pin.id, pin.qty)
        if e.profit and e.revenue then
          local cut = ns.settings.cut or 0.05
          local bad = e.profit - 2 * (e.sd or 0)
          GameTooltip:AddLine(" ")
          GameTooltip:AddDoubleLine("Auction house cut (" .. ns.Round(cut * 100) .. "%), already taken off",
            ns.Money(e.revenue * cut / (1 - cut)), 1, 1, 1, 1, 1, 1)
          GameTooltip:AddDoubleLine("If prices turn", bad < 0 and ("|cffff5040could lose " .. ns.Money(-bad) .. "|r")
            or ("|cff40ff40still +" .. ns.Money(bad) .. "|r"), 1, 1, 1, 1, 1, 1)
        end
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

  -- The whole plan: what it costs, what is left to spend, what it brings.
  hud.total = Text(hud, "GameFontHighlightSmall")
  hud.total:SetPoint("BOTTOMLEFT", 12, 8)
  hud.total:SetPoint("BOTTOMRIGHT", -12, 8)
  hud.total:SetJustifyH("LEFT")
  hud.total:SetWordWrap(true)

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
    text = text .. (moved < 0 and " |cffff5040fell " or " |cff40ff40rose ") .. ns.Money(math.abs(Short(moved))) .. "|r"
  end
  if st.n >= 3 then
    text = text .. GREY .. "  med|r " .. Signed(Short(st.median)) .. GREY .. "  avg|r " .. Signed(Short(st.mean))
  end
  return text
end

-- One line on a planned item's money: what one costs to make and sells
-- for after the cut, then the same for all of them.
function UI.UnitText(m)
  return GREY .. "Each|r " .. ns.Money(m.costEach) .. GREY .. (m.trade and " to buy" or " to make")
    .. (m.toVendor and ", vendor pays|r " or ", sells|r ") .. ns.Money(m.sellEach)
    .. GREY .. "   All " .. ns.Round(m.units) .. ":|r " .. ns.Money(m.cost) .. GREY .. " to|r " .. ns.Money(m.income)
end

-- Two lines on the whole plan: what following it costs and what is left
-- to spend, then what selling everything brings and the profit.
function UI.TotalText(all)
  local text = "|cffffd100Whole plan|r costs " .. ns.Money(all.cost) .. GREY .. ", still to spend|r "
    .. ns.Money(all.toSpend) .. "\n" .. GREY .. "Sold, it brings|r " .. ns.Money(all.income)
    .. GREY .. " after any cut:|r " .. Signed(all.profit)
  if all.unknown > 0 then
    text = text .. GREY .. " (" .. all.unknown .. (all.unknown == 1 and " item" or " items") .. " not priced)|r"
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
  local y, used = -24, 0
  for i, row in ipairs(hud.rows) do
    local job = jobs[i]
    row.job = job
    if job then
      -- The item, then its steps with their buttons, then what is finished.
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 6, y)
      row:SetPoint("TOPRIGHT", -6, y)
      row:SetHeight(HUD_HEAD - 2)
      y = y - HUD_HEAD
      local entries = UI.StepEntries(nil, nil, job, { limit = 7 })
      row.entries = entries
      for _, e in ipairs(entries) do
        used = used + 1
        if not hud.lines[used] then
          hud.lines[used] = UI.CreateStepLines(hud, 1, 54)[1]
        end
        local line = hud.lines[used]
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", 44, y)
        line:SetPoint("TOPRIGHT", -10, y)
        UI.FillStepLines({ line }, { e })
        y = y - 17
      end
      y = y - 4
      local r, g, b = ns.ItemColor(job.pin.id)
      row.icon:SetTexture(ns.ItemIcon(job.pin.id))
      row.name:SetText(ns.ItemName(job.pin.id) .. " |cffffffffx" .. job.pin.qty .. "|r")
      row.name:SetTextColor(r, g, b)
      -- The next step is the first of the lines below, with its button.
      row.status:SetText(UI.UnitText(ns.Jobs.Money(job)))
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
  for i = used + 1, #hud.lines do hud.lines[i]:Hide() end
  hud.usedLines = used
  hud.total:SetText(UI.TotalText(ns.Jobs.MoneyAll(jobs)))
  local height = 6 - y + HUD_FOOT
  local foot = 8 + HUD_FOOT
  hud.buy:Hide()
  if ns.Jobs.place == "merchant" then
    local offer, total = ns.Jobs.MerchantOffer()
    if #offer > 0 then
      hud.buy:SetText("Buy all here: " .. ns.Money(total))
      hud.buy:ClearAllPoints()
      hud.buy:SetPoint("BOTTOM", 0, foot)
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
    hud.mail:SetPoint("BOTTOM", 0, hud.buy:IsShown() and foot + 26 or foot)
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
-- What one craft of the thing a line leads to earns, as short coloured
-- text ("+35c/craft"), or nil when it cannot be told.
function UI.EdgeProfit(e)
  local product = e.from
  if not product or not ns.Opt.IsCraftable(product) then return nil end
  local ev = ns.Opt.Evaluate(product, 1)
  if not ev.profit then return nil end
  local profit = ns.Round(ev.profit)
  return (profit < 0 and "|cffff5040-" or "|cff40ff40+") .. ns.Money(math.abs(profit)) .. "|r" .. GREY .. "/craft|r"
end

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
  -- Said plainly on the window itself: this is an experiment.
  local trial = CreateFrame("Button", nil, frame)
  trial:SetSize(110, 16)
  trial:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -3)
  trial:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)
  trial.text = trial:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  trial.text:SetAllPoints()
  trial.text:SetJustifyH("RIGHT")
  trial.text:SetText("|cffff2020EXPERIMENTAL|r")
  Tip(trial, "Experimental (version " .. ns.VERSION .. ")",
    "CraftGraph is a prototype. It has been tried in the game, but not for long. Figures can be wrong and "
    .. "buttons can misbehave: look at what it proposes before you spend gold, and say what breaks.")
  frame.trial = trial
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
  search:SetSize(124, 20)
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
  -- The pages, in a row; the one in view is lit.
  newsButton = Button(frame, "News", 56)
  newsButton:SetPoint("LEFT", fullButton, "RIGHT", 14, 0)
  newsButton:SetScript("OnClick", function() UI.ShowNews() end)
  Tip(newsButton, "News",
    "What moved in the market over the day and the week: overall, the biggest single moves, by kind "
    .. "of goods, and by profession and rank. Also /cg news.")
  graphButton = Button(frame, "Graph", 62)
  graphButton:SetPoint("LEFT", newsButton, "RIGHT", 4, 0)
  graphButton:SetScript("OnClick", function() UI.ShowGraph() end)
  Tip(graphButton, "Graph", "What the chosen item is made from and used in, with prices on every step.")
  worthButton = Button(frame, "Opportunities", 108)
  worthButton:SetPoint("LEFT", graphButton, "RIGHT", 4, 0)
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
  dataButton = Button(frame, "Data", 56)
  dataButton:SetPoint("LEFT", trendsButton, "RIGHT", 4, 0)
  dataButton:SetScript("OnClick", function() ns.Safe(UI.ShowData) end)
  Tip(dataButton, "Data",
    "Where prices come from and go to: switch data sources on and off, import and export prices, "
    .. "the shared repository on GitHub, and the list of sales seen between scans.")
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
  dataPage = CreateDataPage(inset)
  news = CreateNews(inset)

  panel = CreatePanel(frame)
  UI.sidePanel, panel.rows = panel, rows

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
  UI.UpdateNews()
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
    -- With no item chosen yet there is nothing to draw: start on the list
    -- of what pays now.
    if not state.center then UI.ShowWorth(true, true) end
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
      return "not set up: see the Blizzard prices page"
    end,
    there = function() return ns.Online and ns.Online ~= false and ns.Online.realm == ns.realmKey end,
    tip = "Prices, depth and sales from Blizzard's hourly auction data, brought in by the optional sync "
      .. "tool. Used where it is newer than your own scan." },
  { key = "Shared", text = "Prices shared by another player",
    note = function()
      local people = ns.Market.Contributors()
      if #people == 0 then return "none imported (/cg share)" end
      local total = 0
      for _, c in ipairs(people) do total = total + c.items end
      return total .. " prices from " .. #people .. (#people == 1 and " player" or " players") .. ", listed below"
    end,
    tip = "Prices other players exported and you imported (/cg share, a .cg.json file, or the shared "
      .. "data repository). Used where they are newer than your own scan, and never mixed into your "
      .. "own history. Each player below has a switch of their own." },
  { key = "Auctionator", text = "Auctionator's prices",
    there = function() return _G.Auctionator ~= nil end,
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
  { key = "Base", text = "Base data shipped with the addon",
    note = function()
      local b = ns.Base
      if not b then return "none in this version" end
      if b.realm ~= ns.realmKey then return "for another auction house: " .. tostring(b.realm) end
      local span = date("%d %b", b.from) .. " to " .. date("%d %b", b.to)
      if not ns.Market.Source("Base") then return span .. ", switched off" end
      return b.scans .. " full scans, " .. span .. " (" .. ns.Age(time() - b.to) .. "); used before your own"
    end,
    there = function() return ns.Base and ns.Base.realm == ns.realmKey end,
    tip = "Prices the addon's author scanned on this auction house, shipped with the addon so that a new "
      .. "install starts with some history: prices, depth, how listings are stacked, how fast things sold "
      .. "and vendor prices. For each item it is used only for the time before your own first scan of it, "
      .. "so your own scans always come first. It holds no seller or character names and none of "
      .. "Blizzard's web data." },
}

function UI.SourcesText()
  local off = {}
  for _, def in ipairs(SOURCES) do
    if not ns.Market.Source(def.key) then off[#off + 1] = def.text end
  end
  if #off == 0 then return nil end
  return "|cffff8c33Switched off: " .. table.concat(off, ", ") .. ".|r"
end

local PEOPLE_ROWS = 8

local function UpdateSources()
  if not sourcesFrame then return end
  for _, row in ipairs(sourcesFrame.rows) do
    -- A source that is not there cannot be on: no tick, and the reason.
    local there = not row.def.there or row.def.there()
    row.check:SetChecked(there and ns.Market.Source(row.def.key))
    row.check:SetEnabled(there)
    row.note:SetText(GREY .. row.def.note() .. "|r")
  end
  -- One line per player whose prices are held, each with its own switch.
  local people = ns.Market.Contributors()
  local shown = math.min(#people, PEOPLE_ROWS)
  for i = 1, PEOPLE_ROWS do
    local row, c = sourcesFrame.people[i], people[i]
    row.name = c and c.name or nil
    row.check:SetShown(c ~= nil)
    row.label:SetShown(c ~= nil)
    if c and c.self then
      -- You: shown to say you are there; your own prices are never imported.
      row.name = nil
      row.check:SetChecked(false)
      row.check:SetEnabled(false)
      row.label:SetText("|cff66ff66You (" .. c.name .. ")|r" .. GREY .. "  sharing " .. c.items .. (c.items == 1 and " price" or " prices") .. ", scanned "
        .. ns.Age(time() - (c.made or 0)) .. "; your own are not imported|r")
    elseif c then
      row.check:SetChecked(c.on)
      row.check:SetEnabled(ns.Market.Source("Shared"))
      row.label:SetText(c.name .. GREY .. "  " .. c.items .. " prices, scanned " .. ns.Age(time() - (c.made or 0))
        .. (c.github and (", github: " .. c.github) or "") .. "|r")
    end
  end
  sourcesFrame.morePeople:SetText(#people > PEOPLE_ROWS and (GREY .. "and " .. (#people - PEOPLE_ROWS) .. " more players|r") or "")
  sourcesFrame.peopleTitle:SetShown(#people > 0)
  sourcesFrame:SetHeight(sourcesFrame.baseHeight + (#people > 0 and (26 + shown * 20 + (#people > PEOPLE_ROWS and 16 or 0)) or 0))
  sourcesFrame.guess:SetChecked(ns.settings.showGuesses and true or false)
end

local function BuildSources()
  if not sourcesFrame then
    local f = CreateFrame("Frame", "CraftGraphSources", dataPage.panes.sources, "BackdropTemplate")
    f:SetSize(330, 62 + #SOURCES * 38)
    f:SetPoint("TOPLEFT", 12, -8)
    f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:EnableMouse(true)
    local title = Text(f, "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Data sources")
    local own = Text(f, "GameFontHighlightSmall")
    own:SetPoint("TOPLEFT", 12, -30)
    own:SetText("Your own scans are always used. Untick one to see the numbers without it.")
    own:SetPoint("TOPRIGHT", -12, -30)
    own:SetWordWrap(true)
    own:SetMaxLines(2)
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
    -- Not a source: whether to show forecasts that are only guesses.
    local gy = -58 - #SOURCES * 38
    local guess = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    guess:SetSize(24, 24)
    guess:SetPoint("TOPLEFT", 10, gy)
    guess:SetScript("OnClick", function(self)
      ns.settings.showGuesses = self:GetChecked() and true or false
      ns.generation = ns.generation + 1
      ns.Fire("MARKET_UPDATED")
    end)
    Tip(guess, "Show guesses", "Normally a forecast or an hour-and-weekday pattern is shown only when there is "
      .. "enough to go on: at least 8 scans over 2 days, and a price that does not jump about too much. "
      .. "Tick this to see them everywhere, for curiosity.")
    local glabel = Text(f, "GameFontHighlight")
    glabel:SetPoint("TOPLEFT", guess, "TOPRIGHT", 2, -2)
    glabel:SetText("Display: show forecasts that are only guesses")
    local gnote = Text(f, "GameFontDisableSmall")
    gnote:SetPoint("TOPLEFT", glabel, "BOTTOMLEFT", 0, -2)
    gnote:SetText("off: hidden where they would mislead")
    f.guess = guess
    f.baseHeight = 62 + (#SOURCES + 1) * 38 + 30
    f:SetHeight(f.baseHeight)
    f:SetWidth(560)
    -- Players whose shared prices are held.
    local py = -58 - (#SOURCES + 1) * 38 - 4
    f.peopleTitle = Text(f, "GameFontNormalSmall")
    f.peopleTitle:SetPoint("TOPLEFT", 14, py)
    f.peopleTitle:SetText("Players sharing prices with you")
    f.people = {}
    for i = 1, PEOPLE_ROWS do
      local y = py - 18 - (i - 1) * 20
      local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
      check:SetSize(20, 20)
      check:SetPoint("TOPLEFT", 12, y)
      local label = Text(f, "GameFontHighlightSmall")
      label:SetPoint("LEFT", check, "RIGHT", 2, 0)
      label:SetWidth(500)
      label:SetWordWrap(false)
      local row = { check = check, label = label }
      check:SetScript("OnClick", function(self)
        if row.name then ns.Market.SetContributor(row.name, self:GetChecked() and true or false) end
      end)
      Tip(check, "One player's prices", "Untick to leave this player's prices out and see what changes.")
      f.people[i] = row
    end
    f.morePeople = Text(f, "GameFontDisableSmall")
    f.morePeople:SetPoint("TOPLEFT", 16, py - 18 - PEOPLE_ROWS * 20)
    local share = Button(f, "Share prices ...", 130)
    share:SetPoint("BOTTOMLEFT", 12, 10)
    share:SetScript("OnClick", function() ns.Safe(UI.SelectDataTab, "share") end)
    Tip(share, "Share prices", "Export the prices of your latest scans as text for another player, or "
      .. "import what another player sent you.")
    sourcesFrame = f
    UI.sourcesFrame = f
  end
  sourcesFrame:Show()
  UpdateSources()
end

ns.Listen("SOURCES", function()
  UpdateSources()
end)

------------------------------------------------------------------------------
-- Sharing prices: a box of text to copy out of or paste into. What an
-- import did is always said in plain words under the box, green when it
-- worked and orange when it did not.
------------------------------------------------------------------------------
local shareFrame
local forceNext = false

local function ShareSay(text, ok)
  shareFrame.result:SetText(text or "")
  if ok == true then shareFrame.result:SetTextColor(0.3, 1, 0.3)
  elseif ok == false then shareFrame.result:SetTextColor(1, 0.55, 0.2)
  else shareFrame.result:SetTextColor(0.8, 0.8, 0.8) end
end

function UI.ShareExport()
  local text, count = ns.Market.Export()
  shareFrame.box:SetText(text)
  if shareFrame.box.HighlightText then shareFrame.box:HighlightText() end
  if shareFrame.box.SetFocus then shareFrame.box:SetFocus() end
  if count == 0 then
    ShareSay("Nothing to export: no scan of your own in the last day. Do a full scan first.", false)
  else
    ShareSay("Exported " .. count .. " prices (" .. ns.Round(#text / 1024) .. " KB). Press Ctrl+C to copy, then send it "
      .. "or save it as a file ending in .cg.json.", true)
  end
  forceNext = false
  return count
end

function UI.ShareImport()
  local result = ns.Market.Import(shareFrame.box:GetText(), forceNext)
  forceNext = result.otherRealm or false
  ns.Market.lastImport = result
  ShareSay(result.text, result.ok)
  return result
end

local function BuildShare()
  if not shareFrame then
    local f = CreateFrame("Frame", "CraftGraphShare", dataPage.panes.share, "BackdropTemplate")
    f:SetSize(620, 420)
    f:SetPoint("TOPLEFT", 12, -8)
    f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:EnableMouse(true)
    local title = Text(f, "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Share prices")
    local help = Text(f, "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 12, -30)
    help:SetPoint("TOPRIGHT", -12, -30)
    help:SetWordWrap(true)
    help:SetMaxLines(2)
    help:SetText("Export puts the prices of your scans from the last day in the box as text, to copy and send. "
      .. "To take in what someone sent you, paste it into the box and press Import.")

    local scroll = CreateFrame("ScrollFrame", "CraftGraphShareScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -64)
    scroll:SetPoint("BOTTOMRIGHT", -34, 76)
    local back = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    back:SetPoint("TOPLEFT", scroll, -4, 4)
    back:SetPoint("BOTTOMRIGHT", scroll, 4, -4)
    back:SetColorTexture(0, 0, 0, 0.55)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetWidth(560)
    box:SetMaxLetters(0)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    f.box = box

    f.result = Text(f, "GameFontHighlightSmall")
    f.result:SetPoint("BOTTOMLEFT", 14, 36)
    f.result:SetPoint("BOTTOMRIGHT", -14, 36)
    f.result:SetWordWrap(true)
    f.result:SetMaxLines(3)
    f.result:SetJustifyV("BOTTOM")

    local export = Button(f, "Export my prices", 130)
    export:SetPoint("BOTTOMLEFT", 12, 10)
    export:SetScript("OnClick", function() ns.Safe(UI.ShareExport) end)
    local import = Button(f, "Import what is in the box", 170)
    import:SetPoint("LEFT", export, "RIGHT", 6, 0)
    import:SetScript("OnClick", function() ns.Safe(UI.ShareImport) end)
    local forget = Button(f, "Forget shared prices", 140)
    forget:SetPoint("BOTTOMRIGHT", -12, 10)
    forget:SetScript("OnClick", function()
      ns.Market.ClearShared()
      ShareSay("Shared prices forgotten: only your own scans and the other sources are used.", nil)
    end)
    shareFrame = f
    UI.shareFrame = f
  end
  shareFrame:Show()
end

-- Opens the import and export page. mode "import": an empty box to paste
-- into; otherwise the player's prices are exported into the box.
function UI.ShowShare(mode)
  UI.ShowData("share")
  forceNext = false
  if mode == "import" then
    shareFrame.box:SetText("")
    if shareFrame.box.SetFocus then shareFrame.box:SetFocus() end
    local last = ns.Market.lastImport
    ShareSay(last and ("Last time: " .. last.text) or "Paste the text here (Ctrl+V), then press Import.", last and last.ok or nil)
  else
    UI.ShareExport()
  end
end

------------------------------------------------------------------------------
-- The GitHub page: the game cannot reach the internet, so this page says
-- what is here, who is sharing, and what to run outside the game.
------------------------------------------------------------------------------
local githubPane
local DATA_REPO = "https://github.com/t-more/craftgraph-data"

local function CopyBox(parent, y, label, text)
  local l = Text(parent, "GameFontHighlightSmall")
  l:SetPoint("TOPLEFT", 16, y)
  l:SetPoint("TOPRIGHT", -16, y)
  l:SetWordWrap(true)
  l:SetMaxLines(2)
  l:SetText(label)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(640, 20)
  box:SetPoint("TOPLEFT", 22, y - 17)
  box:SetAutoFocus(false)
  box:SetText(text)
  -- The text is there to be copied, not changed.
  box:SetScript("OnTextChanged", function(self, user) if user then self:SetText(text) end end)
  box:SetScript("OnEditFocusGained", function(self) if self.HighlightText then self:HighlightText() end end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return box
end

local function BuildGitHub()
  if githubPane then return end
  local f = dataPage.panes.github
  githubPane = f
  UI.githubPane = f
  f.title = Text(f, "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 16, -10)
  f.title:SetText("Prices shared on GitHub (optional)")
  f.intro = Text(f, "GameFontHighlightSmall")
  f.intro:SetPoint("TOPLEFT", 16, -30)
  f.intro:SetPoint("TOPRIGHT", -16, -30)
  f.intro:SetWordWrap(true)
  f.intro:SetMaxLines(3)
  f.intro:SetSpacing(2)
  f.intro:SetText("Players who want to can pool the prices of their latest scans in one public place, each "
    .. "under their character's name. The game cannot reach the internet, so a small optional program "
    .. "on your computer does the fetching and sharing, and the game takes it in when you log in. "
    .. "Without it nothing here changes: everything else is local.")
  f.status = Text(f, "GameFontHighlight")
  f.status:SetPoint("TOPLEFT", 16, -84)
  f.status:SetPoint("TOPRIGHT", -16, -84)
  f.status:SetWordWrap(true)
  f.status:SetMaxLines(2)
  f.people = Text(f, "GameFontHighlightSmall")
  f.people:SetPoint("TOPLEFT", 16, -122)
  f.people:SetPoint("TOPRIGHT", -16, -122)
  f.people:SetWordWrap(true)
  f.people:SetMaxLines(4)
  f.people:SetSpacing(2)
  f.people:SetJustifyV("TOP")
  local head = Text(f, "GameFontNormal")
  head:SetPoint("TOPLEFT", 16, -196)
  head:SetText("To connect (outside the game; click a box and press Ctrl+C to copy)")
  f.boxes = {
    CopyBox(f, -218, "1. The shared place. Open it to see who shares, and to ask to be let in:", DATA_REPO),
    CopyBox(f, -266, "2. Fetch what others share. Needs Python 3, no account. Run in the CraftGraph addon folder:",
      "python3 sync/craftgraph_sync.py data-pull"),
    CopyBox(f, -314, "3. Share yours as well. Needs the GitHub CLI logged in (gh auth login) and the owner's go-ahead:",
      "python3 sync/craftgraph_sync.py data-sync"),
  }
  f.note = Text(f, "GameFontDisableSmall")
  f.note:SetPoint("TOPLEFT", 16, -368)
  f.note:SetPoint("TOPRIGHT", -16, -368)
  f.note:SetWordWrap(true)
  f.note:SetMaxLines(3)
  f.note:SetText("Sharing is your own choice and your own responsibility. It makes public: your character's name, your GitHub name, and the prices from your scans "
    .. "of the last day. Each player you fetch has a switch of their own on the Data sources page, and your "
    .. "own prices are never imported back.")
end

function UI.UpdateGitHub()
  BuildGitHub()
  local f = githubPane
  local people = ns.Market.Contributors()
  local me, others, names = nil, 0, {}
  for _, c in ipairs(people) do
    if c.self then
      me = c
    else
      others = others + 1
      names[#names + 1] = c.name .. GREY .. " (" .. c.items .. ", " .. ns.Age(time() - (c.made or 0)) .. ")|r"
    end
  end
  if me then
    f.status:SetText("|cff66ff66You are sharing|r as " .. me.name .. (me.github and (" (GitHub: " .. me.github .. ")") or "")
      .. ": " .. me.items .. " prices, scanned " .. ns.Age(time() - (me.made or 0)) .. ".")
  elseif others > 0 then
    f.status:SetText("You are fetching what others share. Your own prices are not seen among them.")
  else
    f.status:SetText("|cffff8c33Not connected:|r nothing has been fetched yet. The steps are below.")
  end
  if others > 0 then
    f.people:SetText(others .. (others == 1 and " player" or " players") .. " fetched: " .. table.concat(names, ", ")
      .. ". Their switches are on the Data sources page.")
  else
    f.people:SetText(GREY .. "No other player's prices are held.|r")
  end
  f.others, f.me = others, me
end

------------------------------------------------------------------------------
-- The Blizzard prices page: how to set the hourly data up, whose key it is,
-- and the thirty days their terms allow the data to be kept.
------------------------------------------------------------------------------
local blizzardPane
local TERMS_URL = "https://www.blizzard.com/en-us/legal/a2989b50-5f16-43b1-abec-2ae17cc09dd6/blizzard-developer-api-terms-of-use"

-- The steps to hourly prices, in order, each with whether it is done. Only
-- what is left is shown. A step may carry a text to copy and one button:
-- "again" reloads the game to look again, "ask" asks the helper to do it.
function UI.SetupSteps()
  local M = ns.Market
  local h = M.Helper()
  local o = ns.Online
  local steps = {
    { key = "helper", done = h ~= nil, title = "Start the helper on your computer",
      text = "The game cannot reach the internet or start a program, so a small helper outside it does. It needs "
        .. "Python 3 (free: python.org/downloads). In the addon's sync folder double-click \"Set up online "
        .. "features\" (Windows), or run this outside the game. A page opens in your browser. Then press the button.",
      box = "python3 sync/craftgraph_setup.py", button = "Done: look again", again = true },
    { key = "key", done = h ~= nil and h.key == true, title = "Enter your own Blizzard API key on the helper's page",
      text = "The page shows what you take on: the key is yours and so are Blizzard's terms. Make a free key at "
        .. "this address (sign in, Create Client; the page says what to fill in), enter it there, then press the button. "
        .. "The key stays in one private file on your computer and never comes into the game.",
      box = "https://develop.battle.net/access/clients", button = "Done: look again", again = true },
    { key = "watch", done = h ~= nil and h.watch == true, title = "Let the buttons here work",
      text = "On the helper's page press \"Let the game's buttons work, always\", or keep that page open while "
        .. "you play. From then on the buttons here can ask the helper to fetch, delete and keep things for you.",
      button = "Done: look again", again = true },
    { key = "scan", done = ns.db.lastFullScan ~= nil, title = "Do one full scan at the auction house",
      text = "The helper finds which auction house is yours by comparing Blizzard's lists with your own scan. "
        .. "Open the auction house and press Full scan above. This step goes away when the scan is done." },
    { key = "fetch", done = type(o) == "table" and o.realm == ns.realmKey and M.OnlineAge() ~= nil,
      title = "Fetch the prices",
      text = "The helper downloads your auction house from Blizzard and writes it where the game reads it. "
        .. "The game reloads to pass the request on; a few seconds later press \"Show the answer\".",
      button = "Fetch the prices", ask = "run" },
  }
  if not (h and h.windows) then
    steps[#steps + 1] = { key = "hourly", done = h ~= nil and h.timer == true, title = "Fetch every hour by itself (optional)",
      text = "Prices then stay fresh while you are away. It runs while you are logged in to this computer, "
        .. "and the game shows them at its next login or /reload.",
      button = "Fetch every hour", ask = "install_timer" }
  end
  local left = {}
  for i, step in ipairs(steps) do
    step.n = i
    if not step.done then left[#left + 1] = step end
  end
  return steps, left
end

local function BuildBlizzard()
  if blizzardPane then return end
  local f = dataPage.panes.blizzard
  blizzardPane = f
  UI.blizzardPane = f
  f.title = Text(f, "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 16, -8)
  f.title:SetText("Hourly prices from Blizzard (optional)")
  f.intro = Text(f, "GameFontHighlightSmall")
  f.intro:SetPoint("TOPLEFT", 16, -26)
  f.intro:SetPoint("TOPRIGHT", -16, -26)
  f.intro:SetWordWrap(true)
  f.intro:SetMaxLines(2)
  f.intro:SetSpacing(2)
  f.intro:SetText("Blizzard publishes every auction house once an hour. An optional helper on your computer fetches "
    .. "yours, so prices are known while you are away. The data comes from Blizzard; CraftGraph is not "
    .. "affiliated with or endorsed by Blizzard. Without this nothing here changes.")
  f.status = Text(f, "GameFontHighlight")
  f.status:SetPoint("TOPLEFT", 16, -62)
  f.status:SetPoint("TOPRIGHT", -16, -62)
  f.status:SetWordWrap(false)
  -- What the helper answered to the last thing asked.
  f.answer = Text(f, "GameFontHighlightSmall")
  f.answer:SetPoint("TOPLEFT", 16, -82)
  f.answer:SetPoint("TOPRIGHT", -200, -82)
  f.answer:SetWordWrap(true)
  f.answer:SetMaxLines(3)
  f.answer:SetSpacing(2)
  f.answerButton = Button(f, "Show the answer", 170)
  f.answerButton:SetPoint("TOPRIGHT", -16, -80)
  f.answerButton:SetScript("OnClick", function()
    local asked = ns.Market.Asked()
    if asked and (asked.state == "done" or asked.state == "failed") then
      ns.Market.ForgetAsked()
      UI.UpdateBlizzard()
    else
      ReloadUI()
    end
  end)
  Tip(f.answerButton, "The helper's answer",
    "The game only reads files when it loads, so the answer shows after a reload. This reloads the game.")
  -- What is left to do: the next step in full, the later ones by name.
  f.doneLine = Text(f, "GameFontHighlightSmall")
  f.doneLine:SetPoint("TOPLEFT", 16, -130)
  f.doneLine:SetPoint("TOPRIGHT", -16, -130)
  f.doneLine:SetWordWrap(false)
  f.stepTitle = Text(f, "GameFontNormal")
  f.stepTitle:SetPoint("TOPLEFT", 16, -150)
  f.stepText = Text(f, "GameFontHighlightSmall")
  f.stepText:SetPoint("TOPLEFT", 16, -168)
  f.stepText:SetPoint("TOPRIGHT", -16, -168)
  f.stepText:SetWordWrap(true)
  f.stepText:SetMaxLines(3)
  f.stepText:SetSpacing(2)
  f.stepBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  f.stepBox:SetSize(470, 20)
  f.stepBox:SetPoint("TOPLEFT", 22, -212)
  f.stepBox:SetAutoFocus(false)
  f.stepBox:SetScript("OnTextChanged", function(self, user) if user then self:SetText(self.keep or "") end end)
  f.stepBox:SetScript("OnEditFocusGained", function(self) if self.HighlightText then self:HighlightText() end end)
  f.stepBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  Tip(f.stepBox, "To copy", "Click the box and press Ctrl+C. It is for use outside the game.")
  f.stepButton = Button(f, "", 190)
  f.stepButton:SetPoint("TOPLEFT", 506, -211)
  f.stepButton:SetScript("OnClick", function()
    local step = f.step
    if not step then return end
    if step.ask then ns.Market.Ask(step.ask) else ReloadUI() end
  end)
  Tip(f.stepButton, "This reloads the game",
    "The game reads what the helper wrote only when it loads, and passes a request on only when it saves. "
    .. "Both happen in a reload, which takes a few seconds.")
  f.later = Text(f, "GameFontDisableSmall")
  f.later:SetPoint("TOPLEFT", 16, -240)
  f.later:SetPoint("TOPRIGHT", -16, -240)
  f.later:SetWordWrap(false)
  -- Things to ask the helper for at any time.
  f.askHead = Text(f, "GameFontNormal")
  f.askHead:SetPoint("TOPLEFT", 16, -264)
  f.askHead:SetText("Ask the helper (each reloads the game to pass it on)")
  f.asks = {}
  local x = 16
  for _, a in ipairs({
    { "run", "Fetch prices now", 130, "Downloads your auction house from Blizzard now." },
    { "archive", "Keep every scan", 126, "Copies every in-game scan into a database on your computer, in full and for good." },
    { "check_update", "Newer version?", 120, "Looks on GitHub for a newer CraftGraph." },
    { "data_pull", "Shared prices", 112, "Fetches the prices other players share on GitHub." },
  }) do
    local b = Button(f, a[2], a[3])
    b:SetPoint("TOPLEFT", x, -282)
    b.ask = a[1]
    b:SetScript("OnClick", function() ns.Market.Ask(a[1]) end)
    Tip(b, a[2], a[4] .. " The game reloads to pass the request on; press \"Show the answer\" a few seconds later.")
    f.asks[#f.asks + 1] = b
    x = x + a[3] + 6
  end
  f.askNote = Text(f, "GameFontDisableSmall")
  f.askNote:SetPoint("TOPLEFT", 16, -284)
  f.askNote:SetPoint("TOPRIGHT", -16, -284)
  f.askNote:SetWordWrap(false)
  -- The thirty days.
  f.keep = Text(f, "GameFontHighlightSmall")
  f.keep:SetPoint("TOPLEFT", 16, -318)
  f.keep:SetPoint("TOPRIGHT", -236, -318)
  f.keep:SetWordWrap(true)
  f.keep:SetMaxLines(2)
  f.keep:SetSpacing(2)
  f.forget = Button(f, "Delete what is older than 30 days", 212)
  f.forget:SetPoint("TOPRIGHT", -16, -316)
  f.forget:SetScript("OnClick", function()
    ns.Market.ForgetOldOnline()
    local h = ns.Market.Helper()
    -- With the helper listening, the files on the computer go too.
    if h and h.watch then ns.Market.Ask("purge") end
    UI.UpdateBlizzard()
  end)
  Tip(f.forget, "Delete old Blizzard data",
    "Blizzard's terms allow data from their service to be kept thirty days at most. This stops the game "
    .. "using anything older, at once and for good, and asks the helper to delete it from your computer "
    .. "too (the game reloads for that). Without the helper listening, delete the files on its page or "
    .. "with: python3 sync/craftgraph_sync.py purge. Your own scans are yours and stay.")
  f.done = Text(f, "GameFontHighlightSmall")
  f.done:SetPoint("TOPLEFT", 16, -350)
  f.done:SetPoint("TOPRIGHT", -16, -350)
  f.done:SetWordWrap(true)
  f.done:SetMaxLines(2)
  f.terms = CopyBox(f, -378, "Blizzard's Developer API Terms of Use. Making a key means you accept them yourself:", TERMS_URL)
  f.note = Text(f, "GameFontDisableSmall")
  f.note:SetPoint("TOPLEFT", 16, -424)
  f.note:SetPoint("TOPRIGHT", -16, -424)
  f.note:SetWordWrap(true)
  f.note:SetMaxLines(6)
  f.note:SetSpacing(2)
  f.note:SetText("|cffff8c33Your own responsibility.|r CraftGraph is a prototype among friends, given as it is. The key "
    .. "is personal: you make it, you accept Blizzard's terms, you answer for its use. It is kept in one "
    .. "private file on your computer (sync.json in your own config folder) and nowhere else: not in the "
    .. "addon folder, not in the game, not in an export, not in anything shared or uploaded. Never send it "
    .. "to anyone. Main points of the terms: keep their data 30 days at most; do not pass it on or sell it; "
    .. "Blizzard may end your access at any time, and breaking the terms can cost you the key and may have "
    .. "consequences for your account. Exports and shared prices hold only your own in-game scans.")
end

function UI.UpdateBlizzard()
  BuildBlizzard()
  local f = blizzardPane
  local M = ns.Market
  local o = ns.Online
  local h = M.Helper()
  local age = M.OnlineAge()
  local steps, left = UI.SetupSteps()
  if not o or o == false then
    f.status:SetText("|cffff8c33Not set up.|r " .. (#left > 0 and ("Step " .. left[1].n .. " of " .. #steps .. " is next.") or ""))
  elseif o.realm ~= ns.realmKey then
    f.status:SetText("|cffff8c33Set up for another auction house|r (" .. tostring(o.realm) .. "), so it is not used here.")
  elseif not age then
    f.status:SetText("Set up, but no data is in use: it was all deleted. Fetch fresh prices below.")
  else
    f.status:SetText("|cff66ff66Connected:|r " .. tostring(o.name or "your auction house") .. ", prices from "
      .. ns.Age(time() - (o.updated or 0)) .. " (" .. (o.snapshots or 0) .. " hourly snapshots)"
      .. (M.Source("Online") and "." or "; switched off on the Data sources page."))
  end
  -- The last thing asked of the helper.
  local asked = M.Asked()
  if not asked then
    f.answer:SetText("")
    f.answerButton:Hide()
  elseif asked.state == "waiting" then
    f.answer:SetText("Asked the helper to " .. asked.text .. " (" .. ns.Age(asked.age) .. "). It answers within "
      .. "seconds, but the game only reads the answer when it loads.")
    f.answerButton:SetText("Show the answer")
    f.answerButton:Show()
  elseif asked.state == "silent" then
    f.answer:SetText("|cffff8c33No answer yet|r to \"" .. asked.text .. "\" (asked " .. ns.Age(asked.age)
      .. "). Is the helper listening? Open its page outside the game (python3 sync/craftgraph_setup.py) "
      .. "and keep it open, or press \"Let the game's buttons work, always\" there. Then look again.")
    f.answerButton:SetText("Look again")
    f.answerButton:Show()
  else
    local text = tostring(asked.answer or ""):gsub("|", "||")
    f.answer:SetText((asked.state == "done" and "|cff66ff66The helper did it|r" or "|cffff8c33That did not work|r")
      .. " (" .. asked.text .. ", " .. ns.Age(time() - (asked.t or time())) .. "): " .. text:gsub("\n", " "))
    f.answerButton:SetText("OK")
    f.answerButton:Show()
  end
  -- What is done, the next step, and what comes after.
  local doneNames = {}
  local NAMES = { helper = "helper found", key = "your key saved", watch = "buttons work", scan = "full scan made",
    fetch = "prices fetched", hourly = "hourly fetch on" }
  for _, step in ipairs(steps) do
    if step.done then doneNames[#doneNames + 1] = NAMES[step.key] end
  end
  f.doneLine:SetText(#doneNames > 0 and ("|cff66ff66Done:|r " .. table.concat(doneNames, ", ")
    .. (h and h.python and (GREY .. "  (Python " .. h.python .. ")|r") or "")) or "")
  local step = left[1]
  f.step = step
  if step then
    f.stepTitle:SetText("Step " .. step.n .. " of " .. #steps .. ": " .. step.title)
    f.stepText:SetText(step.text)
    f.stepBox.keep = step.box
    f.stepBox:SetText(step.box or "")
    f.stepBox:SetShown(step.box ~= nil)
    f.stepButton:SetShown(step.button ~= nil)
    if step.button then
      f.stepButton:SetText(step.button)
      f.stepButton:ClearAllPoints()
      f.stepButton:SetPoint("TOPLEFT", step.box and 506 or 16, -211)
      -- Asking needs someone to listen.
      f.stepButton:SetEnabled(not step.ask or (h ~= nil and h.watch == true))
    end
    local names = {}
    for i = 2, #left do names[#names + 1] = left[i].n .. ". " .. left[i].title end
    f.later:SetText(#names > 0 and ("Then: " .. table.concat(names, "  |  ")) or "")
  else
    f.stepTitle:SetText("|cff66ff66Everything is set up.|r")
    f.stepText:SetText("Prices are fetched every hour while you are logged in to your computer, and the game shows "
      .. "them at its next login or /reload. The buttons below ask the helper for things in between.")
    f.stepBox:Hide()
    f.stepButton:Hide()
    f.later:SetText("")
  end
  -- The asking buttons need the helper to be listening.
  local listening = h ~= nil and h.watch == true
  f.askHead:SetShown(h ~= nil)
  for _, b in ipairs(f.asks) do
    b:SetShown(listening)
    b:SetEnabled(b.ask ~= "run" or (h ~= nil and h.key == true))
  end
  f.askNote:SetText((h and not listening) and "The helper is not listening right now: open its page outside the game, or finish the step above." or "")
  local keep = M.ONLINE_KEEP_DAYS
  if age and age > keep then
    f.keep:SetText("|cffff8c33You hold Blizzard data that is " .. math.floor(age) .. " days old.|r Their terms allow "
      .. keep .. " days: delete the older part now with the button.")
  elseif age then
    f.keep:SetText("Blizzard's terms allow their data to be kept " .. keep .. " days. The oldest in use is "
      .. (age < 1 and "under a day" or (math.floor(age) .. (math.floor(age) == 1 and " day" or " days")))
      .. " old" .. GREY .. " (" .. math.max(0, math.ceil(keep - age)) .. " days to go).|r")
  else
    f.keep:SetText(GREY .. "Blizzard's terms allow their data to be kept " .. keep
      .. " days. Once you use it, this page reminds you when to delete.|r")
  end
  f.forget:SetEnabled(age ~= nil)
  local at = ns.db.onlineForgotAt
  f.done:SetText(at and ("|cff66ff66Deleted in the game " .. ns.Age(time() - at) .. ":|r nothing older than " .. keep
    .. " days is used. " .. (listening and "The helper was asked to delete it from your computer too."
      or "Now delete it from your computer too: on the helper's page, or with python3 sync/craftgraph_sync.py purge.")) or "")
  f.age = age
end

------------------------------------------------------------------------------
-- Sales seen: the auctions judged sold between full scans, newest first.
-- For one item (from the side panel) or for everything.
------------------------------------------------------------------------------
local salesPane
local salesOnlyItem = false
local SALES_ROWS = 22

local function BuildSales()
  if salesPane then return end
  local f = dataPage.panes.sales
  salesPane = f
  UI.salesPane = f
  f.summary = Text(f, "GameFontNormal")
  f.summary:SetPoint("TOPLEFT", 16, -8)
  f.filter = Button(f, "This item only", 130)
  f.filter:SetHeight(19)
  f.filter:SetPoint("TOPRIGHT", -14, -6)
  f.filter:SetScript("OnClick", function()
    salesOnlyItem = not salesOnlyItem
    f.offset = 0
    UI.UpdateSalesList()
  end)
  Tip(f.filter, "Which sales", "Switches between the sales of the item in focus and the sales of everything.")
  f.note = Text(f, "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", 16, -28)
  f.note:SetPoint("TOPRIGHT", -16, -28)
  f.note:SetWordWrap(false)
  local COLS = {
    { text = "Found gone", x = 16, w = 90 }, { text = "Item", x = 112, w = 230 },
    { text = "Amount", right = 400, w = 50 }, { text = "Each", right = 490, w = 80 },
    { text = "In all", right = 590, w = 90 }, { text = "Seller", x = 606, w = 110 }, { text = "Sure", right = 780, w = 40 },
  }
  for _, c in ipairs(COLS) do
    local h = Text(f, "GameFontNormalSmall", c.right and "RIGHT" or "LEFT")
    h:SetWidth(c.w)
    if c.x then h:SetPoint("TOPLEFT", c.x, -50) else h:SetPoint("TOPRIGHT", f, "TOPLEFT", c.right, -50) end
    h:SetText(c.text)
  end
  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.3)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT", 10, -66)
  line:SetPoint("TOPRIGHT", -10, -66)
  f.rows = {}
  for i = 1, SALES_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(20)
    local y = -70 - (i - 1) * 20
    row:SetPoint("TOPLEFT", 8, y)
    row:SetPoint("TOPRIGHT", -8, y)
    row.when = Text(row, "GameFontDisableSmall")
    row.when:SetPoint("LEFT", 8, 0)
    row.when:SetWidth(90)
    row.when:SetWordWrap(false)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 104, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = Text(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(210)
    row.name:SetWordWrap(false)
    row.count = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.count:SetPoint("RIGHT", row, "LEFT", 392, 0)
    row.each = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.each:SetPoint("RIGHT", row, "LEFT", 482, 0)
    row.total = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.total:SetPoint("RIGHT", row, "LEFT", 582, 0)
    row.seller = Text(row, "GameFontHighlightSmall")
    row.seller:SetPoint("LEFT", row, "LEFT", 598, 0)
    row.seller:SetWidth(110)
    row.seller:SetWordWrap(false)
    row.sure = Text(row, "GameFontDisableSmall", "RIGHT")
    row.sure:SetPoint("RIGHT", row, "LEFT", 772, 0)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    row:RegisterForClicks("LeftButtonUp", "Button4Up", "Button5Up")
    row:SetScript("OnClick", function(self, button)
      if UI.NavButton(button) then return end
      if self.data then
        UI.Remember()
        SetMode("graph")
        UI.Focus(self.data.id)
      end
    end)
    f.rows[i] = row
  end
  f.more = Text(f, "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 14, 8)
  f.offset = 0
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    f.offset = max(0, f.offset - delta * 3)
    UI.UpdateSalesList()
  end)
end

function UI.UpdateSalesList()
  BuildSales()
  local f = salesPane
  local focus = state.center
  local only = salesOnlyItem and focus
  local list = ns.Market.SalesLog(only or nil)
  f.filter:SetText(only and "Show all items" or "This item only")
  f.filter:SetEnabled(focus ~= nil or salesOnlyItem)
  local dayUnits, dayValue, day = 0, 0, time() - 86400
  for _, e in ipairs(list) do
    if e.t >= day then dayUnits, dayValue = dayUnits + e.count, dayValue + e.count * e.unit end
  end
  f.summary:SetText("Sales seen" .. (only and (": " .. ns.ItemName(only)) or "") .. "  |cffffffff" .. #list .. "|r"
    .. GREY .. (dayUnits > 0 and ("  (last 24 h: " .. dayUnits .. " units, " .. ns.Money(dayValue) .. "|r" .. GREY .. ")|r") or "|r"))
  if not ns.Market.Source("Sales") then
    f.note:SetText("|cffff8c33Sales seen between full scans is switched off on the Data sources page.|r")
  elseif #list == 0 then
    f.note:SetText(GREY .. "None yet. A sale is seen when an auction is there at one full scan and gone at the next, "
      .. "and was not about to run out or relisted.|r")
  else
    f.note:SetText(GREY .. "Auctions that were there at one full scan and gone at the next, and more likely sold than not. "
      .. "\"Sure\" is how likely. Click a row to open the item.|r")
  end
  f.offset = min(f.offset, max(0, #list - SALES_ROWS))
  for i = 1, SALES_ROWS do
    local row, e = f.rows[i], list[i + f.offset]
    row.data = e
    if e then
      local r, g, b = ns.ItemColor(e.id)
      row.when:SetText(ns.Age(time() - e.t))
      row.icon:SetTexture(ns.ItemIcon(e.id))
      row.name:SetText(ns.ItemName(e.id))
      row.name:SetTextColor(r, g, b)
      row.count:SetText("x" .. e.count)
      row.each:SetText(ns.Money(e.unit))
      row.total:SetText(ns.Money(e.unit * e.count))
      row.seller:SetText(e.owner ~= "" and e.owner or (GREY .. "unknown|r"))
      row.sure:SetText(ns.Round(e.sure * 100) .. "%")
      row:Show()
    else
      row:Hide()
    end
  end
  f.more:SetText(#list > SALES_ROWS and ((f.offset + 1) .. " to " .. min(#list, f.offset + SALES_ROWS) .. " of " .. #list
    .. ". Scroll for more.") or "")
  f.count = #list
end

------------------------------------------------------------------------------
-- Opening the Data page and its sub-pages
------------------------------------------------------------------------------
function UI.SelectDataTab(tab)
  if not dataPage then return end
  dataTab = dataPage.panes[tab] and tab or "sources"
  for key, pane in pairs(dataPage.panes) do
    pane:SetShown(key == dataTab)
    if key == dataTab then dataPage.tabs[key]:LockHighlight() else dataPage.tabs[key]:UnlockHighlight() end
  end
  if dataTab == "sources" then
    BuildSources()
  elseif dataTab == "share" then
    BuildShare()
    if shareFrame.box:GetText() == "" and shareFrame.result:GetText() == "" then
      ShareSay("Press Export to put your prices in the box, or paste what you were sent and press Import.", nil)
    end
  elseif dataTab == "blizzard" then
    UI.UpdateBlizzard()
  elseif dataTab == "github" then
    UI.UpdateGitHub()
  elseif dataTab == "sales" then
    UI.UpdateSalesList()
  end
end

-- Opens the Data page on a sub-page; with none given, the button's toggle.
function UI.ShowData(tab)
  if not (UI.IsOpen and UI.IsOpen()) then ns.Open() end
  if not dataPage then return end
  if not tab and CurrentMode() == "data" then
    SetMode("graph")
    return
  end
  dataTab = tab or dataTab
  SetMode("data")
end

-- Back to the graph from any page.
function UI.ShowGraph()
  SetMode("graph")
end

-- The data sources: shown, or put away again when already in view.
function UI.ToggleSources()
  if CurrentMode() == "data" and dataTab == "sources" and UI.IsOpen and UI.IsOpen() then
    SetMode("graph")
  else
    UI.ShowData("sources")
  end
end

-- The list of sales seen; thisItem: only those of the item in focus.
function UI.ShowSales(thisItem)
  salesOnlyItem = thisItem and true or false
  UI.ShowData("sales")
end

ns.Listen("SOURCES", function()
  if dataPage and dataPage:IsShown() and dataTab == "github" then ns.Safe(UI.UpdateGitHub) end
  if dataPage and dataPage:IsShown() and dataTab == "blizzard" then ns.Safe(UI.UpdateBlizzard) end
end)
ns.Listen("MARKET_UPDATED", function()
  if dataPage and dataPage:IsShown() and dataTab == "sales" then ns.Safe(UI.UpdateSalesList) end
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
