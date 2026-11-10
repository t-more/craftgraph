-- CraftGraph graph view: draws the item graph on a canvas that can be
-- dragged and zoomed. Each item is a small panel with its icon and prices;
-- curved lines join an item (left end) to what it is made from (right end).
local ADDON, ns = ...
local V = {}
ns.GraphView = V

local max, min = math.max, math.min
local G = ns.Graph

local SEGMENTS = 12
local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 14,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local GREY = "|cff9d9d9d"

------------------------------------------------------------------------------
-- Node text
------------------------------------------------------------------------------
local function PriceLine(id)
  local info = ns.Market.Info(id)
  if not info then
    return GREY .. "Auction|r  " .. GREY .. "no data|r"
  end
  if not info.price then
    return GREY .. "Auction|r  " .. GREY .. "none listed|r"
  end
  local _, sd = ns.Stats.Estimate(id, 0)
  -- An unsure price is shown dimmer than one backed by several scans.
  local tint = ""
  if sd and sd > 0.2 then tint = "|cffa89878" elseif sd and sd > 0.12 then tint = "|cffd8ccb0" end
  local text = GREY .. "Auction|r  " .. tint .. ns.Money(info.price) .. (tint ~= "" and "|r" or "")
  if sd then
    text = text .. GREY .. " \194\177" .. ns.Round(sd * 100) .. "%|r"
  end
  -- How many sell in a day, in short: "120/d", "1.3k/d", or "120+/d" when
  -- that is only a floor.
  if info.turnover then
    local n = info.turnover
    local short = n >= 1000 and string.format("%.1fk", n / 1000) or (n >= 10 and tostring(ns.Round(n)) or string.format("%.1f", n))
    text = text .. " |cff7fbf7f" .. short .. ((info.sales and info.sales.floor) and "+" or "") .. "/d|r"
  end
  return text
end

local function VendorLine(id)
  local sell = ns.VendorSell(id)
  local buy = ns.Market.VendorBuy(id)
  -- One figure per line so it always fits beside the button: what a vendor
  -- charges when vendors stock it, otherwise what a vendor pays for it.
  if buy then
    return GREY .. "Vendor sells|r  " .. ns.Money(buy)
  end
  return GREY .. "Vendor pays|r  " .. (sell > 0 and ns.Money(sell) or (GREY .. "nothing|r"))
end

local function MakeLine(node)
  local id = node.id
  if ns.Opt.IsCraftable(id) then
    local e = ns.Opt.Evaluate(id, 1)
    if not e.plan.complete then
      return GREY .. "Make|r  " .. GREY .. "price missing|r"
    end
    local text = GREY .. "Make|r  " .. ns.Money(e.cost / e.produced)
    if e.profit then
      local per = e.profit / e.produced
      text = text .. (per >= 0 and "  |cff40ff40+" or "  |cffff5040") .. ns.Money(per) .. "|r"
    end
    return text
  end
  if node.bought or node.vended then
    local parts = {}
    if node.bought then parts[#parts + 1] = "buy " .. ns.Round(node.bought) end
    if node.vended then parts[#parts + 1] = "vendor " .. ns.Round(node.vended) end
    return "|cffffd100Need|r  " .. table.concat(parts, ", ")
  end
  return GREY .. "Base resource|r"
end

------------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------------
local function ShowTooltip(button)
  local node = button.node
  if not node then return end
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  if node.more then
    GameTooltip:SetText(node.expanded and "Show fewer" or (node.more .. " more things are made from this"))
    GameTooltip:AddLine("Click to " .. (node.expanded and "shorten" or "show") .. " the list.", 1, 1, 1)
    GameTooltip:Show()
    return
  end
  local id = node.id
  if not pcall(GameTooltip.SetItemByID, GameTooltip, id) then
    GameTooltip:SetText(ns.ItemName(id))
  end
  GameTooltip:AddLine(" ")
  local info = ns.Market.Info(id)
  if info and info.price then
    GameTooltip:AddDoubleLine("Auction price", ns.Money(info.price), 1, 0.82, 0, 1, 1, 1)
    if info.total and info.total > 0 then
      local depth = info.summary and " (prices beyond the cheapest are estimated)" or ""
      GameTooltip:AddDoubleLine("Listed", info.total .. depth, 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Last seen", ns.Age(info.age), 1, 0.82, 0, 1, 1, 1)
    if info.turnover then
      GameTooltip:AddDoubleLine("Sells about", string.format("%.0f a day", info.turnover), 1, 0.82, 0, 1, 1, 1)
    end
  elseif info then
    GameTooltip:AddDoubleLine("Auction price", "none listed " .. ns.Age(info.age), 1, 0.82, 0, 0.7, 0.7, 0.7)
    if info.lastPrice then
      GameTooltip:AddDoubleLine("Last seen at", ns.Money(info.lastPrice), 1, 0.82, 0, 1, 1, 1)
    end
  else
    GameTooltip:AddDoubleLine("Auction price", "not scanned yet", 1, 0.82, 0, 0.7, 0.7, 0.7)
  end
  local est, sd = ns.Stats.Estimate(id, 0)
  if est and sd then
    GameTooltip:AddDoubleLine("Estimate now",
      ns.Money(est) .. " \194\177" .. ns.Round(sd * 100) .. "%", 1, 0.82, 0, 1, 1, 1)
  end
  local inBags, inBank = ns.Player.ItemCount(id), ns.Player.BankCount(id)
  if inBags > 0 then GameTooltip:AddDoubleLine("In your bags", inBags, 1, 0.82, 0, 1, 1, 1) end
  if inBank > 0 then GameTooltip:AddDoubleLine("In your bank", inBank, 1, 0.82, 0, 0.45, 0.75, 1) end
  GameTooltip:AddDoubleLine("Vendor pays", ns.Money(ns.VendorSell(id)), 1, 0.82, 0, 1, 1, 1)
  local buy = ns.Market.VendorBuy(id)
  if buy then
    GameTooltip:AddDoubleLine("Vendor sells for", ns.Money(buy), 1, 0.82, 0, 1, 1, 1)
  end
  if ns.Opt.IsCraftable(id) then
    local spell = ns.Opt.BestRecipe(id)
    local r = ns.Opt.Recipe(spell)
    local e = ns.Opt.Evaluate(id, 1)
    if e.plan.complete then
      GameTooltip:AddDoubleLine("Make one for", ns.Money(e.cost / e.produced), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Recipe",
      (ns.Data.skills[r[1]] or "?") .. " " .. r[2] .. ": " .. r[6], 1, 0.82, 0, 1, 1, 1)
  end
  -- How it ranks among the things on screen, and why.
  local rank = ns.Opt.Rank(id)
  if rank then
    local function Sure(value, sd)
      return ns.Money(value) .. " \194\177" .. ns.Money(sd) .. GREY .. " (at least " .. ns.Money(value - sd) .. ")|r"
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(rank.group == "ready" and "You can make this now" or rank.group == "buy" and "Needs materials bought first"
      or "You do not know this recipe", 1, 0.82, 0)
    local unlearned, teacher = ns.Player.Unlearned(id)
    if unlearned then
      GameTooltip:AddLine(ns.Player.TeacherText(teacher), 0.45, 0.75, 1, true)
    end
    GameTooltip:AddDoubleLine("One craft earns", Sure(rank.perCraft, rank.sdCraft), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("From what you own", rank.own > 0 and ("makes " .. ns.Round(rank.own)) or "none", 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Most worth making", ns.Round(rank.best), 1, 1, 1, 1, 1, 1)
    if rank.qty > 0 then
      local pct = ns.Round((ns.settings.buyRatio or 1) * 100)
      GameTooltip:AddDoubleLine("At your setting (" .. pct .. "% bought)", "make " .. ns.Round(rank.qty), 1, 1, 1, 1, 1, 1)
      GameTooltip:AddDoubleLine("That earns", Sure(rank.total, rank.totalSd), 1, 1, 1, 1, 1, 1)
      if rank.buyCost > 0 then
        GameTooltip:AddDoubleLine("To buy at auction", ns.Money(rank.buyCost), 1, 1, 1, 1, 1, 1)
      end
    end
    local view = button:GetParent() and button:GetParent():GetParent()
    local top = view and view.topScore or 0
    if top > 0 and rank.group ~= "unknown" then
      GameTooltip:AddLine("Ranked " .. ((ns.settings.rankBy == "craft") and "per craft" or "in all") .. ": "
        .. ns.Round(100 * rank.score / top) .. "% of the best on screen.", 0.8, 0.8, 0.8)
    end
  end
  GameTooltip:AddLine("Click to centre the graph here.", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("Shift-click to link in chat.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

------------------------------------------------------------------------------
-- Node buttons
------------------------------------------------------------------------------
local function CreateNode(canvas)
  local b = CreateFrame("Button", nil, canvas, "BackdropTemplate")
  b:SetSize(G.NODE_W, G.NODE_H)
  b:SetBackdrop(BACKDROP)
  b:SetBackdropColor(0.07, 0.06, 0.05, 0.95)

  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(40, 40)
  b.icon:SetPoint("LEFT", 9, 0)
  b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b.iconBorder = b:CreateTexture(nil, "OVERLAY")
  b.iconBorder:SetTexture("Interface\\Common\\WhiteIconFrame")
  b.iconBorder:SetAllPoints(b.icon)

  -- For something the player could make if the recipe were learned: the
  -- recipe that teaches it, small, on the corner of the icon. Click it to
  -- look that recipe up.
  b.teach = ns.UI.CreateTeachMark(b, b.icon, 18)
  b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.name:SetPoint("TOPLEFT", b, "TOPLEFT", 56, -8)
  b.name:SetPoint("TOPRIGHT", b, "TOPRIGHT", -7, -8)
  b.name:SetJustifyH("LEFT")
  b.name:SetWordWrap(false)
  ns.Watch(b.name, "graph item name")
  -- The card when the graph is zoomed out: a larger name and one line,
  -- which can still be read; the rest is in the tooltip and one zoom away.
  b.bigName = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  b.bigName:SetPoint("TOPLEFT", b, "TOPLEFT", 56, -8)
  b.bigName:SetPoint("TOPRIGHT", b, "TOPRIGHT", -7, -8)
  b.bigName:SetJustifyH("LEFT")
  b.bigName:SetJustifyV("TOP")
  b.bigName:SetWordWrap(true)
  b.bigName:SetMaxLines(2)
  b.bigName:Hide()
  b.bigLine = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  b.bigLine:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 56, 9)
  b.bigLine:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -7, 9)
  b.bigLine:SetJustifyH("LEFT")
  b.bigLine:SetWordWrap(false)
  b.bigLine:Hide()
  -- A golden halo: the stronger, the better this is to make among the
  -- things on screen. The best one's halo breathes.
  -- The halo, built to look like light, not paint: a crisp bright rim
  -- right at the card's edge, and outside it a glow that fades to nothing.
  -- All of it sits around the card, so it never covers the text. On the
  -- best card the glow breathes and a glint sweeps across now and then.
  b.gild = { rim = {}, glow = {}, alpha = 0 }
  local GLOW, RIM = 14, 2
  local function Strip(list, layer, sub)
    local t = b:CreateTexture(nil, layer, nil, sub)
    if t.SetBlendMode then t:SetBlendMode("ADD") end
    list[#list + 1] = t
    return t
  end
  -- rim: top, bottom, left, right
  local t = Strip(b.gild.rim, "BORDER", 1)
  t:SetPoint("BOTTOMLEFT", b, "TOPLEFT", -RIM, 0) t:SetPoint("BOTTOMRIGHT", b, "TOPRIGHT", RIM, 0) t:SetHeight(RIM)
  t = Strip(b.gild.rim, "BORDER", 1)
  t:SetPoint("TOPLEFT", b, "BOTTOMLEFT", -RIM, 0) t:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", RIM, 0) t:SetHeight(RIM)
  t = Strip(b.gild.rim, "BORDER", 1)
  t:SetPoint("TOPRIGHT", b, "TOPLEFT", 0, 0) t:SetPoint("BOTTOMRIGHT", b, "BOTTOMLEFT", 0, 0) t:SetWidth(RIM)
  t = Strip(b.gild.rim, "BORDER", 1)
  t:SetPoint("TOPLEFT", b, "TOPRIGHT", 0, 0) t:SetPoint("BOTTOMLEFT", b, "BOTTOMRIGHT", 0, 0) t:SetWidth(RIM)
  -- glow: the same four sides, wider, each fading outward
  local sides = {
    { "BOTTOMLEFT", "TOPLEFT", -RIM, RIM, "BOTTOMRIGHT", "TOPRIGHT", RIM, RIM, "VERTICAL", true, true },
    { "TOPLEFT", "BOTTOMLEFT", -RIM, -RIM, "TOPRIGHT", "BOTTOMRIGHT", RIM, -RIM, "VERTICAL", false, true },
    { "TOPRIGHT", "TOPLEFT", -RIM, RIM, "BOTTOMRIGHT", "BOTTOMLEFT", -RIM, -RIM, "HORIZONTAL", false, false },
    { "TOPLEFT", "TOPRIGHT", RIM, RIM, "BOTTOMLEFT", "BOTTOMRIGHT", RIM, -RIM, "HORIZONTAL", true, false },
  }
  for i, side in ipairs(sides) do
    local g = Strip(b.gild.glow, "BACKGROUND", 1)
    g:SetPoint(side[1], b, side[2], side[3], side[4])
    g:SetPoint(side[5], b, side[6], side[7], side[8])
    if side[11] then g:SetHeight(GLOW) else g:SetWidth(GLOW) end
    g:SetColorTexture(1, 1, 1, 1)
    g.orientation, g.brightFirst = side[9], side[10]
  end
  -- Sets the halo's strength, 0 to 1.
  function b.gild:Set(a)
    self.alpha = a
    for _, strip in ipairs(self.rim) do strip:SetColorTexture(1, 0.90, 0.45, min(1, a * 1.25)) end
    local bright, dark = CreateColor(1, 0.80, 0.15, a * 0.75), CreateColor(1, 0.70, 0, 0)
    for _, g in ipairs(self.glow) do
      if g.brightFirst then g:SetGradient(g.orientation, bright, dark) else g:SetGradient(g.orientation, dark, bright) end
      g:SetShown(a > 0)
    end
  end
  -- The glint: a soft bright band that crosses the best card.
  b.shineHost = CreateFrame("Frame", nil, b)
  b.shineHost:SetAllPoints()
  b.shineHost:SetClipsChildren(true)
  b.shineHost:Hide()
  b.shine = {}
  for i = 1, 2 do
    local band = b.shineHost:CreateTexture(nil, "OVERLAY")
    band:SetSize(34, G.NODE_H + 20)
    band:SetColorTexture(1, 1, 1, 1)
    if band.SetBlendMode then band:SetBlendMode("ADD") end
    b.shine[i] = band
  end
  -- Whether it can be made now, needs buying first, or is not known.
  b.tag = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.tag:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -7, 10)
  b.tag:SetJustifyH("RIGHT")
  b.tag:Hide()

  -- Three lines: auction, vendor, make. Each can carry its own button at
  -- the right end: buy or sell at auction, buy from a vendor, craft.
  b.steps = {}
  for i, key in ipairs({ "line1", "line2", "line3" }) do
    local y = -8 - i * 14
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", b, "TOPLEFT", 56, y)
    fs:SetPoint("TOPRIGHT", b, "TOPRIGHT", -7, y)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    b[key] = fs
    ns.Watch(fs, "graph item line " .. i)

    local step = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
    step:SetSize(62, 15)
    step:SetPoint("TOPRIGHT", b, "TOPRIGHT", -5, y + 2)
    if step.SetNormalFontObject then
      step:SetNormalFontObject("GameFontNormalSmall")
      step:SetHighlightFontObject("GameFontHighlightSmall")
      step:SetDisabledFontObject("GameFontDisableSmall")
    end
    -- A greyed button still explains itself on hover.
    if step.SetMotionScriptsWhileDisabled then step:SetMotionScriptsWhileDisabled(true) end
    step.glow = step:CreateTexture(nil, "OVERLAY")
    step.glow:SetPoint("TOPLEFT", -2, 2)
    step.glow:SetPoint("BOTTOMRIGHT", 2, -2)
    step.glow:SetColorTexture(1, 0.82, 0, 0.3)
    if step.glow.SetBlendMode then step.glow:SetBlendMode("ADD") end
    step.glow:Hide()
    step:Hide()
    step:SetScript("OnClick", function(self)
      if self.fn then ns.Safe(self.fn) end
    end)
    step:SetScript("OnEnter", function(self)
      if not self.title then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(self.title)
      if self.tip then GameTooltip:AddLine(self.tip, 1, 1, 1, true) end
      if self.glowing then GameTooltip:AddLine("This is the step to do now.", 1, 0.82, 0) end
      GameTooltip:Show()
    end)
    step:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.steps[i] = step
  end

  -- Line 4: what the player already owns of this, and how much of it this
  -- plan may use. The two small buttons change that; the rest is bought.
  b.stock = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.stock:SetPoint("TOPLEFT", b, "TOPLEFT", 56, -64)
  b.stock:SetPoint("TOPRIGHT", b, "TOPRIGHT", -48, -64)
  b.stock:SetJustifyH("LEFT")
  b.stock:SetWordWrap(false)
  ns.Watch(b.stock, "graph item own stock")
  local function Stepper(text, x, key)
    local s = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
    s:SetSize(19, 15)
    s:SetPoint("TOPRIGHT", b, "TOPRIGHT", x, -62)
    s:SetText(text)
    if s.SetMotionScriptsWhileDisabled then s:SetMotionScriptsWhileDisabled(true) end
    s:Hide()
    s:SetScript("OnClick", function(self)
      if self.fn then ns.Safe(self.fn) end
    end)
    s:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(key == "less" and "Use fewer of your own" or "Use more of your own")
      GameTooltip:AddLine("Sets how many of your own this plan uses; the rest is bought. "
        .. "Hold Shift for steps of 10, Ctrl for none or all.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return s
  end
  b.less = Stepper("-", -26, "less")
  b.more = Stepper("+", -5, "more")

  b.moreText = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.moreText:SetPoint("CENTER")

  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", 3, -3)
  hl:SetPoint("BOTTOMRIGHT", -3, 3)
  hl:SetColorTexture(1, 1, 1, 0.07)

  b:RegisterForClicks("LeftButtonUp", "Button4Up", "Button5Up")
  b:SetScript("OnEnter", function(self) ns.Safe(ShowTooltip, self) end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function(self, button)
    if ns.UI.NavButton(button) then return end
    local node = self.node
    if not node then return end
    if node.more then
      ns.UI.ToggleExpandLeft()
    elseif IsShiftKeyDown() and ChatFrameUtil and ChatFrameUtil.InsertLink then
      ChatFrameUtil.InsertLink(ns.ItemLink(node.id))
    else
      ns.UI.Focus(node.id)
    end
  end)
  return b
end

local function FillNode(b, node, isCenter)
  b.node = node
  if node.more then
    b.icon:Hide()
    b.iconBorder:Hide()
    b.name:SetText("")
    b.line1:SetText("")
    b.line2:SetText("")
    b.line3:SetText("")
    ns.UI.SetTeachMark(b.teach, nil)
    b.moreText:SetText(node.expanded and "Show fewer" or ("+" .. node.more .. " more"))
    b.moreText:Show()
    for _, step in ipairs(b.steps) do step:Hide() end
    b.stock:SetText("")
    b.less:Hide()
    b.more:Hide()
    b:SetBackdropBorderColor(0.6, 0.5, 0.3, 0.9)
    return
  end
  local id = node.id
  local r, g, bl = ns.ItemColor(id)
  b.moreText:Hide()
  b.icon:Show()
  b.iconBorder:Show()
  b.icon:SetTexture(ns.ItemIcon(id))
  b.iconBorder:SetVertexColor(r, g, bl)
  b.name:SetText(ns.ItemName(id))
  b.name:SetTextColor(r, g, bl)
  ns.UI.SetTeachMark(b.teach, id)
  b.line1:SetText(PriceLine(id))
  b.line2:SetText(VendorLine(id))
  b.line3:SetText(MakeLine(node))
  -- The step buttons: lit when it is the step to do now, greyed (with the
  -- reason on hover) when it makes no sense at the moment.
  local actions = ns.UI.NodeActions and ns.UI.NodeActions(node) or {}
  for i, step in ipairs(b.steps) do
    local a = actions[i]
    local line = b["line" .. i]
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", b, "TOPLEFT", 56, -8 - i * 14)
    line:SetPoint("TOPRIGHT", b, "TOPRIGHT", a and -70 or -7, -8 - i * 14)
    if a then
      step.fn = a.enabled and a.fn or nil
      step.title, step.tip, step.glowing = a.title, a.tip, a.glow and a.enabled
      step:SetText(a.text)
      step:SetEnabled(a.enabled and true or false)
      step.glow:SetShown(step.glowing and true or false)
      step:Show()
    else
      step.fn = nil
      step:Hide()
    end
  end
  local stock = ns.UI.NodeStock and ns.UI.NodeStock(node)
  if stock then
    b.stock:SetText(stock.text)
    b.less.fn, b.more.fn = stock.less, stock.more
    b.less:SetEnabled(stock.less ~= nil)
    b.more:SetEnabled(stock.more ~= nil)
    b.less:SetShown(stock.adjust)
    b.more:SetShown(stock.adjust)
  else
    b.stock:SetText("")
    b.less:Hide()
    b.more:Hide()
  end
  if isCenter then
    b:SetBackdropBorderColor(1, 0.82, 0, 1)
    b:SetBackdropColor(0.16, 0.12, 0.04, 0.97)
  else
    b:SetBackdropBorderColor(0.55 + r * 0.2, 0.5 + g * 0.2, 0.42 + bl * 0.2, 0.9)
    b:SetBackdropColor(0.07, 0.06, 0.05, 0.95)
  end
end

-- Marks a card by how good it is to make: the halo's strength is its score
-- against the best on screen; recipes the player does not know are greyed.
local function Gild(b, rank, top, compact)
  local gold = (rank and top > 0) and min(1, rank.score / top) or 0
  b.gold = gold
  b.rank = rank
  b.gild:Set(gold > 0.12 and (0.12 + 0.50 * gold * gold) or 0)
  b.shineHost:Hide()
  b.greyed = (rank and rank.group == "unknown") or false
  b:SetAlpha(b.greyed and 0.55 or 1)
  local tag
  if rank and compact then
    if rank.group == "ready" then
      tag = "|cff40ff40make " .. ns.Round(rank.own) .. " now|r"
    elseif rank.group == "buy" then
      tag = rank.qty > 0 and ("|cffffd100buy, make " .. ns.Round(rank.qty) .. "|r") or (GREY .. "buy first|r")
    else
      tag = GREY .. "recipe not known|r"
    end
  end
  b.tag:SetText(tag or "")
  b.tag:SetShown(tag ~= nil)
end

-- Below this zoom the cards show less, larger.
V.DENSE_BELOW = 0.75

-- Switches a filled card between its full form and the zoomed-out one:
-- the name and one line (price, and what a craft of it earns).
local function Dense(b, compact)
  local node = b.node
  compact = compact and node and not node.more
  b.bigName:SetShown(compact and true or false)
  b.bigLine:SetShown(compact and true or false)
  b.compact = compact and true or false
  if not compact then
    b.name:Show()
    b.line1:Show()
    b.line2:Show()
    b.line3:Show()
    b.stock:Show()
    return
  end
  local id = node.id
  local r, g, bl = ns.ItemColor(id)
  b.bigName:SetText(ns.ItemName(id))
  b.bigName:SetTextColor(r, g, bl)
  local info = ns.Market.Info(id)
  local text = (info and info.price) and ns.Money(info.price) or (GREY .. (info and "none listed" or "no price") .. "|r")
  local earn = ns.UI.EdgeProfit and ns.UI.EdgeProfit({ from = id })
  if earn then text = text .. "   " .. earn end
  b.bigLine:SetText(text)
  b.name:Hide()
  b.line1:Hide()
  b.line2:Hide()
  b.line3:Hide()
  b.stock:Hide()
  b.less:Hide()
  b.more:Hide()
  for _, step in ipairs(b.steps) do step:Hide() end
end

-- What making the item a line leads to earns in all, at the quantity that
-- earns most: 0 when it does not pay or cannot be told.
function V.EdgeGain(e)
  local product = e.from
  if not product or not ns.Opt.IsCraftable(product) then return 0 end
  local _, best = ns.Opt.BestQuantity(product)
  return best and best.profit and best.profit > 0 and best.profit or 0
end

-- How much making the item a line leads to earns, from -1 (a loss of a
-- quarter of its cost or more) through 0 (nothing) to 1 (a gain of a
-- quarter or more); nil when the prices to tell are missing.
function V.EdgeLean(e)
  local product = e.from
  if not product or not ns.Opt.IsCraftable(product) then return nil end
  local ev = ns.Opt.Evaluate(product, 1)
  if not ev.profit or not ev.cost or ev.cost <= 0 then return nil end
  return max(-1, min(1, ev.profit / ev.cost / 0.25))
end

------------------------------------------------------------------------------
-- View
------------------------------------------------------------------------------
function V.Create(parent)
  local view = CreateFrame("Frame", nil, parent)
  view:SetClipsChildren(true)

  local bg = view:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local hasAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("auctionhouse-background-index")
  if hasAtlas then
    bg:SetAtlas("auctionhouse-background-index")
    local shade = view:CreateTexture(nil, "BACKGROUND", nil, 1)
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.45)
  else
    bg:SetColorTexture(0.05, 0.04, 0.03, 0.92)
  end

  local canvas = CreateFrame("Frame", nil, view)
  canvas:SetSize(10, 10)
  canvas:SetPoint("CENTER", view, "CENTER", 0, 0)
  view.canvas = canvas
  view.ox, view.oy, view.scale = 0, 0, 1
  view.nodes, view.lines, view.labels = {}, {}, {}

  local function Header(point, x, text)
    local fs = view:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint(point, x, -8)
    fs:SetText(text)
    fs:SetAlpha(0.85)
    return fs
  end
  Header("TOPLEFT", 12, "Used in")
  Header("TOPRIGHT", -12, "Made from")
  -- How the cards are ranked, and how much may be bought at auction.
  local rankButton = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  rankButton:SetSize(128, 19)
  rankButton:SetPoint("TOP", -150, -5)
  rankButton:SetScript("OnClick", function()
    ns.settings.rankBy = (ns.settings.rankBy == "craft") and "total" or "craft"
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
  end)
  rankButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("How the cards are ranked")
    GameTooltip:AddLine("The more golden a card's halo, the better it is to make among the things on screen; the "
      .. "best one breathes. \"In all\" ranks by what the whole amount you could make now earns; \"per "
      .. "craft\" by what one craft earns. Both are counted cautiously: the estimate less its margin. "
      .. "Things you can make now come first, then what needs buying, then recipes you do not know (greyed).",
      1, 1, 1, true)
    GameTooltip:Show()
  end)
  rankButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  view.rankButton = rankButton

  local slider = CreateFrame("Button", nil, view)
  slider:SetSize(120, 16)
  slider:SetPoint("LEFT", rankButton, "RIGHT", 96, 0)
  local caption = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  caption:SetPoint("RIGHT", slider, "LEFT", -6, 0)
  caption:SetText("Buy at auction:")
  local track = slider:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("LEFT", 0, 0)
  track:SetPoint("RIGHT", 0, 0)
  track:SetHeight(4)
  track:SetColorTexture(1, 1, 1, 0.18)
  local fill = slider:CreateTexture(nil, "BORDER")
  fill:SetPoint("LEFT", 0, 0)
  fill:SetHeight(4)
  fill:SetColorTexture(1, 0.82, 0, 0.8)
  local thumb = slider:CreateTexture(nil, "ARTWORK")
  thumb:SetSize(8, 14)
  thumb:SetColorTexture(1, 0.9, 0.5, 1)
  local value = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  value:SetPoint("LEFT", slider, "RIGHT", 6, 0)
  view.slider, view.sliderValue = slider, value
  function view.ShowRatio()
    local ratio = max(0, min(1, ns.settings.buyRatio or 1))
    local w = 120
    fill:SetWidth(max(0.5, w * ratio))
    thumb:ClearAllPoints()
    thumb:SetPoint("CENTER", slider, "LEFT", w * ratio, 0)
    value:SetText(ratio <= 0 and "nothing: own stock only" or (ns.Round(ratio * 100) .. "% of what it takes"))
    rankButton:SetText((ns.settings.rankBy == "craft") and "Rank: per craft" or "Rank: in all")
  end
  -- Sets the ratio (0 to 1, in steps of a twentieth) and ranks again.
  function view.SetRatio(ratio)
    ratio = max(0, min(1, math.floor(ratio * 20 + 0.5) / 20))
    if ratio == ns.settings.buyRatio then return end
    ns.settings.buyRatio = ratio
    view.ShowRatio()
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
  end
  local function FromCursor()
    local left, scale = slider:GetLeft(), slider:GetEffectiveScale()
    if not left or not scale or scale == 0 then return nil end
    return (GetCursorPosition() / scale - left) / 120
  end
  slider:SetScript("OnMouseDown", function()
    slider.dragging = true
    local r = FromCursor()
    if r then view.SetRatio(r) end
  end)
  slider:SetScript("OnMouseUp", function() slider.dragging = false end)
  slider:SetScript("OnHide", function() slider.dragging = false end)
  slider:SetScript("OnUpdate", function()
    if not slider.dragging then return end
    if not IsMouseButtonDown("LeftButton") then slider.dragging = false return end
    local r = FromCursor()
    if r then view.SetRatio(r) end
  end)
  slider:EnableMouseWheel(true)
  slider:SetScript("OnMouseWheel", function(_, delta) view.SetRatio((ns.settings.buyRatio or 1) + delta * 0.05) end)
  slider:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("How much to buy at auction")
    GameTooltip:AddLine("How far you are willing to go beyond what you already own. At nothing, cards are "
      .. "ranked by what your own bags and bank can make. At 100%, by the best amount the market allows, "
      .. "buying whatever it takes. Drag, click or scroll.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  slider:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local hint = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 10, 8)
  hint:SetText("Click an item to centre it. Drag to move, mouse wheel to zoom.")

  view.empty = view:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  view.empty:SetPoint("CENTER")
  view.empty:SetWidth(460)
  view.empty:SetText("Search for an item above, or Alt-click one in your bags.\n"
    .. "Or open Opportunities to see what pays right now.")

  local function Place()
    canvas:ClearAllPoints()
    canvas:SetPoint("CENTER", view, "CENTER", view.ox / view.scale, view.oy / view.scale)
  end
  view.Place = Place

  view:EnableMouse(true)
  view:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    local x, y = GetCursorPosition()
    self.drag = { x = x, y = y, ox = self.ox, oy = self.oy }
  end)
  view:SetScript("OnMouseUp", function(self, button)
    self.drag = nil
    ns.UI.NavButton(button)
  end)
  view:SetScript("OnHide", function(self) self.drag = nil end)
  view:SetScript("OnUpdate", function(self)
    V.Animate(self)
    local d = self.drag
    if not d then return end
    if not IsMouseButtonDown("LeftButton") then
      self.drag = nil
      return
    end
    local x, y = GetCursorPosition()
    local s = self:GetEffectiveScale()
    self.ox = d.ox + (x - d.x) / s
    self.oy = d.oy + (y - d.y) / s
    Place()
  end)
  view:EnableMouseWheel(true)
  view:SetScript("OnMouseWheel", function(self, delta)
    local s = self.scale * (delta > 0 and 1.12 or 1 / 1.12)
    self.scale = max(0.4, min(1.6, s))
    canvas:SetScale(self.scale)
    Place()
    -- Crossing the zoom at which cards show more or less: fill them again.
    if self.graph and (self.scale < V.DENSE_BELOW) ~= (self.compact and true or false) then
      V.SetGraph(self, self.graph, false)
    end
  end)

  view.SetGraph = V.SetGraph
  return view
end

local function Bezier(x1, y1, x2, y2, t)
  local d = max(30, (x2 - x1) * 0.5)
  local ax, bx = x1 + d, x2 - d
  local u = 1 - t
  local x = u * u * u * x1 + 3 * u * u * t * ax + 3 * u * t * t * bx + t * t * t * x2
  local y = u * u * u * y1 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y2
  return x, y
end

-- graph: result of Graph.Build, or nil for the empty state.
-- refit: recentre and rescale so the whole graph is visible.
function V.SetGraph(view, graph, refit)
  local canvas = view.canvas
  local nNode, nLine, nLabel = 0, 0, 0
  view.graph = graph
  if view.ShowRatio then view.ShowRatio() end
  -- Zoomed out, cards and line labels carry less, so that they can be read.
  local compact = view.scale < V.DENSE_BELOW
  view.compact = compact
  view.empty:SetShown(graph == nil)
  view.flows = {}

  if graph then
    -- Lines first (they sit under the item panels).
    local stacked, earned = {}, {}
    -- Every craftable thing on screen is scored; the best sets the scale.
    local ranks, topScore = {}, 0
    view.topCard = nil
    for _, node in ipairs(graph.nodes) do
      if node.id then
        local rank = ns.Opt.Rank(node.id)
        if rank then
          ranks[node.id] = rank
          if rank.group ~= "unknown" then topScore = max(topScore, rank.score) end
        end
      end
    end
    view.ranks, view.topScore = ranks, topScore
    -- How much each thing on screen earns at its best quantity, against
    -- the best of them: lines towards the bigger earners are drawn thicker.
    local gains, topGain = {}, 0
    for _, e in ipairs(graph.edges) do
      if gains[e.from] == nil then
        gains[e.from] = V.EdgeGain(e)
        topGain = max(topGain, gains[e.from])
      end
    end
    for _, e in ipairs(graph.edges) do
      local a, b = graph.byId[e.from], graph.byId[e.to]
      if a and b and a.x and b.x then
        local x1, y1 = a.x + G.NODE_W / 2, a.y
        local x2, y2 = b.x - G.NODE_W / 2, b.y
        local r, g, bl, alpha, thick = 0.62, 0.52, 0.36, 0.55, 1.3
        if e.chosen then
          alpha, thick = 0.95, 2.2
        elseif e.cross then
          alpha, thick = 0.4, 1.1
        end
        -- The colour says whether turning the material into the thing it
        -- leads to earns money: gold when it does, grey around nothing, red
        -- towards a loss. A quarter of the cost either way is full colour.
        local lean = V.EdgeLean(e)
        local share = (topGain > 0 and (gains[e.from] or 0) > 0) and math.sqrt(gains[e.from] / topGain) or 0
        thick = thick + 1.8 * share
        if lean then
          local to = lean >= 0 and { 1, 0.82, 0 } or { 0.86, 0.30, 0.24 }
          local k = math.abs(lean)
          r, g, bl = 0.60 + (to[1] - 0.60) * k, 0.57 + (to[2] - 0.57) * k, 0.52 + (to[3] - 0.52) * k
        elseif e.chosen then
          r, g, bl = 1, 0.82, 0
        elseif e.cross then
          r, g, bl = 0.45, 0.62, 0.9
        end
        -- Where a step clearly earns, a small light drifts along its line
        -- from the material towards the thing made of it.
        if lean and lean >= 0.3 and ns.settings.flowGlow ~= false then
          view.flows[#view.flows + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, strength = lean, share = share,
            offset = ((e.from * 7 + e.to * 13) % 100) / 100 }
        end
        local px, py = x1, y1
        for s = 1, SEGMENTS do
          local x, y = Bezier(x1, y1, x2, y2, s / SEGMENTS)
          nLine = nLine + 1
          local line = view.lines[nLine]
          if not line then
            line = canvas:CreateLine(nil, "BACKGROUND")
            view.lines[nLine] = line
          end
          line:SetColorTexture(r, g, bl, alpha)
          line:SetThickness(thick)
          line:SetStartPoint("CENTER", canvas, px, py)
          line:SetEndPoint("CENTER", canvas, x, y)
          line:Show()
          px, py = x, y
        end
        -- On each line: how many go along it and what they are worth. The
        -- label sits beside the item at the end where lines fan out, and
        -- labels arriving at the same item stack upwards.
        local text = ns.UI.EdgeLabel and ns.UI.EdgeLabel(e) or (e.qty and e.qty > 0 and ("x" .. e.qty))
        -- What one craft of the thing this line leads to earns. On the
        -- "used in" side it follows the amount; on the "made from" side it
        -- sits once at the product's end, where its materials' lines meet.
        local earn = ns.UI.EdgeProfit and ns.UI.EdgeProfit(e) or nil
        if compact then
          -- Just the amount: the card itself says what a craft earns.
          text = text and text:match("^(x[%d%.]+)") or text
          earn = nil
        end
        if earn and e.left and text then
          text = text .. " " .. earn
        elseif earn and not e.left and not earned[e.from] then
          earned[e.from] = true
          nLabel = nLabel + 1
          local es = view.labels[nLabel]
          if not es then
            es = canvas:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            view.labels[nLabel] = es
          end
          es:ClearAllPoints()
          es:SetPoint("BOTTOMLEFT", canvas, "CENTER", x1 + 5, y1 + 3)
          es:SetText(earn)
          es:SetTextColor(1, 1, 1)
          es:Show()
        end
        if text then
          nLabel = nLabel + 1
          local fs = view.labels[nLabel]
          if not fs then
            fs = canvas:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            view.labels[nLabel] = fs
          end
          local key = e.left and ("L" .. e.from) or ("R" .. e.to)
          stacked[key] = (stacked[key] or 0) + 1
          local lift = 3 + (stacked[key] - 1) * 12
          fs:ClearAllPoints()
          if e.left then
            fs:SetPoint("BOTTOMLEFT", canvas, "CENTER", x1 + 5, y1 + lift)
          else
            fs:SetPoint("BOTTOMRIGHT", canvas, "CENTER", x2 - 5, y2 + lift)
          end
          fs:SetText(text)
          fs:SetTextColor(r, g, bl)
          fs:Show()
        end
      end
    end

    local minX, maxX, minY, maxY = 0, 0, 0, 0
    for _, node in ipairs(graph.nodes) do
      nNode = nNode + 1
      local b = view.nodes[nNode]
      if not b then
        b = CreateNode(canvas)
        view.nodes[nNode] = b
      end
      FillNode(b, node, node.id == graph.center)
      Dense(b, compact)
      Gild(b, node.id and ranks[node.id] or nil, topScore, compact)
      if node.id and ranks[node.id] and ranks[node.id].score > 0 and ranks[node.id].score == topScore then
        view.topCard = b
      end
      b:ClearAllPoints()
      b:SetPoint("CENTER", canvas, "CENTER", node.x, node.y)
      b:Show()
      minX, maxX = min(minX, node.x), max(maxX, node.x)
      minY, maxY = min(minY, node.y), max(maxY, node.y)
    end

    if refit then
      local w = (maxX - minX) + G.NODE_W + 30
      local h = (maxY - minY) + G.NODE_H + 80
      local vw, vh = view:GetWidth(), view:GetHeight()
      local scale = 1
      if vw and vw > 0 and vh and vh > 0 then
        -- Down to half size, so that four columns still fit side by side.
        scale = max(0.5, min(1, vw / w, vh / h))
      end
      view.scale = scale
      view.ox = -(minX + maxX) / 2 * scale
      view.oy = -(minY + maxY) / 2 * scale
      canvas:SetScale(scale)
      view.Place()
      -- The zoom is known only now: draw once more if it changes how much
      -- the cards show.
      if (scale < V.DENSE_BELOW) ~= compact then
        return V.SetGraph(view, graph, false)
      end
    end
  end

  ns.QueueTruncationCheck()
  for i = nNode + 1, #view.nodes do
    view.nodes[i]:Hide()
    view.nodes[i].node = nil
  end
  for i = nLine + 1, #view.lines do view.lines[i]:Hide() end
  for i = nLabel + 1, #view.labels do view.labels[i]:Hide() end
  V.Animate(view)
end

-- Moves the lights along the lines that earn. Each takes a few seconds to
-- cross, fading in at the material and out at the product; they are faint
-- on purpose. Called every frame the graph is shown.
local FLOW_SECONDS = 2.8
function V.Animate(view)
  -- The best thing to make: its halo breathes.
  local best = view.topCard
  if best and best.gild and (best.gold or 0) > 0 then
    local now = GetTime()
    local breath = 0.5 + 0.5 * math.sin(now * 2.2)
    best.gild:Set(0.62 + 0.38 * breath)
    -- Every few seconds a glint crosses the card, left to right.
    local cycle = (now % 3.4) / 3.4
    if cycle < 0.38 then
      local x = -50 + (cycle / 0.38) * (G.NODE_W + 100)
      local peak = math.sin(cycle / 0.38 * math.pi) * 0.34
      local clear, lit = CreateColor(1, 1, 1, 0), CreateColor(1, 0.96, 0.8, peak)
      best.shine[1]:ClearAllPoints()
      best.shine[1]:SetPoint("RIGHT", best, "LEFT", x, 0)
      best.shine[1]:SetGradient("HORIZONTAL", clear, lit)
      best.shine[2]:ClearAllPoints()
      best.shine[2]:SetPoint("LEFT", best, "LEFT", x, 0)
      best.shine[2]:SetGradient("HORIZONTAL", lit, clear)
      best.shineHost:Show()
      best.glint = x
    else
      best.shineHost:Hide()
      best.glint = nil
    end
  end
  local flows = view.flows or {}
  view.pulses = view.pulses or {}
  local now = GetTime()
  for i, flow in ipairs(flows) do
    local pulse = view.pulses[i]
    if not pulse then
      pulse = { dot = view.canvas:CreateTexture(nil, "BORDER", nil, 2), halo = view.canvas:CreateTexture(nil, "BORDER", nil, 1) }
      pulse.dot:SetSize(4, 4)
      pulse.halo:SetSize(12, 12)
      if pulse.dot.SetBlendMode then
        pulse.dot:SetBlendMode("ADD")
        pulse.halo:SetBlendMode("ADD")
      end
      view.pulses[i] = pulse
    end
    local progress = (now / FLOW_SECONDS + flow.offset) % 1
    -- The line runs from the product (start) to the material (end); the
    -- light goes the other way, with the money.
    local x, y = Bezier(flow.x1, flow.y1, flow.x2, flow.y2, 1 - progress)
    local fade = math.sin(progress * math.pi)
    pulse.dot:ClearAllPoints()
    pulse.dot:SetPoint("CENTER", view.canvas, "CENTER", x, y)
    -- A bigger earner gets a bigger light.
    local grow = flow.share or 0
    pulse.dot:SetSize(4 + 3 * grow, 4 + 3 * grow)
    pulse.halo:SetSize(12 + 8 * grow, 12 + 8 * grow)
    pulse.dot:SetColorTexture(1, 0.92, 0.55, 0.75 * flow.strength * fade)
    pulse.halo:ClearAllPoints()
    pulse.halo:SetPoint("CENTER", view.canvas, "CENTER", x, y)
    pulse.halo:SetColorTexture(1, 0.82, 0.2, 0.16 * flow.strength * fade)
    pulse.dot:Show()
    pulse.halo:Show()
    pulse.x, pulse.y = x, y
  end
  for i = #flows + 1, #view.pulses do
    view.pulses[i].dot:Hide()
    view.pulses[i].halo:Hide()
  end
end
