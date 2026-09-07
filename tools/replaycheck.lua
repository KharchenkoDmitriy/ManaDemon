-- tools/run.sh tools/replaycheck.lua
--
-- The replay's trace and state machine (docs/SPEC-v0.8.md 2.6), offline. Runs
-- the shared scripted pull, replays it through SP.Replay with a max-rank plan
-- for the right column, and asserts:
--   * the trace's shape and the sampling rule (post-cast mana on the grid);
--   * every recorded own cast is in the left trace, in order, at its time;
--   * the right column carries reasons; the left carries none;
--   * seek(t) == step-to(t) for every accessor, at ten times;
--   * onEvent fires once per event when stepping and never on a seek;
--   * a run without opts.trace allocates no trace.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB

local ids = dofile(here .. "/fakepull.lua")(MD, S)
local SM, SP, RT = MD.SimModel, MD.SimPlanner, MD.ReplayTrace
local K, TK = SM.K, SM.TK

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-38s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local rec = MD.FightRecorder:Get(1)
assert(rec, "no recording")
local kit = MD.RankMath:SpellKit()
local plan = SP.NewPlan(SP.MaxRankBinds(),
    { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false }, kit)

local rp = SP.Replay(rec, { plan = plan, force = true, dt = 0.25 })
check("replay built", rp ~= nil and rp.left ~= nil and rp.left.trace ~= nil)
local L = rp.left.trace

--------------------------------------------------------------------------------
-- 1. shape
--------------------------------------------------------------------------------
local expectN = math.floor(rec.dur / 0.25 + 1e-9) + 1
check("grid length", L.n == expectN, string.format("%d vs %d (dur %.2f)", L.n, expectN, rec.dur))
check("mana/form arrays full", #L.mana == L.n and #L.form == L.n, string.format("%d / %d", #L.mana, #L.form))
local hpFull = true
for _, ti in ipairs(rec.tracked) do
    if not L.hp[ti] or #L.hp[ti] ~= L.n then hpFull = false end
end
check("hp arrays full for tracked", hpFull)
local kindsOk = true
for i = 1, L.nEv do if L.ev.kind[i] < 1 or L.ev.kind[i] > 8 then kindsOk = false end end
check("no damage kind in the trace", kindsOk and L.nEv > 0, tostring(L.nEv))

--------------------------------------------------------------------------------
-- 2. every recorded own cast is a CAST trace event, in order, at its time
--------------------------------------------------------------------------------
local recCasts = {}
for i = 1, rec.n do
    if rec.ev.kind[i] == K.OWNCAST then recCasts[#recCasts + 1] = { rec.ev.t[i], rec.ev.x[i], rec.ev.tgt[i] } end
end
local traceCasts = {}
for i = 1, L.nEv do
    if L.ev.kind[i] == TK.CAST then traceCasts[#traceCasts + 1] = { L.ev.t[i], L.ev.a[i], L.ev.tgt[i], L.ev.why[i], i } end
end
local same = #recCasts == #traceCasts
for n = 1, math.min(#recCasts, #traceCasts) do
    local r, tr = recCasts[n], traceCasts[n]
    if math.abs(r[1] - tr[1]) > 0.01 or r[2] ~= tr[2] or r[3] ~= tr[3] then same = false end
end
check("own casts in the left trace", same, string.format("%d recorded, %d traced", #recCasts, #traceCasts))
local noWhy = true
for _, c in ipairs(traceCasts) do if c[4] ~= 0 then noWhy = false end end
check("left casts carry no reason", noWhy)

--------------------------------------------------------------------------------
-- 3. the sampling rule: a cast ON a grid point shows post-cast mana there
--------------------------------------------------------------------------------
local ruleOk, ruleDetail = false, "no cast on a grid point"
for _, c in ipairs(traceCasts) do
    local t, i = c[1], c[5]
    local k = math.floor(t / 0.25 + 1e-6) + 1
    local onGrid = math.abs((k - 1) * 0.25 - t) < 1e-6
    local cost = L.ev.b[i]
    if onGrid and k > 1 and cost > 0 then
        -- at most one grid step of regen (< 20 mana here) can hide the drop
        ruleOk = L.mana[k] <= L.mana[k - 1] - cost + 20
        ruleDetail = string.format("t %.2f k %d: %d -> %d (cost %d)", t, k, L.mana[k - 1], L.mana[k], cost)
        break
    end
end
check("post-cast mana on the grid", ruleOk, ruleDetail)

--------------------------------------------------------------------------------
-- 4. death and pre-pull HoT
--------------------------------------------------------------------------------
local deathI
for i = 1, L.nEv do if L.ev.kind[i] == TK.DEATH then deathI = i end end
check("death traced", deathI ~= nil)
if deathI then
    local ti = L.ev.tgt[deathI]
    local k = math.floor(L.ev.t[deathI] / 0.25 + 1e-6) + 2
    if k > L.n then k = L.n end
    check("hp is zero after the death", L.hp[ti] and L.hp[ti][k] == 0, tostring(L.hp[ti] and L.hp[ti][k]))
end
-- the stub has no UnitAura, so this recording carries no initial auras; the
-- BF-1 fixture does (a Lifebloom and a Regrowth rolling on the tank at the
-- pull), and they must reach the trace as HOT events at t = 0
do
    local fx = MD.SimFixtures.BF1
    local targets = {}
    for i, r in ipairs(fx.roster) do targets[i] = { name = r.name, maxHP = 10000, hp0 = 10000, tracked = true } end
    local sc = { dur = fx.dur, pool = fx.pool, initial = fx.initial, targets = targets, forms = fx.forms, kit = kit }
    local fr = SM:Run(sc, SM.ScriptPlan(fx.casts), { trace = { dt = 0.25 } })
    local lb, rg = false, false
    for i = 1, fr.trace.nEv do
        if fr.trace.ev.kind[i] == TK.HOT and fr.trace.ev.t[i] == 0 and fr.trace.ev.tgt[i] == 1 then
            if fr.trace.ev.a[i] == SM.HOT_INDEX.Lifebloom then lb = true end
            if fr.trace.ev.a[i] == SM.HOT_INDEX.Regrowth then rg = true end
        end
    end
    check("pre-pull HoTs traced at t=0 (fixture)", lb and rg)
    -- and a fresh state machine reports them without firing anything
    local fired = 0
    local st0 = RT.New(fr.trace, sc, { onEvent = function() fired = fired + 1 end })
    local h = st0:Hot(1, SM.HOT_INDEX.Lifebloom)
    check("t=0 HoT is initial state, not an event", h ~= nil and h.remaining > 0 and fired == 0,
        h and string.format("%.1fs left, %d fired", h.remaining, fired) or "no hot")
    -- form changes in the fixture reach the trace
    local forms = 0
    for i = 1, fr.trace.nEv do if fr.trace.ev.kind[i] == TK.FORM then forms = forms + 1 end end
    check("form changes traced (fixture)", forms == #fx.forms, string.format("%d vs %d", forms, #fx.forms))
end

--------------------------------------------------------------------------------
-- 5. the grid agrees with the gate's own sampler
--------------------------------------------------------------------------------
local r2 = SM:Run(rp.scenario, nil, { critMode = "ev", trace = { dt = 0.25 } })
local agree, agreeN = true, 0
for j, ts in ipairs(rp.scenario.hpSampleT or {}) do
    local k = math.floor(ts / 0.25 + 1e-6) + 1
    if math.abs((k - 1) * 0.25 - ts) < 1e-6 and k <= r2.trace.n then
        for _, ti in ipairs(rec.tracked) do
            local g = r2.trace.hp[ti][k]
            local c = r2.hpCurve[ti][j] / rp.scenario.targets[ti].maxHP
            if math.abs(g - c) > 1e-6 then agree = false end
            agreeN = agreeN + 1
        end
    end
end
check("grid == gate sampler at snapshots", agree and agreeN > 0, tostring(agreeN) .. " points")

--------------------------------------------------------------------------------
-- 6. the right column
--------------------------------------------------------------------------------
check("right column built", rp.right ~= nil and rp.right.trace ~= nil)
if rp.right then
    local R = rp.right.trace
    local fixedCasts = 0
    local rightCasts, whyOk, waits, waitsOk = 0, true, 0, true
    for i = 1, R.nEv do
        if R.ev.kind[i] == TK.CAST then
            rightCasts = rightCasts + 1
            -- 6 is not a rule: a cast of the healer's own that the plan had to
            -- work around rather than choose (v0.10.2)
            if R.ev.why[i] < 1 or R.ev.why[i] > 6 then whyOk = false end
            if R.ev.why[i] == SM.WHY_FIXED then fixedCasts = fixedCasts + 1 end
        elseif R.ev.kind[i] == TK.WAIT then
            waits = waits + 1
            if R.ev.a[i] <= 0 then waitsOk = false end
        end
    end
    check("right casts carry a rule", rightCasts > 0 and whyOk, tostring(rightCasts))
    -- the scripted pull casts Mark of the Wild: the plan does not choose it and
    -- may not skip it, so it is in the suggested column too, at its own time
    check("the plan pays for the casts it did not choose", fixedCasts > 0, tostring(fixedCasts))
    -- one decision chain, always: two of them counted every wait twice and put
    -- "waited 390% of the fight" on a card
    check("waiting never exceeds the fight", (rp.right.snapshot.waitFraction or 0) <= 1.0001,
        string.format("%.0f%%", (rp.right.snapshot.waitFraction or 0) * 100))
    check("the longest wait fits inside the fight",
        (rp.right.snapshot.maxWaitRun or 0) <= (rec.dur or 0) + 0.01,
        string.format("%.1fs of %.1fs", rp.right.snapshot.maxWaitRun or 0, rec.dur or 0))
    -- a fixed cast preempts a plan cast in flight, and a cancelled cast is free
    check("a preempted cast costs nothing", (function()
        local sc = SM.ScenarioFromRecording(rec, kit)
        local withFixed = SP.RunPlan(sc, plan, { critMode = "ev" }).manaSpent
        local saved = sc.fixed
        sc.fixed = nil
        local without = SP.RunPlan(sc, plan, { critMode = "ev" }).manaSpent
        sc.fixed = saved
        local fixedMana = 0
        for _, c in ipairs(saved or {}) do fixedMana = fixedMana + (c[3] or 0) end
        -- with the fixed casts the plan spends their mana on top, and never
        -- more than that: a cast it had to abandon is not paid for
        return withFixed <= without + fixedMana + 1
    end)())
    check("waits carry their length", waits > 0 and waitsOk, tostring(waits))
    local differ = rightCasts ~= #traceCasts
    if not differ then
        local li, ri = 0, 0
        for i = 1, R.nEv do
            if R.ev.kind[i] == TK.CAST then
                ri = ri + 1
                if traceCasts[ri] and (traceCasts[ri][2] ~= R.ev.a[i] or math.abs(traceCasts[ri][1] - R.ev.t[i]) > 0.01) then differ = true end
            end
        end
    end
    check("right casts differ from left", differ)
end
check("labels per cast", rp.casts ~= nil and #rp.casts == #recCasts, rp.casts and tostring(#rp.casts) or "nil")
if rp.casts then
    -- the labels are the v0.7.4 classifier's, unchanged; what v0.8 adds is
    -- that every cast now carries its own
    local seen, allLabelled = {}, true
    for _, c in ipairs(rp.casts) do
        if type(c.label) ~= "string" or not c.t or not c.spellID then allLabelled = false end
        seen[c.label] = true
    end
    check("every cast carries a label", allLabelled and seen.early, table.concat((function()
        local t = {}; for k in pairs(seen) do t[#t + 1] = k end; table.sort(t); return t end)(), ","))
end
local ticksOk = true
for _, ti in ipairs(rec.tracked) do
    local col = rp.ticks.hp[ti]
    if not col or #col ~= #rp.ticks.t then ticksOk = false
    else for _, v in ipairs(col) do if v ~= -1 and (v < 0 or v > 1) then ticksOk = false end end end
end
check("snapshot ticks as fractions", ticksOk and #rp.ticks.t > 0, tostring(#rp.ticks.t))

--------------------------------------------------------------------------------
-- 7. seek == step
--------------------------------------------------------------------------------
local function Snapshot(st)
    local s = { t = st.t, mana = st:Mana(), form = st:Form(), waiting = st:Waiting(),
                casting = st:Casting() and st:Casting().spellID or nil }
    s.spent, s.lowest, s.deaths, s.casts = st:Score()
    for ti = 1, L.nT do
        s["hp" .. ti] = st:Hp(ti)
        s["dead" .. ti] = st:Dead(ti)
        for fi = 1, 3 do
            local h = st:Hot(ti, fi)
            s["hot" .. ti .. "." .. fi] = h and string.format("%d/%.3f", h.stacks, h.remaining) or "-"
        end
    end
    return s
end
local function Same(a, b)
    for k, v in pairs(a) do
        local w = b[k]
        if type(v) == "number" and type(w) == "number" then
            if math.abs(v - w) > 1e-6 then return false, k .. ": " .. v .. " vs " .. w end
        elseif v ~= w then return false, k .. ": " .. tostring(v) .. " vs " .. tostring(w) end
    end
    for k in pairs(b) do if a[k] == nil then return false, k .. " missing" end end
    return true
end

local function SeekEqualsStep(trace, label)
    local allOk, detail = true, nil
    local times = {}
    for i = 1, 10 do times[i] = (i * 0.137 * trace.dur) % trace.dur end
    times[#times + 1] = trace.dur
    for _, t in ipairs(times) do
        local stepper = RT.New(trace, rp.scenario)
        while stepper.t < t - 1e-9 do stepper:Advance(math.min(0.1, t - stepper.t)) end
        local seeker = RT.New(trace, rp.scenario)
        seeker:Seek(t)
        local same, why = Same(Snapshot(stepper), Snapshot(seeker))
        if not same then allOk, detail = false, string.format("t %.2f %s", t, why); break end
    end
    check("seek == step (" .. label .. ")", allOk, detail)
end
SeekEqualsStep(L, "left")
if rp.right then SeekEqualsStep(rp.right.trace, "right") end

--------------------------------------------------------------------------------
-- 8. onEvent fires once per event stepping, never seeking
--------------------------------------------------------------------------------
-- events at t = 0 are initial state and never fire (the opening swing here)
local fired, dmgFired = 0, 0
local st = RT.New(L, rp.scenario, { onEvent = function(kind)
    if kind >= 100 then dmgFired = dmgFired + 1 else fired = fired + 1 end
end })
while not st:AtEnd() do st:Advance(0.25) end
local nEvAfter0 = 0
for i = 1, L.nEv do if L.ev.t[i] > 0 then nEvAfter0 = nEvAfter0 + 1 end end
check("onEvent once per trace event", fired == nEvAfter0, string.format("%d vs %d", fired, nEvAfter0))
local nDmg = 0
for i = 1, #rp.scenario.ev.t do
    local k = rp.scenario.ev.kind[i]
    if (k == K.DMG or k == K.FHEAL) and rp.scenario.ev.t[i] > 0 then nDmg = nDmg + 1 end
end
check("damage pulses from the scenario", dmgFired == nDmg, string.format("%d vs %d", dmgFired, nDmg))
fired, dmgFired = 0, 0
st:Seek(L.dur * 0.5)
check("seek fires nothing", fired == 0 and dmgFired == 0)

--------------------------------------------------------------------------------
-- 8b. auras reach the state machine from the scenario, and seek agrees
--------------------------------------------------------------------------------
do
    local tank, mage
    for i, r in ipairs(rec.roster) do
        if r.name == "Destroyka" then tank = i end
        if r.name == "Alkandari" then mage = i end
    end
    local sa = RT.New(L, rp.scenario)
    sa:Seek(5.0)
    local up = sa:Auras(tank)
    check("Shield Wall up at 5s", #up == 1 and up[1].spellID == 871 and up[1].buff, tostring(#up))
    sa:Seek(16.0)
    check("Shield Wall gone at 16s", #sa:Auras(tank) == 0, tostring(#sa:Auras(tank)))
    local d = sa:Auras(mage)
    check("debuff at 2 stacks at 16s", #d == 1 and d[1].stacks == 2 and not d[1].buff,
        d[1] and string.format("%d x%d", d[1].spellID, d[1].stacks) or "none")
    local sb = RT.New(L, rp.scenario)
    while sb.t < 16.0 - 1e-9 do sb:Advance(math.min(0.1, 16.0 - sb.t)) end
    local e = sb:Auras(mage)
    check("aura seek == step", #e == 1 and e[1].stacks == 2 and #sb:Auras(tank) == 0)
end

--------------------------------------------------------------------------------
-- 9b. v0.9.0: the measured mp5 the recording carries reaches the engine. The
-- recorder writes initial.energize at the pull (whatever the API omits for THIS
-- character, as measured then), the scenario passes it through, and the mana
-- curve has to move by exactly energize x t -- that is the whole reason the 87s
-- Hellfire fight missed its mana gate.
--------------------------------------------------------------------------------
do
    local saved, savedMana = rec.initial.energize, rec.initial.mana
    -- start well below the pool: at full mana the regen has nowhere to go and
    -- both curves would read the same for a reason that is not the model's
    rec.initial.mana = math.floor((rec.pool or 7009) * 0.4)
    rec.initial.energize = 0
    -- the run result lives in a pooled slot, so read the number out before the
    -- next run reuses it
    local dry = SM:Run(SM.ScenarioFromRecording(rec, kit), nil, { critMode = "ev" }).manaEnd
    rec.initial.energize = 5.0
    local wet = SM:Run(SM.ScenarioFromRecording(rec, kit), nil, { critMode = "ev" }).manaEnd
    rec.initial.energize, rec.initial.mana = saved, savedMana
    local expect = 5.0 * (rec.dur or 0)
    local got = wet - dry
    check("energize moves the mana curve", math.abs(got - expect) < 1.0,
        string.format("%.0f vs %.0f over %.1fs", got, expect, rec.dur or 0))
    check("the recording carries what was measured", saved ~= nil,
        saved and string.format("%.2f/s", saved) or "nil")
end

--------------------------------------------------------------------------------
-- 9c. v0.10.3: the deficit a plan leaves behind is priced, the danger line is
-- measured, and the HoT rule takes the one that fits.
--------------------------------------------------------------------------------
do
    -- the danger line comes from the fight's own biggest hit, not db.simFloor
    local sc2 = SM.ScenarioFromRecording(rec, kit)
    local tank, biggest = nil, 0
    for i = 1, (rec.n or 0) do
        if rec.ev.kind[i] == K.DMG and (rec.ev.amt[i] or 0) > biggest then
            biggest, tank = rec.ev.amt[i], rec.ev.tgt[i]
        end
    end
    local tg = sc2.targets[tank]
    check("the danger line is the biggest hit taken",
        tg and tg.danger and math.abs(tg.danger - biggest / tg.maxHP) < 1e-6,
        tg and string.format("%.3f vs %.3f", tg.danger or -1, biggest / (tg.maxHP or 1)) or "no target")
    check("a target nobody hit has no line of its own", (function()
        for i, t2 in ipairs(sc2.targets) do
            if i ~= tank and t2.danger == nil then return true end
        end
        return false
    end)())

    -- health left missing at the end is priced in mana, and nothing is earned
    -- above db.simFullHp
    local r2 = SM:Run(sc2, nil, { critMode = "ev" })
    check("the run reports the deficit it ends with", r2.endDeficit ~= nil and r2.endDeficit >= 0,
        tostring(r2.endDeficit))
    local hpm = SP.BestHPM(plan)
    check("the plan can price it", hpm and hpm > 0, tostring(hpm))
    local owed = SP.ManaOwed({ endDeficit = 1000 }, plan)
    check("owed mana is the deficit at the best rate the plan has",
        math.abs(owed - 1000 / hpm) < 1e-6, string.format("%.1f", owed))
    check("no deficit, nothing owed", SP.ManaOwed({ endDeficit = 0 }, plan) == 0)

    -- the score charges for it
    -- 674 mana and a 4000 deficit owes 4000/hpm on top, which is more than the
    -- 1100 a plan spent to end whole: the cheaper-looking plan loses
    local cheapButHurt = { deaths = { n = 0 }, floorSeconds = 0, manaSpent = 674, endDeficit = 4000,
                           healed = 1, overhealed = 0 }
    local dearerButWhole = { deaths = { n = 0 }, floorSeconds = 0, manaSpent = 1100, endDeficit = 0,
                             healed = 1, overhealed = 0 }
    check("a plan that leaves you hurt is charged for it",
        SP.Better(SP.Score(dearerButWhole, plan, 0), SP.Score(cheapButHurt, plan, 0)),
        string.format("674 + %.0f owed vs 1100 + 0", 4000 / hpm))
    -- and without the debt the same pair orders the other way, which is the
    -- behaviour this term exists to change
    local blind = { deaths = { n = 0 }, floorSeconds = 0, manaSpent = 674, endDeficit = 0,
                    healed = 1, overhealed = 0 }
    check("without a deficit the cheap plan still wins, as it should",
        SP.Better(SP.Score(blind, plan, 0), SP.Score(dearerButWhole, plan, 0)))
    -- Nothing is earned above db.simFullHp, so no plan is pushed into overheal
    -- to satisfy the term. A bare scenario, because the scripted pull lands a
    -- 5000 hit at t = 0 and would be measuring the damage, not the rule.
    local function quiet(frac)
        return { dur = 1, pool = 7000, initial = { mana = 7000 }, kit = kit, floor = 0.30,
                 targets = { { name = "T", maxHP = 10000, hp0 = 10000 * frac, tracked = true } } }
    end
    check("health above the full line is not a debt",
        (SM:Run(quiet(0.90), nil, { critMode = "ev" }).endDeficit or -1) == 0)
    check("health below it is, measured to the line and no further", (function()
        local d = SM:Run(quiet(0.50), nil, { critMode = "ev" }).endDeficit or -1
        return math.abs(d - (0.85 - 0.50) * 10000) < 1
    end)(), tostring(SM:Run(quiet(0.50), nil, { critMode = "ev" }).endDeficit))
end

--------------------------------------------------------------------------------
-- 9d. v0.10.3: what the casts a plan cannot choose cost the healer, measured as
-- the difference between two runs rather than estimated per cast.
--------------------------------------------------------------------------------
do
    local c = SM.CostOfCasts(rec, kit, { utility = true, shift = true, cc = true, damage = true })
    check("the cost of the non-healing casts is measured", c ~= nil and c.casts > 0,
        c and tostring(c.casts) or "nil")
    -- the scripted pull's Mark of the Wild costs 445
    check("their mana is their own recorded cost", c and math.abs(c.mana - 445) < 1,
        c and string.format("%.0f", c.mana) or "-")
    check("the regen they cost is never negative", c and c.regen >= 0, c and tostring(c.regen))
    check("without them the fight ends richer by cost plus regen",
        c and math.abs(c.total - (c.mana + c.regen)) < 1,
        c and string.format("%.0f vs %.0f + %.0f", c.total, c.mana, c.regen) or "-")
    check("asking about a kind the fight never cast returns nothing",
        SM.CostOfCasts(rec, kit, { nosuchkind = true }) == nil)
end

--------------------------------------------------------------------------------
-- 9e. v0.10.4: four strategies out of one pool of evaluations.
--------------------------------------------------------------------------------
do
    -- a hand-built pool: three plans with clearly different shapes
    local function snap(mana, floorS, area, endD, manaEnd)
        return { deaths = { n = 0 }, floorSeconds = floorS, manaSpent = mana, deficitArea = area,
                 endDeficit = endD, manaEnd = manaEnd, healed = 1, overhealed = 0,
                 lowest = { hp = 0.5 } }
    end
    local pool = {
        a = { plan = plan, result = snap(3000, 0.0, 2.0, 0, 4000), params = {} },  -- heals a lot
        b = { plan = plan, result = snap(700, 0.0, 30.0, 0, 6000), params = {} },  -- barely heals
        c = { plan = plan, result = snap(1500, 0.0, 9.0, 0, 5200), params = {} },
        -- cheapest of all, but six seconds one hit from death: no objective may
        -- take it, because every one of them ranks danger above its own axis
        risky = { plan = plan, result = snap(100, 6.0, 40.0, 0, 6900), params = {} },
        dead = { plan = plan, result = { deaths = { n = 1 }, floorSeconds = 0, manaSpent = 0,
                 deficitArea = 0, endDeficit = 0, manaEnd = 9000, healed = 1, overhealed = 0,
                 lowest = { hp = 0 } }, params = {} },
    }
    local w = SP.Winners(pool)
    check("every objective has a winner", w.safe and w.health and w.cheap and w.regen)
    check("no objective ever picks a plan that let somebody die", (function()
        for _, obj in ipairs(SP.OBJECTIVES) do
            if (w[obj.key].result.deaths.n or 0) > 0 then return false end
        end
        return true
    end)())
    check("safest takes the least time in danger", w.safe.result.floorSeconds == 0
        and w.safe.result.deficitArea == 2.0, tostring(w.safe.result.floorSeconds))
    check("no objective buys its axis with time in danger", (function()
        for _, obj in ipairs(SP.OBJECTIVES) do
            if (w[obj.key].result.floorSeconds or 0) > 0 then return false end
        end
        return true
    end)())
    check("highest health takes the smallest deficit", w.health.result.deficitArea == 2.0)
    check("least mana takes the cheapest", w.cheap.result.manaSpent == 700,
        tostring(w.cheap.result.manaSpent))
    check("most mana left takes the fullest pool", w.regen.result.manaEnd == 6000,
        tostring(w.regen.result.manaEnd))
    check("they are not all the same plan", w.cheap.result ~= w.health.result)
    check("an empty pool yields no winners", next(SP.Winners({})) == nil)

    -- the search hands the pool out with the winner, without simulating again
    local got, evals = nil, nil
    local h = SP.Search(rp.scenario, { kit = kit, binds = SP.MaxRankBinds(), maxEvals = 12 }, nil,
        function(_, _, n2, _, winners) got, evals = winners, n2 end)
    local frames = 0
    while not got and frames < 20000 do S.Tick(0.016); frames = frames + 1 end
    check("a real search returns strategies too", got ~= nil and got.cheap ~= nil,
        string.format("%d evaluations in %d frames", evals or -1, frames))
end

--------------------------------------------------------------------------------
-- 9f. v0.11.8: the HoT rule waits for the efficient spell rather than spending
-- more mana on a worse one, unless the target is urgent.
--------------------------------------------------------------------------------
do
    local kit2 = kit
    local lb = MD.SpellData.maxRank.Lifebloom
    local rj = MD.SpellData.maxRank.Rejuvenation
    local e1, e2 = kit2.caster[lb], kit2.caster[rj]
    local function hpm(e)
        return ((e.direct or 0) + (e.tick or 0) * (e.ticks or 0) + (e.bloom or 0)) / (e.cost or 1)
    end
    check("Lifebloom is the efficient one on this kit", hpm(e1) > hpm(e2),
        string.format("%.2f vs %.2f per mana", hpm(e1), hpm(e2)))

    local plan2 = SP.NewPlan(SP.MaxRankBinds(),
        { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 0, hotBelow = 0.90, filler = false }, kit2)
    -- a target hurt but not urgent, with the efficient HoT already rolling
    local S2 = { nT = 1, tracked = { true }, dead = { false }, hp = { 6000 }, maxHP = { 10000 },
                 role = { "TANK" }, hots = { { } }, cd = {}, dmg = { { t = {}, a = {} } } }
    -- the damage ring is read by index, so it has to be filled: an empty one
    -- compares nil with a number
    for j = 1, 64 do S2.dmg[1].t[j], S2.dmg[1].a[j] = -1000, 0 end
    S2.hots[1][SM.HOT_INDEX.Lifebloom] = { active = true, expires = 99, stacks = 1 }
    local id = plan2:Decide(S2, 5, 9999, "caster")
    check("it does not buy the worse rate when the target can wait", id ~= rj,
        id and tostring(id) or "waited")

    -- the same target, now urgent: the worse HoT is better than nothing
    S2.hp[1] = 3000
    local id2 = plan2:Decide(S2, 5, 9999, "caster")
    check("but it does when the target is urgent", id2 ~= nil, tostring(id2))

    -- with nothing rolling, it takes the efficient one
    S2.hp[1] = 6000
    S2.hots[1][SM.HOT_INDEX.Lifebloom].active = false
    local id3 = plan2:Decide(S2, 5, 9999, "caster")
    check("with nothing rolling it takes the efficient one", id3 == lb, tostring(id3))
end

--------------------------------------------------------------------------------
-- 9. no trace unless asked
--------------------------------------------------------------------------------
local plain = SM:Run(rp.scenario, nil, { critMode = "ev" })
check("no trace unless asked", plain.trace == nil)

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
