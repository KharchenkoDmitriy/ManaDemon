-- Floating one-line widget: "OOM 1:20 v  rest 2:10" plus a 2px five-second-
-- rule underline that fills over 5s after each mana spend (full = spirit
-- regen running). Text is LEFT-anchored so the "OOM" label never slides when
-- the digit count or the rest segment changes; the underline follows the
-- text width. All show/hide decisions live in MD:UpdateVisibility() —
-- nothing else may call Show/Hide on this frame.
local _, MD = ...

local widget, text, underline
local shown = false
local forceUntil = 0        -- first-run / unlock preview
local flashedThisFight = false

local function CreateWidget()
    widget = CreateFrame("Frame", "ManaDemonWidget", UIParent)
    widget:SetSize(190, 22)
    widget:SetFrameStrata("MEDIUM")
    widget:SetMovable(true)
    widget:SetClampedToScreen(true)
    widget:EnableMouse(false)
    widget:RegisterForDrag("LeftButton")

    text = widget:CreateFontString(nil, "OVERLAY")
    text:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    text:SetPoint("LEFT", widget, "LEFT", 6, 2)

    underline = CreateFrame("StatusBar", nil, widget)
    underline:SetSize(60, 2)
    underline:SetPoint("BOTTOMLEFT", widget, "BOTTOMLEFT", 6, 0)
    underline:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    underline:SetMinMaxValues(0, 5)

    widget:SetScript("OnDragStart", function(self)
        -- draggable when unlocked OR during the first-run/unlock preview
        if not MD.db.locked or GetTime() < forceUntil then self:StartMoving() end
    end)
    widget:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        MD.db.pos = { point, relPoint, x, y }
    end)

    -- pulse animation (used by MD:Alert and the one-per-fight 30s flash)
    local pulse = widget:CreateAnimationGroup()
    for i, dir in ipairs({ 1, -1, 1, -1 }) do
        local a = pulse:CreateAnimation("Alpha")
        a:SetFromAlpha(dir > 0 and 1 or 0.2)
        a:SetToAlpha(dir > 0 and 0.2 or 1)
        a:SetDuration(0.25)
        a:SetOrder(i)
    end
    widget.pulse = pulse

    widget:Hide()
    MD:ApplyWidgetPosition()

    -- Rendering only; the model is event/tick driven elsewhere. The text is
    -- rebuilt 4x/s (the latch in TTO.lua means it can only change every 1s
    -- anyway); the underline keeps a 10 Hz refresh so it fills smoothly.
    local acc, textAcc = 0, 1
    widget:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.1 then return end
        textAcc = textAcc + acc
        acc = 0

        if not MD.db.locked or GetTime() < forceUntil then
            text:SetText("|cff9966ffManaDemon|r - drag me")
            underline:SetWidth(math.max(60, text:GetStringWidth()))
            underline:SetValue(5)
            underline:SetStatusBarColor(0.6, 0.4, 1)
            return
        end

        if textAcc >= 0.25 then
            textAcc = 0
            local str = MD:GetDisplayString()
            text:SetText(str ~= "" and str or "|cff999999OOM ...|r")
            underline:SetWidth(math.max(60, text:GetStringWidth()))

            -- one attention event per fight: first time TTO crosses below 30s
            if not flashedThisFight then
                local s = MD:GetManaState()
                if s and s.mode == "oom" and s.tto and s.tto < 30 and s.stable then
                    flashedThisFight = true
                    widget.pulse:Play()
                end
            end
        end

        local remaining = MD.Regen:FSRRemaining()
        underline:SetValue(5 - remaining)
        if remaining > 0 then
            underline:SetStatusBarColor(1, 0.67, 0.2)   -- in FSR: amber, filling
        else
            underline:SetStatusBarColor(0.2, 1, 0.4)    -- spirit regen running
        end
    end)
end

function MD:ApplyWidgetPosition()
    if not widget then return end
    widget:ClearAllPoints()
    local pos = MD.db.pos
    if #pos == 4 then
        widget:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else -- legacy 3-element form
        widget:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3])
    end
end

function MD:PulseWidget()
    if widget and shown then widget.pulse:Play() end
end

function MD:ForceWidgetPreview(seconds)
    forceUntil = GetTime() + (seconds or 60)
    MD:UpdateVisibility()
end

--------------------------------------------------------------------------------
-- Visibility: the single owner. In combat: always show. Out of combat:
-- hysteresis (show below 90% mana, hide above 95%) so it never flickers.
--------------------------------------------------------------------------------
function MD:UpdateVisibility()
    if not widget then return end

    local wantShown
    if not MD.db.locked or GetTime() < forceUntil then
        wantShown = true
        widget:EnableMouse(true)
    else
        widget:EnableMouse(false)
        if not MD.player.usesMana then
            wantShown = false
        elseif InCombatLockdown() or UnitAffectingCombat("player") then
            wantShown = true
        else
            local mana = UnitPower("player", 0)
            local manaMax = UnitPowerMax("player", 0)
            local pct = manaMax > 0 and mana / manaMax or 1
            if shown then
                wantShown = pct <= 0.95
            else
                wantShown = pct < 0.90
            end
        end
    end

    if wantShown ~= shown then
        shown = wantShown
        if shown then widget:Show() else widget:Hide() end
    end
end

MD:RegisterCallback("MD_READY", function()
    CreateWidget()
    MD:UpdateVisibility()
end)

MD:OnTick(function()
    MD:UpdateVisibility()
end)

MD:On("PLAYER_REGEN_DISABLED", function()
    flashedThisFight = false
    MD:UpdateVisibility()
end)

MD:On("PLAYER_REGEN_ENABLED", function()
    MD:UpdateVisibility()
end)
