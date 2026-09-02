-- ElvUI datatext: same display string as the floating widget, themed with the
-- user's ElvUI value colour. Loads only when ElvUI is present (the .toc lists
-- ElvUI in OptionalDeps so it always loads first when installed).
local _, MD = ...

if not ElvUI then return end

local E = unpack(ElvUI)
local DT = E:GetModule("DataTexts")
if not DT then return end

local hex = nil -- "|cffxxxxxx" from ApplySettings, nil until themed

local function OnUpdate(panel, elapsed)
    -- ElvUI fires the first OnUpdate with elapsed = 20000; clamp it.
    if elapsed > 100 then elapsed = 0.25 end
    panel.mdElapsed = (panel.mdElapsed or 0) + elapsed
    if panel.mdElapsed < 0.25 then return end
    panel.mdElapsed = 0
    local str = MD.GetDisplayString and MD:GetDisplayString(hex) or ""
    panel.text:SetText(str ~= "" and str or "ManaDemon")
end

local function OnClick()
    if IsShiftKeyDown() then
        MD.Spend:Reset()
        MD:Print("spend window reset.")
    elseif MD.ToggleDashboard then
        MD:ToggleDashboard()
    end
end

local function OnEnter(panel)
    DT.tooltip:ClearLines()
    DT.tooltip:AddLine("ManaDemon")

    local s = MD.GetManaState and MD:GetManaState()
    if s then
        local RM = MD.Regen
        local spiritPerSec, mp5Gear = RM:Components()
        DT.tooltip:AddDoubleLine("Net rate (pessimistic)",
            string.format("%+d mana/s", -(s.pessimistic - s.regen)), 1, 1, 1, 1, 1, 1)
        DT.tooltip:AddDoubleLine("Spending", string.format("%d mana/s", s.spend), 1, 1, 1, 1, 1, 1)
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

DT:RegisterDatatext("ManaDemon", nil, nil, nil, OnUpdate, OnClick, OnEnter, nil, "ManaDemon", nil, ApplySettings)
