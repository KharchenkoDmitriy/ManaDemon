-- Hand-transcribed fixture of the hardest pull in .logs/dungeon-BF-1.txt
-- (Blood Furnace, 2026-09-04, druid level 64; log time +2153.83 .. +2194.15):
-- 154 mana/s, -508 net mp5, 6.2k spent in 40s, mana floor 2536 of 7009.
--
-- The addon cannot read its own text logs, so this is the only way to run the
-- replay's MANA half (docs/SPEC-v0.7.md 3.9) before a fight has been recorded
-- in-game. The log carries no damage-taken or HP lines: there is no HP half.
-- Generated 2026-09-05 by a script over the log; times are seconds from the
-- PLAYER_REGEN_DISABLED line. Costs are the LIVE costs the log recorded.
--
-- Known limits, stated so nobody tunes the engine to them:
--   * initial auras are approximate: the tank had the player's Lifebloom x1
--     (ticks 99-100) and a Regrowth HoT (ticks 243) running for ~19s before
--     the pull; remaining durations were not logged
--   * the player was in Tree of Life at the pull (pre-pull ticks are tagged
--     [tree]); the first FORM event is 1.63s in
--   * no drink buff at this pull (base 69.24 / casting 28.33); no Innervate,
--     potion or Nature's Swiftness in the window
--   * the pre-pull Lifebloom at -0.02s is already reflected in initial.mana
--     (6833 = 7009 - 176); it is listed for aura state only
-- Expected: replaying `casts` from initial.mana at these rates plus the
-- measured energize below reproduces `mana` with mean |delta| <= 2 percent of
-- pool and max <= 5 percent. `/md simreplay fixture` also prints the fit
-- WITHOUT the energize, which is what the two-rate model alone can do.
local _, MD = ...

MD.SimFixtures = MD.SimFixtures or {}
MD.SimFixtures.BF1 = {
    v = 1, zone = "Hellfire Citadel", name = "BF-1 hard pull", t0 = 0, dur = 40.32, pool = 7009,
    -- energize: mana the client's regen API does not report, MEASURED off this
    -- log's own mana lines rather than assumed. Over the 40.27s window the
    -- player gained 2072 mana while continuously inside the five-second rule;
    -- GetManaRegen's casting rate accounts for 1141 of it (19 ticks of ~57,
    -- 27.2/s against the reported 28.33/s). The remaining 931 arrives as two
    -- clean periodic streams the API is blind to -- exactly 17 every 2.00s
    -- (8.45/s) and bursts of 13-15 on a ~3s cycle (8.37/s), plus merges --
    -- most likely Blessing of Wisdom from the party's paladin and a second
    -- source not yet identified. 931 / 40.27 = 23.1 mana/s = 116 mp5.
    -- This is the same class of thing Dreamstate was in v0.5: a periodic
    -- energize, not a regen stat. It is recorded here so the replay validates
    -- the ENGINE (5SR handling, per-cast deduction, curve shape) instead of
    -- re-measuring a rate the fixture already knows. See docs/TESTING.md 16.
    initial = { mana = 6833, apiBase = 69.24, apiCasting = 28.33, energize = 23.1, form = "tree",
                auras = { -- target 1 = tank; remaining durations approximate
                    { target = 1, spellID = 33763, stacks = 1, remaining = 4.0 },  -- Lifebloom
                    { target = 1, spellID = 9858,  stacks = 1, remaining = 9.0 },  -- Regrowth HoT
                } },
    roster = {
        { name = "Destroyka",  class = "WARRIOR", role = "TANK" },
        { name = "Penek",      class = "DRUID",   role = "HEALER" },
        { name = "Alkandari",  class = "MAGE",    role = "DAMAGER" },
        { name = "Abufaisall", class = "WARLOCK", role = "DAMAGER" },
        { name = "Trecoda",    class = "PALADIN", role = "DAMAGER" },
    },
    -- own casts in the 20s before the pull: { t, spellID, cost }  (mana already applied)
    precasts = {
        {  -0.02, 33763,  176 }, -- Lifebloom
    },
    -- own casts during the pull: { t, spellID, cost }  (target not in this log: -1)
    casts = {
        {   1.63,  2782,  135 }, -- Remove Curse
        {   3.15, 33891,  332 }, -- Tree of Life
        {   7.33,  9858,  460 }, -- Regrowth
        {   7.87, 33763,  176 }, -- Lifebloom
        {   9.38, 26981,  296 }, -- Rejuvenation
        {  11.66, 26978,  820 }, -- Healing Touch
        {  13.65, 33891,  332 }, -- Tree of Life
        {  15.15, 18562,  217 }, -- Swiftmend
        {  16.66, 33763,  176 }, -- Lifebloom
        {  20.26,  9858,  460 }, -- Regrowth
        {  20.66, 33763,  176 }, -- Lifebloom
        {  24.61,  9858,  460 }, -- Regrowth
        {  24.93, 26981,  296 }, -- Rejuvenation
        {  26.43, 33763,  176 }, -- Lifebloom
        {  29.95,  9858,  460 }, -- Regrowth
        {  30.11, 33763,  176 }, -- Lifebloom
        {  36.11, 33763,  176 }, -- Lifebloom
        {  38.73,  9885,  445 }, -- Mark of the Wild
        {  40.25, 26992,  400 }, -- Thorns
    },
    -- form changes during the pull: { t, "tree" | "caster" }
    forms = {
        {   1.63, "caster" },
        {   3.15, "tree" },
        {  11.66, "caster" },
        {  13.65, "tree" },
        {  38.73, "caster" },
    },
    -- mana samples: { t, mana }  -- every UNIT_POWER change the log saw (89 samples)
    mana = {
        {   0.50, 6891 },
        {   1.63, 6756 },
        {   1.93, 6773 },
        {   2.53, 6830 },
        {   3.15, 6498 },
        {   3.95, 6515 },
        {   4.55, 6572 },
        {   5.58, 6585 },
        {   5.70, 6599 },
        {   5.96, 6616 },
        {   6.56, 6673 },
        {   7.33, 6213 },
        {   7.87, 6037 },
        {   7.95, 6054 },
        {   8.56, 6067 },
        {   8.58, 6125 },
        {   8.68, 6152 },
        {   8.80, 6166 },
        {   9.38, 5870 },
        {   9.95, 5887 },
        {  10.61, 5944 },
        {  11.56, 5957 },
        {  11.66, 5137 },
        {  11.70, 5164 },
        {  11.80, 5191 },
        {  11.83, 5205 },
        {  11.85, 5252 },
        {  11.95, 5269 },
        {  12.65, 5327 },
        {  12.92, 5341 },
        {  13.65, 5009 },
        {  13.90, 5024 },
        {  13.93, 5041 },
        {  14.58, 5054 },
        {  14.66, 5125 },
        {  14.70, 5138 },
        {  14.80, 5165 },
        {  14.85, 5180 },
        {  15.15, 4963 },
        {  15.72, 4978 },
        {  15.93, 4995 },
        {  16.66, 4819 },
        {  16.70, 4876 },
        {  16.73, 4891 },
        {  17.68, 4904 },
        {  17.78, 4919 },
        {  17.81, 4932 },
        {  17.85, 4947 },
        {  17.93, 4964 },
        {  18.63, 4979 },
        {  18.71, 5037 },
        {  19.65, 5052 },
        {  19.93, 5069 },
        {  20.26, 4609 },
        {  20.66, 4433 },
        {  20.70, 4446 },
        {  20.73, 4503 },
        {  20.78, 4517 },
        {  20.85, 4532 },
        {  21.83, 4608 },
        {  21.93, 4625 },
        {  22.75, 4682 },
        {  22.96, 4697 },
        {  23.80, 4710 },
        {  23.95, 4727 },
        {  24.61, 4267 },
        {  24.78, 4325 },
        {  24.93, 4029 },
        {  25.95, 4046 },
        {  26.43, 3870 },
        {  26.81, 3927 },
        {  27.95, 3944 },
        {  28.86, 4002 },
        {  29.93, 4019 },
        {  29.95, 3559 },
        {  30.11, 3383 },
        {  30.90, 3441 },
        {  31.93, 3458 },
        {  32.93, 3516 },
        {  33.95, 3533 },
        {  34.97, 3590 },
        {  35.93, 3607 },
        {  36.11, 3431 },
        {  37.00, 3489 },
        {  37.95, 3506 },
        {  38.73, 3061 },
        {  39.05, 3119 },
        {  39.93, 3136 },
        {  40.25, 2736 },
    },
}
