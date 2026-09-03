-- Advisor: three push-channel features that fire at real decision moments.
--   1. Mana-cooldown / potion timing — alert the first moment the mana deficit
--      exceeds what the source restores, so none of it is wasted. The sources
--      and their values come from Engine/ManaCooldowns.lua.
--   2. Gear-change rank toast — when +healing shifts a spell's efficient rank.
--   3. Drink reminder — out of combat, low mana, not drinking.
local _, MD = ...

-- Every mana source (Innervate today, per-class cooldowns later, plus carried
-- potions) and what it is worth right now comes from Engine/ManaCooldowns.lua,
-- so the advisor and the OOM clock can never quote different numbers for the
-- same decision.
local fired = {}

MD:OnTick(function()
    if not MD.db or not UnitAffectingCombat("player") or not MD.player.usesMana then return end
    if not MD.ManaCooldowns then return end
    local deficit = UnitPowerMax("player", 0) - UnitPower("player", 0)

    for _, src in ipairs(MD.ManaCooldowns:All()) do
        -- Fire the first moment the deficit swallows the whole thing: any
        -- earlier and part of the restore is wasted.
        if src.ready and src.delta > 500 and not fired[src.key] and deficit >= src.delta then
            fired[src.key] = true
            MD:Alert(string.format("%s now - you're down %d mana (worth ~%d), none of it will be wasted.",
                src.name, deficit, src.delta))
        end
    end
end)

MD:On("PLAYER_REGEN_ENABLED", function()
    wipe(fired)
end)

--------------------------------------------------------------------------------
-- Gear-change rank toast
--------------------------------------------------------------------------------
local toastPending = false

local function CheckRankShift()
    toastPending = false
    if not MD.player.isDruid or not MD.cdb then return end
    if MD.sim and next(MD.sim) then return end -- dashboard simulation active: not real gear
    -- Suggestions depend on the form too (Tree of Life cost + aura), so a
    -- stored snapshot from the other form is replaced, never compared.
    local current = MD.RankMath:SuggestedRanks()
    local form = MD:InTreeForm() and "tree" or "caster"
    local stored = MD.cdb.suggestedRanks
    if stored and stored.form == form and stored.ranks then
        for family, rank in pairs(current) do
            if stored.ranks[family] and stored.ranks[family] ~= rank then
                local label = MD.SpellData.families[family].label
                MD:Alert(string.format("gear change — %s R%d is now your efficient rank (was R%d). Rebind?",
                    label, rank, stored.ranks[family]))
            end
        end
    end
    MD.cdb.suggestedRanks = { form = form, ranks = current }
end

MD:On("PLAYER_EQUIPMENT_CHANGED", function()
    if toastPending or not MD.db then return end
    toastPending = true
    C_Timer.After(2, CheckRankShift) -- debounce a full outfit swap into one check
end)

MD:RegisterCallback("MD_READY", function()
    C_Timer.After(5, function()
        if MD.player.isDruid and MD.cdb and not (MD.cdb.suggestedRanks and MD.cdb.suggestedRanks.ranks) then
            MD.cdb.suggestedRanks = { form = MD:InTreeForm() and "tree" or "caster",
                                      ranks = MD.RankMath:SuggestedRanks() }
        end
    end)
end)

--------------------------------------------------------------------------------
-- Drink reminder: OOC, mana < 70%, stationary ~5s, not drinking, at most once
-- per rest period (re-arms when mana passes 90% or combat starts).
--------------------------------------------------------------------------------
local DRINK_NAMES = { ["Drink"] = true, ["Refreshment"] = true, ["Food & Drink"] = true }
local stillSince = nil
local drinkArmed = true

local function IsDrinking()
    if not UnitBuff then return false end
    for i = 1, 40 do
        local name = UnitBuff("player", i)
        if not name then break end
        if DRINK_NAMES[name] then return true end
    end
    return false
end

MD:OnTick(function(dt)
    if not MD.db or not MD.db.drinkReminder or not MD.player.usesMana then return end
    if UnitAffectingCombat("player") then
        stillSince = nil
        drinkArmed = true
        return
    end
    local manaMax = UnitPowerMax("player", 0)
    local pct = manaMax > 0 and UnitPower("player", 0) / manaMax or 1
    if pct > 0.90 then drinkArmed = true end
    if not drinkArmed or pct >= 0.70 or IsDrinking() then
        stillSince = nil
        return
    end
    local speed = GetUnitSpeed and GetUnitSpeed("player") or 0
    if speed and speed > 0 then
        stillSince = nil
        return
    end
    stillSince = stillSince or GetTime()
    if GetTime() - stillSince >= 5 then
        drinkArmed = false
        stillSince = nil
        MD:Alert("Drink.")
    end
end)
