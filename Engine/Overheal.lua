-- Measured overheal, per spell family and per rank, from the combat log.
-- UI/Summary.lua's single COMBAT_LOG handler feeds Record(); RankMath asks
-- Fraction() so the dashboard can show "effective" heal / HPM / HPS / HP5 --
-- what the spell is actually worth on the targets this player heals, rather
-- than on a dummy at 1 hp.
--
-- Weighting is by AMOUNT, not by event, so a four-tick Rejuvenation and a
-- Healing Touch contribute in proportion to the healing they really did. The
-- weight decays per event with a half-life of HALF_EVENTS, so a changed spec,
-- raid slot or gear level washes out on its own.
--
-- Known bias, surfaced in the tooltip rather than hidden: until a rank has
-- MIN_EVENTS of its own it borrows the family's fraction, which UNDERSTATES
-- the case for downranking (a smaller heal overheals less). A family-scope
-- fraction also scales every rank of that family by the same factor, so it can
-- never reorder them -- which is why the Pareto filter and the suggested rank
-- deliberately stay on raw values (docs/DESIGN-v0.5.md F3).
local _, MD = ...

local OH = {}
MD.Overheal = OH

local HALF_EVENTS = 150
local DECAY = 0.5 ^ (1 / HALF_EVENTS)
local MIN_EVENTS = 40

-- Bound to MD.cdb.overheal at MD_READY: play style and content, so per
-- character, and it survives a /reload by living in SavedVariables directly.
OH.stats = nil

--------------------------------------------------------------------------------
-- Which convention does this client use for SPELL_HEAL's "amount"?
--
-- It is documented both ways across client versions: GROSS (the full heal, of
-- which "overhealing" was wasted) or NET (the part that landed, with
-- "overhealing" on top). A full overheal is the discriminator -- gross reports
-- amount == overheal, net reports amount == 0 -- so the first unambiguous
-- sample latches it and everything downstream is right from then on. Until
-- then NET is assumed, which is what the fight summary already did, so nothing
-- changes on its own.
--------------------------------------------------------------------------------
local function LatchConvention(amount, overheal)
    if overheal <= 0 or MD.db == nil or MD.db.healAmountGross ~= nil then return end
    local gross
    if amount == 0 then
        gross = false
    elseif amount == overheal then
        gross = true
    else
        return -- a partial overheal says nothing
    end
    MD.db.healAmountGross = gross
    MD:Debug("heal", "combat log convention latched: SPELL_HEAL amount is %s overheal "
        .. "(sample amount %d, overheal %d)", gross and "GROSS, including" or "NET, excluding",
        amount, overheal)
end

-- Returns effective (landed) and gross (attempted) healing for one event,
-- under whichever convention is in force.
function OH:Split(amount, overheal)
    amount, overheal = amount or 0, overheal or 0
    if MD.db and MD.db.healAmountGross then
        return math.max(0, amount - overheal), amount
    end
    return amount, amount + overheal
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------
local function Bump(key, effective, over)
    local st = OH.stats[key]
    if not st then
        st = { h = 0, o = 0, n = 0 }
        OH.stats[key] = st
    end
    st.h = st.h * DECAY + effective
    st.o = st.o * DECAY + over
    st.n = math.min(st.n + 1, 100000)
end

-- Called for every SPELL_HEAL / SPELL_PERIODIC_HEAL the player lands, in and
-- out of combat: rolling Lifebloom on a tank between pulls is exactly the sort
-- of casting whose overheal belongs in the average.
function OH:Record(spellID, amount, overheal)
    if not OH.stats or not spellID then return end
    LatchConvention(amount or 0, overheal or 0)
    local effective, gross = OH:Split(amount, overheal)
    if gross <= 0 then return end
    local over = gross - effective

    Bump("s:" .. spellID, effective, over)
    local s = MD.SpellData and MD.SpellData.spells[spellID]
    if s then Bump("f:" .. s.family, effective, over) end
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------
local function FractionOf(key)
    local st = OH.stats and OH.stats[key]
    if not st or st.n < MIN_EVENTS then return nil end
    local total = st.h + st.o
    if total <= 0 then return nil end
    return st.o / total, st.n
end

-- Returns fraction (0..1), sample count, scope ("rank" | "family"), or nil
-- when neither scope has enough data yet.
function OH:Fraction(spellID)
    local frac, n = FractionOf("s:" .. spellID)
    if frac then return frac, n, "rank" end

    local s = MD.SpellData and MD.SpellData.spells[spellID]
    if s then
        frac, n = FractionOf("f:" .. s.family)
        if frac then return frac, n, "family" end
    end
    return nil
end

-- Per-family summary for the dashboard's callout line.
function OH:FamilyFraction(family)
    return FractionOf("f:" .. family)
end

function OH:Reset()
    if not OH.stats then return end
    wipe(OH.stats)
    MD:Print("overheal data cleared.")
end

-- Plain lines for /md profile and the debug log.
function OH:Summary()
    local out = {}
    if not OH.stats then return out end
    local keys = {}
    for k in pairs(OH.stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local st = OH.stats[k]
        local total = st.h + st.o
        local label = k
        if k:sub(1, 2) == "s:" then
            local id = tonumber(k:sub(3))
            label = (GetSpellInfo(id) or "?") .. " (" .. tostring(id) .. ")"
        else
            label = k:sub(3)
        end
        out[#out + 1] = string.format("%s: overheal %.0f%% over %d events%s",
            label, total > 0 and st.o / total * 100 or 0, st.n,
            st.n < MIN_EVENTS and string.format(" (needs %d)", MIN_EVENTS) or "")
    end
    return out
end

MD:RegisterCallback("MD_READY", function()
    MD.cdb.overheal = MD.cdb.overheal or {}
    OH.stats = MD.cdb.overheal
end)
