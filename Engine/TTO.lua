-- Time-to-OOM / time-to-full. Model (docs/DECISIONS.md, feedback round 3):
--   spend = EWMA rate + K_SIGMA * sigma          (pessimistic edge, calibrated)
--   regen = FSR-duty-weighted GetManaRegen()     (no regime flip at the 5s edge)
--   net   = spend - regen
--   mode  = oom   (net >  sigma): tto   = mana / net
--           full  (net < -sigma): ttf   = deficit / -net
--           hold  (|net| <= sigma): one-sided bound mana / (net + sigma)
--   rest  = time to full if casting stopped NOW (exact inputs, ~zero variance)
-- Out of combat the clock is deterministic: max(observed mana gain, FSR-aware
-- GetManaRegen) so drinking reads correctly.
--
-- Display layer (tick-accumulated, render-only; the raw state above is what
-- every other module reads): digits are quantized to the model's own sigma,
-- the shown value and mode are latched (bad news instant, good news needs two
-- consecutive ticks), and the trend arrow is derived from the SHOWN value so
-- arrow and number can never contradict each other.
local _, MD = ...

local RM, ST -- bound at MD_READY (load order guarantees they exist by then)
MD:RegisterCallback("MD_READY", function()
    RM, ST = MD.Regen, MD.Spend
end)

local K_SIGMA = 1.0        -- pessimistic edge, in standard deviations
local CV_STABLE = 0.35     -- sigma/rate above this -> "~" (chain-casting sits ~0.24)
local WARMUP_CASTS = 3     -- sigma is meaningless below this many priced casts
local CAP = 600            -- seconds; beyond this the clock reads ">10m"
local FULL_PCT = 0.98

local state -- raw state, refreshed every master tick

--------------------------------------------------------------------------------
-- Raw model
--------------------------------------------------------------------------------
-- FSR-aware time to full at the current GetManaRegen rates with zero spend.
local function RestTime(mana, manaMax)
    local deficit = manaMax - mana
    if deficit <= 0 then return 0 end
    local fsr = RM:FSRRemaining()
    if fsr > 0 then
        local gained = RM.casting * fsr
        if gained >= deficit then
            return RM.casting > 0 and deficit / RM.casting or nil
        end
        if RM.base <= 0 then return nil end
        return fsr + (deficit - gained) / RM.base
    end
    if RM.base <= 0 then return nil end
    return deficit / RM.base
end

local function Compute()
    if not RM or not MD.player.usesMana then return nil end
    local mana = UnitPower("player", 0)
    local manaMax = UnitPowerMax("player", 0)
    local rate, sigma, n = ST:Estimate()
    local regen = RM:Effective()
    local pess = rate + K_SIGMA * sigma
    local net = pess - regen
    local cv = rate > 0 and sigma / rate or 0
    local s = {
        mana = mana, manaMax = manaMax,
        pct = manaMax > 0 and mana / manaMax or 1,
        regen = regen, regenNow = RM:Current(), duty = RM:Duty(),
        spend = rate, sigma = sigma, pessimistic = pess, net = net,
        casts = n, cv = cv,
        stable = n >= 5 and cv <= CV_STABLE,
        inCombat = UnitAffectingCombat("player") and true or false,
        rest = RestTime(mana, manaMax),
    }
    if not s.inCombat then
        local deficit = manaMax - mana
        local ttf = s.rest
        local fill = RM:ObservedFill()
        if fill > 0 and deficit > 0 then
            local t = deficit / fill
            if not ttf or t < ttf then ttf = t end
        end
        s.ttf = ttf
        if s.pct >= FULL_PCT then
            s.mode = "fullnow"
        else
            s.mode = ttf and "ooc" or "nodata"
        end
    elseif n < WARMUP_CASTS and not ST:Seeded() then
        s.mode = "warmup"
    elseif net > sigma then
        s.mode = "oom"
        s.tto = mana / net
    elseif net < -sigma then
        s.mode = "full"
        s.ttf = (manaMax - mana) / -net
    else
        s.mode = "hold"
        if net + sigma > 0 then s.bound = mana / (net + sigma) end
    end
    -- sigma of the projected horizon (delta method): T * sigma / |net|
    local T = s.tto or s.ttf
    if T and s.inCombat and net ~= 0 then
        s.sigmaT = T * sigma / math.abs(net)
    end
    return s
end

-- Raw state for every consumer except the display string. Fields:
-- mana, manaMax, pct, regen (projection), regenNow, duty, spend, sigma,
-- pessimistic, net, casts, cv, stable, inCombat, rest, mode, and one of
-- tto (oom) / ttf (full, ooc) / bound (hold); sigmaT when a horizon exists.
function MD:GetManaState()
    return state
end

--------------------------------------------------------------------------------
-- Display layer
--------------------------------------------------------------------------------
local LADDER = { 1, 5, 10, 15, 30, 60 }
local BETTER = { oom = 1, hold = 2, full = 3 } -- in-combat modes, worst first
local disp = { history = {} }

local function ResetDisplay(mode)
    disp.mode = mode
    disp.modeCand, disp.modeTicks = nil, 0
    disp.value, disp.cand, disp.candTicks = nil, nil, 0
    disp.step, disp.finer, disp.finerSince = nil, nil, nil
    wipe(disp.history)
end

-- Worse news switches immediately; better news needs two consecutive ticks.
local function LatchMode(m)
    local cur = disp.mode
    if cur == m then
        disp.modeCand, disp.modeTicks = nil, 0
        return
    end
    local immediate = not (BETTER[cur] and BETTER[m]) or BETTER[m] < BETTER[cur]
    if immediate then
        ResetDisplay(m)
        return
    end
    if disp.modeCand == m then
        disp.modeTicks = disp.modeTicks + 1
    else
        disp.modeCand, disp.modeTicks = m, 1
    end
    if disp.modeTicks >= 2 then ResetDisplay(m) end
end

-- Display step = smallest ladder value >= 0.5 * sigma of the horizon, floored
-- at 1s (under a minute) / 5s, capped at 60s: the digit that moves is a digit
-- that means something. The step may coarsen at once but refines only after
-- the finer step has held for 5s, so granularity itself does not flicker.
local function ChooseStep(v, sigmaT, now)
    local floorStep = v < 60 and 1 or 5
    local want = 0.5 * (sigmaT or 0)
    local step = 60
    for _, s in ipairs(LADDER) do
        if s >= want then
            step = s
            break
        end
    end
    step = math.max(step, floorStep)
    if not disp.step or step > disp.step then
        disp.step, disp.finer, disp.finerSince = step, nil, nil
    elseif step < disp.step then
        if disp.finer ~= step then disp.finer, disp.finerSince = step, now end
        if now - disp.finerSince >= 5 then
            disp.step, disp.finer, disp.finerSince = step, nil, nil
        end
    else
        disp.finer, disp.finerSince = nil, nil
    end
    return disp.step
end

local function Quantize(v, step)
    return step * math.floor(v / step + 0.5)
end

-- The shown value changes only after the same quantized value is seen on two
-- consecutive ticks — except when it worsens by more than two steps or crosses
-- the 60s / 20s severity boundaries downward, which apply at once.
local function LatchValue(q, worseIsLower, step)
    local cur = disp.value
    if cur == nil or q == cur then
        disp.value, disp.cand, disp.candTicks = q, nil, 0
        return
    end
    local worse = (worseIsLower and q < cur) or (not worseIsLower and q > cur)
    if worse then
        local big = math.abs(q - cur) > 2 * step
        local crossed = worseIsLower and ((cur >= 60 and q < 60) or (cur >= 20 and q < 20))
        if big or crossed then
            disp.value, disp.cand, disp.candTicks = q, nil, 0
            return
        end
    end
    if disp.cand == q then
        disp.candTicks = disp.candTicks + 1
    else
        disp.cand, disp.candTicks = q, 1
    end
    if disp.candTicks >= 2 then
        disp.value, disp.cand, disp.candTicks = q, nil, 0
    end
end

MD:OnTick(function()
    state = Compute()
    if not state then
        disp.mode = nil
        return
    end
    local now = GetTime()
    LatchMode(state.mode)

    local m = disp.mode
    local v, worseIsLower, sigmaT
    if m == "oom" then
        v, worseIsLower, sigmaT = state.tto, true, state.sigmaT
    elseif m == "hold" then
        v, worseIsLower, sigmaT = state.bound, true, 60 -- bound: coarse by design
    elseif m == "full" then
        v, worseIsLower, sigmaT = state.ttf, false, state.sigmaT
    elseif m == "ooc" then
        v, worseIsLower, sigmaT = state.ttf, false, 0     -- deterministic
    end
    if v then
        local step = ChooseStep(v, sigmaT, now)
        LatchValue(Quantize(v, step), worseIsLower, step)
    else
        disp.value = nil
    end

    -- shown-value history for the arrow: keep ~10s
    local h = disp.history
    h[#h + 1] = { now, disp.value }
    while h[2] and now - h[2][1] >= 10 do
        table.remove(h, 1)
    end
end)

-- Arrow from the SHOWN value over the last ~10s. A clock counting down at
-- 1s/s is "=" (steady drain); "v" = losing ground faster than that;
-- "^" = the clock went up (recovering). Dead band = one display step.
local function Arrow(now)
    local old = disp.history[1]
    if not old or old[2] == nil or disp.value == nil then return "=" end
    local elapsed = now - old[1]
    if elapsed < 8 then return "=" end
    local step = disp.step or 5
    local change = disp.value - old[2] + elapsed
    if change < -step then return "v" end
    if change > step then return "^" end
    return "="
end

--------------------------------------------------------------------------------
-- Shared display string: the ElvUI datatext, the floating widget and the
-- minimap tooltip all render exactly this. ASCII only (WoW fonts have no
-- arrow/infinity glyphs) and NO bare "|" (it opens a colour escape).
-- valueHex (e.g. "|cff16c3f2") replaces the number's colour so the datatext
-- can inherit the ElvUI theme — except the critical band, which stays red.
--------------------------------------------------------------------------------
local GREY  = "|cff999999"
local WHITE = "|cffffffff"
local WARN  = "|cffffaa33"
local CRIT  = "|cffff4444"
local GOOD  = "|cff33ff66"

local function FmtTime(sec)
    if sec > CAP then return ">10m" end
    if sec >= 60 then
        return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
    end
    return string.format("%ds", math.floor(sec))
end

function MD:GetDisplayString(valueHex)
    local s = state
    local m = disp.mode
    if not s or not m then return "" end
    local v = disp.value
    local out

    if m == "fullnow" then
        out = GOOD .. "FULL|r"
    elseif m == "nodata" then
        out = GREY .. "FULL --|r"
    elseif m == "ooc" or m == "full" then
        out = GREY .. "FULL|r " .. (valueHex or GOOD) .. FmtTime(v or 0) .. "|r"
    elseif m == "warmup" then
        out = GREY .. "OOM ...|r"
    elseif m == "hold" then
        local bound = (v and v <= CAP) and FmtTime(v) or "10m"
        out = GREY .. "OOM >" .. bound .. " =|r"
    else -- oom
        v = v or 0
        if v < 20 then
            out = CRIT .. "OOM " .. FmtTime(v) .. " vv|r"
        else
            local hex = valueHex or (v < 60 and WARN or WHITE)
            local prefix = ""
            if not s.stable then hex, prefix = GREY, "~" end
            local a = Arrow(GetTime())
            local ac = (a == "^" and GOOD) or (a == "v" and WARN) or GREY
            out = GREY .. "OOM|r " .. hex .. prefix .. FmtTime(v) .. "|r " .. ac .. a .. "|r"
        end
    end

    -- Secondary segment: "rest" = time to full if you stop casting now.
    -- Combat only, never next to a FULL clock, hidden when within 25% of the
    -- primary (no decision content), two-space separator (never a pipe).
    if s.inCombat and s.rest and (m == "oom" or m == "hold" or m == "warmup")
        and not (MD.db and MD.db.showRest == false) then
        local r = s.rest
        local show = (v == nil) or (v > CAP) or (math.abs(r - v) / math.max(v, 1) >= 0.25)
        if show then
            out = out .. "  " .. GREY .. "rest " .. FmtTime(Quantize(r, r < 30 and 1 or 5)) .. "|r"
        end
    end
    return out
end
