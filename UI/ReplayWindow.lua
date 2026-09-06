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

local COL_W, FRAME_H, FRAME_GAP = 360, 38, 6
local GUTTER = 14
local HEADER_H, STRIP_H, SCRUB_H = 26, 92, 78
local NAME_X, BAR_X, PCT_W = 58, 142, 44
local DT_STEP_MAX = 0.25       -- never advance more than this per frame at 1x (a hitch is not a skip)
local FLASH_CAST, FLASH_TEXT, FLASH_FOREIGN, PULSE_DMG = 0.8, 2.0, 0.4, 0.4
local GCD = 1.5                -- an instant still locks the healer for this long
local SPEEDS = { 0.25, 0.5, 1, 2, 4 }
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
local HOT_SQ, HOT_GAP = 14, 2  -- the three HoT icons under the role letter
local SWIFTMEND = 18562
local ICON_DEBUFF, ICON_DEF, MAX_DEBUFF_ICONS = 14, 16, 3
local ROLE_LETTER = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }

local frame, scrubber, playBtn, timeFS, headerFS, speedHighlight, speedButtons
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

local rankCount = nil
local function SpellLabel(spellID)
    local SD = MD.SpellData
    local sd = SD.spells[spellID]
    if sd then
        if not rankCount then
            rankCount = {}
            for _, s in pairs(SD.spells) do rankCount[s.family] = (rankCount[s.family] or 0) + 1 end
        end
        local fam = SD.families[sd.family]
        local name = fam and fam.label or sd.family
        if (rankCount[sd.family] or 1) > 1 then name = string.format("%s R%d", name, sd.rank) end
        return name, sd.family
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

    f.role = f:CreateFontString(nil, "OVERLAY", UI.FONT)
    f.role:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -3)
    f.role:SetWidth(12)
    f.role:SetJustifyH("LEFT")
    f.role:SetTextColor(0.7, 0.7, 0.7)

    f.name = f:CreateFontString(nil, "OVERLAY", UI.FONT)
    f.name:SetPoint("LEFT", f, "LEFT", NAME_X, 0)
    f.name:SetWidth(BAR_X - NAME_X - 4)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)

    -- One icon builder for HoTs, defensives and debuffs: the spell's texture,
    -- a Cell-style VERTICAL sweep (the elapsed share of the icon dimmed from
    -- the top down, a 1px spark at the edge -- Cell/Indicators/Base.lua's
    -- VerticalCooldown, done with an overlay rather than a mask because the
    -- window paints every frame anyway), a stack count bottom-right, and a
    -- lettered fallback when no texture resolves.
    local function Icon(size)
        local ic = CreateFrame("Frame", nil, f, "BackdropTemplate")
        ic:SetSize(size, size)
        UI.StylizeFrame(ic, { 0.15, 0.15, 0.15, 1 }, { 0, 0, 0, 1 })
        ic.tex = ic:CreateTexture(nil, "ARTWORK")
        ic.tex:SetPoint("TOPLEFT", ic, "TOPLEFT", 1, -1)
        ic.tex:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", -1, 1)
        ic.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic.dim = ic:CreateTexture(nil, "OVERLAY", nil, 1)
        ic.dim:SetPoint("TOPLEFT", ic, "TOPLEFT", 1, -1)
        ic.dim:SetPoint("TOPRIGHT", ic, "TOPRIGHT", -1, -1)
        ic.dim:SetHeight(1)
        ic.dim:SetColorTexture(0, 0, 0, 0.65)
        ic.dim:Hide()
        ic.spark = ic:CreateTexture(nil, "OVERLAY", nil, 2)
        ic.spark:SetPoint("TOPLEFT", ic.dim, "BOTTOMLEFT", 0, 0)
        ic.spark:SetPoint("TOPRIGHT", ic.dim, "BOTTOMRIGHT", 0, 0)
        ic.spark:SetHeight(1)
        ic.spark:SetColorTexture(0.8, 0.8, 0.8, 0.9)
        ic.spark:Hide()
        ic.letter = ic:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        ic.letter:SetPoint("CENTER")
        ic.count = ic:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        ic.count:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 1, -1)
        ic.text = ic.count   -- older name, kept for the harness
        ic:EnableMouse(true)
        ic:SetScript("OnEnter", function(self)
            if MD.Tip and self.tip then MD.Tip:Show(self, "ANCHOR_RIGHT", self.tip) end
        end)
        ic:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)
        ic.size = size
        ic:Hide()
        return ic
    end
    f.Icon = Icon

    -- HoT icons (Rejuvenation, Regrowth, Lifebloom in SM.HOT_INDEX order)
    -- and the Swiftmend-ready dot after them
    f.hots = {}
    for fi = 1, 3 do
        local ic = Icon(HOT_SQ)
        ic:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6 + (fi - 1) * (HOT_SQ + HOT_GAP), 3)
        f.hots[fi] = ic
    end
    f.dot = f:CreateTexture(nil, "OVERLAY")
    f.dot:SetSize(5, 5)
    f.dot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6 + 3 * (HOT_SQ + HOT_GAP), 5)
    f.dot:SetColorTexture(1, 0.6, 0.2, 1)
    f.dot:Hide()

    -- v0.8.3: a defensive cooldown as one icon with the accent border, up
    -- front; up to three debuffs over the bar's right end, with their stacks.
    -- Recorded and drawn, never modelled -- the damage they changed was
    -- recorded as changed.
    f.defIcon = Icon(ICON_DEF)
    f.defIcon:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -3)
    f.defIcon:SetBackdropBorderColor(UI.accent[1], UI.accent[2], UI.accent[3], 1)
    f.debuffs = {}
    for i = 1, MAX_DEBUFF_ICONS do
        local ic = Icon(ICON_DEBUFF)
        ic:SetPoint("RIGHT", f.bar, "RIGHT", -(i - 1) * (ICON_DEBUFF + 1) - 1, 0)
        f.debuffs[i] = ic
    end
    f.auraBuf = {}

    f.bar = CreateBar(f, COL_W - BAR_X - PCT_W - 6, FRAME_H - 8)
    f.bar:SetPoint("LEFT", f, "LEFT", BAR_X, 0)

    -- the damage pulse: a red wash over the bar's empty part
    f.pulse = f.bar:CreateTexture(nil, "ARTWORK")
    f.pulse:SetAllPoints(f.bar)
    f.pulse:SetColorTexture(0.9, 0.15, 0.1, 0)

    -- the snapshot tick (left column only): the truth over the reconstruction
    f.tick = f.bar:CreateTexture(nil, "OVERLAY")
    f.tick:SetSize(2, FRAME_H - 8)
    f.tick:SetColorTexture(1, 1, 1, 0)
    f.tick:SetPoint("LEFT", f.bar, "LEFT", 0, 0)

    f.pct = f:CreateFontString(nil, "OVERLAY", UI.FONT)
    f.pct:SetPoint("RIGHT", f, "RIGHT", -6, 0)
    f.pct:SetWidth(PCT_W - 6)
    f.pct:SetJustifyH("RIGHT")

    -- the cast text INSIDE the bar (Cell draws its text over the bar too), and
    -- the classifier's label under it, right-aligned (left column only)
    f.cast = f.bar:CreateFontString(nil, "OVERLAY", UI.FONT)
    f.cast:SetPoint("TOPLEFT", f.bar, "TOPLEFT", 4, -2)
    f.cast:SetJustifyH("LEFT")
    f.cast:SetText("")
    f.label = f.bar:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.label:SetPoint("BOTTOMRIGHT", f.bar, "BOTTOMRIGHT", -4, 2)
    f.label:SetJustifyH("RIGHT")
    f.label:SetText("")

    f.flashUntil, f.textUntil, f.labelUntil, f.pulseUntil, f.tickAt = 0, 0, 0, 0, nil
    return f
end

local function CreateStrip(parent, x, y)
    local s = {}
    s.mana = CreateBar(parent, COL_W - 70, 18)
    s.mana:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    s.mana:SetStatusBarColor(0.25, 0.45, 0.95)
    s.manaFS = s.mana:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.manaFS:SetPoint("CENTER")
    s.form = parent:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.form:SetPoint("LEFT", s.mana, "RIGHT", 8, 0)
    s.form:SetTextColor(0.7, 0.7, 0.7)

    -- the cast bar: a real cast fills over its cast time in the family colour;
    -- an instant sweeps the GCD in grey (the healer is locked either way).
    -- The name STAYS until the next cast, dimmed once the bar is done -- the
    -- question the strip answers is "what was I doing", not "is a bar moving".
    s.cast = CreateBar(parent, COL_W - 70, 18)
    s.cast:SetPoint("TOPLEFT", s.mana, "BOTTOMLEFT", 0, -6)
    s.cast:SetStatusBarColor(0.8, 0.8, 0.8)
    s.castFS = s.cast:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.castFS:SetPoint("LEFT", s.cast, "LEFT", 5, 0)
    s.castFS:SetJustifyH("LEFT")
    s.castFS:SetWordWrap(false)
    s.wait = parent:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.wait:SetPoint("LEFT", s.cast, "RIGHT", 8, 0)
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

    s.score = parent:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.score:SetPoint("TOPLEFT", s.cast, "BOTTOMLEFT", 0, -8)
    s.score:SetJustifyH("LEFT")
    s.score:SetWidth(COL_W)
    s.gcdUntil, s.gcdStart = 0, 0
    return s
end

local function CreateColumn(x, titleText)
    local col = { frames = {}, x = x }
    col.title = frame:CreateFontString(nil, "OVERLAY", UI.FONT_TITLE)
    col.title:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(HEADER_H + 6))
    col.title:SetText(titleText)
    col.strip = CreateStrip(frame, x, -(HEADER_H + 30))
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
            local tgtName = rp.rec.roster[tgt] and rp.rec.roster[tgt].name
            col.strip.lastCast = label .. (tgtName and (" -> " .. tgtName) or "")
            col.strip.lastFamily = family
            -- an instant: sweep the GCD from this moment (replay clock, not wall clock)
            local c = col.state and col.state:Casting()
            col.strip.gcdStart, col.strip.gcdUntil = t, t + GCD
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

local textureCache = {}
local function SpellTexture(spellID)
    local tex = textureCache[spellID]
    if tex ~= nil then return tex or nil end
    local ok, t = pcall(GetSpellTexture, spellID)
    if not (ok and t) then
        -- this client may not have GetSpellTexture; GetSpellInfo's third
        -- return is the icon on the 2.5.x client
        local ok2, _, _, icon = pcall(GetSpellInfo, spellID)
        if ok2 and icon then ok, t = true, icon end
    end
    if not (ok and t) then MD:Debug("sim", "replay: no texture for spell %d", spellID); t = false end
    textureCache[spellID] = t
    return t or nil
end

-- Set the icon's texture (or its lettered fallback) once per spell, then the
-- sweep: the elapsed share of (since .. until) dimmed from the top down.
local function SetIcon(ic, spellID, fallbackName)
    if ic.spellID ~= spellID then
        ic.spellID = spellID
        local tex = SpellTexture(spellID)
        if tex then
            ic.tex:SetTexture(tex)
            ic.letter:SetText("")
        else
            ic.tex:SetTexture(nil)
            ic.letter:SetText((fallbackName or "?"):sub(1, 1))
        end
    end
end

local function Sweep(ic, since, until_, t)
    local dur = (until_ or 0) - (since or 0)
    if dur <= 0 then ic.dim:Hide(); ic.spark:Hide(); return end
    local frac = (t - since) / dur
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    local h = (ic.size - 2) * frac
    if h < 0.5 then
        ic.dim:Hide(); ic.spark:Hide()
    else
        ic.dim:SetHeight(h)
        ic.dim:Show()
        Shown(ic.spark, frac < 1)
    end
end

local function PaintIcon(ic, a, t, isDef)
    SetIcon(ic, a.spellID, AuraName(a.spellID))
    Sweep(ic, a.since, a.until_, t)
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

    -- HoT icons with the vertical sweep of their remaining time; Lifebloom
    -- shows its stacks and its border turns white in the last second (the
    -- bloom is coming). The dot: Swiftmend has something to eat and is ready.
    local SM = MD.SimModel
    local HOT_INDEX = SM.HOT_INDEX
    local eatable = false
    for fi = 1, 3 do
        local ic = f.hots[fi]
        local h = (not dead) and st:Hot(ti, fi) or nil
        if h then
            local fam = SM.HOT_NAME[fi]
            SetIcon(ic, MD.SpellData.maxRank[fam] or 0, fam)
            Sweep(ic, h.since, h.since + (h.duration or 0), st.t)
            if fi == HOT_INDEX.Lifebloom then
                ic.count:SetText(tostring(h.stacks or 1))
                if h.remaining <= 1 then ic:SetBackdropBorderColor(1, 1, 1, 1)
                else ic:SetBackdropBorderColor(0, 0, 0, 1) end
            else
                ic.count:SetText("")
                eatable = true
            end
            ic:Show()
        else
            ic:Hide()
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
    if c and c.castTime > 0 then
        -- a real cast, filling over its recorded (left) or modelled (right) time
        local label, family = SpellLabel(c.spellID)
        local frac = (st.t - c.startedAt) / c.castTime
        if frac > 1 then frac = 1 end
        if frac < 0 then frac = 0 end
        local fc = FAMILY_COLOR[family] or FAMILY_COLOR.other
        s.cast:SetStatusBarColor(fc[1], fc[2], fc[3])
        s.cast:SetValue(frac)
        local tgt = rp.rec.roster[c.target]
        s.castFS:SetText(label .. (tgt and (" -> " .. tgt.name) or "") .. string.format("  %.1fs", c.castTime))
        s.castFS:SetTextColor(1, 1, 1)
    elseif s.lastCast and st.t < s.gcdUntil and st.t >= s.gcdStart then
        -- just after an instant: the GCD sweeping, in grey
        s.cast:SetStatusBarColor(0.45, 0.45, 0.45)
        s.cast:SetValue((st.t - s.gcdStart) / GCD)
        s.castFS:SetText(s.lastCast .. "  instant")
        s.castFS:SetTextColor(1, 1, 1)
    else
        -- idle: the last cast's name stays, dimmed, so "what was I doing" has an answer
        s.cast:SetValue(0)
        s.castFS:SetText(s.lastCast or "")
        s.castFS:SetTextColor(0.55, 0.55, 0.55)
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
    for _, col in ipairs({ left, right }) do
        if col then col.strip.lastCast, col.strip.gcdStart, col.strip.gcdUntil = nil, 0, 0 end
    end
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
    playBtn:SetSize(30, 20)
    playBtn:SetScript("OnClick", function() SetPlaying(not playing) end)

    local speeds, prev = {}, playBtn
    for _, sp in ipairs(SPEEDS) do
        local text = sp >= 1 and (sp .. "x") or ("1/" .. math.floor(1 / sp + 0.5) .. "x")
        local b = UI.CreateButton(frame, text, "accent-hover", { 34, 18 }, false, false, UI.FONT_SMALL)
        b.id = sp
        b:SetPoint("LEFT", prev, "RIGHT", 3, 0)
        speeds[#speeds + 1] = b
        prev = b
    end
    speedButtons = speeds
    speedHighlight = UI.CreateButtonGroup(speeds, function(id)
        speed = id
        MD.db.replaySpeed = id
    end)

    timeFS = frame:CreateFontString(nil, "OVERLAY", UI.FONT)
    timeFS:SetPoint("LEFT", prev, "RIGHT", 12, 0)
    timeFS:SetWidth(110)
    timeFS:SetJustifyH("LEFT")

    -- the scrubber on its own row above the buttons, full width
    scrubber = CreateFrame("Slider", nil, frame, "BackdropTemplate")
    scrubber:SetOrientation("HORIZONTAL")
    scrubber:SetSize(2 * COL_W + GUTTER, 14)
    scrubber:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", GUTTER, 50)
    UI.StylizeFrame(scrubber, { 0.115, 0.115, 0.115, 1 })
    local thumb = scrubber:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(UI.accent[1], UI.accent[2], UI.accent[3], 1)
    thumb:SetSize(6, 18)
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
    ticksCB:SetPoint("LEFT", timeFS, "RIGHT", 8, 0)
    ticksCB:SetChecked(MD.db.replayTicks ~= false)
    frame.ticksCB = ticksCB

    -- the hint on its own line at the very bottom, never under a control
    frame.hint = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    frame.hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", GUTTER, 6)
    frame.hint:SetTextColor(0.5, 0.5, 0.5)
    frame.hint:SetJustifyH("LEFT")
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
    frame.hint:SetWidth(width - 2 * GUTTER)
    Shown(right.title, hasRight)
    for _, k in ipairs({ "mana", "cast", "form", "wait", "score" }) do Shown(right.strip[k], hasRight) end
    scrubber:SetWidth(width - 2 * GUTTER)

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
                for _, ic in ipairs(f.hots) do ic.spellID = nil end
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
                                 scrubber = scrubber, timeFS = timeFS, playing = playing, speeds = speedButtons } end,
    _setPlaying = function(on) SetPlaying(on) end,
    _seek = function(t) SeekTo(t) end,
}
