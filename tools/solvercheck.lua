-- tools/run.sh tools/solvercheck.lua
--
-- The solver (docs/SPEC-v0.13.md): a spell is a series of deposits, and the
-- cast to make is the one that removes the most missing-health-seconds per
-- mana. These assertions are about the PROPERTIES the design claims, not about
-- particular numbers -- an overhealing cast must score below a clean one with
-- no overheal term anywhere in the code, and the same deficit must pull a
-- different spell depending only on how the damage is spread.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local SM, SP, SV = MD.SimModel, MD.SimPlanner, MD.SimSolver
local K = SM.K

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-46s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local kit = MD.RankMath:SpellKit({ live = true })
local binds = SP.MaxRankBinds()

--------------------------------------------------------------------------------
-- 1. Deposits
--------------------------------------------------------------------------------
do
    local caster = kit.caster
    local lb = caster[binds.Lifebloom]
    local dep, n = SV.Deposits(lb, nil)
    local total = 0
    for i = 1, n do total = total + dep[i][2] end
    local want = (lb.tick or 0) * (lb.ticks or 0) + (lb.bloom or 0)
    check("a spell's deposits sum to what it heals",
        math.abs(total - want) < 1, string.format("%.0f vs %.0f", total, want))
    check("every deposit lands after the cast finishes", (function()
        for i = 1, n do if dep[i][1] < (lb.cast or 1.5) - 1e-9 then return false end end
        return true
    end)())

    local rj = caster[binds.Rejuvenation]
    local d2, n2 = SV.Deposits(rj, nil)
    check("a HoT deposits once per tick", n2 == (rj.ticks or 0), string.format("%d of %d", n2, rj.ticks or 0))

    local rg = caster[binds.Regrowth]
    local d3, n3 = SV.Deposits(rg, nil)
    check("a hybrid deposits its direct heal first",
        n3 == (rg.ticks or 0) + 1 and math.abs(d3[1][2] - rg.direct) < 1,
        string.format("%d deposits, first %.0f", n3, d3[1][2]))

    -- a Lifebloom on top of two stacks deposits three stacks' worth
    local st = { active = true, stacks = 2, family = "Lifebloom" }
    local d4, n4 = SV.Deposits(lb, st)
    check("Lifebloom onto 2 stacks deposits 3 stacks' worth",
        math.abs(d4[1][2] - lb.tick * 3) < 1,
        string.format("%.0f vs %.0f", d4[1][2], lb.tick * 3))
end

--------------------------------------------------------------------------------
-- 2. The gap does the work three separate terms used to do
--------------------------------------------------------------------------------
do
    local maxHP = 10000
    -- a full target: every deposit is overheal, so it saves nothing
    local dep = { { 1.5, 3000 } }
    local full = SV.Gap(maxHP, maxHP, 0, nil, {}, 0, nil, 0, 0, 12)
    local fullWith = SV.Gap(maxHP, maxHP, 0, nil, {}, 0, dep, 1, 0, 12)
    check("a cast into a full target saves nothing", math.abs(full - fullWith) < 1e-6,
        string.format("%.0f vs %.0f", full, fullWith))

    -- the same cast into a real deficit saves the whole integral it fills
    local hurt = SV.Gap(4000, maxHP, 0, nil, {}, 0, nil, 0, 0, 12)
    local hurtWith = SV.Gap(4000, maxHP, 0, nil, {}, 0, dep, 1, 0, 12)
    check("the same cast into a deficit saves real health-seconds",
        hurt - hurtWith > 1000, string.format("%.0f saved", hurt - hurtWith))

    -- half of it overheals: it must save strictly less, with no overheal term
    local dep2 = { { 1.5, 12000 } }
    local overWith = SV.Gap(4000, maxHP, 0, nil, {}, 0, dep2, 1, 0, 12)
    local savedClean = hurt - hurtWith
    local savedOver = hurt - overWith
    check("an oversized cast saves less per point than a fitting one",
        savedOver / 12000 < savedClean / 3000,
        string.format("%.3f vs %.3f per point", savedOver / 12000, savedClean / 3000))

    -- a deposit that lands late is worth less than the same one landing now
    local now = SV.Gap(4000, maxHP, 0, nil, {}, 0, { { 0.5, 3000 } }, 1, 0, 12)
    local late = SV.Gap(4000, maxHP, 0, nil, {}, 0, { { 9.0, 3000 } }, 1, 0, 12)
    check("a deposit landing sooner saves more than the same one landing late",
        (hurt - now) > (hurt - late), string.format("%.0f vs %.0f", hurt - now, hurt - late))
end

--------------------------------------------------------------------------------
-- 3. The decision: same deficit, different damage shape, different spell
--------------------------------------------------------------------------------
local function state(hp, rate, seenFor)
    local S = { nT = 1, tracked = { true }, dead = {}, hp = { hp }, maxHP = { 10000 },
                hots = { {} }, dmg = {}, threat = {}, incoming = {} }
    local ring = { t = {}, a = {}, total = 0, hits = 0, firstAt = 0, biggest = 0 }
    for i = 1, 64 do ring.t[i], ring.a[i] = -100, 0 end
    if rate > 0 then
        local per = rate * 1.0
        for i = 1, 5 do
            ring.t[i], ring.a[i] = (seenFor or 5) - i, per
            ring.total = ring.total + per
            ring.hits = ring.hits + 1
            if per > ring.biggest then ring.biggest = per end
        end
        ring.firstAt = 0
    end
    S.dmg[1] = ring
    return S
end

do
    local plan = SV.NewPlan(binds, { minValue = 0.1, horizon = 12 }, kit)
    -- deeply hurt, nothing incoming: the gap is NOW, so a direct heal wins
    local hurtQuiet = state(3000, 0)
    local id1 = plan:Decide(hurtQuiet, 10, 99999, "caster")
    local sd1 = id1 and MD.SpellData.spells[id1]
    check("a deep deficit with no incoming pulls a direct heal",
        sd1 ~= nil and (sd1.family == "Regrowth" or sd1.family == "HealingTouch"
                        or sd1.family == "Swiftmend"),
        sd1 and (sd1.family .. " r" .. sd1.rank) or tostring(id1))

    -- barely hurt but bleeding: the gap is AHEAD, so a HoT wins
    local trickle = state(9200, 300)
    local id2 = plan:Decide(trickle, 10, 99999, "caster")
    local sd2 = id2 and MD.SpellData.spells[id2]
    check("a small deficit with damage coming pulls a HoT",
        sd2 ~= nil and (sd2.family == "Lifebloom" or sd2.family == "Rejuvenation"),
        sd2 and (sd2.family .. " r" .. sd2.rank) or tostring(id2))
    check("the two answers differ on demand alone, not on a threshold",
        id1 ~= id2, string.format("%s vs %s", tostring(id1), tostring(id2)))

    -- full and quiet: nothing is worth casting
    local calm = state(10000, 0)
    check("nobody hurt, nothing coming: it waits",
        plan:Decide(calm, 10, 99999, "caster") == nil)

    -- the efficiency floor is the mana dial
    local greedy = SV.NewPlan(binds, { minValue = 0.01, horizon = 12 }, kit)
    local stingy = SV.NewPlan(binds, { minValue = 1000, horizon = 12 }, kit)
    local weak = state(9700, 40)
    check("a low floor spends on a thin target", greedy:Decide(weak, 10, 99999, "caster") ~= nil)
    check("a high floor keeps the mana", stingy:Decide(weak, 10, 99999, "caster") == nil)
end

--------------------------------------------------------------------------------
-- 4. Causality: the solver may not see the future either
--------------------------------------------------------------------------------
do
    local function scenarioWithBurst(burst)
        local ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
        local n = 0
        local function add(at, amt)
            n = n + 1
            ev.t[n], ev.kind[n], ev.tgt[n], ev.amt[n], ev.x[n] = at, K.DMG, 1, amt, 0
        end
        for at = 2, 38, 4 do add(at, 300) end
        if burst then for at = 40, 48 do add(at, 1200) end end
        return { dur = 60, pool = 9000, initial = { mana = 9000, apiBase = 10, apiCasting = 4 },
                 kit = kit, floor = 0.30, ev = ev,
                 targets = { { name = "T", role = "TANK", maxHP = 10000, hp0 = 10000, tracked = true } } }
    end
    local function castsOf(sc)
        local out = {}
        SP.RunPlan(sc, SV.NewPlan(binds, { minValue = 0.5, horizon = 12 }, kit),
            { critMode = "ev", onCast = function(_, at, id)
                out[#out + 1] = string.format("%.2f:%d", at, id) end })
        return out
    end
    local quiet, loud = castsOf(scenarioWithBurst(false)), castsOf(scenarioWithBurst(true))
    local diverged
    for j = 1, math.min(#quiet, #loud) do
        local at = tonumber(quiet[j]:match("^([%d%.]+)"))
        if quiet[j] ~= loud[j] then diverged = diverged or at end
    end
    check("the solver casts something", #quiet > 0, string.format("%d casts", #quiet))
    check("a burst at 40s changes nothing the solver does before it",
        diverged == nil or diverged >= 39.9,
        diverged and string.format("diverged at %.1fs", diverged) or "identical until the burst")
end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
