-- Packs item records into the strings of Data/Base.lua. Development only:
-- used by tools/make_base.lua and the offline tests. The game only unpacks,
-- and the reader is Market.lua (M.BaseRecord); the two must agree.
--
-- One string per item, made of numbers written in a 64-letter alphabet:
-- each letter carries five bits, low bits first; the first 32 letters end
-- a number, the other 32 say that more of it follows. Signed numbers are
-- folded (0, -1, 1, -2, ... become 0, 1, 2, 3, ...). Small numbers, which
-- is most of them once each value is written as a step from the one
-- before, take one letter.
--
-- Prices are kept on a log scale in steps of 0.2% (exact below about
-- 5 silver, within a tenth of a percent above), times in steps of five
-- minutes from the base data's start.
--
-- An item, in order:
--   flags     1 the ladder is a summary (only cheapest and total known)
--             2 a selling-rate belief follows   4 stack sizes follow
--             8 a ladder follows
--   points    how many, then for each: minutes since the one before (in
--             steps of five), units listed (step from the one before) and,
--             when any were listed, the price (step from the last price)
--             and how far the sturdier price sits above it
--   ladder    when it was seen, how many levels, the first price and units,
--             then each level's rise in price and units, then units listed
--             beyond the ladder
--   stacks    how many, then size and weight (in tenths) of each
--   sales     units judged sold (tenths), auctions (tenths), days watched
--             (ten-thousandths), share that went between scans (hundredths)
local P = {}

P.ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
P.STEP = math.log(1.002)
P.SLOT = 300

local floor, max, log = math.floor, math.max, math.log
local letters = {}
for i = 1, 64 do letters[i - 1] = P.ALPHABET:sub(i, i) end

local function Uint(out, v)
  v = floor(v + 0.5)
  if v < 0 then error("negative number in an unsigned field: " .. v) end
  while v >= 32 do
    out[#out + 1] = letters[32 + v % 32]
    v = floor(v / 32)
  end
  out[#out + 1] = letters[v]
end
P.Uint = Uint

local function Int(out, v)
  v = floor(v + 0.5)
  Uint(out, v >= 0 and 2 * v or -2 * v - 1)
end
P.Int = Int

function P.Q(price)
  return floor(log(price) / P.STEP + 0.5)
end

local function Slot(t, t0)
  return floor((t - t0) / P.SLOT + 0.5)
end

-- rec: { h = flat history {time, cheapest, sturdier, units, ...} oldest
-- first, l = ladder {price, units, ...}, lt, ln, ls, bs = {size, weight, ...},
-- sa, sc, sb, sf }. t0: the base data's start (a multiple of P.SLOT).
function P.Item(rec, t0)
  local out = {}
  local h, l = rec.h or {}, rec.l
  local hasLadder = l and l[1] and rec.lt and true or false
  local hasSales = rec.sb and rec.sb > 0 and true or false
  local hasStacks = rec.bs and rec.bs[1] and true or false
  Uint(out, (rec.ls and 1 or 0) + (hasSales and 2 or 0) + (hasStacks and 4 or 0) + (hasLadder and 8 or 0))

  Uint(out, #h / 4)
  local slot, units, q = 0, 0, 0
  for i = 1, #h, 4 do
    local s = max(Slot(h[i], t0), slot)       -- never a step back in time
    Uint(out, s - slot)
    slot = s
    local u = h[i + 1] > 0 and max(1, floor(h[i + 3] + 0.5)) or 0
    Int(out, u - units)
    units = u
    if u > 0 then
      local pq = P.Q(h[i + 1])
      Int(out, pq - q)
      q = pq
      Uint(out, max(0, P.Q(max(h[i + 2], h[i + 1])) - pq))
    end
  end

  if hasLadder then
    Uint(out, max(0, Slot(rec.lt, t0)))
    -- Levels that land on the same step of the scale become one.
    local levels = {}
    for i = 1, #l, 2 do
      local lq = P.Q(l[i])
      local n = #levels
      if n > 0 and levels[n - 1] >= lq then
        levels[n] = levels[n] + l[i + 1]
      else
        levels[n + 1], levels[n + 2] = lq, l[i + 1]
      end
    end
    Uint(out, #levels / 2)
    local prev, sum = 0, 0
    for i = 1, #levels, 2 do
      Uint(out, levels[i] - prev)
      Uint(out, levels[i + 1])
      prev, sum = levels[i], sum + levels[i + 1]
    end
    Uint(out, max(0, (rec.ln or sum) - sum))
  end

  if hasStacks then
    Uint(out, #rec.bs / 2)
    for i = 1, #rec.bs, 2 do
      Uint(out, rec.bs[i])
      Uint(out, rec.bs[i + 1] * 10)
    end
  end

  if hasSales then
    Uint(out, (rec.sa or 0) * 10)
    Uint(out, (rec.sc or 0) * 10)
    Uint(out, rec.sb * 10000)
    Uint(out, (rec.sf or 0) * 100)
  end
  return table.concat(out)
end

return P
