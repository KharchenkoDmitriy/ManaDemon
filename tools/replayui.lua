-- tools/run.sh tools/replayui.lua
--
-- The replay WINDOW under the stub: loads UI/Style.lua, UI/Tooltip.lua and
-- UI/ReplayWindow.lua on top of the engine harness, opens the scripted pull,
-- plays it, seeks it, and reads back what was painted. The stub's frames are
-- permissive (unknown methods are no-ops) but they store text, values and
-- colours, which is enough to catch the class of bug that bit v0.7.6: a nil
-- index, a wrong argument order, a string with a bare pipe.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB

S.Load({ "UI/Style.lua", "UI/Tooltip.lua", "UI/ReplayWindow.lua" }, "ManaDemon", MD)

local ids = dofile(here .. "/fakepull.lua")(MD, S)
local SM, SP = MD.SimModel, MD.SimPlanner

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-38s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local rec = MD.FightRecorder:Get(1)
local kit = MD.RankMath:SpellKit()
-- the scripted pull fails validation on purpose (a death, 69% foreign healing);
-- let it through so the right column is exercised too
local realValidate = SM.Validate
function SM:Validate(...) local v = realValidate(self, ...); v.ok = true; return v end
SP.plans[rec.id] = SP.NewPlan(SP.MaxRankBinds(),
    { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false }, kit)

MD:OpenReplay(1)
local W = MD.Replay._state()
check("window shown", W.frame and W.frame:IsShown())
check("five rows", #W.rows == 5, tostring(#W.rows))
local roster = rec.roster
check("tank first", roster[W.rows[1]] and roster[W.rows[1]].role == "TANK", roster[W.rows[1]] and roster[W.rows[1]].role)
check("healer second", roster[W.rows[2]] and roster[W.rows[2]].role == "HEALER", roster[W.rows[2]] and roster[W.rows[2]].role)
check("right column built", W.right and W.right.state ~= nil and W.right.title:IsShown())
check("time text", W.timeFS:GetText():match("^0:00%.0 / 0:%d%d%.%d$") ~= nil, W.timeFS:GetText())

-- every painted string: no bare pipe (WoW would eat the text after it)
local function Pipes()
    local bad = {}
    local function scan(fs, label)
        local t = fs and fs.GetText and fs:GetText() or ""
        local stripped = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if stripped:find("|", 1, true) then bad[#bad + 1] = label .. ": " .. t end
    end
    for _, col in ipairs({ W.left, W.right }) do
        for ti, f in pairs(col.frames) do scan(f.name, "name"); scan(f.pct, "pct"); scan(f.cast, "cast") end
        scan(col.strip.score, "score"); scan(col.strip.castFS, "castbar"); scan(col.strip.wait, "wait")
    end
    scan(W.timeFS, "time")
    return bad
end

-- play through at 1x: one 0.1s frame at a time
MD.Replay._setPlaying(true)
local tankRow, lockRow, mageRow = W.rows[1], nil, nil
for _, ti in ipairs(W.rows) do
    if roster[ti].name == "Abufaisall" then lockRow = ti end
    if roster[ti].name == "Alkandari" then mageRow = ti end
end
local sawRegrowth, sawDamage, sawTwoK = false, false, false
local frames = 0
while MD.Replay._state().playing and frames < 2000 do
    S.Tick(0.1); frames = frames + 1
    local f = W.left.frames[tankRow]
    if f.cast:GetText():find("Regrowth") then sawRegrowth = true end
    -- the tank's hit is at t = 0 (initial state, never fires); the mage's is at 6.5s
    local m = mageRow and W.left.frames[mageRow]
    if m and m.pulse.color and m.pulse.color[4] > 0 then sawDamage = true end
end
check("played to the end", not MD.Replay._state().playing and W.left.state:AtEnd(), string.format("%d frames", frames))
check("cast text appeared on the tank", sawRegrowth)
check("damage pulse appeared on the mage", sawDamage)
check("the warlock reads dead", lockRow and W.left.frames[lockRow].pct:GetText() == "dead",
    lockRow and W.left.frames[lockRow].pct:GetText() or "no row")
local spent = W.left.state:Score()
check("strip spent == recording spent", spent == (rec.spent or 0), string.format("%d vs %d", spent, rec.spent or 0))
check("score line painted", W.left.strip.score:GetText():find("spent") ~= nil, W.left.strip.score:GetText())
local bad = Pipes()
check("no bare pipe in painted text", #bad == 0, bad[1])

-- seek back to the start: effects cleared, bars back
MD.Replay._seek(0)
check("seek clears the cast text", W.left.frames[tankRow].cast:GetText() == "")
check("seek resets the clock", W.timeFS:GetText():match("^0:00%.0") ~= nil, W.timeFS:GetText())
check("warlock alive again at 0", W.left.frames[lockRow].pct:GetText() ~= "dead", W.left.frames[lockRow].pct:GetText())

-- ticks: at a snapshot time the left tick is drawn, and never on the right
MD.Replay._seek(5.0)
local tick = W.left.frames[tankRow].tick
check("snapshot tick drawn on the left", tick.color and tick.color[4] > 0, tick.color and tostring(tick.color[4]))
check("no tick on the right", W.right.frames[tankRow].tick.color[4] == 0)

-- markers on the scrubber: the death, the casts
local shown = 0
for _, m in ipairs(W.scrubber.markers) do if m:IsShown() then shown = shown + 1 end end
check("scrubber markers placed", shown >= 7, tostring(shown))

-- the left-only path
SP.plans[rec.id] = nil
MD:OpenReplay(1)
W = MD.Replay._state()
check("left only without a plan", W.right.state == nil and not W.right.title:IsShown())
check("hint says to coach first", W.frame.hint:GetText():find("Coach") ~= nil, W.frame.hint:GetText())
check("narrower window", W.frame:GetWidth() < 400, tostring(W.frame:GetWidth()))

-- in combat: refuses
_G.UnitAffectingCombat = function() return true end
local before = W.frame:IsShown()
W.frame:Hide()
MD:OpenReplay(1)
check("refuses to open in combat", not MD.Replay._state().frame:IsShown())
_G.UnitAffectingCombat = function() return false end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
