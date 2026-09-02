-- Static TBC druid healing spell data. The 2.5.x client does not reliably
-- expose per-rank mana costs, so this table is the source of truth; TBC data
-- is frozen so it only has to be verified once.
--
-- !!! VERIFICATION REQUIRED: run /md verify in-game once. Values below are
-- best-effort from TBC references; any mismatch the harness prints must be
-- fixed here. Fields marked VERIFY are the least certain.
local _, MD = ...

local SD = {}
MD.SpellData = SD

-- family metadata
--   type:    direct | hot | hybrid | lifebloom | channel | instant
--   tol:     castable while in Tree of Life form
--   exclude: excluded from the single-target rank dashboard (still priced for
--            the spend tracker)
SD.families = {
    HealingTouch = { type = "direct",    tol = false, label = "Healing Touch" },
    Regrowth     = { type = "hybrid",    tol = true,  label = "Regrowth" },
    Rejuvenation = { type = "hot",       tol = true,  label = "Rejuvenation" },
    Lifebloom    = { type = "lifebloom", tol = true,  label = "Lifebloom" },
    Tranquility  = { type = "channel",   tol = false, label = "Tranquility",  exclude = true },
    Swiftmend    = { type = "instant",   tol = true,  label = "Swiftmend",    exclude = true },
}

SD.familyOrder = { "HealingTouch", "Lifebloom", "Rejuvenation", "Regrowth" }

-- Lifebloom coefficients are empirical 2.4-era values. VERIFY in-game.
SD.lifebloomHotCoef = 0.5187
SD.lifebloomBloomCoef = 0.3422

-- spellID -> data
--   level: level the rank is learned (drives downrank + sub-20 penalties)
--   cost:  base mana cost before talents/forms
--   cast:  base cast time in seconds (used for both the cast column and the
--          direct coefficient; nil = instant/GCD)
--   healMin/healMax: direct heal range;  hotTotal/hotDuration: HoT portion
SD.spells = {
    -- Healing Touch (direct)
    [5185]  = { family = "HealingTouch", rank = 1,  level = 1,  cost = 25,  cast = 1.5, healMin = 37,   healMax = 51 },
    [5186]  = { family = "HealingTouch", rank = 2,  level = 8,  cost = 55,  cast = 2.0, healMin = 88,   healMax = 112 },
    [5187]  = { family = "HealingTouch", rank = 3,  level = 14, cost = 110, cast = 2.5, healMin = 195,  healMax = 243 },
    [5188]  = { family = "HealingTouch", rank = 4,  level = 20, cost = 185, cast = 3.0, healMin = 363,  healMax = 445 },
    [5189]  = { family = "HealingTouch", rank = 5,  level = 26, cost = 270, cast = 3.5, healMin = 572,  healMax = 694 },
    [6778]  = { family = "HealingTouch", rank = 6,  level = 32, cost = 335, cast = 3.5, healMin = 742,  healMax = 894 },
    [8903]  = { family = "HealingTouch", rank = 7,  level = 38, cost = 405, cast = 3.5, healMin = 936,  healMax = 1121 },
    [9758]  = { family = "HealingTouch", rank = 8,  level = 44, cost = 495, cast = 3.5, healMin = 1199, healMax = 1428 },
    [9888]  = { family = "HealingTouch", rank = 9,  level = 50, cost = 600, cast = 3.5, healMin = 1516, healMax = 1804 },
    [9889]  = { family = "HealingTouch", rank = 10, level = 56, cost = 720, cast = 3.5, healMin = 1890, healMax = 2230 },
    [25297] = { family = "HealingTouch", rank = 11, level = 60, cost = 800, cast = 3.5, healMin = 2267, healMax = 2678 },
    [26978] = { family = "HealingTouch", rank = 12, level = 62, cost = 820, cast = 3.5, healMin = 2364, healMax = 2799 }, -- VERIFY
    [26979] = { family = "HealingTouch", rank = 13, level = 69, cost = 935, cast = 3.5, healMin = 2707, healMax = 3198 }, -- VERIFY

    -- Rejuvenation (HoT, 12s, 4 ticks)
    [774]   = { family = "Rejuvenation", rank = 1,  level = 4,  cost = 25,  hotTotal = 32,   hotDuration = 12 },
    [1058]  = { family = "Rejuvenation", rank = 2,  level = 10, cost = 40,  hotTotal = 56,   hotDuration = 12 },
    [1430]  = { family = "Rejuvenation", rank = 3,  level = 16, cost = 75,  hotTotal = 116,  hotDuration = 12 },
    [2090]  = { family = "Rejuvenation", rank = 4,  level = 22, cost = 105, hotTotal = 180,  hotDuration = 12 },
    [2091]  = { family = "Rejuvenation", rank = 5,  level = 28, cost = 135, hotTotal = 244,  hotDuration = 12 },
    [3627]  = { family = "Rejuvenation", rank = 6,  level = 34, cost = 190, hotTotal = 304,  hotDuration = 12 },
    [8910]  = { family = "Rejuvenation", rank = 7,  level = 40, cost = 235, hotTotal = 388,  hotDuration = 12 },
    [9839]  = { family = "Rejuvenation", rank = 8,  level = 46, cost = 280, hotTotal = 488,  hotDuration = 12 },
    [9840]  = { family = "Rejuvenation", rank = 9,  level = 52, cost = 335, hotTotal = 608,  hotDuration = 12 },
    [9841]  = { family = "Rejuvenation", rank = 10, level = 58, cost = 405, hotTotal = 756,  hotDuration = 12 },
    [25299] = { family = "Rejuvenation", rank = 11, level = 60, cost = 435, hotTotal = 888,  hotDuration = 12 },
    [26981] = { family = "Rejuvenation", rank = 12, level = 63, cost = 450, hotTotal = 932,  hotDuration = 12 }, -- VERIFY
    [26982] = { family = "Rejuvenation", rank = 13, level = 69, cost = 415, hotTotal = 1060, hotDuration = 12 }, -- VERIFY

    -- Regrowth (hybrid: direct + HoT over 21s, 7 ticks)
    [8936]  = { family = "Regrowth", rank = 1,  level = 12, cost = 80,  cast = 2.0, healMin = 84,   healMax = 98,   hotTotal = 98,   hotDuration = 21 },
    [8938]  = { family = "Regrowth", rank = 2,  level = 18, cost = 135, cast = 2.0, healMin = 164,  healMax = 188,  hotTotal = 175,  hotDuration = 21 },
    [8939]  = { family = "Regrowth", rank = 3,  level = 24, cost = 185, cast = 2.0, healMin = 240,  healMax = 274,  hotTotal = 259,  hotDuration = 21 },
    [8940]  = { family = "Regrowth", rank = 4,  level = 30, cost = 230, cast = 2.0, healMin = 318,  healMax = 360,  hotTotal = 343,  hotDuration = 21 },
    [8941]  = { family = "Regrowth", rank = 5,  level = 36, cost = 275, cast = 2.0, healMin = 405,  healMax = 457,  hotTotal = 427,  hotDuration = 21 },
    [9750]  = { family = "Regrowth", rank = 6,  level = 42, cost = 335, cast = 2.0, healMin = 511,  healMax = 576,  hotTotal = 546,  hotDuration = 21 },
    [9856]  = { family = "Regrowth", rank = 7,  level = 48, cost = 405, cast = 2.0, healMin = 646,  healMax = 724,  hotTotal = 686,  hotDuration = 21 },
    [9857]  = { family = "Regrowth", rank = 8,  level = 54, cost = 485, cast = 2.0, healMin = 809,  healMax = 905,  hotTotal = 861,  hotDuration = 21 },
    [9858]  = { family = "Regrowth", rank = 9,  level = 60, cost = 575, cast = 2.0, healMin = 1003, healMax = 1119, hotTotal = 1064, hotDuration = 21 },
    [26980] = { family = "Regrowth", rank = 10, level = 65, cost = 675, cast = 2.0, healMin = 1215, healMax = 1356, hotTotal = 1274, hotDuration = 21 }, -- VERIFY

    -- Lifebloom (single rank in TBC; 7s HoT + bloom on expiry)
    [33763] = { family = "Lifebloom", rank = 1, level = 64, cost = 220, hotTotal = 273, hotDuration = 7, bloom = 600 },

    -- Priced for the spend tracker only (excluded from ranking). Costs VERIFY.
    [740]   = { family = "Tranquility", rank = 1, level = 30, cost = 375,  cast = 8, channel = true },
    [8918]  = { family = "Tranquility", rank = 2, level = 40, cost = 505,  cast = 8, channel = true },
    [9862]  = { family = "Tranquility", rank = 3, level = 50, cost = 620,  cast = 8, channel = true },
    [9863]  = { family = "Tranquility", rank = 4, level = 60, cost = 750,  cast = 8, channel = true },
    [26983] = { family = "Tranquility", rank = 5, level = 69, cost = 1650, cast = 8, channel = true },
    [18562] = { family = "Swiftmend",   rank = 1, level = 40, cost = 379 }, -- VERIFY

    -- Zero-cost utility that must NOT be logged as unknown by the tracker.
    [29166] = { family = "Innervate", rank = 1, level = 40, cost = 0 },
}

--------------------------------------------------------------------------------
-- Cost with talent / form modifiers.
-- TBC rounds talent-modified costs down; VERIFY floor-vs-round via /md verify.
--------------------------------------------------------------------------------
function SD:GetCost(spellID)
    local s = SD.spells[spellID]
    if not s then return nil end
    local cost = s.cost
    if MD.player.isDruid and cost > 0 then
        local fam = s.family
        -- Moonglow: -3%/rank for Healing Touch, Regrowth AND Rejuvenation.
        if fam == "HealingTouch" or fam == "Regrowth" or fam == "Rejuvenation" then
            cost = cost * (1 - 0.03 * MD:TalentRank("Moonglow"))
        end
        -- Tranquil Spirit: -2%/rank for Healing Touch and Tranquility.
        if fam == "HealingTouch" or fam == "Tranquility" then
            cost = cost * (1 - 0.02 * MD:TalentRank("Tranquil Spirit"))
        end
        -- Tree of Life: -20% on the HoTs castable in form.
        if MD:InTreeForm() and (fam == "Rejuvenation" or fam == "Regrowth"
                or fam == "Lifebloom" or fam == "Swiftmend") then
            cost = cost * 0.8
        end
    end
    return math.floor(cost)
end

--------------------------------------------------------------------------------
-- Known-rank index (built at login, rebuilt when spells change).
--------------------------------------------------------------------------------
SD.known = {}     -- family -> sorted array of known spellIDs (ascending rank)
SD.knownSet = {}  -- spellID -> true for known spells
SD.maxRank = {}   -- family -> highest known spellID

-- Static family -> sorted array of ALL spellIDs (built once at load; the
-- dashboard shows unlearned ranks dimmed).
SD.all = {}
for id, s in pairs(SD.spells) do
    SD.all[s.family] = SD.all[s.family] or {}
    local list = SD.all[s.family]
    list[#list + 1] = id
end
for _, list in pairs(SD.all) do
    table.sort(list, function(a, b)
        return SD.spells[a].rank < SD.spells[b].rank
    end)
end

local function IsKnown(id)
    if IsSpellKnown then return IsSpellKnown(id) end
    if IsPlayerSpell then return IsPlayerSpell(id) end
    return GetSpellInfo(GetSpellInfo(id) or "") ~= nil
end

function SD:BuildKnown()
    wipe(SD.known)
    wipe(SD.knownSet)
    wipe(SD.maxRank)
    for id, s in pairs(SD.spells) do
        if IsKnown(id) then
            SD.knownSet[id] = true
            SD.known[s.family] = SD.known[s.family] or {}
            local list = SD.known[s.family]
            list[#list + 1] = id
        end
    end
    for family, list in pairs(SD.known) do
        table.sort(list, function(a, b)
            return SD.spells[a].rank < SD.spells[b].rank
        end)
        SD.maxRank[family] = list[#list]
    end
    MD:Fire("SPELLS_REBUILT")
end

function SD:IsMaxKnownRank(spellID)
    local s = SD.spells[spellID]
    return s and SD.maxRank[s.family] == spellID
end

MD:RegisterCallback("MD_READY", function() SD:BuildKnown() end)
MD:On("LEARNED_SPELL_IN_TAB", function() SD:BuildKnown() end)
MD:On("SPELLS_CHANGED", function()
    if MD.db then SD:BuildKnown() end
end)
