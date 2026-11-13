-- wowlayout.lua: a stand-in for the game's widget system that also works
-- out where everything sits, so the addon's interface can be drawn to an
-- SVG picture outside the game. It is for pictures and visual checks only:
-- fonts, borders and icons are approximations of the game's.
--
--   local wow = dofile("tools/render/wowlayout.lua")
--   local ns = wow.load("CraftGraph.toc")
--   wow.fire("ADDON_LOADED", "CraftGraph") ...
--   wow.svg(path, { width = 1280, height = 800, caption = "..." })
local wow = { frames = {}, now = 1794300000, clock = 0, cursor = nil }
local floor, max, min = math.floor, math.max, math.min

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."
local CHAR = dofile(here .. "/fontwidths.lua")

------------------------------------------------------------------------------
-- Lua differences and plain globals
------------------------------------------------------------------------------
local rawxpcall = xpcall
xpcall = function(f, handler, ...)
  local args, n = { ... }, select("#", ...)
  return rawxpcall(function() return f(unpack(args, 1, n)) end, handler)
end
time = function() return wow.now end
date = function(fmt, t) return os.date(fmt or "%c", t or wow.now) end
GetTime = function() return wow.clock end
debugstack = function() return debug.traceback("", 2) end
tinsert, tremove = table.insert, table.remove
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
format, strfind, strsub, strlower, strupper = string.format, string.find, string.sub, string.lower, string.upper
sqrt = math.sqrt

------------------------------------------------------------------------------
-- Fonts
------------------------------------------------------------------------------
local FONTS = {
  GameFontNormalLarge = { size = 16, color = { 1, 0.82, 0 } },
  GameFontHighlightLarge = { size = 16, color = { 1, 1, 1 } },
  GameFontNormal = { size = 12.5, color = { 1, 0.82, 0 } },
  GameFontHighlight = { size = 12.5, color = { 1, 1, 1 } },
  GameFontDisable = { size = 12.5, color = { 0.5, 0.5, 0.5 } },
  GameFontNormalSmall = { size = 10.8, color = { 1, 0.82, 0 } },
  GameFontHighlightSmall = { size = 10.8, color = { 1, 1, 1 } },
  GameFontDisableSmall = { size = 10.8, color = { 0.5, 0.5, 0.5 } },
}
local COIN = { gold = "#f2c230", silver = "#c8ccd4", copper = "#c9783c" }

-- Splits game text into runs: { text, color } or { coin = kind }.
local function Runs(text, base)
  local runs, color = {}, base
  local i, n = 1, #text
  local buf = {}
  local function flush()
    if #buf > 0 then
      runs[#runs + 1] = { text = table.concat(buf), color = color }
      buf = {}
    end
  end
  while i <= n do
    local c = text:sub(i, i)
    if c == "|" then
      local nxt = text:sub(i + 1, i + 1)
      if nxt == "c" and text:sub(i + 2, i + 9):match("^%x%x%x%x%x%x%x%x$") then
        flush()
        local hex = text:sub(i + 4, i + 9)
        color = { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 }
        i = i + 10
      elseif nxt == "r" then
        flush()
        color = base
        i = i + 2
      elseif nxt == "A" then
        local stop = text:find("|a", i, true)
        local kind = text:sub(i, stop or n):match("coin%-(%a+)")
        flush()
        if kind then runs[#runs + 1] = { coin = kind } end
        i = (stop or n) + 2
      elseif nxt == "T" then
        local stop = text:find("|t", i, true)
        i = (stop or n) + 2
      elseif nxt == "n" then
        flush()
        runs[#runs + 1] = { newline = true }
        i = i + 2
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    elseif c == "\n" then
      flush()
      runs[#runs + 1] = { newline = true }
      i = i + 1
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return runs
end

local function TextWidth(s, size)
  local w, i, n = 0, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == 194 and s:byte(i + 1) == 177 then
      w = w + (CHAR[177] or 0.5)
      i = i + 2
    elseif b >= 192 then
      -- another multi-byte character: count it once
      w = w + 0.5
      i = i + 1
      while i <= n and s:byte(i) >= 128 and s:byte(i) < 192 do i = i + 1 end
    else
      w = w + (CHAR[b] or 0.5)
      i = i + 1
    end
  end
  return w * size
end

local function RunWidth(run, size)
  if run.coin then return size * 1.05 end
  if run.newline then return 0 end
  return TextWidth(run.text, size)
end

-- Lays text out into lines of runs. width nil = no wrapping.
local function LayoutText(text, size, base, width, wrap, maxLines)
  local lines, line, lineW = {}, {}, 0
  local function push()
    lines[#lines + 1] = { runs = line, width = lineW }
    line, lineW = {}, 0
  end
  for _, run in ipairs(Runs(text, base)) do
    if run.newline then
      push()
    elseif run.coin or not (wrap and width) then
      local w = RunWidth(run, size)
      if wrap and width and lineW + w > width and #line > 0 then push() end
      line[#line + 1] = run
      lineW = lineW + w
    else
      -- wrap by words
      for word, space in run.text:gmatch("([^ ]*)( *)") do
        if word ~= "" or space ~= "" then
          local ww = TextWidth(word, size)
          if lineW + ww > width and #line > 0 then push() end
          local piece = word .. space
          local last = line[#line]
          if last and last.text and last.color == run.color then
            last.text = last.text .. piece
          else
            line[#line + 1] = { text = piece, color = run.color }
          end
          lineW = lineW + TextWidth(piece, size)
        end
      end
    end
  end
  push()
  while #lines > 1 and #lines[#lines].runs == 0 do table.remove(lines) end
  local truncated = false
  if maxLines and maxLines > 0 and #lines > maxLines then
    truncated = true
    for i = #lines, maxLines + 1, -1 do table.remove(lines, i) end
  end
  local widest = 0
  for _, l in ipairs(lines) do widest = max(widest, l.width) end
  if width and not wrap and widest > width + 0.5 then truncated = true end
  return lines, widest, truncated
end

------------------------------------------------------------------------------
-- Regions
------------------------------------------------------------------------------
local unmodelled = {}
local W = {}
W.__index = function(_, key)
  local v = rawget(W, key)
  if v ~= nil then return v end
  if type(key) == "string" and key:match("^%u") then
    return function() unmodelled[key] = true end
  end
  return nil
end

local serial = 0
local function New(kind, parent)
  serial = serial + 1
  return setmetatable({ _kind = kind, _parent = parent, scripts = {}, _events = {}, _shown = true, _text = "",
    _points = {}, _alpha = 1, _scale = 1, _serial = serial, _regions = {}, _children = {}, _enabled = true }, W)
end
wow.New = New

function W:SetScript(name, fn) self.scripts[name] = fn end
function W:GetScript(name) return self.scripts[name] end
function W:HookScript(name, fn)
  local old = self.scripts[name]
  self.scripts[name] = function(...)
    if old then old(...) end
    fn(...)
  end
end
function W:Show()
  local was = self._shown
  self._shown = true
  if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function W:Hide()
  local was = self._shown
  self._shown = false
  if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function W:SetShown(s) if s then self:Show() else self:Hide() end end
function W:IsShown() return self._shown end
function W:IsVisible()
  local r = self
  while r do
    if not r._shown then return false end
    r = r._parent
  end
  return true
end
function W:GetParent() return self._parent end
function W:SetText(t) self._text = tostring(t or "") end
function W:GetText() return self._text end
function W:SetFormattedText(f, ...) self._text = string.format(f, ...) end
function W:SetSize(w, h) self._w, self._h = w, h end
function W:SetWidth(w) self._w = w end
function W:SetHeight(h) self._h = h end
function W:SetChecked(c) self._checked = c and true or false end
function W:GetChecked() return self._checked or false end
function W:HasFocus() return false end
function W:SetEnabled(e) self._enabled = e and true or false end
function W:Enable() self._enabled = true end
function W:Disable() self._enabled = false end
function W:IsEnabled() return self._enabled end
function W:SetPoint(point, a, b, c, d)
  local relTo, relPoint, x, y
  if type(a) == "number" then
    relTo, relPoint, x, y = nil, point, a, b
  elseif type(a) == "table" or a == nil then
    relTo = a
    if type(b) == "string" then relPoint, x, y = b, c, d else relPoint, x, y = point, b, c end
  elseif type(a) == "string" then
    relTo = _G[a]
    if type(b) == "string" then relPoint, x, y = b, c, d else relPoint, x, y = point, b, c end
  end
  for i, p in ipairs(self._points) do
    if p.point == point then table.remove(self._points, i) break end
  end
  self._points[#self._points + 1] = { point = point, relTo = relTo, relPoint = relPoint or point, x = x or 0, y = y or 0 }
end
function W:ClearAllPoints() self._points = {} end
function W:GetPoint(i)
  local p = self._points[i or 1]
  if p then return p.point, p.relTo, p.relPoint, p.x, p.y end
end
function W:SetAllPoints(rel)
  self._points = {
    { point = "TOPLEFT", relTo = rel, relPoint = "TOPLEFT", x = 0, y = 0 },
    { point = "BOTTOMRIGHT", relTo = rel, relPoint = "BOTTOMRIGHT", x = 0, y = 0 },
  }
end
function W:SetStartPoint(relPoint, relTo, x, y) self._startPoint = { relPoint, relTo, x or 0, y or 0 } end
function W:SetEndPoint(relPoint, relTo, x, y) self._endPoint = { relPoint, relTo, x or 0, y or 0 } end
function W:SetThickness(t) self._thick = t end
function W:SetColorTexture(r, g, b, a) self._color, self._texture, self._atlas = { r, g, b, a or 1 }, nil, nil end
function W:SetTexture(t) self._texture, self._color = t, nil end
function W:SetAtlas(a) self._atlas, self._color = a, nil end
function W:SetTexCoord(...) self._coord = { ... } end
function W:SetVertexColor(r, g, b, a) self._vertex = { r, g, b, a or 1 } end
function W:SetGradient(orientation, a, b) self._grad = { a, b, orientation } end
function W:SetRotation(r) self._rotation = r end
function W:SetTextColor(r, g, b, a) self._tcolor = { r, g, b, a or 1 } end
function W:SetJustifyH(j) self._justifyH = j end
function W:SetJustifyV(j) self._justifyV = j end
function W:SetWordWrap(w) self._wrap = w end
function W:SetMaxLines(n) self._maxLines = n end
function W:SetSpacing(s) self._spacing = s end
function W:SetFontObject(f) if type(f) == "string" then self._font = f end end
function W:SetNormalFontObject(f) if type(f) == "string" then self._font = f end end
function W:SetAlpha(a) self._alpha = a end
function W:GetAlpha() return self._alpha end
function W:SetScale(s) self._scale = s end
function W:GetScale() return self._scale end
function W:SetBackdrop(b) self._backdrop = b end
function W:SetBackdropColor(r, g, b, a) self._backdropColor = { r, g, b, a or 1 } end
function W:SetBackdropBorderColor(r, g, b, a) self._backdropBorder = { r, g, b, a or 1 } end
function W:SetClipsChildren(c) self._clips = c end
function W:SetScrollChild(child)
  child._points = { { point = "TOPLEFT", relTo = self, relPoint = "TOPLEFT", x = 0, y = 0 } }
end
function W:SetFrameStrata(s) self._strata = s end
function W:SetTitle(t) self._title = t end
function W:SetPortraitToAsset(a) self._portrait = a end
function W:LockHighlight() self._locked = true end
function W:UnlockHighlight() self._locked = false end
function W:RegisterEvent(e) self._events[e] = true end
function W:UnregisterEvent(e) self._events[e] = nil end
function W.StartMoving() end
function W.StopMovingOrSizing() end
function W:ClearFocus() end

local LAYER = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
local function Region(kind)
  return function(self, _, layer, a, b)
    local r = New(kind, self)
    r._layer = LAYER[layer or "ARTWORK"] or 3
    if kind == "FontString" then
      r._font = type(a) == "string" and a or "GameFontNormal"
      r._wrap = true
    else
      r._sub = type(b) == "number" and b or 0
    end
    self._regions[#self._regions + 1] = r
    return r
  end
end
W.CreateTexture = Region("Texture")
W.CreateFontString = Region("FontString")
W.CreateLine = Region("Line")

function CreateFrame(kind, name, parent, template)
  local f = New(kind, parent)
  f._template = template
  if parent then parent._children[#parent._children + 1] = f end
  wow.frames[#wow.frames + 1] = f
  if name then _G[name] = f end
  if template == "UIPanelButtonTemplate" then f._w, f._h = 80, 22 end
  if template == "UICheckButtonTemplate" then f._w, f._h = 24, 24 end
  if template == "UIPanelCloseButton" then f._w, f._h = 24, 24 end
  -- A scroll frame shows only what fits inside it.
  if kind == "ScrollFrame" then f._clips = true end
  if template == "PortraitFrameTemplate" then
    f.CloseButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.CloseButton:SetPoint("TOPRIGHT", 0, 0)
  end
  return f
end

UIParent = New("Frame")
UIParent._w, UIParent._h = 1280, 800
wow.root = UIParent

------------------------------------------------------------------------------
-- Geometry. Screen units, origin at the bottom left, y upward.
------------------------------------------------------------------------------
local function EffScale(r)
  local s = 1
  while r do
    s = s * (r._scale or 1)
    r = r._parent
  end
  return s
end

local Rect

local function TextBlock(r, width)
  local font = FONTS[r._font] or FONTS.GameFontNormal
  local size = font.size
  local wrap = r._wrap ~= false
  local lines, widest, truncated = LayoutText(r._text or "", size, r._tcolor or font.color, width, wrap, r._maxLines)
  local lineH = size * 1.22 + (r._spacing or 0)
  return lines, widest, #lines * lineH - (r._spacing or 0), lineH, size, truncated
end

local function PointOf(rect, point)
  local x, y
  if point:find("LEFT") then x = rect.l elseif point:find("RIGHT") then x = rect.l + rect.w else x = rect.l + rect.w / 2 end
  if point:find("TOP") then y = rect.b + rect.h elseif point:find("BOTTOM") then y = rect.b else y = rect.b + rect.h / 2 end
  return x, y
end

function Rect(r)
  if r == UIParent then return { l = 0, b = 0, w = UIParent._w, h = UIParent._h } end
  if r._resolving then return { l = 0, b = 0, w = 0, h = 0 } end
  if r._rect and r._stamp == wow.stamp then return r._rect end
  r._resolving = true
  local scale = EffScale(r)
  local left, right, cx, top, bottom, cy
  for _, p in ipairs(r._points) do
    local rel = p.relTo or r._parent or UIParent
    local rr = Rect(rel)
    local px, py = PointOf(rr, p.relPoint)
    px, py = px + p.x * scale, py + p.y * scale
    local pt = p.point
    if pt:find("LEFT") then left = px elseif pt:find("RIGHT") then right = px else cx = px end
    if pt:find("TOP") then top = py elseif pt:find("BOTTOM") then bottom = py else cy = py end
  end
  local w = r._w and r._w * scale or nil
  local h = r._h and r._h * scale or nil
  if left and right then w = right - left end
  if r._kind == "FontString" then
    local constrained = w and w > 0 and w / scale or nil
    r._constrained = constrained
    local _, widest, height = TextBlock(r, constrained)
    if not w or w <= 0 then w = widest * scale end
    if not (top and bottom) then h = height * scale end
  end
  if top and bottom then h = top - bottom end
  w, h = w or 0, h or 0
  local l, b
  if left then l = left elseif right then l = right - w elseif cx then l = cx - w / 2 else l = 0 end
  if bottom then b = bottom elseif top then b = top - h elseif cy then b = cy - h / 2 else b = 0 end
  if #r._points == 0 and r._parent then
    local pr = Rect(r._parent)
    l, b = pr.l, pr.b + pr.h - h
  end
  r._resolving = nil
  r._rect, r._stamp = { l = l, b = b, w = w, h = h }, wow.stamp
  return r._rect
end
wow.rect = function(r) wow.stamp = (wow.stamp or 0) + 1 return Rect(r) end

function W:GetWidth() local s = EffScale(self) return Rect(self).w / s end
function W:GetHeight() local s = EffScale(self) return Rect(self).h / s end
function W:GetLeft() local s = EffScale(self) return Rect(self).l / s end
function W:GetBottom() local s = EffScale(self) return Rect(self).b / s end
function W:GetTop() local s = EffScale(self) local r = Rect(self) return (r.b + r.h) / s end
function W:GetRight() local s = EffScale(self) local r = Rect(self) return (r.l + r.w) / s end
function W:GetCenter() local s = EffScale(self) local r = Rect(self) return (r.l + r.w / 2) / s, (r.b + r.h / 2) / s end
function W:GetEffectiveScale() return EffScale(self) end
function W:GetStringWidth()
  local _, widest = TextBlock(self, nil)
  return widest
end
function W:IsTruncated()
  local s = EffScale(self)
  local _, _, _, _, _, truncated = TextBlock(self, Rect(self).w / s)
  return truncated
end

------------------------------------------------------------------------------
-- Game functions the addon touches
------------------------------------------------------------------------------
UISpecialFrames = {}
SlashCmdList = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) wow.chat[#wow.chat + 1] = msg end }
wow.chat = {}
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function hooksecurefunc() end
function IsAltKeyDown() return false end
function IsShiftKeyDown() return wow.shift or false end
function IsControlKeyDown() return false end
function IsMouseButtonDown() return wow.mouseDown or false end
function InCombatLockdown() return false end
function GetCursorPosition() return (wow.cursor and wow.cursor[1] or 0), (wow.cursor and wow.cursor[2] or 0) end
function GetRealmName() return "Simulated" end
function UnitName() return "Demo" end
function UnitFactionGroup() return "Alliance" end
function GetMoney() return 5000000 end
function ReloadUI() end
Enum = setmetatable({}, { __index = function(t, k) local e = {} rawset(t, k, e) return e end })
C_Texture = { GetAtlasInfo = function() return nil end }
ChatFrameUtil = { InsertLink = function() end }
HandleModifiedItemClick = function() end

local timers = {}
C_Timer = {
  After = function(_, fn) timers[#timers + 1] = fn end,
  NewTicker = function(_, fn)
    local t = { fn = fn }
    function t:Cancel() self.cancelled = true end
    return t
  end,
  NewTimer = function(_, fn)
    local t = {}
    function t:Cancel() self.cancelled = true end
    timers[#timers + 1] = function() if not t.cancelled then fn() end end
    return t
  end,
}
function wow.runTimers()
  local guard = 0
  while #timers > 0 and guard < 1000000 do
    guard = guard + 1
    table.remove(timers, 1)()
  end
end

-- The tooltip: remembers its lines so that it can be drawn.
GameTooltip = New("GameTooltip")
GameTooltip._shown = false
GameTooltip._lines = {}
function GameTooltip:SetOwner(owner, anchor) self._owner, self._anchor, self._lines = owner, anchor, {} end
function GameTooltip:ClearLines() self._lines = {} end
function GameTooltip:SetText(text, r, g, b)
  self._lines = { { left = tostring(text or ""), lc = r and { r, g, b } or { 1, 0.82, 0 }, title = true } }
  self._shown = true
end
function GameTooltip:AddLine(text, r, g, b, wrap)
  self._lines[#self._lines + 1] = { left = tostring(text or ""), lc = r and { r, g, b } or { 1, 0.82, 0 }, wrap = wrap }
end
function GameTooltip:AddDoubleLine(left, right, r, g, b, r2, g2, b2)
  self._lines[#self._lines + 1] = { left = tostring(left or ""), right = tostring(right or ""), lc = r and { r, g, b } or { 1, 0.82, 0 },
    rc = r2 and { r2, g2, b2 } or { 1, 1, 1 } }
end
function GameTooltip:SetItemByID(id)
  local name = wow.itemName and wow.itemName(id) or ("Item " .. id)
  self._lines = { { left = name, lc = wow.itemColor and wow.itemColor(id) or { 1, 1, 1 }, title = true } }
  self._shown = true
end
function GameTooltip:Show() self._shown = true end
function GameTooltip:Hide() self._shown = false end
function GameTooltip:IsShown() return self._shown end

------------------------------------------------------------------------------
-- Loading and driving
------------------------------------------------------------------------------
function wow.load(tocPath, addonName)
  addonName = addonName or tocPath:match("([^/\\]+)%.toc$")
  local dir = tocPath:match("^(.*)[/\\][^/\\]+$")
  local ns = {}
  for line in io.lines(tocPath) do
    line = line:gsub("\r", ""):gsub("%s+$", "")
    if line:match("%.lua$") and not line:match("^#") then
      local file = line:gsub("\\", "/")
      if dir then file = dir .. "/" .. file end
      assert(loadfile(file))(addonName, ns)
    end
  end
  wow.ns = ns
  return ns
end

function wow.fire(event, ...)
  for _, f in ipairs(wow.frames) do
    if f._events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end

-- Runs a frame's OnEnter (to raise its tooltip) or OnClick.
function wow.hover(frame)
  if wow.hovered and wow.hovered ~= frame and wow.hovered.scripts.OnLeave then wow.hovered.scripts.OnLeave(wow.hovered) end
  wow.hovered = frame
  if frame and frame.scripts.OnEnter then frame.scripts.OnEnter(frame) end
end
function wow.click(frame, button)
  if frame.scripts.OnClick then frame.scripts.OnClick(frame, button or "LeftButton") end
  wow.runTimers()
end
-- Puts the pointer on the middle of a region (or at a fraction of it).
function wow.point(region, fx, fy)
  wow.stamp = (wow.stamp or 0) + 1
  local r = Rect(region)
  wow.cursor = { r.l + r.w * (fx or 0.5), r.b + r.h * (fy or 0.5) }
end

------------------------------------------------------------------------------
-- Drawing to SVG
------------------------------------------------------------------------------
local out
local function emit(s) out[#out + 1] = s end
local function rgb(c) return string.format("rgb(%d,%d,%d)", (c[1] or c.r) * 255, (c[2] or c.g) * 255, (c[3] or c.b) * 255) end
local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local H                                     -- canvas height, to flip y
local defs, defN

-- Icons: tools/render/icons/<fileID or name>.png if present, else a tile.
local iconCache = {}
wow.missingIcons = {}
local function IconData(key)
  if iconCache[key] ~= nil then return iconCache[key] end
  local name = tostring(key):gsub("^.*[/\\]", ""):lower()
  local f = io.open(here .. "/icons/" .. name .. ".b64", "r")
  local data = f and f:read("*a") or false
  if f then f:close() end
  iconCache[key] = data and data:gsub("%s", "") or false
  if not data then wow.missingIcons[name] = true end
  return iconCache[key]
end

local function DrawTexture(r, rect, alpha)
  local x, y, w, h = rect.l, H - rect.b - rect.h, rect.w, rect.h
  if w <= 0 or h <= 0 then return end
  if r._grad then
    defN = defN + 1
    local a, b = r._grad[1], r._grad[2]
    local across = r._grad[3] == "HORIZONTAL"
    defs[#defs + 1] = string.format('<linearGradient id="g%d" ' .. (across and 'x1="0" y1="0" x2="1" y2="0"' or 'x1="0" y1="1" x2="0" y2="0"') .. '><stop offset="0" stop-color="%s" stop-opacity="%.3f"/><stop offset="1" stop-color="%s" stop-opacity="%.3f"/></linearGradient>',
      defN, rgb(a), (a.a or 1) * alpha, rgb(b), (b.a or 1) * alpha)
    emit(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="url(#g%d)"/>', x, y, w, h, defN))
    return
  end
  if r._color then
    local rot = r._rotation and string.format(' transform="rotate(%.1f %.2f %.2f)"', -math.deg(r._rotation), x + w / 2, y + h / 2) or ""
    emit(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s" fill-opacity="%.3f"%s/>',
      x, y, w, h, rgb(r._color), (r._color[4] or 1) * alpha, rot))
    return
  end
  if r._atlas then
    emit(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="#15110c" fill-opacity="%.3f"/>', x, y, w, h, alpha))
    return
  end
  local tex = r._texture
  if not tex then return end
  local name = tostring(tex)
  if name:find("UI%-TOD%-Indicator") then
    -- The minimap's sun or moon.
    local night = r._coord and r._coord[1] and r._coord[1] >= 0.5
    local cxp, cyp, rad = x + w / 2, y + h / 2, min(w, h) * 0.36
    if night then
      emit(string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="#b9c6e8" fill-opacity="%.2f"/><circle cx="%.2f" cy="%.2f" r="%.2f" fill="#0d0b09"/>',
        cxp, cyp, rad, alpha, cxp + rad * 0.45, cyp - rad * 0.25, rad * 0.85))
    else
      emit(string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="#ffd23a" fill-opacity="%.2f"/>', cxp, cyp, rad * 0.8, alpha))
      for k = 0, 7 do
        local ang = k * math.pi / 4
        emit(string.format('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="#ffd23a" stroke-width="1" stroke-opacity="%.2f"/>',
          cxp + math.cos(ang) * rad, cyp + math.sin(ang) * rad, cxp + math.cos(ang) * rad * 1.35, cyp + math.sin(ang) * rad * 1.35, alpha))
      end
    end
    return
  end
  if name:find("WhiteIconFrame") then
    local c = r._vertex or { 1, 1, 1 }
    emit(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="none" stroke="%s" stroke-width="1.6" stroke-opacity="%.2f" rx="2"/>',
      x + 0.8, y + 0.8, w - 1.6, h - 1.6, rgb(c), alpha))
    return
  end
  local data = IconData(tex)
  if data then
    emit(string.format('<image x="%.2f" y="%.2f" width="%.2f" height="%.2f" opacity="%.2f" preserveAspectRatio="none" href="data:image/png;base64,%s"/>',
      x, y, w, h, alpha, data))
  else
    -- A stand-in tile, tinted by the texture's identity.
    local n = 0
    for ch in name:gmatch(".") do n = (n * 31 + ch:byte()) % 360 end
    emit(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="3" fill="hsl(%d,35%%,32%%)" fill-opacity="%.2f"/>', x, y, w, h, n, alpha))
    emit(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="2" fill="hsl(%d,45%%,48%%)" fill-opacity="%.2f"/>',
      x + w * 0.22, y + h * 0.22, w * 0.56, h * 0.56, n, alpha))
  end
end

local function DrawLines(lines, x, yTop, width, size, lineH, justify, alpha)
  for i, line in ipairs(lines) do
    local lx = x
    if justify == "RIGHT" then lx = x + width - line.width elseif justify == "CENTER" then lx = x + (width - line.width) / 2 end
    local baseline = yTop + (i - 1) * lineH + size * 0.93
    for _, run in ipairs(line.runs) do
      if run.coin then
        emit(string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" fill-opacity="%.2f" stroke="#000" stroke-opacity="0.5" stroke-width="0.5"/>',
          lx + size * 0.5, baseline - size * 0.33, size * 0.38, COIN[run.coin] or "#fff", alpha))
        lx = lx + size * 1.05
      elseif run.text and run.text ~= "" then
        emit(string.format('<text x="%.2f" y="%.2f" font-size="%.2f" fill="%s" fill-opacity="%.2f" xml:space="preserve">%s</text>',
          lx, baseline, size, rgb(run.color), alpha, esc(run.text)))
        lx = lx + TextWidth(run.text, size)
      end
    end
  end
end

local function DrawFontString(r, rect, alpha, scale)
  if (r._text or "") == "" then return end
  local lines, _, height, lineH, size = TextBlock(r, r._constrained)
  local yTop = H - rect.b - rect.h
  local extra = rect.h - height * scale
  if r._justifyV == "BOTTOM" then yTop = yTop + extra elseif r._justifyV ~= "TOP" then yTop = yTop + extra / 2 end
  emit(string.format('<g transform="translate(%.2f %.2f) scale(%.4f)">', rect.l, yTop, scale))
  DrawLines(lines, 0, 0, rect.w / scale, size, lineH, r._justifyH or "LEFT", alpha * (r._tcolor and r._tcolor[4] or 1))
  emit("</g>")
end

local function DrawLine(r, alpha)
  if not (r._startPoint and r._endPoint and r._color) then return end
  local scale = EffScale(r)
  local function at(p)
    local rr = Rect(p[2] or r._parent)
    local x, y = PointOf(rr, p[1])
    return x + p[3] * scale, H - (y + p[4] * scale)
  end
  local x1, y1 = at(r._startPoint)
  local x2, y2 = at(r._endPoint)
  emit(string.format('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" stroke-opacity="%.3f" stroke-width="%.2f" stroke-linecap="round"/>',
    x1, y1, x2, y2, rgb(r._color), (r._color[4] or 1) * alpha, (r._thick or 1) * scale))
end

local function Box(x, y, w, h, fill, fillA, stroke, strokeA, radius, sw)
  emit(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.1f" fill="%s" fill-opacity="%.3f" stroke="%s" stroke-opacity="%.3f" stroke-width="%.1f"/>',
    x, y, w, h, radius or 0, fill, fillA, stroke or "none", strokeA or 0, sw or 1))
end

local function CenterText(text, x, y, w, h, size, color, alpha)
  local tw = TextWidth(text, size)
  emit(string.format('<text x="%.2f" y="%.2f" font-size="%.2f" fill="%s" fill-opacity="%.2f">%s</text>',
    x + (w - tw) / 2, y + h / 2 + size * 0.35, size, color, alpha, esc(text)))
end

-- The parts the game's templates draw by themselves.
local function DrawChrome(f, rect, alpha, scale)
  local x, y, w, h = rect.l, H - rect.b - rect.h, rect.w, rect.h
  local t = f._template or ""
  if t:find("PortraitFrameTemplate") then
    Box(x, y, w, h, "#1b1712", 0.97 * alpha, "#8a7446", alpha, 6 * scale, 2 * scale)
    Box(x + 2 * scale, y + 2 * scale, w - 4 * scale, 22 * scale, "#2a2116", alpha, "#5c4a2a", alpha, 4 * scale)
    CenterText(f._title or "", x, y + 2 * scale, w, 22 * scale, 13 * scale, "#ffd100", alpha)
    emit(string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="#3a2c12" stroke="#b89a55" stroke-width="%.1f" fill-opacity="%.2f"/>',
      x + 30 * scale, y + 30 * scale, 28 * scale, 2 * scale, alpha))
    emit(string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="#f2c230" stroke="#8a6a12" stroke-width="%.1f" fill-opacity="%.2f"/>',
      x + 30 * scale, y + 30 * scale, 15 * scale, 2 * scale, alpha))
  elseif t:find("InsetFrameTemplate") then
    Box(x, y, w, h, "#0d0b09", 0.9 * alpha, "#4d4027", alpha, 3 * scale)
  elseif f._backdrop then
    local bc, ec = f._backdropColor or { 0.06, 0.05, 0.04, 0.95 }, f._backdropBorder or { 0.6, 0.5, 0.3, 1 }
    Box(x, y, w, h, rgb(bc), (bc[4] or 1) * alpha, rgb(ec), (ec[4] or 1) * alpha, 5 * scale, 1.4 * scale)
  elseif t:find("UIPanelButtonTemplate") then
    local on = f._enabled ~= false
    local fill = f._locked and "#a8281c" or (on and "#6e1611" or "#2c2622")
    Box(x, y, w, h, fill, alpha, on and "#c8a45a" or "#5a5248", alpha, 3 * scale)
    if on then Box(x + 1, y + 1, w - 2, h * 0.45, "#ffffff", 0.07 * alpha, nil, 0, 3 * scale) end
    CenterText(f._text or "", x, y, w, h, 11.5 * scale, on and "#ffd100" or "#7f7f7f", alpha)
  elseif t:find("UICheckButtonTemplate") then
    local s = min(w, h)
    Box(x + s * 0.18, y + s * 0.18, s * 0.64, s * 0.64, "#15120e", alpha, "#9a8452", alpha, 2 * scale)
    if f._checked then
      emit(string.format('<polyline points="%.2f,%.2f %.2f,%.2f %.2f,%.2f" fill="none" stroke="#ffd100" stroke-width="%.1f" stroke-opacity="%.2f" stroke-linecap="round" stroke-linejoin="round"/>',
        x + s * 0.28, y + s * 0.5, x + s * 0.45, y + s * 0.68, x + s * 0.76, y + s * 0.26, 2.2 * scale, alpha))
    end
  elseif t:find("UIPanelCloseButton") then
    Box(x + 3 * scale, y + 3 * scale, w - 6 * scale, h - 6 * scale, "#7a1a12", alpha, "#c8a45a", alpha, 3 * scale)
    CenterText("x", x, y - scale, w, h, 13 * scale, "#ffd100", alpha)
  elseif f._kind == "EditBox" then
    Box(x, y, w, h, "#0a0908", 0.9 * alpha, "#6b5a36", alpha, 3 * scale)
    local txt = f._text ~= "" and f._text or (t:find("SearchBox") and "Search" or "")
    local color = f._text ~= "" and "#ffffff" or "#7f7f7f"
    emit(string.format('<text x="%.2f" y="%.2f" font-size="%.2f" fill="%s" fill-opacity="%.2f">%s</text>',
      x + 7 * scale, y + h / 2 + 4 * scale, 11.5 * scale, color, alpha, esc(txt)))
  end
end

local function DrawFrame(f, alpha)
  if not f._shown then return end
  alpha = alpha * (f._alpha or 1)
  local rect = Rect(f)
  local scale = EffScale(f)
  local clipped = f._clips
  if clipped then
    defN = defN + 1
    defs[#defs + 1] = string.format('<clipPath id="c%d"><rect x="%.2f" y="%.2f" width="%.2f" height="%.2f"/></clipPath>',
      defN, rect.l, H - rect.b - rect.h, rect.w, rect.h)
    emit(string.format('<g clip-path="url(#c%d)">', defN))
  end
  DrawChrome(f, rect, alpha, scale)
  local regions = {}
  for _, r in ipairs(f._regions) do regions[#regions + 1] = r end
  table.sort(regions, function(a, b)
    if a._layer ~= b._layer then return a._layer < b._layer end
    if (a._sub or 0) ~= (b._sub or 0) then return (a._sub or 0) < (b._sub or 0) end
    return a._serial < b._serial
  end)
  for _, r in ipairs(regions) do
    local visible = r._shown and (r._layer ~= 5 or wow.hovered == f or f._locked)
    if visible then
      local ra = alpha * (r._alpha or 1)
      if r._kind == "Texture" then
        DrawTexture(r, Rect(r), ra)
      elseif r._kind == "FontString" then
        DrawFontString(r, Rect(r), ra, EffScale(r))
      elseif r._kind == "Line" then
        DrawLine(r, ra)
      end
    end
  end
  for _, c in ipairs(f._children) do
    if c._strata ~= "DIALOG" then DrawFrame(c, alpha) end
  end
  if clipped then emit("</g>") end
end

local function DrawTooltip()
  local tip = GameTooltip
  if not tip._shown or #tip._lines == 0 then return end
  local size, pad, maxW = 11.5, 9, 330
  local rows, width, height = {}, 0, pad
  for _, line in ipairs(tip._lines) do
    local s = line.title and 13 or size
    local leftLines, lw = LayoutText(line.left, s, line.lc, line.right and nil or maxW, line.wrap or not line.right, nil)
    local rightLines, rw = nil, 0
    if line.right then rightLines, rw = LayoutText(line.right, s, line.rc, nil, false, nil) end
    local lineH = s * 1.3
    local rowH = #leftLines * lineH
    rows[#rows + 1] = { left = leftLines, right = rightLines, size = s, lineH = lineH, y = height, lw = lw, rw = rw }
    width = max(width, lw + (line.right and (rw + 24) or 0))
    height = height + rowH + 1.5
  end
  width, height = min(max(width, 120), maxW + 40) + pad * 2, height + pad
  local owner = tip._owner and Rect(tip._owner) or { l = 400, b = 400, w = 0, h = 0 }
  local x, y = owner.l + owner.w + 6, H - owner.b - owner.h
  if tip._anchor == "ANCHOR_BOTTOM" then x, y = owner.l, H - owner.b + 4 end
  if tip._anchor == "ANCHOR_TOP" then x, y = owner.l, H - owner.b - owner.h - height - 4 end
  if tip._anchor == "ANCHOR_LEFT" then x = owner.l - width - 6 end
  if wow.cursor and (tip._anchor == "ANCHOR_RIGHT" or tip._anchor == nil) then x, y = wow.cursor[1] + 18, H - wow.cursor[2] + 10 end
  -- ANCHOR_NONE with a point of its own: its TOPRIGHT or TOPLEFT on another frame's corner.
  local p = tip._anchor == "ANCHOR_NONE" and tip._points and tip._points[1]
  if p and p.relTo and (p.point == "TOPRIGHT" or p.point == "TOPLEFT") then
    local r = Rect(p.relTo)
    local rx = (p.relPoint:find("RIGHT") and r.l + r.w) or (p.relPoint:find("LEFT") and r.l) or (r.l + r.w / 2)
    local ry = (p.relPoint:find("TOP") and r.b + r.h) or (p.relPoint:find("BOTTOM") and r.b) or (r.b + r.h / 2)
    x = rx + (p.x or 0) - (p.point == "TOPRIGHT" and width or 0)
    y = H - (ry + (p.y or 0))
  end
  x = max(4, min(UIParent._w - width - 4, x))
  y = max(4, min(H - height - 4, y))
  Box(x, y, width, height, "#0b0a12", 0.96, "#b8b8c8", 0.9, 5, 1.2)
  for _, row in ipairs(rows) do
    DrawLines(row.left, x + pad, y + row.y, width - pad * 2, row.size, row.lineH, "LEFT", 1)
    if row.right then DrawLines(row.right, x + pad, y + row.y, width - pad * 2, row.size, row.lineH, "RIGHT", 1) end
  end
end

-- opts: width, height, caption (a line of text under the picture),
-- background (css colour).
function wow.svg(path, opts)
  opts = opts or {}
  wow.stamp = (wow.stamp or 0) + 1
  out, defs, defN = {}, {}, 0
  local width, height = opts.width or UIParent._w, opts.height or UIParent._h
  H = UIParent._h
  local body = out
  DrawFrame(UIParent, 1)
  -- Dialogs go on top of everything else.
  for _, f in ipairs(wow.frames) do
    if f._strata == "DIALOG" and f:IsVisible() then DrawFrame(f, 1) end
  end
  DrawTooltip()
  if wow.cursor then
    local cxp, cyp = wow.cursor[1], H - wow.cursor[2]
    emit(string.format('<path d="M%.1f %.1f l0 17 l4.5 -4 l3 7 l3 -1.3 l-3 -6.8 l6 -0.4 z" fill="#fff" stroke="#000" stroke-width="1"/>', cxp, cyp))
  end
  -- opts.view = { x, y, w, h } (from the top left) draws only that part;
  -- opts.zoom enlarges the picture.
  local view = opts.view or { 0, 0, width, height }
  local zoom = opts.zoom or 1
  width, height = view[3], view[4]
  local head = {
    string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%.1f %.1f %.1f %.1f" font-family="Fira Sans Condensed, Fira Sans, sans-serif">',
      floor(width * zoom + 0.5), floor(height * zoom + 0.5), view[1], view[2], width, height),
    string.format('<rect x="%.1f" y="%.1f" width="%d" height="%d" fill="%s"/>', view[1], view[2], width, height, opts.background or "#11151a"),
    "<defs>" .. table.concat(defs, "") .. "</defs>",
  }
  local tail = {}
  if opts.caption then
    local size = 21 / zoom * (opts.captionScale or 1)
    local tw = TextWidth(opts.caption, size)
    local barH = size * 2.2
    tail[#tail + 1] = string.format('<rect x="%.1f" y="%.1f" width="%d" height="%.1f" fill="#000" fill-opacity="0.8"/>',
      view[1], view[2] + height - barH, width, barH)
    tail[#tail + 1] = string.format('<text x="%.1f" y="%.1f" font-size="%.1f" fill="#ffe9a8">%s</text>',
      view[1] + (width - tw) / 2, view[2] + height - barH * 0.32, size, esc(opts.caption))
  end
  tail[#tail + 1] = "</svg>"
  local f = assert(io.open(path, "w"))
  f:write(table.concat(head, "\n"), "\n", table.concat(body, "\n"), "\n", table.concat(tail, "\n"), "\n")
  f:close()
end

-- The part of the picture a region covers, with a margin: { x, y, w, h }.
function wow.viewOf(region, pad)
  wow.stamp = (wow.stamp or 0) + 1
  local r = Rect(region)
  pad = pad or 0
  return { r.l - pad, UIParent._h - r.b - r.h - pad, r.w + pad * 2, r.h + pad * 2 }
end

function wow.unmodelled()
  local names = {}
  for k in pairs(unmodelled) do names[#names + 1] = k end
  table.sort(names)
  return names
end

return wow
