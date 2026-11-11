-- CraftGraph's look: dark stone, a gold frame with corner pieces, a title
-- plaque, gold-rimmed buttons and notched icon frames. The textures are in
-- Media/, drawn from code by tools/render/make_textures.py. Everything here
-- only dresses frames the rest of the addon builds; turning it off
-- (/cg skin) leaves the game's own look.
local ADDON, ns = ...
local K = {}
ns.Skin = K

local PATH = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
function K.Tex(name) return PATH .. name end

-- Whether the look is on. Read when a frame is built, so a change shows
-- after a reload.
function K.On()
  return not ns.settings or ns.settings.skin ~= false
end

-- A serif font for titles and headings, made once. Falls back to the game's
-- own large font when the serif cannot be loaded.
local fonts = {}
function K.Font(size, base)
  base = base or "GameFontNormalLarge"
  local name = "CraftGraphSerif" .. size
  if fonts[name] ~= nil then return fonts[name] or base end
  fonts[name] = false
  if not (CreateFont and K.On()) then return base end
  local f = _G[name] or CreateFont(name)
  if f.SetFont then f:SetFont("Fonts\\MORPHEUS.TTF", size, "") end
  local file = f.GetFont and f:GetFont()
  if not file then return base end
  if f.SetTextColor then f:SetTextColor(1, 0.82, 0.35) end
  if f.SetShadowColor then f:SetShadowColor(0, 0, 0, 1) end
  if f.SetShadowOffset then f:SetShadowOffset(1, -1) end
  fonts[name] = name
  return name
end

-- Hides the textures a template drew, so ours show instead.
local function HideTemplateArt(f)
  if not f.GetRegions then return end
  for _, r in ipairs({ f:GetRegions() }) do
    if r and r.GetObjectType and r:GetObjectType() == "Texture" then r:SetAlpha(0) end
  end
  for _, key in ipairs({ "NineSlice", "Bg", "Background", "TitleBg", "TopTileStreaks" }) do
    local part = f[key]
    if type(part) == "table" and part.Hide then part:Hide() end
  end
end

local function Tex(parent, layer, name, sub)
  local t = parent:CreateTexture(nil, layer, nil, sub or 0)
  if name then t:SetTexture(K.Tex(name)) end
  return t
end

------------------------------------------------------------------------------
-- The window: stone behind everything, a gold band on each edge, a corner
-- piece with a gem at each corner, the title on a plaque.
------------------------------------------------------------------------------
local GEMS = {
  { 0.95, 0.18, 0.22 }, { 0.95, 0.18, 0.22 }, { 0.25, 0.85, 0.95 }, { 0.95, 0.25, 0.2 },
}

function K.Window(f, title)
  if not K.On() then return end
  f.cgSkin = "window"
  HideTemplateArt(f)
  local stone = Tex(f, "BACKGROUND", nil, -8)
  stone:SetTexture(K.Tex("cg-stone"), "REPEAT", "REPEAT")
  if stone.SetHorizTile then stone:SetHorizTile(true) stone:SetVertTile(true) end
  stone:SetPoint("TOPLEFT", 4, -4)
  stone:SetPoint("BOTTOMRIGHT", -4, 4)
  f.cgStone = stone

  local B, OUT = 16, 7                     -- band width, and how far it sits outside
  local top = Tex(f, "BORDER", "cg-frame-h")
  top:SetPoint("TOPLEFT", -OUT, OUT) top:SetPoint("TOPRIGHT", OUT, OUT) top:SetHeight(B)
  local bottom = Tex(f, "BORDER", "cg-frame-h")
  bottom:SetPoint("BOTTOMLEFT", -OUT, -OUT) bottom:SetPoint("BOTTOMRIGHT", OUT, -OUT) bottom:SetHeight(B)
  bottom:SetTexCoord(0, 1, 1, 0)
  local left = Tex(f, "BORDER", "cg-frame-v")
  left:SetPoint("TOPLEFT", -OUT, OUT) left:SetPoint("BOTTOMLEFT", -OUT, -OUT) left:SetWidth(B)
  local right = Tex(f, "BORDER", "cg-frame-v")
  right:SetPoint("TOPRIGHT", OUT, OUT) right:SetPoint("BOTTOMRIGHT", OUT, -OUT) right:SetWidth(B)
  right:SetTexCoord(1, 0, 0, 1)

  -- Corner pieces (the top left one is mirrored for the others) with a
  -- gem in each socket. They sit on a frame above the content's edges.
  local deco = CreateFrame("Frame", nil, f)
  deco:SetAllPoints()
  deco:SetFrameLevel((f:GetFrameLevel() or 1) + 8)
  if deco.EnableMouse then deco:EnableMouse(false) end
  f.cgDeco = deco
  local C, SOCK, GEM = 60, 15.5, 15
  local corners = {
    { "TOPLEFT", -OUT - 3, OUT + 3, 0, 1, 0, 1, 1, -1 },
    { "TOPRIGHT", OUT + 3, OUT + 3, 1, 0, 0, 1, -1, -1 },
    { "BOTTOMLEFT", -OUT - 3, -OUT - 3, 0, 1, 1, 0, 1, 1 },
    { "BOTTOMRIGHT", OUT + 3, -OUT - 3, 1, 0, 1, 0, -1, 1 },
  }
  for i, c in ipairs(corners) do
    local t = Tex(deco, "ARTWORK", "cg-corner")
    t:SetSize(C, C)
    t:SetPoint(c[1], f, c[1], c[2], c[3])
    t:SetTexCoord(c[4], c[5], c[6], c[7])
    local g = Tex(deco, "OVERLAY", "cg-gem")
    g:SetSize(GEM, GEM)
    g:SetPoint("CENTER", t, c[1], c[8] * SOCK, c[9] * SOCK)
    g:SetVertexColor(GEMS[i][1], GEMS[i][2], GEMS[i][3])
  end

  -- The title plaque over the top edge.
  local plaque = Tex(deco, "ARTWORK", "cg-plaque", 1)
  plaque:SetSize(300, 75)
  plaque:SetPoint("TOP", f, "TOP", 0, 32)
  local name = deco:CreateFontString(nil, "OVERLAY", K.Font(22))
  name:SetPoint("CENTER", plaque, "CENTER", 0, 1)
  name:SetText(title)
  f.cgTitle = name
end

-- The medallion at the top left, around an icon.
function K.Emblem(f, icon)
  if not K.On() then return end
  local deco = f.cgDeco or f
  local pic = deco:CreateTexture(nil, "ARTWORK", nil, 2)
  pic:SetSize(38, 38)
  pic:SetPoint("CENTER", f, "TOPLEFT", 26, -26)
  pic:SetTexture(icon)
  if pic.SetTexCoord then pic:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
  local ring = deco:CreateTexture(nil, "OVERLAY", nil, 3)
  ring:SetSize(66, 66)
  ring:SetPoint("CENTER", pic, "CENTER")
  ring:SetTexture(K.Tex("cg-emblem"))
end

------------------------------------------------------------------------------
-- Panels: a dark glass over the stone with a thin gold line around it.
------------------------------------------------------------------------------
function K.Panel(f, opts)
  if not K.On() then return end
  opts = opts or {}
  f.cgSkin = "panel"
  HideTemplateArt(f)
  local bg = Tex(f, "BACKGROUND", nil, -7)
  bg:SetAllPoints()
  bg:SetColorTexture(0.025, 0.03, 0.04, opts.alpha or 0.72)
  local function Edge(p1, p2, horizontal, r, g, b, a, inset)
    local t = Tex(f, "BORDER", nil, 2)
    t:SetColorTexture(r, g, b, a)
    t:SetPoint(p1, inset * (p1:find("LEFT") and 1 or -1), inset * (p1:find("TOP") and -1 or 1))
    t:SetPoint(p2, inset * (p2:find("LEFT") and 1 or -1), inset * (p2:find("TOP") and -1 or 1))
    if horizontal then t:SetHeight(1) else t:SetWidth(1) end
  end
  for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
    { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
    Edge(e[1], e[2], e[3], 0.62, 0.48, 0.24, 0.9, 0)
    Edge(e[1], e[2], e[3], 0, 0, 0, 0.7, 1)
  end
  if opts.sigil then
    local s = Tex(f, "BACKGROUND", "cg-sigil", -6)
    s:SetSize(opts.sigil, opts.sigil)
    s:SetPoint("CENTER", 0, 0)
    s:SetVertexColor(0.6, 0.78, 1, 0.13)
    f.cgSigil = s
  end
end

------------------------------------------------------------------------------
-- Buttons: gold rim around a dark face; the page in view is lit gold.
------------------------------------------------------------------------------
local CAP = 24 / 256                     -- the rounded ends, as a share of the texture

local function Refresh(b)
  local s = b.cgSlices
  if not s then return end
  local file = K.Tex(b.cgLit and "cg-button-lit" or "cg-button")
  local on = b:IsEnabled() and true or false
  for _, t in ipairs(s) do
    t:SetTexture(file)
    if t.SetDesaturated then t:SetDesaturated(not on) end
    local k = on and (b.cgDown and 0.75 or 1) or 0.7
    t:SetVertexColor(k, k, k)
  end
  s[1]:SetTexCoord(0, CAP, 0, 1)
  s[2]:SetTexCoord(CAP, 1 - CAP, 0, 1)
  s[3]:SetTexCoord(1 - CAP, 1, 0, 1)
end
K.RefreshButton = Refresh

-- After a call to one of the button's own methods, redraws it.
local function After(b, method)
  local orig = b[method]
  if type(orig) ~= "function" then return end
  b[method] = function(self, ...)
    local a, c = orig(self, ...)
    Refresh(self)
    return a, c
  end
end

-- h: the button's height (22 when not given), which sets the ends' width.
function K.Button(b, h)
  if not K.On() or b.cgSlices then return b end
  b.cgSkin = "button"
  HideTemplateArt(b)
  for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture" }) do
    local t = b[get] and b[get](b)
    if t and t.SetAlpha then t:SetAlpha(0) end
  end
  h = h or 22
  local capW = math.floor(h * 24 / 64 + 0.5)
  local l = Tex(b, "BORDER", nil, 1)
  l:SetPoint("TOPLEFT") l:SetPoint("BOTTOMLEFT") l:SetWidth(capW)
  local r = Tex(b, "BORDER", nil, 1)
  r:SetPoint("TOPRIGHT") r:SetPoint("BOTTOMRIGHT") r:SetWidth(capW)
  local m = Tex(b, "BORDER", nil, 1)
  m:SetPoint("TOPLEFT", l, "TOPRIGHT") m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
  b.cgSlices = { l, m, r }
  if b.SetHighlightTexture then
    b:SetHighlightTexture(K.Tex("cg-button-hl"), "ADD")
    local hl = b.GetHighlightTexture and b:GetHighlightTexture()
    if hl then
      hl:SetAlpha(0.8)
      hl:SetTexCoord(0, 1, 0, 1)
      hl:ClearAllPoints()
      hl:SetAllPoints()
    end
  end
  for _, method in ipairs({ "Enable", "Disable", "SetEnabled" }) do After(b, method) end
  -- The rounded ends keep their shape when the height changes later.
  local function Caps(height)
    if type(height) ~= "number" or height <= 0 then return end
    local w = math.floor(height * 24 / 64 + 0.5)
    l:SetWidth(w)
    r:SetWidth(w)
  end
  local setHeight, setSize = b.SetHeight, b.SetSize
  if setHeight then
    b.SetHeight = function(self, height, ...)
      setHeight(self, height, ...)
      Caps(height)
    end
  end
  if setSize then
    b.SetSize = function(self, width, height, ...)
      setSize(self, width, height, ...)
      Caps(height)
    end
  end
  -- The game lights the page in view with LockHighlight; here that is the
  -- gold face.
  local lock, unlock = b.LockHighlight, b.UnlockHighlight
  b.LockHighlight = function(self, ...)
    self.cgLit = true
    if lock then lock(self, ...) end
    Refresh(self)
  end
  b.UnlockHighlight = function(self, ...)
    self.cgLit = nil
    if unlock then unlock(self, ...) end
    Refresh(self)
  end
  b:HookScript("OnMouseDown", function(self) self.cgDown = true Refresh(self) end)
  b:HookScript("OnMouseUp", function(self) self.cgDown = nil Refresh(self) end)
  Refresh(b)
  return b
end

------------------------------------------------------------------------------
-- An item's icon frame: a bevelled ring with a diamond above and below,
-- tinted with the item's quality colour.
------------------------------------------------------------------------------
function K.IconFrame(border, icon, size)
  if not K.On() then return false end
  border:SetTexture(K.Tex("cg-iconframe"))
  border:ClearAllPoints()
  local s = (size or 40) * 64 / 42
  border:SetSize(s, s)
  border:SetPoint("CENTER", icon, "CENTER")
  return true
end

-- A soft glow around a frame of size w x h, for the item in the middle of
-- the graph. The glow's bright line sits on the frame's edge.
function K.Glow(f, w, h, r, g, b)
  if not K.On() then return nil end
  local t = f:CreateTexture(nil, "BACKGROUND", nil, -2)
  t:SetTexture(K.Tex("cg-glow"))
  if t.SetBlendMode then t:SetBlendMode("ADD") end
  -- In the texture the line runs 28 pixels in from each edge of 256 x 128.
  local px, py = w * (28 / 256) / (1 - 56 / 256), h * (28 / 128) / (1 - 56 / 128)
  t:SetPoint("TOPLEFT", -px, py)
  t:SetPoint("BOTTOMRIGHT", px, -py)
  t:SetVertexColor(r, g, b, 0.9)
  t:Hide()
  return t
end
