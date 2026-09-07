-- tools/run.sh tools/navui.lua
--
-- The navigation kit (docs/SPEC-v0.11.md §3) under the stub: groups down the
-- left, that group's views along the top, panes built lazily and cached, the
-- selection remembered. It is the piece every other window is about to be
-- rebuilt on, so it gets its own suite before anything moves.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
S.Load({ "UI/Style.lua" }, "ManaDemon", MD)
local UI = MD.UI

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-46s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local built, selections = {}, {}
local groups = {
    { id = "spells", text = "Spells", views = {
        { id = "ht", text = "Healing Touch" }, { id = "rg", text = "Regrowth" } } },
    { id = "reports", text = "Reports", views = {
        { id = "waste", text = "Waste" }, { id = "review", text = "Review" } } },
    { id = "settings", text = "Settings", views = { { id = "general", text = "General" } } },
}
local shows = {}
local nav = UI.CreateNavFrame("ManaDemon", "MDNavTest", 900, 600, groups,
    function(g, v, content)
        local key = g .. ":" .. tostring(v)
        built[key] = (built[key] or 0) + 1
        local pane = CreateFrame("Frame", nil, content)
        pane.key = key
        return pane
    end,
    function(g, v)
        selections[#selections + 1] = g .. "/" .. tostring(v)
        local key = g .. ":" .. tostring(v)
        shows[key] = (shows[key] or 0) + 1
    end)

check("a nav frame is created", nav ~= nil and nav.frame ~= nil)
check("one button per group", #nav.buttons == 3, tostring(#nav.buttons))
check("nothing is selected before it is asked", nav.group == nil and nav.view == nil)

nav:Select("spells")
local g, v = nav:Selected()
check("selecting a group takes its first view", g == "spells" and v == "ht", tostring(g) .. "/" .. tostring(v))
check("the view row is that group's", #nav.viewButtons == 2, tostring(#nav.viewButtons))
check("the pane was built once", built["spells:ht"] == 1)

nav:Select("spells", "rg")
check("selecting a view keeps the group", nav.group == "spells" and nav.view == "rg")
check("its pane is built too", built["spells:rg"] == 1)

nav:Select("spells", "ht")
check("going back does not rebuild the pane", built["spells:ht"] == 1, tostring(built["spells:ht"]))
check("but it is shown again, so it can refresh", shows["spells:ht"] == 2,
    tostring(shows["spells:ht"]))

nav:Select("reports")
check("the view row follows the group", #nav.viewButtons == 2 and nav.view == "waste",
    tostring(nav.view))
check("a group's panes are not built until it is opened", built["reports:review"] == nil)
nav:Select("reports", "review")
check("and then they are", built["reports:review"] == 1)

-- one pane visible at a time, and it is the selected one
local function shownKeys()
    local out = {}
    for _, panes in pairs(nav.panes or {}) do
        for _, pane in pairs(panes) do if pane:IsShown() then out[#out + 1] = pane.key end end
    end
    return out
end
local shown = shownKeys()
check("exactly one pane is shown", #shown == 1 and shown[1] == "reports:review",
    table.concat(shown, ", "))

-- the path is remembered for the next session
check("the selection is written to the database", MD.db.uiPath ~= nil
    and MD.db.uiPath[1] == "reports" and MD.db.uiPath[2] == "review",
    MD.db.uiPath and table.concat(MD.db.uiPath, "/") or "nothing saved")

-- a group whose views change while the window is open
nav:SetViews("reports", { { id = "waste", text = "Waste" }, { id = "review", text = "Review" },
                          { id = "runs", text = "Runs" } })
check("views can change while it is open", #nav.viewButtons == 3, tostring(#nav.viewButtons))
nav:Select("reports", "runs")
check("and the new one selects", nav.view == "runs", tostring(nav.view))

-- a hidden view is not offered, and asking for it lands somewhere real
nav:SetViews("spells", { { id = "ht", text = "Healing Touch" },
                         { id = "sm", text = "Swiftmend", hidden = true } })
nav:Select("spells", "sm")
check("a hidden view is refused, not shown", nav.view == "ht", tostring(nav.view))
check("hidden views get no button", #nav.viewButtons == 1, tostring(#nav.viewButtons))

-- an unknown group falls back rather than erroring
nav:Select("nosuchgroup")
check("an unknown group falls back to the first", nav.group == "spells", tostring(nav.group))

--------------------------------------------------------------------------------
-- the level-3 box: the same rule inside a pane
--------------------------------------------------------------------------------
local boxSel = {}
local box = UI.CreateNavBox(nav:Content(), 400, 200, {
    { id = "a", text = "Alpha", views = { { id = "one", text = "One" }, { id = "two", text = "Two" } } },
    { id = "b", text = "Beta", views = { { id = "three", text = "Three" } } },
}, function(g2, v2) boxSel[#boxSel + 1] = g2 .. "/" .. tostring(v2) end)
check("a nav box is created", box ~= nil and box.frame ~= nil)
box:Select("a")
check("the box selects its first view", boxSel[#boxSel] == "a/one", boxSel[#boxSel])
box:Select("b")
check("the box switches groups", boxSel[#boxSel] == "b/three", boxSel[#boxSel])
check("the box has its own content frame", box:Content() ~= nav:Content())

-- palette: one place decides
check("there is a single palette", UI.PALETTE ~= nil and UI.PALETTE.frame and UI.PALETTE.header)

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
