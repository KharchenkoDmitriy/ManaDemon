-- Regen model. The two GetManaRegen() returns (base = out of the five-second
-- rule, casting = inside it) are used DIRECTLY for everything the client
-- reports — no algebra on top, so Intensity / Living Spirit / gear mp5 are
-- never double-counted. Verified in-game 2026-09-03 (/md regentest, see
-- docs/HISTORY.md): observed regen ticks match GetManaRegen within ~1%,
-- EXCEPT Dreamstate, which the client leaves out of both values. That one
-- talent (4/7/10% of Intellect per 5s, in and out of the 5SR) is added here
-- as RM.unreported; RM.apiBase / RM.apiCasting keep the raw client numbers
-- for the verify harness and the display decomposition.
local _, MD = ...

local RM = {}
MD.Regen = RM

RM.fsrEnd = 0                     -- GetTime() when the five-second rule expires
RM.apiBase, RM.apiCasting = 0, 0  -- raw GetManaRegen("player")
RM.unreported = 0                 -- regen the client does not report (Dreamstate + measured mp5)
RM.dreamstate = 0                 -- of that: the talent
RM.measured = 0                   -- of that: the measured item-mp5 beat (cdb.mp5, v0.9.0)
RM.base = 0                       -- mana/sec outside the FSR (api + unreported)
RM.casting = 0                    -- mana/sec inside the FSR (api + unreported)

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
-- Projection regen: the two rates weighted by the measured five-second-rule
-- duty cycle (EWMA of "inside the FSR", half-life 20s). RM:Current() is a
-- point sample of a two-state process; over a 30–200s horizon the healer
-- will be in the FSR some FRACTION of the time, and using the instantaneous
-- state made the TTO jump every time a casting gap crossed 5s. Reset to 1
-- (pessimistic) at the pull. RM:Current() keeps driving the underline.
--------------------------------------------------------------------------------
local duty = 0
local DUTY_HALFLIFE = 20

function RM:Effective()
    return duty * RM.casting + (1 - duty) * RM.base
end

function RM:Duty()
    return duty
end

--------------------------------------------------------------------------------
-- Out of combat, drink/food are periodic energize effects GetManaRegen does
-- not report, so the FULL clock uses the observed mana gain rate. Regen
-- lands in discrete ticks (every 2s), so the rate is estimated per GAIN
-- EVENT — gain / interval since the previous gain — smoothed over ~3 events.
-- (A per-tick EWMA of that spiky signal oscillated +-10% and kept the
-- display latch from ever settling: "FULL 2:05" stuck at a true 94s.)
--------------------------------------------------------------------------------
local observedFill, fillGains, lastGainT = 0, 0, nil
local FILL_ALPHA = 0.4
local FILL_TIMEOUT = 6   -- no gain for this long -> estimate is stale

function RM:ObservedFill()
    if fillGains < 2 or not lastGainT or GetTime() - lastGainT > FILL_TIMEOUT then return 0 end
    return observedFill
end

local function ResetFill()
    observedFill, fillGains, lastGainT = 0, 0, nil
end

--------------------------------------------------------------------------------
-- Regen the client does not report. Dreamstate: measured 2026-09-03 at
-- 342 Int / rank 3 — observed ticks ran ~35 mp5 above GetManaRegen with the
-- talent and matched it without (docs/HISTORY.md). Adding this on a client
-- that DID report it would double count, which is why it was measured first.
--------------------------------------------------------------------------------
local DREAMSTATE_PCT = { 0.04, 0.07, 0.10 }

function RM:Dreamstate()
    local r = MD:TalentRank("Dreamstate")
    if r == 0 then return 0 end
    return (DREAMSTATE_PCT[r] or 0) * (UnitStat("player", 4) or 0) / 5
end

-- The second unreported stream (v0.9.0): a constant beat the API leaves out
-- that is NOT a talent -- item mp5 on this client, measured on three solo
-- recordings at ~31 mp5 and confirmed by /md regentest's tick histogram (a
-- 2.00s beat next to the spirit tick, in and out of the five-second rule).
-- It is a MEASUREMENT with a date, stored per character by the test itself
-- (Verify.lua), never a constant and never inferred from gear. No measurement
-- means zero: the model does not guess.
-- A stored measurement is trusted, with one bound: it is what the client does
-- NOT report, so it cannot be bigger than what the client does. v0.9.0 shipped
-- a test that stored the size of the whole regen tick instead of the leftover,
-- and a character regenerating 279 mp5 ended up modelled at 556. The test is
-- fixed (Verify.lua, v0.9.5); this refuses the old number so a database written
-- before the fix cannot keep lying, and says so once rather than silently
-- clamping.
local warnedMp5 = false
function RM:MeasuredMp5()
    local m = MD.cdb and MD.cdb.mp5
    if not m or not m.perSec or m.perSec <= 0 then return 0 end
    if RM.apiBase > 0 and m.perSec > RM.apiBase then
        if not warnedMp5 then
            warnedMp5 = true
            MD:Print(string.format("the stored measured mp5 (%d) is larger than everything the client reports (%d mp5) " ..
                "- ignoring it. Run |cffffff00/md regentest 30|r solo to measure again, or |cffffff00/md regentest clear|r.",
                m.mp5 or (m.perSec * 5 + 0.5), RM.apiBase * 5 + 0.5))
        end
        return 0
    end
    return m.perSec
end

function RM:Unreported()
    return RM:Dreamstate() + RM:MeasuredMp5()
end

function RM:Refresh()
    if not GetManaRegen then return end
    local base, casting = GetManaRegen("player")
    -- GetManaRegen returns mana per 1 second on this client (verified: +122
    -- per 2s tick against base 60.16/s).
    base, casting = base or 0, casting or 0
    local extra = RM:Unreported()
    if math.abs(base - RM.apiBase) > 0.005 or math.abs(casting - RM.apiCasting) > 0.005
        or math.abs(extra - RM.unreported) > 0.005 then
        MD:Debug("regen", "GetManaRegen base %.2f/s casting %.2f/s (mp5 %d / %d)%s",
            base, casting, base * 5 + 0.5, casting * 5 + 0.5,
            extra > 0 and string.format(" + %.2f/s not in the API (%d mp5: Dreamstate %d, measured %d)",
                extra, extra * 5 + 0.5, RM:Dreamstate() * 5 + 0.5, RM:MeasuredMp5() * 5 + 0.5) or "")
    end
    RM.apiBase, RM.apiCasting, RM.unreported = base, casting, extra
    RM.dreamstate, RM.measured = RM:Dreamstate(), RM:MeasuredMp5()
    RM.base = base + extra
    RM.casting = casting + extra
end

--------------------------------------------------------------------------------
-- Display-only decomposition (dashboard/tooltip): spirit share vs flat mp5
-- (gear/buffs), derived from the client's own two numbers and the in-FSR
-- talent fraction f:  base = S + G,  casting = f*S + G  =>  S = (base -
-- casting) / (1 - f). No level constant involved (the level-70 0.009327
-- formula read 2x low at level 64 on this client). Never feeds the TTO.
-- Returns spiritPerSec, mp5Gear, inFSRFraction, unreportedPerSec.
--------------------------------------------------------------------------------
local IN_FSR_TALENT = {
    DRUID  = { "Intensity", 0.10 },
    PRIEST = { "Meditation", 0.05 },
    MAGE   = { "Arcane Meditation", 0.05 },
}

function RM:InFSRFraction()
    local t = IN_FSR_TALENT[MD.player.class]
    return t and (t[2] * MD:TalentRank(t[1])) or 0
end

function RM:Components()
    local f = RM:InFSRFraction()
    local spiritPerSec = 0
    if f < 1 then
        spiritPerSec = math.max(0, (RM.apiBase - RM.apiCasting) / (1 - f))
    end
    local mp5Gear = math.max(0, RM.apiBase - spiritPerSec) * 5
    return spiritPerSec, mp5Gear, f, RM.unreported
end

--------------------------------------------------------------------------------
-- FSR trigger: ANY drop in player mana refreshes the 5s clock. This is
-- spell-table independent (wands, off-spec casts, any class) — the reason the
-- TTO side of the addon is class-generic. Enemy mana burns are rare enough to
-- accept as false FSR triggers.
--------------------------------------------------------------------------------
local lastMana
local wasInFSR = false

MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    if lastMana and cur < lastMana then
        if not RM:InFSR() then
            MD:Debug("regen", "5SR start (casting regen %.2f/s)", RM.casting)
            wasInFSR = true
        end
        RM.fsrEnd = GetTime() + 5
        MD:Fire("MANA_SPENT", lastMana - cur)
    elseif lastMana and cur > lastMana and not combat.active then
        local now = GetTime()
        if lastGainT then
            local r = (cur - lastMana) / math.max(now - lastGainT, 0.5)
            if fillGains < 2 then
                observedFill = r
            else
                observedFill = observedFill + (r - observedFill) * FILL_ALPHA
            end
        end
        fillGains = fillGains + 1
        lastGainT = now
    end
    if lastMana and cur ~= lastMana then
        MD:Debug("mana", "%+d -> %d/%d%s", cur - lastMana, cur, UnitPowerMax("player", 0),
            RM:InFSR() and " (5SR)" or "")
    end
    lastMana = cur
end)

MD:RegisterCallback("MD_READY", function()
    lastMana = UnitPower("player", 0)
    RM:Refresh()
end)
MD:RegisterCallback("TALENTS_CHANGED", function() RM:Refresh() end)

--------------------------------------------------------------------------------
-- Per-combat FSR uptime → "spirit regen realized" for the fight summary.
--------------------------------------------------------------------------------
MD:On("PLAYER_REGEN_DISABLED", function()
    combat.active = true
    combat.total = 0
    combat.inFSR = 0
    duty = 1
    ResetFill()
end)

MD:On("PLAYER_REGEN_ENABLED", function()
    combat.active = false
    ResetFill()
end)

local oocLogAcc = 0

MD:OnTick(function(dt)
    RM:Refresh() -- cheap; keeps rates fresh through auras/procs mid-combat
    local inFSR = RM:InFSR()
    if wasInFSR and not inFSR then
        MD:Debug("regen", "5SR end (spirit regen resumed, %.2f/s)", RM.base)
    end
    wasInFSR = inFSR
    duty = duty + ((inFSR and 1 or 0) - duty) * (1 - 0.5 ^ (dt / DUTY_HALFLIFE))
    if combat.active then
        combat.total = combat.total + dt
        if inFSR then
            combat.inFSR = combat.inFSR + dt
        end
    else
        -- Premise check for the OOC clock: observed gain rate vs the model.
        oocLogAcc = oocLogAcc + dt
        if oocLogAcc >= 10 then
            oocLogAcc = 0
            local fill = RM:ObservedFill()
            if fill > 0 and UnitPower("player", 0) < UnitPowerMax("player", 0) then
                MD:Debug("regen", "OOC fill observed %.2f/s vs model %.2f/s (API %.2f, %s, duty %d%%)",
                    fill, RM:Current(), inFSR and RM.apiCasting or RM.apiBase,
                    inFSR and "5SR" or "out of 5SR", duty * 100)
            end
        end
    end
end)

-- Fraction of the fight's potential spirit regen that was actually realized
-- (time out of FSR counts fully; time in FSR counts at the Intensity fraction).
function RM:CombatSpiritRealized()
    if combat.total <= 0 then return nil end
    local _, _, intensityFrac = RM:Components()
    return (combat.total - combat.inFSR + intensityFrac * combat.inFSR) / combat.total
end
