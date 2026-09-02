-- Advisor: three push-channel features that fire at real decision moments.
--   1. Innervate/potion timing — alert the first moment the mana deficit
--      exceeds what the consumable restores, so none of it is wasted.
--   2. Gear-change rank toast — when +healing shifts a spell's efficient rank.
--   3. Drink reminder — out of combat, low mana, not drinking.
local _, MD = ...

local INNERVATE = 29166

-- itemID -> max restored mana (max roll, so the alert never fires early)
local MANA_POTIONS = {
    { id = 22832, value = 3000, name = "Super Mana Potion" },
    { id = 13444, value = 2250, name = "Major Mana Potion" },
    { id = 13443, value = 1500, name = "Superior Mana Potion" },
    { id = 3827,  value = 585,  name = "Mana Potion" },
}

local firedInnervate, firedPotion = false, false

local function ItemReady(itemID)
    if GetItemCount(itemID) == 0 then return false end
    local ok, start, duration
    if C_Container and C_Container.GetItemCooldown then
        ok, start, duration = pcall(C_Container.GetItemCooldown, itemID)
    elseif GetItemCooldown then
        ok, start, duration = pcall(GetItemCooldown, itemID)
    end
    if not ok then return true end -- can't read cooldown: don't suppress
    return not start or start == 0 or (start + duration - GetTime()) <= 0
end

local function InnervateReady()
    if not MD.player.isDruid then return false end
    if not (IsSpellKnown and IsSpellKnown(INNERVATE)) then return false end
    local start, duration = GetSpellCooldown(INNERVATE)
    return start == 0 or (start + duration - GetTime()) <= 0
end

-- Rough Innervate value: 400% spirit regen + full regen while casting for 20s.
-- Estimated as 3.5x the spirit-based regen rate over 20s (conservative).
local function InnervateValue()
    local spiritPerSec = MD.Regen:Components()
    return spiritPerSec * 3.5 * 20
end

MD:OnTick(function()
    if not MD.db or not UnitAffectingCombat("player") or not MD.player.usesMana then return end
    local deficit = UnitPowerMax("player", 0) - UnitPower("player", 0)

    if not firedInnervate and InnervateReady() then
        local value = InnervateValue()
        if value > 500 and deficit >= value then
            firedInnervate = true
            MD:Alert(string.format("Innervate now — you're down %d mana (worth ~%d).", deficit, value))
        end
    end

    if not firedPotion then
        for _, potion in ipairs(MANA_POTIONS) do
            if ItemReady(potion.id) then
                if deficit >= potion.value then
                    firedPotion = true
                    MD:Alert(string.format("%s now — you're down %d mana, none of it will be wasted.",
                        potion.name, deficit))
                end
                break -- only consider the best potion carried
            end
        end
    end
end)

MD:On("PLAYER_REGEN_ENABLED", function()
    firedInnervate, firedPotion = false, false
end)

--------------------------------------------------------------------------------
-- Gear-change rank toast
--------------------------------------------------------------------------------
local toastPending = false

local function CheckRankShift()
    toastPending = false
    if not MD.player.isDruid or not MD.cdb then return end
    local current = MD.RankMath:SuggestedRanks()
    local stored = MD.cdb.suggestedRanks
    if stored then
        for family, rank in pairs(current) do
            if stored[family] and stored[family] ~= rank then
                local label = MD.SpellData.families[family].label
                MD:Alert(string.format("gear change — %s R%d is now your efficient rank (was R%d). Rebind?",
                    label, rank, stored[family]))
            end
        end
    end
    MD.cdb.suggestedRanks = current
end

MD:On("PLAYER_EQUIPMENT_CHANGED", function()
    if toastPending or not MD.db then return end
    toastPending = true
    C_Timer.After(2, CheckRankShift) -- debounce a full outfit swap into one check
end)

MD:RegisterCallback("MD_READY", function()
    C_Timer.After(5, function()
        if MD.player.isDruid and MD.cdb and not MD.cdb.suggestedRanks then
            MD.cdb.suggestedRanks = MD.RankMath:SuggestedRanks()
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
