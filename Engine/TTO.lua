-- Time-to-OOM: mana / (pessimistic spend rate − analytic regen rate).
-- Returns a "sustainable" state instead of infinity when regen wins.
local _, MD = ...

local RM, ST -- bound at MD_READY (load order guarantees they exist by then)
MD:RegisterCallback("MD_READY", function()
    RM, ST = MD.Regen, MD.Spend
end)

-- Net-rate history for the trend arrow: one sample per master tick, ~40 kept
-- (20 seconds → current 10s window vs the previous one).
local netHistory = {}
local MAX_SAMPLES = 40

function MD:GetManaState()
    if not RM or not MD.player.usesMana then return nil end
    local mana = UnitPower("player", 0)
    local manaMax = UnitPowerMax("player", 0)
    local regen = RM:Current()
    local ewma = ST:Rate()
    local casts, median, p25, p75, stable = ST:WindowStats()
    local pess = math.max(ewma, p75 or 0)
    local net = pess - regen
    local state = {
        mana = mana, manaMax = manaMax,
        regen = regen, spend = ewma, pessimistic = pess,
        net = net, stable = stable, casts = casts,
    }
    if net <= 0 then
        state.sustainable = true
    else
        state.tto = mana / net
    end
    return state
end

MD:OnTick(function()
    local s = MD:GetManaState()
    if not s then return end
    netHistory[#netHistory + 1] = s.net
    if #netHistory > MAX_SAMPLES then
        table.remove(netHistory, 1)
    end
end)

-- "up": draining slower / regenerating; "down": draining faster; "flat" ±10%.
function MD:GetTrend()
    local n = #netHistory
    if n < 10 then return "flat" end
    local half = math.floor(math.min(n, MAX_SAMPLES) / 2)
    local recent, older = 0, 0
    for i = n - half + 1, n do recent = recent + netHistory[i] end
    for i = math.max(1, n - 2 * half + 1), n - half do older = older + netHistory[i] end
    recent = recent / half
    older = older / half
    if recent <= 0 then return "up" end
    if older <= 0 then return "down" end
    if recent < older * 0.9 then return "up" end
    if recent > older * 1.1 then return "down" end
    return "flat"
end

--------------------------------------------------------------------------------
-- Shared display string: the ElvUI datatext and the floating widget both
-- render exactly this. valueHex (e.g. "|cff16c3f2") overrides the number's
-- severity colour so the datatext can inherit the user's ElvUI theme.
--------------------------------------------------------------------------------
local function FormatTTO(seconds)
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
    end
    return string.format("%ds", math.floor(seconds))
end

local COLOR_OK    = "|cffffffff"
local COLOR_WARN  = "|cffffaa33"
local COLOR_CRIT  = "|cffff4444"
local COLOR_GOOD  = "|cff33ff66"
local COLOR_GREY  = "|cff999999"

function MD:GetDisplayString(valueHex)
    local s = MD:GetManaState()
    if not s then return "" end

    -- ASCII trend markers only: WoW's default fonts have no glyphs for
    -- arrows/infinity (they render as boxes).
    if s.sustainable then
        local hex = valueHex or COLOR_GOOD
        return "OOM " .. hex .. "--|r " .. COLOR_GOOD .. "^|r"
    end

    local severity = COLOR_OK
    if s.tto < 20 then
        severity = COLOR_CRIT
    elseif s.tto < 60 then
        severity = COLOR_WARN
    end

    local trend = MD:GetTrend()
    local arrow
    if s.tto < 20 then
        arrow = COLOR_CRIT .. "vv|r"        -- draining hard, under 20s
    elseif trend == "up" then
        arrow = COLOR_GOOD .. "^|r"         -- gaining ground
    elseif trend == "down" then
        arrow = COLOR_WARN .. "v|r"         -- draining faster
    else
        arrow = COLOR_GREY .. "=|r"         -- flat
    end

    local prefix = s.stable and "" or "~"
    local hex = valueHex or severity
    return "OOM " .. hex .. prefix .. FormatTTO(s.tto) .. "|r " .. arrow
end
