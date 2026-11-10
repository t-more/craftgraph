-- wowmock.lua: a small stand-in for the World of Warcraft addon environment,
-- so an addon's Lua can be loaded and exercised with plain Lua 5.1 (the
-- language version the game uses) without the game.
--
-- What it proves: your own code is consistent (no nil indexing, no typos,
-- no wrong arithmetic) and your logic gives the numbers you expect.
-- What it cannot prove: that the real game accepts each call. Any widget
-- method not modelled here is accepted silently; `wow.unmodelled()` lists
-- them so you can check those names against the game's interface source.
--
-- Usage, from the addon folder:
--
--   local wow = dofile("/path/to/wowmock.lua")
--   local ns = wow.load("MyAddon.toc")            -- runs every .lua the TOC lists
--   wow.fire("ADDON_LOADED", "MyAddon")
--   wow.fire("PLAYER_LOGIN")
--   wow.check(ns.Something() == 42, "something is 42")
--   wow.runTimers()                               -- runs C_Timer callbacks
--   wow.finish()                                  -- prints a summary, exits non-zero on failure
--
-- Add or replace game functions as plain globals before or after loading:
--   C_AuctionHouse = { GetNumReplicateItems = function() return 0 end }

local wow = { frames = {}, now = 1794300000, clock = 0, checks = 0, failures = 0 }

------------------------------------------------------------------------------
-- Differences between the game's Lua and stock Lua 5.1
------------------------------------------------------------------------------
-- The game's xpcall passes extra arguments on to the function; stock 5.1 does not.
local rawxpcall = xpcall
xpcall = function(f, handler, ...)
  local args, n = { ... }, select("#", ...)
  return rawxpcall(function() return f(unpack(args, 1, n)) end, handler)
end

time = function() return wow.now end
date = os.date
GetTime = function() return wow.clock end
debugstack = function() return debug.traceback("", 2) end
tinsert, tremove, wipe = table.insert, table.remove, function(t) for k in pairs(t) do t[k] = nil end return t end
strsplit = function(sep, s) local out = {} for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end return unpack(out) end
format, strfind, strsub, strlower, strupper = string.format, string.find, string.sub, string.lower, string.upper
floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs

------------------------------------------------------------------------------
-- Widgets. Fields you set on a frame behave like fields (unset = nil).
-- Methods the mock does not model are accepted and do nothing; the game's
-- methods all start with a capital letter, which is how they are told apart.
------------------------------------------------------------------------------
local unmodelled = {}
local Widget = {}
Widget.__index = function(_, key)
  local v = rawget(Widget, key)
  if v ~= nil then return v end
  if type(key) == "string" and key:match("^%u") then
    return function() unmodelled[key] = true end
  end
  return nil
end

local function NewWidget(kind)
  return setmetatable({ kind = kind, scripts = {}, events = {}, shown = true, text = "", w = 0, h = 0 }, Widget)
end
wow.NewWidget = NewWidget

function Widget:SetScript(name, fn) self.scripts[name] = fn end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:HookScript(name, fn)
  local old = self.scripts[name]
  self.scripts[name] = function(...)
    if old then old(...) end
    fn(...)
  end
end
function Widget:Show()
  local was = self.shown
  self.shown = true
  if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Widget:Hide()
  local was = self.shown
  self.shown = false
  if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Widget:SetShown(s) if s then self:Show() else self:Hide() end end
function Widget:IsShown() return self.shown end
function Widget:IsVisible() return self.shown end
function Widget:SetText(t) self.text = tostring(t) end
function Widget:GetText() return self.text end
function Widget:SetSize(w, h) self.w, self.h = w, h end
function Widget:SetWidth(w) self.w = w end
function Widget:SetHeight(h) self.h = h end
-- A frame sized only by its anchors reports a plausible size.
function Widget:GetWidth() return self.w > 0 and self.w or 800 end
function Widget:GetHeight() return self.h > 0 and self.h or 600 end
function Widget:GetEffectiveScale() return 1 end
function Widget:SetChecked(c) self.checked = c end
function Widget:GetChecked() return self.checked end
function Widget:HasFocus() return self.focus or false end
function Widget:SetEnabled(e) self.enabled = e end
function Widget:IsEnabled() return self.enabled ~= false end
-- Recorded so a test can inspect or draw the layout (see wow.frames).
function Widget:SetPoint(...) self.point = { ... } end
function Widget:ClearAllPoints() self.point = nil end
function Widget:GetPoint() if self.point then return unpack(self.point) end end
function Widget:SetStartPoint(...) self.startPoint = { ... } end
function Widget:SetEndPoint(...) self.endPoint = { ... } end
local function Child(kind)
  return function(self)
    local c = NewWidget(kind)
    self.children = self.children or {}
    self.children[#self.children + 1] = c
    return c
  end
end
Widget.CreateTexture = Child("Texture")
Widget.CreateFontString = Child("FontString")
Widget.CreateLine = Child("Line")
function Widget:RegisterEvent(event) self.events[event] = true end
function Widget:UnregisterEvent(event) self.events[event] = nil end
function Widget.StartMoving() end
function Widget.StopMovingOrSizing() end

function CreateFrame(kind, name, parent, template)
  local f = NewWidget(kind)
  f.template, f.parent = template, parent
  wow.frames[#wow.frames + 1] = f
  if name then _G[name] = f end
  return f
end

UIParent = NewWidget("Frame")
UIParent.w, UIParent.h = 1365, 768
GameTooltip = NewWidget("GameTooltip")
UISpecialFrames = {}
SlashCmdList = {}
DEFAULT_CHAT_FRAME = {
  AddMessage = function(_, msg)
    if wow.quiet then return end
    print("  [chat] " .. (tostring(msg):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|[AT].-|[at]", "")))
  end,
}

------------------------------------------------------------------------------
-- A few game functions with harmless defaults. Replace any of them.
------------------------------------------------------------------------------
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function hooksecurefunc() end
function IsAltKeyDown() return false end
function IsShiftKeyDown() return false end
function IsControlKeyDown() return false end
function IsMouseButtonDown() return false end
function InCombatLockdown() return false end
function GetCursorPosition() return 0, 0 end
function GetRealmName() return "TestRealm" end
function UnitName() return "Tester" end
function UnitFactionGroup() return "Alliance" end
function GetMoney() return 1000000 end
function ReloadUI() wow.reloaded = true end
Enum = setmetatable({}, { __index = function(t, k) local e = {} rawset(t, k, e) return e end })

local timers = {}
C_Timer = {
  After = function(_, fn) timers[#timers + 1] = fn end,
  NewTicker = function(_, fn)
    local t = { fn = fn }
    function t:Cancel() self.cancelled = true end
    return t
  end,
  NewTimer = function(_, fn)
    local t = { fn = fn }
    function t:Cancel() self.cancelled = true end
    timers[#timers + 1] = function() if not t.cancelled then fn() end end
    return t
  end,
}

-- Runs every pending C_Timer.After callback, including ones they schedule.
function wow.runTimers()
  local guard = 0
  while #timers > 0 and guard < 1000000 do
    guard = guard + 1
    table.remove(timers, 1)()
  end
end

------------------------------------------------------------------------------
-- Loading and driving the addon
------------------------------------------------------------------------------
-- Runs every .lua file the TOC lists, in order, passing (addonName, ns) the
-- way the game does. Returns ns. XML files are skipped.
function wow.load(tocPath, addonName)
  addonName = addonName or tocPath:match("([^/\\]+)%.toc$")
  local dir = tocPath:match("^(.*)[/\\][^/\\]+$")
  local ns = {}
  for line in io.lines(tocPath) do
    line = line:gsub("\r", ""):gsub("%s+$", "")
    -- Drop a trailing load condition such as [AllowLoadGameType classic].
    line = line:gsub("%s*%[.-%]%s*$", "")
    if line:match("%.lua$") and not line:match("^#") then
      local file = line:gsub("\\", "/")
      if dir then file = dir .. "/" .. file end
      local chunk, err = loadfile(file)
      if not chunk then error(err) end
      chunk(addonName, ns)
    end
  end
  wow.addonName, wow.ns = addonName, ns
  return ns
end

-- Sends a game event to every frame that registered for it.
function wow.fire(event, ...)
  for _, f in ipairs(wow.frames) do
    if f.events[event] and f.scripts.OnEvent then
      f.scripts.OnEvent(f, event, ...)
    end
  end
end

function wow.check(cond, what)
  wow.checks = wow.checks + 1
  if not cond then
    wow.failures = wow.failures + 1
    print("FAIL: " .. tostring(what))
  end
  return cond
end

function wow.near(a, b, tol)
  return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tol or 1e-6)
end

-- Names of widget methods the addon called that this mock does not model.
function wow.unmodelled()
  local names = {}
  for k in pairs(unmodelled) do names[#names + 1] = k end
  table.sort(names)
  return names
end

function wow.finish()
  local names = wow.unmodelled()
  print("widget methods used but not modelled (" .. #names .. "): " .. table.concat(names, " "))
  print(string.format("%d checks, %d failed", wow.checks, wow.failures))
  os.exit(wow.failures == 0 and 0 or 1)
end

return wow
