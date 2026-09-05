-- Rank dashboard (/md): a Cell-style movable frame (header bar with title and
-- close), a row of spell tabs, the header/hint lines and the recap. The rank
-- table itself lives in UI/Dashboard_Rows.lua and the "Simulate" strip in
-- UI/Dashboard_Simulate.lua; both load first and hand back a small object.
-- Settings are in the options frame (UI/OptionsFrame.lua).
local _, MD = ...
local UI = MD.UI

local WIDTH, HEIGHT = 760, 496
local frame, statsFS, calloutFS, hintFS, recapFS, messageFS, effectiveCB
local rankTable, simStrip
local currentFamily = "HealingTouch"
local spellTabs, highlightTab = {}, nil

--------------------------------------------------------------------------------
-- refresh
--------------------------------------------------------------------------------
local function Refresh()
    if not frame or not frame:IsShown() then return end
    messageFS:Hide()

    -- overall info line: current regen state
    local RM = MD.Regen
    local bonus = 0
    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        if ok then bonus = v or 0 end
    end
    local spiritPerSec, mp5Gear, _, unreported = RM:Components()
    statsFS:SetFormattedText(
        "+%d healing   regen |cff33ff66%d|r mana/s out of 5SR, |cffffaa33%d|r casting   ~%d mp5 spirit, ~%d mp5 gear/buffs%s",
        bonus, RM.base, RM.casting, spiritPerSec * 5, mp5Gear,
        unreported > 0 and string.format(", +%d mp5 Dreamstate (not in the API)", unreported * 5 + 0.5) or "")

    if not MD.player.isDruid then
        rankTable:Release()
        messageFS:Show()
        messageFS:SetText("Rank analysis is Druid-only in v1 - the OOM widget, datatext and advisor still work for your class.")
        calloutFS:SetText("")
        return
    end

    if highlightTab then highlightTab(currentFamily) end

    local results = MD.RankMath:Compute()
    local info = MD.RankMath.info
    if info then
        simStrip:SetPlaceholders(info.live)
        if info.simulated then
            statsFS:SetText("|cffff9933SIMULATION|r  " .. statsFS:GetText())
        end
    end
    if info and info.relic then
        local r = info.relic
        local what = r.flat and string.format("+%d %s", r.flat, MD.SpellData.families[r.family].label)
            or r.perTick and string.format("+%d per %s tick", r.perTick, MD.SpellData.families[r.family].label)
            or r.aura and string.format("+%d Tree aura", r.aura) or ""
        statsFS:SetText(statsFS:GetText() .. string.format("   relic: %s (%s)", r.name, what))
    end
    if info and info.treeAura > 0 then
        statsFS:SetText((statsFS:GetText():gsub("^%+%d+ healing",
            string.format("+%d healing (+%d Tree of Life aura on party targets)", info.statBonus, info.treeAura))))
    elseif info and info.inTree then
        statsFS:SetText((statsFS:GetText():gsub("^%+%d+ healing", "%0 (Tree aura not counted - see Settings)")))
    end
    if info then
        hintFS:SetFormattedText("|cff888888HPM = heal per mana.  HPS = heal per second of cast time (1.5s GCD for instants).  " ..
            "HP5 = healing per 5s you can sustain at zero mana, casting only as regen pays (5SR-aware, %d / %d mp5 casting / resting).  " ..
            "To OOM = chain-casts from your current %d mana.%s|r",
            info.castingRegen * 5 + 0.5, info.baseRegen * 5 + 0.5, info.mana,
            info.naturesGrace > 0 and "  * = Nature's Grace averaged in." or "")
    end

    local res = results[currentFamily]
    if not res then
        rankTable:Release()
        calloutFS:SetText("")
        return
    end

    local tolNote = (MD:InTreeForm() and not res.tol) and "  |cffff4444(not castable in Tree form)|r" or ""
    local ohNote = ""
    if MD.Overheal then
        local frac, n = MD.Overheal:FamilyFraction(currentFamily)
        if frac then
            ohNote = string.format("  |cff888888overheal %d%% measured over %d %s events%s|r",
                frac * 100, n, res.label,
                MD.db.effectiveMode and "" or " - tick Effective to apply it")
        end
    end
    calloutFS:SetText("|cffffcc00" .. (res.callout or "") .. "|r" .. tolNote .. ohNote)

    rankTable:Render(res.rows)

    -- recap
    local last = MD.fightHistory and MD.fightHistory[#MD.fightHistory]
    if last then
        recapFS:SetText("Last fight: " .. (last.summary or "-") ..
            (#MD.fightHistory > 1 and ("  |cff666666(" .. #MD.fightHistory .. " fights this session)|r") or ""))
    else
        recapFS:SetText("|cff666666No fights recorded this session yet.|r")
    end
end

--------------------------------------------------------------------------------
-- frame construction
--------------------------------------------------------------------------------
local function CreateDashboard()
    frame = UI.CreateMovableFrame("ManaDemon", "ManaDemonDashboard", WIDTH, HEIGHT, "HIGH", 1, true)
    UI.StylizeFrame(frame, { 0.1, 0.1, 0.1, 0.95 })
    tinsert(UISpecialFrames, "ManaDemonDashboard") -- ESC closes

    -- spell tab row (druid only) + Settings on the right
    local prev
    local buttons = {}
    for _, family in ipairs(MD.SpellData.familyOrder) do
        local info = MD.SpellData.families[family]
        if info and not info.exclude then
            local btn = UI.CreateButton(frame, info.label, "accent-hover", { 110, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
            btn.id = family
            if prev then
                btn:SetPoint("LEFT", prev, "RIGHT", -1, 0)
            else
                btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
            end
            spellTabs[family] = btn
            buttons[#buttons + 1] = btn
            prev = btn
            btn:SetShown(MD.player.isDruid)
        end
    end
    highlightTab = UI.CreateButtonGroup(buttons, function(id)
        currentFamily = id
        Refresh()
    end)

    local settingsBtn = UI.CreateButton(frame, "Settings", "accent-hover", { 90, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
    settingsBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
    settingsBtn:SetScript("OnClick", function() MD:ShowOptionsFrame("general") end)

    effectiveCB = UI.CreateCheckButton(frame, "Effective", function(checked)
        MD.db.effectiveMode = checked
        Refresh()
    end, "Overheal-adjusted values", "Heal, HPM, HPS and HP5 become value x (1 - measured overheal),",
        "from your own combat log. Mana, Cast and To OOM never move.",
        "A grey ? means that rank has no measurement of its own yet.")
    effectiveCB:SetPoint("LEFT", settingsBtn, "LEFT", -80, 0) -- label runs right of the box
    effectiveCB:SetShown(MD.player.isDruid)

    simStrip = MD.DashboardParts.CreateStrip(frame, 16, -42, Refresh)

    statsFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statsFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -68)
    statsFS:SetJustifyH("LEFT")
    statsFS:SetWidth(WIDTH - 32)

    calloutFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    calloutFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -86)
    calloutFS:SetJustifyH("LEFT")
    calloutFS:SetWidth(WIDTH - 32)

    hintFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hintFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -102)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetWidth(WIDTH - 32)

    messageFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -126)
    messageFS:SetJustifyH("LEFT")
    messageFS:SetWidth(WIDTH - 32)
    messageFS:Hide()

    rankTable = MD.DashboardParts.CreateTable(frame, WIDTH)
    rankTable.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -120)
    rankTable.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 40)

    recapFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    recapFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
    recapFS:SetJustifyH("LEFT")
    recapFS:SetWidth(WIDTH - 32)

    frame:SetScript("OnShow", function()
        effectiveCB:SetChecked(MD.db.effectiveMode and true or false)
        Refresh()
    end)

    -- The "To OOM" column follows your current mana: re-render every 2s while
    -- the frame is open (rendering only; the model is event-driven).
    local acc = 0
    MD:OnTick(function(dt)
        if not frame:IsShown() then return end
        acc = acc + dt
        if acc >= 2 then
            acc = 0
            Refresh()
        end
    end)
end

function MD:ToggleDashboard()
    if not frame then return end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- Kept for the minimap button's right-click.
function MD:OpenDashboardSettings()
    MD:ShowOptionsFrame("general")
end

MD:RegisterCallback("MD_READY", CreateDashboard)
MD:RegisterCallback("TALENTS_CHANGED", Refresh)
MD:RegisterCallback("SPELLS_REBUILT", Refresh)
MD:RegisterCallback("FIGHT_RECORDED", Refresh)
MD:RegisterCallback("FORM_CHANGED", Refresh) -- Tree of Life: costs and aura change
MD:On("PLAYER_EQUIPMENT_CHANGED", function()
    if frame and frame:IsShown() then Refresh() end
end)
