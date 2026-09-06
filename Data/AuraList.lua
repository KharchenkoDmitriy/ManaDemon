-- Buffs the recorder keeps on tracked targets (docs/SPEC-v0.8.md 5.1): the
-- defensive cooldowns a healer's decision actually turns on. A rogue under
-- Evasion is not urgent; a tank at 40% with Shield Wall up is not the same 40%
-- as without it. Debuffs are recorded without a list (every one, capped).
--
-- These change NOTHING in the engine: the damage a defensive prevented was
-- recorded as prevented. They are drawn on the replay's frames so the dip is
-- explained, and they are the prerequisite for the reserved decision input
-- (spec 7). Every id is TBC-era from memory and marked VERIFY until it has been
-- seen in a recording; a wrong id costs an icon, never a number.
local _, MD = ...

local L = {}
MD.AuraList = L

-- [spellID] = { name, class }  -- name is for the fallback square and the log
L.defensive = {
    -- Warrior
    [871]   = { "Shield Wall", "WARRIOR" },        -- VERIFY
    [12975] = { "Last Stand", "WARRIOR" },         -- VERIFY
    [2565]  = { "Shield Block", "WARRIOR" },       -- VERIFY
    [23920] = { "Spell Reflection", "WARRIOR" },   -- VERIFY
    -- Druid
    [22812] = { "Barkskin", "DRUID" },             -- VERIFY
    [22842] = { "Frenzied Regeneration", "DRUID" }, -- VERIFY (rank 1; 22895 / 22896 higher ranks)
    [22895] = { "Frenzied Regeneration", "DRUID" }, -- VERIFY
    [22896] = { "Frenzied Regeneration", "DRUID" }, -- VERIFY
    [17116] = { "Nature's Swiftness", "DRUID" },   -- verified: the recorder already keys on it
    [29166] = { "Innervate", "DRUID" },            -- verified: the recorder already keys on it
    -- Rogue
    [5277]  = { "Evasion", "ROGUE" },              -- VERIFY (rank 1)
    [26669] = { "Evasion", "ROGUE" },              -- VERIFY (rank 2, level 50)
    [31224] = { "Cloak of Shadows", "ROGUE" },     -- VERIFY
    -- Paladin
    [642]   = { "Divine Shield", "PALADIN" },      -- VERIFY (rank 1)
    [1020]  = { "Divine Shield", "PALADIN" },      -- VERIFY (rank 2)
    [498]   = { "Divine Protection", "PALADIN" },  -- VERIFY (rank 1)
    [5573]  = { "Divine Protection", "PALADIN" },  -- VERIFY (rank 2)
    [1022]  = { "Blessing of Protection", "PALADIN" }, -- VERIFY (rank 1)
    [5599]  = { "Blessing of Protection", "PALADIN" }, -- VERIFY (rank 2)
    [10278] = { "Blessing of Protection", "PALADIN" }, -- VERIFY (rank 3)
    -- Priest
    [33206] = { "Pain Suppression", "PRIEST" },    -- VERIFY
    [17]    = { "Power Word: Shield", "PRIEST" },  -- VERIFY (rank 1)
    [592]   = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [600]   = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [3747]  = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [6065]  = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [6066]  = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [10898] = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [10899] = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [10900] = { "Power Word: Shield", "PRIEST" },  -- VERIFY
    [10901] = { "Power Word: Shield", "PRIEST" },  -- VERIFY (rank 10)
    [25217] = { "Power Word: Shield", "PRIEST" },  -- VERIFY (rank 11)
    [25218] = { "Power Word: Shield", "PRIEST" },  -- VERIFY (rank 12)
    -- Mage
    [45438] = { "Ice Block", "MAGE" },             -- VERIFY (2.4 id; 27619 before)
    [27619] = { "Ice Block", "MAGE" },             -- VERIFY
    -- Hunter
    [19263] = { "Deterrence", "HUNTER" },          -- VERIFY
    -- Racial
    [20594] = { "Stoneform", "DWARF" },            -- VERIFY
}

-- Debuffs recorded per target at once; the fifth is dropped, not displaced.
L.MAX_DEBUFFS_PER_TARGET = 4
-- Share of the stream's event budget debuffs may use before they stop being
-- recorded (defensives keep going).
L.DEBUFF_BUDGET = 0.10

function L.Defensive(spellID)
    return L.defensive[spellID]
end
