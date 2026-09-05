-- Pull budget: "how many more pulls before I drink?"
--
-- In 5-man content the fight is 17-45s and the DECISION happens between
-- pulls. The OOM clock has, rightly, nothing to say there (it projects a
-- horizon far longer than any pull), and the potion advisor answers "is this
-- potion efficient?" when the question being asked is "can I pull again?" --
-- all four potion alerts in the first dungeon log went unanswered.
--
-- So: from the persisted fight history, the median mana a pull costs HERE
-- (same zone, at least two fights; otherwise recent fights anywhere), and how
-- many of those the current pool affords, now and after a drink. Shown in the
-- mana tooltip out of combat and as the drink reminder's text. It sits beside
-- the clock, not instead of it.
local _, MD = ...

local PB = {}
MD.PullBudget = PB

local RECENT = 5

local function Median(t)
    if #t == 0 then return nil end
    table.sort(t)
    local mid = math.ceil(#t / 2)
    return t[mid]
end

-- { perPull, afford, afterDrink, source = <zone name | "recent fights">, n }
-- or nil with fewer than two recorded fights.
function PB:Estimate()
    local hist = MD.fightHistory
    if not hist or #hist < 2 then return nil end

    local zone = GetRealZoneText and GetRealZoneText() or nil
    local pool, source = (MD.FightsInZone and MD:FightsInZone(zone, RECENT)) or {}, zone
    if #pool < 2 then
        pool, source = {}, "recent fights"
        for i = math.max(1, #hist - RECENT + 1), #hist do pool[#pool + 1] = hist[i] end
    end

    local spent = {}
    for _, f in ipairs(pool) do
        local s = (f.avgSpendRate or 0) * (f.duration or 0)
        if s > 0 then spent[#spent + 1] = s end
    end
    local perPull = Median(spent)
    if not perPull or perPull <= 0 then return nil end

    local mana, manaMax = UnitPower("player", 0) or 0, UnitPowerMax("player", 0) or 0
    return {
        perPull = perPull,
        afford = math.floor(mana / perPull),
        afterDrink = math.floor(manaMax / perPull),
        source = source or "recent fights",
        n = #spent,
        pct = manaMax > 0 and mana / manaMax or 1,
    }
end

local function K(n) return n >= 1000 and string.format("%.1fk", n / 1000) or string.format("%d", n) end

-- One sentence, ASCII only, no bare "|":
--   62% -- recent pulls here cost ~2.3k -- 2 more, or 4 after a drink.
function PB:Line()
    local e = PB:Estimate()
    if not e then return nil end
    local where = e.source == "recent fights" and "recent pulls" or "recent pulls here"
    return string.format("%d%% -- %s cost ~%s -- %d more, or %d after a drink.",
        e.pct * 100 + 0.5, where, K(e.perPull), e.afford, e.afterDrink)
end

-- Tooltip lines (out of combat only; in combat the clock is the readout).
function PB:Lines()
    local e = PB:Estimate()
    if not e or UnitAffectingCombat("player") then return {} end
    return {
        {},
        { l = "Pull budget", r = string.format("%d more, %d after a drink", e.afford, e.afterDrink),
          c = { 0.78, 0.78, 0.78 } },
        { l = string.format("  a pull %s costs ~%s (median of %d)",
            e.source == "recent fights" and "recently" or ("in " .. e.source), K(e.perPull), e.n),
          c = { 0.63, 0.63, 0.63 } },
    }
end
