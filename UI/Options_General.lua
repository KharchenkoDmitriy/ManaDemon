-- Options > General: everything the slash commands can do, in titled panes.
local _, MD = ...
local UI = MD.UI

local tab = UI.CreateFrame("ManaDemonOptionsFrame_GeneralTab", MD.optionsFrame, nil, nil, true)
tab:SetAllPoints(MD.optionsFrame)
tab:Hide()

local lockCB, restCB, tipCB, cdCB, muteCB, drinkCB, minimapCB, halfLifeSlider, treeAuraCB, ngCB

--------------------------------------------------------------------------------
-- OOM widget
--------------------------------------------------------------------------------
local function CreateWidgetPane()
    local pane = UI.CreateTitledPane(tab, "OOM Widget", 205, 164)
    pane:SetPoint("TOPLEFT", tab, "TOPLEFT", 5, -5)

    lockCB = UI.CreateCheckButton(pane, "Lock widget", function(checked)
        MD.db.locked = checked
        if MD.UpdateVisibility then MD:UpdateVisibility() end
    end, "Lock widget", "Uncheck to drag the OOM clock.", "It stays visible while unlocked.")
    lockCB:SetPoint("TOPLEFT", pane, 5, -27)

    restCB = UI.CreateCheckButton(pane, "Show rest time", function(checked)
        MD.db.showRest = checked
    end, "Show rest time", "Grey 'rest 2:10' next to the clock:", "time to full if you stop casting right now.")
    restCB:SetPoint("TOPLEFT", lockCB, "BOTTOMLEFT", 0, -9)

    tipCB = UI.CreateCheckButton(pane, "Tooltip on hover", function(checked)
        MD.db.widgetTooltip = checked
        if MD.UpdateVisibility then MD:UpdateVisibility() end
    end, "Tooltip on hover", "Hovering the clock shows the full mana breakdown,",
        "and left-click opens the dashboard. This needs mouse input on the",
        "widget, so it also swallows clicks in its own small rectangle.")
    tipCB:SetPoint("TOPLEFT", restCB, "BOTTOMLEFT", 0, -9)

    cdCB = UI.CreateCheckButton(pane, "Show mana cooldown", function(checked)
        MD.db.showCooldown = checked
    end, "Mana cooldown projection", "Under 90s to OOM, with Innervate (or a potion) ready and",
        "worth at least 10% of your pool, the clock shows 'inn 2:10':",
        "what it becomes if you press it now. It replaces 'rest' there.")
    cdCB:SetPoint("TOPLEFT", tipCB, "BOTTOMLEFT", 0, -9)

    local resetBtn = UI.CreateButton(pane, "Reset position", "accent-hover", { 150, 17 })
    resetBtn:SetPoint("TOPLEFT", cdCB, "BOTTOMLEFT", 0, -12)
    resetBtn:SetScript("OnClick", function()
        local d = MD.DEFAULTS.pos
        MD.db.pos = { d[1], d[2], d[3], d[4] }
        if MD.ApplyWidgetPosition then MD:ApplyWidgetPosition() end
        MD:Print("widget position reset.")
    end)
    return pane
end

--------------------------------------------------------------------------------
-- Alerts
--------------------------------------------------------------------------------
local function CreateAlertsPane(anchor)
    local pane = UI.CreateTitledPane(tab, "Alerts", 205, 95)
    pane:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)

    muteCB = UI.CreateCheckButton(pane, "Mute alerts", function(checked)
        MD.db.muted = checked
    end, "Mute alerts", "Silences the advisor (Innervate / potion timing),", "the rank-shift toast and the drink reminder.")
    muteCB:SetPoint("TOPLEFT", pane, 5, -27)

    drinkCB = UI.CreateCheckButton(pane, "Drink reminder", function(checked)
        MD.db.drinkReminder = checked
    end, "Drink reminder", "Out of combat, below 90% mana and not drinking: 'Drink.'")
    drinkCB:SetPoint("TOPLEFT", muteCB, "BOTTOMLEFT", 0, -9)
    return pane
end

--------------------------------------------------------------------------------
-- Model
--------------------------------------------------------------------------------
local function CreateModelPane()
    local pane = UI.CreateTitledPane(tab, "Model", 205, 175)
    pane:SetPoint("TOPLEFT", tab, "TOPLEFT", 222, -5)

    halfLifeSlider = UI.CreateSlider("Spend half-life (s)", pane, 5, 60, 160, 1, function(value)
        MD.db.halfLife = value
    end, nil, false, "Spend half-life", "How fast the spend estimator forgets old casts.",
        "Shorter reacts faster, longer is steadier. Default 15s.")
    halfLifeSlider:SetPoint("TOPLEFT", pane, 22, -45)

    treeAuraCB = UI.CreateCheckButton(pane, "Count Tree of Life aura", function(checked)
        MD.db.treeAura = checked
        MD:Fire("FORM_CHANGED", MD:InTreeForm())
    end, "Tree of Life aura in heal values", "Party members under your Tree of Life aura receive",
        "25% of your Spirit as extra healing. It is not part of the", "+healing stat, so the dashboard adds it while you are in form.")
    treeAuraCB:SetPoint("TOPLEFT", pane, 5, -88)

    ngCB = UI.CreateCheckButton(pane, "Average in Nature's Grace", function(checked)
        MD.db.naturesGrace = checked
        MD:Fire("TALENTS_CHANGED")
    end, "Nature's Grace in cast times", "A spell crit takes 0.5s off your next cast, so chain-casting",
        "Healing Touch or Regrowth averages out faster than the tooltip says.",
        "Marked with a grey * in the dashboard's Cast column.")
    ngCB:SetPoint("TOPLEFT", treeAuraCB, "BOTTOMLEFT", 0, -9)

    local ohBtn = UI.CreateButton(pane, "Reset overheal data", "red-hover", { 150, 17 }, false, false, nil, nil,
        "Reset overheal data", "The dashboard's 'Effective' numbers come from your own combat log,",
        "per character. Clear it after a gear jump or a change of content -",
        "otherwise it forgets on its own over about 150 healing events.")
    ohBtn:SetPoint("TOPLEFT", ngCB, "BOTTOMLEFT", 0, -12)
    ohBtn:SetScript("OnClick", function()
        if MD.Overheal then MD.Overheal:Reset() end
    end)
    return pane
end

--------------------------------------------------------------------------------
-- Misc
--------------------------------------------------------------------------------
local function CreateMiscPane(anchor)
    local pane = UI.CreateTitledPane(tab, "Misc", 205, 125)
    pane:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)

    minimapCB = UI.CreateCheckButton(pane, "Show minimap button", function(checked)
        MD.db.minimap.hide = not checked
        if MD.UpdateMinimapButton then MD:UpdateMinimapButton() end
    end)
    minimapCB:SetPoint("TOPLEFT", pane, 5, -27)

    local debugBtn = UI.CreateButton(pane, "Debug Console", "accent-hover", { 150, 17 }, false, false, nil, nil,
        "Debug Console", "Live log of regen, mana ticks, casts and the clock state.", "Enable logging there; Copy exports it as text.")
    debugBtn:SetPoint("TOPLEFT", minimapCB, "BOTTOMLEFT", 0, -12)
    debugBtn:SetScript("OnClick", function()
        if MD.ToggleDebugConsole then MD:ToggleDebugConsole() end
    end)

    local verifyBtn = UI.CreateButton(pane, "Verify spell data", "accent-hover", { 150, 17 }, false, false, nil, nil,
        "Verify spell data", "Same as /md verify: static TBC spell table vs the live client,", "plus an input snapshot. Output goes to chat and the debug log.")
    verifyBtn:SetPoint("TOPLEFT", debugBtn, "BOTTOMLEFT", 0, -5)
    verifyBtn:SetScript("OnClick", function()
        if MD.RunVerify then MD:RunVerify() end
    end)

    local regenBtn = UI.CreateButton(pane, "Regen test (30s)", "accent-hover", { 150, 17 }, false, false, nil, nil,
        "Regen test", "Stand idle at partial mana, no drink, no casting, for 30s.",
        "Compares observed mana gain with GetManaRegen and tells whether", "Dreamstate is included in the API value.")
    regenBtn:SetPoint("TOPLEFT", verifyBtn, "BOTTOMLEFT", 0, -5)
    regenBtn:SetScript("OnClick", function()
        if MD.RunRegenTest then MD:RunRegenTest(30) end
    end)
    return pane
end

--------------------------------------------------------------------------------
-- build + show
--------------------------------------------------------------------------------
local built = false
local function Build()
    if built then return end
    built = true
    local widgetPane = CreateWidgetPane()
    CreateAlertsPane(widgetPane)
    local modelPane = CreateModelPane()
    CreateMiscPane(modelPane)
end

local function ShowTab(which)
    if which ~= "general" then
        tab:Hide()
        return
    end
    Build()
    tab:Show()
    lockCB:SetChecked(MD.db.locked)
    restCB:SetChecked(MD.db.showRest ~= false)
    tipCB:SetChecked(MD.db.widgetTooltip ~= false)
    cdCB:SetChecked(MD.db.showCooldown ~= false)
    muteCB:SetChecked(MD.db.muted)
    drinkCB:SetChecked(MD.db.drinkReminder)
    minimapCB:SetChecked(not MD.db.minimap.hide)
    halfLifeSlider:SetValue(MD.db.halfLife or 15)
    treeAuraCB:SetChecked(MD.db.treeAura ~= false)
    ngCB:SetChecked(MD.db.naturesGrace ~= false)
end
MD:RegisterCallback("ShowOptionsTab", ShowTab)
