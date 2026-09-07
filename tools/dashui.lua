-- tools/run.sh tools/dashui.lua
--
-- The dashboard under the stub (docs/SPEC-v0.11.md §4, v0.11.1): the window is
-- now the navigation kit, so this drives it the way a mouse would -- click a
-- group, click a view, read back what was painted and which panes exist.
--
-- It also holds the line the spec draws under the move: /md must behave exactly
-- as it did, and a pane must not know it lives in a different window.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
S.Load({ "UI/Style.lua", "UI/Tooltip.lua", "UI/Dashboard_Rows.lua", "UI/Dashboard_Simulate.lua",
         "UI/Dashboard_Waste.lua", "UI/Dashboard_Review.lua", "UI/Dashboard.lua" }, "ManaDemon", MD)

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-48s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end
local chat = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }

-- the dashboard builds on MD_READY, which the harness already fired
S.Fire("PLAYER_LOGIN")
MD:Fire("MD_READY")

local frame = _G.ManaDemonDashboard
check("the dashboard exists", frame ~= nil)
check("it is one window, not two", frame ~= MD.optionsFrame)

local function ButtonNamed(text)
    for _, f in ipairs(S.allFrames) do
        if f.kind == "Button" and f.text == text and f.shown ~= false then return f end
    end
    return nil
end
local function Click(b) local fn = b and b:GetScript("OnClick"); if fn then fn(b) end end
local function Painted(pat)
    for _, f in ipairs(S.allFrames) do
        local t = f.GetText and f:GetText() or ""
        if type(t) == "string" and t:find(pat) then return t end
    end
    return nil
end

check("the four groups are the author's, minus the two still to move",
    ButtonNamed("Spells") ~= nil and ButtonNamed("Reports") ~= nil)

MD:ToggleDashboard()
check("it opens", frame:IsShown())

-- opening lands on a spell, and the rank table is built
check("it opens on a spell", MD.db.uiPath and MD.db.uiPath[1] == "spells",
    MD.db.uiPath and table.concat(MD.db.uiPath, "/") or "no path")
check("the rank table is built for it", Painted("HPM heal per mana") ~= nil)
check("the Simulate strip is with the spells", ButtonNamed("Clear") ~= nil)

-- switching families keeps the group
local rg = ButtonNamed("Regrowth")
check("a family button exists", rg ~= nil)
Click(rg)
check("clicking a family selects it", MD.db.uiPath[2] == "Regrowth", MD.db.uiPath[2])

-- Reports: a different group, its own views, built on first sight
Click(ButtonNamed("Reports"))
check("Reports selects its first view", MD.db.uiPath[1] == "reports" and MD.db.uiPath[2] == "Waste",
    table.concat(MD.db.uiPath, "/"))
check("the Waste pane says what it is", Painted("Where the mana went") ~= nil)
Click(ButtonNamed("Review"))
check("Review is a view of Reports", MD.db.uiPath[2] == "Review", MD.db.uiPath[2])
check("the Review pane is built", Painted("The fights this character recorded") ~= nil)
check("Review's own buttons came with it", ButtonNamed("Validate") ~= nil
    and ButtonNamed("Play") ~= nil and ButtonNamed("Start run") ~= nil)

-- back to a spell: the pane is not rebuilt, and the table is drawn again
Click(ButtonNamed("Spells"))
check("going back to Spells restores the rank table", Painted("HPM heal per mana") ~= nil)
check("and the path followed", MD.db.uiPath[1] == "spells", MD.db.uiPath[1])

-- the path is remembered across an open/close
MD:ToggleDashboard()
check("it closes", not frame:IsShown())
Click(ButtonNamed("Reports")); -- no-op while hidden, but must not error
MD:ToggleDashboard()
check("it reopens where it was", frame:IsShown() and MD.db.uiPath[1] ~= nil,
    table.concat(MD.db.uiPath, "/"))

-- no bare pipe anywhere it paints
local bad
for _, f in ipairs(S.allFrames) do
    local t = f.GetText and f:GetText() or ""
    if type(t) == "string" then
        local stripped = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if stripped:find("|", 1, true) then bad = bad or t end
    end
end
check("no bare pipe in any painted string", bad == nil, bad)

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
