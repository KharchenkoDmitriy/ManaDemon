-- tools/run.sh tools/import.lua [command] [n] [options]
--
-- Real recordings, offline. Loads the game's SavedVariables file -- the only
-- file a WoW addon can write -- as this addon's own database, and runs the
-- same engine the Review tab runs, on the real fights, without the game:
--
--   list                 every recording of the character, with its validate verdict
--   validate N           the full gate report for recording N (1 = most recent)
--   replay N             the trace: every own cast with its target and label, the
--                        mana fit, each target's lowest health
--   coach N [force]      the search and the card (force: even if the gates failed)
--   export N             the /md export text for N, written to .logs/recordings/<id>.txt
--
-- Options: --file <path>   the SavedVariables file (default: $MD_SAVEDVARS, then
--                          .logs/ManaDemon.lua, then the author's install)
--          --char <key>    "Name-Realm" (default: the first character with recordings)
--
-- The spell kit is the CHARACTER's when the file carries a profile (v0.9.0:
-- ManaDemon writes cdb.profile at login, on a talent change and on a gear
-- change) -- healing, crit, spirit, intellect, level, talents and the relic are
-- applied to the stub before the kit is built. Without one, the kit is the
-- harness's stand-in (the BF-1 build, +450 healing, 15% crit) and every run
-- says so. Costs are the recorded ones either way, so the mana side is exact.
local here = arg[0]:match("^(.*)/[^/]+$")

-- arguments
local cmd, n, opts = "list", 1, {}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--file" then opts.file = arg[i + 1]; i = i + 1
        elseif a == "--char" then opts.char = arg[i + 1]; i = i + 1
        elseif a == "force" then opts.force = true
        elseif tonumber(a) then n = tonumber(a)
        elseif a:match("^%a+$") then cmd = a end
        i = i + 1
    end
end

-- the file
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end return false end
local file = opts.file or os.getenv("MD_SAVEDVARS")
if not file then
    local candidates = { ".logs/ManaDemon.lua" }
    local p = io.popen('ls "/mnt/e/Blizzard/World of Warcraft/_anniversary_/WTF/Account"/*/SavedVariables/ManaDemon.lua 2>/dev/null')
    if p then for line in p:lines() do candidates[#candidates + 1] = line end; p:close() end
    for _, c in ipairs(candidates) do if exists(c) then file = c; break end end
end
if not file or not exists(file) then
    print("import: no SavedVariables file. Pass --file <path>, set MD_SAVEDVARS, or copy ManaDemon.lua to .logs/.")
    os.exit(2)
end

-- Load the database BEFORE the addon, so Core.lua initialises from it exactly
-- as the client does: settings, history, calibration, recordings.
dofile(file)
local realDB = _G.ManaDemonDB
if not realDB then print("import: " .. file .. " holds no ManaDemonDB."); os.exit(2) end

local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
S.Load({ "UI/Style.lua", "UI/Tooltip.lua" }, "ManaDemon", MD)   -- Tip is what the card and reports print through

-- the character: the stub's charKey is "Penek-Anniversary"; the real one is
-- whatever the game wrote
local chars = {}
for key, c in pairs(realDB.char or {}) do chars[#chars + 1] = { key = key, n = #(c.recordings or {}) } end
table.sort(chars, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.key < b.key end)
local charKey = opts.char or (chars[1] and chars[1].key)
if not charKey or not realDB.char[charKey] then
    print("import: no character with recordings in " .. file); os.exit(2)
end
MD.cdb = realDB.char[charKey]
MD.player.charKey = charKey

-- The character, applied to the stub (v0.9.0). Every number RankMath:Context()
-- reads comes from the client in game; here it comes from the profile the addon
-- wrote. Talents replace the harness's BF-1 build, so a spell kit built after
-- this is THIS druid's. Anything the profile does not carry keeps the stub's
-- value, and the header line says which of the two you are looking at.
local profile = MD.cdb.profile
local kitLine
if profile then
    S.level = profile.level or S.level
    S.stats[4] = profile.intellect or S.stats[4]
    S.stats[5] = profile.spirit or S.stats[5]
    S.manaMax = profile.manaMax or S.manaMax
    S.mana = S.manaMax
    local healing, crit = profile.healing or 0, profile.crit or 0
    _G.GetSpellBonusHealing = function() return healing end
    _G.GetSpellCritChance = function() return crit end
    if profile.relic then _G.GetInventoryItemID = function() return profile.relic end end
    local talents = profile.talents or {}
    function MD:TalentRank(name) return talents[name] or 0 end
    MD.player.class = profile.class or MD.player.class
    MD.player.isDruid = (profile.class == "DRUID")
    MD.player.level = S.level
    -- the form the profile was taken in, so the Tree aura and the costs agree
    if profile.form == "tree" then
        function MD:InTreeForm() return true end
    elseif profile.form then
        function MD:InTreeForm() return false end
    end
    MD.Regen:Refresh()
    kitLine = string.format("kit:   the character's (profile of %s): level %d %s, +%d healing, %.1f%% crit, " ..
        "%d spirit, %d int, %s", os.date("%Y-%m-%d %H:%M", profile.at or 0), profile.level or 0,
        profile.class or "?", profile.healing or 0, profile.crit or 0, profile.spirit or 0,
        profile.intellect or 0, profile.form == "tree" and "Tree of Life form" or "caster form")
else
    kitLine = "kit:   the harness's (BF-1 build, +450 healing, 15% crit) -- this file carries no profile; " ..
        "log in with v0.9.0 or later and it will"
end

local mp5 = MD.cdb.mp5
local mp5Line
if mp5 then
    mp5Line = string.format("mp5:   %d measured by %s on %s (%d beats%s) - the model adds %.2f/s the API omits",
        mp5.mp5 or 0, mp5.source or "?", os.date("%Y-%m-%d", mp5.at or 0), mp5.ticks or 0,
        mp5.solo == false and ", IN A GROUP" or "", MD.Regen:Unreported())
else
    mp5Line = "mp5:   not measured (/md regentest solo) - recordings made before it carry energize 0"
end

local function Say(fmt, ...) print(string.format(fmt, ...)) end
local function Strip(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

Say("file:  %s", file)
Say("char:  %s   (%d recording(s), %d summarised fight(s))", charKey, #(MD.cdb.recordings or {}), #(MD.cdb.fights or {}))
Say("%s", kitLine)
Say("%s", mp5Line)
Say("")

local FR, SM, SP = MD.FightRecorder, MD.SimModel, MD.SimPlanner
local list = FR:List()
if #list == 0 then Say("no recordings."); os.exit(0) end

local function Verdict(rec)
    local v = SM:Validate(rec)
    if not v then return "?" end
    if v.ok then return "ok" end
    for _, g in ipairs(v.gates) do if not g.ok then return g.name .. ": " .. Strip(g.text) end end
    return "failed"
end

local function When(id)
    return id and os.date("%Y-%m-%d %H:%M", id) or "?"
end

if cmd == "list" then
    Say("%-3s %-17s %-22s %7s %5s %6s %7s %5s  %s", "#", "when", "zone", "dur", "casts", "spent", "tracked", "auras", "validate")
    for i, r in ipairs(list) do
        Say("%-3d %-17s %-22s %6.1fs %5d %6d %7d %5d  %s%s", i, When(r.id), r.zone or "?", r.dur or 0, r.ownCasts or 0,
            r.spent or 0, #(r.tracked or {}), r.auraN or 0, Verdict(r), r.pinned and "  [pinned]" or "")
    end

elseif cmd == "validate" then
    local rec = list[n]; if not rec then Say("no recording %d", n); os.exit(1) end
    for _, line in ipairs(MD:ValidationReport(rec, n)) do Say("%s", Strip(line)) end

elseif cmd == "replay" then
    local rec = list[n]; if not rec then Say("no recording %d", n); os.exit(1) end
    local rp = SP.Replay(rec, { force = opts.force })
    local L, TK = rp.left.trace, SM.TK
    Say("recording %d: %s, %.1fs, %d own casts, %d trace events, grid %d x %.2fs%s", n, rec.zone or "?", rec.dur or 0,
        rec.ownCasts or 0, L.nEv, L.n, L.dt, rp.right and "  (+ the coached plan on the right)" or "")
    for _, line in ipairs(MD:ValidationReport(rec, n)) do Say("  %s", Strip(line)) end
    Say("")
    Say("%7s  %-22s %-14s %5s  %s", "t", "cast", "target", "cost", "label")
    local ci = 0
    for i = 1, L.nEv do
        if L.ev.kind[i] == TK.CAST then
            ci = ci + 1
            local sd = MD.SpellData.spells[L.ev.a[i]]
            local name = sd and (sd.family .. " R" .. sd.rank) or ("spell " .. L.ev.a[i])
            local tgt = rec.roster[L.ev.tgt[i]] and rec.roster[L.ev.tgt[i]].name or "-"
            local label = rp.casts and rp.casts[ci] and rp.casts[ci].label or ""
            Say("%7.2f  %-22s %-14s %5d  %s", L.ev.t[i], name, tgt, L.ev.b[i], label)
        end
    end
    Say("")
    for _, ti in ipairs(rec.tracked or {}) do
        local col = L.hp[ti]
        if col then
            local lo, loK = 1, 1
            for k = 1, L.n do if col[k] < lo then lo, loK = col[k], k end end
            Say("  %-14s lowest %3d%% at %.1fs", rec.roster[ti] and rec.roster[ti].name or ("#" .. ti), lo * 100 + 0.5, (loK - 1) * L.dt)
        end
    end
    if rp.right then
        local R = rp.right.trace
        local casts, waits = 0, 0
        for i = 1, R.nEv do
            if R.ev.kind[i] == TK.CAST then casts = casts + 1 elseif R.ev.kind[i] == TK.WAIT then waits = waits + 1 end
        end
        Say("  plan: %d casts, %d waits, spent %d vs your %d", casts, waits, rp.right.snapshot.manaSpent, rp.left.snapshot.manaSpent)
    end

elseif cmd == "coach" then
    local rec = list[n]; if not rec then Say("no recording %d", n); os.exit(1) end
    if not MD.player.isDruid then MD.player.isDruid = true end
    local done, out = false, nil
    local h = SP.CoachAsync(rec, { n = n, force = opts.force }, function(lines) out = lines; done = true end)
    local frames = 0
    while not done and frames < 20000 do S.Tick(0.016); frames = frames + 1 end
    if not done then Say("coach: the search did not finish in %d frames", frames); os.exit(1) end
    for _, line in ipairs(out) do Say("%s", Strip(line)) end
    if h then Say("(search ran across %d stub frames)", frames) end

elseif cmd == "export" then
    local rec = list[n]; if not rec then Say("no recording %d", n); os.exit(1) end
    -- MD:Export renders every recording; keep the sections before the
    -- recordings (fights, overheal, roster) and this one recording's section
    local lines = MD:Export()
    os.execute("mkdir -p .logs/recordings")
    local path = string.format(".logs/recordings/%s.txt", tostring(rec.id))
    local f = assert(io.open(path, "w"))
    local phase = "head"   -- head -> in this recording -> other recording
    for _, line in ipairs(lines) do
        local which = line:match("^# recording (%d+)")
        if which then phase = (tonumber(which) == n) and "mine" or "other" end
        if phase ~= "other" then f:write(line, "\n") end
    end
    f:close()
    Say("wrote %s (%d lines in the export; this recording's section kept)", path, #lines)
else
    Say("unknown command %q", cmd)
    os.exit(1)
end
