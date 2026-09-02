-- ManaDemon: mana dynamics, time-to-OOM prediction and healing rank analysis
-- for TBC healers. Core: namespace, saved variables, event/tick dispatch,
-- profile & talent scanning, slash commands.
local ADDON_NAME, MD = ...
_G.ManaDemon = MD

do
    local ok, v = pcall(GetAddOnMetadata, ADDON_NAME, "Version")
    MD.version = (ok and v) or "dev"
end

local DEFAULTS = {
    pos = { "CENTER", "CENTER", 0, -140 }, -- point, relativePoint, x, y
    locked = true,
    muted = false,
    halfLife = 15,        -- seconds; half-life of the spend-rate EWMA
    drinkReminder = true,
    showRest = true,      -- "rest 2:10" segment: time to full if you stop casting
    firstRun = true,
    minimap = { hide = false, angle = 220 },
    char = {},
}

--------------------------------------------------------------------------------
-- Event dispatch
--------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

-- Register a handler; events unknown to this client are silently skipped.
function MD:On(event, fn)
    if not handlers[event] then
        local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then return end
        handlers[event] = {}
    end
    handlers[event][#handlers[event] + 1] = fn
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        list[i](...)
    end
end)

-- Internal pub/sub (module-to-module, not Blizzard events).
local callbacks = {}
function MD:RegisterCallback(name, fn)
    callbacks[name] = callbacks[name] or {}
    callbacks[name][#callbacks[name] + 1] = fn
end
function MD:Fire(name, ...)
    local list = callbacks[name]
    if not list then return end
    for i = 1, #list do
        list[i](...)
    end
end

--------------------------------------------------------------------------------
-- Master ticker: the model is event-driven; this drives accumulation/rendering.
--------------------------------------------------------------------------------
local tickers = {}
function MD:OnTick(fn)
    tickers[#tickers + 1] = fn
end

local TICK = 0.5
C_Timer.NewTicker(TICK, function()
    for i = 1, #tickers do
        tickers[i](TICK)
    end
end)

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------
function MD:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ffManaDemon:|r " .. tostring(msg))
end

-- Alert respects /md mute and pulses the widget if present.
function MD:Alert(msg)
    if MD.db and MD.db.muted then return end
    MD:Print(msg)
    if MD.PulseWidget then MD:PulseWidget() end
end

--------------------------------------------------------------------------------
-- Player profile
--------------------------------------------------------------------------------
MD.player = { class = "UNKNOWN", level = 0, isDruid = false, guid = "", charKey = "?" }

function MD:DetectProfile()
    local _, class = UnitClass("player")
    MD.player.class = class or "UNKNOWN"
    MD.player.isDruid = class == "DRUID"
    MD.player.level = UnitLevel("player") or 0
    MD.player.guid = UnitGUID("player") or ""
    MD.player.charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    -- Druids are checked at login (caster form); cat/bear later doesn't change
    -- that mana is their healing resource.
    MD.player.usesMana = UnitPowerType("player") == 0
end

-- Buff scan by name; tolerates both the classic UnitBuff API and C_UnitAuras.
function MD:HasBuff(matchName)
    if not matchName then return false end
    if UnitBuff then
        for i = 1, 40 do
            local name = UnitBuff("player", i)
            if not name then break end
            if name == matchName then return true end
        end
    elseif C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            if aura.name == matchName then return true end
        end
    end
    return false
end

local TREE_OF_LIFE = GetSpellInfo(33891)
function MD:InTreeForm()
    return MD.player.isDruid and MD:HasBuff(TREE_OF_LIFE)
end

--------------------------------------------------------------------------------
-- Talents: scanned by NAME across all tabs so positional index shifts between
-- client builds can't silently return the wrong talent.
--------------------------------------------------------------------------------
MD.talents = {}

function MD:ScanTalents()
    wipe(MD.talents)
    if not GetNumTalentTabs then return end
    for tab = 1, GetNumTalentTabs() do
        for i = 1, GetNumTalents(tab) do
            local name, _, _, _, rank = GetTalentInfo(tab, i)
            if name then
                MD.talents[name] = rank or 0
            end
        end
    end
    MD:Fire("TALENTS_CHANGED")
end

function MD:TalentRank(name)
    return MD.talents[name] or 0
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------
local function InitDB()
    ManaDemonDB = ManaDemonDB or {}
    for k, v in pairs(DEFAULTS) do
        if ManaDemonDB[k] == nil then
            if type(v) == "table" then
                local copy = {}
                for k2, v2 in pairs(v) do copy[k2] = v2 end
                ManaDemonDB[k] = copy
            else
                ManaDemonDB[k] = v
            end
        end
    end
    MD.db = ManaDemonDB
    MD.db.char[MD.player.charKey] = MD.db.char[MD.player.charKey] or {}
    MD.cdb = MD.db.char[MD.player.charKey]
end

MD:On("PLAYER_LOGIN", function()
    MD:DetectProfile()
    InitDB()
    MD:ScanTalents()
    MD:Fire("MD_READY")

    if MD.db.firstRun then
        MD.db.firstRun = false
        MD:Print("first run — the widget is unlocked for 60s so you can drag it. |cffffff00/md lock|r when done, |cffffff00/md help|r for commands.")
        if MD.ForceWidgetPreview then MD:ForceWidgetPreview(60) end
    end
end)

MD:On("CHARACTER_POINTS_CHANGED", function() MD:ScanTalents() end)
MD:On("PLAYER_TALENT_UPDATE", function() MD:ScanTalents() end)
MD:On("PLAYER_LEVEL_UP", function(level)
    MD.player.level = tonumber(level) or UnitLevel("player") or MD.player.level
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------
local function ShowHelp()
    MD:Print("commands:")
    MD:Print("  |cffffff00/md|r — toggle the rank dashboard")
    MD:Print("  |cffffff00/md lock|r / |cffffff00unlock|r — lock / unlock (drag) the widget")
    MD:Print("  |cffffff00/md reset|r — reset the widget position")
    MD:Print("  |cffffff00/md mute|r — toggle alert messages")
    MD:Print("  |cffffff00/md drink|r — toggle the drink reminder")
    MD:Print("  |cffffff00/md rest|r — toggle the 'rest' segment (time to full if you stop casting)")
    MD:Print("  |cffffff00/md window N|r — spend estimator half-life in seconds (default 15)")
    MD:Print("  |cffffff00/md verify|r — check static spell data against the live client")
    MD:Print("  |cffffff00/md fsrtest|r — log mana ticks for 15s (five-second-rule anchor test)")
end

SLASH_MANADEMON1 = "/manademon"
SLASH_MANADEMON2 = "/md"
SlashCmdList.MANADEMON = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.*)$")
    if cmd == "" then
        if MD.ToggleDashboard then MD:ToggleDashboard() end
    elseif cmd == "help" then
        ShowHelp()
    elseif cmd == "lock" then
        MD.db.locked = true
        if MD.UpdateVisibility then MD:UpdateVisibility() end
        MD:Print("widget locked.")
    elseif cmd == "unlock" then
        MD.db.locked = false
        if MD.UpdateVisibility then MD:UpdateVisibility() end
        MD:Print("widget unlocked — drag it, then /md lock.")
    elseif cmd == "reset" then
        MD.db.pos = { DEFAULTS.pos[1], DEFAULTS.pos[2], DEFAULTS.pos[3], DEFAULTS.pos[4] }
        if MD.ApplyWidgetPosition then MD:ApplyWidgetPosition() end
        MD:Print("widget position reset.")
    elseif cmd == "mute" then
        MD.db.muted = not MD.db.muted
        MD:Print("alerts " .. (MD.db.muted and "muted." or "unmuted."))
    elseif cmd == "drink" then
        MD.db.drinkReminder = not MD.db.drinkReminder
        MD:Print("drink reminder " .. (MD.db.drinkReminder and "on." or "off."))
    elseif cmd == "rest" then
        MD.db.showRest = not MD.db.showRest
        MD:Print("rest segment " .. (MD.db.showRest and "on." or "off."))
    elseif cmd == "window" then
        local n = tonumber(arg)
        if n and n >= 5 and n <= 60 then
            MD.db.halfLife = n
            MD:Print("spend half-life set to " .. n .. "s.")
        else
            MD:Print("usage: /md window N (5–60 seconds)")
        end
    elseif cmd == "verify" then
        if MD.RunVerify then MD:RunVerify() end
    elseif cmd == "fsrtest" then
        if MD.RunFSRTest then MD:RunFSRTest() end
    else
        ShowHelp()
    end
end
