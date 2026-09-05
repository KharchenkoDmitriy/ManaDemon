-- Debug console (Cell-style): MD:Debug() lines land in an in-memory ring,
-- shown in a movable window with per-category filters, and exported through
-- a "Copy" popup (select-all edit box, Ctrl+C). Logging is off unless the
-- "Enable Debug Logging" box is ticked; nothing is persisted.
local _, MD = ...
local UI = MD.UI

local CATEGORY_ORDER = { "regen", "mana", "spend", "tto", "heal", "cast", "combat", "chat", "other" }
local CATEGORY_LABELS = {
    regen = "Regen", mana = "Mana", spend = "Spend", tto = "TTO", heal = "Heal",
    cast = "Cast", combat = "Combat", chat = "Chat", other = "Other",
}
local CATEGORY_COLORS = {
    regen = "|cff33ff66", mana = "|cff66aaff", spend = "|cffff9933", tto = "|cffffcc00",
    heal = "|cff66ff99", cast = "|cffcc99ff", combat = "|cffff5555", chat = "|cffaaaaaa",
    other = "|cffcccccc",
}

-- Category filter grid: 5 per row at a fixed pitch wide enough for the
-- longest label ("Combat"), so adding a category grows a row instead of
-- overflowing the frame.
local CATEGORY_COLUMNS, CATEGORY_COL_W, CATEGORY_ROW_H = 5, 84, 20

local MIN_LINES, MAX_LINES, DEFAULT_LINES = 200, 20000, 1000
local VIEW_LINES = 300       -- rendered in the window (newest)

local function MaxLogLines()
    local n = MD.db and MD.db.debug and tonumber(MD.db.debug.maxLines) or DEFAULT_LINES
    if n < MIN_LINES then n = MIN_LINES elseif n > MAX_LINES then n = MAX_LINES end
    return n
end
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
    -- Trim in batches (drop the oldest 25% once the ring is a quarter over its
    -- size) so a 20k-line buffer never pays a per-line table.remove(1).
    local max = MaxLogLines()
    if #logLines > max * 1.25 then
        local keep = {}
        for i = #logLines - max + 1, #logLines do keep[#keep + 1] = logLines[i] end
        logLines = keep
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
-- Copy popup: a read-only scroll edit box holding plain text, pre-selected so
-- Ctrl+C just works. Public (MD:ShowCopyPopup) because /md profile hands the
-- author 40 lines of state and chat is the wrong place for that.
--------------------------------------------------------------------------------
local copyFrame, copyTextArea, copyTitle

function MD:ShowCopyPopup(title, text)
    if not copyFrame then
        copyFrame = UI.CreateMovableFrame("Copy", "ManaDemonDebugCopyFrame", 460, 340, "FULLSCREEN_DIALOG", 10, true)
        copyFrame:SetToplevel(true)
        copyTitle = copyFrame.header.text

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

    if copyTitle then copyTitle:SetText(title or "Copy") end
    copyFrame.text = text or ""
    copyTextArea.eb:SetText(copyFrame.text)
    copyTextArea.eb:SetCursorPosition(0)

    copyFrame:ClearAllPoints()
    copyFrame:SetPoint("CENTER")
    copyFrame:Show()
    copyTextArea.eb:SetFocus()
    copyTextArea.eb:HighlightText()
end

local function ShowLogCopyPopup()
    -- Every pasted log carries its own inputs: the first dungeon log could not
    -- say whether Nature's Grace was even talented, and the analysis had to
    -- infer it from a cast time.
    local text = BuildPlainTextLog()
    if MD.Snapshot then
        local head = { string.format("=== ManaDemon v%s  %s  %s level %d  %s ===", MD.version, MD.player.charKey,
            MD.player.class, MD.player.level, date("%Y-%m-%d %H:%M")) }
        for _, line in ipairs(MD:Snapshot()) do head[#head + 1] = line end
        head[#head + 1] = "--- log ---"
        text = table.concat(head, "\n") .. "\n" .. text
    end
    MD:ShowCopyPopup("Copy Debug Log", text)
end

--------------------------------------------------------------------------------
-- Console window
--------------------------------------------------------------------------------
local function CreateDebugConsoleFrame()
    consoleFrame = UI.CreateMovableFrame("ManaDemon Debug Console", "ManaDemonDebugConsole", 700, 560, "DIALOG", 1, true)
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
        logLines = {}
        RefreshLog()
    end)

    local copyBtn = UI.CreateButton(consoleFrame, "Copy", "accent-hover", { 60, 17 }, false, false, nil, nil,
        "Copy", "Opens a text box with the visible categories as plain text - Ctrl+C there.")
    copyBtn:SetPoint("RIGHT", clearBtn, "LEFT", -5, 0)
    copyBtn:SetScript("OnClick", ShowLogCopyPopup)

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

    -- Fixed grid, not a chained row: the labels are different widths, and
    -- chaining them ran the last category off the frame and under the "keep
    -- lines" box as soon as a ninth category (Cast) was added. Columns are a
    -- fixed pitch so they line up, and the row count follows the category
    -- count instead of being implied by the frame width.
    categoryCBs = {}
    for i, category in ipairs(CATEGORY_ORDER) do
        local cb = UI.CreateCheckButton(consoleFrame, CATEGORY_LABELS[category], function(checked)
            MD.db.debug.categories[category] = checked
            RefreshLog()
        end)
        local col = (i - 1) % CATEGORY_COLUMNS
        local row = math.floor((i - 1) / CATEGORY_COLUMNS)
        cb:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", col * CATEGORY_COL_W, -12 - row * CATEGORY_ROW_H)
        categoryCBs[category] = cb
    end

    countFS = consoleFrame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    countFS:SetPoint("RIGHT", regenBtn, "LEFT", -8, 0)
    countFS:SetTextColor(0.6, 0.6, 0.6)

    -- "keep N lines": ring size, saved in the settings
    local keepEB = UI.CreateEditBox(consoleFrame, 56, 16, false, false, true, UI.FONT_SMALL)
    keepEB:SetPoint("TOPRIGHT", -10, -37)
    keepEB:SetTextInsets(3, 3, 0, 0)
    local keepLabel = consoleFrame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    keepLabel:SetPoint("RIGHT", keepEB, "LEFT", -4, 0)
    keepLabel:SetTextColor(0.7, 0.7, 0.7)
    keepLabel:SetText("keep lines")
    UI.SetTooltips(keepEB, "ANCHOR_TOPLEFT", 0, 3, "Lines kept in memory",
        string.format("%d to %d (default %d). Copy exports all of them; the", MIN_LINES, MAX_LINES, DEFAULT_LINES),
        string.format("window shows the newest %d. A long fight with Mana on is ~3 lines/s.", VIEW_LINES))
    local function ApplyKeep(self)
        local n = tonumber(self:GetText())
        if n then
            if n < MIN_LINES then n = MIN_LINES elseif n > MAX_LINES then n = MAX_LINES end
            MD.db.debug.maxLines = n
        end
        self:SetText(tostring(MaxLogLines()))
        self:HighlightText(0, 0)
    end
    keepEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    keepEB:SetScript("OnEditFocusLost", ApplyKeep)
    consoleFrame.keepEB = keepEB

    local categoryRows = math.ceil(#CATEGORY_ORDER / CATEGORY_COLUMNS)
    UI.CreateScrollFrame(consoleFrame, -(46 + categoryRows * CATEGORY_ROW_H), 5)
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
        consoleFrame.keepEB:SetText(tostring(MaxLogLines()))
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
