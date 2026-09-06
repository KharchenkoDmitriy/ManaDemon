-- Rank dashboard (/md): a Cell-style movable frame (header bar with title and
-- close), a row of spell tabs, the header/hint lines and the recap. The rank
-- table itself lives in UI/Dashboard_Rows.lua and the "Simulate" strip in
-- UI/Dashboard_Simulate.lua; both load first and hand back a small object.
-- Settings are in the options frame (UI/OptionsFrame.lua).
local _, MD = ...
local UI = MD.UI

local WIDTH, HEIGHT = 760, 514 -- +18 for the Simulate strip's second row
local frame, statsFS, calloutFS, hintFS, recapFS, messageFS, effectiveCB
local rankTable, simStrip, wasteView, reviewView
local currentFamily = "HealingTouch"
local userPicked = false   -- once a tab is clicked, stop picking one automatically
local spellTabs, highlightTab = {}, nil

-- The family this character actually casts most (persisted counts kept by the
-- spend tracker), so the dashboard opens on the spell that matters. The first
-- dungeon log had one Healing Touch in 29 minutes and 245 Lifeblooms; it opened
-- on Healing Touch.
local function DefaultFamily()
    local counts = MD.cdb and MD.cdb.familyCasts
    local best, bestN = "HealingTouch", -1
    if counts then
        for _, family in ipairs(MD.SpellData.familyOrder) do
            local info = MD.SpellData.families[family]
            if info and not info.exclude and (counts[family] or 0) > bestN then
                best, bestN = family, counts[family] or 0
            end
        end
    end
    return best
end

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

    -- the Waste and Review views each replace the rank table, its hint and its
    -- callout
    local review = currentFamily == "Review"
    reviewView.frame:SetShown(review)
    if review then
        wasteView.frame:Hide()
        rankTable.frame:Hide()
        effectiveCB:Hide()
        messageFS:Hide()
        rankTable:Release()
        calloutFS:SetText("|cffffcc00The fights this character recorded, and what the engine can reproduce about each.|r")
        hintFS:SetText("|cff888888A greyed row is a fight the model could not replay - the reason is in the validate " ..
            "column. Coach only runs on fights that passed, because advice from a fight the engine gets wrong is worse than none.|r")
        reviewView:Render()
        return
    end

    local waste = currentFamily == "Waste"
    wasteView.frame:SetShown(waste)
    rankTable.frame:SetShown(not waste)
    effectiveCB:SetShown(not waste)
    if waste then
        messageFS:Hide()
        rankTable:Release()
        calloutFS:SetText("|cffffcc00Where the mana went and where the healing was wasted, from your own combat log.|r")
        hintFS:SetText("|cff888888Overheal is a share of gross healing. Wasted mana is each event that healed nothing, " ..
            "carrying its share of the cast's cost. Mana belongs to the spell, so it only appears in Spell mode.|r")
        wasteView:Render()
        return
    end

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
        if info.costCtx then
            -- the client can only price the form and talents you actually have
            statsFS:SetText(statsFS:GetText() ..
                "   |cffff9933costs from the static table while simulating form/talents|r")
        end
    end
    if info and info.relic then
        local r = info.relic
        local fl = r.family and MD.SpellData.families[r.family] and MD.SpellData.families[r.family].label or "?"
        local what = r.flat and string.format("+%d %s", r.flat, fl)
            or r.perTick and string.format("+%d per %s tick", r.perTick, fl)
            or r.castReduce and string.format("-%.2fs %s cast", r.castReduce, fl)
            or r.cost and string.format("-%d mana %s", r.cost, fl)
            or r.aura and string.format("+%d Tree aura", r.aura) or ""
        if r.verify then what = what .. ", unverified" end
        statsFS:SetText(statsFS:GetText() .. string.format("   relic: %s (%s)", r.name, what))
    end
    if info and info.treeAura > 0 then
        statsFS:SetText((statsFS:GetText():gsub("^%+%d+ healing",
            string.format("+%d healing (+%d Tree of Life aura on party targets)", info.statBonus, info.treeAura))))
    elseif info and info.inTree then
        statsFS:SetText((statsFS:GetText():gsub("^%+%d+ healing", "%0 (Tree aura not counted - see Settings)")))
    end
    if info then
        -- One line only: this sits 18px above the table, and the old paragraph
        -- wrapped onto the rows. The full glossary is the header row's tooltip.
        hintFS:SetFormattedText("|cff888888HPM heal per mana - HPS heal per second of cast - " ..
            "To OOM chain-casts from %d mana at %d mp5 casting regen.  Hover the header or any row.|r",
            info.mana, info.castingRegen * 5 + 0.5)
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
            ohNote = string.format("  |cff888888overheal %d%% (%d events)|r", frac * 100, n)
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
    -- the Waste view is a fifth tab after the families
    local wasteBtn = UI.CreateButton(frame, "Waste", "accent-hover", { 80, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
    wasteBtn.id = "Waste"
    wasteBtn:SetPoint("LEFT", prev, "RIGHT", -1, 0)
    buttons[#buttons + 1] = wasteBtn
    -- and Review after it: also class-agnostic, because the recorded stream is
    -- just numbers
    local reviewBtn = UI.CreateButton(frame, "Review", "accent-hover", { 80, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
    reviewBtn.id = "Review"
    reviewBtn:SetPoint("LEFT", wasteBtn, "RIGHT", -1, 0)
    buttons[#buttons + 1] = reviewBtn
    highlightTab = UI.CreateButtonGroup(buttons, function(id)
        currentFamily = id
        userPicked = true
        Refresh()
    end)

    local settingsBtn = UI.CreateButton(frame, "Settings", "accent-hover", { 90, 20 }, false, false, UI.FONT_TITLE, UI.FONT_TITLE_DISABLE)
    settingsBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
    settingsBtn:SetScript("OnClick", function() MD:ShowOptionsFrame("general") end)

    effectiveCB = UI.CreateCheckButton(frame, "Effective", function(checked)
        MD.db.effectiveMode = checked
        Refresh()
    end, "Overheal-adjusted values", "Heal, HPM and HPS become value x (1 - measured overheal),",
        "from your own combat log. Mana, Cast and To OOM never move.",
        "A grey ? means that rank has no measurement of its own yet.")
    effectiveCB:SetPoint("LEFT", settingsBtn, "LEFT", -80, 0) -- label runs right of the box
    effectiveCB:SetShown(MD.player.isDruid)
    -- Waste and Review work for any class; only the rank tabs are druid-only
    wasteBtn:Show()
    reviewBtn:Show()

    simStrip = MD.DashboardParts.CreateStrip(frame, 16, -42, Refresh)

    statsFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statsFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -86)
    statsFS:SetJustifyH("LEFT")
    statsFS:SetWidth(WIDTH - 32)

    calloutFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    calloutFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -104)
    calloutFS:SetJustifyH("LEFT")
    calloutFS:SetWidth(WIDTH - 32)

    hintFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hintFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -120)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetWidth(WIDTH - 32)

    messageFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -144)
    messageFS:SetJustifyH("LEFT")
    messageFS:SetWidth(WIDTH - 32)
    messageFS:Hide()

    rankTable = MD.DashboardParts.CreateTable(frame, WIDTH)
    rankTable.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -138)
    rankTable.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 40)

    wasteView = MD.DashboardParts.CreateWaste(frame, WIDTH)
    wasteView.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -138)
    wasteView.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 40)

    reviewView = MD.DashboardParts.CreateReview(frame, WIDTH)
    reviewView.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -138)
    reviewView.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 40)

    recapFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    recapFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
    recapFS:SetJustifyH("LEFT")
    recapFS:SetWidth(WIDTH - 32)

    frame:SetScript("OnShow", function()
        effectiveCB:SetChecked(MD.db.effectiveMode and true or false)
        if not userPicked then currentFamily = DefaultFamily() end
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
