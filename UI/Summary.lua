-- End-of-combat summary: one chat line per fight (>=15s) plus an in-memory
-- ring of the last 5 fights (feeds the dashboard recap and the pull-time
-- spend seed). No SavedVariables persistence in v1 by design.
local _, MD = ...

MD.fightHistory = {}
local MAX_HISTORY = 5

local fight = nil -- active fight state

-- Overheal via combat log (SPELL_HEAL / SPELL_PERIODIC_HEAL from the player).
MD:On("COMBAT_LOG_EVENT_UNFILTERED", function()
    if not fight then return end
    local _, subevent, _, sourceGUID = CombatLogGetCurrentEventInfo()
    if sourceGUID ~= MD.player.guid then return end
    if subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        local amount = select(15, CombatLogGetCurrentEventInfo()) or 0
        local overheal = select(16, CombatLogGetCurrentEventInfo()) or 0
        fight.healed = fight.healed + amount
        fight.overhealed = fight.overhealed + overheal
    end
end)

MD:On("PLAYER_REGEN_DISABLED", function()
    fight = {
        start = GetTime(),
        startMana = UnitPower("player", 0),
        healed = 0,
        overhealed = 0,
        oomAt = nil,
    }
    MD:Debug("combat", "pull: mana %d/%d, regen base %.2f casting %.2f",
        fight.startMana, UnitPowerMax("player", 0), MD.Regen.base, MD.Regen.casting)
end)

-- OOM detection (below 2% counts as dry).
MD:OnTick(function()
    if not fight or fight.oomAt then return end
    local manaMax = UnitPowerMax("player", 0)
    if manaMax > 0 and UnitPower("player", 0) <= manaMax * 0.02 then
        fight.oomAt = GetTime() - fight.start
    end
end)

local function FmtClock(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

MD:On("PLAYER_REGEN_ENABLED", function()
    if not fight then return end
    local f = fight
    fight = nil

    local duration = GetTime() - f.start
    local ST = MD.Spend
    if duration < 15 or ST.combat.spent <= 0 then
        MD:Debug("combat", "end: %.0fs, spent %d - too short to record", duration, ST.combat.spent)
        return
    end

    local endMana = UnitPower("player", 0)
    local netMp5 = (endMana - f.startMana) / duration * 5
    local avgSpendRate = ST.combat.spent / duration

    local parts = {
        FmtClock(duration),
        string.format("net %+d mp5", netMp5),
        string.format("spent %.1fk", ST.combat.spent / 1000),
    }
    if f.healed + f.overhealed > 0 then
        parts[#parts + 1] = string.format("overheal %d%%",
            f.overhealed / (f.healed + f.overhealed) * 100)
    end
    local realized = MD.Regen:CombatSpiritRealized()
    if realized then
        parts[#parts + 1] = string.format("spirit regen realized %d%%", realized * 100)
    end
    if MD.player.isDruid and ST.combat.casts > 0 then
        parts[#parts + 1] = string.format("max-rank casts %d%%",
            ST.combat.maxRankCasts / ST.combat.casts * 100)
    end
    if f.oomAt then
        parts[#parts + 1] = "|cffff4444OOM at " .. FmtClock(f.oomAt) .. "|r"
    end

    local summary = table.concat(parts, " || ") -- ASCII only; default WoW fonts lack many glyphs
    MD:Debug("combat", "end: %s (casts %d, healed %d, overhealed %d)", summary, ST.combat.casts, f.healed, f.overhealed)
    MD:Print(summary)

    MD.fightHistory[#MD.fightHistory + 1] = {
        duration = duration,
        avgSpendRate = avgSpendRate,
        netMp5 = netMp5,
        oomAt = f.oomAt,
        summary = summary,
    }
    if #MD.fightHistory > MAX_HISTORY then
        table.remove(MD.fightHistory, 1)
    end
    MD:Fire("FIGHT_RECORDED")
end)
