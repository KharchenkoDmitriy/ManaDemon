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
                -- Compare against what the model expects, not the raw table:
                -- Naturalist and a cast-time idol are known. (The first
                -- regression log reported 13 "mismatches", all Naturalist.)
                -- The live value may sit UNDER the 1.5s GCD floor the model
                -- applies (HT R1 reads 1.0s with Naturalist 5); that is fine.
                local expect = s.cast
                if s.family == "HealingTouch" then
                    expect = expect - 0.1 * MD:TalentRank("Naturalist")
                    local relic = SD:Relic()
                    if relic and relic.castReduce and relic.family == s.family then
                        expect = expect - relic.castReduce
                    end
                end
                if math.abs(castMs / 1000 - expect) > 0.01 then
                    mismatches = mismatches + 1
                    MD:Print(string.format("|cffffaa33CAST|r %s: table %.1fs%s, live %.1fs",
                        label, s.cast, expect ~= s.cast and string.format(" (model %.1fs)", expect) or "",
                        castMs / 1000))
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
        if relic then
            local what = relic.flat and string.format("+%d %s", relic.flat, relic.family)
                or relic.perTick and string.format("+%d per %s tick", relic.perTick, relic.family)
                or relic.castReduce and string.format("-%.2fs %s cast", relic.castReduce, relic.family)
                or relic.cost and string.format("-%d mana on %s (live cost already includes it)", relic.cost, relic.family)
                or relic.aura and string.format("+%d Tree of Life aura", relic.aura) or "?"
            add("relic: %s (%d) - %s%s", relic.name, relicID, what,
                relic.verify and " [value from a database tooltip, not yet measured - calibration will say]" or " [measured]")
        else
            add("relic: %s (%d) - NOT in the relic table (tell the author what it does)", relicName or "?", relicID)
        end
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

    -- Recorded streams (v0.7.2): the parallel arrays as they are, one event per
    -- row. This is the raw material for offline replay, so it is dumped
    -- verbatim rather than summarised -- a summary of a stream is what the
    -- Review tab is for.
    if MD.FightRecorder then
        for n, r in ipairs(MD.FightRecorder:List()) do
            add("# recording " .. n, r.id or "", r.zone or "",
                string.format("%.1f", r.dur or 0), "pool " .. (r.pool or 0),
                (r.ownCasts or 0) .. " casts", (r.spent or 0) .. " mana",
                string.format("foreign %.0f%%", (r.foreignShare or 0) * 100),
                r.truncated and "TRUNCATED" or "", r.pinned and "pinned" or "")
            add("# roster")
            add("idx", "name", "class", "role", "roleSource", "maxHP", "tracked")
            local trackedSet = {}
            for _, idx in ipairs(r.tracked or {}) do trackedSet[idx] = true end
            for i, e in ipairs(r.roster or {}) do
                add(i, e.name or "", e.class or "", e.role or "", e.roleSource or "",
                    e.maxHP or -1, trackedSet[i] and "y" or "")
            end
            local init = r.initial or {}
            add("# initial", "mana " .. (init.mana or 0), "base " .. (init.apiBase or 0),
                "casting " .. (init.apiCasting or 0), init.form or "?")
            for _, a in ipairs(init.auras or {}) do
                add("aura", a.target, a.spellID, a.stacks, string.format("%.1f", a.remaining or 0))
            end
            for _, b in ipairs(init.buffs or {}) do
                add("buff", b.spellID or 0, b.name or "", string.format("%.1f", b.remaining or 0))
            end
            add("# precasts")
            add("t", "spellID", "cost", "tgt", "hpAtCast", "form")
            for _, c in ipairs(r.precasts or {}) do
                add(string.format("%.2f", c[1]), c[2], c[3], c[4],
                    string.format("%.3f", c[5] or -1), c[6])
            end
            add("# ev")
            add("t", "kind", "tgt", "amt", "x")
            local ev = r.ev or {}
            for i = 1, #(ev.t or {}) do
                add(string.format("%.2f", ev.t[i]), ev.kind[i], ev.tgt[i],
                    string.format("%.0f", ev.amt[i] or 0), ev.x[i])
            end
            add("# hp")
            local hp = r.hp or {}
            local head = { "t" }
            for _, idx in ipairs(r.tracked or {}) do head[#head + 1] = "hp" .. idx end
            for _, idx in ipairs(r.tracked or {}) do head[#head + 1] = "max" .. idx end
            add(unpack(head))
            for i = 1, #(hp.t or {}) do
                local row = { string.format("%.1f", hp.t[i]) }
                for _, idx in ipairs(r.tracked or {}) do row[#row + 1] = hp.hp[idx][i] or -1 end
                for _, idx in ipairs(r.tracked or {}) do row[#row + 1] = hp.max[idx][i] or -1 end
                add(unpack(row))
            end
            add("# mana")
            add("t", "v", "base", "cast")
            local mn = r.mana or {}
            for i = 1, #(mn.t or {}) do
                add(string.format("%.1f", mn.t[i]), mn.v[i],
                    string.format("%.2f", mn.base[i] or 0), string.format("%.2f", mn.cast[i] or 0))
            end
        end
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

--------------------------------------------------------------------------------
-- /md simrun -- self-tests for Engine/SimModel.lua (docs/SPEC-v0.7.md 3.8).
--
-- Nine assertions about mechanics nobody can eyeball once the engine is inside
-- a search: does a Rejuvenation heal what the dashboard says it heals, does a
-- refresh drop the ticks it should, does one Lifebloom stack bloom once, does
-- Swiftmend eat the right HoT, does a corpse stop taking heals, does the
-- five-second rule switch rates at 5.0, does the GCD hold two instants 1.5s
-- apart, and does Run allocate. Everything downstream trusts these.
--------------------------------------------------------------------------------
local function SimTargets(n, maxHP, hp0)
    local t = {}
    for i = 1, n do t[i] = { name = "T" .. i, maxHP = maxHP, hp0 = hp0, tracked = true } end
    return t
end

local function Near(a, b, tol)
    return math.abs((a or 0) - (b or 0)) <= tol
end

function MD:RunSimRun()
    local SM, RM, SD = MD.SimModel, MD.RankMath, MD.SpellData
    if not (SM and RM and SD) then MD:Print("simrun: engine not loaded.") return end

    -- The kit's caster half is built with inTree = false, so the rows it is
    -- compared against must be too -- otherwise running this in Tree form
    -- fails every heal assertion for the wrong reason.
    local kit = RM:SpellKit()
    local ctx = RM:Context({ live = true, healer = { inTree = false } })
    local out, fails = {}, 0
    local function Check(name, ok, detail)
        if not ok then fails = fails + 1 end
        out[#out + 1] = string.format("%-28s %s%s", name, ok and "ok" or "FAIL",
            detail and (" - " .. detail) or "")
    end

    local BIG = 1000000
    local rejuvID = SD.maxRank.Rejuvenation
    local regrowthID = SD.maxRank.Regrowth
    local lifebloomID = SD.maxRank.Lifebloom
    local swiftmendID = SD.maxRank.Swiftmend
    local caster = kit.caster

    -- 1. one Rejuvenation heals what the dashboard row says it heals
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local row = RM:RowFor(rejuvID, ctx)
        local sc = { dur = 30, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 } }))
        Check("1 rejuv total heal", Near(r.healed, row.heal, 1),
            string.format("sim %.1f vs row %.1f", r.healed, row.heal))
        Check("1 rejuv mana", Near(r.manaSpent, e.cost, 0.01),
            string.format("spent %.0f vs cost %d", r.manaSpent, e.cost))
    else
        Check("1 rejuv", false, "Rejuvenation not known")
    end

    -- 2. chain-cast to OOM matches the dashboard's closed form
    if regrowthID and caster[regrowthID] then
        local e = caster[regrowthID]
        local mana = math.max(e.cost * 6, 8000)
        local regen = ctx.castingRegen
        local expected = RM:CastsToOOM(e.cost, e.cast, mana, regen)
        local sc = { dur = (expected + 2) * e.cast, pool = mana,
                     initial = { mana = mana, apiBase = regen, apiCasting = regen, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ChainPlan(regrowthID, 1, kit, "caster"))
        Check("2 chain casts to OOM", r.casts == expected,
            string.format("sim %d vs closed form %s", r.casts, tostring(expected)))
    else
        Check("2 chain casts to OOM", false, "Regrowth not known")
    end

    -- 3. a refresh drops the ticks that were still pending
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local expected = 2 + e.ticks
        local sc = { dur = 40, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 }, { 6.5, rejuvID, e.cost, 1 } }))
        Check("3 refresh loses ticks", r.ticks == expected,
            string.format("%d ticks, expected %d", r.ticks, expected))
    end

    -- 4. a Lifebloom stack blooms exactly once
    if lifebloomID and caster[lifebloomID] then
        local e = caster[lifebloomID]
        local sc = { dur = 25, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, lifebloomID, e.cost, 1 },
                                             { 1, lifebloomID, e.cost, 1 },
                                             { 2, lifebloomID, e.cost, 1 } }))
        Check("4 lifebloom blooms once", r.blooms == 1, string.format("%d bloom(s)", r.blooms))
    end

    -- 5. Swiftmend eats Regrowth before Rejuvenation
    if swiftmendID and caster[swiftmendID] and caster[swiftmendID].swiftmendRegrowth then
        local sm = caster[swiftmendID]
        local sc = { dur = 25, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, regrowthID, caster[regrowthID].cost, 1 },
                                             { 0.1, rejuvID, caster[rejuvID].cost, 1 },
                                             { 0.2, swiftmendID, sm.cost, 1 } }))
        local got = r.healByFamily.Swiftmend or 0
        Check("5 swiftmend eats regrowth", Near(got, sm.swiftmendRegrowth, 1),
            string.format("%.0f vs regrowth %.0f / rejuv %.0f", got,
                sm.swiftmendRegrowth or 0, sm.swiftmendRejuv or 0))
    end

    -- 6. nothing lands on a corpse
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local sc = { dur = 20, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = { { name = "T1", maxHP = 1000, hp0 = 1000, tracked = true } },
                     kit = kit, grace = 0, floor = 0,
                     ev = { t = { 1 }, kind = { MD.SimModel.K.DMG }, tgt = { 1 }, amt = { 5000 }, x = { 0 } } }
        local r = SM:Run(sc, SM.ScriptPlan({ { 2, rejuvID, e.cost, 1 } }))
        Check("6 no heals on a corpse", (r.healByFamily.Rejuvenation or 0) == 0 and r.deaths.n == 1,
            string.format("healed %.0f, deaths %d", r.healByFamily.Rejuvenation or 0, r.deaths.n))
    end

    -- 7. the five-second rule switches rates at 5.0
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local M0, B, C = 40000, 40, 10
        local sc = { dur = 12, pool = 100000,
                     initial = { mana = M0, apiBase = B, apiCasting = C, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit, sampleT = { 5, 10 } }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 } }))
        local want5 = M0 - e.cost + C * 5
        local want10 = want5 + B * 5
        Check("7 5SR rate switch", Near(r.manaCurve[1], want5, 0.5) and Near(r.manaCurve[2], want10, 0.5),
            string.format("%.0f/%.0f vs %.0f/%.0f", r.manaCurve[1] or -1, r.manaCurve[2] or -1, want5, want10))
    end

    -- 8. the GCD holds two instants 1.5s apart
    if rejuvID and caster[rejuvID] then
        local function ChainFor(dur)
            local sc = { dur = dur, pool = 100000, initial = { mana = 100000, form = "caster" },
                         targets = SimTargets(1, BIG, 1), kit = kit }
            return SM:Run(sc, SM.ChainPlan(rejuvID, 1, kit, "caster")).casts
        end
        local a, b = ChainFor(1.4), ChainFor(1.6)
        Check("8 gcd 1.5s", a == 1 and b == 2, string.format("1.4s -> %d, 1.6s -> %d", a, b))
    end

    -- 9. Run's cost does not grow with the timeline.
    --
    -- Measured per run over many runs, not once: a single run right after a
    -- collect reports the collector's own bookkeeping as if it were ours (4.1 KB
    -- against a true 2.1). What matters is that a 1,500-event fight costs the
    -- same as an empty one -- the loop reads the recorded arrays by index and
    -- allocates nothing. The fixed ~2 KB is Run's own local closures, built
    -- once per call.
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local n, reps = 1500, 50
        local evT, evK, evTg, evA, evX = {}, {}, {}, {}, {}
        for i = 1, n do
            evT[i], evK[i], evTg[i], evA[i], evX[i] = i * 0.02, MD.SimModel.K.FHEAL, 1, 10, 0
        end
        local heavy = { dur = 35, pool = 100000, initial = { mana = 100000, form = "caster" },
                        targets = SimTargets(1, BIG, 1), kit = kit,
                        ev = { t = evT, kind = evK, tgt = evTg, amt = evA, x = evX } }
        local light = { dur = 35, pool = 100000, initial = { mana = 100000, form = "caster" },
                        targets = SimTargets(1, BIG, 1), kit = kit }
        local script = SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 } })
        local function PerRun(sc)
            SM:Run(sc, script)
            collectgarbage("collect")
            local before = collectgarbage("count")
            for _ = 1, reps do SM:Run(sc, script) end
            return (collectgarbage("count") - before) / reps
        end
        local heavyKB, lightKB = PerRun(heavy), PerRun(light)
        Check("9 run cost is flat", heavyKB < 4 and math.abs(heavyKB - lightKB) < 0.5,
            string.format("%.2f KB/run with %d events, %.2f KB/run with none", heavyKB, n, lightKB))
    end

    MD:Print(string.format("simrun: %d test(s), %s", #out,
        fails == 0 and "all ok" or (fails .. " FAILED")))
    for _, line in ipairs(out) do
        MD:Print("  " .. line)
        MD:Debug("sim", "simrun %s", line)
    end
end

--------------------------------------------------------------------------------
-- /md simreplay fixture -- replay Data/SimFixture_BF1.lua and report how well
-- the engine reproduces the mana curve the log actually recorded.
--
-- Three numbers, because they answer three different questions:
--   spend     the recorded costs, summed by the engine. Must be exact; if it
--             is not, the script or the cost handling is broken.
--   modelled  the fit using ONLY what GetManaRegen reports. This is what the
--             addon's own regen model can predict, and on BF-1 it is short by
--             design -- the log carries ~23 mana/s of periodic energize the
--             API never mentions (see the fixture header).
--   measured  the fit with that energize included. THIS is the engine gate
--             (mean <= 2%, max <= 5% of pool): five-second-rule handling,
--             per-cast deduction, ordering and curve shape, with the rate
--             argument taken out of the question.
--------------------------------------------------------------------------------
local function ReplayFixture(fx)
    local SM, RM = MD.SimModel, MD.RankMath
    local sampleT, sampleM = {}, {}
    for i, m in ipairs(fx.mana) do sampleT[i], sampleM[i] = m[1], m[2] end

    local targets = {}
    for i, r in ipairs(fx.roster or {}) do
        targets[i] = { name = r.name, role = r.role, maxHP = 10000, hp0 = 10000, tracked = false }
    end

    local function RunWith(energize)
        local sc = {
            dur = fx.dur, pool = fx.pool,
            initial = { mana = fx.initial.mana, apiBase = fx.initial.apiBase,
                        apiCasting = fx.initial.apiCasting, energize = energize,
                        form = fx.initial.form, auras = fx.initial.auras },
            targets = targets, forms = fx.forms, sampleT = sampleT,
            kit = RM:SpellKit(),
        }
        local r = SM:Run(sc, SM.ScriptPlan(fx.casts))
        local sum, worst, worstT = 0, 0, 0
        for i = 1, #sampleT do
            local d = math.abs((r.manaCurve[i] or 0) - sampleM[i])
            sum = sum + d
            if d > worst then worst, worstT = d, sampleT[i] end
        end
        return sum / math.max(1, #sampleT) / fx.pool, worst / fx.pool, worstT, r
    end

    -- Order matters: the result belongs to the pool slot, so the run whose
    -- result is still read must be the last one.
    local mMean, mMax, mAt = RunWith(0)
    local eMean, eMax, eAt, eRes = RunWith(fx.initial.energize or 0)

    local recorded = 0
    for _, c in ipairs(fx.casts) do recorded = recorded + (c[3] or 0) end

    local lines = {
        string.format("fixture %s: %d casts, %.1fs, pool %d", fx.name or "?", #fx.casts, fx.dur, fx.pool),
        string.format("  spend    sim %.0f vs recorded %d  (%s)", eRes.manaSpent, recorded,
            math.abs(eRes.manaSpent - recorded) < 1 and "exact" or "MISMATCH"),
        string.format("  modelled mean %.1f%%  max %.1f%% at %.1fs   (GetManaRegen only)",
            mMean * 100, mMax * 100, mAt),
        string.format("  measured mean %.1f%%  max %.1f%% at %.1fs   (+ %.1f mana/s energize) -> %s",
            eMean * 100, eMax * 100, eAt, fx.initial.energize or 0,
            (eMean <= 0.02 and eMax <= 0.05) and "PASS" or "FAIL"),
    }
    return lines
end

function MD:RunSimReplay(arg)
    if not (MD.SimModel and MD.RankMath) then MD:Print("simreplay: engine not loaded.") return end
    if arg == nil or arg == "" or arg == "fixture" or arg == "bf1" then
        local fx = MD.SimFixtures and MD.SimFixtures.BF1
        if not fx then MD:Print("simreplay: no fixture loaded.") return end
        for _, line in ipairs(ReplayFixture(fx)) do
            MD:Print(line)
            MD:Debug("sim", "simreplay %s", line)
        end
        return
    end
    local n = tonumber(arg)
    local rec = MD.FightRecorder and MD.FightRecorder:Get(n or 1)
    if not rec then
        MD:Print("simreplay: no recording " .. tostring(arg) .. " (try /md simreplay fixture).")
        return
    end
    for _, line in ipairs(MD:ValidationReport(rec, n or 1)) do
        MD:Print(line)
        MD:Debug("sim", "simreplay %s", line)
    end
end

--------------------------------------------------------------------------------
-- The validation report for one recording: whether the engine can reproduce the
-- fight, gate by gate, with each threshold's provenance. This is what the
-- Review tab's tooltip shows and what decides whether the Coach is allowed to
-- say anything at all about this pull.
--------------------------------------------------------------------------------
function MD:ValidationReport(rec, n)
    local v = MD.SimModel:Validate(rec)
    if not v then return { "simreplay: nothing to validate." } end
    local out = {
        string.format("recording %d: %s, %.0fs, %d casts, %d mana%s", n or 1,
            rec.zone or "?", rec.dur or 0, rec.ownCasts or 0, rec.spent or 0,
            rec.truncated and " (stream truncated)" or ""),
        string.format("  verdict: %s", v.ok and "REPLAYS - safe to coach from"
            or "does NOT replay - nothing will be suggested from this fight"),
    }
    for _, g in ipairs(v.gates) do
        out[#out + 1] = string.format("  %-18s %-4s %s", g.name, g.ok and "ok" or "FAIL", g.text)
    end
    for i, why in pairs(v.excluded) do
        local name = rec.roster[i] and rec.roster[i].name or ("target " .. i)
        out[#out + 1] = string.format("  excluded: %s - %s", name, why)
    end
    for _, g in ipairs(v.gates) do
        if not g.ok and g.why then
            out[#out + 1] = string.format("  why %s is %s: %s", g.name,
                g.limit and string.format("%.2f", g.limit) or "set where it is", g.why)
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- /md coach [n] [force]
--------------------------------------------------------------------------------
function MD:RunCoach(arg)
    if not (MD.SimPlanner and MD.FightRecorder) then MD:Print("coach: not loaded.") return end
    local n, rest = (arg or ""):match("^(%d*)%s*(%a*)$")
    n = tonumber(n) or 1
    local rec = MD.FightRecorder:Get(n)
    if not rec then MD:Print("coach: no recording " .. n .. ".") return end
    local lines = MD.SimPlanner.Coach(rec, { n = n, force = (rest == "force") })
    if MD.ShowCopyPopup and #lines > 6 then
        MD:ShowCopyPopup("ManaDemon coach: recording " .. n, table.concat(lines, "\n"))
    end
    for _, line in ipairs(lines) do
        MD:Print(line)
        MD:Debug("sim", "coach %s", line)
    end
end
