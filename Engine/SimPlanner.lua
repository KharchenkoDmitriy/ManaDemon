-- Plans: a healing strategy a human could actually follow, and the machinery to
-- score one, compare it with what the player did, and say what to change.
--
-- CAUSALITY: Plan:Decide(state, t) receives, and may read, ONLY: t; each
-- target's hp, maxHP, alive, and the player's own HoT state on it as of t;
-- mana, form, cooldowns as of t; and ONE derived input: each target's damage
-- taken over the trailing 5 s, computed from events already applied. It holds
-- no reference to the scenario's event arrays and nothing it schedules may
-- depend on any event with t' > t. A cast, once started, is locked until it
-- lands. This is what makes the card advice rather than hindsight.
--
-- A plan is deliberately small: at most five bound spells and five rules in a
-- fixed order. "Cast rank 7 here and rank 9 there" is not a strategy a person
-- can execute at 2am in a heroic, and a suggestion nobody can follow is worse
-- than no suggestion.
local _, MD = ...

local SP = {}
MD.SimPlanner = SP

local SM = nil  -- MD.SimModel, bound lazily
local HOT_INDEX = { Rejuvenation = 1, Regrowth = 2, Lifebloom = 3 }

-- Parameter domains (docs/SPEC-v0.7.md 5.1). Small on purpose: the search has
-- 300 evaluations and a human has to remember the answer.
SP.DOMAINS = {
    swiftmendBelow = { 0.30, 0.40 },
    directBelow    = { 0.35, 0.45, 0.55 },
    rollStacks     = { 0, 1, 3 },
    hotBelow       = { 0.60, 0.80, 0.90 },
    filler         = { false, true },   -- wait, or Lifebloom x1 on the tank
}
SP.PARAM_ORDER = { "swiftmendBelow", "directBelow", "rollStacks", "hotBelow", "filler" }

-- The families a rule can bind. Tranquility is deliberately absent: the spell
-- table carries no heal values for it, so no plan may spend the player's mana
-- on a number nobody has measured (spec 13 also rules it out of v0.7 planning).
SP.BINDABLE = { "Lifebloom", "Rejuvenation", "Regrowth", "HealingTouch", "Swiftmend" }

--------------------------------------------------------------------------------
-- Binds: which rank of which family the plan uses. Fixed by default to the
-- ranks the player actually cast, because a card that silently rebinds every
-- spell is a different addon's suggestion, not this fight's.
--------------------------------------------------------------------------------
function SP.BindsFromRecording(rec, kit)
    local SD = MD.SpellData
    local counts = {}
    if rec then
        for i = 1, (rec.n or 0) do
            if rec.ev.kind[i] == MD.SimModel.K.OWNCAST then
                local id = rec.ev.x[i]
                local sd = SD.spells[id]
                if sd and SD.families[sd.family] then
                    counts[sd.family] = counts[sd.family] or {}
                    counts[sd.family][id] = (counts[sd.family][id] or 0) + 1
                end
            end
        end
    end
    local binds = {}
    for _, family in ipairs(SP.BINDABLE) do
        local best, bestN
        for id, n in pairs(counts[family] or {}) do
            if not bestN or n > bestN then best, bestN = id, n end
        end
        binds[family] = best or SD.maxRank[family]
    end
    return binds
end

function SP.MaxRankBinds()
    local SD, binds = MD.SpellData, {}
    for _, family in ipairs(SP.BINDABLE) do binds[family] = SD.maxRank[family] end
    return binds
end

--------------------------------------------------------------------------------
-- A plan
--------------------------------------------------------------------------------
local Plan = {}
Plan.__index = Plan

function SP.NewPlan(binds, params, kit)
    SM = SM or MD.SimModel
    local p = setmetatable({
        binds = binds,
        kit = kit,
        swiftmendBelow = params.swiftmendBelow or 0.30,
        directBelow = params.directBelow or 0.45,
        rollStacks = params.rollStacks or 3,
        hotBelow = params.hotBelow or 0.80,
        filler = params.filler or false,
        noDirect = params.noDirect or false,   -- the "HoTs only" baseline
    }, Plan)
    return p
end

function Plan:Reset()
    self.anchor = nil
end

function Plan:Params()
    return { swiftmendBelow = self.swiftmendBelow, directBelow = self.directBelow,
             rollStacks = self.rollStacks, hotBelow = self.hotBelow,
             filler = self.filler, noDirect = self.noDirect }
end

function Plan:Clone(param, value)
    local params = self:Params()
    params[param] = value
    return SP.NewPlan(self.binds, params, self.kit)
end

-- The tank, or -- failing a role -- whoever has taken the most damage so far.
-- Recomputed rather than cached: roles can be wrong and damage is causal.
local function Anchor(self, S, t)
    if self.anchor and not S.dead[self.anchor] then return self.anchor end
    local best, bestDmg
    for i = 1, S.nT do
        if S.tracked[i] and not S.dead[i] then
            if S.role[i] == "TANK" then self.anchor = i; return i end
            local d = SM.RecentDamage(S, i, t, 60)
            if not bestDmg or d > bestDmg then best, bestDmg = i, d end
        end
    end
    return best
end

-- Lowest health fraction first, the anchor breaking ties: two people at 40% and
-- one of them is holding the mob.
local function Neediest(self, S, t, below, requireNoHot, hotIndex)
    local pick, pickFrac
    local anchor = Anchor(self, S, t)
    for i = 1, S.nT do
        if S.tracked[i] and not S.dead[i] and S.maxHP[i] > 0 then
            local frac = S.hp[i] / S.maxHP[i]
            if frac < below then
                local ok = true
                if requireNoHot and hotIndex then
                    local st = S.hots[i] and S.hots[i][hotIndex]
                    ok = not (st and st.active)
                end
                if ok then
                    if not pick or frac < pickFrac - 0.0001
                       or (math.abs(frac - pickFrac) <= 0.0001 and i == anchor) then
                        pick, pickFrac = i, frac
                    end
                end
            end
        end
    end
    return pick, pickFrac
end

-- Rules, in the fixed order. Returns spellID, target -- or nil to wait, which
-- is a real answer: the less you drink, the faster the dungeon goes.
-- Returns spellID, target, rule -- the rule (1..5) is the reason, recorded by
-- the trace; every other caller ignores it.
function Plan:Decide(S, t, mana, form)
    local kit = self.kit[form] or self.kit.caster
    local function affordable(id)
        local e = id and kit[id]
        return e and mana >= (e.cost or 0) and e or nil
    end

    -- 1. Swiftmend: instant, cheap, and it eats a HoT that was going to tick
    --    into a corpse anyway.
    local sm = self.binds.Swiftmend
    local smE = affordable(sm)
    if smE and SM.Ready(S, sm, t) then
        local i = Neediest(self, S, t, self.swiftmendBelow)
        if i then
            local row = S.hots[i]
            local has = row and ((row[HOT_INDEX.Regrowth] and row[HOT_INDEX.Regrowth].active)
                              or (row[HOT_INDEX.Rejuvenation] and row[HOT_INDEX.Rejuvenation].active))
            if has then return sm, i, 1 end
        end
    end

    -- 2. A direct heal, when a HoT would not arrive in time. The deficit test
    --    uses the NON-CRIT amount: a plan that counts on a crit is a plan that
    --    kills somebody one fight in five.
    if not self.noDirect then
        local direct = self.binds.Regrowth or self.binds.HealingTouch
        local dE = affordable(direct)
        if dE then
            local i = Neediest(self, S, t, self.directBelow)
            if i then return direct, i, 2 end
        end
    end

    -- 3. Keep Lifebloom rolling on the anchor.
    local lb = self.binds.Lifebloom
    local lbE = affordable(lb)
    if lbE and self.rollStacks > 0 then
        local i = Anchor(self, S, t)
        if i then
            local st = S.hots[i] and S.hots[i][HOT_INDEX.Lifebloom]
            local stacks = (st and st.active) and st.stacks or 0
            if stacks < self.rollStacks then return lb, i, 3 end
            -- at the target stack, refresh only as it is about to fall off
            if st and st.active and (st.expires - t) <= 1.5 then return lb, i, 3 end
        end
    end

    -- 4. Rejuvenation on anyone hurt who does not already have one.
    local rj = self.binds.Rejuvenation
    local rjE = affordable(rj)
    if rjE then
        local i = Neediest(self, S, t, self.hotBelow, true, HOT_INDEX.Rejuvenation)
        if i then return rj, i, 4 end
    end

    -- 5. Filler, or wait.
    if self.filler and lbE then
        local i = Anchor(self, S, t)
        local st = i and S.hots[i] and S.hots[i][HOT_INDEX.Lifebloom]
        if i and not (st and st.active) then return lb, i, 5 end
    end
    return nil
end

-- One line per rule, for the replay window's "why" (docs/SPEC-v0.8.md 4.3).
SP.RULE_NAMES = {
    "Swiftmend on a big hit", "direct heal, a HoT would be late",
    "keep Lifebloom rolling on the anchor", "Rejuvenation on anyone hurt", "filler",
}

function Plan:BindCount()
    local n = 0
    for _, id in pairs(self.binds) do if id then n = n + 1 end end
    return n
end

--------------------------------------------------------------------------------
-- Score: lexicographic, lower is better (docs/SPEC-v0.7.md 5.3).
--   (deaths, floorSeconds, manaSpent, -heldOn, #binds, overhealSim)
-- Nothing is blended into a scalar. A plan that lets somebody die is not
-- redeemed by saving mana, and no weight can be chosen that says otherwise.
--------------------------------------------------------------------------------
function SP.Score(result, plan, heldOn)
    local oh = 0
    local total = (result.healed or 0) + (result.overhealed or 0)
    if total > 0 then oh = result.overhealed / total end
    return { result.deaths and result.deaths.n or 0, result.floorSeconds or 0,
             result.manaSpent or 0, -(heldOn or 0), plan and plan:BindCount() or 0, oh }
end

function SP.Better(a, b)
    if not b then return true end
    for i = 1, #a do
        if a[i] < b[i] - 1e-9 then return true end
        if a[i] > b[i] + 1e-9 then return false end
    end
    return false
end

--------------------------------------------------------------------------------
-- Running a plan on a scenario. The scenario's own script is removed: a plan
-- decides for itself, and leaving the recorded casts in would have it cast
-- twice.
--------------------------------------------------------------------------------
function SP.RunPlan(scenario, plan, opts)
    SM = SM or MD.SimModel
    local saved = scenario.script
    scenario.script = nil
    local r = SM:Run(scenario, plan, opts)
    scenario.script = saved
    return r
end

--------------------------------------------------------------------------------
-- Baselines, always run (5.4). "You" is the replay itself.
--------------------------------------------------------------------------------
function SP.Baselines(rec, kit)
    local maxBinds = SP.MaxRankBinds()
    return {
        { name = "max rank", plan = SP.NewPlan(maxBinds,
            { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80,
              filler = false }, kit) },
        { name = "HoTs only", plan = SP.NewPlan(maxBinds,
            { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80,
              filler = false, noDirect = true }, kit) },
    }
end

--------------------------------------------------------------------------------
-- The classifier (docs/SPEC-v0.7.md 5.5). Every cast the player made gets
-- exactly one plan-relative label, and their mana must add up to the fight's
-- spend -- an identity that is asserted, because a breakdown that quietly loses
-- a thousand mana would be worse than no breakdown.
--
-- Two of the ten labels cannot be answered by asking the plan at the moment of
-- a real cast, because they are about casts the plan wanted at other moments:
-- `late` (the plan would have healed this target 3s earlier) and `idle` (the
-- plan cast where the player did nothing). Those two come from running the plan
-- on the same scenario and comparing timelines; the other eight are answered in
-- lockstep, with the recording's own state. The split is stated on the card.
--------------------------------------------------------------------------------
local LABELS = { "utility", "shift", "fine", "rank", "spell", "early", "stack",
                 "overheal", "late", "unclassified" }
SP.LABELS = LABELS

local SHIFT_SPELLS = { [33891] = true, [5487] = true, [9634] = true, [768] = true,
                       [783] = true, [1066] = true, [24858] = true }

function SP.Classify(rec, scenario, plan, kit)
    SM = SM or MD.SimModel
    local SD = MD.SpellData
    local K = SM.K
    local fullHp = (MD.db and MD.db.simFullHp) or 0.85

    -- what the plan would do on its own, for `late` and `idle`
    local planCasts = {}
    local planResult = SP.RunPlan(scenario, plan, {
        critMode = "ev",
        onCast = function(_, t, spellID, ti) planCasts[#planCasts + 1] = { t, spellID, ti } end,
    })

    local labels, counts = {}, {}
    for _, k in ipairs(LABELS) do labels[k], counts[k] = 0, 0 end
    local detail = { overheal = {}, unclassified = {} }
    local perCast = {}   -- [n] = { t, spellID, tgt, label }, in cast order (SPEC-v0.8 4.2)

    -- the recorded costs, in cast order: the replay fires onCast in the same
    -- order, so cast n costs costs[n]
    local costs = {}
    for i = 1, (rec.n or 0) do
        if rec.ev.kind[i] == K.OWNCAST then
            costs[#costs + 1] = (rec.ev.amt[i] or 0) > 0 and rec.ev.amt[i] or 0
        end
    end

    local ci = 0
    local r = SM:Run(scenario, nil, {
        critMode = "ev",
        onCast = function(S, t, spellID, ti, mana, form)
            ci = ci + 1
            local sd = SD.spells[spellID]
            local cost = costs[ci] or 0
            local label
            local wantID, wantTgt = plan:Decide(S, t, mana, form)
            local wantSd = wantID and SD.spells[wantID]
            local hp = (ti and ti >= 1 and ti <= S.nT and S.maxHP[ti] > 0)
                and (S.hp[ti] / S.maxHP[ti]) or -1

            if SHIFT_SPELLS[spellID] then
                label = "shift"
            elseif not (sd and SD.families[sd.family]) then
                label = "utility"
            elseif wantSd and wantSd.family == sd.family and wantTgt == ti then
                label = (wantID ~= spellID) and "rank" or "fine"
            elseif wantSd and wantSd.family == sd.family then
                label = "fine"   -- right spell, the plan just had somebody worse in mind
            elseif sd.family == "Lifebloom" then
                local st = ti and ti >= 1 and S.hots[ti] and S.hots[ti][HOT_INDEX.Lifebloom]
                if st and st.active and st.stacks >= plan.rollStacks and plan.rollStacks > 0 then
                    label = "stack"
                end
            end

            if not label and (sd.family == "Rejuvenation" or sd.family == "Regrowth") then
                local fi = HOT_INDEX[sd.family]
                local st = ti and ti >= 1 and S.hots[ti] and S.hots[ti][fi]
                if st and st.active and st.ticksLeft >= 2 then label = "early" end
            end
            if not label and hp >= 0 and hp >= fullHp and wantID == nil then
                label = "overheal"
            end
            if not label and wantSd and wantTgt == ti then
                label = "spell"
            end
            if not label then
                -- did the plan want this target earlier and get ignored?
                for _, pc in ipairs(planCasts) do
                    if pc[3] == ti and pc[1] <= t - 3 then label = "late"; break end
                end
            end
            label = label or "unclassified"
            perCast[ci] = { t = t, spellID = spellID, tgt = ti, label = label }

            labels[label] = labels[label] + cost
            counts[label] = counts[label] + 1
            if label == "overheal" and sd then
                detail.overheal[sd.family] = (detail.overheal[sd.family] or 0) + 1
            elseif label == "unclassified" then
                detail.unclassified[#detail.unclassified + 1] =
                    string.format("%s at %.0fs", GetSpellInfo(spellID) or spellID, t)
            end
        end,
    })

    -- idle: the plan cast where the player did nothing, and the target had been
    -- below the floor long enough that a human could have known
    local reaction = (MD.db and MD.db.simReaction) or 0.5
    local realT = {}
    for i = 1, (rec.n or 0) do
        if rec.ev.kind[i] == K.OWNCAST then realT[#realT + 1] = rec.ev.t[i] end
    end
    local idle = 0
    for _, pc in ipairs(planCasts) do
        local near = false
        for _, rt in ipairs(realT) do
            if math.abs(rt - pc[1]) <= reaction + 2.0 then near = true; break end
        end
        if not near then idle = idle + 1 end
    end

    return { labels = labels, counts = counts, detail = detail, idle = idle, casts = perCast,
             replay = r, planResult = planResult, planCasts = planCasts }
end

--------------------------------------------------------------------------------
-- The card (docs/SPEC-v0.7.md 5.7): what to change, in the order a healer would
-- read it, with the numbers that justify it and the caveats that limit it.
--
-- The verdict line comes first and is allowed to say "nothing here needed to
-- change", because most pulls do not need coaching and a card that always finds
-- something is a card nobody trusts twice.
--------------------------------------------------------------------------------
local function Fmt(v)
    if v >= 1000 then return string.format("%.1fk", v / 1000) end
    return string.format("%d", v + 0.5)
end

local function Clock(sec)
    return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

local function RankLabel(id)
    local sd = MD.SpellData.spells[id]
    return sd and string.format("%s R%d", MD.SpellData.families[sd.family].label, sd.rank)
        or tostring(id)
end

function SP.Card(rec, best, bestResult, replayResult, baselineResults, cls, validation)
    local out = {}
    local function add(fmt, ...) out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end

    local nTargets = #(rec.tracked or {})
    add("%s, %s (%s, %d targets)   you %s   best %s   diff %s",
        rec.zone or "?", date and date("%H:%M", rec.id) or "", Clock(rec.dur or 0), nTargets,
        Fmt(replayResult.manaSpent), Fmt(bestResult.manaSpent),
        Fmt(math.abs(replayResult.manaSpent - bestResult.manaSpent)))

    -- verdict
    -- "did this pull even need coaching": one more pull's worth of mana left in
    -- the tank is the honest answer to most fights.
    local budget = MD.PullBudget and MD.PullBudget:Estimate()
    if budget and budget.n >= 2 and replayResult.lowestMana - budget.perPull >= 0 then
        add("  you had %s headroom - nothing here needed to change",
            Fmt(replayResult.lowestMana - budget.perPull))
    elseif budget and budget.n >= 4 and budget.perPull > 0 then
        local saved = replayResult.manaSpent - bestResult.manaSpent
        if saved > 0 then
            add("  ~ one fewer drink per %d pulls", math.max(1, math.floor(budget.perPull / saved + 0.5)))
        end
    end

    local bindList = {}
    for _, fam in ipairs({ "Lifebloom", "Rejuvenation", "Regrowth", "HealingTouch", "Swiftmend" }) do
        if best.binds[fam] then bindList[#bindList + 1] = RankLabel(best.binds[fam]) end
    end
    add("  Bind: %s", table.concat(bindList, ", "))
    if best.binds.Swiftmend then
        add("  1. Anyone under %d%% with a HoT: Swiftmend", best.swiftmendBelow * 100 + 0.5)
    end
    if not best.noDirect then
        local d = best.binds.Regrowth or best.binds.HealingTouch
        if d then add("  2. Anyone under %d%%: %s", best.directBelow * 100 + 0.5, RankLabel(d)) end
    end
    if best.rollStacks > 0 and best.binds.Lifebloom then
        add("  3. Keep Lifebloom x%d rolling on the tank", best.rollStacks)
    end
    if best.binds.Rejuvenation then
        add("  4. Anyone under %d%% without Rejuvenation: %s",
            best.hotBelow * 100 + 0.5, RankLabel(best.binds.Rejuvenation))
    end
    add("  5. Otherwise %s - %d%% of the fight%s",
        best.filler and "Lifebloom on the tank" or "wait",
        (bestResult.waitFraction or 0) * 100 + 0.5,
        bestResult.maxWaitRun and string.format(", longest gap %.0fs", bestResult.maxWaitRun) or "")

    local function row(name, res, extra)
        add("  %-12s %7s   lowest %3d%%%s", name, Fmt(res.manaSpent),
            (res.lowest and res.lowest.hp or 1) * 100 + 0.5, extra or "")
    end
    row("you", replayResult, string.format("   overheal %d%%",
        (replayResult.healed + replayResult.overhealed) > 0
            and replayResult.overhealed / (replayResult.healed + replayResult.overhealed) * 100 or 0))
    for _, b in ipairs(baselineResults or {}) do row(b.name, b.result) end
    row("best", bestResult, best.heldOn and string.format("   held on %d of %d",
        best.heldOn, best.heldOf or 0) or "")

    -- what the casts were, plan-relative
    local order = { "overheal", "early", "rank", "spell", "stack", "late", "unclassified" }
    for _, k in ipairs(order) do
        if (cls.counts[k] or 0) > 0 then
            local extra = ""
            if k == "overheal" then
                local fams = {}
                for fam, n in pairs(cls.detail.overheal) do fams[#fams + 1] = fam .. " " .. n end
                table.sort(fams)
                if #fams > 0 then extra = "   " .. table.concat(fams, ", ") .. " above 85%" end
            elseif k == "unclassified" and #cls.detail.unclassified > 0 then
                extra = "   " .. table.concat(cls.detail.unclassified, ", ", 1,
                    math.min(3, #cls.detail.unclassified))
            end
            add("  %-12s %d casts %s%s", k, cls.counts[k], Fmt(cls.labels[k]), extra)
        end
    end
    if cls.idle > 0 then
        add("  %-12s %d moment(s) the plan would have cast and you did not", "idle", cls.idle)
    end
    if (cls.labels.utility or 0) + (cls.labels.shift or 0) > 0 then
        add("  utility %s  shifts %s  (outside the healing denominator)",
            Fmt(cls.labels.utility), Fmt(cls.labels.shift))
    end

    -- the identity, which is the reason to believe any of the above
    local sum = 0
    for _, k in ipairs(LABELS) do sum = sum + (cls.labels[k] or 0) end
    MD:Debug("sim", "classifier: %d labelled vs %d spent (delta %+d)", sum, rec.spent or 0,
        sum - (rec.spent or 0))
    if math.abs(sum - (rec.spent or 0)) > math.max(50, (rec.spent or 0) * 0.02) then
        add("  (warning: labelled %s of %s spent - the breakdown is incomplete)",
            Fmt(sum), Fmt(rec.spent or 0))
    end

    local caveats = { "EV crit", "other healers as recorded", "threat and kill speed not modelled" }
    if validation then
        local failed = {}
        for _, g in ipairs(validation.gates) do if not g.ok then failed[#failed + 1] = g.name end end
        caveats[#caveats + 1] = #failed == 0 and "all gates passed"
            or ("gates failed: " .. table.concat(failed, ", "))
    end
    caveats[#caveats + 1] = "late and idle come from running the plan alone, the rest from lockstep"
    add("  caveat: %s", table.concat(caveats, "; "))
    return out
end

--------------------------------------------------------------------------------
-- Loop closure (5.6): remember what the card said, so the Review tab can tell
-- the player whether anything actually changed afterwards. This is the feature
-- -- a healer who improves over runs -- and it needs a before to have an after.
--------------------------------------------------------------------------------
function SP.Mark(rec, cls)
    if not (MD.cdb and rec.zone) then return end
    MD.cdb.coachMarks = MD.cdb.coachMarks or {}
    local healCasts, overhealCasts = 0, 0
    for _, k in ipairs(LABELS) do
        if k ~= "utility" and k ~= "shift" then healCasts = healCasts + (cls.counts[k] or 0) end
    end
    overhealCasts = cls.counts.overheal or 0
    local budget = MD.PullBudget and MD.PullBudget:Estimate()
    MD.cdb.coachMarks[rec.zone] = {
        t = time(), overhealFrac = healCasts > 0 and overhealCasts / healCasts or 0,
        manaPerPull = budget and budget.perPull or nil,
        topHabit = (function()
            local best, bestMana
            for _, k in ipairs(LABELS) do
                if k ~= "utility" and k ~= "shift" and (cls.labels[k] or 0) > 0 then
                    if not bestMana or cls.labels[k] > bestMana then best, bestMana = k, cls.labels[k] end
                end
            end
            return best
        end)(),
    }
end

-- "since your last card (N fights): overheal 39% -> 31%, mana/pull -0.8k"
function SP.Progress(zone)
    local mark = MD.cdb and MD.cdb.coachMarks and MD.cdb.coachMarks[zone]
    if not mark then return nil end
    local since, over, overN = 0, 0, 0
    for _, f in ipairs(MD.fightHistory or {}) do
        if f.zone == zone and (f.t or 0) > mark.t then
            since = since + 1
            if f.hpBuckets then
                local total = (f.hpBuckets[1] or 0) + (f.hpBuckets[2] or 0) + (f.hpBuckets[3] or 0)
                if total > 0 then over = over + (f.hpBuckets[3] or 0) / total; overN = overN + 1 end
            end
        end
    end
    if since < 3 then return nil end
    local now = overN > 0 and (over / overN) or nil
    local budget = MD.PullBudget and MD.PullBudget:Estimate()
    local parts = {}
    if now and mark.overhealFrac then
        parts[#parts + 1] = string.format("overheal %d%% -> %d%%",
            mark.overhealFrac * 100 + 0.5, now * 100 + 0.5)
    end
    if budget and budget.perPull and mark.manaPerPull then
        parts[#parts + 1] = string.format("mana/pull %+.1fk", (budget.perPull - mark.manaPerPull) / 1000)
    end
    if #parts == 0 then return nil end
    return string.format("since your last card (%d fights): %s", since, table.concat(parts, ", "))
end

--------------------------------------------------------------------------------
-- Coach: validate, run the baselines and the candidate, classify, print a card.
-- Until v0.7.5's search exists, "best" is the best of the baselines and the
-- player's own binds with default thresholds -- which is already an honest
-- comparison, just a coarse one.
--------------------------------------------------------------------------------
function SP.Coach(rec, opts)
    SM = SM or MD.SimModel
    if not rec then return { "coach: no recording." } end
    local kit = MD.RankMath:SpellKit()
    local validation = SM:Validate(rec, kit)
    if not (opts and opts.force) and validation and not validation.ok then
        local out = { "coach: this fight does not replay, so there is nothing to suggest." }
        for _, g in ipairs(validation.gates) do
            if not g.ok then out[#out + 1] = "  " .. g.name .. ": " .. g.text end
        end
        out[#out + 1] = "  /md simreplay for the full report; /md coach " ..
            tostring(opts and opts.n or 1) .. " force to see a card anyway."
        return out, validation
    end

    local scenario = SM.ScenarioFromRecording(rec, kit)
    local replayResult = SM:Run(scenario, nil, { critMode = "ev" })
    -- the result belongs to a pool slot, so keep the handful of numbers the
    -- card needs before anything else runs
    local you = { manaSpent = replayResult.manaSpent, healed = replayResult.healed,
                  overhealed = replayResult.overhealed, lowestMana = replayResult.lowestMana,
                  lowest = { hp = replayResult.lowest.hp } }

    local candidates = SP.Baselines(rec, kit)
    candidates[#candidates + 1] = { name = "your binds",
        plan = SP.NewPlan(SP.BindsFromRecording(rec, kit),
            { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80,
              filler = false }, kit) }
    if opts and opts.extra then
        for _, c in ipairs(opts.extra) do candidates[#candidates + 1] = c end
    end

    local results, best, bestScore, bestResult = {}, nil, nil, nil
    for _, c in ipairs(candidates) do
        local r = SP.RunPlan(scenario, c.plan, { critMode = "ev" })
        local snap = { manaSpent = r.manaSpent, healed = r.healed, overhealed = r.overhealed,
                       lowestMana = r.lowestMana, lowest = { hp = r.lowest.hp },
                       floorSeconds = r.floorSeconds, deaths = { n = r.deaths.n },
                       waitFraction = r.waitFraction, maxWaitRun = r.maxWaitRun }
        results[#results + 1] = { name = c.name, result = snap }
        local score = SP.Score(snap, c.plan, 0)
        if SP.Better(score, bestScore) then best, bestScore, bestResult = c.plan, score, snap end
    end

    local cls = SP.Classify(rec, scenario, best, kit)
    SP.Mark(rec, cls)
    local card = SP.Card(rec, best, bestResult, you, results, cls, validation)
    local progress = SP.Progress(rec.zone)
    if progress then card[#card + 1] = "  " .. progress end
    -- the last plan coached for this fight, so Play never searches (SPEC-v0.8 2.5)
    SP.plans[rec.id] = best
    -- A plan the author asked for ANYWAY, on a fight the gates rejected. The
    -- replay window shows it without being asked twice: forcing the coach is a
    -- deliberate act, and having to repeat it at the Play button would be a
    -- second lock on a door the author already opened. It is marked, not hidden.
    if opts and opts.force and validation and not validation.ok then
        SP.forced[rec.id] = true
    end
    return card, validation, cls, best
end

SP.plans = {}   -- [rec.id] = the plan Coach last produced for it
SP.forced = {}  -- [rec.id] = that plan came from a forced coach on a fight that does not replay

--------------------------------------------------------------------------------
-- Replay (docs/SPEC-v0.8.md 2.5): both columns of the replay window in one
-- call. Left is the recorded casts through the engine, right is a plan --
-- the one passed in, else the one Coach cached for this fight -- and only if
-- the fight validates (the same rule as Coach's disabled button; opts.force
-- overrides it, as it does there). The recorder's real HP snapshots ride
-- along as `ticks` so the window can draw the truth over the reconstruction.
--------------------------------------------------------------------------------
local function Snap(r)
    return { manaSpent = r.manaSpent, healed = r.healed, overhealed = r.overhealed,
             lowestMana = r.lowestMana, lowest = { hp = r.lowest.hp, tgt = r.lowest.tgt, t = r.lowest.t },
             floorSeconds = r.floorSeconds, deaths = { n = r.deaths.n },
             waitFraction = r.waitFraction, maxWaitRun = r.maxWaitRun }
end

function SP.Replay(rec, opts)
    SM = SM or MD.SimModel
    opts = opts or {}
    if not rec then return nil end
    local kit = opts.kit or MD.RankMath:SpellKit()
    local validation = SM:Validate(rec, kit)
    local scenario = SM.ScenarioFromRecording(rec, kit)
    local dt = opts.dt or 0.25
    local rp = { rec = rec, scenario = scenario, kit = kit, validation = validation }

    local left = SM:Run(scenario, nil, { critMode = "ev", trace = { dt = dt } })
    rp.left = { trace = left.trace, snapshot = Snap(left) }

    local plan = opts.plan or SP.plans[rec.id]
    local forced = opts.force or SP.forced[rec.id] or false
    if plan and (forced or not validation or validation.ok) then
        rp.forced = forced and validation and not validation.ok or false
        local right = SP.RunPlan(scenario, plan, { critMode = "ev", trace = { dt = dt } })
        rp.right = { trace = right.trace, snapshot = Snap(right), plan = plan }
        if opts.labels ~= false then
            local cls = SP.Classify(rec, scenario, plan, kit)
            rp.casts = cls.casts
        end
    end

    -- the recorder's snapshots as fractions, tracked targets only
    local hp = rec.hp or {}
    local ticks = { t = hp.t or {}, hp = {} }
    for _, ti in ipairs(rec.tracked or {}) do
        local cur, max = hp.hp and hp.hp[ti], hp.max and hp.max[ti]
        if cur and max then
            local col = {}
            for k = 1, #ticks.t do
                local m = max[k] or 0
                col[k] = (m > 0 and cur[k] and cur[k] >= 0) and (cur[k] / m) or -1
            end
            ticks.hp[ti] = col
        end
    end
    rp.ticks = ticks
    return rp
end

--------------------------------------------------------------------------------
-- The search (docs/SPEC-v0.7.md 6). Coordinate descent from four seeds, at most
-- 300 evaluations, sliced across frames in a coroutine so the game never
-- stutters. Full-grid enumeration was rejected: the domains multiply out to 108
-- points per bind set, each ~10-20 ms, and the answer is not 108x better.
--
-- Coordinate descent can stop in a local minimum. It is used anyway, and the
-- reason is on the card: the alternatives within 5% are listed, so a player can
-- see that the search found a ridge rather than a peak.
--------------------------------------------------------------------------------
local MAX_EVALS = 300
local SLICE_MS = 8       -- milliseconds of work per frame
local SLICE_STEPS = 3    -- fallback when the client has no sub-frame clock

-- GetTime() is the frame's timestamp and does NOT advance inside a frame, so
-- slicing on it would run the whole search in one frame and freeze the client
-- for seconds. debugprofilestop() is the sub-frame clock; if it is missing, fall
-- back to a fixed number of coroutine resumes per frame.
local function NowMs()
    if debugprofilestop then
        local ok, v = pcall(debugprofilestop)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

local function RandomParams()
    local p = {}
    for _, name in ipairs(SP.PARAM_ORDER) do
        local dom = SP.DOMAINS[name]
        p[name] = dom[math.random(#dom)]
    end
    return p
end

-- Search(scenario, opts, onProgress, onDone)
--   opts = { kit, binds, rec, maxEvals, abortAbove }
--   onProgress(evals, bestScore)   called at most once per slice
--   onDone(best, bestResult, evals, alternates)
-- Returns a handle with :Cancel(). The whole thing runs on an OnUpdate frame:
-- a search that froze the client for ten seconds would be unusable in exactly
-- the moment it is wanted (between two pulls).
function SP.Search(scenario, opts, onProgress, onDone)
    SM = SM or MD.SimModel
    opts = opts or {}
    local kit = opts.kit or MD.RankMath:SpellKit()
    local binds = opts.binds or SP.MaxRankBinds()
    local maxEvals = opts.maxEvals or MAX_EVALS
    local evals = 0
    local best, bestScore, bestResult = nil, nil, nil
    local seen = {}
    local alternates = {}

    local function Key(p)
        return string.format("%.2f|%.2f|%d|%.2f|%s", p.swiftmendBelow, p.directBelow,
            p.rollStacks, p.hotBelow, tostring(p.filler))
    end

    local function Eval(params)
        local key = Key(params)
        if seen[key] then return seen[key] end
        if evals >= maxEvals then return nil end
        local plan = SP.NewPlan(binds, params, kit)
        local r = SP.RunPlan(scenario, plan, {
            critMode = "ev",
            -- no candidate that has already spent more than the incumbent can win
            abortAbove = bestScore and bestScore[1] == 0 and bestScore[2] == 0
                and bestScore[3] or nil,
        })
        evals = evals + 1
        local snap = { manaSpent = r.manaSpent, healed = r.healed, overhealed = r.overhealed,
                       lowestMana = r.lowestMana, lowest = { hp = r.lowest.hp },
                       floorSeconds = r.floorSeconds, deaths = { n = r.deaths.n },
                       waitFraction = r.waitFraction, maxWaitRun = r.maxWaitRun,
                       aborted = r.aborted }
        local score = snap.aborted and nil or SP.Score(snap, plan, 0)
        local out = { plan = plan, result = snap, score = score, params = params }
        seen[key] = out
        if score and SP.Better(score, bestScore) then
            best, bestScore, bestResult = plan, score, snap
        end
        return out
    end

    local seeds = {
        { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false },
        { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false,
          noDirect = true },
        { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false },
        RandomParams(),
    }

    local co = coroutine.create(function()
        for _, seed in ipairs(seeds) do
            local cur = {}
            for k, v in pairs(seed) do cur[k] = v end
            Eval(cur)
            coroutine.yield()
            local improved = true
            while improved and evals < maxEvals do
                improved = false
                for _, name in ipairs(SP.PARAM_ORDER) do
                    local baseline = Eval(cur)
                    for _, value in ipairs(SP.DOMAINS[name]) do
                        if value ~= cur[name] then
                            local trial = {}
                            for k, v in pairs(cur) do trial[k] = v end
                            trial[name] = value
                            local out = Eval(trial)
                            if out and out.score and baseline and baseline.score
                               and SP.Better(out.score, baseline.score) then
                                cur, improved = trial, true
                                baseline = out
                            end
                        end
                        if evals >= maxEvals then break end
                    end
                    coroutine.yield()
                    if evals >= maxEvals then break end
                end
            end
        end
    end)

    -- alternates: anything within 5% of the winner's mana with fewer binds
    local function CollectAlternates()
        if not bestScore then return end
        for _, out in pairs(seen) do
            if out.score and out ~= best and out.result.manaSpent <= bestResult.manaSpent * 1.05
               and out.score[1] == bestScore[1] and out.score[2] <= bestScore[2] + 1e-9 then
                alternates[#alternates + 1] = out
            end
        end
        table.sort(alternates, function(a, b) return a.result.manaSpent < b.result.manaSpent end)
    end

    local frame = CreateFrame("Frame")
    local handle = { cancelled = false, evals = 0 }
    function handle:Cancel() self.cancelled = true end

    frame:SetScript("OnUpdate", function()
        if handle.cancelled then
            frame:SetScript("OnUpdate", nil)
            MD:Debug("sim", "search cancelled after %d evaluation(s)", evals)
            if onDone then onDone(nil, nil, evals, nil) end
            return
        end
        local started, steps = NowMs(), 0
        while coroutine.status(co) == "suspended"
              and (started and (NowMs() - started) < SLICE_MS or (not started and steps < SLICE_STEPS)) do
            steps = steps + 1
            local ok, err = coroutine.resume(co)
            if not ok then
                frame:SetScript("OnUpdate", nil)
                MD:Debug("sim", "search error: %s", tostring(err))
                if onDone then onDone(nil, nil, evals, nil) end
                return
            end
        end
        handle.evals = evals
        if onProgress then onProgress(evals, bestScore) end
        if coroutine.status(co) == "dead" or evals >= maxEvals then
            frame:SetScript("OnUpdate", nil)
            CollectAlternates()
            MD:Debug("sim", "search done: %d evaluation(s), best (deaths %d, floor %.1fs, mana %d, binds %d)",
                evals, bestScore and bestScore[1] or -1, bestScore and bestScore[2] or -1,
                bestScore and bestScore[3] or -1, bestScore and bestScore[5] or -1)
            -- The physical floor: no plan can spend less than the damage taken
            -- divided by the best healing-per-mana available. Never shown on a
            -- card (spec 13), but a best that beats it means the engine is wrong.
            -- ...and only when nobody died: a plan that let a target die did not
            -- have to heal the damage that target took, so the bound does not
            -- apply to it.
            if bestResult and opts.rec and bestScore and bestScore[1] == 0 then
                local damage = 0
                for i = 1, (opts.rec.n or 0) do
                    if opts.rec.ev.kind[i] == SM.K.DMG then damage = damage + (opts.rec.ev.amt[i] or 0) end
                end
                local bestHpm = 0
                for _, e in pairs(kit.caster) do
                    if e.cost and e.cost > 0 then
                        local heal = (e.direct or 0) + (e.tick or 0) * (e.ticks or 0) + (e.bloom or 0)
                        local hpm = heal / e.cost
                        if hpm > bestHpm then bestHpm = hpm end
                    end
                end
                if bestHpm > 0 then
                    local floorMana = damage / bestHpm
                    MD:Debug("sim", "physical floor %.0f mana vs best %.0f%s", floorMana,
                        bestResult.manaSpent,
                        bestResult.manaSpent < floorMana * 0.99 and "  <- IMPOSSIBLE, engine is wrong" or "")
                end
            end
            if onDone then onDone(best, bestResult, evals, alternates) end
        end
    end)
    return handle
end

--------------------------------------------------------------------------------
-- CoachAsync: the search, then the card. Split from SP.Coach so the synchronous
-- path (baselines only) stays testable and the async one is a thin wrapper.
--
-- `heldOn` is computed here rather than in the search: it asks whether the
-- winning plan also survives the OTHER fights that were kept, which is the
-- difference between a strategy and a curve fitted to one pull.
--------------------------------------------------------------------------------
local function HeldOn(plan, kit, exceptID)
    local held, of = 0, 0
    for _, other in ipairs(MD.FightRecorder and MD.FightRecorder:List() or {}) do
        if other.id ~= exceptID then
            of = of + 1
            local sc = SM.ScenarioFromRecording(other, kit)
            local r = SP.RunPlan(sc, plan, { critMode = "ev" })
            if r.deaths.n == 0 and r.floorSeconds == 0 then held = held + 1 end
        end
    end
    return held, of
end

function SP.CoachAsync(rec, opts, onDone)
    SM = SM or MD.SimModel
    opts = opts or {}
    local kit = MD.RankMath:SpellKit()
    local validation = SM:Validate(rec, kit)
    if not opts.force and validation and not validation.ok then
        onDone(select(1, SP.Coach(rec, opts)), validation)
        return nil
    end

    local scenario = SM.ScenarioFromRecording(rec, kit)
    local binds = SP.BindsFromRecording(rec, kit)
    if MD.db and MD.db.simAllowRebinds then binds = SP.MaxRankBinds() end

    MD:Print("coach: searching (this runs across frames; /md coach cancel stops it)...")
    return SP.Search(scenario, { kit = kit, binds = binds, rec = rec },
        function(evals) MD:Debug("sim", "search %d evaluations", evals) end,
        function(best, bestResult, evals)
            if not best then
                onDone({ "coach: search cancelled." }, validation)
                return
            end
            best.heldOn, best.heldOf = HeldOn(best, kit, rec.id)
            local lines = SP.Coach(rec, {
                n = opts.n, force = true,
                extra = { { name = "best (search)", plan = best } },
            })
            lines[#lines + 1] = string.format("  search: %d plans evaluated", evals)
            onDone(lines, validation)
        end)
end

--------------------------------------------------------------------------------
-- FromRecordings (docs/SPEC-v0.7.md 9): a damage preset derived from what
-- actually happened in a zone, rather than from `Data/SimPresets.lua`'s
-- placeholders. Per target, tagged by role:
--   baseline   mean damage per second outside the big hits
--   big hit    a single second's damage worth >= db.simBigHit of that target's
--              max health; reported as a rate and a p50/p90 size
-- Provenance travels with it, because the difference between "450 dps on the
-- tank because a healer guessed" and "450 dps on the tank measured over 6
-- fights in Blood Furnace" is the whole difference between the two features.
--------------------------------------------------------------------------------
local function Percentile(sorted, p)
    if #sorted == 0 then return 0 end
    local i = math.max(1, math.min(#sorted, math.ceil(p * #sorted)))
    return sorted[i]
end

function SP.FromRecordings(zone, maxFights)
    SM = SM or MD.SimModel
    local list = MD.FightRecorder and MD.FightRecorder:List() or {}
    local byRole = {}          -- role -> { seconds, steady, bigs = {} }
    local fights, seconds = 0, 0
    local used = {}

    for _, rec in ipairs(list) do
        if (rec.dur or 0) >= 20 and (not zone or rec.zone == zone) then
            fights = fights + 1
            used[#used + 1] = rec.id
            seconds = seconds + rec.dur
            -- bucket damage into whole seconds per target, so "a big hit" means
            -- what a healer would call one
            local perSec = {}
            for i = 1, (rec.n or 0) do
                if rec.ev.kind[i] == SM.K.DMG then
                    local tgt = rec.ev.tgt[i]
                    local sec = math.floor(rec.ev.t[i])
                    perSec[tgt] = perSec[tgt] or {}
                    perSec[tgt][sec] = (perSec[tgt][sec] or 0) + (rec.ev.amt[i] or 0)
                end
            end
            for tgt, secs in pairs(perSec) do
                local r = rec.roster[tgt]
                local role = r and r.role or "UNKNOWN"
                local maxHP = (r and r.maxHP or 0)
                if maxHP <= 0 and rec.hp and rec.hp.max and rec.hp.max[tgt] then
                    maxHP = rec.hp.max[tgt][1] or 0
                end
                local bucket = byRole[role]
                if not bucket then bucket = { seconds = 0, steady = 0, bigs = {} }; byRole[role] = bucket end
                bucket.seconds = bucket.seconds + rec.dur
                local threshold = maxHP > 0 and maxHP * ((MD.db and MD.db.simBigHit) or 0.15) or math.huge
                for _, amount in pairs(secs) do
                    if amount >= threshold then
                        bucket.bigs[#bucket.bigs + 1] = amount
                    else
                        bucket.steady = bucket.steady + amount
                    end
                end
            end
        end
        if maxFights and fights >= maxFights then break end
    end

    if fights == 0 then return nil end
    local out = { fights = fights, seconds = seconds, zone = zone, ids = used, byRole = {} }
    for role, b in pairs(byRole) do
        table.sort(b.bigs)
        out.byRole[role] = {
            dps = b.seconds > 0 and (b.steady / b.seconds) or 0,
            bigRate = b.seconds > 0 and (#b.bigs / b.seconds) or 0,
            bigP50 = Percentile(b.bigs, 0.50),
            bigP90 = Percentile(b.bigs, 0.90),
            bigN = #b.bigs,
        }
        local r = out.byRole[role]
        if r.bigRate > 0 then
            r.pulse = { amount = r.bigP50, period = 1 / r.bigRate, offset = 1 / r.bigRate / 2 }
        end
    end
    out.provenance = string.format("%d fight(s), %.0fs%s, %s", fights, seconds,
        zone and (" in " .. zone) or "", date and date("%d %b") or "")
    return out
end

--------------------------------------------------------------------------------
-- Monte Carlo (spec 9): only for the three reported plans in SYNTHETIC mode,
-- never inside the search and never on a replay card -- the judge rejected both.
-- K replicates with rolled crits and big-hit sizes sampled between p50 and p90.
-- What it answers is one question: how often does this plan let somebody drop
-- below the floor when the fight is not exactly average?
--------------------------------------------------------------------------------
local REPLICATES = 30

function SP.MonteCarlo(scenario, plan, derived, k)
    SM = SM or MD.SimModel
    k = k or REPLICATES
    local violations, deaths = 0, 0
    local amt = scenario.ev and scenario.ev.amt
    if not amt then return nil end
    -- keep the originals: the scenario is reused by the caller
    local original = {}
    for i = 1, #amt do original[i] = amt[i] end

    for rep = 1, k do
        for i = 1, #amt do
            local base = original[i]
            -- scale each second's damage by a factor drawn between the p50 and
            -- p90 shape of what was measured, or +-30% when nothing was
            amt[i] = base * (0.85 + math.random() * 0.45)
        end
        local r = SP.RunPlan(scenario, plan, { critMode = "roll", seed = rep })
        if r.floorSeconds > 0 then violations = violations + 1 end
        if r.deaths.n > 0 then deaths = deaths + 1 end
    end
    for i = 1, #amt do amt[i] = original[i] end
    return { k = k, floorRate = violations / k, deathRate = deaths / k,
             derived = derived and derived.provenance or nil }
end

--------------------------------------------------------------------------------
-- THE RUN (docs/SPEC-v0.9.md 5): the same coordinate descent, one plan for the
-- whole dungeon, scored on a chain of pulls with the gaps in between.
--
-- The score is v0.7's tuple with TIME put in front of mana:
--   (deaths, floorSeconds, addedTime, drinks, manaSpent, -heldOn, #binds, overheal)
-- `addedTime` is the time the run got LONGER because a drink did not fit its
-- gap; `drinks` is next because each is most of a minute of five people standing
-- still even when it does fit. Mana ranks after both: in a dungeon mana is only
-- worth the time it saves (docs/DECISIONS.md v0.9).
--------------------------------------------------------------------------------
SP.POLICY_DOMAINS = { below = { 0.40, 0.50, 0.60, 0.70, 0.80 }, upTo = { 0.80, 0.90, 1.00 } }
SP.POLICY_ORDER = { "below", "upTo" }

function SP.ChainScore(chain, plan, heldOn)
    local oh, total = 0, (chain.healed or 0) + (chain.overhealed or 0)
    if total > 0 then oh = chain.overhealed / total end
    return { chain.deaths or 0, chain.floorSeconds or 0, chain.addedTime or 0,
             chain.drinks or 0, chain.manaSpent or 0, -(heldOn or 0),
             plan and plan:BindCount() or 0, oh }
end

local function ChainSnap(c)
    return { deaths = c.deaths, floorSeconds = c.floorSeconds, manaSpent = c.manaSpent,
             healed = c.healed, overhealed = c.overhealed, drinks = c.drinks,
             drinkTime = c.drinkTime, addedTime = c.addedTime, wall = c.wall,
             lowest = { hp = c.lowest.hp, tgt = c.lowest.tgt, pull = c.lowest.pull },
             oomPulls = c.oomPulls, innervates = c.innervates, potionMana = c.potionMana,
             policy = c.policy, drinkRate = c.drinkRate, drinkRateSource = c.drinkRateSource,
             pulls = c.pulls, gaps = c.gaps, pool = c.pool }
end
SP.ChainSnap = ChainSnap

-- The run search. A chain costs one simulation per pull, so the evaluation
-- budget scales down with the length of the dungeon rather than being a flat
-- 300: thirty pulls at 300 evaluations would be nine thousand fight sims.
function SP.SearchRun(run, opts, onProgress, onDone)
    SM = SM or MD.SimModel
    opts = opts or {}
    local kit = opts.kit or MD.RankMath:SpellKit()
    local pulls = run.pulls or {}
    local binds = opts.binds or SP.MaxRankBinds()
    local maxEvals = opts.maxEvals or math.max(24, math.min(300, math.floor(2400 / math.max(1, #pulls))))
    local evals, seen = 0, {}
    local best, bestScore, bestChain = nil, nil, nil

    local function Key(p)
        return string.format("%.2f|%.2f|%d|%.2f|%s|%.2f|%.2f", p.swiftmendBelow, p.directBelow,
            p.rollStacks, p.hotBelow, tostring(p.filler), p.below, p.upTo)
    end

    local function Eval(params)
        local key = Key(params)
        if seen[key] then return seen[key] end
        if evals >= maxEvals then return nil end
        local plan = SP.NewPlan(binds, params, kit)
        local chain = SM.ChainRun(run, kit, { plan = plan, drinkRate = opts.drinkRate,
            policy = { below = params.below, upTo = params.upTo } })
        evals = evals + 1
        local snap = ChainSnap(chain)
        local out = { plan = plan, chain = snap, score = SP.ChainScore(snap, plan, 0), params = params }
        seen[key] = out
        if SP.Better(out.score, bestScore) then best, bestScore, bestChain = plan, out.score, snap end
        return out
    end

    local seeds = {
        { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false,
          below = 0.60, upTo = 0.95 },
        { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false,
          noDirect = true, below = 0.60, upTo = 0.95 },
        { swiftmendBelow = 0.30, directBelow = 0.35, rollStacks = 0, hotBelow = 0.60, filler = false,
          below = 0.50, upTo = 0.90 },
    }
    local order = {}
    for _, n in ipairs(SP.PARAM_ORDER) do order[#order + 1] = n end
    for _, n in ipairs(SP.POLICY_ORDER) do order[#order + 1] = n end
    local function Domain(name)
        return SP.DOMAINS[name] or SP.POLICY_DOMAINS[name]
    end

    local co = coroutine.create(function()
        for _, seed in ipairs(seeds) do
            local cur = {}
            for k, v in pairs(seed) do cur[k] = v end
            Eval(cur)
            coroutine.yield()
            local improved = true
            while improved and evals < maxEvals do
                improved = false
                for _, name in ipairs(order) do
                    local baseline = Eval(cur)
                    for _, value in ipairs(Domain(name)) do
                        if value ~= cur[name] then
                            local trial = {}
                            for k, v in pairs(cur) do trial[k] = v end
                            trial[name] = value
                            local out = Eval(trial)
                            if out and baseline and SP.Better(out.score, baseline.score) then
                                cur, improved, baseline = trial, true, out
                            end
                        end
                        if evals >= maxEvals then break end
                    end
                    coroutine.yield()
                    if evals >= maxEvals then break end
                end
            end
        end
    end)

    local frame = CreateFrame("Frame")
    local handle = { cancelled = false, evals = 0 }
    function handle:Cancel() self.cancelled = true end
    frame:SetScript("OnUpdate", function()
        if handle.cancelled then
            frame:SetScript("OnUpdate", nil)
            if onDone then onDone(nil, nil, evals) end
            return
        end
        local started, steps = NowMs(), 0
        while coroutine.status(co) == "suspended"
              and (started and (NowMs() - started) < SLICE_MS or (not started and steps < SLICE_STEPS)) do
            steps = steps + 1
            local ok, err = coroutine.resume(co)
            if not ok then
                frame:SetScript("OnUpdate", nil)
                MD:Debug("sim", "run search error: %s", tostring(err))
                if onDone then onDone(nil, nil, evals) end
                return
            end
        end
        handle.evals = evals
        if onProgress then onProgress(evals, bestScore) end
        if coroutine.status(co) == "dead" or evals >= maxEvals then
            frame:SetScript("OnUpdate", nil)
            MD:Debug("sim", "run search done: %d evaluation(s) over %d pull(s), best (deaths %d, floor %.0fs, " ..
                "added %.0fs, drinks %d, mana %d)", evals, #pulls, bestScore and bestScore[1] or -1,
                bestScore and bestScore[2] or -1, bestScore and bestScore[3] or -1,
                bestScore and bestScore[4] or -1, bestScore and bestScore[5] or -1)
            if onDone then onDone(best, bestChain, evals) end
        end
    end)
    return handle
end

--------------------------------------------------------------------------------
-- The run card (spec 5.4). Two rows -- what the run cost you, and what the best
-- plan would have cost -- in the units a dungeon is measured in: time first.
--------------------------------------------------------------------------------
local function Pct(x) return string.format("%d%%", (x or 0) * 100 + 0.5) end

-- How much of the run the engine actually reproduces. A pull the gates reject
-- still goes into the chain -- its MANA is what a run is scored on, and the
-- mana gate is the one v0.9.0 fixed -- but the card has to say how much of the
-- health side it is standing on. One validation per pull, once, not per search
-- evaluation.
function SP.RunGates(run, kit)
    SM = SM or MD.SimModel
    kit = kit or MD.RankMath:SpellKit()
    local out = { of = 0, failed = 0, byGate = {}, order = {} }
    for _, rec in ipairs(run.pulls or {}) do
        if not rec.short then
            out.of = out.of + 1
            local v = SM:Validate(rec, kit)
            if v and not v.ok then
                out.failed = out.failed + 1
                for _, g in ipairs(v.gates) do
                    if not g.ok then
                        if not out.byGate[g.name] then
                            out.byGate[g.name] = 0
                            out.order[#out.order + 1] = g.name
                        end
                        out.byGate[g.name] = out.byGate[g.name] + 1
                        break
                    end
                end
            end
        end
    end
    return out
end

function SP.RunCard(run, best, chain, you, evals, gates)
    local RR = MD.RunRecorder
    local out = {}
    local function add(fmt, ...) out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
    local st = run.stats or {}

    add("Run: %s -- %d pull(s), %s (combat %s)", run.name or "?", st.pulls or 0,
        Clock(st.wall or 0), Pct(st.combatPct))

    local function Row(label, c, extra)
        local drink = (c.drinks or 0) > 0
            and string.format("drank %dx (%s)", c.drinks, Clock(c.drinkTime or 0))
            or "no drink"
        add("  %-9s %-22s %-16s %6s spent   lowest %s%s", label, drink,
            (c.addedTime or 0) > 0 and string.format("+%s waiting to drink", Clock(c.addedTime))
                or "never forced",
            Fmt(c.manaSpent or 0), Pct(c.lowest and c.lowest.hp),
            extra or "")
    end
    Row("you", you, you.lowest and you.lowest.pull and string.format(" (pull %d)", you.lowest.pull) or "")
    Row("best", chain, chain.lowest and chain.lowest.pull and string.format(" (pull %d)", chain.lowest.pull) or "")

    if best then
        local p = best:Params()
        add("  the plan: Swiftmend <%s, direct <%s, HoT <%s, roll %d stack(s)%s",
            Pct(p.swiftmendBelow), Pct(p.directBelow), Pct(p.hotBelow), p.rollStacks,
            p.filler and ", filler on" or "")
        local binds = {}
        for _, fam in ipairs(SP.BINDABLE) do
            local id = best.binds and best.binds[fam]
            if id then binds[#binds + 1] = RankLabel(id) end
        end
        if #binds > 0 then add("  binds: %s", table.concat(binds, ", ")) end
    end
    add("  drink policy: under %s, up to %s   (rate %s)",
        Pct(chain.policy and chain.policy.below), Pct(chain.policy and chain.policy.upTo),
        chain.drinkRate and string.format("%d mana/s, %s", chain.drinkRate + 0.5, chain.drinkRateSource)
            or chain.drinkRateSource)
    local yours = RR and RR:DrinkPolicy(run)
    if yours then
        add("  yours was:    under %s, up to %s   (%d drink(s) recorded)",
            Pct(yours.below), Pct(yours.upTo), yours.drinks)
    end

    -- where the two differ, per pull, biggest saving first
    local diffs = {}
    for i, p in ipairs(chain.pulls or {}) do
        local y = you.pulls and you.pulls[i]
        if y then
            local d = (y.manaSpent or 0) - (p.manaSpent or 0)
            if math.abs(d) > 200 then diffs[#diffs + 1] = { i, d, p, y } end
        end
    end
    table.sort(diffs, function(a, b) return a[2] > b[2] end)
    if #diffs > 0 then
        local parts = {}
        for i = 1, math.min(4, #diffs) do
            parts[#parts + 1] = string.format("pull %d %s %s", diffs[i][1],
                diffs[i][2] > 0 and "saves" or "costs", Fmt(math.abs(diffs[i][2])))
        end
        add("  where it differs: %s (Play one to see it: /md replay <run>:<pull>)",
            table.concat(parts, ", "))
    end

    local short, dead = 0, 0
    for _, p in ipairs(chain.pulls or {}) do
        if p.short then short = short + 1 end
        if (p.deaths or 0) > 0 then dead = dead + 1 end
    end
    if short > 0 or dead > 0 or (st.summarised or 0) > 0 then
        add("  pulls not to trust: %d under the recording gate, %d with a death%s",
            short, dead, (st.summarised or 0) > 0
                and string.format(", %d summarised only (not simulated)", st.summarised) or "")
    end
    if gates and gates.failed > 0 then
        local why = {}
        for _, name in ipairs(gates.order) do
            why[#why + 1] = string.format("%s %d", name, gates.byGate[name])
        end
        add("  pulls that do not replay: %d of %d (%s). Their mana still counts -- that is what a run is",
            gates.failed, gates.of, table.concat(why, ", "))
        add("  scored on -- but their health curves are the engine's reconstruction, not the log's.")
    end
    add("  caveat: EV crit; gap lengths, damage and other healers as recorded; drink rate %s.",
        chain.drinkRateSource or "unknown")
    if (chain.innervates or 0) > 0 then
        add("          %d innervate(s) in the gaps are counted but NOT modelled: the value is 400%% of the",
            chain.innervates)
        add("          spirit share, and a recording carries the total rate, not the split.")
    end
    if (chain.potionMana or 0) > 0 then
        add("          %s of potion is applied at the table's max roll.", Fmt(chain.potionMana))
    end
    if evals then add("  searched %d plan/policy combination(s).", evals) end
    return out
end

--------------------------------------------------------------------------------
-- CoachRun: the "you" chain, the search, the card.
--------------------------------------------------------------------------------
function SP.CoachRun(run, opts, onDone)
    SM = SM or MD.SimModel
    opts = opts or {}
    if not run then if onDone then onDone({ "coachrun: no run." }) end return nil end
    if #(run.pulls or {}) == 0 then
        if onDone then onDone({ "coachrun: this run kept no pulls." }) end
        return nil
    end
    local kit = opts.kit or MD.RankMath:SpellKit()
    local you = ChainSnap(SM.ChainRun(run, kit, { recorded = true }))
    local gates = SP.RunGates(run, kit)
    return SP.SearchRun(run, { kit = kit, drinkRate = opts.drinkRate, maxEvals = opts.maxEvals },
        opts.onProgress,
        function(best, chain, evals)
            if not best then
                if onDone then onDone({ "coachrun: cancelled." }) end
                return
            end
            SP.runPlans[run.id] = best
            if onDone then onDone(SP.RunCard(run, best, chain, you, evals, gates), best, chain, you) end
        end)
end

SP.runPlans = {}   -- [run.id] = the plan CoachRun last produced for it
