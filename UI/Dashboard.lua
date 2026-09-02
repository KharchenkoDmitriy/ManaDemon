-- Rank dashboard (/md). Layout: class tab row (Druid | Settings), spell
-- subtabs under it, and per-spell a table of ALL ranks (unlearned ranks
-- dimmed) with tooltip-style columns: heal per cast, mana, HPM, HPS, cast.
-- The Settings tab is the GUI for everything the slash commands can do.
local _, MD = ...

local WIDTH, HEIGHT = 700, 520
local frame, statsFS, calloutFS, recapFS
local spellTabsRow, settingsPane, tablePane, messageFS

local currentView = "spell"          -- "spell" | "settings"
local currentFamily = "HealingTouch"

local classTabs, spellTabs = {}, {}
local rowPool, usedRows = {}, {}

local COLS = {
    { key = "rank",  x = 12,  w = 46,  label = "Rank" },
    { key = "level", x = 62,  w = 40,  label = "Lvl" },
    { key = "cost",  x = 106, w = 60,  label = "Mana" },
    { key = "heal",  x = 170, w = 86,  label = "Heal/cast" },
    { key = "hpm",   x = 260, w = 64,  label = "HPM" },
    { key = "hps",   x = 328, w = 70,  label = "HPS" },
    { key = "cast",  x = 402, w = 56,  label = "Cast" },
    { key = "note",  x = 462, w = 200, label = "" },
}

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function Fmt(n, decimals)
    return string.format(decimals and ("%." .. decimals .. "f") or "%d", n)
end

local function AcquireRow()
    local row = table.remove(rowPool)
    if not row then
        row = CreateFrame("Frame", nil, tablePane)
        row:SetSize(WIDTH - 60, 16)
        row.cells = {}
        for _, col in ipairs(COLS) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
            fs:SetWidth(col.w)
            fs:SetJustifyH("LEFT")
            row.cells[col.key] = fs
        end
    end
    row:Show()
    usedRows[#usedRows + 1] = row
    return row
end

local function ReleaseRows()
    for _, row in ipairs(usedRows) do
        row:Hide()
        rowPool[#rowPool + 1] = row
    end
    wipe(usedRows)
end

-- ElvUI look: stock button textures stripped, flat 0.1-grey backdrop with a
-- 1px black border, centred text; active tab = lighter backdrop + gold text.
local FLAT = "Interface\\Buttons\\WHITE8x8"
local FLAT_BACKDROP = { bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 }
local TAB_BG, TAB_BG_HOVER, TAB_BG_ACTIVE = 0.1, 0.18, 0.22

local function TabButton(parent, label, width, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width, 22)
    btn:SetBackdrop(FLAT_BACKDROP)
    btn:SetBackdropColor(TAB_BG, TAB_BG, TAB_BG, 1)
    btn:SetBackdropBorderColor(0, 0, 0, 1)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("CENTER")
    btn.text:SetText(label)
    btn.label = label
    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self)
        if not self.active then self:SetBackdropColor(TAB_BG_HOVER, TAB_BG_HOVER, TAB_BG_HOVER, 1) end
    end)
    btn:SetScript("OnLeave", function(self)
        if not self.active then self:SetBackdropColor(TAB_BG, TAB_BG, TAB_BG, 1) end
    end)
    return btn
end

local function SetTabActive(btn, active)
    btn.active = active
    local bg = active and TAB_BG_ACTIVE or TAB_BG
    btn:SetBackdropColor(bg, bg, bg, 1)
    btn.text:SetText(active and ("|cffffcc00" .. btn.label .. "|r") or btn.label)
end

--------------------------------------------------------------------------------
-- refresh
--------------------------------------------------------------------------------
local Refresh -- forward declaration

local function SelectView(view, family)
    currentView = view
    if family then currentFamily = family end
    Refresh()
end

Refresh = function()
    if not frame or not frame:IsShown() then return end
    ReleaseRows()

    -- tab highlight states
    SetTabActive(classTabs.class, currentView == "spell")
    SetTabActive(classTabs.settings, currentView == "settings")
    for fam, btn in pairs(spellTabs) do
        SetTabActive(btn, currentView == "spell" and currentFamily == fam)
    end

    local inSpellView = currentView == "spell"
    spellTabsRow:SetShown(inSpellView and MD.player.isDruid)
    settingsPane:SetShown(currentView == "settings")
    tablePane:SetShown(inSpellView)
    statsFS:SetShown(inSpellView)
    calloutFS:SetShown(inSpellView)
    messageFS:SetShown(false)

    if currentView == "settings" then
        -- checkbox/slider states are synced by their own OnShow handlers
        settingsPane:Hide()
        settingsPane:Show()
        return
    end

    -- overall info line (the part the author liked): current regen state
    local RM = MD.Regen
    local bonus = 0
    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        if ok then bonus = v or 0 end
    end
    local spiritPerSec, mp5Gear = RM:Components()
    statsFS:SetFormattedText(
        "+%d healing   regen |cff33ff66%d|r mana/s out of 5SR, |cffffaa33%d|r casting   ~%d mp5 from spirit, ~%d mp5 gear/buffs",
        bonus, RM.base, RM.casting, spiritPerSec * 5, mp5Gear)

    if not MD.player.isDruid then
        messageFS:SetShown(true)
        messageFS:SetText("Rank analysis is Druid-only in v1 — the OOM widget, datatext and advisor still work for your class.")
        calloutFS:SetText("")
        return
    end

    local results = MD.RankMath:Compute()
    local res = results[currentFamily]
    if not res then
        calloutFS:SetText("")
        return
    end

    local tolNote = (MD:InTreeForm() and not res.tol) and "  |cffff4444(not castable in Tree form)|r" or ""
    calloutFS:SetText("|cffffcc00" .. (res.callout or "") .. "|r" .. tolNote)

    local y = -4
    local header = AcquireRow()
    header:SetPoint("TOPLEFT", tablePane, "TOPLEFT", 0, y)
    for _, col in ipairs(COLS) do
        header.cells[col.key]:SetText("|cff888888" .. col.label .. "|r")
    end
    y = y - 18

    for _, r in ipairs(res.rows) do
        local row = AcquireRow()
        row:SetPoint("TOPLEFT", tablePane, "TOPLEFT", 0, y)
        local c
        if not r.known then
            c = "|cff555555"
        elseif r.suggested then
            c = "|cffffcc00"
        elseif r.dominated then
            c = "|cff8a8a8a"
        else
            c = "|cffffffff"
        end
        row.cells.rank:SetText(c .. (r.rankLabel or ("R" .. r.rank)) .. (r.suggested and " *" or "") .. "|r")
        row.cells.level:SetText(c .. r.level .. "|r")
        row.cells.cost:SetText(c .. Fmt(r.cost) .. "|r")
        row.cells.heal:SetText(c .. Fmt(r.heal) .. "|r")
        row.cells.hpm:SetText(c .. Fmt(r.hpm, 2) .. "|r")
        row.cells.hps:SetText(c .. Fmt(r.hps) .. "|r")
        row.cells.cast:SetText(c .. Fmt(r.cast, 1) .. "s|r")
        local note
        if not r.known then
            note = "|cff555555not learned|r"
        elseif r.virtual then
            note = "|cff888888rolling stack (6 ticks, no bloom)|r"
        elseif r.suggested and r.isMax then
            note = "|cffffcc00efficient + max rank|r"
        elseif r.suggested then
            note = "|cffffcc00efficient rank|r"
        elseif r.isMax then
            note = "|cff888888max rank|r"
        elseif r.dominated then
            note = "|cff5a5a5adominated|r"
        else
            note = ""
        end
        row.cells.note:SetText(note)
        y = y - 16
    end

    -- recap
    local last = MD.fightHistory and MD.fightHistory[#MD.fightHistory]
    if last then
        recapFS:SetText("Last fight: " .. (last.summary or "-") ..
            (#MD.fightHistory > 1 and ("  |cff666666(" .. #MD.fightHistory .. " fights this session)|r") or ""))
    else
        recapFS:SetText("|cff666666No fights recorded this session yet.|r")
    end
end

--------------------------------------------------------------------------------
-- settings pane
--------------------------------------------------------------------------------
local function AddCheckbox(name, label, y, get, set)
    local cb = CreateFrame("CheckButton", name, settingsPane, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", settingsPane, "TOPLEFT", 8, y)
    local textFS = _G[name .. "Text"]
    if textFS then
        textFS:SetText(label)
        textFS:SetFontObject("GameFontHighlight")
    end
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return cb
end

local function BuildSettingsPane()
    settingsPane = CreateFrame("Frame", nil, frame)
    settingsPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -70)
    settingsPane:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 44)
    settingsPane:Hide()

    AddCheckbox("ManaDemonCBMute", "Mute alerts (advisor, toasts)", -6,
        function() return MD.db.muted end,
        function(v) MD.db.muted = v end)

    AddCheckbox("ManaDemonCBDrink", "Drink reminder out of combat", -36,
        function() return MD.db.drinkReminder end,
        function(v) MD.db.drinkReminder = v end)

    AddCheckbox("ManaDemonCBLock", "Lock the OOM widget (uncheck to drag it)", -66,
        function() return MD.db.locked end,
        function(v)
            MD.db.locked = v
            MD:UpdateVisibility()
        end)

    AddCheckbox("ManaDemonCBMinimap", "Show minimap button", -96,
        function() return not MD.db.minimap.hide end,
        function(v)
            MD.db.minimap.hide = not v
            if MD.UpdateMinimapButton then MD:UpdateMinimapButton() end
        end)

    AddCheckbox("ManaDemonCBRest", "Show 'rest' next to the OOM clock (time to full if you stop casting)", -126,
        function() return MD.db.showRest end,
        function(v) MD.db.showRest = v end)

    local resetBtn = TabButton(settingsPane, "Reset widget position", 170, function()
        MD.db.pos = { "CENTER", "CENTER", 0, -140 }
        MD:ApplyWidgetPosition()
        MD:Print("widget position reset.")
    end)
    resetBtn:SetPoint("TOPLEFT", settingsPane, "TOPLEFT", 12, -164)

    local slider = CreateFrame("Slider", "ManaDemonSliderHalfLife", settingsPane, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", settingsPane, "TOPLEFT", 14, -220)
    slider:SetWidth(220)
    slider:SetMinMaxValues(5, 60)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    _G["ManaDemonSliderHalfLifeLow"]:SetText("5s")
    _G["ManaDemonSliderHalfLifeHigh"]:SetText("60s")
    local sliderLabel = _G["ManaDemonSliderHalfLifeText"]
    slider:SetScript("OnShow", function(self)
        self:SetValue(MD.db.halfLife)
        sliderLabel:SetText("Spend window half-life: " .. MD.db.halfLife .. "s")
    end)
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        MD.db.halfLife = value
        sliderLabel:SetText("Spend window half-life: " .. value .. "s")
    end)

    local hint = settingsPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", settingsPane, "TOPLEFT", 12, -270)
    hint:SetJustifyH("LEFT")
    hint:SetWidth(WIDTH - 80)
    hint:SetText("|cff888888Shorter half-life reacts faster to your casting, longer is steadier.\n" ..
        "Everything here is also available as slash commands — /md help.\n" ..
        "/md verify checks the spell data against your client; /md fsrtest logs mana ticks.|r")
end

--------------------------------------------------------------------------------
-- frame construction
--------------------------------------------------------------------------------
local function CreateDashboard()
    frame = CreateFrame("Frame", "ManaDemonDashboard", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    -- ElvUI-style flat panel: near-opaque dark backdrop, 1px black border.
    frame:SetBackdrop(FLAT_BACKDROP)
    frame:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("HIGH")
    frame:Hide()
    tinsert(UISpecialFrames, "ManaDemonDashboard") -- ESC closes

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -14)
    title:SetText("|cff9966ffManaDemon|r")

    local close = TabButton(frame, "x", 22, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

    -- class tab row: the player's class (only Druid has rank data) + Settings
    local classLabel = MD.player.isDruid and "Druid"
        or (UnitClass("player") or "Class")
    classTabs.class = TabButton(frame, classLabel, 90, function() SelectView("spell") end)
    classTabs.class:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -36)
    classTabs.settings = TabButton(frame, "Settings", 90, function() SelectView("settings") end)
    classTabs.settings:SetPoint("LEFT", classTabs.class, "RIGHT", 6, 0)

    -- spell subtab row
    spellTabsRow = CreateFrame("Frame", nil, frame)
    spellTabsRow:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -62)
    spellTabsRow:SetSize(WIDTH - 32, 24)
    local prev
    for _, family in ipairs(MD.SpellData.familyOrder) do
        local info = MD.SpellData.families[family]
        if info and not info.exclude then
            local btn = TabButton(spellTabsRow, info.label, 110, function()
                SelectView("spell", family)
            end)
            if prev then
                btn:SetPoint("LEFT", prev, "RIGHT", 4, 0)
            else
                btn:SetPoint("LEFT", spellTabsRow, "LEFT", 0, 0)
            end
            spellTabs[family] = btn
            prev = btn
        end
    end

    statsFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statsFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -94)
    statsFS:SetJustifyH("LEFT")
    statsFS:SetWidth(WIDTH - 44)

    calloutFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    calloutFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -112)
    calloutFS:SetJustifyH("LEFT")
    calloutFS:SetWidth(WIDTH - 44)

    messageFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -140)
    messageFS:SetJustifyH("LEFT")
    messageFS:SetWidth(WIDTH - 44)
    messageFS:Hide()

    tablePane = CreateFrame("Frame", nil, frame)
    tablePane:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -132)
    tablePane:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 44)

    recapFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    recapFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 20)
    recapFS:SetJustifyH("LEFT")
    recapFS:SetWidth(WIDTH - 40)

    BuildSettingsPane()

    frame:SetScript("OnShow", Refresh)
end

function MD:ToggleDashboard()
    if not frame then return end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function MD:OpenDashboardSettings()
    if not frame then return end
    currentView = "settings"
    if frame:IsShown() then Refresh() else frame:Show() end
end

MD:RegisterCallback("MD_READY", CreateDashboard)
MD:RegisterCallback("TALENTS_CHANGED", Refresh)
MD:RegisterCallback("SPELLS_REBUILT", Refresh)
MD:RegisterCallback("FIGHT_RECORDED", Refresh)
MD:On("PLAYER_EQUIPMENT_CHANGED", function()
    if frame and frame:IsShown() then Refresh() end
end)
