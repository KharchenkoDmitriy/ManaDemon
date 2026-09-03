-- Big mana cooldowns and carried mana potions: one place that answers "how
-- much mana does this button actually give me right now, over and above what
-- the clock is already projecting?".
--
-- Before this file the advisor had its own rough Innervate estimate and the
-- clock knew nothing, so the two could show different numbers for the same
-- decision. Both read MC now.
--
-- Only the Druid entry has a value function; the other classes are Phase 2
-- stubs (docs/PLAN.md) and are skipped until someone of that class can log one
-- in-game. The potion table is class-generic and always active.
local _, MD = ...

local MC = {}
MD.ManaCooldowns = MC

local INNERVATE = 29166

--------------------------------------------------------------------------------
-- Value models. Every one returns the MARGINAL mana gained by using it now:
-- (boosted rate - the rate the clock already projects) * duration, minus its
-- own cost. Adding that to the pool therefore never double counts.
--------------------------------------------------------------------------------
-- Innervate (TBC): "increases mana regeneration by 400% and allows 100% of
-- mana regeneration to continue while casting" for 20s. The 400% multiplies
-- the SPIRIT share; flat gear/buff mp5 and Dreamstate are not spirit-based, so
-- they are added once, not five times. That split is assumed until the "regen"
-- debug lines around the buff confirm it in-game (docs/DESIGN-v0.5.md F2).
local function InnervateValue(entry)
    local RM = MD.Regen
    if not RM then return 0 end
    local spiritPerSec, mp5Gear, _, unreported = RM:Components()
    local boosted = 5 * spiritPerSec + mp5Gear / 5 + unreported
    local gain = (boosted - RM:Effective()) * entry.duration
    local cost = MD.SpellData and MD.SpellData:GetCost(INNERVATE) or 0
    return math.max(0, gain - (cost or 0))
end

--------------------------------------------------------------------------------
-- Sources
--------------------------------------------------------------------------------
MC.byClass = {
    DRUID = {
        { key = "innervate", short = "inn", id = INNERVATE, name = "Innervate",
          duration = 20, value = InnervateValue },
    },
    -- Phase 2: each needs a value model and one in-game log from that class.
    PRIEST  = { { key = "shadowfiend", short = "sf",  id = 34433, name = "Shadowfiend",         duration = 15 } },
    SHAMAN  = { { key = "manatide",    short = "mt",  id = 16190, name = "Mana Tide Totem",     duration = 12 } },
    PALADIN = { { key = "divineillum", short = "di",  id = 31842, name = "Divine Illumination", duration = 15 } },
}

-- itemID -> max restored mana (max roll, so an alert never fires early)
MC.potions = {
    { key = "pot22832", short = "pot", id = 22832, value = 3000, name = "Super Mana Potion" },
    { key = "pot13444", short = "pot", id = 13444, value = 2250, name = "Major Mana Potion" },
    { key = "pot13443", short = "pot", id = 13443, value = 1500, name = "Superior Mana Potion" },
    { key = "pot3827",  short = "pot", id = 3827,  value = 585,  name = "Mana Potion" },
}

--------------------------------------------------------------------------------
-- Readiness
--------------------------------------------------------------------------------
-- Seconds of cooldown left; 0 = ready, nil = the client would not say.
local function SpellCooldownRemaining(id)
    if not GetSpellCooldown then return nil end
    local ok, start, duration = pcall(GetSpellCooldown, id)
    if not ok or start == nil then return nil end
    if start == 0 then return 0 end
    return math.max(0, start + duration - GetTime())
end

local function SpellKnown(id)
    if IsSpellKnown then
        local ok, known = pcall(IsSpellKnown, id)
        if ok then return known end
    end
    return GetSpellInfo(id) ~= nil
end

local function ItemReady(itemID)
    if not GetItemCount or GetItemCount(itemID) == 0 then return false end
    local ok, start, duration
    if C_Container and C_Container.GetItemCooldown then
        ok, start, duration = pcall(C_Container.GetItemCooldown, itemID)
    elseif GetItemCooldown then
        ok, start, duration = pcall(GetItemCooldown, itemID)
    end
    if not ok then return true end -- can't read the cooldown: don't suppress
    return not start or start == 0 or (start + duration - GetTime()) <= 0
end

-- True while one of this class's cooldown buffs is running: the client already
-- reports the boosted regen then, so the clock must NOT add a second figure.
function MC:Active()
    local list = MC.byClass[MD.player.class]
    if not list then return false end
    for _, entry in ipairs(list) do
        if entry.value then
            local name = GetSpellInfo(entry.id)
            if name and MD:HasBuff(name) then return true end
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Every source this character could use, richest first. Entries:
--   key, name, short, kind ("spell" | "potion"), delta (marginal mana),
--   ready, cdRemaining
--------------------------------------------------------------------------------
-- Rebuilt at most once per master tick: the advisor and the clock both ask
-- every 0.5s, and each rebuild walks GetSpellCooldown / GetItemCount.
local cache, cacheAt = nil, -1

function MC:All()
    local now = GetTime()
    if cache and now - cacheAt < 0.4 then return cache end

    local out = {}
    if not MD.player.usesMana then
        cache, cacheAt = out, now
        return out
    end

    local list = MC.byClass[MD.player.class]
    if list then
        for _, entry in ipairs(list) do
            if entry.value and SpellKnown(entry.id) then
                local remaining = SpellCooldownRemaining(entry.id)
                out[#out + 1] = {
                    key = entry.key, name = entry.name, short = entry.short, kind = "spell",
                    delta = entry.value(entry),
                    cdRemaining = remaining or 0,
                    ready = (remaining or 0) <= 0,
                }
            end
        end
    end

    -- Only the best potion carried: the others are strictly worse and would
    -- just produce a second alert for the same decision.
    for _, potion in ipairs(MC.potions) do
        if GetItemCount and GetItemCount(potion.id) > 0 then
            out[#out + 1] = {
                key = potion.key, name = potion.name, short = potion.short, kind = "potion",
                delta = potion.value,
                cdRemaining = 0,
                ready = ItemReady(potion.id),
            }
            break
        end
    end

    table.sort(out, function(a, b) return a.delta > b.delta end)
    cache, cacheAt = out, now
    return out
end

-- The richest source that is ready right now, or nil. Suppressed entirely
-- while one of the buffs is already running.
function MC:Best()
    if MC:Active() then return nil end
    for _, src in ipairs(MC:All()) do
        if src.ready and src.delta > 0 then return src end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Debug: the regen rates either side of a cooldown buff, which is what proves
-- (or disproves) the "400% on the spirit share only" model above.
--------------------------------------------------------------------------------
local wasActive = false
MD:OnTick(function()
    if not (MD.db and MD.db.debug and MD.db.debug.enabled) then return end
    local active = MC:Active()
    if active ~= wasActive then
        wasActive = active
        local RM = MD.Regen
        local spiritPerSec, mp5Gear, _, unreported = RM:Components()
        MD:Debug("regen", "mana cooldown %s: GetManaRegen base %.2f/s casting %.2f/s; model expects %.2f/s while up "
            .. "(5 x spirit %.2f + gear %.2f + unreported %.2f)",
            active and "UP" or "faded", RM.apiBase, RM.apiCasting,
            5 * spiritPerSec + mp5Gear / 5 + unreported, spiritPerSec, mp5Gear / 5, unreported)
    end
end)
