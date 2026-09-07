-- Settings (v0.11.2): no longer a window of its own. `MD.optionsFrame` is now a
-- PANEL that the dashboard's navigation hosts as its fourth group -- the author
-- asked for one window, and two windows disagreeing about what a tab looks like
-- was the reason. The two tab panes (UI/Options_General.lua,
-- UI/Options_About.lua) are unchanged: they still parent themselves to
-- MD.optionsFrame and still show themselves on the "ShowOptionsTab" callback.
--
-- The panel is created here, at load time, because the tabs anchor to it as
-- they load; the dashboard adopts it into its content frame when it builds.
local _, MD = ...
local UI = MD.UI

-- Per-tab height, kept because UI/Options_About.lua measures its content
-- against it. Inside the navigation the panel fills the content area instead.
local TAB_HEIGHT = { general = 520, about = 360 }
MD.optionsTabHeight = TAB_HEIGHT

local frame = UI.CreateFrame("ManaDemonOptionsPanel", UIParent, 432, TAB_HEIGHT.general, true)
MD.optionsFrame = frame
frame:Hide()

local lastShownTab = nil

local function ShowTab(tab)
    lastShownTab = tab
    MD:Fire("ShowOptionsTab", tab)
end

-- The dashboard calls this once, when its navigation exists.
function MD:AdoptOptionsPanel(parent)
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetAllPoints(parent)
    frame:Show()
end

-- MD:ShowOptionsFrame()      the settings group, on the last tab used
-- MD:ShowOptionsFrame(tab)   that tab
function MD:ShowOptionsFrame(tab)
    if MD.SelectView then
        MD:SelectView("settings", tab or lastShownTab or "general")
    else
        ShowTab(tab or lastShownTab or "general")
    end
end

-- the navigation tells us which settings view it selected
MD:RegisterCallback("UI_VIEW_SELECTED", function(group, view)
    if group == "settings" and view then ShowTab(view) end
end)
