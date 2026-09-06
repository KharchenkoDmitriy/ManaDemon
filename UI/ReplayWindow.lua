-- The replay window (docs/SPEC-v0.8.md 3): a recorded fight played back as two
-- columns of unit frames on one clock -- ACTUAL on the left (the recorded
-- casts through the engine), SUGGESTED on the right (the plan Coach found) --
-- with the recorder's real HP snapshots drawn as ticks on the left bars, so the
-- reconstruction's error is visible at every moment. Both columns are engine
-- output: the damage is identical by construction and every visible difference
-- is a healer decision.
--
-- This file only PAINTS. Everything it knows about a moment comes from
-- Engine/ReplayTrace.lua (`Seek`, `Advance`, `Hp`, `Hot`, `Casting`, ...); the
-- two states advance the same dt from the same OnUpdate, there is no per-column
-- clock. Nothing is interpolated: a heal is a jump and between grid points the
-- bar holds. The window never opens in combat, never runs the search (Play
-- shows what Coach found), and never touches the recorder.
local _, MD = ...
local UI = MD.UI

local COL_W, FRAME_H, FRAME_GAP = 300, 30, 4
local GUTTER = 12
local HEADER_H, STRIP_H, SCRUB_H = 24, 64, 56
local DT_STEP_MAX = 0.25       -- never advance more than this per frame at 1x (a hitch is not a skip)
local FLASH_CAST, FLASH_TEXT, FLASH_FOREIGN, PULSE_DMG = 0.8, 1.2, 0.4, 0.4
local TICK_FADE = 5            -- the recorder's snapshot cadence

-- Family colours, one table (spec 3.2). Utility and shifts are grey.
local FAMILY_COLOR = {
    Rejuvenation = { 0.72, 0.45, 0.95 }, Regrowth = { 0.35, 0.85, 0.35 }, Lifebloom = { 0.75, 0.90, 0.25 },
    HealingTouch = { 0.35, 0.60, 1.00 }, Swiftmend = { 1.00, 0.60, 0.20 }, Tranquility = { 0.30, 0.85, 0.85 },
    other = { 0.6, 0.6, 0.6 },
}
-- Label colours (spec 4.2): what the classifier said about each recorded cast,
-- shown under the cast text as it lands and on the scrubber's cast ticks.
local LABEL_COLOR = {
    late = { 1, 0.3, 0.3 }, overheal = { 1, 0.6, 0.2 }, early = { 1, 0.9, 0.3 }, stack = { 1, 0.9, 0.3 },
    spell = { 0.8, 0.8, 0.8 }, rank = { 0.8, 0.8, 0.8 }, fine = { 0.5, 0.5, 0.5 },
    unclassified = { 0.5, 0.5, 0.5 },
}
local LABEL_FLASH = 1.5
local HOT_SQ, HOT_GAP = 8, 2   -- the three HoT squares under the role letter
local SWIFTMEND = 18562
local ICON_DEBUFF, ICON_DEF, MAX_DEBUFF_ICONS = 14, 16, 3
local ROLE_LETTER = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }

local frame, scrubber, playBtn, timeFS, headerFS, speedHighlight
local left, right          -- the two columns: { state, frames = {}, strip = {}, title }
local rp                   -- the SP.Replay result being shown
local rows = {}            -- roster indices in display order
local playing, speed = false, 1
local classColorCache = {}

-- Show/Hide rather than SetShown: the older pair exists on every client this
-- addon targets, and a font string has no SetShown on some of them.
local function Shown(obj, on) if on then obj:Show() else obj:Hide() end end

local function ClassColor(class)
    local c = classColorCache[class]
    if c then return c end
    local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    c = cc and { cc.r, cc.g, cc.b } or { 0.6, 0.6, 0.6 }
    classColorCache[class] = c
    return c
end

local function SpellLabel(spellID)
    local sd = MD.SpellData.spells[spellID]
    if sd then
        local fam = MD.SpellData.families[sd.family]
        return string.format("%s R%d", fam and fam.label or sd.family, sd.rank), sd.family
    end
    local ok, name = pcall(GetSpellInfo, spellID)
    return (ok and name) or ("spell " .. tostring(spellID)), "other"
end

local function Clock(sec)
    if sec < 0 then sec = 0 end
    return string.format("%d:%04.1f", math.floor(sec / 60), sec % 60)
end

local function K(n)
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return string.format("%d", n + 0.5)
end

--------------------------------------------------------------------------------
-- Building one column
--------------------------------------------------------------------------------
local function CreateBar(parent, width, height)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width, height)
    bar:SetStatusBarTexture(UI.whiteTexture)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.06, 0.06, 1)
    bar.bg = bg
    return bar
end

local function CreateUnitFrame(parent, x, y)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(COL_W, FRAME_H)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    UI.StylizeFrame(f, { 0.1, 0.1, 0.1, 1 }, { 0, 0, 0, 1 })

    f.role = f:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.role:SetPoint("LEFT", f, "LEFT", 5, 0)
    f.role:SetWidth(12)
    f.role:SetJustifyH("LEFT")
    f.role:SetTextColor(0.7, 0.7, 0.7)

    f.name = f:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.name:SetPoint("LEFT", f, "LEFT", 42, 0)
    f.name:SetWidth(56)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)

    -- HoT squares (Rejuvenation, Regrowth, Lifebloom in SM.HOT_INDEX order),
    -- Cell-indicator style, and the Swiftmend-ready dot after them
    f.hots = {}
    for fi = 1, 3 do
        local sq = CreateFrame("Frame", nil, f, "BackdropTemplate")
        sq:SetSize(HOT_SQ, HOT_SQ)
        sq:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 5 + (fi - 1) * (HOT_SQ + HOT_GAP), 3)
        UI.StylizeFrame(sq, { 0.15, 0.15, 0.15, 1 }, { 0, 0, 0, 1 })
        sq.text = sq:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        sq.text:SetPoint("CENTER", sq, "CENTER", 0, 0)
        sq.text:SetText("")
        sq:Hide()
        f.hots[fi] = sq
    end
    f.dot = f:CreateTexture(nil, "OVERLAY")
    f.dot:SetSize(5, 5)
    f.dot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 5 + 3 * (HOT_SQ + HOT_GAP), 4)
    f.dot:SetColorTexture(1, 0.6, 0.2, 1)
    f.dot:Hide()

    -- v0.8.3: a defensive cooldown as one icon with the accent border, up
    -- front; up to three debuffs over the bar's right end, with their stacks.
    -- Recorded and drawn, never modelled -- the damage they changed was
    -- recorded as changed.
    local function Icon(size)
        local ic = CreateFrame("Frame", nil, f, "BackdropTemplate")
        ic:SetSize(size, size)
        UI.StylizeFrame(ic, { 0.2, 0.2, 0.2, 1 }, { 0, 0, 0, 1 })
        ic.tex = ic:CreateTexture(nil, "ARTWORK")
        ic.tex:SetPoint("TOPLEFT", ic, "TOPLEFT", 1, -1)
        ic.tex:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", -1, 1)
        ic.letter = ic:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        ic.letter:SetPoint("CENTER")
        ic.count = ic:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        ic.count:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 1, -1)
        ic:EnableMouse(true)
        ic:SetScript("OnEnter", function(self)
            if MD.Tip and self.tip then MD.Tip:Show(self, "ANCHOR_RIGHT", self.tip) end
        end)
        ic:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)
        ic:Hide()
        return ic
    end
    f.defIcon = Icon(ICON_DEF)
    f.defIcon:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -2)
    f.defIcon:SetBackdropBorderColor(UI.accent[1], UI.accent[2], UI.accent[3], 1)
    f.debuffs = {}
    for i = 1, MAX_DEBUFF_ICONS do
        local ic = Icon(ICON_DEBUFF)
        ic:SetPoint("RIGHT", f.bar, "RIGHT", -(i - 1) * (ICON_DEBUFF + 1) - 1, 0)
        f.debuffs[i] = ic
    end
    f.auraBuf = {}

    f.bar = CreateBar(f, COL_W - 100 - 42, FRAME_H - 10)
    f.bar:SetPoint("LEFT", f, "LEFT", 100, 0)

    -- the damage pulse: a red wash over the bar's empty part
    f.pulse = f.bar:CreateTexture(nil, "ARTWORK")
    f.pulse:SetAllPoints(f.bar)
    f.pulse:SetColorTexture(0.9, 0.15, 0.1, 0)

    -- the snapshot tick (left column only): the truth over the reconstruction
    f.tick = f.bar:CreateTexture(nil, "OVERLAY")
    f.tick:SetSize(1, FRAME_H - 10)
    f.tick:SetColorTexture(1, 1, 1, 0)
    f.tick:SetPoint("LEFT", f.bar, "LEFT", 0, 0)

    f.pct = f:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.pct:SetPoint("RIGHT", f, "RIGHT", -5, 0)
    f.pct:SetWidth(36)
    f.pct:SetJustifyH("RIGHT")

    -- the cast text, above the bar's right end, and the classifier's label
    -- under it (left column only)
    f.cast = f:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.cast:SetPoint("BOTTOMRIGHT", f.bar, "TOPRIGHT", 0, -1)
    f.cast:SetJustifyH("RIGHT")
    f.cast:SetText("")
    f.label = f:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.label:SetPoint("TOPRIGHT", f.bar, "BOTTOMRIGHT", 0, 1)
    f.label:SetJustifyH("RIGHT")
    f.label:SetText("")

    f.flashUntil, f.textUntil, f.labelUntil, f.pulseUntil, f.tickAt = 0, 0, 0, 0, nil
    return f
end

local function CreateStrip(parent, x, y)
    local s = {}
    s.mana = CreateBar(parent, COL_W - 60, 12)
    s.mana:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    s.mana:SetStatusBarColor(0.25, 0.45, 0.95)
    s.manaFS = s.mana:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    s.manaFS:SetPoint("CENTER")
    s.form = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    s.form:SetPoint("LEFT", s.mana, "RIGHT", 6, 0)
    s.form:SetTextColor(0.7, 0.7, 0.7)

    s.cast = CreateBar(parent, COL_W - 60, 12)
    s.cast:SetPoint("TOPLEFT", s.mana, "BOTTOMLEFT", 0, -4)
    s.cast:SetStatusBarColor(0.8, 0.8, 0.8)
    s.castFS = s.cast:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    s.castFS:SetPoint("LEFT", s.cast, "LEFT", 4, 0)
    s.castFS:SetJustifyH("LEFT")
    s.wait = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    s.wait:SetPoint("LEFT", s.cast, "RIGHT", 6, 0)
    s.wait:SetTextColor(0.6, 0.6, 0.6)
    -- the wait band: a grey wash over the cast bar while the plan holds
    s.band = s.cast:CreateTexture(nil, "ARTWORK")
    s.band:SetAllPoints(s.cast)
    s.band:SetColorTexture(0.5, 0.5, 0.5, 0)
    -- hovering the cast bar names the rule behind the current cast or wait
    s.cast:EnableMouse(true)
    s.cast:SetScript("OnEnter", function(self)
        if not (MD.Tip and s.why) then return end
        MD.Tip:Show(self, "ANCHOR_TOP", s.why)
    end)
    s.cast:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)

    s.score = parent:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    s.score:SetPoint("TOPLEFT", s.cast, "BOTTOMLEFT", 0, -4)
    s.score:SetJustifyH("LEFT")
    s.score:SetWidth(COL_W)
    s.flashUntil = 0
    return s
end

local function CreateColumn(x, titleText)
    local col = { frames = {}, x = x }
    col.title = frame:CreateFontString(nil, "OVERLAY", UI.FONT)
    col.title:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(HEADER_H + 4))
    col.title:SetText(titleText)
    col.strip = CreateStrip(frame, x, -(HEADER_H + 24))
    return col
end

--------------------------------------------------------------------------------
-- Visual events: what onEvent does with a crossed event. State is read from
-- the machine every frame; these only start the short-lived effects.
--------------------------------------------------------------------------------
local function MakeOnEvent(col)
    local RT, TK = MD.ReplayTrace, MD.SimModel.TK
    return function(kind, tgt, a, b, t)
        local now = GetTime()
        local f = tgt and col.frames[tgt]
        if kind == TK.CAST then
            local label, family = SpellLabel(a)
            if f then
                local c = FAMILY_COLOR[family] or FAMILY_COLOR.other
                f:SetBackdropBorderColor(c[1], c[2], c[3], 1)
                f.flashUntil = now + FLASH_CAST
                f.cast:SetText(label)
                f.cast:SetTextColor(c[1], c[2], c[3])
                f.textUntil = now + FLASH_TEXT
                -- the classifier's word for this cast (left column, plan present)
                local lc = col.state and col.state.lastCast
                local cl = col.isLeft and rp.casts and lc and rp.casts[lc.n]
                if cl and cl.label and cl.label ~= "utility" and cl.label ~= "shift" then
                    local lcol = LABEL_COLOR[cl.label] or LABEL_COLOR.unclassified
                    f.label:SetText(cl.label)
                    f.label:SetTextColor(lcol[1], lcol[2], lcol[3])
                    f.labelUntil = now + LABEL_FLASH
                end
            end
            col.strip.flashUntil = now + 0.3
            col.strip.lastCast = label
        elseif kind == RT.EV_DMG then
            if f then
                local maxHP = rp.scenario.targets[tgt] and rp.scenario.targets[tgt].maxHP or 1
                local frac = (a or 0) / maxHP
                if frac > 1 then frac = 1 end
                f.pulseAlpha = 0.25 + 0.6 * frac
                f.pulseUntil = now + PULSE_DMG
            end
        elseif kind == RT.EV_FHEAL then
            if f then
                f:SetBackdropBorderColor(1, 1, 1, 0.8)
                f.flashUntil = now + FLASH_FOREIGN
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Painting a moment
--------------------------------------------------------------------------------
local function AuraName(spellID)
    local d = MD.AuraList and MD.AuraList.Defensive(spellID)
    if d then return d[1] end
    local ok, name = pcall(GetSpellInfo, spellID)
    return (ok and name) or ("spell " .. tostring(spellID))
end

local function PaintIcon(ic, a, t, isDef)
    if ic.spellID ~= a.spellID then
        ic.spellID = a.spellID
        local ok, tex = pcall(GetSpellTexture, a.spellID)
        if ok and tex then
            ic.tex:SetTexture(tex)
            ic.letter:SetText("")
        else
            ic.tex:SetTexture(nil)
            ic.letter:SetText(AuraName(a.spellID):sub(1, 1))
        end
    end
    ic.count:SetText((a.stacks or 1) > 1 and tostring(a.stacks) or "")
    ic.tip = ic.tip or {}
    ic.tip[1] = { l = AuraName(a.spellID), r = isDef and "|cff888888defensive|r" or "|cff888888debuff|r" }
    ic.tip[2] = { l = string.format("applied at %s", Clock(a.since)), r = string.format("up %.0fs", t - a.since) }
    ic.tip[3] = (a.stacks or 1) > 1 and { l = string.format("%d stacks", a.stacks), r = "" } or nil
    ic:Show()
end

local function PaintFrame(f, st, ti, isLeft, now)
    local hp = st:Hp(ti)
    local dead = st:Dead(ti)
    if dead then
        f.bar:SetValue(0)
        f.pct:SetText("dead")
        f.pct:SetTextColor(0.5, 0.5, 0.5)
        f.name:SetTextColor(0.5, 0.5, 0.5)
    else
        f.bar:SetValue(hp or 0)
        f.pct:SetText(string.format("%d%%", (hp or 0) * 100 + 0.5))
        f.pct:SetTextColor(1, 1, 1)
        local c = f.classColor
        f.name:SetTextColor(c[1], c[2], c[3])
    end

    if f.flashUntil > now then
        -- keep the colour set by the event
    else
        f:SetBackdropBorderColor(0, 0, 0, 1)
    end
    if f.textUntil <= now and f.cast:GetText() ~= "" then f.cast:SetText("") end
    if f.labelUntil <= now and f.label:GetText() ~= "" then f.label:SetText("") end

    -- HoT squares: remaining seconds as one digit (nothing above 9), Lifebloom
    -- its stack count, brighter per stack and white in its last second (the
    -- bloom is coming). The dot: Swiftmend has something to eat and is ready.
    local HOT_INDEX = MD.SimModel.HOT_INDEX
    local eatable = false
    for fi = 1, 3 do
        local sq = f.hots[fi]
        local h = (not dead) and st:Hot(ti, fi) or nil
        if h then
            local fam = MD.SimModel.HOT_NAME[fi]
            local c = FAMILY_COLOR[fam] or FAMILY_COLOR.other
            if fi == HOT_INDEX.Lifebloom then
                local k = 0.45 + 0.25 * (h.stacks or 1)
                if h.remaining <= 1 then sq:SetBackdropColor(1, 1, 1, 1)
                else sq:SetBackdropColor(c[1] * k, c[2] * k, c[3] * k, 1) end
                sq.text:SetText(tostring(h.stacks or 1))
            else
                sq:SetBackdropColor(c[1], c[2], c[3], 1)
                local r = math.floor(h.remaining)
                sq.text:SetText(r <= 9 and tostring(r) or "")
                eatable = true
            end
            sq:Show()
        else
            sq:Hide()
        end
    end
    Shown(f.dot, eatable and st:Ready(SWIFTMEND))

    -- auras: the first defensive up front, the first three debuffs on the bar
    local auras = st:Auras(ti, f.auraBuf)
    local defShown, nDeb = false, 0
    for _, a in ipairs(auras) do
        if a.buff and not defShown then
            PaintIcon(f.defIcon, a, st.t, true)
            defShown = true
        elseif not a.buff and nDeb < MAX_DEBUFF_ICONS then
            nDeb = nDeb + 1
            PaintIcon(f.debuffs[nDeb], a, st.t, false)
        end
    end
    if not defShown then f.defIcon:Hide() end
    for i = nDeb + 1, MAX_DEBUFF_ICONS do f.debuffs[i]:Hide() end
    if f.pulseUntil > now then
        local left = (f.pulseUntil - now) / PULSE_DMG
        f.pulse:SetColorTexture(0.9, 0.15, 0.1, (f.pulseAlpha or 0.4) * left)
    else
        f.pulse:SetColorTexture(0.9, 0.15, 0.1, 0)
    end

    -- the snapshot tick: the latest recorded HP at or before t, fading until
    -- the next one is due
    if isLeft and MD.db.replayTicks and rp.ticks and rp.ticks.hp[ti] then
        local ts, col = rp.ticks.t, rp.ticks.hp[ti]
        local t = st.t
        local j = f.tickIdx or 1
        if j > 1 and ts[j - 1] and ts[j - 1] > t then j = 1 end       -- seeked backwards
        while ts[j + 1] and ts[j + 1] <= t do j = j + 1 end
        f.tickIdx = j
        local v = (ts[j] and ts[j] <= t) and col[j] or nil
        if v and v >= 0 and not dead then
            local age = t - ts[j]
            local alpha = 0.9 - 0.6 * (age / TICK_FADE)
            if alpha < 0.3 then alpha = 0.3 end
            f.tick:SetColorTexture(1, 1, 1, alpha)
            f.tick:ClearAllPoints()
            f.tick:SetPoint("LEFT", f.bar, "LEFT", v * f.bar:GetWidth(), 0)
        else
            f.tick:SetColorTexture(1, 1, 1, 0)
        end
    else
        f.tick:SetColorTexture(1, 1, 1, 0)
    end
end

local function PaintStrip(s, st, pool, now)
    local mana = st:Mana() or 0
    s.mana:SetValue(pool > 0 and mana / pool or 0)
    s.manaFS:SetText(string.format("%d", mana + 0.5))
    s.form:SetText(st:Form() == "tree" and "[tree]" or "[caster]")

    local c = st:Casting()
    if c then
        local label, family = SpellLabel(c.spellID)
        local frac = c.castTime > 0 and ((st.t - c.startedAt) / c.castTime) or 1
        if frac > 1 then frac = 1 end
        local fc = FAMILY_COLOR[family] or FAMILY_COLOR.other
        s.cast:SetStatusBarColor(fc[1], fc[2], fc[3])
        s.cast:SetValue(frac)
        local tgt = rp.rec.roster[c.target]
        s.castFS:SetText(label .. (tgt and (" -> " .. tgt.name) or ""))
    elseif s.flashUntil > now then
        s.cast:SetValue(1)
        s.castFS:SetText(s.lastCast or "")
    else
        s.cast:SetValue(0)
        s.castFS:SetText("")
    end
    local w = st:Waiting()
    s.wait:SetText(w and string.format("waiting %.1fs", w) or "")
    s.band:SetColorTexture(0.5, 0.5, 0.5, w and 0.35 or 0)

    -- the rule behind what the bar shows, for the hover (right column: the
    -- plan's reasons; left: none are on record)
    local why = (c and c.why) or (st.lastCast and st.lastCast.why) or 0
    if why and why > 0 and MD.SimPlanner.RULE_NAMES[why] then
        s.why = { { l = string.format("rule %d: %s", why, MD.SimPlanner.RULE_NAMES[why]), r = "" } }
    elseif w then
        s.why = { { l = "waiting: no rule fired", r = "" },
                  { l = "|cff888888nobody under a threshold, or nothing affordable|r", r = "" } }
    else
        s.why = nil
    end

    local spent, lowest, deaths = st:Score()
    s.score:SetText(string.format("spent %s   lowest %d%%   %s", K(spent), lowest * 100 + 0.5,
        deaths > 0 and string.format("|cffff5555%d dead|r", deaths) or "0 dead"))
end

local function Paint()
    if not rp then return end
    local now = GetTime()
    local pool = rp.scenario.pool or 1
    for _, ti in ipairs(rows) do
        PaintFrame(left.frames[ti], left.state, ti, true, now)
        if right and right.state then PaintFrame(right.frames[ti], right.state, ti, false, now) end
    end
    PaintStrip(left.strip, left.state, pool, now)
    if right and right.state then PaintStrip(right.strip, right.state, pool, now) end
    timeFS:SetText(Clock(left.state.t) .. " / " .. Clock(left.state.dur))
    if not scrubber.dragging then
        scrubber.settingValue = true
        scrubber:SetValue(left.state.t)
        scrubber.settingValue = false
    end
end

--------------------------------------------------------------------------------
-- Time control
--------------------------------------------------------------------------------
local function SeekTo(t)
    left.state:Seek(t)
    if right and right.state then right.state:Seek(t) end
    -- a seek clears every short-lived effect: they belong to the crossed events
    for _, ti in ipairs(rows) do
        for _, col in ipairs({ left, right }) do
            local f = col and col.frames[ti]
            if f then
                f.flashUntil, f.textUntil, f.labelUntil, f.pulseUntil, f.tickIdx = 0, 0, 0, 0, nil
                f.cast:SetText(""); f.label:SetText("")
            end
        end
    end
    left.strip.flashUntil = 0
    if right then right.strip.flashUntil = 0 end
    Paint()
end

local function SetPlaying(on)
    playing = on
    playBtn:SetText(on and "II" or ">")
    if on and left.state:AtEnd() then SeekTo(0) end
end

local function OnUpdate(_, elapsed)
    if not rp or not playing then return end
    local dt = elapsed * speed
    local cap = DT_STEP_MAX * speed
    if dt > cap then dt = cap end
    left.state:Advance(dt)
    if right and right.state then right.state:Advance(dt) end
    Paint()
    if left.state:AtEnd() then SetPlaying(false) end
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------
local function Build()
    if frame then return end
    frame = UI.CreateMovableFrame("ManaDemon: Replay", "ManaDemonReplayWindow", 2 * COL_W + 3 * GUTTER, 300)
    frame:SetFrameStrata("HIGH")
    tinsert(UISpecialFrames, "ManaDemonReplayWindow")
    frame:SetScript("OnUpdate", OnUpdate)
    frame:SetScript("OnHide", function() playing = false end)
    function frame:OnMoved()
        local point, _, relPoint, x, y = self:GetPoint()
        MD.db.replayPos = { point, relPoint, x, y }
    end
    if MD.db.replayPos then
        local p = MD.db.replayPos
        frame:ClearAllPoints()
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end

    headerFS = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    headerFS:SetPoint("TOPLEFT", frame, "TOPLEFT", GUTTER, -6)
    headerFS:SetJustifyH("LEFT")
    headerFS:SetWidth(2 * COL_W + GUTTER)

    left = CreateColumn(GUTTER, "ACTUAL")
    right = CreateColumn(2 * GUTTER + COL_W, "SUGGESTED")
    left.isLeft = true

    -- scrubber row, anchored to the bottom
    playBtn = UI.CreateButton(frame, ">", "accent-hover", { 24, 18 }, false, false, nil, nil,
        "Play / pause", "Space also toggles while the window has focus.")
    playBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", GUTTER, 24)
    playBtn:SetScript("OnClick", function() SetPlaying(not playing) end)

    local speeds, prev = {}, playBtn
    for _, sp in ipairs({ 1, 2, 4 }) do
        local b = UI.CreateButton(frame, sp .. "x", "accent-hover", { 26, 18 }, false, false, UI.FONT_SMALL)
        b.id = sp
        b:SetPoint("LEFT", prev, "RIGHT", 3, 0)
        speeds[#speeds + 1] = b
        prev = b
    end
    speedHighlight = UI.CreateButtonGroup(speeds, function(id)
        speed = id
        MD.db.replaySpeed = id
    end)

    timeFS = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    timeFS:SetPoint("LEFT", prev, "RIGHT", 10, 0)
    timeFS:SetWidth(96)
    timeFS:SetJustifyH("LEFT")

    scrubber = CreateFrame("Slider", nil, frame, "BackdropTemplate")
    scrubber:SetOrientation("HORIZONTAL")
    scrubber:SetSize(2 * COL_W + GUTTER - 230, 10)
    scrubber:SetPoint("LEFT", timeFS, "RIGHT", 4, 0)
    UI.StylizeFrame(scrubber, { 0.115, 0.115, 0.115, 1 })
    local thumb = scrubber:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(UI.accent[1], UI.accent[2], UI.accent[3], 1)
    thumb:SetSize(6, 14)
    scrubber:SetThumbTexture(thumb)
    scrubber:SetMinMaxValues(0, 1)
    scrubber:SetValueStep(0.05)
    scrubber:SetObeyStepOnDrag(true)
    scrubber:SetScript("OnValueChanged", function(self, v, user)
        if self.settingValue or not rp then return end
        SeekTo(v)
    end)
    scrubber:SetScript("OnMouseDown", function(self) self.dragging = true end)
    scrubber:SetScript("OnMouseUp", function(self) self.dragging = false end)
    scrubber.markers = {}

    local ticksCB = UI.CreateCheckButton(frame, "ticks", function(checked)
        MD.db.replayTicks = checked
        Paint()
    end, "Snapshot ticks", "The recorder's real HP every 5s, drawn over the",
        "engine's reconstruction on the left bars.")
    ticksCB:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", GUTTER, 4)
    ticksCB:SetChecked(MD.db.replayTicks ~= false)
    frame.ticksCB = ticksCB

    frame.hint = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    frame.hint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -GUTTER, 6)
    frame.hint:SetTextColor(0.5, 0.5, 0.5)
    frame.hint:SetJustifyH("RIGHT")
end

-- Markers along the scrubber: deaths red, big hits orange, the left column's
-- casts as faint grey ticks.
local function PlaceMarkers()
    for _, m in ipairs(scrubber.markers) do m:Hide() end
    local n = 0
    local function Mark(t, r, g, b, a, h)
        n = n + 1
        local m = scrubber.markers[n]
        if not m then
            m = scrubber:CreateTexture(nil, "OVERLAY")
            scrubber.markers[n] = m
        end
        m:SetSize(1, h or 10)
        m:SetColorTexture(r, g, b, a)
        m:ClearAllPoints()
        local dur = left.state.dur
        m:SetPoint("LEFT", scrubber, "LEFT", dur > 0 and (t / dur) * scrubber:GetWidth() or 0, 0)
        m:Show()
    end
    local TK, K = MD.SimModel.TK, MD.SimModel.K
    local L = rp.left.trace
    local n = 0
    for i = 1, L.nEv do
        if L.ev.kind[i] == TK.CAST then
            n = n + 1
            local cl = rp.casts and rp.casts[n]
            local lc = cl and LABEL_COLOR[cl.label]
            if lc and cl.label ~= "fine" and cl.label ~= "unclassified" then
                Mark(L.ev.t[i], lc[1], lc[2], lc[3], 0.9, 8)
            else
                Mark(L.ev.t[i], 1, 1, 1, 0.25, 6)
            end
        end
    end
    local big = (MD.db.simBigHit or 0.15)
    local sev = rp.scenario.ev
    if sev then
        for i = 1, #sev.t do
            if sev.kind[i] == K.DMG then
                local tg = rp.scenario.targets[sev.tgt[i]]
                if tg and tg.maxHP > 0 and (sev.amt[i] or 0) / tg.maxHP >= big then
                    Mark(sev.t[i], 1, 0.6, 0.2, 0.9, 10)
                end
            end
        end
    end
    for i = 1, L.nEv do
        if L.ev.kind[i] == TK.DEATH then Mark(L.ev.t[i], 1, 0.2, 0.2, 1, 14) end
    end
end

--------------------------------------------------------------------------------
-- Opening a fight
--------------------------------------------------------------------------------
local function Layout()
    -- rows: tanks, healers, the rest, roster order within each
    rows = {}
    for _, ti in ipairs(rp.rec.tracked or {}) do rows[#rows + 1] = ti end
    local roster = rp.rec.roster
    table.sort(rows, function(a, b)
        local ra, rb = ROLE_ORDER[roster[a] and roster[a].role] or 4, ROLE_ORDER[roster[b] and roster[b].role] or 4
        if ra ~= rb then return ra < rb end
        return a < b
    end)

    local hasRight = rp.right ~= nil
    local width = hasRight and (2 * COL_W + 3 * GUTTER) or (COL_W + 2 * GUTTER)
    local height = HEADER_H + STRIP_H + #rows * (FRAME_H + FRAME_GAP) + SCRUB_H + 8
    frame:SetSize(width, height)
    Shown(right.title, hasRight)
    for _, k in ipairs({ "mana", "cast", "form", "wait", "score" }) do Shown(right.strip[k], hasRight) end
    scrubber:SetWidth(width - 2 * GUTTER - 230)

    for _, col in ipairs({ left, right }) do
        for _, f in pairs(col.frames) do f:Hide() end
    end
    local y0 = -(HEADER_H + STRIP_H + 4)
    for n, ti in ipairs(rows) do
        local y = y0 - (n - 1) * (FRAME_H + FRAME_GAP)
        for ci, col in ipairs({ left, right }) do
            if ci == 1 or hasRight then
                local f = col.frames[ti]
                if not f then
                    f = CreateUnitFrame(frame, col.x, y)
                    col.frames[ti] = f
                else
                    f:ClearAllPoints()
                    f:SetPoint("TOPLEFT", frame, "TOPLEFT", col.x, y)
                end
                local r = roster[ti] or {}
                f.classColor = ClassColor(r.class)
                f.role:SetText(ROLE_LETTER[r.role] or "?")
                f.name:SetText(r.name or ("#" .. ti))
                local c = f.classColor
                f.bar:SetStatusBarColor(c[1] * 0.85, c[2] * 0.85, c[3] * 0.85)
                f.flashUntil, f.textUntil, f.labelUntil, f.pulseUntil, f.tickIdx = 0, 0, 0, 0, nil
                f.cast:SetText(""); f.label:SetText("")
                f:SetBackdropBorderColor(0, 0, 0, 1)
                f.defIcon.spellID = nil
                for _, ic in ipairs(f.debuffs) do ic.spellID = nil end
                f:Show()
            end
        end
    end
end

function MD:OpenReplay(n)
    local FR, SP = MD.FightRecorder, MD.SimPlanner
    if not (FR and SP and MD.ReplayTrace) then MD:Print("replay: not loaded.") return end
    if (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") then
        MD:Print("replay: not in combat - it is a review tool.")
        return
    end
    n = tonumber(n) or 1
    local rec = FR:Get(n)
    if not rec then MD:Print("replay: no recording " .. tostring(n) .. ".") return end

    Build()
    playing = false
    local t0 = debugprofilestop and debugprofilestop() or 0
    rp = SP.Replay(rec, { dt = 0.25 })
    if not rp then MD:Print("replay: could not build the fight.") return end
    local RT = MD.ReplayTrace
    left.state = RT.New(rp.left.trace, rp.scenario, { onEvent = MakeOnEvent(left) })
    right.state = rp.right and RT.New(rp.right.trace, rp.scenario, { onEvent = MakeOnEvent(right) }) or nil
    MD:Debug("sim", "replay %d opened: %d rows, %d/%d trace events, dt %.2f, %.0f ms", n, #(rec.tracked or {}),
        rp.left.trace.nEv, rp.right and rp.right.trace.nEv or 0, rp.left.trace.dt,
        (debugprofilestop and debugprofilestop() or 0) - t0)

    Layout()
    speed = MD.db.replaySpeed or 1
    speedHighlight(speed)

    local v = rp.validation
    local fit = ""
    if v and v.gates then
        for _, g in ipairs(v.gates) do
            if g.name == "mana" then fit = g.text; break end
        end
    end
    local when = rec.id and date and date("%H:%M", rec.id) or ""
    headerFS:SetText(string.format("|cffffcc00#%d|r  %s  %s  %s   %s%s", n, rec.zone or "?", when,
        Clock(rec.dur or 0), v and (v.ok and "|cff99dd99replays|r" or "|cffff9966does not replay|r") or "",
        fit ~= "" and ("  |cff888888" .. fit .. "|r") or ""))
    if rp.right then
        local p = rp.right.plan
        right.title:SetText(string.format("SUGGESTED  |cff888888(%s, %d binds)|r", p.name or "plan", p:BindCount()))
        frame.hint:SetText("")
    else
        frame.hint:SetText(v and not v.ok and "no plan: this fight does not replay, so nothing is suggested"
            or "no plan - press Coach first for the right column")
    end

    scrubber.settingValue = true
    scrubber:SetMinMaxValues(0, left.state.dur)
    scrubber:SetValue(0)
    scrubber.settingValue = false
    PlaceMarkers()
    SeekTo(0)
    frame:Show()
end

function MD:ToggleReplay(arg)
    if frame and frame:IsShown() and (arg == nil or arg == "") then
        frame:Hide()
        return
    end
    MD:OpenReplay(arg)
end

MD.Replay = {
    Open = function(_, n) MD:OpenReplay(n) end,
    -- for tools/replayui.lua: what the window is showing, read-only
    _state = function() return { frame = frame, left = left, right = right, rows = rows, rp = rp,
                                 scrubber = scrubber, timeFS = timeFS, playing = playing } end,
    _setPlaying = function(on) SetPlaying(on) end,
    _seek = function(t) SeekTo(t) end,
}
