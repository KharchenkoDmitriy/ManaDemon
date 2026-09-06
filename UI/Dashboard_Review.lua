-- The Review tab (docs/SPEC-v0.7.md 8): the fights this character recorded, what
-- the engine can and cannot reproduce about each, and -- for the ones it can --
-- what a better plan would have done.
--
-- The validate column is the point of the tab. A fight the engine cannot
-- reproduce is shown greyed with the number that failed, and its Coach button
-- is disabled with the reason on it. Nothing is hidden and nothing is guessed:
-- if the model cannot replay a pull, saying so is more useful than a card.
--
-- Class-agnostic for listing (the stream is just numbers); Coach needs the
-- druid spell kit.
local _, MD = ...
local UI = MD.UI

MD.DashboardParts = MD.DashboardParts or {}

local ROW_HEIGHT = 16
local COLS = {
    { "n",      0,   22,  "#" },
    { "when",   22,  110, "when" },
    { "zone",   132, 150, "zone" },
    { "dur",    282, 46,  "dur" },
    { "tgts",   328, 40,  "tgts" },
    { "casts",  368, 48,  "casts" },
    { "spent",  416, 56,  "spent" },
    { "low",    472, 66,  "low mana" },
    { "valid",  538, 190, "validate" },
}

local function K(n)
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return string.format("%d", n + 0.5)
end
local function Clock(s) return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60)) end

-- The fight's mana low-water mark, read back out of the recorded samples: the
-- stream is the record, so nothing needs to be stored twice.
local function LowestMana(rec)
    local pool = rec.pool or 0
    if pool <= 0 then return 0 end
    local low = nil
    for _, v in ipairs(rec.mana and rec.mana.v or {}) do
        if not low or v < low then low = v end
    end
    return (low or pool) / pool
end

local function When(id)
    if not id then return "?" end
    local days = math.floor((time() - id) / 86400)
    local hm = date and date("%H:%M", id) or "?"
    if days <= 0 then return "today " .. hm end
    if days == 1 then return "yesterday " .. hm end
    return (date and date("%d %b %H:%M", id)) or hm
end

function MD.DashboardParts.CreateReview(parent, width)
    local pane = CreateFrame("Frame", nil, parent)
    pane:Hide()
    local rowPool, usedRows = {}, {}
    local selected = 1
    local cache = {}     -- recording id -> validation result (validating is not cheap)
    local api = { frame = pane }

    local habitsFS = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    habitsFS:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 12, 20)
    habitsFS:SetJustifyH("LEFT")
    habitsFS:SetWidth(width - 60)

    local progressFS = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progressFS:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 12, 4)
    progressFS:SetJustifyH("LEFT")
    progressFS:SetWidth(width - 60)

    local validateBtn = UI.CreateButton(pane, "Validate", "accent-hover", { 72, 18 }, false, false,
        UI.FONT_SMALL, UI.FONT_SMALL, "Replay this fight through the engine",
        "Runs the eight gates and shows what matched and what did not.")
    local coachBtn = UI.CreateButton(pane, "Coach", "accent-hover", { 60, 18 }, false, false,
        UI.FONT_SMALL, UI.FONT_SMALL)
    local pinBtn = UI.CreateButton(pane, "Pin", "accent-hover", { 44, 18 }, false, false,
        UI.FONT_SMALL, UI.FONT_SMALL, "Keep this recording",
        "Pinned fights are never replaced (at most two).")
    local exportBtn = UI.CreateButton(pane, "Export", "accent-hover", { 60, 18 }, false, false,
        UI.FONT_SMALL, UI.FONT_SMALL, "Copy every recording as text", "Same as /md export.")

    exportBtn:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -12, 40)
    pinBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
    coachBtn:SetPoint("RIGHT", pinBtn, "LEFT", -4, 0)
    validateBtn:SetPoint("RIGHT", coachBtn, "LEFT", -4, 0)

    local function Selected()
        return MD.FightRecorder and MD.FightRecorder:Get(selected)
    end

    local function Validation(rec, force)
        if not rec then return nil end
        if cache[rec.id] and not force then return cache[rec.id] end
        if not (MD.SimModel and MD.RankMath) then return nil end
        cache[rec.id] = MD.SimModel:Validate(rec)
        return cache[rec.id]
    end

    validateBtn:SetScript("OnClick", function()
        local rec = Selected()
        if not rec then return end
        Validation(rec, true)
        for _, line in ipairs(MD:ValidationReport(rec, selected)) do MD:Print(line) end
        api:Render()
    end)
    coachBtn:SetScript("OnClick", function()
        if MD.RunCoach then MD:RunCoach(tostring(selected)) end
    end)
    pinBtn:SetScript("OnClick", function()
        local rec = Selected()
        if not rec then return end
        rec.pinned = not rec.pinned
        api:Render()
    end)
    exportBtn:SetScript("OnClick", function() if MD.RunExport then MD:RunExport() end end)

    local function AcquireRow()
        local row = table.remove(rowPool)
        if not row then
            row = CreateFrame("Button", nil, pane)
            row:SetSize(width - 60, ROW_HEIGHT)
            row.cells = {}
            for _, col in ipairs(COLS) do
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetJustifyH("LEFT")
                fs:SetPoint("LEFT", row, "LEFT", col[2], 0)
                fs:SetWidth(col[3])
                row.cells[col[1]] = fs
            end
            row.highlight = row:CreateTexture(nil, "BACKGROUND")
            row.highlight:SetAllPoints()
            row.highlight:SetColorTexture(1, 1, 1, 0.06)
            row.highlight:Hide()
        end
        row:Show()
        usedRows[#usedRows + 1] = row
        return row
    end

    function api:Release()
        for _, row in ipairs(usedRows) do row:Hide(); rowPool[#rowPool + 1] = row end
        wipe(usedRows)
    end

    -- The one line that says whether a fight is usable, and why not when it is
    -- not. The first failing gate wins: a healer does not need five reasons.
    local function ValidateCell(v)
        if not v then return "|cff888888not checked|r", false end
        if v.ok then return "|cff99dd99ok|r", true end
        for _, g in ipairs(v.gates) do
            if not g.ok then
                local short = g.text:match("^([^%(]+)")
                return "|cffff9966" .. g.name .. ": " .. (short or g.text):gsub("%s+$", "") .. "|r", false
            end
        end
        return "|cffff9966failed|r", false
    end

    -- Habits: the same labels the summaries have carried since v0.7.0, summed
    -- over every recorded fight. `ok` is never a habit.
    local function Habits()
        local mana, casts = {}, {}
        local n = 0
        for _, f in ipairs(MD.fightHistory or {}) do
            if f.labels then
                n = n + 1
                for k, v in pairs(f.labels) do
                    if k ~= "ok" then
                        mana[k] = (mana[k] or 0) + v
                        casts[k] = (casts[k] or 0) + ((f.labelCasts and f.labelCasts[k]) or 0)
                    end
                end
            end
        end
        if n == 0 then return nil end
        local list = {}
        for k, v in pairs(mana) do if v > 0 then list[#list + 1] = { k, v } end end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(3, #list) do
            parts[#parts + 1] = string.format("%s %d casts %s", list[i][1], casts[list[i][1]] or 0, K(list[i][2]))
        end
        if #parts == 0 then return nil end
        return string.format("Habits over the last %d fights:  %s", n, table.concat(parts, "   "))
    end

    function api:Render()
        if not pane:IsShown() then return end
        api:Release()

        local list = MD.FightRecorder and MD.FightRecorder:List() or {}
        if selected > #list then selected = math.max(1, #list) end

        local y = -6
        local header = AcquireRow()
        header:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        header:EnableMouse(false)
        for _, col in ipairs(COLS) do header.cells[col[1]]:SetText("|cff888888" .. col[4] .. "|r") end
        y = y - 18

        if #list == 0 then
            local row = AcquireRow()
            row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
            row.cells.when:SetText("|cff888888No recorded fights yet - pull something for 20s.|r")
            row.cells.when:SetWidth(width - 80)
        end

        for i, rec in ipairs(list) do
            if y < -(pane:GetHeight() - 70) then break end
            local row = AcquireRow()
            row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
            row.highlight:SetShown(i == selected)
            row:EnableMouse(true)
            row.recIndex = i
            row:SetScript("OnClick", function(self) selected = self.recIndex; api:Render() end)

            local v = cache[rec.id]
            local cell, ok = ValidateCell(v)
            local c = (v and not ok) and "|cffbbbbbb" or "|cffffffff"
            row.cells.n:SetText(c .. i .. (rec.pinned and "*" or "") .. "|r")
            row.cells.when:SetText(c .. When(rec.id) .. "|r")
            row.cells.zone:SetText(c .. (rec.zone or "?") .. "|r")
            row.cells.dur:SetText(c .. Clock(rec.dur or 0) .. "|r")
            row.cells.tgts:SetText(c .. #(rec.tracked or {}) .. "|r")
            row.cells.casts:SetText(c .. (rec.ownCasts or 0) .. "|r")
            row.cells.spent:SetText(c .. K(rec.spent or 0) .. "|r")
            row.cells.low:SetText(c .. string.format("%d%%", LowestMana(rec) * 100 + 0.5) .. "|r")
            row.cells.valid:SetText(cell)

            row:SetScript("OnEnter", function(self)
                local tip = MD.Tip
                if not tip then return end
                local lines = {}
                lines[#lines + 1] = { l = rec.zone or "?", r = When(rec.id) }
                lines[#lines + 1] = { l = "foreign healing",
                    r = string.format("%d%%", (rec.foreignShare or 0) * 100 + 0.5) }
                if rec.truncated then
                    lines[#lines + 1] = { l = "|cffff9966stream truncated|r", r = "over 4000 events" }
                end
                if v then
                    for _, g in ipairs(v.gates) do
                        lines[#lines + 1] = { l = (g.ok and "|cff99dd99" or "|cffff9966") .. g.name .. "|r",
                                              r = g.text }
                    end
                    for idx, why in pairs(v.excluded) do
                        lines[#lines + 1] = { l = "  excluded " .. ((rec.roster[idx] and rec.roster[idx].name) or idx),
                                              r = why }
                    end
                else
                    lines[#lines + 1] = { l = "|cff888888press Validate to replay this fight|r", r = "" }
                end
                tip:Show(self, "ANCHOR_RIGHT", lines)
            end)
            row:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)
            y = y - ROW_HEIGHT
        end

        -- buttons follow the selection
        local rec = Selected()
        local v = rec and cache[rec.id]
        pinBtn:SetText(rec and rec.pinned and "Unpin" or "Pin")
        -- Enable/Disable rather than SetEnabled: the older call exists on every
        -- client this addon targets.
        local function Set(btn, on) if on then btn:Enable() else btn:Disable() end end
        Set(pinBtn, rec ~= nil)
        Set(validateBtn, rec ~= nil)
        Set(exportBtn, #list > 0)
        Set(coachBtn, rec ~= nil and MD.player.isDruid and not (v and not v.ok))
        coachBtn:SetScript("OnEnter", function(self)
            if not MD.Tip then return end
            local lines = { { l = "Coach", r = "" } }
            if not MD.player.isDruid then
                lines[#lines + 1] = { l = "|cff888888Coaching is Druid-only in v1.|r", r = "" }
            elseif v and not v.ok then
                lines[#lines + 1] = { l = "|cffff9966This fight does not replay, so nothing would be", r = "" }
                lines[#lines + 1] = { l = "|cffff9966suggested from it.|r", r = "" }
                for _, g in ipairs(v.gates) do
                    if not g.ok then lines[#lines + 1] = { l = "  " .. g.name, r = g.text } end
                end
            elseif not v then
                lines[#lines + 1] = { l = "|cff888888Validate first, or press Coach to do both.|r", r = "" }
            else
                lines[#lines + 1] = { l = "Search for a better plan and print the card.", r = "" }
                lines[#lines + 1] = { l = "|cff888888Runs across frames; /md coach cancel stops it.|r", r = "" }
            end
            MD.Tip:Show(self, "ANCHOR_RIGHT", lines)
        end)
        coachBtn:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)

        habitsFS:SetText(Habits() or "|cff888888Habits appear once a few fights have been summarised.|r")
        local zone = GetRealZoneText and GetRealZoneText() or nil
        local prog = MD.SimPlanner and zone and MD.SimPlanner.Progress(zone)
        progressFS:SetText(prog and ("|cff99dd99" .. prog .. "|r") or "")
    end

    return api
end
