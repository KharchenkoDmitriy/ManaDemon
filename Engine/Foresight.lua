local _, MD = ...

--------------------------------------------------------------------------------
-- Deformed foresight (docs/SPEC-v0.13.md §9).
--
-- v0.13.1 learned a prior from OTHER fights. The author's objection is correct:
--
--   "the problem with prior records is that they can be totally irrelevant. So I
--    would like to use the current fight, but with some deformation, so it does
--    not know exactly numbers and patterns and does not trust it, but has a
--    small correction"
--
-- A healer who has pulled this boss before does know something about THIS fight:
-- that the AoE lands about every half minute, that the tank takes a big one
-- early. They do not know it to the hundred points or the half second.
--
-- SO BE HONEST ABOUT WHAT THIS IS. Reading the current fight's damage, however
-- blurred, is foresight. The strict causality invariant (docs/SPEC-v0.12.md §2)
-- does NOT hold for a plan built with this, `SP.RunPlan` marks such a plan, and
-- every card and replay built on one says so. What is defended instead is that
-- the foresight is genuinely DEGRADED, and that is asserted rather than claimed:
--
--   * time is bucketed and smeared across neighbouring buckets, so a burst
--     cannot be located to better than the bucket width;
--   * magnitude is perturbed by a deterministic hash and then quantised, so the
--     exact number is not recoverable;
--   * nothing beyond `sight` seconds is visible at all;
--   * what comes out is trusted at `trust` < 1 and blended with observation,
--     which always wins once it has anything to say.
--
-- Deterministic in the fight's own id, so a replay reproduces exactly.
--------------------------------------------------------------------------------

local FS = {}
MD.Foresight = FS

local BUCKET = 4.0      -- seconds; the resolution a memory of a fight has
local SIGHT = 10.0      -- seconds; how far ahead that memory reaches
local TRUST = 0.5       -- how much of it the plan is willing to believe
local JITTER = 0.35     -- +/- on every bucket, deterministic per fight and target
local STEPS = 6         -- magnitude is quantised to this many levels

-- A small deterministic hash -> [0,1). Same fight, same target, same bucket,
-- same number, every run: a replay must reproduce.
local function Hash01(a, b, c)
    local x = (a * 73856093) + (b * 19349663) + (c * 83492791)
    x = x % 2147483647
    x = (x * 1103515245 + 12345) % 2147483647
    return x / 2147483647
end

-- Build the deformed view of a scenario's incoming damage.
function FS.Build(scenario, opts)
    opts = opts or {}
    local SM = MD.SimModel
    local K = SM.K
    local bucket = opts.bucket or BUCKET
    local sight = opts.sight or SIGHT
    local trust = opts.trust or TRUST
    local jitter = opts.jitter or JITTER
    local seed = opts.seed or 1
    local dur = scenario.dur or 0
    local nBins = math.floor(dur / bucket + 1) + 2
    local nT = scenario.targets and #scenario.targets or 0
    if nT == 0 or dur <= 0 then return nil end

    -- 1. the truth, in buckets
    local raw = {}
    for i = 1, nT do
        raw[i] = {}
        for b = 1, nBins do raw[i][b] = 0 end
    end
    local ev = scenario.ev
    for j = 1, (ev and #(ev.t or {}) or 0) do
        if ev.kind[j] == K.DMG then
            local i = ev.tgt[j]
            if i and i >= 1 and i <= nT then
                local b = math.floor((ev.t[j] or 0) / bucket) + 1
                if b >= 1 and b <= nBins then raw[i][b] = raw[i][b] + (ev.amt[j] or 0) end
            end
        end
    end

    -- 2. smear across neighbours, so a spike cannot be placed in its own bucket
    local smeared = {}
    for i = 1, nT do
        smeared[i] = {}
        for b = 1, nBins do
            local a = raw[i][b - 1] or 0
            local m = raw[i][b] or 0
            local z = raw[i][b + 1] or 0
            smeared[i][b] = 0.25 * a + 0.5 * m + 0.25 * z
        end
    end

    -- 3. perturb and quantise: the shape survives, the numbers do not
    local out, scale = {}, {}
    for i = 1, nT do
        local peak = 0
        for b = 1, nBins do if smeared[i][b] > peak then peak = smeared[i][b] end end
        scale[i] = peak
        out[i] = {}
        local step = peak > 0 and (peak / STEPS) or 1
        for b = 1, nBins do
            local v = smeared[i][b] * (1 + (Hash01(seed, i, b) * 2 - 1) * jitter)
            if v < 0 then v = 0 end
            out[i][b] = math.floor(v / step + 0.5) * step        -- coarse levels only
        end
    end

    return { bins = out, bucket = bucket, sight = sight, trust = trust,
             nBins = nBins, nT = nT, peak = scale, seed = seed }
end

-- The rate this target is expected to be taking over the next `horizon`
-- seconds, as far as `sight` allows. Returns 0 when nothing is remembered.
function FS.Rate(fs, i, t, horizon)
    if not (fs and fs.bins and fs.bins[i]) then return 0 end
    local span = math.min(horizon or fs.sight, fs.sight)
    if span <= 0 then return 0 end
    local from, to = t, t + span
    local total = 0
    local b1 = math.floor(from / fs.bucket) + 1
    local b2 = math.floor(to / fs.bucket) + 1
    for b = b1, b2 do
        if b >= 1 and b <= fs.nBins then
            local lo = math.max(from, (b - 1) * fs.bucket)
            local hi = math.min(to, b * fs.bucket)
            if hi > lo then
                total = total + (fs.bins[i][b] or 0) * ((hi - lo) / fs.bucket)
            end
        end
    end
    return (total / span) * fs.trust
end

FS.BUCKET, FS.SIGHT, FS.TRUST, FS.JITTER = BUCKET, SIGHT, TRUST, JITTER
return FS
