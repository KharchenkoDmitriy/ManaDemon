local here = arg[0]:match("^(.*)/[^/]+$")
local p = io.popen('ls "/mnt/e/Blizzard/World of Warcraft/_anniversary_/WTF/Account"/*/SavedVariables/ManaDemon.lua 2>/dev/null')
local file = p and p:read("*l"); if p then p:close() end
dofile(file)
local realDB = _G.ManaDemonDB
local pre = {}
for k, c in pairs(realDB.char or {}) do pre[k] = { profile = c.profile, mp5 = c.mp5 } end
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local key
for k, c in pairs(realDB.char or {}) do if #(c.recordings or {}) > 0 then key = k end end
MD.cdb = realDB.char[key]
local pr = pre[key].profile
MD.cdb.profile, MD.cdb.mp5 = pr, pre[key].mp5
S.level, S.stats[4], S.stats[5], S.manaMax = pr.level, pr.intellect, pr.spirit, pr.manaMax
_G.GetSpellBonusHealing = function() return pr.healing end
_G.GetSpellCritChance = function() return pr.crit end
local T = pr.talents
function MD:TalentRank(n) return T[n] or 0 end
function MD:InTreeForm() return pr.form == "tree" end
MD.Regen:Refresh()

local SM, SP = MD.SimModel, MD.SimPlanner
local rec = MD.FightRecorder:Get(1)
local kit = MD.RankMath:SpellKit()
local sc = SM.ScenarioFromRecording(rec, kit)
local binds = SP.BindsFromRecording(rec, kit)
local SD = MD.SpellData
local function try(name, params)
  local plan = SP.NewPlan(binds, params, kit)
  local casts = {}
  local r = SP.RunPlan(sc, plan, { critMode = "ev", onCast = function(_, t, id)
      local sd = SD.spells[id]
      casts[#casts+1] = string.format("%.0fs %s", t, sd and (sd.family:sub(1, 4) .. sd.rank) or tostring(id)) end })
  local owed = SP.ManaOwed(r, plan)
  print(string.format("%-24s spent %5d  owed %4.0f  total %5.0f  endDef %5.0f  lowest %3.0f%%  casts: %s",
    name, r.manaSpent, owed, r.manaSpent + owed, r.endDeficit or -1, r.lowest.hp * 100,
    #casts > 0 and table.concat(casts, " ") or "none"))
end
try("hotBelow .6", { swiftmendBelow=0.30, directBelow=0.45, rollStacks=0, hotBelow=0.60, filler=false })
try("hotBelow .8", { swiftmendBelow=0.30, directBelow=0.45, rollStacks=0, hotBelow=0.80, filler=false })
try("hotBelow .9", { swiftmendBelow=0.30, directBelow=0.45, rollStacks=0, hotBelow=0.90, filler=false })
try("hotBelow 1.0", { swiftmendBelow=0.30, directBelow=0.45, rollStacks=0, hotBelow=1.00, filler=false })
try("roll 3 hot .9", { swiftmendBelow=0.30, directBelow=0.45, rollStacks=3, hotBelow=0.90, filler=false })
