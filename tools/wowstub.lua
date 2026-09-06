-- Minimal WoW-client stub: just enough of the API for the non-UI half of
-- ManaDemon to load and run outside the game, so Engine/SimModel.lua can be
-- exercised without logging in. Values mirror the BF-1 log's druid (level 64,
-- 7009 mana pool) so the numbers mean something.
--
-- This is NOT a fake client. It answers the handful of calls the engine path
-- makes and nothing else: anything it gets wrong shows up as a failing
-- assertion, not as a silently different answer. Rules it deliberately keeps:
--   * GetSpellPowerCost returns nil, so costs come from Data/SpellData.lua's
--     static table and the talent maths -- deterministic, and it exercises the
--     fallback path the live client normally hides.
--   * Frames only register events and run OnUpdate; nothing draws.
-- Run it with tools/run.sh (which builds a Lua 5.1 for you if there is none).
local S = {}
_G.STUB = S

S.now = 0
function GetTime() return S.now end
-- The sub-frame clock the search slices on. In the client this advances inside
-- a frame while GetTime() does not, which is the whole reason it is used.
function debugprofilestop() return os.clock() * 1000 end
function time() return 1757000000 end
function date(fmt, t) return os.date(fmt, t or 1757000000) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strsplit(sep, s) return s end
function GetAddOnMetadata()
    local f = io.open((S.root or ".") .. "/ManaDemon.toc", "r")
    if f then
        for line in f:lines() do local v = line:match("^## Version: (.+)$"); if v then f:close(); return v end end
        f:close()
    end
    return "0.0.0"
end
function GetLocale() return "enUS" end

S.mana, S.manaMax = 7009, 7009
S.stats = { [4] = 425, [5] = 380 } -- Int, Spirit
S.level = 64

-- Unit model. Only what the engine path reads: a token -> one table. Party
-- slots can be added by a harness script (see tools/reccheck.lua).
S.units = {
    player = { guid = "Player-1", name = "Penek", class = "DRUID", role = "HEALER",
               hp = 5000, hpMax = 5000 },
}
S.unitOrder = { "player" }
function S.AddUnit(token, t)
    S.units[token] = t
    S.unitOrder[#S.unitOrder + 1] = token
    return t
end
local function U(u) return S.units[u] end

function UnitPower(u, t) return S.mana end
function UnitPowerMax(u, t) return S.manaMax end
function UnitPowerType(u) return 0 end
function UnitHealth(u) local x = U(u); return x and x.hp or 0 end
function UnitHealthMax(u) local x = U(u); return x and x.hpMax or 1 end
function UnitGUID(u) local x = U(u); return x and x.guid or nil end
function UnitName(u) local x = U(u); return x and x.name or nil end
function UnitClass(u) local x = U(u); return x and x.class or "DRUID", x and x.class or "DRUID" end
function UnitLevel(u) return S.level end
function UnitStat(u, i) return S.stats[i] or 0, S.stats[i] or 0, 0, 0 end
function UnitExists(u) return U(u) ~= nil end
function UnitIsUnit(a, b) return a == b end
function UnitAffectingCombat() return false end
function UnitGroupRolesAssigned(u) local x = U(u); return x and x.role or "NONE" end
function GetPartyAssignment() return false end
function GetRealmName() return "Anniversary" end
function GetRealZoneText() return "Blood Furnace" end
function IsInRaid() return false end
function GetNumGroupMembers() return #S.unitOrder end
function GetRaidRosterInfo() return nil end
function InCombatLockdown() return false end
function UnitAura() return nil end

function GetManaRegen() return 69.24, 28.33 end
function GetSpellBonusHealing() return 450 end
function GetSpellCritChance() return 15 end
function GetInventoryItemID() return nil end
function GetItemInfo() return nil end
function GetSpellCooldown() return 0, 0, 1 end
-- Live costs: nil for the druid healing table (so Data/SpellData.lua's static
-- maths is exercised), a real answer for the spells that table does not know --
-- which is exactly the split the live client produces.
S.liveCosts = { [9885] = 445, [26992] = 400, [2782] = 135, [33891] = 332, [17116] = 0 }
function GetSpellPowerCost(id)
    local c = S.liveCosts[id]
    if c then return { { type = 0, cost = c } } end
    return nil
end
function IsSpellKnown(id) return S.known[id] == true end
function IsPlayerSpell(id) return S.known[id] == true end
function GetSpellTexture(id) return "Interface\\Icons\\Spell_" .. tostring(id) end
function GetSpellInfo(id)
    if type(id) == "number" then return S.spellNames[id] or ("Spell" .. id) end
    return nil
end
function GetNumTalentTabs() return 3 end
function GetNumTalents() return 0 end
function GetTalentInfo() return nil end
-- Scripted combat log: S.Combat(subevent, ...) sets the payload and fires the
-- event, exactly as the client would.
S.clog = { 0, "NONE" }
function CombatLogGetCurrentEventInfo() return unpack(S.clog, 1, S.clogN or #S.clog) end
function S.Combat(...)
    S.clog = { ... }
    S.clogN = select("#", ...)
    S.Fire("COMBAT_LOG_EVENT_UNFILTERED")
end
function GetWeaponEnchantInfo() return false end
function IsUsableSpell() return true end
function GetItemCount() return 0 end
function GetItemCooldown() return 0, 0 end
function GetContainerNumSlots() return 0 end
function GetContainerItemID() return nil end
_G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
function collectgarbage_count() return collectgarbage("count") end

S.spellNames = setmetatable({}, { __index = function(_, k) return "Spell" .. tostring(k) end })
S.known = {}

_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print(m) end }
_G.SlashCmdList = {}
_G.UIParent = nil   -- set to a frame once CreateFrame exists (below)
_G.C_Timer = {
    After = function(_, fn) S.timers = S.timers or {}; table.insert(S.timers, fn) end,
    NewTicker = function(period, fn)
        S.tickers = S.tickers or {}
        table.insert(S.tickers, { period = period, fn = fn, acc = 0 })
        return { Cancel = function() end }
    end,
}
_G.C_Spell = nil

-- Frames: only what the engine files touch (event registration and OnUpdate).
local frames = {}
local FrameMT = {}
FrameMT.__index = FrameMT
local function noop() end
-- Unknown METHODS are no-ops (WoW's are UpperCamelCase); unknown lowercase
-- keys are plain nil so a frame can carry state fields like any table.
setmetatable(FrameMT, { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
    return nil
end })
function FrameMT:RegisterEvent(e) self.events[e] = true end
function FrameMT:UnregisterEvent(e) self.events[e] = nil end
function FrameMT:SetScript(k, fn) self.scripts[k] = fn end
function FrameMT:GetScript(k) return self.scripts[k] end
function FrameMT:IsShown() return self.shown == true end
function FrameMT:IsVisible() return self.shown == true end
function FrameMT:Show() self.shown = true end
function FrameMT:Hide() self.shown = false end
function FrameMT:SetSize(w, h) self.w, self.h = w, h end
function FrameMT:SetWidth(w) self.w = w end
function FrameMT:SetHeight(h) self.h = h end
function FrameMT:GetWidth() return self.w or 100 end
function FrameMT:GetHeight() return self.h or 20 end
function FrameMT:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function FrameMT:GetFrameLevel() return 1 end
function FrameMT:GetScale() return 1 end
function FrameMT:GetEffectiveScale() return 1 end
function FrameMT:GetAlpha() return 1 end
function FrameMT:GetLeft() return 0 end
function FrameMT:GetRight() return self.w or 100 end
function FrameMT:GetTop() return self.h or 20 end
function FrameMT:GetBottom() return 0 end
-- Enough of a widget for the UI files to load and paint: font strings and
-- textures are frames too (every unknown method is a no-op), text and values
-- are stored so a harness can read back what was painted.
local function Child(kind)
    return setmetatable({ events = {}, scripts = {}, kind = kind }, FrameMT)
end
function FrameMT:CreateFontString() return Child("FontString") end
function FrameMT:CreateTexture() return Child("Texture") end
function FrameMT:GetFontString() self.fs = self.fs or Child("FontString"); return self.fs end
function FrameMT:SetText(t) self.text = t end
function FrameMT:GetText() return self.text or "" end
function FrameMT:GetStringWidth() return 40 end
function FrameMT:SetValue(v) self.value = v end
function FrameMT:GetValue() return self.value or 0 end
function FrameMT:SetMinMaxValues(a, b) self.minV, self.maxV = a, b end
function FrameMT:SetChecked(v) self.checked = v and true or false end
function FrameMT:GetChecked() return self.checked == true end
function FrameMT:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function FrameMT:SetBackdropBorderColor(r, g, b, a) self.border = { r, g, b, a } end
function FrameMT:SetStatusBarColor(r, g, b) self.barColor = { r, g, b } end
function FrameMT:SetTextColor(r, g, b) self.textColor = { r, g, b } end
_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
_G.tinsert = table.insert
_G.UISpecialFrames = {}
_G.PlaySound = noop
-- font objects are frames too; GetFont is the one call the kit makes at load
function FrameMT:GetFont() return "font", 12, "" end
function CreateFont() return Child("Font") end
_G.GameFontNormal = CreateFont()
_G.GameFontNormalSmall = CreateFont()
_G.GameFontHighlightSmall = CreateFont()
_G.RAID_CLASS_COLORS = {
    WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, DRUID = { r = 1, g = 0.49, b = 0.04 },
    MAGE = { r = 0.41, g = 0.8, b = 0.94 }, WARLOCK = { r = 0.58, g = 0.51, b = 0.79 },
    PALADIN = { r = 0.96, g = 0.55, b = 0.73 }, PRIEST = { r = 1, g = 1, b = 1 },
}

function CreateFrame(kind, name, parent, tmpl)
    local f = setmetatable({ events = {}, scripts = {}, kind = kind }, FrameMT)
    frames[#frames + 1] = f
    return f
end

_G.UIParent = CreateFrame("Frame")
_G.GameTooltip = CreateFrame("GameTooltip")

function S.Fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

function S.Tick(dt)
    S.now = S.now + dt
    for _, f in ipairs(frames) do
        if f.scripts.OnUpdate then f.scripts.OnUpdate(f, dt) end
    end
    for _, tk in ipairs(S.tickers or {}) do
        tk.acc = tk.acc + dt
        while tk.acc >= tk.period do tk.acc = tk.acc - tk.period; tk.fn() end
    end
end

function S.Load(files, addonName, MD)
    for _, rel in ipairs(files) do
        local path = S.root .. "/" .. rel
        local chunk, err = loadfile(path)
        if not chunk then error("load " .. rel .. ": " .. tostring(err)) end
        chunk(addonName, MD)
    end
end
