-- tools/run.sh tools/reccheck.lua
--
-- Drives a whole fake pull through the real UI/Summary.lua handler and
-- Engine/FightRecorder.lua: a party of five, damage on the tank, the player's
-- own casts and heals, a foreign heal, a death, form changes. Then checks the
-- recorded stream and the plan-free labels against what was scripted.
--
-- This is the only way to exercise the recorder without a dungeon.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local SD = MD.SpellData

S.AddUnit("party1", { guid = "Tank-1",  name = "Destroyka", class = "WARRIOR", role = "TANK",   hp = 8000, hpMax = 8000 })
S.AddUnit("party2", { guid = "Mage-1",  name = "Alkandari", class = "MAGE",    role = "DAMAGER", hp = 4000, hpMax = 4000 })
S.AddUnit("party3", { guid = "Lock-1",  name = "Abufaisall",class = "WARLOCK", role = "DAMAGER", hp = 4200, hpMax = 4200 })
S.AddUnit("party4", { guid = "Pala-1",  name = "Trecoda",   class = "PALADIN", role = "DAMAGER", hp = 5200, hpMax = 5200 })
S.Fire("GROUP_ROSTER_UPDATE")

MD.db.debug.enabled = true
function MD:DebugLog(cat, text) if cat == "sim" or cat == "combat" then print("[" .. cat .. "] " .. text) end end

local PLAYER = "Player-1"
MD.db.healAmountGross = true
local rejuv, regrowth, lifebloom = SD.maxRank.Rejuvenation, SD.maxRank.Regrowth, SD.maxRank.Lifebloom
local MOTW = 9885

-- One combat-log event. The prefix must be spliced into the SAME call as the
-- payload: a function call in a non-final argument position is truncated to one
-- value, which is exactly the Lua trap CLAUDE.md names -- and it silently ate
-- every event the first time this file was written.
local function ev(sub, src, dst, dstName, ...)
    S.Combat(0, sub, false, src, "src", 0, 0, dst, dstName, 0, 0, ...)
end
local function cast(spellID, dst, dstName)
    ev("SPELL_CAST_SUCCESS", PLAYER, dst, dstName, spellID, "S", 8)
    -- the client fires both; Engine/SpendTracker.lua listens to this one
    S.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, spellID)
end
-- This client reports heal `amount` GROSS (overheal included), so a full
-- overheal is amount == overheal.
local function ownTick(spellID, dst, dstName, gross, over)
    ev("SPELL_PERIODIC_HEAL", PLAYER, dst, dstName, spellID, "S", 8, gross, over, 0, false)
end
local function swing(dst, dstName, amount)
    ev("SWING_DAMAGE", "Mob-1", dst, dstName, amount, 0, 1, 0, 0, 0, false)
end
local function foreignHeal(dst, dstName, amount)
    ev("SPELL_HEAL", "Pala-1", dst, dstName, 635, "Holy Light", 2, amount, 0, 0, false)
end

-- 6s of pre-pull: a Lifebloom on a full-health tank whose ticks all overheal
S.Tick(0.5)
cast(lifebloom, "Tank-1", "Destroyka")
for _ = 1, 4 do S.Tick(1.0); ownTick(lifebloom, "Tank-1", "Destroyka", 99, 99) end

S.Fire("PLAYER_REGEN_DISABLED")
local FR = MD.FightRecorder
assert(FR.active, "recorder did not start")

local function advance(sec) for _ = 1, math.floor(sec / 0.5 + 0.5) do S.Tick(0.5) end end

S.units.party1.hp = 3000
swing("Tank-1", "Destroyka", 5000)
advance(1.5); cast(regrowth, "Tank-1", "Destroyka"); S.mana = S.mana - (SD:GetCost(regrowth) or 0)
advance(1.5); cast(rejuv, "Tank-1", "Destroyka");    S.mana = S.mana - (SD:GetCost(rejuv) or 0)
advance(1.5); cast(MOTW, PLAYER, "Penek");           S.mana = S.mana - 445
advance(3.0); ownTick(rejuv, "Tank-1", "Destroyka", 400, 0)
S.units.party2.hp = 1000
swing("Mage-1", "Alkandari", 3000)
foreignHeal("Mage-1", "Alkandari", 900)
advance(2.0); cast(rejuv, "Mage-1", "Alkandari");    S.mana = S.mana - (SD:GetCost(rejuv) or 0)
-- refresh a Rejuvenation with three ticks still pending: this must label "early"
advance(3.0); cast(rejuv, "Mage-1", "Alkandari");    S.mana = S.mana - (SD:GetCost(rejuv) or 0)
-- and one cast on a target at full health: this must label "overheal"
advance(2.0); cast(lifebloom, "Pala-1", "Trecoda");  S.mana = S.mana - (SD:GetCost(lifebloom) or 0)
ev("UNIT_DIED", "Mob-1", "Lock-1", "Abufaisall")
advance(10)
S.Fire("PLAYER_REGEN_ENABLED")

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-34s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local rec = FR:Get(1)
check("stream recorded", rec ~= nil)
if rec then
    local n = { }
    for i = 1, rec.n do n[rec.ev.kind[i]] = (n[rec.ev.kind[i]] or 0) + 1 end
    local K = MD.SimModel.K
    check("own casts recorded", (n[K.OWNCAST] or 0) == 6, tostring(n[K.OWNCAST]))
    check("damage recorded", (n[K.DMG] or 0) == 2, tostring(n[K.DMG]))
    check("foreign heal recorded", (n[K.FHEAL] or 0) == 1, tostring(n[K.FHEAL]))
    check("own tick recorded", (n[K.OWNTICK] or 0) == 1, tostring(n[K.OWNTICK]))
    check("death recorded", #rec.deaths == 1, tostring(#rec.deaths))
    check("precasts carried", #rec.precasts == 1, tostring(#rec.precasts))
    check("mana samples", #rec.mana.t > 5, tostring(#rec.mana.t))
    check("hp snapshots", #rec.hp.t > 3, tostring(#rec.hp.t))
    check("roster indexed", #rec.roster == 5, tostring(#rec.roster))
    check("foreign share sane", rec.foreignShare > 0 and rec.foreignShare < 1,
        string.format("%.2f", rec.foreignShare))
    local L = rec.labels
    check("labels attached", L ~= nil)
    if L then
        -- costs come from the live/static maths, so the expectations do too
        local cRejuv, cLB = SD:GetCost(rejuv), SD:GetCost(lifebloom)
        check("utility labelled", (L.utility or 0) == 445, tostring(L.utility))
        check("early labelled", (L.early or 0) == cRejuv,
            string.format("%s, expected one Rejuvenation (%s)", tostring(L.early), tostring(cRejuv)))
        check("overheal labelled", (L.overheal or 0) == cLB,
            string.format("%s, expected one Lifebloom (%s)", tostring(L.overheal), tostring(cLB)))
        local sum = 0
        for _, k in ipairs({ "utility", "shift", "early", "overheal", "ok" }) do sum = sum + (L[k] or 0) end
        check("label identity holds", sum == (rec.spent or 0),
            string.format("%d labelled vs %d spent", sum, rec.spent or 0))
    end
end

local f = MD.fightHistory[#MD.fightHistory]
check("summary row written", f ~= nil and f.streamID == (rec and rec.id))
if f then
    check("row has hp buckets", f.hpBuckets ~= nil and (f.hpBuckets[3] or 0) >= 1,
        f.hpBuckets and table.concat(f.hpBuckets, "/") or "nil")
    check("row prehot > 0", (f.prehot or 0) > 0, tostring(f.prehot))
end

-- /md export must render the stream without blowing up on a nil array
local exported = MD:Export()
local sections = 0
for _, line in ipairs(exported) do if line:match("^# ") then sections = sections + 1 end end
check("export renders the stream", #exported > 60 and sections >= 8,
    string.format("%d lines, %d sections", #exported, sections))

-- Replay the recording we just made, through the real gates.
if rec then
    print("\n-- /md simreplay 1 --")
    local report = MD:ValidationReport(rec, 1)
    for _, line in ipairs(report) do print(line) end
    local v = MD.SimModel:Validate(rec)
    check("validate returns gates", v and #v.gates >= 6, v and tostring(#v.gates) or "nil")
    -- this scripted pull HAS a death and heavy foreign healing, so it must be
    -- rejected: a replay that passed here would mean the gates do nothing
    check("scripted pull is rejected", v and v.ok == false)
    local byName = {}
    for _, g in ipairs(v.gates) do byName[g.name] = g end
    check("death gate fired", byName["no tracked death"] and not byName["no tracked death"].ok)
    check("foreign gate fired", byName["foreign healing"] and not byName["foreign healing"].ok)
    check("coverage gate present", byName["spend coverage"] ~= nil,
        byName["spend coverage"] and byName["spend coverage"].text or "missing")
end

-- The coach must refuse a fight that does not replay, and produce a card when
-- forced. Both paths are exercised: silence is the more important one.
if rec then
    print("\n-- /md coach 1 --")
    local refused = MD.SimPlanner.Coach(rec, { n = 1 })
    for _, l in ipairs(refused) do print(l) end
    check("coach refuses a failed replay", refused[1]:find("does not replay") ~= nil)

    print("\n-- /md coach 1 force --")
    local card = MD.SimPlanner.Coach(rec, { n = 1, force = true })
    for _, l in ipairs(card) do print(l) end
    check("card produced", #card > 8, tostring(#card))
    check("card names the binds", table.concat(card, "\n"):find("Bind:") ~= nil)
    check("card carries caveats", table.concat(card, "\n"):find("caveat:") ~= nil)
    check("coach mark written", MD.cdb.coachMarks and MD.cdb.coachMarks["Blood Furnace"] ~= nil)
end

-- The search: drive it across frames the way the client would.
if rec then
    print("\n-- search --")
    local done, bestPlan, bestRes, evalCount = false, nil, nil, 0
    local sc = MD.SimModel.ScenarioFromRecording(rec, MD.RankMath:SpellKit())
    local t0 = os.clock()
    MD.SimPlanner.Search(sc, { rec = rec, maxEvals = 300 }, nil,
        function(b, r, evals) done, bestPlan, bestRes, evalCount = true, b, r, evals end)
    local frames = 0
    while not done and frames < 5000 do S.Tick(0.016); frames = frames + 1 end
    check("search finished", done, string.format("%d frames, %d evals, %.0f ms",
        frames, evalCount, (os.clock() - t0) * 1000))
    check("search stayed in budget", evalCount <= 300, tostring(evalCount))
    check("search found a plan", bestPlan ~= nil)
    if bestPlan then
        print(string.format("  best: swiftmend<%.0f%% direct<%.0f%% roll x%d hot<%.0f%% filler=%s -> %.0f mana, lowest %.0f%%",
            bestPlan.swiftmendBelow * 100, bestPlan.directBelow * 100, bestPlan.rollStacks,
            bestPlan.hotBelow * 100, tostring(bestPlan.filler), bestRes.manaSpent,
            (bestRes.lowest.hp or 0) * 100))
        -- the search must not lose to a baseline it was seeded with
        local base = MD.SimPlanner.RunPlan(sc, MD.SimPlanner.Baselines(rec, MD.RankMath:SpellKit())[1].plan,
            { critMode = "ev" })
        local baseSnap = { manaSpent = base.manaSpent, healed = base.healed, overhealed = base.overhealed,
                           floorSeconds = base.floorSeconds, deaths = { n = base.deaths.n },
                           lowest = { hp = base.lowest.hp } }
        local bs = MD.SimPlanner.Score(baseSnap, bestPlan, 0)
        local ws = MD.SimPlanner.Score(bestRes, bestPlan, 0)
        check("search beats or ties max rank", not MD.SimPlanner.Better(bs, ws),
            string.format("best %.0f vs max-rank %.0f mana", bestRes.manaSpent, base.manaSpent))
    end
end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
