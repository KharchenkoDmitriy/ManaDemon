-- tools/run.sh tools/solvercmp.lua [--file <sv>] [--char <key>]
--
-- The control experiment for docs/SPEC-v0.13.md: the threshold rules and the
-- solver, on the same recordings, through the same engine, scored on the same
-- lexicographic tuple. The solver has to win or tie to replace anything.
local here = arg[0]:match("^(.*)/[^/]+$")
local opts = {}
do
    local i = 1
    while i <= #arg do
        if arg[i] == "--file" then opts.file = arg[i + 1]; i = i + 1
        elseif arg[i] == "--char" then opts.char = arg[i + 1]; i = i + 1 end
        i = i + 1
    end
end
local file = opts.file or ".logs/ManaDemon.lua"
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end end
if not exists(file) then
    local p = io.popen('ls "/mnt/e/Blizzard/World of Warcraft/_anniversary_/WTF/Account"/*/SavedVariables/ManaDemon.lua 2>/dev/null')
    if p then for line in p:lines() do file = line; break end; p:close() end
end
dofile(file)
local realDB = _G.ManaDemonDB
local pre = {}
for k, c in pairs(realDB.char or {}) do pre[k] = { profile = c.profile, mp5 = c.mp5 } end

local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local SM, SP, SV = MD.SimModel, MD.SimPlanner, MD.SimSolver

local chars = {}
for key, c in pairs(realDB.char or {}) do
    if #(c.recordings or {}) > 0 then chars[#chars + 1] = key end
end
table.sort(chars)
local charKey = opts.char or chars[1]
MD.cdb = realDB.char[charKey]
MD.cdb.profile = pre[charKey] and pre[charKey].profile
MD.cdb.mp5 = pre[charKey] and pre[charKey].mp5

local function ApplyProfile(p)
    if not p then return end
    S.level = p.level or S.level
    if (p.intellect or 0) > 0 then S.stats[4] = p.intellect end
    if (p.spirit or 0) > 0 then S.stats[5] = p.spirit end
    S.manaMax = p.manaMax or S.manaMax; S.mana = S.manaMax
    local healing, crit = p.healing or 0, p.crit or 0
    _G.GetSpellBonusHealing = function() return healing end
    _G.GetSpellCritChance = function() return crit end
    local tal = p.talents or {}
    function MD:TalentRank(n) return tal[n] or 0 end
    MD.player.class = p.class or MD.player.class
    MD.player.isDruid = (p.class == "DRUID")
    MD.player.level = S.level
    if p.form == "tree" then function MD:InTreeForm() return true end
    else function MD:InTreeForm() return false end end
    if p.fromLog then
        local lvl = p.level or 70
        _G.IsSpellKnown = function(id)
            local sd = MD.SpellData.spells[id]
            return sd ~= nil and (sd.level or 0) <= lvl
        end
        _G.IsPlayerSpell = _G.IsSpellKnown
    end
    MD.SpellData:BuildKnown()
    MD.Regen:Refresh()
end

-- Every recording in the file, with the profile it belongs to. A multi-character
-- file (the Warcraft Logs corpus) is one pool to learn from and many kits to
-- plan with: the prior is shared, the spell values are each druid's own.
local pool = {}
for key, c in pairs(realDB.char or {}) do
    for _, rec in ipairs(c.recordings or {}) do
        pool[#pool + 1] = { rec = rec, profile = pre[key] and pre[key].profile, who = key }
    end
end
table.sort(pool, function(a, b) return (a.rec.id or 0) < (b.rec.id or 0) end)
local allRecs = {}
for i, e in ipairs(pool) do allRecs[i] = e.rec end

local p = MD.cdb.profile
ApplyProfile(p)
local kit = MD.RankMath:SpellKit({ live = true })
local binds = SP.MaxRankBinds()
print(string.format("char: %s   +%d healing, level %d\n", charKey,
    p and p.healing or 0, p and p.level or 0))

local function tup(t) return string.format("deaths %d  floor %5.1fs  mana %6.0f  overheal %4.0f",
    t[1], t[2], t[3], t[6] or 0) end

local IN = MD.Intuition
print(string.format("corpus: %d recording(s) across %d character(s)", #pool, (function()
    local n = 0; for _ in pairs(realDB.char or {}) do n = n + 1 end; return n end)()))
print("intuition over the whole corpus: " .. IN:Describe(IN:Build(allRecs, nil)) .. "\n")

local function total(mk)
    local d, f, m = 0, 0, 0
    for _, e in ipairs(pool) do
        ApplyProfile(e.profile)
        local kit2 = MD.RankMath:SpellKit({ live = true })
        local sc = SM.ScenarioFromRecording(e.rec, kit2)
        if sc then
            local plan = mk(e.rec, kit2)
            local r = SP.RunPlan(sc, plan, { critMode = "ev" })
            local a = SP.Score(r, plan, 0)
            d, f, m = d + a[1], f + a[2], m + a[3]
        end
    end
    return d, f, m
end

local function line(label, d, f, m)
    print(string.format("%-44s deaths %d  floor %6.1fs  mana %7.0f", label, d, f, m))
end

local rd, rf, rm = total(function(_, k2)
    return SP.NewPlan(SP.MaxRankBinds(), { swiftmendBelow = 0.30, directBelow = 0.45,
        rollStacks = 3, hotBelow = 0.80, filler = false }, k2)
end)
line("rules (5 thresholds)", rd, rf, rm)

local BEST = { minValue = 15, horizon = 18 }
local sd, sf, sm = total(function(_, k2)
    return SV.NewPlan(SP.MaxRankBinds(), BEST, k2)
end)
line("solver, no prior", sd, sf, sm)

local id_, if_, im_ = total(function(rec, k2)
    return SV.NewPlan(SP.MaxRankBinds(), { minValue = BEST.minValue, horizon = BEST.horizon,
        prior = IN:Build(allRecs, rec.id), zone = rec.zone }, k2)
end)
line("solver + intuition (leave-one-out)", id_, if_, im_)

print(string.format("\nintuition changed mana by %+.0f (%+.1f%%) and floor by %+.1fs",
    im_ - sm, sm > 0 and 100 * (im_ - sm) / sm or 0, if_ - sf))
