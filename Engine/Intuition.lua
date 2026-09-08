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
-- rest. Returns { [role] = { open = n, rest = n } } and the fight's duration.
local function Profile(rec)
    SM = SM or MD.SimModel
    local K = SM.K
    local dur = rec.dur or 0
    if dur <= 0 or not rec.ev then return nil end
    local open, rest = {}, {}
    for _, r in ipairs(ROLES) do open[r], rest[r] = 0, 0 end
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
        -- per head, so a raid of eight damagers does not read as eight times the
        -- danger one of them is in
        local heads = 0
        for _, who in ipairs(rec.roster or {}) do
            if who.role == r then heads = heads + 1 end
        end
        if heads > 0 and seen[r] then
            out[r] = {
                open = openSpan > 0 and (open[r] / openSpan / heads) or 0,
                rest = restSpan > 0 and (rest[r] / restSpan / heads) or 0,
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
                local zone = rec.zone or "?"
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
            out[role] = { open = median(slot.open), rest = median(slot.rest), n = slot.n }
        end
        return out
    end
    local zones = {}
    for zone, roles in pairs(byZone) do zones[zone] = fold(roles) end
    return { zones = zones, all = fold(all), fights = used, excluded = excludeID,
             skipped = skipped }
end

-- What the healer expects this role to be taking, this many seconds in. Zone
-- first, everything ever seen as the fallback, nothing when neither has enough
-- fights behind it to be worth more than silence.
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

function IN:Describe(prior)
    if not prior then return "no prior" end
    local parts = {}
    for _, r in ipairs(ROLES) do
        local a = prior.all and prior.all[r]
        if a and a.n >= MIN_FIGHTS then
            parts[#parts + 1] = string.format("%s %d/%d per s (open/rest)", r,
                a.open + 0.5, a.rest + 0.5)
        end
    end
    return string.format("%d fight(s)%s: %s", prior.fights or 0,
        prior.excluded and " (holding one out)" or "",
        #parts > 0 and table.concat(parts, ", ") or "nothing confident yet")
end

IN.OPEN_UNTIL, IN.MIN_FIGHTS = OPEN_UNTIL, MIN_FIGHTS
return IN
