-- End-of-combat summary: one chat line per fight (>=15s) plus a ring of the
-- last 20 fights, persisted per character in MD.cdb.fights so the pull-time
-- spend seed and the "last time here" reference survive a /reload. The zone is
-- recorded with each fight; Engine/SpendTracker.lua prefers same-zone fights
-- when it seeds the estimator.
local _, MD = ...

MD.fightHistory = {}
local MAX_HISTORY = 20

-- MD.cdb is not there until PLAYER_LOGIN, so bind (and adopt whatever was
-- saved) at MD_READY. MD.fightHistory keeps its name and shape: everything
-- else that reads it is unchanged.
MD:RegisterCallback("MD_READY", function()
    MD.cdb.fights = MD.cdb.fights or {}
    MD.fightHistory = MD.cdb.fights
    while #MD.fightHistory > MAX_HISTORY do
        table.remove(MD.fightHistory, 1)
    end
    if #MD.fightHistory > 0 then
        MD:Debug("combat", "loaded %d recorded fight(s) from this character's history", #MD.fightHistory)
    end
end)

-- Recent fights in a zone, newest last. Used for the pull-time seed.
function MD:FightsInZone(zone, n)
    local out = {}
    if not zone then return out end
    for i = #MD.fightHistory, 1, -1 do
        local f = MD.fightHistory[i]
        if f.zone == zone then
            table.insert(out, 1, f)
            if #out >= (n or 5) then break end
        end
    end
    return out
end

local fight = nil -- active fight state

-- Combat log, one handler and one CombatLogGetCurrentEventInfo() call: the
-- player's own heals feed the fight totals, the per-spell overheal stats and
-- the "heal" debug category. Overheal is recorded in AND out of combat --
-- rolling Lifebloom on a tank between pulls is exactly the sort of casting
-- whose overheal belongs in the average.
MD:On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local _, subevent, _, sourceGUID, _, _, _, destGUID, destName, _, _,
        spellID, spellName, _, amount, overheal, _, critical = CombatLogGetCurrentEventInfo()
    if sourceGUID ~= MD.player.guid then return end
    if subevent ~= "SPELL_HEAL" and subevent ~= "SPELL_PERIODIC_HEAL" then return end
    amount, overheal = amount or 0, overheal or 0

    -- Event kind for calibration and (v0.6.3) the overheal buckets: a periodic
    -- event is a tick; a non-periodic Lifebloom event is its bloom; the rest
    -- are direct heals.
    local kind = "direct"
    if subevent == "SPELL_PERIODIC_HEAL" then
        kind = "tick"
    elseif spellID and MD.SpellData.spells[spellID] and MD.SpellData.spells[spellID].family == "Lifebloom" then
        kind = "bloom"
    end

    local wasted = 0
    if MD.Overheal then wasted = MD.Overheal:Record(spellID, kind, amount, overheal, destGUID, destName) end
    if MD.Calibration then
        -- (a function call inside "a and f() or b" is truncated to ONE value,
        -- which would hand calibration the NET convention's gross -- the bug
        -- v0.5.3 already fixed once in this file)
        local gross = amount + overheal
        if MD.Overheal then
            local _, g = MD.Overheal:Split(amount, overheal)
            gross = g
        end
        MD.Calibration:Observe(spellID, kind, gross, critical, destGUID)
    end

    if fight then
        -- one convention for the whole addon (Engine/Overheal.lua): whether
        -- the log's "amount" already includes the overheal is a client
        -- property, latched from the first full overheal seen.
        local effective, gross
        if MD.Overheal then
            effective, gross = MD.Overheal:Split(amount, overheal)
        else
            effective, gross = amount, amount + overheal
        end
        fight.healed = fight.healed + effective
        fight.overhealed = fight.overhealed + (gross - effective)
        fight.wastedMana = (fight.wastedMana or 0) + wasted
    end

    -- Debug "heal": every heal and HoT tick the player lands, exactly as the
    -- combat log reported it (whether "amount" already includes the overheal
    -- is the client property Engine/Overheal.lua latches). This is how heal
    -- formulas get verified in-game (Tree aura, Lifebloom bloom, relics).
    if MD.db and MD.db.debug and MD.db.debug.enabled and MD.db.debug.categories.heal then
        MD:Debug("heal", "%s (%d)%s on %s: %d%s%s%s", spellName or "?", spellID or 0,
            subevent == "SPELL_PERIODIC_HEAL" and " tick" or "", destName or "?", amount,
            overheal > 0 and string.format(" (%d overheal)", overheal) or "",
            critical and " CRIT" or "", MD:InTreeForm() and " [tree]" or "")
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
    MD:Debug("combat", "pull: mana %d/%d, regen base %.2f casting %.2f, zone %s",
        fight.startMana, UnitPowerMax("player", 0), MD.Regen.base, MD.Regen.casting,
        GetRealZoneText and GetRealZoneText() or "?")
    if MD.Targets then MD:Debug("combat", "roster: %s", MD.Targets:RosterLine()) end
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

    -- spend by family, biggest first, for the "where did it go" clause
    local SHORT = { Lifebloom = "LB", Rejuvenation = "RJ", Regrowth = "RG", HealingTouch = "HT",
                    Swiftmend = "SM", Tranquility = "TQ", other = "other" }
    local fams = {}
    for fam, mana in pairs(ST.combat.byFamily) do fams[#fams + 1] = { fam, mana } end
    table.sort(fams, function(a, b) return a[2] > b[2] end)
    local breakdown = {}
    for i = 1, math.min(4, #fams) do
        breakdown[#breakdown + 1] = string.format("%s %d%%", SHORT[fams[i][1]] or fams[i][1],
            fams[i][2] / ST.combat.spent * 100 + 0.5)
    end

    local parts = {
        FmtClock(duration),
        string.format("net %+d mp5", netMp5),
        string.format("spent %.1fk%s", ST.combat.spent / 1000,
            #breakdown > 0 and (" (" .. table.concat(breakdown, ", ") .. ")") or ""),
    }
    if (f.wastedMana or 0) > 0 then
        parts[#parts + 1] = string.format("~%.1fk into full health", f.wastedMana / 1000)
    end
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
    if MD.Overheal then
        for _, line in ipairs(MD.Overheal:Summary()) do
            MD:Debug("combat", "  overheal %s", line)
        end
    end
    MD:Print(summary)

    MD.fightHistory[#MD.fightHistory + 1] = {
        t = time(),
        duration = duration,
        avgSpendRate = avgSpendRate,
        netMp5 = netMp5,
        oomAt = f.oomAt,
        healed = f.healed,
        overhealed = f.overhealed,
        wastedMana = f.wastedMana,
        byFamily = (function() local t = {} for k, v in pairs(ST.combat.byFamily) do t[k] = v end return t end)(),
        zone = GetRealZoneText and GetRealZoneText() or nil,
        summary = summary,
    }
    if #MD.fightHistory > MAX_HISTORY then
        table.remove(MD.fightHistory, 1)
    end
    MD:Fire("FIGHT_RECORDED")
end)
