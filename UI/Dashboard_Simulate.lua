-- The dashboard's "Simulate" strip: what-if inputs that only the rank math
-- reads (MD.sim). A blank box means "use the live value", which is shown as a
-- grey placeholder inside the box. Split out of UI/Dashboard.lua; exports a
-- constructor on MD.DashboardParts.
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

-- onChange() is called whenever an override is set or cleared.
function MD.DashboardParts.CreateStrip(parent, x, y, onChange)
    local boxes = {}

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

    local clearBtn = UI.CreateButton(parent, "Clear", "red-hover", { 50, 16 }, false, false, UI.FONT_SMALL, nil,
        "Clear simulation", "Back to your live stats.")
    clearBtn:SetPoint("LEFT", last, "RIGHT", 10, 0)

    local api = {}

    -- live = RankMath.info.live
    function api:SetPlaceholders(live)
        if not live then return end
        for key, box in pairs(boxes) do
            if live[key] then
                box.ph:SetText(string.format(box.fmt, live[key]))
            end
        end
    end

    function api:Clear()
        wipe(MD.sim)
        for _, box in pairs(boxes) do
            box.eb:SetText("")
            box.ph:Show()
        end
        if onChange then onChange() end
    end

    clearBtn:SetScript("OnClick", function() api:Clear() end)

    return api
end
