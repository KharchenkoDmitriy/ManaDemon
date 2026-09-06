-- Options frame (Cell-style): a 432px-wide flat panel whose tab buttons sit
-- on its top edge (General | About ... x), height per tab. Tabs register
-- for the "ShowOptionsTab" callback and show/hide themselves.
local _, MD = ...
local UI = MD.UI

local WIDTH = 432
-- Per-tab frame height; a tab may overwrite its entry once it has measured
-- its content (About does).
-- General grew a fourth pane in v0.7.6 (Fight recording); the left column now
-- runs widget + alerts + recording.
local TAB_HEIGHT = { general = 470, about = 360 }
MD.optionsTabHeight = TAB_HEIGHT

local frame = UI.CreateFrame("ManaDemonOptionsFrame", UIParent, WIDTH, TAB_HEIGHT.general)
MD.optionsFrame = frame
frame:SetPoint("CENTER", UIParent, "CENTER", 1, -1)
frame:SetFrameStrata("DIALOG")
frame:SetFrameLevel(520)
frame:SetClampedToScreen(true)
frame:SetClampRectInsets(0, 0, 20, 0)
frame:SetMovable(true)
frame:SetUserPlaced(false)
tinsert(UISpecialFrames, "ManaDemonOptionsFrame") -- ESC closes

local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint()
    MD.db.optionsPos = { point, relPoint, x, y }
end

local function RegisterDrag(f)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        frame:StartMoving()
        frame:SetUserPlaced(false)
    end)
    f:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosition()
    end)
end
RegisterDrag(frame)

local tabs, lastShownTab, init = {}, nil, false

local function ShowTab(tab)
    if lastShownTab ~= tab then
        frame:SetHeight(TAB_HEIGHT[tab] or 300)
        MD:Fire("ShowOptionsTab", tab)
        lastShownTab = tab
    end
end

local function CreateTabButtons()
    local generalBtn = UI.CreateButton(frame, "General", "accent-hover", { 105, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
    local aboutBtn = UI.CreateButton(frame, "About", "accent-hover", { 105, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
    local closeBtn = UI.CreateButton(frame, "×", "red", { 20, 20 }, false, false, UI.FONT_SPECIAL, UI.FONT_SPECIAL)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    generalBtn:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, -1)
    aboutBtn:SetPoint("BOTTOMLEFT", generalBtn, "BOTTOMRIGHT", -1, 0)
    closeBtn:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, -1)

    -- the rest of the strip: a header bar carrying the version
    local bar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    bar:SetPoint("BOTTOMLEFT", aboutBtn, "BOTTOMRIGHT", -1, 0)
    bar:SetPoint("BOTTOMRIGHT", closeBtn, "BOTTOMLEFT", 1, 0)
    bar:SetHeight(20)
    bar:EnableMouse(true)
    UI.StylizeFrame(bar, { 0.115, 0.115, 0.115, 1 })
    local barText = bar:CreateFontString(nil, "OVERLAY", UI.FONT_CLASS)
    barText:SetPoint("CENTER")
    barText:SetText("ManaDemon v" .. MD.version)
    RegisterDrag(bar)

    generalBtn.id, aboutBtn.id = "general", "about"
    RegisterDrag(generalBtn)
    RegisterDrag(aboutBtn)
    tabs.general, tabs.about = generalBtn, aboutBtn

    UI.CreateButtonGroup({ generalBtn, aboutBtn }, ShowTab)
end

local function Init()
    if init then return end
    init = true
    CreateTabButtons()
end

-- MD:ShowOptionsFrame()      toggles (opens on the last tab)
-- MD:ShowOptionsFrame(tab)   opens that tab
function MD:ShowOptionsFrame(tab)
    Init()
    if frame:IsShown() and not tab then
        frame:Hide()
        return
    end
    frame:Show()
    local btn = tabs[tab or lastShownTab or "general"] or tabs.general
    btn:Click()
end

frame:SetScript("OnShow", function()
    frame:ClearAllPoints()
    local p = MD.db and MD.db.optionsPos
    if type(p) == "table" then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 1, -1)
    end
end)
