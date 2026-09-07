-- End-of-combat summary: one chat line per fight (>=15s) plus a ring of the
-- last 200 fights, persisted per character in MD.cdb.fights so the pull-time
-- spend seed and the "last time here" reference survive a /reload. The zone is
-- recorded with each fight; Engine/SpendTracker.lua prefers same-zone fights
-- when it seeds the estimator.
--
-- v0.7.0 adds the raw material for replay and coaching (docs/SPEC-v0.7.md §2):
-- every own cast is captured with its cost, target, HP-at-cast and form into a
-- 20s ring (so the pre-pull HoTs are known at the pull) and into the live
-- fight; at the end of combat each cast gets exactly one plan-free label and
-- the fight gets one extra chat line saying where the mana went.
local _, MD = ...

local SD = MD.SpellData

MD.fightHistory = {}
local MAX_HISTORY = 200

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

--------------------------------------------------------------------------------
-- Own-cast capture (SPEC-v0.7 §2.1)
--
-- One record per cast the player lands, appended to MD.Recorder.ring (always,
-- last 20s) and to the live fight (in combat). The record is the unit both the
-- labels below and the v0.7.1 replay engine read, so it carries everything the
-- combat log cannot reconstruct afterwards: what the target's health was at the
-- moment of the cast, what the cast cost, and whether the player was in Tree
-- form. Anything unavailable is -1, never 0 -- a fabricated zero reads like a
-- measurement (the OOM 0s bug in Engine/TTO.lua was exactly that).
--------------------------------------------------------------------------------
local RING_WINDOW = 20   -- seconds of own casts kept before the pull
local HOT_TICK_TTL = 60  -- seconds before a stale HoT record is dropped

MD.Recorder = {
    ring = {},        -- own casts, last RING_WINDOW seconds
    roster = {},      -- index -> { guid, name, class, role }; stable for the session
    rosterIndex = {}, -- guid -> index
    hots = {},        -- "<guid>\029<family>" -> the cast record that applied it
}
local Rec = MD.Recorder

local SHIFT_SPELLS = {
    [33891] = true,  -- Tree of Life
    [5487]  = true, [9634] = true, -- Bear / Dire Bear
    [768]   = true,  -- Cat
    [783]   = true,  -- Travel
    [1066]  = true,  -- Aquatic
    [24858] = true,  -- Moonkin
}

-- Families whose ticks are tracked (prehot needs Lifebloom too) and the
-- subset where a refresh with ticks left over is genuinely early. Refreshing
-- Lifebloom before it blooms is the play, not a mistake, so it is not here.
local TICKED_FAMILIES = { Rejuvenation = true, Regrowth = true, Lifebloom = true }
local EARLY_FAMILIES = { Rejuvenation = true, Regrowth = true }
local TICK_INTERVAL = { Lifebloom = 1 } -- default 3

-- Utility casts worth naming in the summary: buffs the player put up while the
-- pull was already running. enUS only, like the drink names in UI/Advisor.lua.
local BUFF_NAMES = {
    ["Mark of the Wild"] = true, ["Gift of the Wild"] = true,
    ["Thorns"] = true, ["Omen of Clarity"] = true,
}

local function HotKey(guid, family) return guid .. "\029" .. family end

-- Roster index for a combat-log destination: a small integer the replay engine
-- can key on, assigned on first sight and stable for the session. -1 for
-- anything outside the group.
function Rec:Index(guid, name)
    if not guid or guid == "" then return -1 end
    local i = Rec.rosterIndex[guid]
    if i then return i end
    local e = MD.Targets and MD.Targets:Lookup(guid, name)
    if not e then return -1 end
    i = #Rec.roster + 1
    Rec.roster[i] = { guid = guid, name = e.name, class = e.class, role = e.role }
    Rec.rosterIndex[guid] = i
    return i
end

-- Health fraction of a combat-log destination, or -1 when it cannot be read.
-- The unit token from the roster is only trusted while it still points at the
-- same GUID (party slots shuffle).
local function HpFraction(guid, name)
    if not guid or guid == "" then return -1 end
    local e = MD.Targets and MD.Targets:Lookup(guid, name)
    local unit = e and e.unit
    if not unit or UnitGUID(unit) ~= guid then return -1 end
    local maxHp = UnitHealthMax(unit)
    if not maxHp or maxHp <= 0 then return -1 end
    return UnitHealth(unit) / maxHp
end

local function NoteOwnCast(spellID, destGUID, destName)
    if type(spellID) ~= "number" then return end
    local now = GetTime()
    local sd = SD.spells[spellID]

    local kind = "utility"
    if SHIFT_SPELLS[spellID] then
        kind = "shift"
    elseif sd and SD.families[sd.family] then
        kind = "heal"
    end

    local cost = SD:GetCost(spellID)
    local c = {
        t = now,
        spellID = spellID,
        cost = cost or -1,
        tgt = Rec:Index(destGUID, destName),
        hpAtCast = HpFraction(destGUID, destName),
        form = MD:InTreeForm() and 1 or 0,
        kind = kind,
    }

    -- HoT bookkeeping: the record that applied the HoT owns the ticks that
    -- follow it, which is what makes both "early" (ticks still pending when the
    -- next one went out) and "prehot" (how much of a pre-pull HoT was overheal)
    -- measurements rather than guesses.
    if kind == "heal" and sd and TICKED_FAMILIES[sd.family] and destGUID and destGUID ~= "" then
        local key = HotKey(destGUID, sd.family)
        local prev = Rec.hots[key]
        if prev and EARLY_FAMILIES[sd.family]
           and (prev.ticksTotal - prev.ticksSeen) >= 2 then
            c.early = true
        end
        local interval = TICK_INTERVAL[sd.family] or 3
        c.ticksTotal = sd.hotDuration and math.floor(sd.hotDuration / interval + 0.5) or 4
        c.ticksSeen, c.tickGross, c.tickOver = 0, 0, 0
        Rec.hots[key] = c
    end

    Rec.ring[#Rec.ring + 1] = c
    while Rec.ring[1] and now - Rec.ring[1].t > RING_WINDOW do
        table.remove(Rec.ring, 1)
    end

    if fight then
        fight.casts[#fight.casts + 1] = c
        fight.ownCasts = fight.ownCasts + 1
    end
end

local function PruneHots(now)
    for key, c in pairs(Rec.hots) do
        if now - c.t > HOT_TICK_TTL then Rec.hots[key] = nil end
    end
end

-- Combat log, one handler and one CombatLogGetCurrentEventInfo() call: the
-- player's own heals feed the fight totals, the per-spell overheal stats and
-- the "heal" debug category; the player's own casts feed the ring above.
-- Overheal is recorded in AND out of combat -- rolling Lifebloom on a tank
-- between pulls is exactly the sort of casting whose overheal belongs in the
-- average.
MD:On("COMBAT_LOG_EVENT_UNFILTERED", function()
    -- One unpack for the whole addon. The 11-field prefix is fixed; what p1..p10
    -- mean depends on the subevent (docs/SPEC-v0.7.md 1), so they are named
    -- generically here and interpreted by whoever needs them. For the heal
    -- events this file cares about: p1 spellID, p2 spellName, p4 amount,
    -- p5 overheal, p7 critical.
    local _, subevent, _, sourceGUID, _, _, _, destGUID, destName, _, _,
        p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 = CombatLogGetCurrentEventInfo()
    local spellID, spellName, amount, overheal, critical = p1, p2, p4, p5, p7
    -- group members' own casts (Life Tap) before the player-only gate
    if subevent == "SPELL_CAST_SUCCESS" and MD.Targets then
        MD.Targets:NoteCast(sourceGUID, spellName)
    end
    -- The recorder sees everything, including other people's damage and heals;
    -- it decides for itself what is worth keeping (Engine/FightRecorder.lua).
    if MD.FightRecorder and MD.FightRecorder.active then
        if subevent == "UNIT_DIED" then
            MD.FightRecorder:Died(destGUID, destName)
        else
            MD.FightRecorder:Event(subevent, sourceGUID, destGUID, destName,
                p1, p2, p3, p4, p5, p6, p7, p8, p9, p10)
            -- v0.12.0: a hostile cast aimed at somebody we are healing. Not
            -- handled inside FR:Event because that one is written around "is
            -- this the player's own event"; this is the opposite question.
            if sourceGUID ~= MD.player.guid then
                MD.FightRecorder:EnemyCast(subevent, sourceGUID, destGUID, destName, p1)
            end
        end
    end
    if sourceGUID ~= MD.player.guid then return end
    -- SPELL_CAST_SUCCESS carries the cast's target in the prefix destGUID /
    -- destName (verified against Details!, SPEC-v0.7 §1) -- no cast-to-heal
    -- matching is needed.
    if subevent == "SPELL_CAST_SUCCESS" then
        NoteOwnCast(spellID, destGUID, destName)
        return
    end
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

    -- one convention for the whole addon (Engine/Overheal.lua): whether the
    -- log's "amount" already includes the overheal is a client property,
    -- latched from the first full overheal seen. (A function call inside
    -- "a and f() or b" is truncated to ONE value -- the bug v0.5.3 already
    -- fixed once in this file; write the if out.)
    local effective, gross
    if MD.Overheal then
        effective, gross = MD.Overheal:Split(amount, overheal)
    else
        effective, gross = amount, amount + overheal
    end

    if MD.Calibration then
        MD.Calibration:Observe(spellID, kind, gross, critical, destGUID)
    end

    -- Ticks are credited to the cast record that applied the HoT.
    if kind == "tick" and destGUID and destGUID ~= "" then
        local sd = SD.spells[spellID]
        local h = sd and Rec.hots[HotKey(destGUID, sd.family)]
        if h then
            h.ticksSeen = h.ticksSeen + 1
            h.tickGross = h.tickGross + gross
            h.tickOver = h.tickOver + (gross - effective)
        end
    end

    if fight then
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
    local now = GetTime()
    PruneHots(now)
    fight = {
        start = now,
        startMana = UnitPower("player", 0),
        healed = 0,
        overhealed = 0,
        oomAt = nil,
        casts = {},
        ownCasts = 0,
        precasts = {},
        lowestMana = 1,
    }
    -- Freeze each pre-pull HoT's tick accounting at the pull: what those HoTs
    -- overhealed BEFORE the fight started is the prehot measurement; whatever
    -- they tick for afterwards belongs to the fight.
    for i = 1, #Rec.ring do
        local c = Rec.ring[i]
        c.preGross, c.preOver = c.tickGross or 0, c.tickOver or 0
        fight.precasts[i] = c
    end
    MD:Debug("combat", "pull: mana %d/%d, regen base %.2f casting %.2f, zone %s",
        fight.startMana, UnitPowerMax("player", 0), MD.Regen.base, MD.Regen.casting,
        GetRealZoneText and GetRealZoneText() or "?")
    MD:Debug("sim", "pull: %d cast(s) in the last %ds carried into the fight", #fight.precasts, RING_WINDOW)
    if MD.FightRecorder then MD.FightRecorder:Start(now) end
    if MD.Targets then MD:Debug("combat", "roster: %s", MD.Targets:RosterLine()) end
end)

-- OOM detection (below 2% counts as dry) and the fight's mana low-water mark.
MD:OnTick(function()
    if not fight then return end
    if MD.FightRecorder then MD.FightRecorder:Tick() end
    local manaMax = UnitPowerMax("player", 0)
    if manaMax <= 0 then return end
    local frac = UnitPower("player", 0) / manaMax
    if frac < fight.lowestMana then fight.lowestMana = frac end
    if not fight.oomAt and frac <= 0.02 then
        fight.oomAt = GetTime() - fight.start
    end
end)

local function FmtClock(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

local function FmtMana(v)
    if v >= 1000 then return string.format("%.1fk", v / 1000) end
    return string.format("%d", v + 0.5)
end

local function FamilyLabel(fam)
    local f = SD.families[fam]
    return (f and f.label) or fam
end

-- Family counts as "Lifebloom 9, Rejuvenation 4, Regrowth 1", descending by
-- count, at most `top` entries.
local function FamilyList(counts, top)
    local list = {}
    for fam, n in pairs(counts) do list[#list + 1] = { fam, n } end
    table.sort(list, function(a, b)
        if a[2] ~= b[2] then return a[2] > b[2] end
        return a[1] < b[1]
    end)
    local out = {}
    for i = 1, math.min(top or 3, #list) do
        out[#out + 1] = string.format("%s %d", FamilyLabel(list[i][1]), list[i][2])
    end
    return table.concat(out, ", ")
end

--------------------------------------------------------------------------------
-- Plan-free labels (SPEC-v0.7 §2.2): exactly one per own cast, in this
-- precedence -- utility, shift, early, overheal, ok -- and none of it needs a
-- simulator. Their mana must add up to what the fight spent; the identity is
-- checked in the "sim" debug category, because a label set that does not
-- account for every point of mana would quietly mislead the Review tab.
--------------------------------------------------------------------------------
local LABEL_KEYS = { "utility", "shift", "early", "overheal", "ok" }

local function LabelFight(f, fullHp)
    local labels, labelCasts = {}, {}
    for _, k in ipairs(LABEL_KEYS) do labels[k], labelCasts[k] = 0, 0 end
    local hpBuckets = { 0, 0, 0, 0 }
    local aboveCount, aboveMana, healCasts = 0, 0, 0
    local aboveFams, buffs = {}, {}

    for _, c in ipairs(f.casts) do
        local mana = c.cost > 0 and c.cost or 0
        local label
        if c.kind == "utility" then
            label = "utility"
            local name = GetSpellInfo(c.spellID)
            if name and BUFF_NAMES[name] then
                buffs[#buffs + 1] = { name = name, at = c.t - f.start }
            end
        elseif c.kind == "shift" then
            label = "shift"
        elseif c.early then
            label = "early"
        elseif c.hpAtCast >= fullHp then
            label = "overheal"
        else
            label = "ok"
        end
        labels[label] = labels[label] + mana
        labelCasts[label] = labelCasts[label] + 1

        -- HP buckets and the "above full" clause are a fact about the target's
        -- health, independent of which label won the precedence: a Rejuvenation
        -- refreshed early on a full-health tank is both.
        if c.kind == "heal" then
            healCasts = healCasts + 1
            local hp = c.hpAtCast
            local b
            if hp < 0 then b = 4 elseif hp < 0.5 then b = 1 elseif hp < fullHp then b = 2 else b = 3 end
            hpBuckets[b] = hpBuckets[b] + 1
            if b == 3 then
                aboveCount, aboveMana = aboveCount + 1, aboveMana + mana
                local sd = SD.spells[c.spellID]
                local fam = sd and sd.family or "other"
                aboveFams[fam] = (aboveFams[fam] or 0) + 1
            end
        end
    end

    return labels, labelCasts, hpBuckets, aboveCount, aboveMana, healCasts, aboveFams, buffs
end

-- prehot: HoTs put on an already-full target before the pull, whose ticks
-- landed before the fight even started and mostly went nowhere. Its mana sits
-- outside the fight's spend, which is exactly why it is reported separately.
local function PreHot(f, fullHp)
    local mana, gross, over, fams = 0, 0, 0, {}
    for _, c in ipairs(f.precasts) do
        if c.kind == "heal" and c.hpAtCast >= 0.95 and (c.preGross or 0) > 0
           and c.preOver / c.preGross >= 0.5 then
            mana = mana + (c.cost > 0 and c.cost or 0)
            gross, over = gross + c.preGross, over + c.preOver
            local sd = SD.spells[c.spellID]
            local fam = sd and sd.family or "other"
            fams[fam] = (fams[fam] or 0) + 1
        end
    end
    return mana, gross, over, fams
end

MD:On("PLAYER_REGEN_ENABLED", function()
    if not fight then return end
    local f = fight
    fight = nil
    PruneHots(GetTime())

    local duration = GetTime() - f.start
    local ST = MD.Spend
    if duration < 15 or ST.combat.spent <= 0 then
        MD:Debug("combat", "end: %.0fs, spent %d - too short to record", duration, ST.combat.spent)
        if MD.FightRecorder then MD.FightRecorder:Finish(duration) end
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

    ----------------------------------------------------------------------------
    -- The v0.7.0 line: where the casts went, not just where the mana went.
    ----------------------------------------------------------------------------
    local fullHp = (MD.db and MD.db.simFullHp) or 0.85
    local labels, labelCasts, hpBuckets, aboveCount, aboveMana, healCasts, aboveFams, buffs
        = LabelFight(f, fullHp)
    local prehotMana, prehotGross, prehotOver, prehotFams = PreHot(f, fullHp)

    local labelled = 0
    for _, k in ipairs(LABEL_KEYS) do labelled = labelled + labels[k] end
    MD:Debug("sim", "labels: %s = %d (fight spend %d, delta %+d)",
        (function()
            local t = {}
            for _, k in ipairs(LABEL_KEYS) do
                t[#t + 1] = string.format("%s %d/%d", k, labels[k], labelCasts[k])
            end
            return table.concat(t, ", ")
        end)(), labelled, ST.combat.spent, labelled - ST.combat.spent)
    if math.abs(labelled - ST.combat.spent) > math.max(50, ST.combat.spent * 0.02) then
        MD:Debug("sim", "label identity BROKEN: %d labelled vs %d spent over %d own cast(s)",
            labelled, ST.combat.spent, f.ownCasts)
    end

    if f.ownCasts >= 4 then
        local extra = ""
        local support = labels.utility + labels.shift
        if support > 0 then
            extra = extra .. " - utility/shifts " .. FmtMana(support)
        end
        if #buffs > 0 then
            local shown = {}
            for i = 1, math.min(2, #buffs) do
                shown[#shown + 1] = string.format("%s at %s", buffs[i].name, FmtClock(buffs[i].at))
            end
            extra = extra .. " - buffed in combat: " .. table.concat(shown, ", ")
            if #buffs > 2 then extra = extra .. string.format(" (+%d more)", #buffs - 2) end
        end
        -- With nothing above the line the mana and family clauses would render
        -- as "(0): " -- say the good news plainly instead.
        local head
        if aboveCount > 0 then
            head = string.format("%d of %d casts on targets above %d%% (%s): %s",
                aboveCount, healCasts, fullHp * 100 + 0.5, FmtMana(aboveMana),
                FamilyList(aboveFams, 3))
        else
            head = string.format("no casts on targets above %d%% (%d heal casts)",
                fullHp * 100 + 0.5, healCasts)
        end
        MD:Print(head .. extra)
        if prehotMana > 0 then
            MD:Print(string.format("pre-pull HoTs on full targets: %s (%d%% overheal)",
                FmtMana(prehotMana) .. " in " .. FamilyList(prehotFams, 3),
                prehotOver / prehotGross * 100 + 0.5))
        end
    end

    local stream
    if MD.FightRecorder then stream = MD.FightRecorder:Finish(duration, labels) end

    -- Fights with almost no casting say nothing about how the healer played and
    -- would poison both the spend seed and the habit counts, so they are not
    -- kept at all (SPEC-v0.7 §2.3).
    if f.ownCasts < 4 then
        MD:Debug("combat", "end: %.0fs but only %d own cast(s) - not recorded", duration, f.ownCasts)
        return
    end

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
        -- v0.7.0
        labels = labels,
        labelCasts = labelCasts,
        hpBuckets = hpBuckets,
        prehot = prehotMana,
        foreignShare = stream and stream.foreignShare or nil,
        lowestMana = f.lowestMana,
        ownCasts = f.ownCasts,
        streamID = stream and stream.id or nil,
    }
    if #MD.fightHistory > MAX_HISTORY then
        table.remove(MD.fightHistory, 1)
    end
    MD:Fire("FIGHT_RECORDED")
end)
