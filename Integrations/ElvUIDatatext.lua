-- ElvUI datatexts, themed with the user's ElvUI value colour. Loads only when
-- ElvUI is present (the .toc lists ElvUI in OptionalDeps so it always loads
-- first when installed). Two datatexts:
--   "ManaDemon"       — the OOM readout, same display string as the widget
--   "ManaDemon Regen" — CURRENT mana regen (casting regen inside the
--                       five-second rule, full regen outside); ElvUI's stock
--                       regen datatext only ever shows the out-of-casting value
-- Both share the tooltip and click behaviour.
local _, MD = ...

if not ElvUI then return end

local E = unpack(ElvUI)
local DT = E:GetModule("DataTexts")
if not DT then return end

local hex = nil -- "|cffxxxxxx" from ApplySettings, nil until themed

-- ElvUI fires the first OnUpdate with elapsed = 20000; clamp it, then throttle.
local function Throttled(panel, elapsed)
    if elapsed > 100 then elapsed = 0.25 end
    panel.mdElapsed = (panel.mdElapsed or 0) + elapsed
    if panel.mdElapsed < 0.25 then return false end
    panel.mdElapsed = 0
    return true
end

local function OnClick()
    if IsShiftKeyDown() then
        MD.Spend:Reset()
        MD:Print("spend window reset.")
    elseif MD.ToggleDashboard then
        MD:ToggleDashboard()
    end
end

local function OnEnter()
    DT.tooltip:ClearLines()
    DT.tooltip:AddLine("ManaDemon")

    local s = MD.GetManaState and MD:GetManaState()
    if s then
        local RM = MD.Regen
        local spiritPerSec, mp5Gear = RM:Components()
        if s.tto then
            DT.tooltip:AddDoubleLine("Time to OOM (raw)",
                string.format("%ds +- %ds", s.tto, s.sigmaT or 0), 1, 1, 1, 1, 1, 1)
        elseif s.ttf then
            DT.tooltip:AddDoubleLine("Time to full (raw)", string.format("%ds", s.ttf), 1, 1, 1, 1, 1, 1)
        elseif s.mode == "hold" then
            DT.tooltip:AddDoubleLine("Net rate within noise",
                s.bound and string.format("OOM no sooner than %ds", s.bound) or "sustainable", 1, 1, 1, 1, 1, 1)
        end
        if s.inCombat and s.rest then
            DT.tooltip:AddDoubleLine("Full if you stop casting", string.format("%ds", s.rest), 1, 1, 1, 1, 1, 1)
        end
        DT.tooltip:AddDoubleLine("Net rate (pessimistic)",
            string.format("%+d mana/s", -s.net), 1, 1, 1, 1, 1, 1)
        DT.tooltip:AddDoubleLine("Spending",
            string.format("%d +- %d mana/s (%d casts, CV %.2f)", s.spend, s.sigma, s.casts, s.cv), 1, 1, 1, 1, 1, 1)
        DT.tooltip:AddDoubleLine("Regen now / projected",
            string.format("%d / %d mana/s  (5SR %d%% of time)", s.regenNow, s.regen, s.duty * 100), 1, 1, 1, 1, 1, 1)
        DT.tooltip:AddDoubleLine("Regen out of 5SR / casting",
            string.format("%d / %d mana/s", RM.base, RM.casting), 1, 1, 1, 1, 1, 1)
        DT.tooltip:AddDoubleLine("Spirit / gear mp5",
            string.format("~%d / ~%d", spiritPerSec * 5, mp5Gear), 1, 1, 1, 1, 1, 1)
        if RM:InFSR() then
            DT.tooltip:AddDoubleLine("Spirit regen resumes",
                string.format("%.1fs", RM:FSRRemaining()), 1, 0.67, 0.2, 1, 1, 1)
        end
    end

    local last = MD.fightHistory and MD.fightHistory[#MD.fightHistory]
    if last then
        DT.tooltip:AddLine(" ")
        DT.tooltip:AddLine("Last fight: " .. (last.summary or "-"), 0.7, 0.7, 0.7, true)
    end

    DT.tooltip:AddLine(" ")
    DT.tooltip:AddLine("Click: dashboard  |  Shift-click: reset window", 0.5, 0.5, 0.5)
    DT.tooltip:Show()
end

local function ApplySettings(_, valueHex)
    hex = valueHex and ("|cff" .. valueHex:gsub("|cff", "")) or nil
end

--------------------------------------------------------------------------------
-- OOM datatext
--------------------------------------------------------------------------------
local function OOMUpdate(panel, elapsed)
    if not Throttled(panel, elapsed) then return end
    local str = MD.GetDisplayString and MD:GetDisplayString(hex) or ""
    panel.text:SetText(str ~= "" and str or "ManaDemon")
end

DT:RegisterDatatext("ManaDemon", nil, nil, nil, OOMUpdate, OnClick, OnEnter, nil, "ManaDemon", nil, ApplySettings)

--------------------------------------------------------------------------------
-- Current-regen datatext: "Regen: 123" (mp5), "(5SR)" while casting regen
-- is the one in effect.
--------------------------------------------------------------------------------
local function RegenUpdate(panel, elapsed)
    if not Throttled(panel, elapsed) then return end
    local RM = MD.Regen
    if not RM or not MD.player.usesMana then
        panel.text:SetText("Regen: " .. (hex or "|cffffffff") .. "--|r")
        return
    end
    local mp5 = math.floor(RM:Current() * 5 + 0.5)
    local suffix = RM:InFSR() and " |cffffaa33(5SR)|r" or ""
    panel.text:SetText("Regen: " .. (hex or "|cffffffff") .. mp5 .. "|r" .. suffix)
end

DT:RegisterDatatext("ManaDemon Regen", nil, nil, nil, RegenUpdate, OnClick, OnEnter, nil, "ManaDemon Regen", nil, ApplySettings)
