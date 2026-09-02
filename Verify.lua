-- In-game verification harness (/md verify): diff the static SpellData table
-- against whatever the live client exposes, and dump the regen/healing inputs
-- so formulas can be checked by hand before any number is trusted.
-- /md fsrtest logs mana ticks for 15s to pin down the five-second-rule anchor.
local _, MD = ...

local function LiveCost(spellID)
    if not GetSpellPowerCost then return nil end
    local ok, costs = pcall(GetSpellPowerCost, spellID)
    if ok and type(costs) == "table" then
        for _, c in ipairs(costs) do
            if c.type == 0 then return c.cost end
        end
        return 0
    end
    return nil
end

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
            -- mana cost: live value should equal our talent-modified cost
            local live = LiveCost(id)
            if live ~= nil then
                checkedCost = checkedCost + 1
                local expected = SD:GetCost(id)
                if live ~= expected then
                    mismatches = mismatches + 1
                    MD:Print(string.format("|cffffaa33COST|r %s: table %d (base %d), live %d",
                        label, expected, s.cost, live))
                end
            end
        end
    end

    if checkedCost == 0 then
        MD:Print("|cffffaa33GetSpellPowerCost unavailable|r — costs must be verified by hand " ..
            "(cast each rank at full idle mana and read the drop; compare to the table).")
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

    -- input snapshot for by-hand formula checks
    MD:Print("— input snapshot —")
    if GetManaRegen then
        local base, casting = GetManaRegen("player")
        MD:Print(string.format("GetManaRegen: base %.2f/s, casting %.2f/s (x5 = %d / %d mp5)",
            base or 0, casting or 0, (base or 0) * 5, (casting or 0) * 5))
    end
    local spirit = UnitStat("player", 5) or 0
    local intellect = UnitStat("player", 4) or 0
    local spiritPerSec, mp5Gear, intensityFrac = MD.Regen:Components()
    MD:Print(string.format("spirit %d, int %d -> modeled spirit regen %.2f/s, gear ~%d mp5, Intensity %d%%",
        spirit, intellect, spiritPerSec, mp5Gear, intensityFrac * 100))
    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        MD:Print("+healing: " .. (ok and tostring(v) or "unavailable"))
    end
    if GetSpellCritChance then
        local ok, v = pcall(GetSpellCritChance, 4)
        MD:Print(string.format("nature crit: %s%%", ok and string.format("%.1f", v) or "unavailable"))
    end
    local talentList = {}
    for _, t in ipairs({ "Intensity", "Moonglow", "Tranquil Spirit", "Gift of Nature",
            "Improved Rejuvenation", "Empowered Rejuvenation", "Empowered Touch",
            "Improved Regrowth", "Naturalist" }) do
        local r = MD:TalentRank(t)
        if r > 0 then talentList[#talentList + 1] = t .. " " .. r end
    end
    MD:Print("talents: " .. (#talentList > 0 and table.concat(talentList, ", ") or "none relevant"))
    MD:Print("For the FSR anchor: stand idle at partial mana, run /md fsrtest, cast ONE " ..
        "Healing Touch, and watch which tick sizes appear when.")
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
