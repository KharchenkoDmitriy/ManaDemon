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

local p = MD.cdb.profile
if p then
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
        MD.SpellData:BuildKnown()
    end
    MD.Regen:Refresh()
end

local kit = MD.RankMath:SpellKit({ live = true })
local binds = SP.MaxRankBinds()
print(string.format("char: %s   +%d healing, level %d\n", charKey,
    p and p.healing or 0, p and p.level or 0))

local function tup(t) return string.format("deaths %d  floor %5.1fs  mana %6.0f  overheal %4.0f",
    t[1], t[2], t[3], t[6] or 0) end

-- The rules baseline, once.
local baseMana, baseFloor, baseDeaths = 0, 0, 0
for _, rec in ipairs(MD.cdb.recordings or {}) do
    local sc = SM.ScenarioFromRecording(rec, kit)
    if sc then
        local rules = SP.NewPlan(binds, { swiftmendBelow = 0.30, directBelow = 0.45,
            rollStacks = 3, hotBelow = 0.80, filler = false }, kit)
        local r = SP.RunPlan(sc, rules, { critMode = "ev" })
        local a = SP.Score(r, rules, 0)
        baseDeaths, baseFloor, baseMana = baseDeaths + a[1], baseFloor + a[2], baseMana + a[3]
    end
end
print(string.format("rules (5 thresholds)        deaths %d  floor %5.1fs  mana %6.0f",
    baseDeaths, baseFloor, baseMana))
print("")
print("the solver's frontier -- one dial (minValue) and one horizon:")
print(string.format("%9s %8s  %s", "minValue", "horizon", "deaths / floor / mana over all recordings"))

local best
for _, hz in ipairs({ 12, 18, 24 }) do
    for _, mv in ipairs({ 0.5, 5, 10, 15, 20, 25, 30, 40 }) do
        local d, f, m = 0, 0, 0
        for _, rec in ipairs(MD.cdb.recordings or {}) do
            local sc = SM.ScenarioFromRecording(rec, kit)
            if sc then
                local sv = SV.NewPlan(binds, { minValue = mv, horizon = hz }, kit)
                local r = SP.RunPlan(sc, sv, { critMode = "ev" })
                local b = SP.Score(r, sv, 0)
                d, f, m = d + b[1], f + b[2], m + b[3]
            end
        end
        local mark = ""
        if d <= baseDeaths and f <= baseFloor and m < baseMana then mark = "  <= beats the rules outright" end
        print(string.format("%9.2f %8d  deaths %d  floor %5.1fs  mana %6.0f%s", mv, hz, d, f, m, mark))
        if (not best) or (d < best.d) or (d == best.d and f < best.f)
           or (d == best.d and f == best.f and m < best.m) then
            best = { d = d, f = f, m = m, mv = mv, hz = hz }
        end
    end
end
print(string.format("\nbest by the lexicographic tuple: minValue %.2f horizon %d -> deaths %d, floor %.1fs, mana %.0f",
    best.mv, best.hz, best.d, best.f, best.m))
print(string.format("rules for comparison:                                deaths %d, floor %.1fs, mana %.0f",
    baseDeaths, baseFloor, baseMana))
