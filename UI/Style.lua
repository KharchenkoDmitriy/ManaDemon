-- Widget kit in the style of Cell's options UI (flat 0.115-grey panels with a
-- 1px black border, class-colour accent, 13px widget font, tab buttons that
-- sit on the top edge of the frame). Written from scratch for ManaDemon: no
-- libraries, no pixel-perfect layer, plain sizes. Exposed on MD.UI and used
-- by the options frame, the debug console and the dashboard.
local _, MD = ...

local UI = {}
MD.UI = UI

local WHITE = "Interface\\Buttons\\WHITE8x8"
UI.whiteTexture = WHITE

--------------------------------------------------------------------------------
-- Colours: accent = class colour (Cell convention)
--------------------------------------------------------------------------------
local accent = { 0.7, 0.7, 0.7 }
local accentHex = "|cffb2b2b2"
do
    local _, class = UnitClass("player")
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then
        accent = { c.r, c.g, c.b }
        accentHex = c.colorStr and ("|c" .. c.colorStr)
            or string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
end
UI.accent = accent
UI.accentHex = accentHex
UI.grey = { 0.7, 0.7, 0.7 }
function UI.GetAccentColorRGB() return accent[1], accent[2], accent[3] end

--------------------------------------------------------------------------------
-- Fonts (global font objects, like Cell's CELL_FONT_*)
--------------------------------------------------------------------------------
local function MakeFont(name, size, r, g, b)
    local f = _G[name] or CreateFont(name)
    f:SetFont(GameFontNormal:GetFont(), size, "")
    f:SetTextColor(r, g, b, 1)
    f:SetShadowColor(0, 0, 0)
    f:SetShadowOffset(1, -1)
    f:SetJustifyH("CENTER")
    return f
end
UI.FONT_TITLE = "MANADEMON_FONT_TITLE";                 MakeFont(UI.FONT_TITLE, 14, 1, 1, 1)
UI.FONT_TITLE_DISABLE = "MANADEMON_FONT_TITLE_DISABLE"; MakeFont(UI.FONT_TITLE_DISABLE, 14, 0.4, 0.4, 0.4)
UI.FONT = "MANADEMON_FONT";                             MakeFont(UI.FONT, 13, 1, 1, 1)
UI.FONT_DISABLE = "MANADEMON_FONT_DISABLE";             MakeFont(UI.FONT_DISABLE, 13, 0.4, 0.4, 0.4)
UI.FONT_SMALL = "MANADEMON_FONT_SMALL";                 MakeFont(UI.FONT_SMALL, 11, 1, 1, 1)
UI.FONT_SPECIAL = "MANADEMON_FONT_SPECIAL";             MakeFont(UI.FONT_SPECIAL, 12, 1, 1, 1)
UI.FONT_CLASS_TITLE = "MANADEMON_FONT_CLASS_TITLE";     MakeFont(UI.FONT_CLASS_TITLE, 14, accent[1], accent[2], accent[3])
UI.FONT_CLASS = "MANADEMON_FONT_CLASS";                 MakeFont(UI.FONT_CLASS, 13, accent[1], accent[2], accent[3])

--------------------------------------------------------------------------------
-- Tooltip: a private GameTooltip with the flat backdrop. The 2.5.x tooltip
-- template draws a NineSlice and may lack the backdrop mixin, so both are
-- handled defensively; on any failure the stock look is kept.
--------------------------------------------------------------------------------
local tooltip = CreateFrame("GameTooltip", "ManaDemonTooltip", UIParent, "GameTooltipTemplate")
UI.tooltip = tooltip

local function StyleTooltip()
    if tooltip.NineSlice then tooltip.NineSlice:SetAlpha(0) end
    if not tooltip.SetBackdrop and BackdropTemplateMixin then
        Mixin(tooltip, BackdropTemplateMixin)
        tooltip:HookScript("OnSizeChanged", tooltip.OnBackdropSizeChanged)
    end
    if tooltip.SetBackdrop then
        tooltip:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        tooltip:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
        tooltip:SetBackdropBorderColor(accent[1], accent[2], accent[3], 1)
    end
end
pcall(StyleTooltip)
tooltip:SetOwner(UIParent, "ANCHOR_NONE")
tooltip:HookScript("OnShow", function() pcall(StyleTooltip) end)
tooltip:HookScript("OnHide", function() tooltip:ClearLines() end)

local function ShowTooltips(widget, anchor, x, y, lines)
    if type(lines) ~= "table" or #lines == 0 then
        tooltip:Hide()
        return
    end
    tooltip:SetOwner(widget, anchor or "ANCHOR_TOP", x or 0, y or 0)
    tooltip:AddLine(lines[1])
    for i = 2, #lines do
        if lines[i] then tooltip:AddLine("|cffffffff" .. lines[i]) end
    end
    tooltip:Show()
end

-- UI.SetTooltips(widget, anchor, x, y, title, line2, line3, ...)
function UI.SetTooltips(widget, anchor, x, y, ...)
    if select("#", ...) == 0 or select(1, ...) == nil then return end
    if not widget._tooltipsInited then
        widget._tooltipsInited = true
        widget:HookScript("OnEnter", function() ShowTooltips(widget, anchor, x, y, widget.tooltips) end)
        widget:HookScript("OnLeave", function() tooltip:Hide() end)
    end
    widget.tooltips = { ... }
end

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------
function UI.StylizeFrame(frame, color, borderColor)
    color = color or { 0.1, 0.1, 0.1, 0.9 }
    borderColor = borderColor or { 0, 0, 0, 1 }
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(unpack(color))
    frame:SetBackdropBorderColor(unpack(borderColor))
end

function UI.CreateFrame(name, parent, width, height, isTransparent)
    local f = CreateFrame("Frame", name, parent, "BackdropTemplate")
    f:Hide()
    if not isTransparent then UI.StylizeFrame(f) end
    f:EnableMouse(true)
    if width and height then f:SetSize(width, height) end
    return f
end

-- Frame with a 20px header bar above it (title in class colour, red x).
function UI.CreateMovableFrame(title, name, width, height, strata, level, notUserPlaced)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetUserPlaced(not notUserPlaced)
    f:SetFrameStrata(strata or "HIGH")
    f:SetFrameLevel(level or 1)
    f:SetClampedToScreen(true)
    f:SetClampRectInsets(0, 0, 20, 0)
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:Hide()
    UI.StylizeFrame(f)

    local header = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.header = header
    header:EnableMouse(true)
    header:SetClampedToScreen(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        f:StartMoving()
        if notUserPlaced then f:SetUserPlaced(false) end
    end)
    header:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        if f.OnMoved then f:OnMoved() end
    end)
    header:SetPoint("LEFT")
    header:SetPoint("RIGHT")
    header:SetPoint("BOTTOM", f, "TOP", 0, -1)
    header:SetHeight(20)
    UI.StylizeFrame(header, { 0.115, 0.115, 0.115, 1 })

    header.text = header:CreateFontString(nil, "OVERLAY", UI.FONT_CLASS_TITLE)
    header.text:SetText(title)
    header.text:SetPoint("CENTER", header)

    header.closeBtn = UI.CreateButton(header, "×", "red", { 20, 20 }, false, false, UI.FONT_SPECIAL, UI.FONT_SPECIAL)
    header.closeBtn:SetPoint("TOPRIGHT")
    header.closeBtn:SetScript("OnClick", function() f:Hide() end)

    return f
end

function UI.CreateSeparator(text, parent, width, color)
    color = color or { accent[1], accent[2], accent[3], 0.777 }
    width = width or parent:GetWidth() - 10

    local fs = parent:CreateFontString(nil, "OVERLAY", UI.FONT_TITLE)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetText(text)

    local line = parent:CreateTexture()
    line:SetSize(width, 1)
    line:SetColorTexture(unpack(color))
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -2)
    local shadow = parent:CreateTexture()
    shadow:SetSize(width, 1)
    shadow:SetColorTexture(0, 0, 0, 1)
    shadow:SetPoint("TOPLEFT", line, "TOPLEFT", 1, -1)
    return fs
end

-- Titled pane: accent title, underline at y = -17, content below.
function UI.CreateTitledPane(parent, text, width, height)
    local pane = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    pane:SetSize(width, height)

    local line = pane:CreateTexture()
    pane.line = line
    line:SetHeight(1)
    line:SetColorTexture(accent[1], accent[2], accent[3], 0.777)
    line:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -17)
    line:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, -17)

    local shadow = pane:CreateTexture()
    shadow:SetHeight(1)
    shadow:SetColorTexture(0, 0, 0, 1)
    shadow:SetPoint("TOPLEFT", line, "TOPLEFT", 1, -1)
    shadow:SetPoint("TOPRIGHT", line, "TOPRIGHT", 1, -1)

    local title = pane:CreateFontString(nil, "OVERLAY", UI.FONT_TITLE)
    pane.title = title
    title:SetJustifyH("LEFT")
    title:SetTextColor(accent[1], accent[2], accent[3])
    title:SetText(text)
    title:SetPoint("BOTTOMLEFT", line, "TOPLEFT", 0, 2)

    function pane:SetTitle(t) title:SetText(t) end
    return pane
end

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------
local BUTTON_COLORS = {
    ["red"]          = { { 0.6, 0.1, 0.1, 0.6 },          { 0.6, 0.1, 0.1, 1 } },
    ["red-hover"]    = { { 0.115, 0.115, 0.115, 1 },      { 0.6, 0.1, 0.1, 1 } },
    ["green"]        = { { 0.1, 0.6, 0.1, 0.6 },          { 0.1, 0.6, 0.1, 1 } },
    ["green-hover"]  = { { 0.115, 0.115, 0.115, 1 },      { 0.1, 0.6, 0.1, 1 } },
    ["blue-hover"]   = { { 0.115, 0.115, 0.115, 1 },      { 0, 0.5, 0.8, 1 } },
    ["yellow-hover"] = { { 0.115, 0.115, 0.115, 1 },      { 0.7, 0.7, 0, 1 } },
    ["accent"]       = { { accent[1], accent[2], accent[3], 0.3 }, { accent[1], accent[2], accent[3], 0.6 } },
    ["accent-hover"] = { { 0.115, 0.115, 0.115, 1 },      { accent[1], accent[2], accent[3], 0.6 } },
    ["transparent"]  = { { 0, 0, 0, 0 },                  { accent[1], accent[2], accent[3], 0.6 } },
    ["none"]         = { { 0, 0, 0, 0 },                  nil },
}

-- UI.CreateButton(parent, text, colorName, {w, h}, noBorder, noBackground, fontNormal, fontDisable, tooltip...)
function UI.CreateButton(parent, text, buttonColor, size, noBorder, noBackground, fontNormal, fontDisable, ...)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    if parent then b:SetFrameLevel(parent:GetFrameLevel() + 1) end
    b:SetText(text or "")
    b:SetSize(size[1], size[2])

    local pair = BUTTON_COLORS[buttonColor] or { { 0.115, 0.115, 0.115, 1 }, { 0.23, 0.23, 0.23, 1 } }
    b.color, b.hoverColor = pair[1], pair[2]

    local s = b:GetFontString()
    b.fs = s
    if s then
        s:SetWordWrap(false)
        s:SetPoint("LEFT")
        s:SetPoint("RIGHT")
        function b:SetTextColor(...) s:SetTextColor(...) end
    end

    if noBorder then
        b:SetBackdrop({ bgFile = WHITE })
    else
        b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    end

    if buttonColor == "transparent" then
        if s then
            s:SetJustifyH("LEFT")
            s:SetPoint("LEFT", 5, 0)
            s:SetPoint("RIGHT", -5, 0)
        end
        b:SetBackdropBorderColor(1, 1, 1, 0)
        b:SetPushedTextOffset(0, 0)
    else
        if not noBackground then
            local bg = b:CreateTexture()
            bg:SetDrawLayer("BACKGROUND", -8)
            b.bg = bg
            bg:SetAllPoints(b)
            bg:SetColorTexture(0.115, 0.115, 0.115, 1)
        end
        b:SetBackdropBorderColor(0, 0, 0, 1)
        b:SetPushedTextOffset(0, -1)
    end

    b:SetBackdropColor(unpack(b.color))
    b:SetDisabledFontObject(fontDisable or UI.FONT_DISABLE)
    b:SetNormalFontObject(fontNormal or UI.FONT)
    b:SetHighlightFontObject(fontNormal or UI.FONT)

    if b.hoverColor then
        b:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(self.hoverColor)) end)
        b:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(self.color)) end)
    end
    b:SetScript("PostClick", function()
        if SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON then PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON) end
    end)

    UI.SetTooltips(b, "ANCHOR_TOPLEFT", 0, 3, ...)
    return b
end

-- Radio-style group: the active button keeps its hover colour. Each button
-- needs an .id; onClick(id, button) fires on click. Returns Highlight(id).
function UI.CreateButtonGroup(buttons, onClick, onActive, onInactive)
    local function Highlight(id)
        for _, b in pairs(buttons) do
            if id == b.id then
                b:SetBackdropColor(unpack(b.hoverColor))
                b:SetScript("OnEnter", nil)
                b:SetScript("OnLeave", nil)
                if onActive then onActive(b.id, b) end
            else
                b:SetBackdropColor(unpack(b.color))
                b:SetScript("OnEnter", function() b:SetBackdropColor(unpack(b.hoverColor)) end)
                b:SetScript("OnLeave", function() b:SetBackdropColor(unpack(b.color)) end)
                if onInactive then onInactive(b.id, b) end
            end
        end
    end
    for _, b in pairs(buttons) do
        b:SetScript("OnClick", function()
            Highlight(b.id)
            onClick(b.id, b)
        end)
    end
    return Highlight
end

--------------------------------------------------------------------------------
-- Navigation (docs/SPEC-v0.11.md §3): one window, groups down the left, that
-- group's views along the top, and -- where a pane needs it -- the same rule
-- again inside a bordered box.
--
-- Written once so the panes stay dumb: a pane is a frame parented to
-- nav:Content(), created LAZILY the first time its view is selected and cached
-- after. A druid who never opens Simulate never builds it.
--
-- The palette is UI.PALETTE and nothing here carries its own literals: the
-- author asked for the settings window's colours everywhere, and "everywhere"
-- only holds if there is one place to change.
--------------------------------------------------------------------------------
UI.PALETTE = {
    frame  = { 0.1, 0.1, 0.1, 0.9 },      -- the window itself (UI.StylizeFrame's default)
    header = { 0.115, 0.115, 0.115, 1 },  -- the title bar and the nav columns
    pane   = { 0.13, 0.13, 0.13, 1 },     -- a box drawn inside the content area
    border = { 0, 0, 0, 1 },
}

local NAV_W = 108        -- the left column
local NAV_TOP = 24       -- the horizontal view row
local NAV_PAD = 8

-- groups: { { id, text, views = { { id, text, hidden }, ... } }, ... }
-- onCreate(groupID, viewID, content, nav) -> pane. Called ONCE per view, the
--   first time it is selected; the pane is cached and shown thereafter.
-- onShow(groupID, viewID, pane, nav). Called on every selection, including the
--   first. This is where a pane is refreshed -- rebuilding it instead would
--   throw away its state and its frames every time the author clicked a tab.
function UI.CreateNavFrame(title, name, width, height, groups, onCreate, onShow)
    local P = UI.PALETTE
    local f = UI.CreateMovableFrame(title, name, width, height)
    UI.StylizeFrame(f, P.frame, P.border)

    local nav = { frame = f, groups = groups, buttons = {}, viewButtons = {},
                  group = nil, view = nil }

    -- the left column
    local left = CreateFrame("Frame", nil, f, "BackdropTemplate")
    left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    left:SetWidth(NAV_W)
    UI.StylizeFrame(left, P.header, P.border)
    nav.left = left

    -- the content area, and the row of view buttons above it
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", left, "TOPRIGHT", NAV_PAD, -(NAV_TOP + NAV_PAD))
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -NAV_PAD, NAV_PAD)
    nav.content = content
    function nav:Content() return content end

    -- Hide everything that is not the selected pane, THEN show it. One frame can
    -- be registered under several views (the rank table is the pane for every
    -- spell family), and a single pass would hide it again on whichever key
    -- pairs() happened to visit last.
    local function ShowOnly(groupID, viewID)
        local keep = nav.panes and nav.panes[groupID] and nav.panes[groupID][viewID]
        for _, panes in pairs(nav.panes or {}) do
            for _, pane in pairs(panes) do
                if pane ~= keep and pane.Hide then pane:Hide() end
            end
        end
        if keep and keep.Show then keep:Show() end
    end

    -- the horizontal row for the selected group
    local function BuildViews(group)
        for _, b in ipairs(nav.viewButtons) do b:Hide() end
        wipe(nav.viewButtons)
        local prev
        for _, v in ipairs(group.views or {}) do
            if not v.hidden then
                local b = UI.CreateButton(f, v.text, "accent-hover", { math.max(64, #v.text * 8 + 16), 20 },
                    false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
                b.id = v.id
                if prev then b:SetPoint("LEFT", prev, "RIGHT", -1, 0)
                else b:SetPoint("TOPLEFT", left, "TOPRIGHT", NAV_PAD, -2) end
                nav.viewButtons[#nav.viewButtons + 1] = b
                prev = b
            end
        end
        nav.highlightView = UI.CreateButtonGroup(nav.viewButtons, function(id) nav:Select(group.id, id) end)
    end

    function nav:Select(groupID, viewID)
        local group
        for _, g in ipairs(groups) do if g.id == groupID then group = g end end
        if not group then group = groups[1] end
        if not group then return end
        if nav.group ~= group.id then
            nav.group = group.id
            BuildViews(group)
            nav.view = nil
        end
        local views = group.views or {}
        local view
        for _, v in ipairs(views) do
            if v.id == viewID and not v.hidden then view = v end
        end
        if not view then
            for _, v in ipairs(views) do if not v.hidden and not view then view = v end end
        end
        nav.view = view and view.id or nil
        if nav.highlightGroup then nav.highlightGroup(group.id) end
        if nav.highlightView and nav.view then nav.highlightView(nav.view) end
        if MD.db then MD.db.uiPath = { group.id, nav.view } end
        nav.panes = nav.panes or {}
        nav.panes[group.id] = nav.panes[group.id] or {}
        local pane = nav.view and nav.panes[group.id][nav.view] or nil
        if not pane and nav.view and onCreate then
            pane = onCreate(group.id, nav.view, content, nav)
            if pane then nav.panes[group.id][nav.view] = pane end
        end
        ShowOnly(group.id, nav.view)
        if onShow then onShow(group.id, nav.view, pane, nav) end
    end

    -- a group's views can change while the window is open (Reports/Runs)
    function nav:SetViews(groupID, views)
        for _, g in ipairs(groups) do
            if g.id == groupID then
                g.views = views
                if nav.group == groupID then BuildViews(g); nav:Select(groupID, nav.view) end
                return
            end
        end
    end

    function nav:Selected() return nav.group, nav.view end

    local prev
    for _, g in ipairs(groups) do
        local b = UI.CreateButton(left, g.text, "accent-hover", { NAV_W - 2, 22 }, false, false,
            UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
        b.id = g.id
        if prev then b:SetPoint("TOP", prev, "BOTTOM", 0, 1)
        else b:SetPoint("TOP", left, "TOP", 0, -2) end
        nav.buttons[#nav.buttons + 1] = b
        prev = b
    end
    nav.highlightGroup = UI.CreateButtonGroup(nav.buttons, function(id) nav:Select(id, nil) end)

    return nav
end

-- The same rule one level down, in a bordered box: for a pane that has
-- sub-categories of its own. Nothing needs it yet; it exists so that the next
-- thing that does is not a fourth window.
function UI.CreateNavBox(parent, width, height, groups, onSelect)   -- one hook: a box owns no panes
    local P = UI.PALETTE
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(width, height)
    UI.StylizeFrame(box, P.pane, P.border)
    local nav = { frame = box, groups = groups, buttons = {}, viewButtons = {} }

    local left = CreateFrame("Frame", nil, box, "BackdropTemplate")
    left:SetPoint("TOPLEFT", 1, -1)
    left:SetPoint("BOTTOMLEFT", 1, 1)
    left:SetWidth(NAV_W - 20)
    UI.StylizeFrame(left, P.header, P.border)

    local content = CreateFrame("Frame", nil, box)
    content:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, -(NAV_TOP + 2))
    content:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -6, 6)
    function nav:Content() return content end

    local function BuildViews(group)
        for _, b in ipairs(nav.viewButtons) do b:Hide() end
        wipe(nav.viewButtons)
        local prev
        for _, v in ipairs(group.views or {}) do
            local b = UI.CreateButton(box, v.text, "accent-hover", { math.max(56, #v.text * 7 + 14), 18 },
                false, false, UI.FONT_SMALL, UI.FONT_SMALL)
            b.id = v.id
            if prev then b:SetPoint("LEFT", prev, "RIGHT", -1, 0)
            else b:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, -2) end
            nav.viewButtons[#nav.viewButtons + 1] = b
            prev = b
        end
        nav.highlightView = UI.CreateButtonGroup(nav.viewButtons, function(id) nav:Select(group.id, id) end)
    end

    function nav:Select(groupID, viewID)
        local group
        for _, g in ipairs(groups) do if g.id == groupID then group = g end end
        group = group or groups[1]
        if not group then return end
        if nav.group ~= group.id then nav.group = group.id; BuildViews(group); nav.view = nil end
        local view
        for _, v in ipairs(group.views or {}) do if v.id == viewID then view = v end end
        view = view or (group.views or {})[1]
        nav.view = view and view.id or nil
        if nav.highlightGroup then nav.highlightGroup(group.id) end
        if nav.highlightView and nav.view then nav.highlightView(nav.view) end
        if onSelect then onSelect(group.id, nav.view, content, nav) end
    end

    local prev
    for _, g in ipairs(groups) do
        local b = UI.CreateButton(left, g.text, "accent-hover", { NAV_W - 22, 18 }, false, false,
            UI.FONT_SMALL, UI.FONT_SMALL)
        b.id = g.id
        if prev then b:SetPoint("TOP", prev, "BOTTOM", 0, 1)
        else b:SetPoint("TOP", left, "TOP", 0, -2) end
        nav.buttons[#nav.buttons + 1] = b
        prev = b
    end
    nav.highlightGroup = UI.CreateButtonGroup(nav.buttons, function(id) nav:Select(id, nil) end)

    return nav
end

--------------------------------------------------------------------------------
-- Dropdown: a button that says what is selected and drops a list under it.
--
-- The kit had button groups and nothing else, which is fine for two or three
-- short labels and wrong for four long ones -- four strategy names beside the
-- replay's column title ran off the window (v0.11.11). A dropdown costs one
-- control's width whatever the labels say.
--
-- UI.CreateDropdown(parent, width, height, onSelect) -> dd
--   dd:SetItems({ { id, text, tooltip }, ... })
--   dd:SetValue(id)   -- no callback
--   dd:Value()
--   dd:Close()
--------------------------------------------------------------------------------
function UI.CreateDropdown(parent, width, height, onSelect)
    height = height or 18
    local dd = UI.CreateButton(parent, "", "accent-hover", { width, height }, false, false,
        UI.FONT_SMALL, UI.FONT_SMALL)
    dd.items, dd.rows, dd.value = {}, {}, nil

    local arrow = dd:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    arrow:SetPoint("RIGHT", dd, "RIGHT", -4, 0)
    arrow:SetText("v")
    arrow:SetTextColor(0.7, 0.7, 0.7)

    local list = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    list:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -1)
    list:SetWidth(width)
    list:SetFrameStrata("DIALOG")
    UI.StylizeFrame(list, UI.PALETTE and UI.PALETTE.header or { 0.115, 0.115, 0.115, 1 })
    list:Hide()
    dd.list = list

    local function Label(id)
        for _, it in ipairs(dd.items) do if it.id == id then return it.text end end
        return ""
    end

    function dd:Close() list:Hide() end

    function dd:SetValue(id)
        dd.value = id
        dd:SetText(Label(id))
    end

    function dd:Value() return dd.value end

    function dd:SetItems(items)
        dd.items = items or {}
        for _, r in ipairs(dd.rows) do r:Hide() end
        local prev
        for i, it in ipairs(dd.items) do
            local r = dd.rows[i]
            if not r then
                r = UI.CreateButton(list, "", "accent-hover", { width - 2, height }, true, false,
                    UI.FONT_SMALL, UI.FONT_SMALL)
                dd.rows[i] = r
            end
            r:SetText(it.text)
            r:ClearAllPoints()
            if prev then r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 1)
            else r:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1) end
            if it.tooltip then UI.SetTooltips(r, "ANCHOR_RIGHT", 0, 0, it.text, it.tooltip) end
            r:SetScript("OnClick", function()
                dd:SetValue(it.id)
                list:Hide()
                if onSelect then onSelect(it.id) end
            end)
            r:Show()
            prev = r
        end
        list:SetHeight(math.max(height, #dd.items * (height - 1) + 3))
        if dd.value == nil and dd.items[1] then dd:SetValue(dd.items[1].id) end
    end

    dd:SetScript("OnClick", function()
        if list:IsShown() then list:Hide() else list:Show() end
    end)
    dd:SetScript("OnHide", function() list:Hide() end)

    return dd
end

--------------------------------------------------------------------------------
-- Check button
--------------------------------------------------------------------------------
-- UI.CreateCheckButton(parent, label, onClick(checked, cb), tooltip...)
function UI.CreateCheckButton(parent, label, onClick, ...)
    local cb = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    cb.onClick = onClick
    cb:SetScript("OnClick", function(self)
        if SOUNDKIT then
            PlaySound(self:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        end
        if cb.onClick then cb.onClick(self:GetChecked() and true or false, self) end
    end)

    cb.label = cb:CreateFontString(nil, "OVERLAY", UI.FONT)
    cb.label:SetText(label or "")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 5, 0)

    cb:SetSize(14, 14)
    if label and strtrim(label) ~= "" then
        cb:SetHitRectInsets(0, -cb.label:GetStringWidth() - 5, 0, 0)
    end

    cb:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    cb:SetBackdropColor(0.115, 0.115, 0.115, 0.9)
    cb:SetBackdropBorderColor(0, 0, 0, 1)

    local checkedTexture = cb:CreateTexture(nil, "ARTWORK")
    checkedTexture:SetColorTexture(accent[1], accent[2], accent[3], 0.7)
    checkedTexture:SetPoint("TOPLEFT", 1, -1)
    checkedTexture:SetPoint("BOTTOMRIGHT", -1, 1)

    local highlightTexture = cb:CreateTexture(nil, "ARTWORK")
    highlightTexture:SetColorTexture(accent[1], accent[2], accent[3], 0.1)
    highlightTexture:SetPoint("TOPLEFT", 1, -1)
    highlightTexture:SetPoint("BOTTOMRIGHT", -1, 1)

    cb:SetCheckedTexture(checkedTexture)
    cb:SetHighlightTexture(highlightTexture, "ADD")

    cb:SetScript("OnEnable", function()
        cb.label:SetTextColor(1, 1, 1)
        checkedTexture:SetColorTexture(accent[1], accent[2], accent[3], 0.7)
        cb:SetBackdropBorderColor(0, 0, 0, 1)
    end)
    cb:SetScript("OnDisable", function()
        cb.label:SetTextColor(0.4, 0.4, 0.4)
        checkedTexture:SetColorTexture(0.4, 0.4, 0.4)
        cb:SetBackdropBorderColor(0, 0, 0, 0.4)
    end)

    function cb:SetText(text)
        cb.label:SetText(text)
        if strtrim(text) ~= "" then
            cb:SetHitRectInsets(0, -cb.label:GetStringWidth() - 5, 0, 0)
        else
            cb:SetHitRectInsets(0, 0, 0, 0)
        end
    end

    UI.SetTooltips(cb, "ANCHOR_TOPLEFT", 0, 3, ...)
    return cb
end

--------------------------------------------------------------------------------
-- Edit boxes
--------------------------------------------------------------------------------
function UI.CreateEditBox(parent, width, height, isTransparent, isMultiLine, isNumeric, font)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    if not isTransparent then UI.StylizeFrame(eb, { 0.115, 0.115, 0.115, 0.9 }) end
    eb:SetFontObject(font or UI.FONT)
    eb:SetMultiLine(isMultiLine)
    eb:SetMaxLetters(0)
    eb:SetJustifyH("LEFT")
    eb:SetJustifyV("MIDDLE")
    eb:SetWidth(width or 0)
    eb:SetHeight(height or 0)
    eb:SetTextInsets(5, 5, 0, 0)
    eb:SetAutoFocus(false)
    eb:SetNumeric(isNumeric)
    eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function() eb:ClearFocus() end)
    eb:SetScript("OnEditFocusGained", function() eb:HighlightText() end)
    eb:SetScript("OnEditFocusLost", function() eb:HighlightText(0, 0) end)
    eb:SetScript("OnDisable", function() eb:SetTextColor(0.4, 0.4, 0.4, 1) end)
    eb:SetScript("OnEnable", function() eb:SetTextColor(1, 1, 1, 1) end)
    return eb
end

--------------------------------------------------------------------------------
-- Scroll frame with a 5px accent scrollbar (mouse wheel + draggable thumb)
--------------------------------------------------------------------------------
function UI.CreateScrollFrame(parent, top, bottom, color, border)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "BackdropTemplate")
    parent.scrollFrame = scrollFrame
    top = top or 0
    bottom = bottom or 0
    scrollFrame:SetPoint("TOPLEFT", 0, top)
    scrollFrame:SetPoint("BOTTOMRIGHT", 0, bottom)
    if color then UI.StylizeFrame(scrollFrame, color, border) end

    function scrollFrame:Resize(newTop, newBottom)
        top, bottom = newTop, newBottom
        scrollFrame:SetPoint("TOPLEFT", 0, top)
        scrollFrame:SetPoint("BOTTOMRIGHT", 0, bottom)
    end

    local content = CreateFrame("Frame", nil, scrollFrame, "BackdropTemplate")
    content:SetSize(scrollFrame:GetWidth(), 2)
    scrollFrame:SetScrollChild(content)
    scrollFrame.content = content

    local scrollbar = CreateFrame("Frame", nil, scrollFrame, "BackdropTemplate")
    scrollbar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 2, 0)
    scrollbar:SetPoint("BOTTOMRIGHT", scrollFrame, 7, 0)
    scrollbar:Hide()
    UI.StylizeFrame(scrollbar, { 0.1, 0.1, 0.1, 0.8 })
    scrollFrame.scrollbar = scrollbar

    local scrollThumb = CreateFrame("Frame", nil, scrollbar, "BackdropTemplate")
    scrollThumb:SetWidth(5)
    scrollThumb:SetHeight(scrollbar:GetHeight())
    scrollThumb:SetPoint("TOP")
    UI.StylizeFrame(scrollThumb, { accent[1], accent[2], accent[3], 0.8 })
    scrollThumb:EnableMouse(true)
    scrollThumb:SetMovable(true)
    scrollThumb:SetHitRectInsets(-5, -5, 0, 0)
    scrollFrame.scrollThumb = scrollThumb

    function scrollFrame:ResetHeight() content:SetHeight(2) end

    function scrollFrame:ResetScroll()
        scrollFrame:SetVerticalScroll(0)
        scrollThumb:SetPoint("TOP")
    end

    function scrollFrame:GetVerticalScrollRange()
        local range = content:GetHeight() - scrollFrame:GetHeight()
        return range > 0 and range or 0
    end

    function scrollFrame:VerticalScroll(step)
        local scroll = scrollFrame:GetVerticalScroll() + step
        if scroll <= 0 then
            scrollFrame:SetVerticalScroll(0)
        elseif scroll >= scrollFrame:GetVerticalScrollRange() then
            scrollFrame:SetVerticalScroll(scrollFrame:GetVerticalScrollRange())
        else
            scrollFrame:SetVerticalScroll(scroll)
        end
    end

    function scrollFrame:ScrollToBottom()
        scrollFrame:SetVerticalScroll(scrollFrame:GetVerticalScrollRange())
    end

    function scrollFrame:SetContentHeight(height, num, spacing)
        if num and spacing then
            content:SetHeight(num * height + (num - 1) * spacing)
        else
            content:SetHeight(height)
        end
    end

    scrollFrame:SetScript("OnSizeChanged", function()
        content:SetWidth(scrollFrame:GetWidth())
    end)

    content:SetScript("OnSizeChanged", function()
        local p = scrollFrame:GetHeight() / math.max(content:GetHeight(), 1)
        p = tonumber(string.format("%.3f", p))
        if p < 1 then
            scrollThumb:SetHeight(scrollbar:GetHeight() * p)
            scrollFrame:SetPoint("BOTTOMRIGHT", parent, -7, bottom)
            scrollbar:Show()
        else
            scrollFrame:SetPoint("BOTTOMRIGHT", parent, 0, bottom)
            scrollbar:Hide()
            if scrollFrame:GetVerticalScroll() > 0 then scrollFrame:SetVerticalScroll(0) end
        end
    end)

    scrollThumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local offsetY = select(5, scrollThumb:GetPoint(1)) or 0
        local mouseY = select(2, GetCursorPosition())
        local uiScale = UIParent:GetEffectiveScale()
        self:SetScript("OnUpdate", function()
            local newOffsetY = offsetY + (select(2, GetCursorPosition()) - mouseY) / uiScale
            if newOffsetY >= 0 then
                scrollThumb:SetPoint("TOP")
                newOffsetY = 0
            elseif (-newOffsetY) + scrollThumb:GetHeight() >= scrollbar:GetHeight() then
                scrollThumb:SetPoint("TOP", 0, -(scrollbar:GetHeight() - scrollThumb:GetHeight()))
                newOffsetY = -(scrollbar:GetHeight() - scrollThumb:GetHeight())
            else
                scrollThumb:SetPoint("TOP", 0, newOffsetY)
            end
            local track = scrollbar:GetHeight() - scrollThumb:GetHeight()
            if track > 0 then
                scrollFrame:SetVerticalScroll((-newOffsetY / track) * scrollFrame:GetVerticalScrollRange())
            end
        end)
    end)
    scrollThumb:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)

    scrollFrame:SetScript("OnVerticalScroll", function()
        local range = scrollFrame:GetVerticalScrollRange()
        if range ~= 0 then
            local scrollP = scrollFrame:GetVerticalScroll() / range
            scrollThumb:SetPoint("TOP", 0, -((scrollbar:GetHeight() - scrollThumb:GetHeight()) * scrollP))
        end
    end)

    local step = 25
    function scrollFrame:SetScrollStep(s) step = s end

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(_, delta)
        if delta == 1 then
            scrollFrame:VerticalScroll(-step)
        elseif delta == -1 then
            scrollFrame:VerticalScroll(step)
        end
    end)

    return scrollFrame
end

-- Multi-line edit box inside a scroll frame (used by the copy popup).
function UI.CreateScrollEditBox(parent, onTextChanged, scrollStep)
    scrollStep = scrollStep or 1
    local frame = CreateFrame("Frame", nil, parent)
    UI.CreateScrollFrame(frame)
    UI.StylizeFrame(frame.scrollFrame, { 0.15, 0.15, 0.15, 0.9 })

    frame.eb = UI.CreateEditBox(frame.scrollFrame.content, 10, 20, true, true)
    frame.eb:SetPoint("TOPLEFT")
    frame.eb:SetPoint("RIGHT")
    frame.eb:SetTextInsets(2, 2, 2, 2)
    frame.eb:SetScript("OnEditFocusGained", nil)
    frame.eb:SetScript("OnEditFocusLost", nil)
    frame.eb:SetScript("OnEnterPressed", function(self) self:Insert("\n") end)

    frame.eb:SetScript("OnCursorChanged", function(self, _, y, cursorWidth, lineHeight)
        frame.scrollFrame:SetScrollStep((lineHeight + frame.eb:GetSpacing()) * scrollStep)
        local vs = frame.scrollFrame:GetVerticalScroll()
        local h = frame.scrollFrame:GetHeight()
        local cursorHeight = lineHeight - y
        if vs + y > 0 then
            frame.scrollFrame:SetVerticalScroll(-y)
        elseif cursorHeight > h + vs then
            frame.scrollFrame:SetVerticalScroll(-y - h + lineHeight + (cursorWidth or 0))
        end
        if frame.scrollFrame:GetVerticalScroll() > frame.scrollFrame:GetVerticalScrollRange() then
            frame.scrollFrame:ScrollToBottom()
        end
    end)

    frame.eb:SetScript("OnTextChanged", function(self, userChanged)
        frame.scrollFrame:SetContentHeight(self:GetHeight())
        if onTextChanged then onTextChanged(self, userChanged) end
    end)

    frame.scrollFrame:SetScript("OnMouseDown", function() frame.eb:SetFocus(true) end)

    function frame:SetText(text)
        frame.eb:SetText(text)
        frame.scrollFrame:ResetScroll()
        frame.eb:SetCursorPosition(0)
    end
    function frame:GetText() return frame.eb:GetText() end
    function frame:SetEnabled(enabled) frame.eb:SetEnabled(enabled) end
    return frame
end

--------------------------------------------------------------------------------
-- Slider: label above, value edit box below the middle, low/high captions
--------------------------------------------------------------------------------
-- UI.CreateSlider(name, parent, low, high, width, step, onValueChanged, afterValueChanged, isPercentage, tooltip...)
function UI.CreateSlider(name, parent, low, high, width, step, onValueChangedFn, afterValueChangedFn, isPercentage, ...)
    local tooltips = { ... }
    local slider = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(width, 10)
    local unit = isPercentage and "%" or ""
    UI.StylizeFrame(slider, { 0.115, 0.115, 0.115, 1 })

    local label = slider:CreateFontString(nil, "OVERLAY", UI.FONT)
    label:SetText(name)
    label:SetPoint("BOTTOM", slider, "TOP", 0, 2)
    function slider:SetLabel(n) label:SetText(n) end

    local currentEditBox = UI.CreateEditBox(slider, 48, 14)
    slider.currentEditBox = currentEditBox
    currentEditBox:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", math.ceil(width / 2 - 24), -1)
    currentEditBox:SetJustifyH("CENTER")
    currentEditBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    currentEditBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local value = tonumber(self:GetText())
        if value == self.oldValue then return end
        if value then
            if value < slider.low then value = slider.low end
            if value > slider.high then value = slider.high end
            self:SetText(value)
            slider:SetValue(value)
            if slider.onValueChangedFn then slider.onValueChangedFn(value) end
            if slider.afterValueChangedFn then slider.afterValueChangedFn(value) end
        else
            self:SetText(self.oldValue)
        end
    end)
    currentEditBox:SetScript("OnShow", function(self)
        if self.oldValue then self:SetText(self.oldValue) end
    end)

    local lowText = slider:CreateFontString(nil, "OVERLAY", UI.FONT)
    slider.lowText = lowText
    lowText:SetTextColor(unpack(UI.grey))
    lowText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -1)
    lowText:SetPoint("BOTTOM", currentEditBox)

    local highText = slider:CreateFontString(nil, "OVERLAY", UI.FONT)
    slider.highText = highText
    highText:SetTextColor(unpack(UI.grey))
    highText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -1)
    highText:SetPoint("BOTTOM", currentEditBox)

    local tex = slider:CreateTexture(nil, "ARTWORK")
    tex:SetColorTexture(accent[1], accent[2], accent[3], 0.7)
    tex:SetSize(8, 8)
    slider:SetThumbTexture(tex)

    local valueBeforeClick
    slider.onEnter = function()
        tex:SetColorTexture(accent[1], accent[2], accent[3], 1)
        valueBeforeClick = slider:GetValue()
        if #tooltips > 0 then ShowTooltips(slider, "ANCHOR_TOPLEFT", 0, 3, tooltips) end
    end
    slider:SetScript("OnEnter", slider.onEnter)
    slider.onLeave = function()
        tex:SetColorTexture(accent[1], accent[2], accent[3], 0.7)
        tooltip:Hide()
    end
    slider:SetScript("OnLeave", slider.onLeave)

    slider.onValueChangedFn = onValueChangedFn
    slider.afterValueChangedFn = afterValueChangedFn

    local oldValue
    slider:SetScript("OnValueChanged", function(_, value, userChanged)
        if oldValue == value then return end
        oldValue = value
        if math.floor(value) < value then value = tonumber(string.format("%.2f", value)) end
        currentEditBox:SetText(value)
        currentEditBox.oldValue = value
        if userChanged and slider.onValueChangedFn then slider.onValueChangedFn(value) end
    end)

    slider:SetScript("OnMouseUp", function()
        if not slider:IsEnabled() then return end
        if valueBeforeClick ~= oldValue and slider.afterValueChangedFn then
            valueBeforeClick = oldValue
            local value = slider:GetValue()
            if math.floor(value) < value then value = tonumber(string.format("%.2f", value)) end
            slider.afterValueChangedFn(value)
        end
    end)

    slider:SetValue(low)

    slider:SetScript("OnDisable", function()
        label:SetTextColor(0.4, 0.4, 0.4)
        currentEditBox:SetEnabled(false)
        slider:SetScript("OnEnter", nil)
        slider:SetScript("OnLeave", nil)
        tex:SetColorTexture(0.4, 0.4, 0.4, 0.7)
        lowText:SetTextColor(0.4, 0.4, 0.4)
        highText:SetTextColor(0.4, 0.4, 0.4)
    end)
    slider:SetScript("OnEnable", function()
        label:SetTextColor(1, 1, 1)
        currentEditBox:SetEnabled(true)
        slider:SetScript("OnEnter", slider.onEnter)
        slider:SetScript("OnLeave", slider.onLeave)
        tex:SetColorTexture(accent[1], accent[2], accent[3], 0.7)
        lowText:SetTextColor(unpack(UI.grey))
        highText:SetTextColor(unpack(UI.grey))
    end)

    function slider:UpdateMinMaxValues(minV, maxV)
        slider:SetMinMaxValues(minV, maxV)
        slider.low, slider.high = minV, maxV
        lowText:SetText(minV .. unit)
        highText:SetText(maxV .. unit)
    end
    slider:UpdateMinMaxValues(low, high)

    return slider
end
