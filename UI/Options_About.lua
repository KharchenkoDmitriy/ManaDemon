-- Options > About: what the addon is, every slash command, how to verify.
local _, MD = ...
local UI = MD.UI

local tab = UI.CreateFrame("ManaDemonOptionsFrame_AboutTab", MD.optionsFrame, nil, nil, true)
tab:SetAllPoints(MD.optionsFrame)
tab:Hide()

local built = false
local function Build()
    if built then return end
    built = true

    local title = tab:CreateFontString(nil, "OVERLAY", UI.FONT_CLASS_TITLE)
    title:SetPoint("TOPLEFT", tab, 10, -10)
    title:SetText("ManaDemon")

    local version = tab:CreateFontString(nil, "OVERLAY", UI.FONT)
    version:SetPoint("LEFT", title, "RIGHT", 6, 0)
    version:SetTextColor(0.6, 0.6, 0.6)
    version:SetText("v" .. MD.version .. "  -  TBC Anniversary")

    local blurb = tab:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    blurb:SetWidth(412)
    blurb:SetJustifyH("LEFT")
    blurb:SetTextColor(0.8, 0.8, 0.8)
    blurb:SetText("Mana management for healers: a live time-to-OOM clock (widget + ElvUI datatexts), " ..
        "a per-rank efficiency dashboard for druid heals (/md), Innervate / potion / drink advice " ..
        "and a one-line fight summary. Design notes live in docs/DECISIONS.md.")

    local cmdPane = UI.CreateTitledPane(tab, "Commands", 412, 200)
    cmdPane:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -10)
    local y = -24
    for _, c in ipairs(MD.COMMANDS) do
        local left = cmdPane:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        left:SetPoint("TOPLEFT", cmdPane, 5, y)
        left:SetWidth(118)
        left:SetJustifyH("LEFT")
        left:SetTextColor(UI.accent[1], UI.accent[2], UI.accent[3])
        left:SetText(c[1])
        local right = cmdPane:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        right:SetPoint("TOPLEFT", cmdPane, 128, y)
        right:SetWidth(280)
        right:SetJustifyH("LEFT")
        right:SetTextColor(0.85, 0.85, 0.85)
        right:SetText(c[2])
        y = y - math.max(left:GetStringHeight(), right:GetStringHeight()) - 3
    end
    cmdPane:SetHeight(-y + 4)

    local verifyPane = UI.CreateTitledPane(tab, "Before trusting the numbers", 412, 70)
    verifyPane:SetPoint("TOPLEFT", cmdPane, "BOTTOMLEFT", 0, -10)
    local how = verifyPane:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    how:SetPoint("TOPLEFT", verifyPane, 5, -24)
    how:SetWidth(402)
    how:SetJustifyH("LEFT")
    how:SetTextColor(0.8, 0.8, 0.8)
    how:SetText("1. /md verify - spell costs and cast times against your client.  " ..
        "2. /md regentest - idle 30s: is Dreamstate in GetManaRegen?  " ..
        "3. /md fsrtest - cast once, watch the tick sizes.  " ..
        "Copy everything from the Debug Console (General > Misc).")
    verifyPane:SetHeight(24 + how:GetStringHeight() + 6)

    -- total height: everything above plus margins
    local total = 10 + title:GetStringHeight() + 6 + blurb:GetStringHeight() + 10
        + cmdPane:GetHeight() + 10 + verifyPane:GetHeight() + 12
    MD.optionsTabHeight.about = math.ceil(total)
end

local function ShowTab(which)
    if which ~= "about" then
        tab:Hide()
        return
    end
    Build()
    MD.optionsFrame:SetHeight(MD.optionsTabHeight.about)
    tab:Show()
end
MD:RegisterCallback("ShowOptionsTab", ShowTab)
