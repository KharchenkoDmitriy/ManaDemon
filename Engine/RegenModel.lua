-- Regen model. Per the design debate: for the live TTO the two GetManaRegen()
-- returns are used DIRECTLY (base = out of the five-second rule, casting =
-- inside it) — no algebra on top, so talent effects like Intensity are never
-- double-counted. The spirit/mp5 decomposition below is display-only.
local _, MD = ...

local RM = {}
MD.Regen = RM

RM.fsrEnd = 0          -- GetTime() when the five-second rule expires
RM.base = 0            -- mana/sec outside the FSR
RM.casting = 0         -- mana/sec inside the FSR

-- per-combat FSR accounting
local combat = { active = false, total = 0, inFSR = 0 }

function RM:InFSR()
    return GetTime() < RM.fsrEnd
end

-- Seconds until spirit regen resumes (0 = out of the FSR).
function RM:FSRRemaining()
    return math.max(0, RM.fsrEnd - GetTime())
end

function RM:Current()
    return RM:InFSR() and RM.casting or RM.base
end

--------------------------------------------------------------------------------
-- Projection regen: the two GetManaRegen() rates weighted by the measured
-- five-second-rule duty cycle (EWMA of "inside the FSR", half-life 20s).
-- RM:Current() is a point sample of a two-state process; over a 30–200s
-- horizon the healer will be in the FSR some FRACTION of the time, and using
-- the instantaneous state made the TTO jump every time a casting gap crossed
-- 5s. Both rates are still consumed raw — nothing is decomposed. Reset to 1
-- (pessimistic) at the pull. RM:Current() keeps driving the underline.
--------------------------------------------------------------------------------
local duty = 0
local DUTY_HALFLIFE = 20

-- Out of combat, drink/food are periodic energize effects that GetManaRegen()
-- does not report, so the FULL clock uses the observed mana gain rate instead
-- (EWMA, half-life 5s — drink ticks land every 2s; needs >= 2 observed gains).
local observedFill, fillGains, gainAcc = 0, 0, 0
local FILL_HALFLIFE = 5

function RM:Effective()
    return duty * RM.casting + (1 - duty) * RM.base
end

function RM:Duty()
    return duty
end

function RM:ObservedFill()
    return fillGains >= 2 and observedFill or 0
end

function RM:Refresh()
    if not GetManaRegen then return end
    local base, casting = GetManaRegen("player")
    -- GetManaRegen returns mana per 1 second on Classic clients (ElvUI's
    -- ManaRegen datatext multiplies by 5 for mp5 display). VERIFY via /md verify.
    RM.base = base or 0
    RM.casting = casting or 0
end

--------------------------------------------------------------------------------
-- Display-only decomposition (dashboard/tooltip): estimate the spirit-based
-- share so mp5-from-gear can be shown separately. Never feeds the TTO.
--------------------------------------------------------------------------------
function RM:Components()
    local spirit = UnitStat("player", 5) or 0
    local intellect = UnitStat("player", 4) or 0
    -- Level-70 base_regen constant; regen per 2s tick = spi*sqrt(int)*0.009327.
    local spiritPerSec = spirit * math.sqrt(intellect) * 0.009327 / 2
    local mp5Gear = math.max(0, (RM.base - spiritPerSec)) * 5
    local intensityFrac = 0.1 * MD:TalentRank("Intensity") -- 10%/rank, 3 ranks
    return spiritPerSec, mp5Gear, intensityFrac
end

--------------------------------------------------------------------------------
-- FSR trigger: ANY drop in player mana refreshes the 5s clock. This is
-- spell-table independent (wands, off-spec casts, any class) — the reason the
-- TTO side of the addon is class-generic. Enemy mana burns are rare enough to
-- accept as false FSR triggers.
--------------------------------------------------------------------------------
local lastMana

MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    if lastMana and cur < lastMana then
        RM.fsrEnd = GetTime() + 5
        MD:Fire("MANA_SPENT", lastMana - cur)
    elseif lastMana and cur > lastMana and not combat.active then
        gainAcc = gainAcc + (cur - lastMana)
        fillGains = fillGains + 1
    end
    lastMana = cur
end)

MD:RegisterCallback("MD_READY", function()
    lastMana = UnitPower("player", 0)
    RM:Refresh()
end)

--------------------------------------------------------------------------------
-- Per-combat FSR uptime → "spirit regen realized" for the fight summary.
--------------------------------------------------------------------------------
MD:On("PLAYER_REGEN_DISABLED", function()
    combat.active = true
    combat.total = 0
    combat.inFSR = 0
    duty = 1
    observedFill, fillGains, gainAcc = 0, 0, 0
end)

MD:On("PLAYER_REGEN_ENABLED", function()
    combat.active = false
    observedFill, fillGains, gainAcc = 0, 0, 0
end)

MD:OnTick(function(dt)
    RM:Refresh() -- cheap; keeps rates fresh through auras/procs mid-combat
    local inFSR = RM:InFSR()
    duty = duty + ((inFSR and 1 or 0) - duty) * (1 - 0.5 ^ (dt / DUTY_HALFLIFE))
    if combat.active then
        combat.total = combat.total + dt
        if inFSR then
            combat.inFSR = combat.inFSR + dt
        end
    else
        observedFill = observedFill + (gainAcc / dt - observedFill) * (1 - 0.5 ^ (dt / FILL_HALFLIFE))
        gainAcc = 0
    end
end)

-- Fraction of the fight's potential spirit regen that was actually realized
-- (time out of FSR counts fully; time in FSR counts at the Intensity fraction).
function RM:CombatSpiritRealized()
    if combat.total <= 0 then return nil end
    local _, _, intensityFrac = RM:Components()
    return (combat.total - combat.inFSR + intensityFrac * combat.inFSR) / combat.total
end
