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
    { key = "hp5",   x = 396, w = 64,  label = "HP5" },
    { key = "cast",  x = 464, w = 50,  label = "Cast" },
    { key = "casts", x = 518, w = 56,  label = "To OOM" },
    { key = "note",  x = 578, w = 160, label = "" },
}

local ROW_HEIGHT = 16

local function Fmt(n, decimals)
    return string.format(decimals and ("%." .. decimals .. "f") or "%d", n)
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
            row:Hide()
            rowPool[#rowPool + 1] = row
        end
        wipe(usedRows)
    end

    -- rows come straight from RankMath:Compute()
    function api:Render(rows)
        api:Release()
        local y = -4

        local header = AcquireRow()
        header:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        for _, col in ipairs(COLS) do
            header.cells[col.key]:SetText("|cff888888" .. col.label .. "|r")
        end
        y = y - 18

        for _, r in ipairs(rows) do
            local row = AcquireRow()
            row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)

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
