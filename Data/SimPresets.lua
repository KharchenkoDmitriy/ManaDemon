-- Synthetic scenarios for the Simulation window (docs/SPEC-v0.7.md 9).
--
-- EVERY NUMBER HERE IS A PLACEHOLDER. They are one healer's impression of what
-- a 5-man feels like, written down so the window has something to run before
-- any fight has been recorded. The moment a recording exists,
-- SimPlanner.FromRecordings() derives the same shapes from measurement and the
-- window says which it used. Do not tune a plan against these and believe it;
-- they exist to make the machinery usable, not to be true.
--
-- Provenance is on every table. When one of these is replaced by a measured
-- number, replace the comment with the measurement.
local _, MD = ...

local P = {}
MD.SimPresets = P

--------------------------------------------------------------------------------
-- Party: who is there, in what role, with how much health.
-- Health per level bracket is a rough TBC read: a level 70 tank around 9-11k
-- unbuffed, cloth around 5-6k. Scaled down linearly below 70, which is wrong in
-- detail and right enough in shape.
--------------------------------------------------------------------------------
local function HP(level, role)
    local base = role == "TANK" and 10000 or role == "HEALER" and 6200 or 6000
    return math.floor(base * math.min(1, (level or 70) / 70))
end

P.PARTY = {
    { id = "solo",  label = "Solo",     roles = { "HEALER" } },
    { id = "2",     label = "2 people", roles = { "TANK", "HEALER" } },
    { id = "3",     label = "3 people", roles = { "TANK", "HEALER", "DAMAGER" } },
    { id = "5",     label = "5 people", roles = { "TANK", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER" } },
    { id = "10",    label = "10 (your group of 5)",
      roles = { "TANK", "TANK", "HEALER", "HEALER", "DAMAGER" },
      note = "a raid is healed in subgroups; this is the five you are responsible for" },
    { id = "25",    label = "25 (your group of 5)",
      roles = { "TANK", "HEALER", "HEALER", "DAMAGER", "DAMAGER" },
      note = "same: your assignment, not the raid" },
}

function P.BuildTargets(partyID, level)
    local def
    for _, p in ipairs(P.PARTY) do if p.id == partyID then def = p end end
    if not def then return {} end
    local out = {}
    for i, role in ipairs(def.roles) do
        local maxHP = HP(level or (MD.player and MD.player.level) or 70, role)
        out[i] = { name = role == "HEALER" and "you" or (role:lower() .. i), role = role,
                   maxHP = maxHP, hp0 = maxHP, tracked = true }
    end
    return out
end

--------------------------------------------------------------------------------
-- Incoming damage. Analytic rather than event-by-event: a steady rate per
-- target plus optional pulses. The engine turns these into events.
--   dps    sustained damage per second on that role
--   pulse  { amount, period, offset } a big hit every `period` seconds
--------------------------------------------------------------------------------
P.DAMAGE = {
    { id = "tank1", label = "One steady tank",
      why = "a normal 5-man pull once the tank has aggro",
      byRole = { TANK = { dps = 450 } } },
    { id = "tank2", label = "Two steady targets",
      why = "an off-tank or a melee holding a second mob",
      byRole = { TANK = { dps = 450 }, DAMAGER = { dps = 300, first = 1 } } },
    { id = "dungeon", label = "Dungeon mixed",
      why = "the shape of the BF-1 log: a tank taking steady damage and somebody " ..
            "eating something occasionally",
      byRole = { TANK = { dps = 450, pulse = { amount = 1500, period = 12, offset = 5 } },
                 DAMAGER = { dps = 0, pulse = { amount = 1200, period = 17, offset = 9 }, first = 1 } } },
    { id = "aoe", label = "AoE on everyone",
      why = "a caster pack or a boss with a raid-wide tick",
      byRole = { TANK = { dps = 330 }, HEALER = { dps = 120 }, DAMAGER = { dps = 120 } } },
    { id = "tankaoe", label = "Tank damage plus AoE",
      why = "the hard case: the tank needs attention and nobody else is safe",
      byRole = { TANK = { dps = 600 }, HEALER = { dps = 120 }, DAMAGER = { dps = 120 } } },
}

--------------------------------------------------------------------------------
-- Situation: where everyone's health starts. Healing from full is a different
-- problem from healing from a wipe in progress.
--------------------------------------------------------------------------------
P.SITUATION = {
    { id = "full",   label = "Everyone full",      byRole = {} },
    { id = "low",    label = "Everyone at 30%",    all = 0.30 },
    { id = "tankdps", label = "Tank 50%, a dps at 10%",
      byRole = { TANK = 0.50 }, first = { DAMAGER = 0.10 } },
    { id = "spread", label = "Spread: 100 / 70 / 40 / 20",
      spread = { 1.00, 0.70, 0.40, 0.20 } },
}

--------------------------------------------------------------------------------
-- Turning a preset into a scenario the engine can run. Damage becomes events on
-- a fixed grid; the grid is 1s, which is finer than any healer reacts and
-- coarse enough that a 5 minute fight is 300 events per target.
--------------------------------------------------------------------------------
local GRID = 1.0

function P.BuildScenario(opts)
    local SM = MD.SimModel
    local targets = opts.targets or P.BuildTargets(opts.party or "5", opts.level)
    local dur = opts.dur or 60

    -- situation
    local sit
    for _, s in ipairs(P.SITUATION) do if s.id == (opts.situation or "full") then sit = s end end
    if sit then
        local firstDone = {}
        for i, tg in ipairs(targets) do
            local frac = 1
            if sit.all then frac = sit.all end
            if sit.spread then frac = sit.spread[math.min(i, #sit.spread)] end
            if sit.byRole and sit.byRole[tg.role] then frac = sit.byRole[tg.role] end
            if sit.first and sit.first[tg.role] and not firstDone[tg.role] then
                frac = sit.first[tg.role]
                firstDone[tg.role] = true
            end
            tg.hp0 = math.floor(tg.maxHP * frac)
        end
    end

    -- damage
    local dmg
    for _, d in ipairs(P.DAMAGE) do if d.id == (opts.damage or "tank1") then dmg = d end end
    local ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
    local n = 0
    local function push(t, tgt, amt)
        if amt <= 0 then return end
        n = n + 1
        ev.t[n], ev.kind[n], ev.tgt[n], ev.amt[n], ev.x[n] = t, SM.K.DMG, tgt, amt, 0
    end
    if dmg then
        local firstDone = {}
        for i, tg in ipairs(targets) do
            local spec = dmg.byRole and dmg.byRole[tg.role]
            local override = opts.perTarget and opts.perTarget[i]
            if override then spec = override end
            if spec and spec.first and firstDone[tg.role] then spec = nil end
            if spec then
                if spec.first then firstDone[tg.role] = true end
                local t = GRID
                while t <= dur do
                    push(t, i, (spec.dps or 0) * GRID)
                    t = t + GRID
                end
                if spec.pulse then
                    local pt = spec.pulse.offset or spec.pulse.period
                    while pt <= dur do
                        push(pt, i, spec.pulse.amount or 0)
                        pt = pt + (spec.pulse.period or 10)
                    end
                end
            end
        end
    end
    -- the engine reads ev in time order
    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(a, b)
        if ev.t[a] ~= ev.t[b] then return ev.t[a] < ev.t[b] end
        return a < b
    end)
    local sorted = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
    for j, i in ipairs(order) do
        sorted.t[j], sorted.kind[j], sorted.tgt[j] = ev.t[i], ev.kind[i], ev.tgt[i]
        sorted.amt[j], sorted.x[j] = ev.amt[i], ev.x[i]
    end

    local RM = MD.Regen
    local pool = opts.pool or UnitPowerMax("player", 0) or 0
    -- Utility mana in a synthetic fight: buffs, dispels and shifts are real
    -- spend the plan never chooses, so they go in as one lump at t = 0 rather
    -- than being quietly ignored (they were 12.6% of BF-1).
    local utility = opts.utility
    if utility == nil then utility = MD.db and MD.db.simUtilityPerFight or 0 end

    return {
        dur = dur, pool = pool,
        initial = { mana = math.max(0, (opts.mana or pool) - (utility or 0)),
                    apiBase = RM and RM.apiBase or 0, apiCasting = RM and RM.apiCasting or 0,
                    form = (MD.InTreeForm and MD:InTreeForm()) and "tree" or "caster" },
        targets = targets, ev = sorted,
        floor = (MD.db and MD.db.simFloor) or 0.30,
        grace = 6,
        synthetic = true, utility = utility or 0,
        damageLabel = dmg and dmg.label or "?", situationLabel = sit and sit.label or "?",
    }
end
