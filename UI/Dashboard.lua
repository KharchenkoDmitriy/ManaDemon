-- Rank dashboard (/md): a Cell-style movable frame (header bar with title and
-- close), a row of spell tabs, and per spell a table of ALL ranks (unlearned
-- ranks dimmed) with tooltip-style columns: heal per cast, mana, HPM, HPS,
-- cast. Settings moved to the options frame (UI/OptionsFrame.lua).
local _, MD = ...
local UI = MD.UI

local WIDTH, HEIGHT = 760, 496
local frame, statsFS, calloutFS, hintFS, recapFS, messageFS, tablePane
local simBoxes = {}   -- key -> { eb, label, fmt }
local currentFamily = "HealingTouch"
local spellTabs, highlightTab = {}, nil
local rowPool, usedRows = {}, {}

local COLS = {
    { key = "rank",  x = 12,  w = 46,  label = "Rank" },
    { key = "level", x = 62,  w = 40,  label = "Lvl" },
    { key = "cost",  x = 106, w = 60,  label = "Mana" },
    { key = "heal",  x = 170, w = 86,  label = "Heal/cast" },
    { key = "hpm",   x = 260, w = 64,  label = "HPM" },
    { key = "hps",   x = 328, w = 64,  label = "HPS" },
    { key = "hp5",   x = 396, w = 64,  label = "HP5" },
    { key = "cast",  x = 464, w = 50,  label = "Cast" },
    { key = "casts", x = 518, w = 56,  label = "To OOM" },
    { key = "note",  x = 578, w = 160, label = "" },
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

--------------------------------------------------------------------------------
-- refresh
--------------------------------------------------------------------------------
local function Refresh()
    if not frame or not frame:IsShown() then return end
    ReleaseRows()
    messageFS:Hide()

    -- overall info line: current regen state
    local RM = MD.Regen
    local bonus = 0
    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        if ok then bonus = v or 0 end
    end
    local spiritPerSec, mp5Gear, _, unreported = RM:Components()
    statsFS:SetFormattedText(
        "+%d healing   regen |cff33ff66%d|r mana/s out of 5SR, |cffffaa33%d|r casting   ~%d mp5 spirit, ~%d mp5 gear/buffs%s",
        bonus, RM.base, RM.casting, spiritPerSec * 5, mp5Gear,
        unreported > 0 and string.format(", +%d mp5 Dreamstate (not in the API)", unreported * 5 + 0.5) or "")

    if not MD.player.isDruid then
        messageFS:Show()
        messageFS:SetText("Rank analysis is Druid-only in v1 - the OOM widget, datatext and advisor still work for your class.")
        calloutFS:SetText("")
        return
    end

    if highlightTab then highlightTab(currentFamily) end

    local results = MD.RankMath:Compute()
    local info = MD.RankMath.info
    if info then
        for key, box in pairs(simBoxes) do
            box.ph:SetText(string.format(box.fmt, info.live[key]))
        end
        if info.simulated then
            statsFS:SetText("|cffff9933SIMULATION|r  " .. statsFS:GetText())
        end
    end
    if info and info.treeAura > 0 then
        statsFS:SetText((statsFS:GetText():gsub("^%+%d+ healing",
            string.format("+%d healing (+%d Tree of Life aura on party targets)", info.statBonus, info.treeAura))))
    elseif info and info.inTree then
        statsFS:SetText((statsFS:GetText():gsub("^%+%d+ healing", "%0 (Tree aura not counted - see Settings)")))
    end
    if info then
        hintFS:SetFormattedText("|cff888888HPM = heal per mana.  HPS = heal per second of cast time (1.5s GCD for instants).  " ..
            "HP5 = healing per 5s you can sustain at zero mana, casting only as regen pays (5SR-aware, %d / %d mp5 casting / resting).  " ..
            "To OOM = chain-casts from your current %d mana.|r",
            info.castingRegen * 5 + 0.5, info.baseRegen * 5 + 0.5, info.mana)
    end
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
        row.cells.hp5:SetText(c .. (r.hp5 and Fmt(r.hp5) or "-") .. "|r")
        row.cells.cast:SetText(c .. Fmt(r.cast, 1) .. "s|r")
        row.cells.casts:SetText(c .. (r.casts == math.huge and "inf" or Fmt(r.casts)) .. "|r")
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
-- frame construction
--------------------------------------------------------------------------------
local function CreateDashboard()
    frame = UI.CreateMovableFrame("ManaDemon", "ManaDemonDashboard", WIDTH, HEIGHT, "HIGH", 1, true)
    UI.StylizeFrame(frame, { 0.1, 0.1, 0.1, 0.95 })
    tinsert(UISpecialFrames, "ManaDemonDashboard") -- ESC closes

    -- spell tab row (druid only) + Settings on the right
    local prev
    local buttons = {}
    for _, family in ipairs(MD.SpellData.familyOrder) do
        local info = MD.SpellData.families[family]
        if info and not info.exclude then
            local btn = UI.CreateButton(frame, info.label, "accent-hover", { 110, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
            btn.id = family
            if prev then
                btn:SetPoint("LEFT", prev, "RIGHT", -1, 0)
            else
                btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
            end
            spellTabs[family] = btn
            buttons[#buttons + 1] = btn
            prev = btn
            btn:SetShown(MD.player.isDruid)
        end
    end
    highlightTab = UI.CreateButtonGroup(buttons, function(id)
        currentFamily = id
        Refresh()
    end)

    local settingsBtn = UI.CreateButton(frame, "Settings", "accent-hover", { 90, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
    settingsBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
    settingsBtn:SetScript("OnClick", function() MD:ShowOptionsFrame("general") end)

    -- Simulate strip: blank box = live value (shown in the label).
    local simTitle = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    simTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -42)
    simTitle:SetTextColor(UI.accent[1], UI.accent[2], UI.accent[3])
    simTitle:SetText("Simulate:")
    -- Box shows the live value as a grey placeholder while empty.
    local function AddSimBox(key, labelText, phFmt, anchor)
        local label = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        label:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
        label:SetTextColor(0.7, 0.7, 0.7)
        label:SetText(labelText)
        local eb = UI.CreateEditBox(frame, 56, 16, false, false, false, UI.FONT_SMALL)
        eb:SetPoint("LEFT", label, "RIGHT", 4, 0)
        eb:SetTextInsets(3, 3, 0, 0)
        local ph = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        ph:SetPoint("LEFT", eb, "LEFT", 4, 0)
        ph:SetTextColor(0.45, 0.45, 0.45)
        local function Apply(self)
            local text = strtrim(self:GetText() or "")
            if text == "" then
                MD.sim[key] = nil
            else
                local v = tonumber(text)
                if v then
                    MD.sim[key] = v
                else
                    self:SetText(MD.sim[key] and tostring(MD.sim[key]) or "")
                end
            end
            ph:SetShown(strtrim(self:GetText() or "") == "")
            self:HighlightText(0, 0)
            Refresh()
        end
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEditFocusGained", function() ph:Hide() end)
        eb:SetScript("OnEditFocusLost", Apply)
        simBoxes[key] = { eb = eb, ph = ph, fmt = phFmt }
        return eb
    end
    local last = AddSimBox("heal", "+heal", "%d", simTitle)
    last = AddSimBox("crit", "crit%", "%.1f", last)
    last = AddSimBox("casting", "casting mp5", "%d", last)
    last = AddSimBox("base", "resting mp5", "%d", last)
    last = AddSimBox("mana", "mana", "%d", last)
    local clearBtn = UI.CreateButton(frame, "Clear", "red-hover", { 50, 16 }, false, false, UI.FONT_SMALL, nil,
        "Clear simulation", "Back to your live stats.")
    clearBtn:SetPoint("LEFT", last, "RIGHT", 10, 0)
    clearBtn:SetScript("OnClick", function()
        wipe(MD.sim)
        for _, box in pairs(simBoxes) do box.eb:SetText(""); box.ph:Show() end
        Refresh()
    end)

    statsFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statsFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -68)
    statsFS:SetJustifyH("LEFT")
    statsFS:SetWidth(WIDTH - 32)

    calloutFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    calloutFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -86)
    calloutFS:SetJustifyH("LEFT")
    calloutFS:SetWidth(WIDTH - 32)

    hintFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hintFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -102)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetWidth(WIDTH - 32)

    messageFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -126)
    messageFS:SetJustifyH("LEFT")
    messageFS:SetWidth(WIDTH - 32)
    messageFS:Hide()

    tablePane = CreateFrame("Frame", nil, frame)
    tablePane:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -120)
    tablePane:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 40)

    recapFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    recapFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
    recapFS:SetJustifyH("LEFT")
    recapFS:SetWidth(WIDTH - 32)

    frame:SetScript("OnShow", Refresh)

    -- The "To OOM" column follows your current mana: re-render every 2s while
    -- the frame is open (rendering only; the model is event-driven).
    local acc = 0
    MD:OnTick(function(dt)
        if not frame:IsShown() then return end
        acc = acc + dt
        if acc >= 2 then
            acc = 0
            Refresh()
        end
    end)
end

function MD:ToggleDashboard()
    if not frame then return end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- Kept for the minimap button's right-click.
function MD:OpenDashboardSettings()
    MD:ShowOptionsFrame("general")
end

MD:RegisterCallback("MD_READY", CreateDashboard)
MD:RegisterCallback("TALENTS_CHANGED", Refresh)
MD:RegisterCallback("SPELLS_REBUILT", Refresh)
MD:RegisterCallback("FIGHT_RECORDED", Refresh)
MD:RegisterCallback("FORM_CHANGED", Refresh) -- Tree of Life: costs and aura change
MD:On("PLAYER_EQUIPMENT_CHANGED", function()
    if frame and frame:IsShown() then Refresh() end
end)
