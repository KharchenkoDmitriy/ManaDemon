-- The Simulation window (/md sim): a scenario you build by hand -- party size,
-- incoming damage, starting health -- run through the same engine that replays
-- your recorded fights, so the answer you get here is the answer you would have
-- got there.
--
-- The window is honest about where its numbers come from. Every damage preset
-- in Data/SimPresets.lua is a placeholder written by one healer; the moment a
-- recording exists for the zone you are in, "From recordings" replaces the
-- placeholders with measurement and the header says which is in use. A plan
-- built on invented damage is a plan about an invented fight, and the window
-- should never let you forget which one you are looking at.
local _, MD = ...
local UI = MD.UI

local WIDTH, HEIGHT = 640, 470
local frame

local partyID, damageID, situationID, duration = "5", "dungeon", "full", 60
local derived = nil            -- SimPlanner.FromRecordings result, or nil
local lastResult, searchHandle = nil, nil
local resultFS, headerFS, provFS

local function K(n)
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return string.format("%d", n + 0.5)
end

--------------------------------------------------------------------------------
-- Building the scenario. If a derived preset is loaded it overrides the
-- placeholder damage, per role, and the header says so.
--------------------------------------------------------------------------------
local function BuildScenario()
    local P = MD.SimPresets
    local targets = P.BuildTargets(partyID)
    local perTarget = nil
    if derived then
        perTarget = {}
        for i, tg in ipairs(targets) do
            local d = derived.byRole[tg.role]
            if d then perTarget[i] = { dps = d.dps, pulse = d.pulse } end
        end
    end
    return P.BuildScenario({
        party = partyID, damage = damageID, situation = situationID,
        dur = duration, targets = targets, perTarget = perTarget,
    })
end

--------------------------------------------------------------------------------
-- Running it. The same three plans the replay card compares, plus the search.
--------------------------------------------------------------------------------
local function Snapshot(r)
    return { manaSpent = r.manaSpent, healed = r.healed, overhealed = r.overhealed,
             lowestMana = r.lowestMana, lowest = { hp = r.lowest.hp },
             floorSeconds = r.floorSeconds, deaths = { n = r.deaths.n },
             waitFraction = r.waitFraction, maxWaitRun = r.maxWaitRun }
end

local function Render(lines)
    resultFS:SetText(table.concat(lines, "\n"))
end

local function Run()
    local SP, SM = MD.SimPlanner, MD.SimModel
    if not (SP and SM and MD.player.isDruid) then
        Render({ "Simulation needs the druid spell kit; it is Druid-only in v1." })
        return
    end
    if searchHandle then
        searchHandle:Cancel()
        searchHandle = nil
    end
    local kit = MD.RankMath:SpellKit()
    local scenario = BuildScenario()
    scenario.kit = kit

    local lines = {}
    local baselines = SP.Baselines(nil, kit)
    for _, b in ipairs(baselines) do
        local r = SP.RunPlan(scenario, b.plan, { critMode = "ev" })
        local s = Snapshot(r)
        lines[#lines + 1] = string.format("%-12s %7s mana   lowest %3d%%   %s",
            b.name, K(s.manaSpent), (s.lowest.hp or 1) * 100 + 0.5,
            s.deaths.n > 0 and string.format("|cffff5555%d died|r", s.deaths.n)
                or (s.floorSeconds > 0 and string.format("|cffffcc66%.0fs in danger|r", s.floorSeconds)
                or "|cff99dd99everyone held|r"))
    end
    Render({ "searching for a better plan...", unpack(lines) })

    searchHandle = SP.Search(scenario, { kit = kit, binds = SP.MaxRankBinds() },
        function(evals)
            Render({ string.format("searching... %d plans", evals), unpack(lines) })
        end,
        function(best, bestResult, evals)
            searchHandle = nil
            if not best then Render({ "cancelled.", unpack(lines) }) return end
            local out = {}
            out[#out + 1] = string.format("|cffffcc00Best plan after %d evaluations|r", evals)
            local d = best.binds.Regrowth or best.binds.HealingTouch
            if best.binds.Swiftmend then
                out[#out + 1] = string.format("  1. Under %d%% with a HoT: Swiftmend",
                    best.swiftmendBelow * 100 + 0.5)
            end
            if not best.noDirect and d then
                local sd = MD.SpellData.spells[d]
                out[#out + 1] = string.format("  2. Under %d%%: %s R%d",
                    best.directBelow * 100 + 0.5, MD.SpellData.families[sd.family].label, sd.rank)
            end
            if best.rollStacks > 0 then
                out[#out + 1] = string.format("  3. Keep Lifebloom x%d rolling on the tank", best.rollStacks)
            end
            if best.binds.Rejuvenation then
                local sd = MD.SpellData.spells[best.binds.Rejuvenation]
                out[#out + 1] = string.format("  4. Under %d%% without Rejuvenation: %s R%d",
                    best.hotBelow * 100 + 0.5, MD.SpellData.families[sd.family].label, sd.rank)
            end
            out[#out + 1] = string.format("  5. Otherwise %s (%d%% of the fight)",
                best.filler and "Lifebloom on the tank" or "wait",
                (bestResult.waitFraction or 0) * 100 + 0.5)
            out[#out + 1] = ""
            out[#out + 1] = string.format("%-12s %7s mana   lowest %3d%%", "best",
                K(bestResult.manaSpent), (bestResult.lowest.hp or 1) * 100 + 0.5)
            for _, l in ipairs(lines) do out[#out + 1] = l end

            -- Monte Carlo, synthetic mode only: how often does this plan lose
            -- somebody when the fight is not exactly average?
            local mc = MD.SimPlanner.MonteCarlo(scenario, best, derived)
            if mc then
                out[#out + 1] = ""
                out[#out + 1] = string.format(
                    "|cff888888over %d randomised replicates: someone below the floor %d%% of the time, a death %d%%|r",
                    mc.k, mc.floorRate * 100 + 0.5, mc.deathRate * 100 + 0.5)
            end
            out[#out + 1] = ""
            out[#out + 1] = "|cff888888caveat: rolled crits in the replicates, EV crit elsewhere; no defensives, " ..
                "no threat, no kill speed. " ..
                (derived and "Damage measured from your recordings." or
                 "Damage is a PLACEHOLDER - press 'From recordings' once you have some.") .. "|r"
            Render(out)
            lastResult = bestResult
        end)
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------
-- v0.11.3: a PANEL, not a window. The dashboard's navigation hosts it as its
-- third group; everything below is unchanged and still anchors to `frame`.
local function Build()
    if frame then return end
    frame = UI.CreateFrame("ManaDemonSimPanel", UIParent, WIDTH, HEIGHT, true)
    frame:Hide()

    local function Group(label, list, x, y, width, get, set)
        local fs = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
        fs:SetTextColor(0.7, 0.7, 0.7)
        fs:SetText(label)
        local buttons, prev = {}, nil
        for _, def in ipairs(list) do
            local b = UI.CreateButton(frame, def.label, "accent-hover", { width, 16 }, false, false,
                UI.FONT_SMALL, nil, def.label, def.why or def.note or "")
            b.id = def.id
            if prev then b:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 1)
            else b:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -4) end
            buttons[#buttons + 1] = b
            prev = b
        end
        local highlight = UI.CreateButtonGroup(buttons, set)
        highlight(get())
        return highlight
    end

    Group("party", MD.SimPresets.PARTY, 14, -34, 160,
        function() return partyID end, function(id) partyID = id end)
    Group("incoming damage", MD.SimPresets.DAMAGE, 186, -34, 190,
        function() return damageID end, function(id) damageID = id; derived = nil end)
    Group("situation", MD.SimPresets.SITUATION, 388, -34, 170,
        function() return situationID end, function(id) situationID = id end)

    local durSlider = UI.CreateSlider("Fight length (s)", frame, 20, 300, 160, 10, function(v)
        duration = v
    end, nil, false, "How long the fight lasts.", "A 5-man pull is 25-45s; a boss is minutes.")
    durSlider:SetPoint("TOPLEFT", frame, "TOPLEFT", 30, -196)
    durSlider:SetValue(duration)

    local fromRecBtn = UI.CreateButton(frame, "From recordings", "accent-hover", { 130, 18 },
        false, false, nil, nil, "Use measured damage",
        "Replaces the placeholder damage with what actually happened",
        "in your recorded fights here, per role, with its provenance.")
    fromRecBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 210, -200)
    fromRecBtn:SetScript("OnClick", function()
        local zone = GetRealZoneText and GetRealZoneText() or nil
        derived = MD.SimPlanner and MD.SimPlanner.FromRecordings(zone)
        if not derived then derived = MD.SimPlanner and MD.SimPlanner.FromRecordings(nil) end
        if provFS then
            provFS:SetText(derived
                and ("|cff99dd99damage measured: " .. derived.provenance .. "|r")
                or "|cffff9966no recording long enough to derive damage from yet|r")
        end
    end)

    local runBtn = UI.CreateButton(frame, "Run", "accent-hover", { 80, 18 })
    runBtn:SetPoint("TOPLEFT", fromRecBtn, "TOPRIGHT", 8, 0)
    runBtn:SetScript("OnClick", Run)

    local cancelBtn = UI.CreateButton(frame, "Cancel", "red-hover", { 70, 18 })
    cancelBtn:SetPoint("TOPLEFT", runBtn, "TOPRIGHT", 8, 0)
    cancelBtn:SetScript("OnClick", function()
        if searchHandle then searchHandle:Cancel(); searchHandle = nil end
    end)

    provFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    provFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -226)
    provFS:SetWidth(WIDTH - 28)
    provFS:SetJustifyH("LEFT")
    provFS:SetText("|cff888888damage numbers are placeholders until you press 'From recordings'|r")

    headerFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    headerFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -244)
    headerFS:SetWidth(WIDTH - 28)
    headerFS:SetJustifyH("LEFT")

    local box = CreateFrame("Frame", nil, frame)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -262)
    box:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
    UI.StylizeFrame(box, { 0.1, 0.1, 0.1, 0.5 })
    resultFS = box:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    resultFS:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -8)
    resultFS:SetWidth(WIDTH - 40)
    resultFS:SetJustifyH("LEFT")
    resultFS:SetJustifyV("TOP")
    resultFS:SetSpacing(2)
    resultFS:SetText("|cff888888Pick a party, a damage pattern and a starting state, then Run.|r")

    frame:SetScript("OnHide", function()
        if searchHandle then searchHandle:Cancel(); searchHandle = nil end
    end)
end

-- The dashboard adopts the panel into its content area once, when its
-- navigation builds the Simulate group.
function MD:RefreshSimHeader()
    if not headerFS then return end
    headerFS:SetText(string.format("|cffffcc00%s, %ds%s|r",
        (function()
            for _, p in ipairs(MD.SimPresets.PARTY) do if p.id == partyID then return p.label end end
            return partyID
        end)(), duration, MD.player.isDruid and "" or "  (Druid-only in v1)"))
end

function MD:AdoptSimPanel(parent)
    Build()
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    frame:Show()
    return frame
end

-- /md sim: select the group. It opens the window if it is closed, and toggles
-- the window only when Simulate is already what is showing.
function MD:ToggleSimWindow()
    if MD.SelectView then
        local g = MD.SelectedView and MD:SelectedView()
        if g == "simulate" and MD.ToggleDashboard then MD:ToggleDashboard() return end
        MD:SelectView("simulate", "build")
        MD:RefreshSimHeader()
        return
    end
    Build()
    if frame:IsShown() then
        frame:Hide()
    else
        MD:RefreshSimHeader()
        frame:Show()
    end
end
