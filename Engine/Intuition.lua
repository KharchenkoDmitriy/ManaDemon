local _, MD = ...

--------------------------------------------------------------------------------
-- Healer intuition (docs/SPEC-v0.13.md §8).
--
-- The solver's forecast is honest but blind at the moment it matters most: at
-- the pull nothing has been seen, so SM.SeenDamage is 0, so the demand is 0, so
-- the plan waits -- while any healer who has run the place before is already
-- putting a Lifebloom on the tank because THE TANK IS ABOUT TO GET HIT.
--
-- That knowledge is not clairvoyance. It is memory of OTHER pulls. The author:
--
--   "it should not know the exact future but at least know that some damage is
--    going to be in (like the fight start - tank will probably get damage, or
--    aoe is coming...) as we look logs retrospectively we could make some
--    intuition simulation"
--
-- So: a prior, learned from recordings, keyed by what is knowable before the
-- first hit lands -- the zone you are standing in and the role of the person.
--
-- THE ONE RULE THAT MAKES THIS NOT CHEATING: the prior for a fight is built
-- from every recording EXCEPT that fight. `Build(recs, excludeID)` takes the
-- exclusion as a required argument rather than an option, and the harness
-- asserts that a fight cannot be its own teacher. Learn from the fight you are
-- replaying and you have re-invented seeing the future, with extra steps.
--------------------------------------------------------------------------------

local IN = {}
MD.Intuition = IN

local SM
local OPEN_UNTIL = 10       -- seconds; "the pull" as distinct from "the fight"
local MIN_FIGHTS = 2        -- one fight is an anecdote, not a prior
local ROLES = { "TANK", "HEALER", "DAMAGER" }

local function median(t)
    if #t == 0 then return 0 end
    table.sort(t)
    local m = math.floor(#t / 2)
    if #t % 2 == 1 then return t[m + 1] end
    return (t[m] + t[m + 1]) / 2
end

-- Damage per second per role in one recording, split into the opening and the
-- rest, and expressed as A FRACTION OF THAT TARGET'S MAX HEALTH.
--
-- v0.13.3: absolute rates do not travel. A Sunwell tank with 13k health eating
-- 1400 a second and a level 64 warrior with 4k health eating 400 are in exactly
-- the same trouble, and a prior in raw damage would tell the second one they are
-- about to be fine. Fractions travel; that is what makes a prior learned from
-- somebody else's raid worth anything in your dungeon.
local function MaxHPOf(rec, ti)
    local who = rec.roster and rec.roster[ti]
    if who and (who.maxHP or 0) > 0 then return who.maxHP end
    -- the recorder writes -1 when it could not resolve the unit; the health
    -- snapshots carry the number anyway
    local col = rec.hp and rec.hp.max and rec.hp.max[ti]
    if col then
        for k = 1, #col do if (col[k] or 0) > 0 then return col[k] end end
    end
    return 0
end

local function Profile(rec)
    SM = SM or MD.SimModel
    local K = SM.K
    local dur = rec.dur or 0
    if dur <= 0 or not rec.ev then return nil end
    local open, rest, heads = {}, {}, {}
    for _, r in ipairs(ROLES) do open[r], rest[r], heads[r] = 0, 0, 0 end
    -- how much health each role has between them, so the sum divides correctly
    local pool = {}
    for _, r in ipairs(ROLES) do pool[r] = 0 end
    for ti, who in ipairs(rec.roster or {}) do
        if who.role and pool[who.role] then
            local mx = MaxHPOf(rec, ti)
            if mx > 0 then
                pool[who.role] = pool[who.role] + mx
                heads[who.role] = heads[who.role] + 1
            end
        end
    end
    local seen = {}
    for i = 1, (rec.n or 0) do
        if rec.ev.kind[i] == K.DMG then
            local ti = rec.ev.tgt[i]
            local who = rec.roster and rec.roster[ti]
            local role = who and who.role
            if role and open[role] then
                local t = rec.ev.t[i] or 0
                if t <= OPEN_UNTIL then open[role] = open[role] + (rec.ev.amt[i] or 0)
                else rest[role] = rest[role] + (rec.ev.amt[i] or 0) end
                seen[role] = (seen[role] or 0) + 1
            end
        end
    end
    local out = {}
    local openSpan = math.min(OPEN_UNTIL, dur)
    local restSpan = math.max(0, dur - openSpan)
    for _, r in ipairs(ROLES) do
        if (pool[r] or 0) > 0 and seen[r] then
            -- damage / second / point of that role's total health
            out[r] = {
                open = openSpan > 0 and (open[r] / openSpan / pool[r]) or 0,
                rest = restSpan > 0 and (rest[r] / restSpan / pool[r]) or 0,
            }
        end
    end
    return out
end

-- Build the prior from every recording EXCEPT `excludeID`. The exclusion is not
-- optional: pass nil only when nothing is being replayed.
function IN:Build(recs, excludeID)
    local byZone, all = {}, {}
    local used, skipped = 0, 0
    for _, rec in ipairs(recs or {}) do
        if rec.id == excludeID then
            skipped = skipped + 1
        else
            local p = Profile(rec)
            if p then
                used = used + 1
                -- the encounter, when the record knows it: an imported fight's
                -- `zone` carries its report code, which groups nothing
                local zone = rec.encounter or rec.zone or "?"
                byZone[zone] = byZone[zone] or {}
                for role, v in pairs(p) do
                    byZone[zone][role] = byZone[zone][role] or { open = {}, rest = {}, n = 0 }
                    local slot = byZone[zone][role]
                    slot.open[#slot.open + 1] = v.open
                    slot.rest[#slot.rest + 1] = v.rest
                    slot.n = slot.n + 1
                    all[role] = all[role] or { open = {}, rest = {}, n = 0 }
                    all[role].open[#all[role].open + 1] = v.open
                    all[role].rest[#all[role].rest + 1] = v.rest
                    all[role].n = all[role].n + 1
                end
            end
        end
    end
    local function fold(src)
        local out = {}
        for role, slot in pairs(src) do
            -- the spread matters as much as the middle: a role whose damage is
            -- the same every pull is worth believing, one that swings by five
            -- times between encounters is not
            local lo, hi = math.huge, 0
            for _, v in ipairs(slot.rest) do
                if v < lo then lo = v end
                if v > hi then hi = v end
            end
            local mid = median(slot.rest)
            out[role] = { open = median(slot.open), rest = mid, n = slot.n,
                          spread = (mid > 0 and hi > 0) and (hi / math.max(lo, 1e-9)) or nil }
        end
        return out
    end
    local zones = {}
    for zone, roles in pairs(byZone) do zones[zone] = fold(roles) end
    return { zones = zones, all = fold(all), fights = used, excluded = excludeID,
             skipped = skipped }
end

-- What the healer expects this role to be taking, this many seconds in, AS A
-- FRACTION OF MAX HEALTH PER SECOND. Multiply by the target's max health at the
-- call site. Zone first, everything ever seen as the fallback, nothing when
-- neither has enough fights behind it to be worth more than silence.
function IN:Rate(prior, zone, role, t)
    if not (prior and role) then return 0, nil end
    local src, from = nil, nil
    local z = zone and prior.zones and prior.zones[zone]
    if z and z[role] and z[role].n >= MIN_FIGHTS then src, from = z[role], "zone" end
    if not src and prior.all and prior.all[role] and prior.all[role].n >= MIN_FIGHTS then
        src, from = prior.all[role], "anywhere"
    end
    if not src then return 0, nil end
    return ((t or 0) <= OPEN_UNTIL) and src.open or src.rest, from
end

-- Blur a prior into something worth shipping. Twenty two fights across thirteen
-- encounters is experience, not a lookup table: quantising the rates says so
-- honestly, and stops anybody reading a number off it as if it were a fact
-- about their next pull. `step` is in fractions of max health per second.
function IN:Blur(prior, step)
    step = step or 0.005          -- half a percent of health per second
    local function q(v) return math.floor((v or 0) / step + 0.5) * step end
    local function blurRoles(src)
        local out = {}
        for role, r in pairs(src or {}) do
            out[role] = { open = q(r.open), rest = q(r.rest), n = r.n,
                          spread = r.spread and (math.floor(r.spread * 10 + 0.5) / 10) or nil }
        end
        return out
    end
    local zones = {}
    for zone, roles in pairs(prior.zones or {}) do zones[zone] = blurRoles(roles) end
    return { zones = zones, all = blurRoles(prior.all), fights = prior.fights,
             blurred = step, excluded = prior.excluded, skipped = prior.skipped }
end

-- A prior that came out of a table rather than out of recordings: the shipped
-- one in Data/Intuition_TBC.lua, or anything else in that shape.
function IN:Load(t)
    if not t then return nil end
    return { zones = t.zones or {}, all = t.all or {}, fights = t.fights or 0,
             blurred = t.blurred, shipped = true, source = t.source }
end

function IN:Describe(prior)
    if not prior then return "no prior" end
    local parts = {}
    for _, r in ipairs(ROLES) do
        local a = prior.all and prior.all[r]
        if a and a.n >= MIN_FIGHTS then
            parts[#parts + 1] = string.format("%s %.1f%%/%.1f%% of health per s (open/rest)",
                r, a.open * 100, a.rest * 100)
        end
    end
    return string.format("%d fight(s)%s%s: %s", prior.fights or 0,
        prior.excluded and " (holding one out)" or "",
        prior.shipped and " [shipped]" or (prior.blurred and " [blurred]" or ""),
        #parts > 0 and table.concat(parts, ", ") or "nothing confident yet")
end

IN.OPEN_UNTIL, IN.MIN_FIGHTS = OPEN_UNTIL, MIN_FIGHTS
return IN
