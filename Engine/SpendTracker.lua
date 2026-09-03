-- Spend tracker: exponentially-weighted event-rate estimator over successful
-- casts. Costs come from GetSpellPowerCost (live, any class — this is what
-- makes TTO class-generic) with the static SpellData table as fallback;
-- spells with no resolvable cost are logged, never guessed.
local _, MD = ...

local ST = {}
MD.Spend = ST

local events = {}          -- { {t, cost}, ... } newest last; pruned to 60s
local WINDOW = 60

ST.unknown = {}            -- spellID -> true, spells we couldn't price
ST.combat = { casts = 0, maxRankCasts = 0, spent = 0 }

-- Pull-time seed (accepted "light history" design): decays fast so real casts
-- take over within ~10s.
local seed = nil
local SEED_HALFLIFE = 10

local function Prune(now)
    while events[1] and now - events[1][1] > WINDOW do
        table.remove(events, 1)
    end
end

-- Returns cost, source ("api" | "table") or nil when unpriceable. Live first
-- (the client applies talents / form itself), static table as fallback.
local function ResolveCost(spellID)
    return MD.SpellData:GetCost(spellID)
end

MD:On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit ~= "player" or type(spellID) ~= "number" then return end
    local now = GetTime()
    local cost, source = ResolveCost(spellID)
    if cost == nil then
        ST.unknown[spellID] = true
        MD:Debug("spend", "unpriced spell %s (%d) - ignored", GetSpellInfo(spellID) or "?", spellID)
        return
    end
    if cost > 0 then
        events[#events + 1] = { now, cost }
        Prune(now)
        ST.combat.casts = ST.combat.casts + 1
        ST.combat.spent = ST.combat.spent + cost
        local isMax = MD.SpellData:IsMaxKnownRank(spellID)
        if isMax then
            ST.combat.maxRankCasts = ST.combat.maxRankCasts + 1
        end
        MD:Debug("spend", "%s (%d) cost %d [%s]%s", GetSpellInfo(spellID) or "?", spellID, cost, source,
            isMax and " max rank" or "")
    else
        MD:Debug("spend", "%s (%d) free [%s]", GetSpellInfo(spellID) or "?", spellID, source)
    end
end)

-- Debug "cast": the client's own cast duration for every spell the player
-- starts, next to what the model expects. This is what settles Nature's Grace
-- (0.5s off the next cast after a crit) and Naturalist on this client -- the
-- spellbook tooltip shows neither. Costs nothing when the category is off.
MD:On("UNIT_SPELLCAST_START", function(unit, _, spellID)
    if unit ~= "player" then return end
    local db = MD.db and MD.db.debug
    if not (db and db.enabled and db.categories.cast) then return end
    if not UnitCastingInfo then return end
    local name, _, _, startMS, endMS = UnitCastingInfo("player")
    if not startMS or not endMS then return end
    local actual = (endMS - startMS) / 1000
    local s = spellID and MD.SpellData.spells[spellID]
    if s and s.cast then
        local base = math.max(s.cast - 0.1 * MD:TalentRank("Naturalist"), 1.5)
        MD:Debug("cast", "%s R%d: live %.2fs - model base %.2fs, after a crit %.2fs (table %.1fs)",
            name or "?", s.rank or 0, actual, base, math.max(base - 0.5, 1.5), s.cast)
    else
        MD:Debug("cast", "%s (%s): live %.2fs", name or "?", tostring(spellID), actual)
    end
end)

function ST:Reset()
    wipe(events)
    seed = nil
end

--------------------------------------------------------------------------------
-- Estimate: rate = lambda * sum(w_i * c_i) — expected mana/sec — plus its
-- one-sigma spread, sigma = lambda * sqrt(sum(w_i^2 * c_i^2)), the weighted
-- compound-Poisson standard deviation of that estimate. For n equal-cost casts
-- sigma/rate = 1/sqrt(n) exactly, so the pessimistic edge (rate + K*sigma in
-- TTO.lua) is in real standard-deviation units and is continuous in the data
-- (the old max(EWMA, p75-of-buckets) kinked whenever the argmax switched).
-- n = priced casts in the last 30s; the warm-up gate uses it because sigma
-- means nothing below ~3 casts. Real casting is autocorrelated, so sigma
-- slightly understates the truth — K and the CV threshold are first guesses.
--------------------------------------------------------------------------------
function ST:Estimate()
    local now = GetTime()
    local lambda = math.log(2) / (MD.db and MD.db.halfLife or 15)
    local sum, sumSq, n = 0, 0, 0
    for i = 1, #events do
        local age, c = now - events[i][1], events[i][2]
        local w = math.exp(-lambda * age)
        sum = sum + w * c
        sumSq = sumSq + w * w * c * c
        if age < 30 then n = n + 1 end
    end
    local rate = sum * lambda
    local sigma = math.sqrt(sumSq) * lambda
    if seed then
        local seedLambda = math.log(2) / SEED_HALFLIFE
        rate = math.max(rate, seed.rate * math.exp(-seedLambda * (now - seed.t)))
    end
    return rate, sigma, n
end

function ST:Rate()
    local rate = ST:Estimate()
    return rate
end

-- True while the pull-time seed still carries weight (~3 half-lives).
function ST:Seeded()
    return seed ~= nil and (GetTime() - seed.t) < 3 * SEED_HALFLIFE
end

--------------------------------------------------------------------------------
-- Window stats: last 30s in six 5s buckets → median / p25 / p75 bucket rates.
-- No longer feeds the TTO (sigma does); kept for the tooltip/dashboard.
--------------------------------------------------------------------------------
function ST:WindowStats()
    local now = GetTime()
    local buckets = { 0, 0, 0, 0, 0, 0 }
    local casts = 0
    for i = 1, #events do
        local age = now - events[i][1]
        if age < 30 then
            local b = math.min(6, math.floor(age / 5) + 1)
            buckets[b] = buckets[b] + events[i][2]
            casts = casts + 1
        end
    end
    local rates = {}
    for i = 1, 6 do rates[i] = buckets[i] / 5 end
    table.sort(rates)
    local median = (rates[3] + rates[4]) / 2
    local p25 = rates[2]
    local p75 = rates[5]
    local stable = casts >= 6 and median > 0 and (p75 - p25) <= 0.4 * median
    return casts, median, p25, p75, stable
end

--------------------------------------------------------------------------------
-- Combat lifecycle: seed the estimator at pull from recent fight history when
-- the window is cold; reset per-combat counters.
--------------------------------------------------------------------------------
MD:On("PLAYER_REGEN_DISABLED", function()
    ST.combat.casts = 0
    ST.combat.maxRankCasts = 0
    ST.combat.spent = 0
    local last = events[#events]
    if (not last or GetTime() - last[1] > 30) and MD.fightHistory and #MD.fightHistory > 0 then
        local rates = {}
        for i = 1, #MD.fightHistory do
            rates[#rates + 1] = MD.fightHistory[i].avgSpendRate or 0
        end
        table.sort(rates)
        local m = rates[math.ceil(#rates / 2)]
        if m and m > 0 then
            seed = { rate = m, t = GetTime() }
            MD:Debug("spend", "pull: seeded %.2f mana/s from %d recorded fight(s)", m, #rates)
        end
    end
end)
