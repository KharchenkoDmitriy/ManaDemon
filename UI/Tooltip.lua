-- The one tooltip line builder. Every hover surface in the addon (both ElvUI
-- datatexts, the minimap button, the floating widget, the dashboard's rows and
-- recap line) renders lines produced here, so they can never drift apart.
--
-- A line is a plain table:
--   { l = "left", r = "right", c = {r,g,b}, rc = {r,g,b}, wrap = bool }
-- l alone -> AddLine, l+r -> AddDoubleLine, {} -> a blank spacer. Both
-- GameTooltip and ElvUI's DT.tooltip take exactly those two calls, which is why
-- the pair is the abstraction.
--
-- ASCII only in every string here (default WoW fonts lack arrow/infinity
-- glyphs) and never a bare "|" (it opens a colour escape).
local _, MD = ...
local UI = MD.UI

local Tip = {}
MD.Tip = Tip

local WHITE  = { 1, 1, 1 }
local KEY    = { 0.78, 0.78, 0.78 }
local SUB    = { 0.63, 0.63, 0.63 }
local MUTED  = { 0.43, 0.43, 0.43 }
local WARN   = { 1, 0.67, 0.2 }
local GOLD   = { 1, 0.82, 0 }
local GOOD   = { 0.2, 1, 0.4 }
local MANA   = { 0.31, 0.66, 0.94 }

local function Accent()
    return { UI.accent[1], UI.accent[2], UI.accent[3] }
end

local function Plain(str)
    return (tostring(str):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------
-- Pushes lines into any tooltip object exposing AddLine / AddDoubleLine.
function Tip:Render(tt, lines)
    if not tt or not lines then return end
    for i = 1, #lines do
        local ln = lines[i]
        if ln.l == nil and ln.r == nil then
            tt:AddLine(" ")
        elseif ln.r ~= nil then
            local c = ln.c or WHITE
            local rc = ln.rc or ln.c or WHITE
            tt:AddDoubleLine(ln.l or "", ln.r, c[1], c[2], c[3], rc[1], rc[2], rc[3])
        else
            local c = ln.c or WHITE
            tt:AddLine(ln.l, c[1], c[2], c[3], ln.wrap)
        end
    end
end

-- Convenience for plain GameTooltip owners: Tip:Show(frame, "ANCHOR_LEFT", lines)
function Tip:Show(owner, anchor, ...)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    for i = 1, select("#", ...) do
        Tip:Render(GameTooltip, (select(i, ...)))
    end
    GameTooltip:Show()
end

-- Same, but pinned to a frame instead of following the owner: the dashboard's
-- rows are narrow and centred, so ANCHOR_RIGHT would run off the screen edge.
function Tip:ShowAt(owner, point, relFrame, relPoint, x, y, ...)
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint(point, relFrame, relPoint, x, y)
    GameTooltip:ClearLines()
    for i = 1, select("#", ...) do
        Tip:Render(GameTooltip, (select(i, ...)))
    end
    GameTooltip:Show()
end

function Tip:Hide()
    GameTooltip:Hide()
end

--------------------------------------------------------------------------------
-- Mana state: the clock, what it is made of, and why it says what it says.
--------------------------------------------------------------------------------
function Tip:Mana()
    local lines = {}
    local s = MD.GetManaState and MD:GetManaState()
    if not s then return lines end
    local RM = MD.Regen
    local spiritPerSec, mp5Gear, _, unreported = RM:Components()

    if s.tto then
        lines[#lines + 1] = { l = "Time to OOM (raw)",
            r = string.format("%ds +- %ds", s.tto, s.sigmaT or 0) }
    elseif s.ttf then
        lines[#lines + 1] = { l = "Time to full (raw)", r = string.format("%ds", s.ttf) }
    elseif s.mode == "hold" then
        lines[#lines + 1] = { l = "Net rate within noise",
            r = s.bound and string.format("OOM no sooner than %ds", s.bound) or "sustainable" }
    end
    if s.inCombat and s.rest then
        lines[#lines + 1] = { l = "Full if you stop casting", r = string.format("%ds", s.rest) }
    end
    lines[#lines + 1] = { l = "Net rate (pessimistic)", r = string.format("%+d mana/s", -s.net) }
    lines[#lines + 1] = { l = "Spending",
        r = string.format("%d +- %d mana/s (%d casts, CV %.2f)", s.spend, s.sigma, s.casts, s.cv) }
    lines[#lines + 1] = { l = "Regen now / projected",
        r = string.format("%d / %d mana/s  (5SR %d%% of time)", s.regenNow, s.regen, s.duty * 100) }
    lines[#lines + 1] = { l = "Regen out of 5SR / casting",
        r = string.format("%d / %d mana/s", RM.base, RM.casting) }
    lines[#lines + 1] = { l = "Spirit / gear mp5",
        r = string.format("~%d / ~%d", spiritPerSec * 5, mp5Gear) }
    if unreported > 0 then
        lines[#lines + 1] = { l = "Dreamstate mp5 (added, not in the API)",
            r = string.format("%d", unreported * 5 + 0.5) }
    end
    if RM:InFSR() then
        lines[#lines + 1] = { l = "Spirit regen resumes",
            r = string.format("%.1fs", RM:FSRRemaining()), c = WARN, rc = WHITE }
    end

    -- What each mana source is worth right now, and what it buys on the clock.
    if MD.ManaCooldowns then
        local sources = MD.ManaCooldowns:All()
        if #sources > 0 then
            lines[#lines + 1] = {}
            for _, src in ipairs(sources) do
                local right
                if not src.ready then
                    right = string.format("%d mana, ready in %ds", src.delta, src.cdRemaining)
                elseif s.cd and s.cd.key == src.key and s.cd.tto then
                    right = string.format("%d mana -> OOM %ds", src.delta, s.cd.tto)
                else
                    right = string.format("%d mana, ready", src.delta)
                end
                lines[#lines + 1] = { l = src.name, r = right, c = KEY,
                    rc = src.ready and MANA or MUTED }
            end
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- Recent fights.
--------------------------------------------------------------------------------
function Tip:Fights(n)
    local lines = {}
    local hist = MD.fightHistory
    if not hist or #hist == 0 then return lines end
    n = math.min(n or 1, #hist)
    lines[#lines + 1] = {}
    if n == 1 then
        lines[#lines + 1] = { l = "Last fight: " .. Plain(hist[#hist].summary or "-"), c = SUB, wrap = true }
    else
        lines[#lines + 1] = { l = string.format("Last %d fights", n), c = Accent() }
        for i = #hist - n + 1, #hist do
            lines[#lines + 1] = { l = Plain(hist[i].summary or "-"), c = SUB, wrap = true }
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- Dashboard row: every term behind the numbers in the table, from row.calc
-- (RankMath:Explain). Nothing is modelled here that the row did not already
-- compute -- this is a view of RankMath, not a second opinion.
--------------------------------------------------------------------------------
local function Num(v, dec)
    return string.format(dec and ("%." .. dec .. "f") or "%d", v)
end

function Tip:Row(row)
    local lines = {}
    if not row then return lines end
    local c = row.calc
    if not c then return lines end

    local rankText = row.rankLabel and (c.label .. " (rolling " .. row.rankLabel .. ")")
        or string.format("%s (Rank %d)", c.label, row.rank)
    local note = row.suggested and "efficient rank" or row.isMax and "max rank"
        or row.dominated and "dominated" or (not row.known) and "not learned" or nil
    lines[#lines + 1] = { l = rankText, r = note,
        rc = row.suggested and GOLD or MUTED }
    lines[#lines + 1] = {}

    -- heal breakdown
    local healSuffix = ""
    if c.duration then
        healSuffix = string.format("  over %ds", c.duration)
        if c.ticks then healSuffix = healSuffix .. string.format(" (%d ticks)", c.ticks) end
    end
    lines[#lines + 1] = { l = "Heal", r = Num(row.heal) .. healSuffix, c = KEY }

    if c.kind == "lifebloom" then
        lines[#lines + 1] = { l = "  tick", r = Num(c.tick) .. " x7", c = SUB, rc = SUB }
        if not c.stacks then
            lines[#lines + 1] = { l = "  bloom", r = Num(c.bloom), c = SUB, rc = SUB }
        end
        lines[#lines + 1] = { l = string.format("  +healing  %d x %.4f hot / %.4f bloom coef x %.2f pen x %.2f %s",
            c.bonus, c.hotCoef, c.bloomCoef, c.penalty, c.bonusMult, c.bonusMultName), c = SUB }
        if c.relicTick and c.relicTick > 0 then
            lines[#lines + 1] = { l = "  relic", r = string.format("+%d per tick", c.relicTick), c = SUB, rc = SUB }
        end
    else
        lines[#lines + 1] = { l = "  base", r = Num(c.base), c = SUB, rc = SUB }
        if c.relicFlat and c.relicFlat > 0 then
            local relic = MD.RankMath.info and MD.RankMath.info.relic
            lines[#lines + 1] = { l = "  relic  " .. (relic and relic.name or "idol"),
                r = "+" .. Num(c.relicFlat), c = SUB, rc = SUB }
        end
        if c.kind == "hybrid" then
            lines[#lines + 1] = { l = string.format("  +healing direct  %d x %.2f coef x %.2f downrank",
                c.bonus, c.directCoef, c.penalty), r = "+" .. Num(c.directBonus), c = SUB, rc = SUB }
            lines[#lines + 1] = { l = string.format("  +healing hot  %d x %.2f coef x %.2f downrank x %.2f %s",
                c.bonus, c.hotCoef, c.penalty, c.bonusMult, c.bonusMultName),
                r = "+" .. Num(c.hotBonus), c = SUB, rc = SUB }
            lines[#lines + 1] = { l = string.format("  direct %d + hot %d", c.direct, c.hot), c = SUB }
        else
            lines[#lines + 1] = { l = string.format("  +healing  %d x %.2f coef x %.2f downrank x %.2f %s",
                c.bonus, c.coef, c.penalty, c.bonusMult, c.bonusMultName),
                r = "+" .. Num(c.bonusOut), c = SUB, rc = SUB }
        end
    end
    lines[#lines + 1] = { l = string.format("  talents  x%.2f", c.talentMult), c = SUB }
    if c.critMult then
        lines[#lines + 1] = { l = string.format("  crit  %.1f%% x1.5", c.crit * 100),
            r = string.format("x%.3f", c.critMult), c = SUB, rc = SUB }
    end

    lines[#lines + 1] = {}
    lines[#lines + 1] = { l = "Mana", r = Num(c.cost) .. "  " .. (c.costSource or "?"), c = KEY }
    lines[#lines + 1] = { l = "Cast", r = Num(row.cast, 1) .. "s" .. (row.ng and "*" or "") ..
        (row.cast <= 1.5 and "  GCD" or ""), c = KEY }
    if row.ng then
        lines[#lines + 1] = { l = string.format("  %.1fs base, %.1fs after a crit, %.1f%% crit -> %.2fs average",
            c.castBase, math.max(c.castBase - c.naturesGrace, 1.5), (c.ngCrit or 0) * 100, c.castNG), c = SUB }
        lines[#lines + 1] = { l = "  * Nature's Grace, chain-casting this one spell; an instant cast " ..
            "in between eats the buff for nothing.", c = MUTED, wrap = true }
    end

    lines[#lines + 1] = {}
    lines[#lines + 1] = { l = "HPM   heal per mana", r = Num(row.hpm, 2), c = KEY }
    lines[#lines + 1] = { l = "HPS   heal per second of cast", r = Num(row.hps), c = KEY }
    if row.hp5 then
        lines[#lines + 1] = { l = "HP5   sustained at 0 mana",
            r = string.format("%d  (interval %.1fs)", row.hp5, c.sustainedInterval), c = KEY }
    else
        lines[#lines + 1] = { l = "HP5   sustained at 0 mana", r = "-  cannot sustain", c = KEY, rc = MUTED }
    end
    if row.casts == math.huge then
        lines[#lines + 1] = { l = "To OOM", r = "never: regen covers the cost", c = KEY, rc = GOOD }
    else
        lines[#lines + 1] = { l = "To OOM",
            r = string.format("%d casts from %d mana (net %d each)", row.casts, c.mana, c.netPerCast), c = KEY }
    end

    if row.overheal then
        local oh = row.overheal
        lines[#lines + 1] = {}
        lines[#lines + 1] = { l = "Overheal",
            r = string.format("%d%%  (%s, %d events)", oh.frac * 100,
                oh.scope == "rank" and "measured on this rank" or "family average", oh.n), c = KEY }
        lines[#lines + 1] = { l = "Effective",
            r = string.format("%d heal, %.2f HPM, %d HPS", row.effHeal, row.effHpm, row.effHps), c = KEY }
        if oh.scope == "family" then
            lines[#lines + 1] = { l = "  A family average is the same factor on every rank, so it " ..
                "cannot say whether downranking overheals less. That needs samples on this rank.",
                c = MUTED, wrap = true }
        end
    end

    if row.virtual then
        lines[#lines + 1] = {}
        lines[#lines + 1] = { l = "Rolling stack: refreshed before it expires, so each cast is paid " ..
            "for with 6 ticks at the stack multiplier and never a bloom.", c = MUTED, wrap = true }
    end
    return lines
end

--------------------------------------------------------------------------------
-- The widget / minimap composite: clock, state, last fight, click hints.
--------------------------------------------------------------------------------
function Tip:Clock(hints)
    local lines = { { l = "ManaDemon", c = Accent() } }
    local str = MD.GetDisplayString and MD:GetDisplayString() or ""
    if str ~= "" then
        lines[#lines + 1] = { l = Plain(str) }
    end
    lines[#lines + 1] = {}
    for _, ln in ipairs(Tip:Mana()) do lines[#lines + 1] = ln end
    for _, ln in ipairs(Tip:Fights(1)) do lines[#lines + 1] = ln end
    if hints then
        lines[#lines + 1] = {}
        for _, h in ipairs(hints) do
            lines[#lines + 1] = { l = h, c = MUTED }
        end
    end
    return lines
end
