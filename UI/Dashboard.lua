-- Rank dashboard (/md): a Cell-style movable frame (header bar with title and
-- close), a row of spell tabs, the header/hint lines and the recap. The rank
-- table itself lives in UI/Dashboard_Rows.lua and the "Simulate" strip in
-- UI/Dashboard_Simulate.lua; both load first and hand back a small object.
-- Settings are in the options frame (UI/OptionsFrame.lua).
local _, MD = ...
local UI = MD.UI

local WIDTH, HEIGHT = 912, 617 -- +20% (author, 2026-09-06: not everything fit); was 760 x 514
local frame, statsFS, calloutFS, hintFS, recapFS, messageFS, effectiveCB
local rankTable, simStrip, wasteView, reviewView, nav
local currentGroup = "spells"
local currentFamily = "HealingTouch"
local userPicked = false   -- once a tab is clicked, stop picking one automatically

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
local function Shown(f, on) if not f then return end if on then f:Show() else f:Hide() end end

local function Refresh()
    if not frame or not frame:IsShown() then return end

    -- Only two groups own this furniture. Simulate and Settings bring their own
    -- panel, and drawing the rank table's header lines and the what-if strip on
    -- top of it is what the author's screenshots showed (v0.11.5).
    local spells, reports = currentGroup == "spells", currentGroup == "reports"
    Shown(statsFS, spells or reports)
    Shown(calloutFS, spells or reports)
    Shown(hintFS, spells or reports)
    Shown(recapFS, spells or reports)
    if simStrip then simStrip:SetShown(spells and MD.player.isDruid) end
    Shown(effectiveCB, spells and MD.player.isDruid)
    if not (spells or reports) then
        messageFS:Hide()
        return
    end
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
        unreported > 0 and string.format(", +%d mp5 not in the API (Dreamstate %d, measured %d)",
            unreported * 5 + 0.5, RM.dreamstate * 5 + 0.5, RM.measured * 5 + 0.5) or "")

    -- the Waste and Review views each replace the rank table, its hint and its
    -- callout
    -- a pane is built on first sight, so any of these may still be nil
    local review = (currentFamily == "Review" or currentFamily == "Runs")
    if review and reviewView then
        effectiveCB:Hide()
        messageFS:Hide()
        if rankTable then rankTable:Release() end
        calloutFS:SetText("|cffffcc00The fights this character recorded, and what the engine can reproduce about each.|r")
        hintFS:SetText("|cff888888A greyed row is a fight the model could not replay - the reason is in the validate " ..
            "column. Coach only runs on fights that passed, because advice from a fight the engine gets wrong is worse than none.|r")
        reviewView:SetSource(currentFamily == "Runs" and "run" or "fights")
        reviewView:Render()
        return
    end

    local waste = currentFamily == "Waste"
    Shown(effectiveCB, not waste and not review and MD.player.isDruid and spells)
    if waste and wasteView then
        messageFS:Hide()
        if rankTable then rankTable:Release() end
        calloutFS:SetText("|cffffcc00Where the mana went and where the healing was wasted, from your own combat log.|r")
        hintFS:SetText("|cff888888Overheal is a share of gross healing. Wasted mana is each event that healed nothing, " ..
            "carrying its share of the cast's cost. Mana belongs to the spell, so it only appears in Spell mode.|r")
        wasteView:Render()
        return
    end

    if review or waste or not spells then return end
    if not MD.player.isDruid then
        if rankTable then rankTable:Release() end
        messageFS:Show()
        messageFS:SetText("Rank analysis is Druid-only in v1 - the OOM widget, datatext and advisor still work for your class.")
        calloutFS:SetText("")
        return
    end

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
    if not res or not rankTable then
        if rankTable then rankTable:Release() end
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
-- frame construction (v0.11.1: the navigation kit, docs/SPEC-v0.11.md)
--
-- The window is groups down the left and that group's views along the top. The
-- three panes -- the rank table, Waste and Review -- are unchanged and simply
-- parent themselves to the content frame; they are built the first time their
-- view is selected and cached after, so a non-druid never builds a rank table.
--
-- `currentFamily` is the selected VIEW id, which is why the families and the
-- two reports can share one variable: a family id ("Rejuvenation") and a report
-- id ("Waste") are both just the view that is showing.
--------------------------------------------------------------------------------
local CONTENT_W = 912          -- what the panes were laid out for; the window is wider by the nav
local NAV_W, NAV_PAD = 108, 8
local WIN_W, WIN_H = CONTENT_W + NAV_W + 2 * NAV_PAD, 646

-- Reports' views depend on what has been recorded.
local function ReportViews()
    local views = { { id = "Waste", text = "Waste" }, { id = "Review", text = "Review" } }
    if MD.RunRecorder and #(MD.RunRecorder:List()) > 0 then
        views[#views + 1] = { id = "Runs", text = "Runs" }
    end
    return views
end

local function Groups()
    local spells = {}
    for _, family in ipairs(MD.SpellData.familyOrder) do
        local info = MD.SpellData.families[family]
        if info and not info.exclude then
            spells[#spells + 1] = { id = family, text = info.label or family,
                                    hidden = not MD.player.isDruid }
        end
    end
    return {
        { id = "spells", text = "Spells", views = spells },
        -- Waste and Review work for any class: a recorded stream is numbers
        -- Runs appears only once one has been recorded: a view that is always
        -- empty teaches nothing, and nav:SetViews puts it there the moment a
        -- run is stored (v0.11.4)
        { id = "reports", text = "Reports", views = ReportViews() },
        { id = "simulate", text = "Simulate", views = {
            { id = "build", text = "Build a fight" } } },
        { id = "settings", text = "Settings", views = {
            { id = "general", text = "General" }, { id = "about", text = "About" } } },
    }
end

local function CreateDashboard()
    if nav then return end     -- MD_READY can be fired more than once
    nav = UI.CreateNavFrame("ManaDemon", "ManaDemonDashboard", WIN_W, WIN_H, Groups(),
        function(group, view, content)
            -- built once, on first sight
            if group == "reports" and view == "Waste" then
                wasteView = MD.DashboardParts.CreateWaste(content, CONTENT_W)
                wasteView.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -104)
                wasteView.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 24)
                return wasteView.frame
            elseif group == "reports" and view == "Runs" then
                -- the Review pane already knows how to list a run's pulls; the
                -- Runs view is that pane with a run selected instead of Fights
                if not reviewView then
                    reviewView = MD.DashboardParts.CreateReview(content, CONTENT_W)
                    reviewView.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -104)
                    reviewView.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 24)
                end
                return reviewView.frame
            elseif group == "reports" and view == "Review" then
                reviewView = MD.DashboardParts.CreateReview(content, CONTENT_W)
                reviewView.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -104)
                reviewView.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 24)
                return reviewView.frame
            elseif group == "simulate" then
                if MD.AdoptSimPanel then return MD:AdoptSimPanel(content) end
                return nil
            elseif group == "settings" then
                -- one panel for both settings views; the tabs inside it show
                -- and hide themselves on the ShowOptionsTab callback
                if MD.AdoptOptionsPanel then MD:AdoptOptionsPanel(content) end
                return MD.optionsFrame
            elseif group == "spells" and not rankTable then
                rankTable = MD.DashboardParts.CreateTable(content, CONTENT_W)
                rankTable.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -104)
                rankTable.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 24)
                return rankTable.frame
            end
            return rankTable and rankTable.frame or nil
        end,
        function(group, view)
            currentGroup, currentFamily = group, view
            userPicked = true
            MD:Fire("UI_VIEW_SELECTED", group, view)
            Refresh()

        end)
    frame = nav.frame
    tinsert(UISpecialFrames, "ManaDemonDashboard") -- ESC closes
    local content = nav:Content()

    -- Settings is the fourth group now, not a button that opens a second window
    effectiveCB = UI.CreateCheckButton(frame, "Effective", function(checked)
        MD.db.effectiveMode = checked
        Refresh()
    end, "Overheal-adjusted values", "Heal, HPM and HPS become value x (1 - measured overheal),",
        "from your own combat log. Mana, Cast and To OOM never move.",
        "A grey ? means that rank has no measurement of its own yet.")
    effectiveCB:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -100, -2) -- label runs right of the box
    effectiveCB:SetShown(MD.player.isDruid)

    simStrip = MD.DashboardParts.CreateStrip(content, 2, -2, Refresh)

    statsFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statsFS:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -46)
    statsFS:SetJustifyH("LEFT")
    statsFS:SetWidth(CONTENT_W - 8)

    calloutFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    calloutFS:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -64)
    calloutFS:SetJustifyH("LEFT")
    calloutFS:SetWidth(CONTENT_W - 8)

    hintFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hintFS:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -82)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetWidth(CONTENT_W - 8)

    messageFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageFS:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -110)
    messageFS:SetJustifyH("LEFT")
    messageFS:SetWidth(CONTENT_W - 8)
    messageFS:Hide()

    recapFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    recapFS:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 2, 2)
    recapFS:SetJustifyH("LEFT")
    recapFS:SetWidth(CONTENT_W - 8)

    frame:SetScript("OnShow", function()
        effectiveCB:SetChecked(MD.db.effectiveMode and true or false)
        local path = MD.db.uiPath
        if path and path[1] then
            nav:Select(path[1], path[2])
        else
            nav:Select("spells", DefaultFamily())
        end
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

function MD:SelectedView()
    if not nav then return nil end
    return nav:Selected()
end

-- Every entry point that wants a particular view goes through here: /md sim,
-- /md options, the minimap button's right-click. The window opens if it is
-- closed, which is what all of them used to do with their own window.
function MD:SelectView(group, view)
    if not nav then return end
    if not frame:IsShown() then frame:Show() end
    nav:Select(group, view)
end

function MD:ToggleDashboard()
    if not frame then return end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- Kept for the minimap button's right-click.
function MD:OpenDashboardSettings()
    MD:ShowOptionsFrame("general")
end

-- a run stored while the window is open makes the Runs view appear
local function RefreshReportViews()
    if nav then nav:SetViews("reports", ReportViews()) end
end
MD:RegisterCallback("RUN_STORED", RefreshReportViews)

MD:RegisterCallback("MD_READY", CreateDashboard)
MD:RegisterCallback("TALENTS_CHANGED", Refresh)
MD:RegisterCallback("SPELLS_REBUILT", Refresh)
MD:RegisterCallback("FIGHT_RECORDED", Refresh)
MD:RegisterCallback("FORM_CHANGED", Refresh) -- Tree of Life: costs and aura change
MD:On("PLAYER_EQUIPMENT_CHANGED", function()
    if frame and frame:IsShown() then Refresh() end
end)
