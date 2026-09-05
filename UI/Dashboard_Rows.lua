-- The rank table inside the dashboard: column layout, the row frame pool and
-- the per-row rendering. Split out of UI/Dashboard.lua so the frame file stays
-- about the frame. Exports a constructor on MD.DashboardParts; UI/Dashboard.lua
-- loads after this and calls it.
local _, MD = ...

MD.DashboardParts = MD.DashboardParts or {}

local COLS = {
    { key = "rank",  x = 12,  w = 46,  label = "Rank" },
    { key = "level", x = 62,  w = 40,  label = "Lvl" },
    { key = "cost",  x = 106, w = 60,  label = "Mana" },
    { key = "heal",  x = 170, w = 86,  label = "Heal/cast" },
    { key = "hpm",   x = 260, w = 64,  label = "HPM" },
    { key = "hps",   x = 328, w = 64,  label = "HPS" },
    { key = "cast",  x = 396, w = 50,  label = "Cast" },
    { key = "casts", x = 450, w = 56,  label = "To OOM" },
    { key = "note",  x = 510, w = 228, label = "" },
}

local ROW_HEIGHT = 16

-- Columns whose values become overheal-adjusted in "Effective" mode. Mana,
-- Cast and To OOM never move: mana spent is mana spent.
local EFFECTIVE_COLS = { heal = true, hpm = true, hps = true }

local function Fmt(n, decimals)
    return string.format(decimals and ("%." .. decimals .. "f") or "%d", n)
end

local function AccentHex()
    local a = MD.UI.accent
    return string.format("|cff%02x%02x%02x", a[1] * 255, a[2] * 255, a[3] * 255)
end

function MD.DashboardParts.CreateTable(parent, width)
    local pane = CreateFrame("Frame", nil, parent)
    local rowPool, usedRows = {}, {}

    local function AcquireRow()
        local row = table.remove(rowPool)
        if not row then
            row = CreateFrame("Frame", nil, pane)
            row:SetSize(width - 60, ROW_HEIGHT)
            row.cells = {}

            -- Hover: a faint accent wash and the full breakdown of every
            -- number in the row (RankMath:Explain rebuilds it on demand, so
            -- the 2s re-render never allocates it).
            row.highlight = row:CreateTexture(nil, "BACKGROUND")
            row.highlight:SetAllPoints()
            row.highlight:SetColorTexture(MD.UI.accent[1], MD.UI.accent[2], MD.UI.accent[3], 0.10)
            row.highlight:Hide()

            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if self.isHeader then
                    MD.Tip:ShowAt(self, "TOPLEFT", pane:GetParent(), "TOPRIGHT", 4, 0, MD.Tip:Columns())
                    return
                end
                if not self.spellID then return end
                self.highlight:Show()
                MD.Tip:ShowAt(self, "TOPLEFT", pane:GetParent(), "TOPRIGHT", 4, 0,
                    MD.Tip:Row(MD.RankMath:Explain(self.spellID, self.variant)))
            end)
            row:SetScript("OnLeave", function(self)
                self.highlight:Hide()
                MD.Tip:Hide()
            end)
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

    local api = { frame = pane, cols = COLS }

    function api:Release()
        for _, row in ipairs(usedRows) do
            row.spellID, row.variant, row.isHeader = nil, nil, nil
            row.highlight:Hide()
            row:Hide()
            rowPool[#rowPool + 1] = row
        end
        wipe(usedRows)
    end

    -- rows come straight from RankMath:Compute(). In "Effective" mode the four
    -- healing columns show value * (1 - measured overheal); their headers turn
    -- the accent colour so it is never ambiguous which numbers moved.
    function api:Render(rows)
        api:Release()
        local effective = MD.db and MD.db.effectiveMode and true or false
        local accent = AccentHex()
        local y = -4

        local header = AcquireRow()
        header.isHeader = true -- pooled like any row; its hover shows the glossary
        header:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        for _, col in ipairs(COLS) do
            local hex = (effective and EFFECTIVE_COLS[col.key]) and accent or "|cff888888"
            header.cells[col.key]:SetText(hex .. col.label .. "|r")
        end
        y = y - 18

        for _, r in ipairs(rows) do
            local row = AcquireRow()
            row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
            row.spellID, row.variant = r.id, r.variant

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
            -- In effective mode a row with no measurement of its own keeps its
            -- raw value and gets a grey "?" so the two are never confused.
            local heal, hpm, hps = r.heal, r.hpm, r.hps
            local unmeasured = ""
            if effective then
                if r.overheal then
                    heal, hpm, hps = r.effHeal, r.effHpm, r.effHps
                else
                    unmeasured = "|cff777777?|r"
                end
            end

            row.cells.rank:SetText(c .. (r.rankLabel or ("R" .. r.rank)) .. (r.suggested and " *" or "") .. "|r")
            row.cells.level:SetText(c .. r.level .. "|r")
            row.cells.cost:SetText(c .. Fmt(r.cost) .. "|r")
            row.cells.heal:SetText(c .. Fmt(heal) .. "|r" .. unmeasured)
            row.cells.hpm:SetText(c .. Fmt(hpm, 2) .. "|r")
            row.cells.hps:SetText(c .. Fmt(hps) .. "|r")
            -- the grey "*" means the cast time is a Nature's Grace average
            row.cells.cast:SetText(c .. Fmt(r.cast, 1) .. "s|r" .. (r.ng and "|cff888888*|r" or ""))
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

            y = y - ROW_HEIGHT
        end
    end

    return api
end
