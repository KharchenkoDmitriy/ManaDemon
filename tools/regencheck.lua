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

--------------------------------------------------------------------------------
-- 1. the BF-1 shape
--------------------------------------------------------------------------------
S.mana = 100
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
-- 2. too few ticks to read a cadence: no false confidence, no error
--------------------------------------------------------------------------------
out = {}
S.mana = 100
MD:RunRegenTest(10)
S.Tick(0.5)
local t1 = S.now
while S.now - t1 < 10.5 do
    S.Tick(0.5)
    if math.abs((S.now - t1) - 3.0) < 0.01 then gain(999) end
end
S.Tick(0.5)
check("single odd tick reported honestly", found("999 x 1  .*too few") ~= nil, found("999 x") or "no line")

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
