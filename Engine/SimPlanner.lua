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
    for family in pairs(SD.families) do
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
    for family in pairs(SD.families) do binds[family] = SD.maxRank[family] end
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
            if has then return sm, i end
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
            if i then return direct, i end
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
            if stacks < self.rollStacks then return lb, i end
            -- at the target stack, refresh only as it is about to fall off
            if st and st.active and (st.expires - t) <= 1.5 then return lb, i end
        end
    end

    -- 4. Rejuvenation on anyone hurt who does not already have one.
    local rj = self.binds.Rejuvenation
    local rjE = affordable(rj)
    if rjE then
        local i = Neediest(self, S, t, self.hotBelow, true, HOT_INDEX.Rejuvenation)
        if i then return rj, i end
    end

    -- 5. Filler, or wait.
    if self.filler and lbE then
        local i = Anchor(self, S, t)
        local st = i and S.hots[i] and S.hots[i][HOT_INDEX.Lifebloom]
        if i and not (st and st.active) then return lb, i end
    end
    return nil
end

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

    return { labels = labels, counts = counts, detail = detail, idle = idle,
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
    return card, validation, cls, best
end
