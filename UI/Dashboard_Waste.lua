-- The Waste view: where the mana went and where the healing was wasted, from
-- the combat log. Four groupings -- Spell (per event kind), Role, Class,
-- Target -- and two scopes: this session (undecayed, has targets) or all
-- persisted data (decayed, no targets). Exports a constructor on
-- MD.DashboardParts; UI/Dashboard.lua shows it when the "Waste" tab is up.
--
-- Mana belongs to the SPELL, not the target, so Casts / Mana only appear in
-- Spell mode. A role or target that was guessed rather than read carries a
-- marker: the number is still real, its label is not certain.
local _, MD = ...
local UI = MD.UI

MD.DashboardParts = MD.DashboardParts or {}

local ROW_HEIGHT = 16
local MODES = { { "spell", "Spell" }, { "role", "Role" }, { "class", "Class" }, { "target", "Target" } }

-- column sets per mode: { key, x, w, label, align }
local COLS = {
    spell = {
        { "label",  12,  150, "Spell" },        { "sub",    166, 52, "" },
        { "casts",  222, 50,  "Casts" },        { "mana",   276, 60, "Mana" },
        { "healed", 340, 70,  "Healing" },      { "frac",   414, 64, "Overheal" },
        { "waste",  482, 84,  "Wasted mana" },  { "wev",    570, 120, "Fully wasted" },
    },
    role = {
        { "label",  12,  110, "Role" },         { "healed", 126, 80, "Healing" },
        { "frac",   210, 64,  "Overheal" },     { "waste",  278, 84, "Wasted mana" },
        { "wev",    366, 90,  "Fully wasted" }, { "sub",    460, 260, "Targets" },
    },
    class = {
        { "label",  12,  110, "Class" },        { "healed", 126, 80, "Healing" },
        { "frac",   210, 64,  "Overheal" },     { "waste",  278, 84, "Wasted mana" },
        { "wev",    366, 90,  "Fully wasted" }, { "sub",    460, 260, "" },
    },
    target = {
        { "label",  12,  120, "Target" },       { "sub",    136, 110, "Class" },
        { "role",   250, 90,  "Role" },         { "healed", 344, 80, "Healing" },
        { "frac",   428, 64,  "Overheal" },     { "waste",  496, 84, "Wasted mana" },
        { "wev",    584, 130, "Fully wasted" },
    },
}
local ALL_KEYS = { "label", "sub", "casts", "mana", "healed", "frac", "waste", "wev", "role" }

local function Fmt(n) return string.format("%d", n + 0.5) end
local function Pct(f) return string.format("%.1f%%", f * 100) end
local function K(n) return n >= 10000 and string.format("%.1fk", n / 1000) or Fmt(n) end

function MD.DashboardParts.CreateWaste(parent, width)
    local pane = CreateFrame("Frame", nil, parent)
    pane:Hide()
    local rowPool, usedRows = {}, {}
    local mode, scope = "spell", "session"
    local api = { frame = pane }

    -- controls: by-mode group on the left, scope group on the right
    local byLabel = pane:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    byLabel:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -2)
    byLabel:SetTextColor(0.7, 0.7, 0.7)
    byLabel:SetText("by:")
    local modeBtns, prev = {}, nil
    for _, def in ipairs(MODES) do
        local b = UI.CreateButton(pane, def[2], "accent-hover", { 56, 16 }, false, false, UI.FONT_SMALL, nil)
        b.id = def[1]
        if prev then b:SetPoint("LEFT", prev, "RIGHT", -1, 0) else b:SetPoint("LEFT", byLabel, "RIGHT", 6, 0) end
        modeBtns[#modeBtns + 1] = b
        prev = b
    end
    local highlightMode = UI.CreateButtonGroup(modeBtns, function(id) mode = id; api:Render() end)

    local scopeLabel = pane:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    scopeLabel:SetTextColor(0.7, 0.7, 0.7)
    scopeLabel:SetText("scope:")
    local sessionBtn = UI.CreateButton(pane, "session", "accent-hover", { 60, 16 }, false, false, UI.FONT_SMALL, nil,
        "This login", "Undecayed; the only scope with per-target rows.")
    local allBtn = UI.CreateButton(pane, "all", "accent-hover", { 40, 16 }, false, false, UI.FONT_SMALL, nil,
        "Everything recorded on this character", "Decays with a 150-event half-life so old content fades out.", "No per-target rows: those are never saved.")
    sessionBtn.id, allBtn.id = "session", "all"
    allBtn:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -12, -2)
    sessionBtn:SetPoint("RIGHT", allBtn, "LEFT", 1, 0)
    scopeLabel:SetPoint("RIGHT", sessionBtn, "LEFT", -6, 0)
    local highlightScope = UI.CreateButtonGroup({ sessionBtn, allBtn }, function(id) scope = id; api:Render() end)

    local totalFS = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    totalFS:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 12, 4)
    totalFS:SetJustifyH("LEFT")
    totalFS:SetWidth(width - 60)

    local function AcquireRow()
        local row = table.remove(rowPool)
        if not row then
            row = CreateFrame("Frame", nil, pane)
            row:SetSize(width - 60, ROW_HEIGHT)
            row.cells = {}
            for _, key in ipairs(ALL_KEYS) do
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetJustifyH("LEFT")
                row.cells[key] = fs
            end
        end
        row:Show()
        usedRows[#usedRows + 1] = row
        return row
    end

    local function Layout(row, cols)
        for _, key in ipairs(ALL_KEYS) do row.cells[key]:Hide() end
        for _, col in ipairs(cols) do
            local fs = row.cells[col[1]]
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", row, "LEFT", col[2], 0)
            fs:SetWidth(col[3])
            fs:Show()
        end
    end

    function api:Release()
        for _, row in ipairs(usedRows) do row:Hide(); rowPool[#rowPool + 1] = row end
        wipe(usedRows)
    end

    -- casts + mana per family this session, for Spell mode
    local function FamilySpend()
        local out = {}
        local ST = MD.Spend
        if ST and ST.session then
            for fam, v in pairs(ST.session) do out[fam] = v end
        end
        return out
    end

    function api:Render()
        if not pane:IsShown() then return end
        api:Release()
        highlightMode(mode); highlightScope(scope)
        local OH = MD.Overheal
        local cols = COLS[mode]
        local rows
        if mode == "spell" then rows = OH:SpellRows(scope)
        elseif mode == "role" then rows = OH:RoleRows(scope)
        elseif mode == "class" then rows = OH:ClassRows(scope)
        else rows = OH:TargetRows() end

        local y = -24
        local header = AcquireRow()
        Layout(header, cols)
        header:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        for _, col in ipairs(cols) do header.cells[col[1]]:SetText("|cff888888" .. col[4] .. "|r") end
        y = y - 18

        local spend = mode == "spell" and FamilySpend() or nil
        local shownFam = {}
        for _, r in ipairs(rows) do
            if y < -(pane:GetHeight() - 40) then break end
            local row = AcquireRow()
            Layout(row, cols)
            row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
            local c = r.guessed and "|cffbbbbbb" or "|cffffffff"
            row.cells.label:SetText(c .. r.label .. "|r")
            row.cells.sub:SetText("|cff888888" .. (r.sub or "") .. (r.guessed and mode == "target" and "" or "") .. "|r")
            if mode == "spell" then
                local id = r.key:match("^k:(%d+):")
                local s = id and MD.SpellData.spells[tonumber(id)]
                local fam = s and s.family
                -- casts / mana belong to the spell as a whole: show them on the
                -- first event-kind row of each family only
                if fam and spend and spend[fam] and not shownFam[fam] then
                    shownFam[fam] = true
                    row.cells.casts:SetText(c .. spend[fam].casts .. "|r")
                    row.cells.mana:SetText(c .. K(spend[fam].mana) .. "|r")
                else
                    row.cells.casts:SetText("|cff555555-|r")
                    row.cells.mana:SetText("|cff555555-|r")
                end
            end
            if mode == "target" then
                local st = OH.session[r.key]
                row.cells.role:SetText((r.guessed and "|cffbbbbbb" or c) .. (st and st.role or "?") ..
                    (r.guessed and " ?|r" or "|r"))
                local guid = r.key:match("^u:(.+)$")
                local taps = MD.Targets and MD.Targets:LifeTaps(guid) or 0
                if taps > 0 then
                    -- overheal on a tapping warlock is partly the HoT doing its job
                    row.cells.sub:SetText("|cff888888" .. (r.sub or "") .. "|r |cff9482c9Life Tap x" .. taps .. "|r")
                end
            end
            row.cells.healed:SetText(c .. K(r.healed + r.overhealed) .. "|r")
            local fc = r.frac >= 0.45 and "|cffff6666" or r.frac >= 0.30 and "|cffffcc66" or "|cff99dd99"
            row.cells.frac:SetText(fc .. Pct(r.frac) .. "|r")
            row.cells.waste:SetText(c .. (r.wastedMana > 0 and K(r.wastedMana) or "-") .. "|r")
            row.cells.wev:SetText("|cff888888" .. (r.wastedEvents > 0 and (r.wastedEvents .. " events") or "-") .. "|r")
            if mode ~= "spell" and mode ~= "target" then
                -- who is in this bucket (session only)
                local names = {}
                if scope == "session" then
                    for _, t in ipairs(OH:TargetRows()) do
                        local st = OH.session[t.key]
                        if st and ((mode == "role" and st.role == r.label) or (mode == "class" and st.class == r.label)) then
                            names[#names + 1] = st.name
                        end
                    end
                end
                row.cells.sub:SetText("|cff888888" .. table.concat(names, ", ") .. "|r")
            end
            y = y - ROW_HEIGHT
        end

        if #rows == 0 then
            local row = AcquireRow(); Layout(row, cols)
            row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
            row.cells.label:SetWidth(600)
            row.cells.label:SetText("|cff666666No heals recorded" .. (scope == "session" and " this session" or "") ..
                " yet - heal something.|r")
        end

        local wm, we = OH:WastedTotal()
        local spent = MD.Spend and MD.Spend.sessionSpent or 0
        if spent > 0 then
            totalFS:SetFormattedText("|cff888888%s spent this session, ~%s (%d%%) into targets at full health across %d events.  " ..
                "Grey label / ? = role guessed, not read.|r", K(spent), K(wm), wm / spent * 100, we)
        else
            totalFS:SetText("")
        end
    end

    return api
end
