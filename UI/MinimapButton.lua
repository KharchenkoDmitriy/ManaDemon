-- Minimap button: standard round button parented to Minimap under a global
-- name, which is the pattern minimap-button collectors (MinimapButtonButton,
-- MBB, ElvUI's minimap-icon bar) detect and adopt. Left-click: dashboard.
-- Right-click: settings tab. Drag: move around the minimap edge.
local _, MD = ...

local btn

local function Reposition()
    if not btn then return end
    local angle = math.rad(MD.db.minimap.angle or 220)
    local radius = (Minimap:GetWidth() / 2) + 5
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    MD.db.minimap.angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
    Reposition()
end

local function CreateButton()
    btn = CreateFrame("Button", "ManaDemonMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\Spell_Shadow_Manaburn")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -5)

    btn:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            MD:OpenDashboardSettings()
        else
            MD:ToggleDashboard()
        end
    end)
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    -- Not gated by db.widgetTooltip: that setting is the floating clock's, and
    -- the clock is a thing you park somewhere and stop looking at. A minimap
    -- button is a thing you go to on purpose, so its tooltip always shows.
    btn:SetScript("OnEnter", function(self)
        MD.Tip:Show(self, "ANCHOR_LEFT",
            MD.Tip:Clock({ "Left-click: dashboard", "Right-click: settings" }))
    end)
    btn:SetScript("OnLeave", function() MD.Tip:Hide() end)

    Reposition()
    MD:UpdateMinimapButton()
end

function MD:UpdateMinimapButton()
    if not btn then return end
    if MD.db.minimap.hide then btn:Hide() else btn:Show() end
    Reposition()
end

MD:RegisterCallback("MD_READY", CreateButton)
