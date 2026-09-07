-- The dashboard's "Simulate" strip: what-if inputs that only the rank math
-- reads (MD.sim). A blank box means "use the live value", which is shown as a
-- grey placeholder inside the box.
--
-- Two rows: stats on the first, form and Moonglow on the second. Form is a
-- three-state group rather than a checkbox because "follow my real form" is a
-- distinct answer from "caster". MD:InTreeForm() itself is never overridden --
-- the clock, the advisor and the gear toast keep using the real form; only
-- RankMath:Context() reads MD.sim.
--
-- Simulating a form or a Moonglow rank invalidates the client's live cost, so
-- RankMath falls back to SD:StaticCost(id, ctx) for those; the dashboard says
-- so on the stats line.
--
-- Split out of UI/Dashboard.lua; exports a constructor on MD.DashboardParts.
local _, MD = ...
local UI = MD.UI

MD.DashboardParts = MD.DashboardParts or {}

-- key, label, placeholder format
local BOXES = {
    { "heal",    "+heal",       "%d" },
    { "crit",    "crit%",       "%.1f" },
    { "casting", "casting mp5", "%d" },
    { "base",    "resting mp5", "%d" },
    { "mana",    "mana",        "%d" },
}

local FORMS = { { "live", "Live" }, { "caster", "Caster" }, { "tree", "Tree" } }

local function FormID()
    if MD.sim.tree == nil then return "live" end
    return MD.sim.tree and "tree" or "caster"
end

-- onChange() is called whenever an override is set or cleared. The strip
-- occupies two rows: y and y - ROW_GAP.
local ROW_GAP = 18

function MD.DashboardParts.CreateStrip(parent, x, y, onChange)
    local boxes = {}

    -- v0.11.1: the strip lives in a frame of its own so it can be shown and
    -- hidden with the Spells group. Everything below parents to `holder`; only
    -- the two absolute anchors moved, the rest chain off the title as before.
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    holder:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, y)
    holder:SetHeight(46)
    parent = holder
    x, y = 0, 0

    local title = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    title:SetTextColor(UI.accent[1], UI.accent[2], UI.accent[3])
    title:SetText("Simulate:")

    local function AddBox(key, labelText, phFmt, anchor)
        local label = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        label:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
        label:SetTextColor(0.7, 0.7, 0.7)
        label:SetText(labelText)

        local eb = UI.CreateEditBox(parent, 56, 16, false, false, false, UI.FONT_SMALL)
        eb:SetPoint("LEFT", label, "RIGHT", 4, 0)
        eb:SetTextInsets(3, 3, 0, 0)

        local ph = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
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
            if onChange then onChange() end
        end
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEditFocusGained", function() ph:Hide() end)
        eb:SetScript("OnEditFocusLost", Apply)

        boxes[key] = { eb = eb, ph = ph, fmt = phFmt }
        return eb
    end

    local last = title
    for _, def in ipairs(BOXES) do
        last = AddBox(def[1], def[2], def[3], last)
    end

    ----------------------------------------------------------------------------
    -- second row: form + Moonglow + Clear
    ----------------------------------------------------------------------------
    local formLabel = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    formLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 62, y - ROW_GAP)
    formLabel:SetTextColor(0.7, 0.7, 0.7)
    formLabel:SetText("form")

    local formButtons, prev = {}, nil
    for _, def in ipairs(FORMS) do
        local btn = UI.CreateButton(parent, def[2], "accent-hover", { 48, 16 }, false, false, UI.FONT_SMALL, nil)
        btn.id = def[1]
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", -1, 0)
        else
            btn:SetPoint("LEFT", formLabel, "RIGHT", 6, 0)
        end
        formButtons[#formButtons + 1] = btn
        prev = btn
    end
    local highlightForm = UI.CreateButtonGroup(formButtons, function(id)
        if id == "live" then
            MD.sim.tree = nil
        else
            MD.sim.tree = (id == "tree")
        end
        if onChange then onChange() end
    end)

    local mgLabel = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    mgLabel:SetPoint("LEFT", prev, "RIGHT", 14, 0)
    mgLabel:SetTextColor(0.7, 0.7, 0.7)
    mgLabel:SetText("Moonglow")

    local mgBox = UI.CreateEditBox(parent, 34, 16, false, false, false, UI.FONT_SMALL)
    mgBox:SetPoint("LEFT", mgLabel, "RIGHT", 4, 0)
    mgBox:SetTextInsets(3, 3, 0, 0)
    local mgPh = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    mgPh:SetPoint("LEFT", mgBox, "LEFT", 4, 0)
    mgPh:SetTextColor(0.45, 0.45, 0.45)

    local function ApplyMoonglow(self)
        local text = strtrim(self:GetText() or "")
        if text == "" then
            MD.sim.moonglow = nil
        else
            local v = tonumber(text)
            if v and v >= 0 and v <= 3 then
                MD.sim.moonglow = math.floor(v)
                self:SetText(tostring(MD.sim.moonglow))
            else
                self:SetText(MD.sim.moonglow and tostring(MD.sim.moonglow) or "")
            end
        end
        mgPh:SetShown(strtrim(self:GetText() or "") == "")
        self:HighlightText(0, 0)
        if onChange then onChange() end
    end
    mgBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    mgBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    mgBox:SetScript("OnEditFocusGained", function() mgPh:Hide() end)
    mgBox:SetScript("OnEditFocusLost", ApplyMoonglow)
    UI.SetTooltips(mgBox, "ANCHOR_TOPLEFT", 0, 3, "Moonglow rank (0-3)",
        "-3% mana per rank on Healing Touch, Regrowth and Rejuvenation.",
        "Blank = your real talent. Simulated costs come from the static",
        "table, since the client can only price the talents you have.")

    local clearBtn = UI.CreateButton(parent, "Clear", "red-hover", { 50, 16 }, false, false, UI.FONT_SMALL, nil,
        "Clear simulation", "Back to your live stats and your real form.")
    clearBtn:SetPoint("LEFT", mgBox, "RIGHT", 14, 0)

    local api = {}

    -- live = RankMath.info.live; also re-syncs the widgets with MD.sim, which
    -- other code may have cleared (the Clear button, a fresh session).
    function api:SetPlaceholders(live)
        if live then
            for key, box in pairs(boxes) do
                if live[key] then
                    box.ph:SetText(string.format(box.fmt, live[key]))
                end
            end
        end
        highlightForm(FormID())
        mgPh:SetText(tostring(MD:TalentRank("Moonglow")))
        mgPh:SetShown(strtrim(mgBox:GetText() or "") == "")
    end

    function api:Clear()
        wipe(MD.sim)
        for _, box in pairs(boxes) do
            box.eb:SetText("")
            box.ph:Show()
        end
        mgBox:SetText("")
        mgPh:Show()
        highlightForm("live")
        if onChange then onChange() end
    end

    clearBtn:SetScript("OnClick", function() api:Clear() end)

    api.frame = holder
    function api:SetShown(on) if on then holder:Show() else holder:Hide() end end

    return api
end
