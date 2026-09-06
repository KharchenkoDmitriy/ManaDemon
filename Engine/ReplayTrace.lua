-- The replay window's state machine (docs/SPEC-v0.8.md 2.4). Everything the
-- window needs to KNOW about a moment of a traced run lives here; the window
-- only paints. No frames, no textures, no client API -- which is what lets
-- tools/replaycheck.lua drive it offline and assert that seeking to a time
-- gives exactly the state that stepping to it does.
--
-- Two rules the window must not undo:
--   * no interpolation -- a heal is a jump, and between grid points the value
--     holds;
--   * state at time t is a pure function of the trace prefix -- a seek rescans
--     from zero with the visual callback suppressed, there is no incremental
--     undo. Traces are hundreds of events; the rescan is nothing.
--
-- Events AT t = 0 (a pre-pull HoT, the opening swing) are initial state: they
-- are in the state a fresh machine reports and they never fire onEvent. The
-- window paints from state every frame, so nothing is lost; what is avoided
-- is a flash for something that happened before the window opened.
local _, MD = ...

local RT = {}
MD.ReplayTrace = RT

-- Callback kinds beyond SM.TK: recorded damage and foreign heals are not in
-- the trace (identical in both columns by construction) but the window still
-- wants a pulse for them, so Advance fires these from the scenario's timeline.
RT.EV_DMG, RT.EV_FHEAL = 100, 101

local State = {}
State.__index = State

function RT.New(trace, scenario, opts)
    opts = opts or {}
    local st = setmetatable({
        trace = trace, scenario = scenario, onEvent = opts.onEvent,
        dur = trace.dur or 0, dt = trace.dt or 0.25,
        t = 0, evI = 1, dmgI = 1,
        hots = {}, dead = {}, form = nil, casting = nil,
        waitStart = nil, waitLen = 0,
        spent = 0, deaths = 0, lowest = 1, lowestTgt = nil, casts = 0,
        cdUntil = {}, auras = {},
    }, State)
    for i = 1, (trace.nT or 0) do st.hots[i] = {}; st.auras[i] = {} end
    st:Seek(0)
    return st
end

--------------------------------------------------------------------------------
-- Applying one trace event. `fire` is false during a seek.
--------------------------------------------------------------------------------
local function HotEnd(trace, i, tgt, fi)
    -- the moment this HoT instance stops: the next HOT_END on (tgt, fi), or the
    -- next HOT that replaces it (a refresh drops the old instance)
    local TK = MD.SimModel.TK
    local e = trace.ev
    for j = i + 1, trace.nEv do
        if e.tgt[j] == tgt and e.a[j] == fi then
            if e.kind[j] == TK.HOT_END then return e.t[j], j end
            if e.kind[j] == TK.HOT then return e.t[j], j end
        end
    end
    return trace.dur, nil
end

function State:Apply(i, fire)
    local TK = MD.SimModel.TK
    local e = self.trace.ev
    local kind, tgt, a, b, t = e.kind[i], e.tgt[i], e.a[i], e.b[i], e.t[i]
    if kind == TK.CAST_START then
        self.casting = { spellID = a, target = tgt, startedAt = t, castTime = b, why = e.why[i] }
    elseif kind == TK.CAST then
        self.casting = nil
        self.spent = self.spent + (b or 0)
        self.casts = self.casts + 1
        self.lastCast = { spellID = a, target = tgt, t = t, why = e.why[i], n = self.casts }
        local cd = MD.SimModel.SPELL_CD and MD.SimModel.SPELL_CD[a]
        if cd then self.cdUntil[a] = t + cd end
    elseif kind == TK.CANCEL then
        self.casting = nil
    elseif kind == TK.HOT then
        local row = self.hots[tgt]
        if row then
            local expires = HotEnd(self.trace, i, tgt, a)
            row[a] = { stacks = b, since = t, expires = expires }
        end
    elseif kind == TK.HOT_END then
        local row = self.hots[tgt]
        if row then row[a] = nil end
    elseif kind == TK.DEATH then
        if tgt and not self.dead[tgt] then
            self.dead[tgt] = true
            self.deaths = self.deaths + 1
        end
    elseif kind == TK.FORM then
        self.form = (a == 1) and "tree" or "caster"
    elseif kind == TK.WAIT then
        self.waitStart, self.waitLen = t, a or 0
    end
    if fire and self.onEvent then self.onEvent(kind, tgt, a, b, t, e.why[i]) end
end

local function Reset(self)
    self.t, self.evI, self.dmgI = 0, 1, 1
    for i = 1, #self.hots do
        local row = self.hots[i]
        for k in pairs(row) do row[k] = nil end
    end
    for k in pairs(self.dead) do self.dead[k] = nil end
    self.form, self.casting, self.lastCast = nil, nil, nil
    self.waitStart, self.waitLen = nil, 0
    self.spent, self.deaths, self.casts = 0, 0, 0
    self.lowest, self.lowestTgt = 1, nil
    for k in pairs(self.cdUntil) do self.cdUntil[k] = nil end
    for i = 1, #self.auras do
        local row = self.auras[i]
        for k in pairs(row) do row[k] = nil end
    end
end

-- A recorded AURA event: state whether or not visuals fire.
local function ApplyAura(self, tgt, amt, x, t)
    local row = self.auras[tgt]
    if not row then return end
    local FLAG = MD.SimModel.AURA_BUFF_FLAG
    local buff = x >= FLAG
    local spellID = buff and (x - FLAG) or x
    if amt and amt < 0 then
        row[spellID] = nil
    else
        local a = row[spellID]
        if a then a.stacks = amt or 1
        else row[spellID] = { spellID = spellID, stacks = amt or 1, since = t, buff = buff } end
    end
end

-- Lowest tracked HP so far, from the grid points crossed. Checked at grid
-- resolution, so it can sit a hair above the card's `lowest.hp`, which the
-- engine reads at the instant of each damage event; the difference is the
-- grid, not a disagreement.
local function NoteLowest(self, k)
    local hp = self.trace.hp
    for ti, col in pairs(hp) do
        local v = col[k]
        if v and v < self.lowest then self.lowest, self.lowestTgt = v, ti end
    end
end

--------------------------------------------------------------------------------
-- Moving in time
--------------------------------------------------------------------------------
local function GridIndex(self, t)
    local k = math.floor(t / self.dt + 1e-6) + 1
    if k < 1 then k = 1 end
    if k > self.trace.n then k = self.trace.n end
    return k
end

-- Cross every trace event up to t1 that the cursor has not applied yet (fire =
-- whether onEvent runs), and every recorded damage / foreign heal in
-- (t0, t1]. t0 < 0 means "from before the fight", which includes the events
-- at t = 0 (pre-pull HoTs).
local function Cross(self, t0, t1, fire)
    local e, n = self.trace.ev, self.trace.nEv
    local i = self.evI
    while i <= n and e.t[i] <= t1 do
        self:Apply(i, fire)
        i = i + 1
    end
    self.evI = i

    local sc = self.scenario
    local sev = sc and sc.ev
    if sev then
        local K = MD.SimModel.K
        local j, m = self.dmgI, #sev.t
        while j <= m and sev.t[j] <= t1 do
            local k = sev.kind[j]
            if k == K.AURA then ApplyAura(self, sev.tgt[j], sev.amt[j], sev.x[j], sev.t[j]) end
            if fire and self.onEvent and sev.t[j] > t0 then
                if k == K.DMG then self.onEvent(RT.EV_DMG, sev.tgt[j], sev.amt[j], 0, sev.t[j], 0)
                elseif k == K.FHEAL then self.onEvent(RT.EV_FHEAL, sev.tgt[j], sev.amt[j], 0, sev.t[j], 0) end
            end
            j = j + 1
        end
        self.dmgI = j
    end

    -- grid points crossed, for the running lowest
    local k0 = (t0 < 0) and 0 or GridIndex(self, t0)
    local k1 = GridIndex(self, t1)
    for k = k0 + 1, k1 do NoteLowest(self, k) end
end

function State:Seek(t)
    if t < 0 then t = 0 end
    if t > self.dur then t = self.dur end
    Reset(self)
    Cross(self, -1, t, false)
    self.t = t
    return t
end

function State:Advance(dt)
    local t1 = self.t + (dt or 0)
    if t1 > self.dur then t1 = self.dur end
    if t1 <= self.t then return self.t end
    Cross(self, self.t, t1, true)
    self.t = t1
    return t1
end

function State:AtEnd() return self.t >= self.dur end

--------------------------------------------------------------------------------
-- Reading the moment
--------------------------------------------------------------------------------
function State:Mana()
    return self.trace.mana[GridIndex(self, self.t)]
end

function State:Form()
    if self.form then return self.form end
    local f = self.trace.form[GridIndex(self, self.t)]
    return (f == 1) and "tree" or "caster"
end

function State:Hp(ti)
    local col = self.trace.hp[ti]
    return col and col[GridIndex(self, self.t)] or nil
end

function State:Dead(ti) return self.dead[ti] == true end

function State:Hot(ti, fi)
    local row = self.hots[ti]
    local h = row and row[fi]
    if not h then return nil end
    local remaining = h.expires - self.t
    if remaining < 0 then remaining = 0 end
    return { stacks = h.stacks, remaining = remaining, since = h.since }
end

function State:Casting()
    local c = self.casting
    if not c then return nil end
    if c.castTime and c.castTime > 0 and self.t > c.startedAt + c.castTime + 0.05 then
        -- a CAST_START whose CAST never came (a recorded cancel the recorder
        -- did not see) -- do not show a bar that fills forever
        return nil
    end
    return c
end

function State:Waiting()
    if not self.waitStart then return nil end
    local left = self.waitStart + self.waitLen - self.t
    if left <= 0 then return nil end
    return left
end

-- Auras up on `ti` at st.t, oldest first: { spellID, stacks, since, buff }.
-- Only what the recorder kept -- whitelisted defensives and capped debuffs.
function State:Auras(ti, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local row = self.auras[ti]
    if not row then return out end
    for _, a in pairs(row) do out[#out + 1] = a end
    table.sort(out, function(p, q) return p.since < q.since end)
    return out
end

-- Is this spell off cooldown at st.t? Only the cooldowns the engine respects
-- (SM.SPELL_CD: Swiftmend) -- everything else is always ready.
function State:Ready(spellID)
    local until_ = self.cdUntil[spellID]
    return not until_ or self.t >= until_
end

-- Recorded damage on `ti` in the trailing `window` seconds (for the pulse).
function State:Damage(ti, window)
    local sc = self.scenario
    local sev = sc and sc.ev
    if not sev then return 0 end
    local K = MD.SimModel.K
    local sum, j = 0, self.dmgI - 1
    local floor = self.t - (window or 0.4)
    while j >= 1 and sev.t[j] > floor do
        if sev.kind[j] == K.DMG and sev.tgt[j] == ti then sum = sum + (sev.amt[j] or 0) end
        j = j - 1
    end
    return sum
end

-- The running score line: what the strip prints under the mana bar.
function State:Score()
    return self.spent, self.lowest, self.deaths, self.casts
end
