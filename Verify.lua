-- In-game verification harness (/md verify): diff the static SpellData table
-- against whatever the live client exposes, and dump the regen/healing inputs
-- so formulas can be checked by hand before any number is trusted.
-- /md fsrtest logs mana ticks for 15s to pin down the five-second-rule anchor.
-- /md regentest measures idle regen against GetManaRegen (Dreamstate check).
local _, MD = ...

function MD:RunVerify()
    local SD = MD.SpellData
    MD:Print("— verify: static data vs live client —")
    local mismatches, checkedCost, checkedCast = 0, 0, 0

    local ids = {}
    for id in pairs(SD.spells) do ids[#ids + 1] = id end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local s = SD.spells[id]
        local name, _, _, castMs = GetSpellInfo(id)
        local label = string.format("%s R%d (%d)", s.family, s.rank, id)

        if not name then
            mismatches = mismatches + 1
            MD:Print("|cffff4444MISSING|r " .. label .. " — spellID unknown to this client")
        else
            -- cast time (GetSpellInfo returns milliseconds)
            if s.cast and castMs and castMs > 0 then
                checkedCast = checkedCast + 1
                if math.abs(castMs / 1000 - s.cast) > 0.01 then
                    -- Naturalist lowers live HT cast time; report as info, not error.
                    local talentNote = (s.family == "HealingTouch" and MD:TalentRank("Naturalist") > 0)
                        and " (Naturalist affects live value)" or ""
                    mismatches = mismatches + 1
                    MD:Print(string.format("|cffffaa33CAST|r %s: table %.1fs, live %.1fs%s",
                        label, s.cast, castMs / 1000, talentNote))
                end
            end
            -- mana cost: the live value is what the model uses; the static
            -- table (with talent modifiers) should agree with it.
            local live = SD:LiveCost(id)
            local static = SD:StaticCost(id)
            if live ~= nil and static ~= nil then
                checkedCost = checkedCost + 1
                if live ~= static then
                    mismatches = mismatches + 1
                    MD:Print(string.format("|cffffaa33COST|r %s: static %d (base %d), live %d (used)",
                        label, static, s.cost, live))
                end
            end
        end
    end

    if checkedCost == 0 then
        MD:Print("|cffffaa33GetSpellPowerCost unavailable|r — the static table is in use; costs must be verified " ..
            "by hand (cast each rank at full idle mana and read the drop; compare to the table).")
    end
    MD:Print(string.format("checked %d cast times, %d costs — %d mismatch(es).",
        checkedCast, checkedCost, mismatches))

    -- unknown spells the tracker couldn't price
    local unknown = {}
    for id in pairs(MD.Spend.unknown) do unknown[#unknown + 1] = id end
    if #unknown > 0 then
        table.sort(unknown)
        local names = {}
        for _, id in ipairs(unknown) do
            names[#names + 1] = (GetSpellInfo(id) or "?") .. " (" .. id .. ")"
        end
        MD:Print("unpriced spells seen this session: " .. table.concat(names, ", "))
    end

    MD:Print("— input snapshot —")
    for _, line in ipairs(MD:Snapshot()) do MD:Print(line) end
    MD:Print("For the FSR anchor: stand idle at partial mana, run /md fsrtest, cast ONE " ..
        "Healing Touch, and watch which tick sizes appear when. For Dreamstate: /md regentest.")
end

--------------------------------------------------------------------------------
-- Every model input in one block. /md verify prints it, /md profile copies it,
-- and both therefore always agree. Returns an array of plain strings (no
-- colour escapes, so it survives a paste).
--------------------------------------------------------------------------------
function MD:Snapshot()
    local SD = MD.SpellData
    local RM = MD.Regen
    local out = {}
    local function add(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    if GetManaRegen then
        add("GetManaRegen: base %.2f/s, casting %.2f/s (x5 = %d / %d mp5)",
            RM.apiBase, RM.apiCasting, RM.apiBase * 5 + 0.5, RM.apiCasting * 5 + 0.5)
        if RM.unreported > 0 then
            add("model adds Dreamstate %.2f/s (%d mp5) -> base %.2f/s, casting %.2f/s",
                RM.unreported, RM.unreported * 5 + 0.5, RM.base, RM.casting)
        end
        local drinking = MD:HasBuff("Drink") or MD:HasBuff("Refreshment") or MD:HasBuff("Food & Drink")
        add("drink buff up: %s; observed OOC fill %.2f/s (FSR duty %d%%)",
            drinking and "yes" or "no", RM:ObservedFill(), RM:Duty() * 100)
    end

    local spirit = UnitStat("player", 5) or 0
    local intellect = UnitStat("player", 4) or 0
    local spiritPerSec, mp5Gear, inFSRFrac = RM:Components()
    add("spirit %d, int %d -> spirit share %.2f/s (%d mp5), gear/buffs ~%d mp5, in-5SR fraction %d%%",
        spirit, intellect, spiritPerSec, spiritPerSec * 5 + 0.5, mp5Gear, inFSRFrac * 100)

    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        add("+healing: " .. (ok and tostring(v) or "unavailable") ..
            (MD:InTreeForm() and string.format(" (Tree of Life form: +%d aura on party targets = 25%% of %d spirit%s)",
                0.25 * spirit, spirit, (MD.db.treeAura == false) and ", NOT counted (setting off)" or "")
             or " (not in Tree form)"))
    end
    if GetSpellCritChance then
        local ok, v = pcall(GetSpellCritChance, 4)
        add("nature crit: %s%%", ok and string.format("%.1f", v) or "unavailable")
    end
    add("talents: " .. MD:TalentSummary())

    local relic, relicID, relicName = SD:Relic()
    if relicID then
        add("relic: %s (%d) - %s", relicName or "?", relicID,
            relic and ("known: " .. relic.name) or "NOT in the relic table (tell the author what it does)")
    else
        add("relic: none equipped")
    end

    if MD.Overheal then
        local oh = MD.Overheal:Summary()
        if #oh > 0 then
            add("overheal (combat log, per character):")
            for _, line in ipairs(oh) do add("  " .. line) end
        else
            add("overheal: no samples yet")
        end
        add("combat log 'amount' convention: %s", MD.db.healAmountGross == nil and "not yet latched"
            or (MD.db.healAmountGross and "GROSS (includes overheal)" or "NET (excludes overheal)"))
    end

    if MD.Calibration then
        add("calibration (observed / model, non-crit events):")
        for _, line in ipairs(MD.Calibration:Report()) do add("  " .. line) end
    end

    local hist = MD.fightHistory or {}
    add("recorded fights: %d", #hist)
    for i = math.max(1, #hist - 4), #hist do
        local f = hist[i]
        add("  [%s] %s", f.zone or "?", (f.summary or "-"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end
    return out
end

--------------------------------------------------------------------------------
-- /md profile: every model input in one copyable block. This is the bug report
-- -- chat-spamming forty lines is not one, a Ctrl+C box is, so it goes straight
-- into the debug console's copy popup.
--------------------------------------------------------------------------------
function MD:Profile()
    local SD = MD.SpellData
    local out = {}
    local function add(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    local _, build, _, iface = GetBuildInfo()
    add("=== ManaDemon v%s profile ===", MD.version)
    add("client build %s, interface %s, ElvUI %s", tostring(build), tostring(iface),
        ElvUI and "present" or "absent")
    add("%s, %s level %d, form: %s, mana %d/%d", MD.player.charKey, MD.player.class,
        MD.player.level, MD:InTreeForm() and "Tree of Life" or "caster / other",
        UnitPower("player", 0) or 0, UnitPowerMax("player", 0) or 0)

    add("")
    add("--- inputs ---")
    for _, line in ipairs(MD:Snapshot()) do add(line) end

    add("")
    add("--- costs of known max ranks ---")
    if MD.player.isDruid then
        for _, family in ipairs(SD.familyOrder) do
            local id = SD.maxRank[family]
            if id then
                local spell = SD.spells[id]
                local live = SD:LiveCost(id)
                local static = SD:StaticCost(id)
                add("%s R%d (%d): live %s, static %s, cast %.1fs",
                    family, spell.rank, id, tostring(live), tostring(static), spell.cast or 1.5)
            end
        end
    else
        add("(druid-only)")
    end

    add("")
    add("--- clock ---")
    local st = MD:GetManaState()
    if st then
        add("mode %s, tto %s, ttf %s, rest %s, shown \"%s\"", st.mode,
            st.tto and string.format("%.0fs", st.tto) or "-",
            st.ttf and string.format("%.0fs", st.ttf) or "-",
            st.rest and string.format("%.0fs", st.rest) or "-",
            (MD:GetDisplayString():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
        add("spend %.2f +- %.2f mana/s (%d casts, cv %.2f, half-life %ds), regen %.2f/s (duty %d%%)",
            st.spend, st.sigma, st.casts, st.cv, MD.db.halfLife or 15, st.regen, st.duty * 100)
        if st.cd then
            add("mana cooldown: %s worth %d mana%s", st.cd.name, st.cd.delta,
                st.cd.tto and string.format(" -> OOM %.0fs", st.cd.tto) or "")
        end
    else
        add("(no state yet)")
    end
    local unknown = {}
    for id in pairs(MD.Spend.unknown) do unknown[#unknown + 1] = id end
    if #unknown > 0 then
        table.sort(unknown)
        local names = {}
        for _, id in ipairs(unknown) do
            names[#names + 1] = (GetSpellInfo(id) or "?") .. " (" .. id .. ")"
        end
        add("unpriced spells this session: %s", table.concat(names, ", "))
    end

    add("")
    add("--- settings ---")
    local keys = {}
    for k, v in pairs(MD.db) do
        if k ~= "char" and k ~= "pos" and k ~= "optionsPos" and k ~= "debug" and type(v) ~= "table" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(MD.db[k])
    end
    add(table.concat(parts, "  "))
    local cats = {}
    for k, v in pairs(MD.db.debug.categories) do
        if v then cats[#cats + 1] = k end
    end
    table.sort(cats)
    add("debug: enabled=%s, keep %d lines, categories: %s",
        tostring(MD.db.debug.enabled), MD.db.debug.maxLines or 1000, table.concat(cats, " "))
    if MD.sim and next(MD.sim) then
        local sim = {}
        for k, v in pairs(MD.sim) do sim[#sim + 1] = k .. "=" .. tostring(v) end
        table.sort(sim)
        add("SIMULATION ACTIVE: %s", table.concat(sim, " "))
    end

    return out
end

function MD:RunProfile()
    local lines = MD:Profile()
    if MD.ShowCopyPopup then
        MD:ShowCopyPopup("ManaDemon profile", table.concat(lines, "\n"))
        MD:Print("profile ready - Ctrl+C in the box to copy it.")
    else
        for _, line in ipairs(lines) do MD:Print(line) end
    end
    MD:Debug("other", "profile dumped (%d lines)", #lines)
end

--------------------------------------------------------------------------------
-- /md export: machine-readable TSV for analysis (fights, overheal buckets,
-- roster, calibration when present). Tabs, no quoting: the first dungeon log
-- was analysed by regexing prose, which is how the analyst wants to stop.
--------------------------------------------------------------------------------
function MD:Export()
    local out = {}
    local function add(...) out[#out + 1] = table.concat({ ... }, "\t") end
    add("# manademon " .. MD.version, MD.player.charKey, MD.player.class .. " " .. MD.player.level,
        date("%Y-%m-%d %H:%M"), MD.db.healAmountGross == nil and "amount:unknown"
            or (MD.db.healAmountGross and "amount:gross" or "amount:net"))

    add("# fights")
    add("t", "zone", "dur", "spent", "netMp5", "healed", "overhealed", "oomAt")
    for _, f in ipairs(MD.fightHistory or {}) do
        add(f.t or "", f.zone or "", string.format("%.1f", f.duration or 0),
            string.format("%.0f", (f.avgSpendRate or 0) * (f.duration or 0)),
            string.format("%.0f", f.netMp5 or 0), f.healed or "", f.overhealed or "",
            f.oomAt and string.format("%.1f", f.oomAt) or "")
    end

    if MD.Overheal and MD.Overheal.stats then
        add("# overheal")
        add("key", "n", "healed", "overhealed")
        local keys = {}
        for k in pairs(MD.Overheal.stats) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local st = MD.Overheal.stats[k]
            add(k, st.n, string.format("%.0f", st.h), string.format("%.0f", st.o))
        end
    end

    if MD.Targets then
        add("# roster")
        add("name", "class", "role", "roleSource", "kind")
        for _, row in ipairs(MD.Targets:ExportRows()) do out[#out + 1] = row end
    end

    if MD.Calibration and MD.Calibration.ExportRows then
        add("# calibration")
        add("spellID", "kind", "n", "obs", "pred")
        for _, row in ipairs(MD.Calibration:ExportRows()) do out[#out + 1] = row end
    end
    return out
end

function MD:RunCalibrate()
    if not MD.Calibration then return end
    local lines = MD.Calibration:Report()
    if MD.ShowCopyPopup then
        MD:ShowCopyPopup("ManaDemon calibration: model vs your heals", table.concat(lines, "\n"))
        MD:Print("calibration table ready - a ratio of 1.000 means the model matched the server exactly.")
    else
        for _, line in ipairs(lines) do MD:Print(line) end
    end
end

function MD:RunExport()
    local lines = MD:Export()
    if MD.ShowCopyPopup then
        MD:ShowCopyPopup("ManaDemon export (TSV)", table.concat(lines, "\n"))
        MD:Print(string.format("export ready (%d lines) - Ctrl+C in the box.", #lines))
    else
        for _, line in ipairs(lines) do MD:Print(line) end
    end
end

--------------------------------------------------------------------------------
-- FSR anchor test: log every player mana change with a timestamp for 15s.
--------------------------------------------------------------------------------
local fsrLogging = false
local fsrT0, fsrLast = 0, 0

-- Registered once; inert unless a test is running.
MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if not fsrLogging or unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    if cur ~= fsrLast then
        MD:Print(string.format("  t+%5.2fs  %+d  (-> %d)", GetTime() - fsrT0, cur - fsrLast, cur))
        fsrLast = cur
    end
end)

function MD:RunFSRTest()
    if fsrLogging then return end
    fsrLogging = true
    fsrT0 = GetTime()
    fsrLast = UnitPower("player", 0)
    MD:Print("fsrtest: logging mana changes for 15s — cast one spell now.")
    C_Timer.After(15, function()
        fsrLogging = false
        MD:Print("fsrtest: done.")
    end)
end

--------------------------------------------------------------------------------
-- Idle regen test (/md regentest [seconds]): does the RAW GetManaRegen()
-- include Dreamstate? Stand idle at partial mana, no drink, no casting. The
-- window starts once the five-second rule has ended (so the API side is a
-- single rate), observed mana gain is compared with the raw API base rate
-- and with the model rate (API + whatever RegenModel adds), and the raw
-- difference is matched against the talent's expected contribution
-- (4/7/10% of Intellect per 5s). Mana spent or a drink buff during the
-- window invalidates the result (reported, not hidden).
--------------------------------------------------------------------------------
local DREAMSTATE_PCT = { 0.04, 0.07, 0.10 }
local regenTest = nil

local function IsDrinking()
    return MD:HasBuff("Drink") or MD:HasBuff("Refreshment") or MD:HasBuff("Food & Drink")
end

local function FinishRegenTest(reason)
    local t = regenTest
    regenTest = nil
    if not t then return end
    if not t.t0 then
        MD:Print("regentest: stopped while waiting for the 5SR to end (" .. reason .. ") - nothing measured.")
        return
    end
    local elapsed = GetTime() - t.t0
    if elapsed < 4 then
        MD:Print(string.format("regentest: stopped after %.1fs (%s) - too short, nothing measured.", elapsed, reason))
        return
    end
    local observed = t.gained / elapsed
    local api = t.apiSum / elapsed        -- time-weighted raw GetManaRegen base
    local model = t.modelSum / elapsed    -- time-weighted RM.base (API + unreported)
    local diff = observed - api
    local intellect = UnitStat("player", 4) or 0
    local dsRank = MD:TalentRank("Dreamstate")
    local dsRate = (DREAMSTATE_PCT[dsRank] or 0) * intellect / 5

    MD:Print(string.format("regentest: %.0fs (%s), %d mana in %d ticks -> observed %.2f/s (%d mp5); " ..
        "raw API %.2f/s (%d mp5); diff %+.2f/s (%+d mp5); model %.2f/s (%d mp5), observed - model %+.2f/s",
        elapsed, reason, t.gained, t.ticks, observed, observed * 5 + 0.5, api, api * 5 + 0.5, diff, diff * 5,
        model, model * 5 + 0.5, observed - model))
    if t.spent > 0 then
        MD:Print(string.format("|cffff4444WARNING|r %d mana was spent during the test (5SR reset) - result unreliable.", t.spent))
    end
    if t.fsrTime > 0.5 then
        MD:Print(string.format("|cffff4444WARNING|r %.1fs of the window were inside the 5SR - result unreliable.", t.fsrTime))
    end
    if t.drank then
        MD:Print("|cffff4444WARNING|r a drink/food buff was up during the test - result unreliable.")
    end
    if t.ticks < 3 then
        MD:Print("|cffff4444WARNING|r fewer than 3 regen ticks observed - were you at full mana?")
    end
    if dsRank == 0 then
        MD:Print(string.format("no Dreamstate talent: diff should be ~0 (it is %+.2f/s). A large positive diff means " ..
            "GetManaRegen misses some regen source.", diff))
    elseif diff >= 0.5 * dsRate then
        MD:Print(string.format("|cffffcc00VERDICT|r raw GetManaRegen EXCLUDES Dreamstate: diff %.2f/s vs expected %.2f/s " ..
            "(Dreamstate %d = %d%% of %d int / 5s). The model adds %.2f/s for it.", diff, dsRate, dsRank,
            DREAMSTATE_PCT[dsRank] * 100, intellect, MD.Regen.unreported))
    else
        MD:Print(string.format("|cffffcc00VERDICT|r raw GetManaRegen INCLUDES Dreamstate: diff %.2f/s, it would be ~%.2f/s " ..
            "if excluded (Dreamstate %d, %d int). The model's %.2f/s Dreamstate term would then double count!",
            diff, dsRate, dsRank, intellect, MD.Regen.unreported))
    end
end

-- Registered once; inert unless a test is measuring.
MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if not regenTest or not regenTest.t0 or unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    local delta = cur - regenTest.last
    regenTest.last = cur
    if delta > 0 then
        regenTest.gained = regenTest.gained + delta
        regenTest.ticks = regenTest.ticks + 1
        if cur >= UnitPowerMax("player", 0) then
            FinishRegenTest("mana full")
        end
    elseif delta < 0 then
        regenTest.spent = regenTest.spent + (-delta)
    end
end)

MD:OnTick(function(dt)
    if not regenTest then return end
    local RM = MD.Regen
    if UnitAffectingCombat("player") then
        FinishRegenTest("entered combat")
        return
    end
    if not regenTest.t0 then
        if RM:InFSR() then return end
        regenTest.t0 = GetTime()
        regenTest.last = UnitPower("player", 0)
        MD:Print(string.format("regentest: 5SR over, measuring for %ds now - stand still.", regenTest.duration))
        return
    end
    regenTest.apiSum = regenTest.apiSum + RM.apiBase * dt
    regenTest.modelSum = regenTest.modelSum + RM.base * dt
    if RM:InFSR() then regenTest.fsrTime = regenTest.fsrTime + dt end
    if IsDrinking() then regenTest.drank = true end
    if GetTime() - regenTest.t0 >= regenTest.duration then
        FinishRegenTest("done")
    end
end)

function MD:RunRegenTest(seconds)
    if regenTest then
        MD:Print("regentest: already running.")
        return
    end
    seconds = tonumber(seconds) or 30
    if seconds < 10 then seconds = 10 end
    if UnitAffectingCombat("player") then
        MD:Print("regentest: leave combat first.")
        return
    end
    local mana, manaMax = UnitPower("player", 0), UnitPowerMax("player", 0)
    if mana >= manaMax then
        MD:Print("regentest: you are at full mana - spend some first (a few casts), then run it again.")
        return
    end
    local RM = MD.Regen
    regenTest = {
        t0 = nil, duration = seconds, last = mana,
        gained = 0, ticks = 0, spent = 0, apiSum = 0, modelSum = 0, fsrTime = 0, drank = IsDrinking(),
    }
    MD:Print(string.format("regentest: %ds - do not cast or drink. Mana %d/%d, raw API base %.2f/s, model %.2f/s, " ..
        "Dreamstate %d, int %d, %s%s.", seconds, mana, manaMax, RM.apiBase, RM.base,
        MD:TalentRank("Dreamstate"), UnitStat("player", 4) or 0,
        MD.db.debug.enabled and "debug log on" or "debug log OFF (enable it in the Debug Console to keep the ticks)",
        RM:InFSR() and string.format("; waiting %.1fs for the 5SR to end", RM:FSRRemaining()) or ""))
end

--------------------------------------------------------------------------------
-- Spam test (/md spamtest): validates the dashboard's "To OOM" column. Arm
-- it, then chain-cast ONE spell until you are out of mana (or stop for 10s).
-- Counts the casts, the real per-cast drops and the regen that landed, and
-- compares with the prediction made from the mana you had when you armed it.
--------------------------------------------------------------------------------
local spamTest = nil

local function FinishSpamTest(reason)
    local t = spamTest
    spamTest = nil
    if not t then return end
    if t.casts == 0 then
        MD:Print("spamtest: no cast seen (" .. reason .. ").")
        return
    end
    local name = GetSpellInfo(t.spellID) or "?"
    local duration = (t.lastCastT or t.firstCastT) - t.firstCastT
    local interval = t.casts > 1 and duration / (t.casts - 1) or t.interval
    local avgDrop = t.spent / math.max(t.casts, 1)
    local mana = UnitPower("player", 0)
    MD:Print(string.format("spamtest (%s): %d casts of %s (%d) in %.1fs (%.2fs apart) - %d mana spent (%.1f per cast, live cost %d), " ..
        "%d regained; mana %d -> %d.", reason, t.casts, name, t.spellID, duration, interval, t.spent, avgDrop, t.liveCost, t.gained,
        t.armMana, mana))
    local predicted = MD.RankMath:CastsToOOM(t.liveCost, t.interval, t.armMana, t.castingRegen)
    local predictedReal = MD.RankMath:CastsToOOM(avgDrop, interval, t.armMana, t.gained / math.max(duration, 1))
    MD:Print(string.format("prediction from %d mana: %s casts (live cost %d, %.1fs interval, casting regen %.2f/s); " ..
        "with the MEASURED drop and regen it would be %s. Observed regen during the spam: %.2f/s.",
        t.armMana, predicted == math.huge and "inf" or tostring(predicted), t.liveCost, t.interval, t.castingRegen,
        predictedReal == math.huge and "inf" or tostring(predictedReal), t.gained / math.max(duration, 1)))
    if math.abs(avgDrop - t.liveCost) > 1 then
        MD:Print(string.format("|cffffaa33NOTE|r the real drop per cast (%.1f) differs from the live cost (%d) - that is the column's error source.",
            avgDrop, t.liveCost))
    end
    if t.otherCasts > 0 then
        MD:Print(string.format("|cffffaa33NOTE|r %d cast(s) of other spells were mixed in and counted in the mana spent.", t.otherCasts))
    end
end

MD:On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if not spamTest or unit ~= "player" or type(spellID) ~= "number" then return end
    local now = GetTime()
    if not spamTest.spellID then
        local cost = MD.SpellData:GetCost(spellID)
        if not cost or cost <= 0 then return end -- ignore free/unknown (form shift etc.)
        spamTest.spellID = spellID
        spamTest.liveCost = cost
        local _, _, _, castMs = GetSpellInfo(spellID)
        spamTest.interval = math.max((castMs or 0) / 1000, 1.5)
        spamTest.firstCastT = now
        MD:Print(string.format("spamtest: counting %s (live cost %d, %.1fs interval) - keep casting until OOM.",
            GetSpellInfo(spellID) or "?", cost, spamTest.interval))
    end
    if spellID == spamTest.spellID then
        spamTest.casts = spamTest.casts + 1
        spamTest.lastCastT = now
    else
        spamTest.otherCasts = spamTest.otherCasts + 1
    end
end)

MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if not spamTest or unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    local delta = cur - spamTest.last
    spamTest.last = cur
    if delta < 0 then
        spamTest.spent = spamTest.spent - delta
    elseif delta > 0 then
        spamTest.gained = spamTest.gained + delta
    end
end)

MD:OnTick(function()
    if not spamTest then return end
    local now = GetTime()
    if spamTest.spellID then
        if UnitPower("player", 0) < spamTest.liveCost then
            FinishSpamTest("OOM")
        elseif now - spamTest.lastCastT > 10 then
            FinishSpamTest("stopped")
        end
    elseif now - spamTest.armT > 30 then
        FinishSpamTest("timed out waiting for the first cast")
    end
end)

function MD:RunSpamTest()
    if spamTest then
        MD:Print("spamtest: already armed.")
        return
    end
    local mana = UnitPower("player", 0)
    spamTest = {
        armT = GetTime(), armMana = mana, last = mana,
        castingRegen = MD.Regen.casting,
        casts = 0, otherCasts = 0, spent = 0, gained = 0,
    }
    MD:Print(string.format("spamtest: armed at %d mana (casting regen %.2f/s). Chain-cast ONE spell now until OOM; " ..
        "the dashboard's To OOM column for it should match.", mana, MD.Regen.casting))
end
