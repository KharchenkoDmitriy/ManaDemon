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

-- All lines come from the shared builder (UI/Tooltip.lua) so the datatext,
-- the minimap button and the widget can never say different things.
local function OnEnter()
    DT.tooltip:ClearLines()
    DT.tooltip:AddLine("ManaDemon")
    MD.Tip:Render(DT.tooltip, MD.Tip:Mana())
    MD.Tip:Render(DT.tooltip, MD.Tip:Fights(1))
    DT.tooltip:AddLine(" ")
    DT.tooltip:AddLine("Click: dashboard   Shift-click: reset window", 0.5, 0.5, 0.5)
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
