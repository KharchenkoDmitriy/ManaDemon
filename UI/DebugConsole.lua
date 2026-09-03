-- Debug console (Cell-style): MD:Debug() lines land in an in-memory ring,
-- shown in a movable window with per-category filters, and exported through
-- a "Copy" popup (select-all edit box, Ctrl+C). Logging is off unless the
-- "Enable Debug Logging" box is ticked; nothing is persisted.
local _, MD = ...
local UI = MD.UI

local CATEGORY_ORDER = { "regen", "mana", "spend", "tto", "heal", "combat", "chat", "other" }
local CATEGORY_LABELS = {
    regen = "Regen", mana = "Mana", spend = "Spend", tto = "TTO", heal = "Heal",
    combat = "Combat", chat = "Chat", other = "Other",
}
local CATEGORY_COLORS = {
    regen = "|cff33ff66", mana = "|cff66aaff", spend = "|cffff9933", tto = "|cffffcc00",
    heal = "|cff66ff99", combat = "|cffff5555", chat = "|cffaaaaaa", other = "|cffcccccc",
}

local MAX_LOG_LINES = 1000   -- kept in memory (Copy exports all of them)
local VIEW_LINES = 300       -- rendered in the window (newest)
local logLines = {}
local sessionT0 = GetTime()

local consoleFrame, content, categoryCBs, enableCB, countFS
local dirty = false

local function Categories()
    return MD.db and MD.db.debug and MD.db.debug.categories or {}
end

-- Entry point used by MD:Debug (Core.lua). Timestamp = wall clock plus
-- seconds since load, so sub-second spacing (mana ticks, 5SR edges) is visible.
function MD:DebugLog(category, text)
    if not CATEGORY_LABELS[category] then category = "other" end
    local line = string.format("|cff888888%s +%.2f|r %s[%s]|r %s",
        date("%H:%M:%S"), GetTime() - sessionT0, CATEGORY_COLORS[category], category, tostring(text))
    logLines[#logLines + 1] = { category = category, text = line }
    if #logLines > MAX_LOG_LINES then
        table.remove(logLines, 1)
    end
    dirty = true
end

local function RefreshLog()
    dirty = false
    if not (consoleFrame and consoleFrame:IsShown()) then return end
    local shown = Categories()
    local newest, n = {}, 0
    for i = #logLines, 1, -1 do
        local e = logLines[i]
        if shown[e.category] ~= false then
            n = n + 1
            newest[n] = e.text
            if n >= VIEW_LINES then break end
        end
    end
    local ordered = {}
    for i = n, 1, -1 do ordered[#ordered + 1] = newest[i] end
    content:SetText(table.concat(ordered, "\n"))
    local h = math.max(content:GetStringHeight() + 10, 2)
    consoleFrame.scrollFrame:SetContentHeight(h)
    consoleFrame.scrollFrame:ScrollToBottom()
    countFS:SetText(string.format("%d line%s%s", #logLines, #logLines == 1 and "" or "s",
        n < #logLines and (" (" .. n .. " shown)") or ""))
end

local function StripColors(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function BuildPlainTextLog()
    local shown = Categories()
    local lines = {}
    for _, entry in ipairs(logLines) do
        if shown[entry.category] ~= false then
            lines[#lines + 1] = StripColors(entry.text)
        end
    end
    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Copy popup
--------------------------------------------------------------------------------
local copyFrame, copyTextArea

local function ShowCopyPopup()
    if not copyFrame then
        copyFrame = UI.CreateMovableFrame("Copy Debug Log", "ManaDemonDebugCopyFrame", 460, 340, "FULLSCREEN_DIALOG", 10, true)
        copyFrame:SetToplevel(true)

        local hint = copyFrame:CreateFontString(nil, "OVERLAY", UI.FONT)
        hint:SetPoint("TOPLEFT", 5, -5)
        hint:SetText("Ctrl+C to copy, then paste it wherever you need")

        copyTextArea = UI.CreateScrollEditBox(copyFrame)
        copyTextArea:SetPoint("TOPLEFT", 5, -22)
        copyTextArea:SetPoint("BOTTOMRIGHT", -5, 5)
        UI.StylizeFrame(copyTextArea.scrollFrame, { 0, 0, 0, 0 }, { UI.accent[1], UI.accent[2], UI.accent[3], 1 })

        copyTextArea.eb:SetScript("OnEditFocusGained", function() copyTextArea.eb:HighlightText() end)
        copyTextArea.eb:SetScript("OnMouseUp", function() copyTextArea.eb:HighlightText() end)
        copyTextArea.eb:SetScript("OnEditFocusLost", function() copyFrame:Hide() end)
        copyTextArea.eb:SetScript("OnEscapePressed", function() copyTextArea.eb:ClearFocus() end)
        -- read-only: any typed character restores the text
        copyTextArea.eb:SetScript("OnChar", function()
            copyTextArea.eb:SetText(copyFrame.text)
            copyTextArea.eb:HighlightText()
        end)
    end

    copyFrame.text = BuildPlainTextLog()
    copyTextArea.eb:SetText(copyFrame.text)
    copyTextArea.eb:SetCursorPosition(0)

    copyFrame:ClearAllPoints()
    copyFrame:SetPoint("CENTER")
    copyFrame:Show()
    copyTextArea.eb:SetFocus()
    copyTextArea.eb:HighlightText()
end

--------------------------------------------------------------------------------
-- Console window
--------------------------------------------------------------------------------
local function CreateDebugConsoleFrame()
    consoleFrame = UI.CreateMovableFrame("ManaDemon Debug Console", "ManaDemonDebugConsole", 580, 480, "DIALOG", 1, true)
    consoleFrame:SetToplevel(true)
    tinsert(UISpecialFrames, "ManaDemonDebugConsole")

    enableCB = UI.CreateCheckButton(consoleFrame, "Enable Debug Logging", function(checked)
        MD.db.debug.enabled = checked
        MD:Debug("other", "debug logging enabled (v%s, %s level %d, talents: %s)",
            MD.version, MD.player.class, MD.player.level, MD:TalentSummary())
        RefreshLog()
    end, "Enable Debug Logging", "Records regen / mana ticks / casts / clock state into this window (memory only, nothing is saved).", "Leave it off when you are not testing.")
    enableCB:SetPoint("TOPLEFT", 10, -12)

    local clearBtn = UI.CreateButton(consoleFrame, "Clear", "red-hover", { 60, 17 })
    clearBtn:SetPoint("TOPRIGHT", -10, -10)
    clearBtn:SetScript("OnClick", function()
        wipe(logLines)
        RefreshLog()
    end)

    local copyBtn = UI.CreateButton(consoleFrame, "Copy", "accent-hover", { 60, 17 }, false, false, nil, nil,
        "Copy", "Opens a text box with the visible categories as plain text - Ctrl+C there.")
    copyBtn:SetPoint("RIGHT", clearBtn, "LEFT", -5, 0)
    copyBtn:SetScript("OnClick", ShowCopyPopup)

    local regenBtn = UI.CreateButton(consoleFrame, "Regen test", "accent-hover", { 80, 17 }, false, false, nil, nil,
        "Regen test (30s)", "Stand idle at partial mana, no drink, no casting.",
        "Compares observed mana gain with GetManaRegen and says whether Dreamstate is included.")
    regenBtn:SetPoint("RIGHT", copyBtn, "LEFT", -5, 0)
    regenBtn:SetScript("OnClick", function()
        if not MD.db.debug.enabled then
            enableCB:SetChecked(true)
            enableCB.onClick(true, enableCB)
        end
        if MD.RunRegenTest then MD:RunRegenTest(30) end
    end)

    categoryCBs = {}
    local prevCB
    for _, category in ipairs(CATEGORY_ORDER) do
        local cb = UI.CreateCheckButton(consoleFrame, CATEGORY_LABELS[category], function(checked)
            MD.db.debug.categories[category] = checked
            RefreshLog()
        end)
        if prevCB then
            cb:SetPoint("LEFT", prevCB.label, "RIGHT", 12, 0)
        else
            cb:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -12)
        end
        categoryCBs[category] = cb
        prevCB = cb
    end

    countFS = consoleFrame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    countFS:SetPoint("RIGHT", regenBtn, "LEFT", -8, 0)
    countFS:SetTextColor(0.6, 0.6, 0.6)

    UI.CreateScrollFrame(consoleFrame, -60, 5)
    consoleFrame.scrollFrame:SetScrollStep(37)
    UI.StylizeFrame(consoleFrame.scrollFrame, { 0.1, 0.1, 0.1, 0.5 })

    content = consoleFrame.scrollFrame.content:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    content:SetPoint("TOPLEFT", 5, -5)
    content:SetWidth(consoleFrame:GetWidth() - 30)
    content:SetJustifyH("LEFT")
    content:SetJustifyV("TOP")
    content:SetSpacing(2)

    consoleFrame:SetScript("OnShow", function()
        enableCB:SetChecked(MD.db.debug.enabled)
        for category, cb in pairs(categoryCBs) do
            cb:SetChecked(MD.db.debug.categories[category] ~= false)
        end
        RefreshLog()
    end)

    -- Re-render at most 4x/s while shown (mana ticks can arrive in bursts).
    local acc = 0
    consoleFrame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc >= 0.25 then
            acc = 0
            if dirty then RefreshLog() end
        end
    end)
end

function MD:ToggleDebugConsole()
    if not consoleFrame then
        CreateDebugConsoleFrame()
    end
    if consoleFrame:IsShown() then
        consoleFrame:Hide()
    else
        consoleFrame:ClearAllPoints()
        consoleFrame:SetPoint("CENTER")
        consoleFrame:Show()
    end
end
