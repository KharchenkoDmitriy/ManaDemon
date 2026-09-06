-- tools/run.sh tools/simwindow.lua
--
-- The synthetic side of the Simulation window, without the window: build every
-- preset combination's scenario, run the baselines and the search on a few of
-- them, and check the parts that are pure logic (event generation, Monte Carlo,
-- FromRecordings). The frame itself can only be checked in-game.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local P, SP, SM = MD.SimPresets, MD.SimPlanner, MD.SimModel

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name end
    print(string.format("%-40s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

-- every preset combination must produce a runnable scenario
local combos, worst = 0, nil
for _, party in ipairs(P.PARTY) do
    for _, dmg in ipairs(P.DAMAGE) do
        for _, sit in ipairs(P.SITUATION) do
            combos = combos + 1
            local sc = P.BuildScenario({ party = party.id, damage = dmg.id, situation = sit.id, dur = 45 })
            if #sc.targets == 0 then worst = party.id .. "/" .. dmg.id .. "/" .. sit.id end
            -- events must be sorted: the engine reads them by cursor
            for i = 2, #sc.ev.t do
                if sc.ev.t[i] < sc.ev.t[i - 1] then worst = "unsorted in " .. dmg.id end
            end
        end
    end
end
check("every preset builds a scenario", worst == nil, worst or (combos .. " combinations"))

local kit = MD.RankMath:SpellKit()
local sc = P.BuildScenario({ party = "5", damage = "dungeon", situation = "full", dur = 45 })
sc.kit = kit
check("dungeon preset generates damage", #sc.ev.t > 40, tostring(#sc.ev.t))

local base = SP.RunPlan(sc, SP.Baselines(nil, kit)[1].plan, { critMode = "ev" })
print(string.format("  max rank on the dungeon preset: %.0f mana, lowest %.0f%%, %.0fs in danger, %d dead",
    base.manaSpent, (base.lowest.hp or 1) * 100, base.floorSeconds, base.deaths.n))
check("a baseline actually heals", base.manaSpent > 0, string.format("%.0f mana", base.manaSpent))

local done, best, bestRes = false, nil, nil
SP.Search(sc, { kit = kit, binds = SP.MaxRankBinds(), maxEvals = 300 }, nil,
    function(b, r) done, best, bestRes = true, b, r end)
local frames = 0
while not done and frames < 20000 do S.Tick(0.016); frames = frames + 1 end
check("search completes on a synthetic fight", done and best ~= nil, tostring(frames) .. " frames")
if best then
    print(string.format("  best: swiftmend<%.0f%% direct<%.0f%% roll x%d hot<%.0f%% filler=%s -> %.0f mana, %.0fs in danger",
        best.swiftmendBelow * 100, best.directBelow * 100, best.rollStacks, best.hotBelow * 100,
        tostring(best.filler), bestRes.manaSpent, bestRes.floorSeconds))
    check("best is no worse than max rank",
        not SP.Better(SP.Score(base, best, 0), SP.Score(bestRes, best, 0)))
    local mc = SP.MonteCarlo(sc, best, nil, 10)
    check("monte carlo runs", mc ~= nil and mc.k == 10,
        mc and string.format("floor %.0f%%, death %.0f%%", mc.floorRate * 100, mc.deathRate * 100))
    -- the replicates must not corrupt the scenario they perturb
    local after = SP.RunPlan(sc, best, { critMode = "ev" })
    check("monte carlo restores the damage", math.abs(after.manaSpent - bestRes.manaSpent) < 1,
        string.format("%.0f vs %.0f", after.manaSpent, bestRes.manaSpent))
end

check("FromRecordings says nothing with no recordings", SP.FromRecordings("Nowhere") == nil)

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then os.exit(1) end
