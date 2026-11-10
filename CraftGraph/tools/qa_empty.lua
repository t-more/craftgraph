-- From the addon folder:  lua5.1 tools/qa_empty.lua
-- A brand-new install: no scans, no recipes read, no plan. Everything must open without error.
local wow = dofile("tools/wowmock.lua")
wow.quiet = true
C_Item = { GetItemInfoInstant = function(id) return id, "", "", "", 0, 7, 0 end, GetItemCount = function() return 0 end }
C_Texture = { GetAtlasInfo = function() return nil end }
local sent = 0
C_AuctionHouse = { ReplicateItems = function() sent = sent + 1 end, GetNumReplicateItems = function() return 0 end,
  IsThrottledMessageSystemReady = function() return true end, SendSearchQuery = function() end, MakeItemKey = function(id) return { itemID = id } end }
local ns = wow.load("CraftGraph.toc")
wow.fire("ADDON_LOADED", "CraftGraph")
wow.fire("PLAYER_LOGIN")
wow.runTimers()
wow.check(ns.settings.showGuesses == false, "guesses are hidden on a new install")
local slash = SlashCmdList.CRAFTGRAPH
local function errs() local n = 0 for _, l in ipairs(ns.db.log) do if l:find("ERROR") then n = n + 1 print(l:sub(1, 500)) end end return n end
slash("") wow.runTimers()
wow.check(errs() == 0, "/cg opens the empty window")
for _, cmd in ipairs({ "worth", "sell", "trends", "hud", "auto", "auto", "log", "Copper Bar", "no such item at all" }) do
  slash(cmd) wow.runTimers()
end
wow.check(errs() == 0, "every slash command runs on an empty install")
local worth, trends, side
for _, f in ipairs(wow.frames) do
  if f.filters and f.summary then worth = f end
  if f.options and f.facts then trends = f end
  if f.week and f.chartMode then side = f end
end
wow.check(worth and trends and side, "the views exist")
ns.UI.ShowWorth(true)
for key, b in pairs(worth.filters) do b.scripts.OnClick(b) end
ns.UI.ShowTrends(true)
for key, b in pairs(trends.options) do b.scripts.OnClick(b) end
for i = 1, 3 do side.chartMode.scripts.OnClick(side.chartMode) wow.runTimers() end
-- an item with no price at all, then one with a single scan
ns.UI.Focus(2840) wow.runTimers()
for i = 1, 3 do side.chartMode.scripts.OnClick(side.chartMode) wow.runTimers() end
side.week.Select(30)
ns.UI.ShowTrends(true)
for key, b in pairs(trends.options) do b.scripts.OnClick(b) end
wow.check(errs() == 0, "an item nobody scanned shows in every view")
ns.Market.Record(2840, { { 80, 20 } }, { full = true })
ns.Fire("MARKET_UPDATED") wow.runTimers()
for i = 1, 3 do side.chartMode.scripts.OnClick(side.chartMode) wow.runTimers() side.week.Select(100) end
for key, b in pairs(trends.options) do b.scripts.OnClick(b) end
wow.check(errs() == 0, "an item with one scan shows in every view")
wow.check(ns.Stats.Week(2840) ~= nil and ns.Stats.WeekAt(ns.Stats.Week(2840), 1, 14).price > 0, "one scan gives a week estimate")
-- plan it, track it, HUD
ns.Jobs.Pin(2840, 5, { kind = "flip", qty = 5, outlay = 400, sellEach = 100, profit = 75 })
wow.runTimers() ns.UI.UpdateHUD()
local p = ns.Jobs.Projection(2840, 5, ns.Jobs.Pins()[1].goal)
wow.check(p.now ~= nil and #p.rows >= 6, "a planned trade projects by sell time")
ns.Jobs.Clear() wow.runTimers()
-- auction house opens on an empty install: auto scan asks for one full scan, not more
ns.settings.autoScan = true
wow.fire("AUCTION_HOUSE_SHOW") wow.runTimers()
for i = 1, 5 do ns.Market.AutoTick() end
wow.check(sent == 1, "auto scan asks once for a full scan, not repeatedly (" .. sent .. ")")
wow.fire("AUCTION_HOUSE_CLOSED") wow.runTimers()
wow.check(errs() == 0, "no errors at the auction house")
wow.finish()
