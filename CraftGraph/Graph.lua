-- CraftGraph graph model: which items to show around the chosen one and
-- where to put them. Components run to the right (down to base resources),
-- things made from the item run to the left. An item appears once, so
-- recipes that share ingredients join up into one connected graph.
local ADDON, ns = ...
local G = {}
ns.Graph = G

G.COLW, G.ROWH = 424, 96
G.NODE_W, G.NODE_H = 304, 86

local MAX_RIGHT_DEPTH = 6
local MAX_RIGHT_NODES = 60
local LEFT_CAP, LEFT_CAP_EXPANDED = 9, 40
local LEFT2_CAP, LEFT2_CAP_EXPANDED = 8, 24

local function ProfitScore(id)
  local e = ns.Opt.Evaluate(id, 1)
  return e.profit
end

local function RankByProfit(list)
  local score = {}
  for _, c in ipairs(list) do score[c.id] = ProfitScore(c.id) end
  table.sort(list, function(a, b)
    local sa, sb = score[a.id], score[b.id]
    if sa and sb then
      if sa ~= sb then return sa > sb end
    elseif sa or sb then
      return sa ~= nil
    end
    return ns.ItemName(a.id) < ns.ItemName(b.id)
  end)
end

-- opts.expandLeft: show the long list of things made from the item.
-- opts.plan: plan for the centre item, used to mark the chosen route.
function G.Build(center, opts)
  opts = opts or {}
  local recipes = ns.Data.recipes
  local nodes, byId, edges = {}, {}, {}

  local function AddNode(id, side, layer)
    local n = { id = id, side = side, layer = layer }
    nodes[#nodes + 1] = n
    byId[id] = n
    return n
  end

  AddNode(center, 0, 0)

  -- Right: components, breadth first.
  local order, qi = { center }, 1
  while qi <= #order do
    local id = order[qi]
    qi = qi + 1
    local n = byId[id]
    if n.layer < MAX_RIGHT_DEPTH and #nodes < MAX_RIGHT_NODES then
      local spell = ns.Opt.BestRecipe(id)
      if spell then
        n.recipe = spell
        local reagents = recipes[spell][7]
        for i = 1, #reagents, 2 do
          local rid, qty = reagents[i], reagents[i + 1]
          local child = byId[rid]
          if not child then
            child = AddNode(rid, 1, n.layer + 1)
            order[#order + 1] = rid
          end
          if child.side == 1 then
            edges[#edges + 1] = { from = id, to = rid, qty = qty, spell = spell }
          end
        end
      end
    end
  end

  -- Push each component as far right as its longest chain needs.
  for _ = 1, MAX_RIGHT_DEPTH do
    local changed = false
    for _, e in ipairs(edges) do
      local a, b = byId[e.from], byId[e.to]
      if b.side == 1 and b.layer < a.layer + 1 and a.layer < MAX_RIGHT_DEPTH then
        b.layer = a.layer + 1
        changed = true
      end
    end
    if not changed then break end
  end
  for i = #edges, 1, -1 do
    local e = edges[i]
    if byId[e.to].layer <= byId[e.from].layer then table.remove(edges, i) end
  end

  -- Left: things made from the item, best profit first.
  local function Dependents(id)
    local out, seen = {}, {}
    for _, spell in ipairs(ns.Opt.uses[id] or {}) do
      local r = recipes[spell]
      local product = r[3]
      if not byId[product] and not seen[product] then
        seen[product] = true
        local qty = 0
        for i = 1, #r[7], 2 do
          if r[7][i] == id then qty = r[7][i + 1] end
        end
        out[#out + 1] = { id = product, spell = spell, qty = qty, parent = id }
      end
    end
    return out
  end

  local function AddLeft(cands, layer, cap)
    RankByProfit(cands)
    local shown = 0
    for _, c in ipairs(cands) do
      if shown >= cap then break end
      if not byId[c.id] then
        local n = AddNode(c.id, -1, layer)
        n.recipe = c.spell
        edges[#edges + 1] = { from = c.id, to = c.parent, qty = c.qty, spell = c.spell, left = true }
        shown = shown + 1
      end
    end
    return #cands - shown
  end

  local level1 = Dependents(center)
  local hidden = AddLeft(level1, 1, opts.expandLeft and LEFT_CAP_EXPANDED or LEFT_CAP)
  local level2 = {}
  for _, n in ipairs(nodes) do
    if n.side == -1 and n.layer == 1 then
      for _, c in ipairs(Dependents(n.id)) do level2[#level2 + 1] = c end
    end
  end
  -- The same product can hang off several parents; keep its first.
  local uniq, seen2 = {}, {}
  for _, c in ipairs(level2) do
    if not seen2[c.id] then
      seen2[c.id] = true
      uniq[#uniq + 1] = c
    end
  end
  local hidden2 = AddLeft(uniq, 2, opts.expandLeft and LEFT2_CAP_EXPANDED or LEFT2_CAP)
  if hidden > 0 or (opts.expandLeft and #level1 > LEFT_CAP) then
    local n = { more = hidden, side = -1, layer = 1, expanded = opts.expandLeft }
    nodes[#nodes + 1] = n
  end
  G.hiddenSecond = hidden2

  -- Cross links: other shown items that a shown recipe also needs.
  local have = {}
  for _, e in ipairs(edges) do have[e.from .. ">" .. e.to] = true end
  for _, n in ipairs(nodes) do
    if n.side == -1 and n.recipe then
      local reagents = recipes[n.recipe][7]
      for i = 1, #reagents, 2 do
        local rid = reagents[i]
        if byId[rid] and not have[n.id .. ">" .. rid] then
          have[n.id .. ">" .. rid] = true
          edges[#edges + 1] = { from = n.id, to = rid, qty = reagents[i + 1], spell = n.recipe,
            left = true, cross = true }
        end
      end
    end
  end

  -- Mark the route the plan actually takes.
  local plan = opts.plan
  if plan then
    for _, e in ipairs(edges) do
      if not e.left and plan.casts[e.spell] then e.chosen = true end
    end
    for _, n in ipairs(nodes) do
      if n.id and n.side == 1 then
        n.bought = plan.buy[n.id]
        n.vended = plan.vend[n.id]
      end
    end
  end

  G.Layout(nodes, edges, byId)
  return { nodes = nodes, edges = edges, byId = byId, center = center }
end

function G.Layout(nodes, edges, byId)
  -- Columns are numbered outward from the centre with no gaps, even when a
  -- chain skips a level.
  local used = {}
  for _, n in ipairs(nodes) do used[n.side * n.layer] = true end
  local keys = {}
  for col in pairs(used) do keys[#keys + 1] = col end
  table.sort(keys)
  local renumber, right, left = { [0] = 0 }, 0, 0
  for _, col in ipairs(keys) do
    if col > 0 then
      right = right + 1
      renumber[col] = right
    end
  end
  for i = #keys, 1, -1 do
    if keys[i] < 0 then
      left = left - 1
      renumber[keys[i]] = left
    end
  end
  local cols = {}
  for i, n in ipairs(nodes) do
    n.col = renumber[n.side * n.layer] or 0
    n.seq = i
    cols[n.col] = cols[n.col] or {}
    table.insert(cols[n.col], n)
  end

  local function Place(col)
    local list = cols[col]
    for i, n in ipairs(list) do
      n.row = i
      n.y = -(i - (#list + 1) / 2) * G.ROWH
      n.x = col * G.COLW
    end
  end
  Place(0)

  -- Order each column by where its neighbours in the inner column sit, so
  -- lines cross as little as possible.
  local function Sweep(col, inner)
    local list = cols[col]
    if not list then return false end
    for _, n in ipairs(list) do
      local sum, count = 0, 0
      if n.id then
        for _, e in ipairs(edges) do
          local other
          if e.from == n.id then other = byId[e.to] elseif e.to == n.id then other = byId[e.from] end
          if other and other.col == inner and other.y then
            sum = sum + other.y
            count = count + 1
          end
        end
      end
      n.bary = count > 0 and (sum / count) or nil
    end
    table.sort(list, function(a, b)
      if a.more or b.more then return b.more ~= nil and a.more == nil end
      if a.bary and b.bary and a.bary ~= b.bary then return a.bary > b.bary end
      if (a.bary ~= nil) ~= (b.bary ~= nil) then return a.bary ~= nil end
      return a.seq < b.seq
    end)
    Place(col)
    return true
  end

  local c = 1
  while Sweep(c, c - 1) do c = c + 1 end
  c = -1
  while Sweep(c, c + 1) do c = c - 1 end
end
