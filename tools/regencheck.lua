-- tools/run.sh tools/regencheck.lua
--
-- Drives /md regentest against a scripted mana stream and checks the tick
-- histogram it prints. The histogram is what turns "GetManaRegen misses
-- something" into "it misses THESE two things", so it has to survive the case
-- that made it necessary: several overlapping 3s phases of a party energize,
-- whose *median spacing* reads as ~1s and whose beat is still exactly 3.00s.
--
-- The scripted stream is the shape of .logs/dungeon-BF-1.txt (docs/TESTING.md
-- 16): the reported spirit tick, a constant 17 on a 2.00s beat, and four
-- overlapping 3.00s streams of 13-15.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB

local out = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) out[#out + 1] = m; print(m) end }

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-34s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end
local function found(pat)
    for _, m in ipairs(out) do if m:find(pat) then return m end end
    return nil
end

local function gain(n) S.mana = S.mana + n; S.Fire("UNIT_POWER_UPDATE", "player", "MANA") end

-- Spend down to `v` the way the client would: one power event, then long
-- enough for the five-second rule that drop started to expire. Assigning
-- S.mana silently instead makes the model see the drop at the NEXT gain --
-- five seconds of the measurement window inside the 5SR, which is exactly what
-- v0.9.0 refuses to store from.
local function drainTo(v)
    S.mana = v
    S.Fire("UNIT_POWER_UPDATE", "player", "MANA")
    for _ = 1, 12 do S.Tick(0.5) end
end

--------------------------------------------------------------------------------
-- 1. the BF-1 shape
--------------------------------------------------------------------------------
drainTo(100)
MD:RunRegenTest(30)
S.Tick(0.5) -- starts the window once the 5SR is over
local t0 = S.now
local nextSpirit, nextMp5 = 2.0, 2.6
local phase = { 3.1, 3.25, 4.0, 5.4 } -- four overlapping 3s streams
while S.now - t0 < 30.5 do
    S.Tick(0.1)
    local t = S.now - t0
    if t >= nextSpirit then nextSpirit = nextSpirit + 2.0; gain(138) end
    if t >= nextMp5 then nextMp5 = nextMp5 + 2.0; gain(17) end
    for i = 1, 4 do
        if t >= phase[i] then phase[i] = phase[i] + 3.0; gain(13 + ((i + math.floor(t)) % 3)) end
    end
end
S.Tick(0.5)

check("histogram printed", found("tick histogram") ~= nil)
check("spirit tick named", found("138 x .* the reported spirit tick") ~= nil)

local mp5line = found("   17 x .* 2s beat")
check("constant 17 read as a 2s beat", mp5line ~= nil)
-- 17 per 2.00s is 42.5 mp5; the line must carry the mp5, not the raw size,
-- because that is the number the author compares with the character sheet.
check("2s beat converted to mp5", mp5line ~= nil and mp5line:find("43 mp5") ~= nil, mp5line)

local partyline = found("13%-15 x")
check("13-15 clustered into one row", partyline ~= nil, partyline)
check("party energize read as a 3s beat",
    partyline ~= nil and partyline:find("3s beat") ~= nil and partyline:find("not yours") ~= nil, partyline)
-- 4 phases x ~10 ticks: every one of them must be in the cluster
check("cluster keeps every event", partyline ~= nil and tonumber(partyline:match("x (%d+)")) >= 36,
    partyline and partyline:match("x %d+"))

--------------------------------------------------------------------------------
-- 1b. v0.9.0: a clean window STORES the beat, and the model starts adding it
--------------------------------------------------------------------------------
local m = MD.cdb.mp5
check("clean test stored cdb.mp5", m ~= nil, m and "stored" or "nothing stored")
-- 17 mana every 2.00s is 8.5/s; the estimator drops one tick per stream to keep
-- the window's edges out, so it lands within a few hundredths of it
check("stored value is the leftover, not the tick", m ~= nil and m.mp5 == 43 and math.abs(m.perSec - 8.5) < 0.2,
    m and string.format("%d mp5, %.2f/s", m.mp5 or -1, m.perSec or -1) or "-")
check("the party stream was not measured in", m ~= nil and (m.party or 0) > 10,
    m and string.format("party %.1f/s of the observed %.1f/s", m.party or -1, m.observed or -1) or "-")
check("stored with its provenance", m ~= nil and m.source == "regentest" and m.at and m.ticks >= 5
    and m.level == S.level, m and string.format("%s, %d beats, level %d", tostring(m.source), m.ticks or -1, m.level or -1) or "-")
check("chat line says stored, and what it replaced", found("stored 43 mp5") ~= nil and found("was: none") ~= nil,
    found("stored 43") or "no line")

local RM = MD.Regen
check("RM:MeasuredMp5 returns it", math.abs(RM:MeasuredMp5() - 8.5) < 0.2, string.format("%.2f/s", RM:MeasuredMp5()))
-- the harness build has no Dreamstate, so the whole unreported term is this
RM:Refresh()
check("the model adds it to both rates",
    math.abs(RM.base - (RM.apiBase + 8.5)) < 0.2 and math.abs(RM.casting - (RM.apiCasting + 8.5)) < 0.2,
    string.format("base %.2f (api %.2f), casting %.2f (api %.2f)", RM.base, RM.apiBase, RM.casting, RM.apiCasting))
check("a new recording carries it as energize", (function()
    MD.FightRecorder:Start(S.now)
    local e = MD.FightRecorder.active and MD.FightRecorder.active.initial.energize
    MD.FightRecorder.active = nil
    return e ~= nil and math.abs(e - 8.5) < 0.2
end)())

--------------------------------------------------------------------------------
-- 1c. a DIRTY window does not store: a measurement taken through a cast is not
-- a measurement, and the old one is left exactly as it was
--------------------------------------------------------------------------------
out = {}
local before = MD.cdb.mp5
drainTo(100)
MD:RunRegenTest(20)
S.Tick(0.5)
local td = S.now
local nS, nM = 2.0, 2.6
while S.now - td < 20.5 do
    S.Tick(0.1)
    local t = S.now - td
    if t >= nS then nS = nS + 2.0; gain(138) end
    if t >= nM then nM = nM + 2.0; gain(17) end
    if math.abs(t - 8.0) < 0.05 then S.mana = S.mana - 400; S.Fire("UNIT_POWER_UPDATE", "player", "MANA") end
end
S.Tick(0.5)
check("dirty test refuses to store", found("not stored %- 400 mana was spent") ~= nil,
    found("not stored") or "no refusal line")
check("the old measurement is untouched", MD.cdb.mp5 == before and MD.cdb.mp5.mp5 == 43)

--------------------------------------------------------------------------------
-- 2. too few ticks to read a cadence: no false confidence, no error
--------------------------------------------------------------------------------
out = {}
drainTo(100)
MD:RunRegenTest(10)
S.Tick(0.5)
local t1 = S.now
while S.now - t1 < 10.5 do
    S.Tick(0.5)
    if math.abs((S.now - t1) - 3.0) < 0.01 then gain(999) end
end
S.Tick(0.5)
check("single odd tick reported honestly", found("999 x 1  .*too few") ~= nil, found("999 x") or "no line")
check("one odd tick is not a measurement", found("not stored") ~= nil, found("not stored") or "no refusal line")

--------------------------------------------------------------------------------
-- 3. THE BUG v0.9.5 FIXES. On a druid with Dreamstate there is only ONE tick:
-- the server folds the talent into the same regen tick, so the tick reads well
-- above the raw API rate. v0.9.0 called that "a 2s beat the API does not
-- report" and stored the WHOLE TICK -- 279 mp5 on a character regenerating 279,
-- modelled at 556. The leftover after the API and Dreamstate is what is stored,
-- and here it is zero.
--------------------------------------------------------------------------------
out = {}
MD.harnessTalents["Dreamstate"] = 3           -- 10% of 425 int / 5 = 8.50/s
local dsRate = 0.10 * S.stats[4] / 5
local tick = math.floor((69.24 + dsRate) * 2 + 0.5)   -- one tick, everything in it
drainTo(100)
MD:RunRegenTest(30)
S.Tick(0.5)
local t3 = S.now
local nextTick = 2.0
while S.now - t3 < 30.5 do
    S.Tick(0.1)
    if S.now - t3 >= nextTick then nextTick = nextTick + 2.0; gain(tick) end
end
S.Tick(0.5)

check("the one true tick is not called an unreported beat",
    found("the regen tick the model expects") ~= nil, found("x 15") or "no histogram row")
check("the leftover is zero, so nothing is stored", found("nothing to store") ~= nil,
    found("stored") or found("not stored") or "no line")
check("and the earlier measurement is cleared", MD.cdb.mp5 == nil and found("cleared") ~= nil,
    MD.cdb.mp5 and (MD.cdb.mp5.mp5 .. " mp5 still stored") or (found("cleared") or "no clear line"))
RM:Refresh()
check("the model is the API plus Dreamstate, nothing more",
    math.abs(RM.base - (RM.apiBase + dsRate)) < 0.01,
    string.format("base %.2f vs api %.2f + ds %.2f", RM.base, RM.apiBase, dsRate))

--------------------------------------------------------------------------------
-- 4. a database written before the fix cannot keep lying
--------------------------------------------------------------------------------
out = {}
-- the author's real database held 279 mp5 against a 244 mp5 API rate; the stub
-- reports more than that, so the same relationship needs a bigger number here
MD.cdb.mp5 = { perSec = 75.0, mp5 = 375, at = time(), source = "regentest" }
check("a stored value bigger than the API is refused", RM:MeasuredMp5() == 0,
    string.format("%.2f/s", RM:MeasuredMp5()))
check("and it says so once", found("larger than everything the client reports") ~= nil,
    found("larger than") or "no warning")
RM:Refresh()
check("so the clock is not inflated by it", math.abs(RM.base - (RM.apiBase + dsRate)) < 0.01,
    string.format("base %.2f", RM.base))
out = {}
MD:ClearMeasuredMp5()
check("/md regentest clear forgets it", MD.cdb.mp5 == nil and found("cleared") ~= nil,
    found("cleared") or "no line")
MD.harnessTalents["Dreamstate"] = 0

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
