-- Group roster: who is that heal landing on? GUID -> name, class, role and --
-- as important as the role itself -- WHERE the role came from, so a report can
-- never present a guessed role like a read one.
--
-- Role is READ, not inferred. On this client UnitGroupRolesAssigned() returns
-- the role a player selected (Cell's TBC build draws its role icon from it,
-- enabled by default), which also settles feral druids outright: a talent
-- reading cannot tell a bear from a cat, the player's own selection can.
-- Source order:
--   assigned     UnitGroupRolesAssigned(unit)          the player's selection
--   partyassign  GetPartyAssignment MAINTANK/MAINASSIST raid-side signal
--   class        Mage / Warlock / Rogue / Hunter        only one option
--   unknown      everything else                        reported as such
-- How often "unknown" actually happens in the author's groups is not known
-- yet; the roster debug line at each pull is what will tell us
-- (docs/DESIGN-v0.6.md §5.1).
local _, MD = ...

local Targets = {}
MD.Targets = Targets

Targets.byGUID = {}   -- guid -> { name, class, role, roleSource, unit, isPet, owner }
Targets.byName = {}   -- name -> same table (fallback when a GUID is unknown)

local CLASS_ROLE = { MAGE = "DAMAGER", WARLOCK = "DAMAGER", ROGUE = "DAMAGER", HUNTER = "DAMAGER" }

local function AssignedRole(unit)
    if not UnitGroupRolesAssigned then return nil end
    local ok, role = pcall(UnitGroupRolesAssigned, unit)
    if ok and role and role ~= "NONE" then return role end
    return nil
end

local function PartyAssignmentRole(unit)
    if not GetPartyAssignment then return nil end
    local ok, mt = pcall(GetPartyAssignment, "MAINTANK", unit)
    if ok and mt then return "TANK" end
    local ok2, ma = pcall(GetPartyAssignment, "MAINASSIST", unit)
    if ok2 and ma then return "DAMAGER" end
    return nil
end

local function Describe(unit)
    local guid = UnitGUID(unit)
    if not guid then return nil end
    local name = UnitName(unit)
    local _, class = UnitClass(unit)
    class = class or "UNKNOWN"

    local role, source = AssignedRole(unit), "assigned"
    if not role then role, source = PartyAssignmentRole(unit), "partyassign" end
    if not role then role, source = CLASS_ROLE[class], "class" end
    if not role then role, source = "UNKNOWN", "unknown" end

    return { guid = guid, name = name or "?", class = class, role = role, roleSource = source, unit = unit }
end

local function AddPet(petUnit, owner)
    local guid = UnitGUID(petUnit)
    if not guid or not owner then return end
    local e = { guid = guid, name = UnitName(petUnit) or "pet", class = "PET", isPet = true,
                owner = owner.name, role = owner.role, roleSource = owner.roleSource, unit = petUnit }
    Targets.byGUID[guid] = e
    Targets.byName[e.name] = Targets.byName[e.name] or e
end

function Targets:Rebuild()
    wipe(Targets.byGUID)
    wipe(Targets.byName)

    local me = Describe("player")
    if me then
        Targets.byGUID[me.guid] = me
        Targets.byName[me.name] = me
        if UnitExists("pet") then AddPet("pet", me) end
    end

    if IsInRaid and IsInRaid() then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 40) do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local e = Describe(unit)
                if e then
                    Targets.byGUID[e.guid] = e
                    Targets.byName[e.name] = e
                    if UnitExists("raidpet" .. i) then AddPet("raidpet" .. i, e) end
                end
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local e = Describe(unit)
                if e then
                    Targets.byGUID[e.guid] = e
                    Targets.byName[e.name] = e
                    if UnitExists("partypet" .. i) then AddPet("partypet" .. i, e) end
                end
            end
        end
    end
    MD:Fire("ROSTER_CHANGED")
end

-- Roster entry for a combat-log destination, or nil for anything outside the
-- group (a stranger, an NPC). Name is the fallback for a GUID seen before the
-- roster was built.
function Targets:Lookup(guid, name)
    local e = guid and Targets.byGUID[guid]
    if not e and name then e = Targets.byName[name] end
    return e
end

-- A warlock who Life Taps makes room for a HoT on purpose; overheal on them
-- is partly the plan working. Counted from the combat log per session, so the
-- Waste view can say "Life Tap x12" next to the name instead of assuming.
Targets.lifeTaps = {}   -- guid -> count (session)
local LIFE_TAP = GetSpellInfo(1454) or "Life Tap"

function Targets:NoteCast(sourceGUID, spellName)
    if spellName == LIFE_TAP and sourceGUID then
        Targets.lifeTaps[sourceGUID] = (Targets.lifeTaps[sourceGUID] or 0) + 1
    end
end

function Targets:LifeTaps(guid)
    return guid and Targets.lifeTaps[guid] or 0
end

function Targets:IsSelf(guid)
    return guid ~= nil and guid == MD.player.guid
end

-- One line for the debug log at each pull. This is the line that will tell
-- whether roles are actually being assigned in the author's groups.
function Targets:RosterLine()
    local parts = {}
    local order = {}
    for _, e in pairs(Targets.byGUID) do
        if not e.isPet then order[#order + 1] = e end
    end
    table.sort(order, function(a, b)
        if a.guid == MD.player.guid then return true end
        if b.guid == MD.player.guid then return false end
        return a.name < b.name
    end)
    for _, e in ipairs(order) do
        parts[#parts + 1] = string.format("%s %s %s(%s)", e.name, e.class, e.role, e.roleSource)
    end
    return #parts > 0 and table.concat(parts, ", ") or "(solo)"
end

-- Lines for /md export.
function Targets:ExportRows()
    local out = {}
    for _, e in pairs(Targets.byGUID) do
        out[#out + 1] = table.concat({ e.name, e.class, e.role, e.roleSource, e.isPet and "pet" or "player" }, "\t")
    end
    table.sort(out)
    return out
end

MD:On("GROUP_ROSTER_UPDATE", function() if MD.db then Targets:Rebuild() end end)
MD:On("PLAYER_ENTERING_WORLD", function() if MD.db then Targets:Rebuild() end end)
MD:On("UNIT_PET", function(unit) if MD.db then Targets:Rebuild() end end)
MD:RegisterCallback("MD_READY", function() Targets:Rebuild() end)
