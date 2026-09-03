-- Rank math: per-rank effective heal / HPM / HPS with TBC downranking rules.
-- Formulas (per the design debate, confidence noted in docs/DECISIONS.md):
--   direct coefficient  = clamp(baseCast, 1.5, 3.5) / 3.5
--   HoT coefficient     = duration / 15
--   hybrid (Regrowth)   = portions weighted by c/(c+h), h/(c+h)
--   sub-level-20 malus  = 1 - (20 - spellLevel) * 0.0375
--   downrank penalty    = min(1, (spellLevel + 11) / casterLevel)
--   healing crits are 1.5x, HoTs never crit.
-- Penalties apply to the BONUS-healing contribution, not the base heal.
local _, MD = ...

local RankMath = {}
MD.RankMath = RankMath

local function BonusHealing()
    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

local function NatureCrit()
    if GetSpellCritChance then
        local ok, v = pcall(GetSpellCritChance, 4) -- 4 = nature school
        if ok and type(v) == "number" then return v / 100 end
    end
    return 0
end

local function Penalty(spellLevel, playerLevel)
    local downrank = math.min(1, (spellLevel + 11) / math.max(playerLevel, 1))
    local sub20 = spellLevel < 20 and (1 - (20 - spellLevel) * 0.0375) or 1
    return downrank * sub20
end

-- Chain-casts until the next cast is unaffordable: each cast nets
-- (cost - regen * interval) mana, so floor((mana - cost) / net) + 1 casts.
-- math.huge when regen covers the cost, 0 when mana < cost.
function RankMath:CastsToOOM(cost, interval, mana, regen)
    if cost <= 0 then return math.huge end
    local net = cost - regen * interval
    if net <= 0 then return math.huge end
    if mana < cost then return 0 end
    return math.floor((mana - cost) / net) + 1
end

-- Returns family -> { label, tol, rows = {...}, suggestedID, callout }; the
-- inputs used (bonus, statBonus, treeAura, inTree) are left in RankMath.info.
-- Row: { id, rank, cost, cast, heal, hpm, hps, hp5 (sustained healing per 5s
-- at zero mana, regen-paced, 5SR-aware; nil without base regen), casts
-- (chain-casts to OOM from current mana, math.huge when regen covers the
-- cost), dominated, suggested, isMax }
function RankMath:Compute()
    local SD = MD.SpellData
    local results = {}
    if not MD.player.isDruid then return results end

    -- Tree of Life aura: party members (the tree included) receive extra
    -- healing equal to 25% of the druid's Spirit. It is a "healing received"
    -- aura on the targets, so GetSpellBonusHealing() never shows it, but it
    -- goes through the same coefficient/penalty path as +healing (MaNGOS-era
    -- SpellHealingBonus: taken advertised benefit * coeff). Counted while in
    -- form unless the setting is off; only true for targets in your party.
    -- Simulation overrides (MD.sim, session-only, set from the dashboard's
    -- "Simulate" strip): nil = live value. Only the rank math reads them;
    -- the clock, widget and advisor always use real inputs.
    local sim = MD.sim or {}
    local liveBonus = BonusHealing()
    local statBonus = sim.heal or liveBonus
    local treeAura = 0
    if MD:InTreeForm() and not (MD.db and MD.db.treeAura == false) then
        treeAura = 0.25 * (UnitStat("player", 5) or 0)
    end
    local bonus = statBonus + treeAura
    local liveCrit = NatureCrit()
    local crit = sim.crit and (sim.crit / 100) or liveCrit
    local playerLevel = MD.player.level
    -- Chain-cast budget: every cast nets (cost - castingRegen * interval);
    -- from the current mana that allows floor((mana - cost) / net) + 1 casts
    -- (interval = cast time, or the 1.5s GCD for instants). Casting regen is
    -- the in-5SR rate (Intensity, gear mp5, Dreamstate) since spamming keeps
    -- you inside the five-second rule the whole time.
    local liveMana = UnitPower("player", 0) or 0
    local liveCasting = MD.Regen and MD.Regen.casting or 0
    local liveBase = MD.Regen and MD.Regen.base or 0
    local mana = sim.mana or liveMana
    local castingRegen = sim.casting and (sim.casting / 5) or liveCasting
    local baseRegen = sim.base and (sim.base / 5) or liveBase
    -- Sustained output at zero mana (author's "HP5"): cast only when regen has
    -- paid for it. Each cast starts 5s of casting regen, then base regen runs
    -- until the next cast is affordable, so the steady-state interval is
    --   T = cost / casting            if 5s of casting regen already cover it
    --   T = 5 + (cost - 5*casting) / base   otherwise
    -- never shorter than the cast itself. HP5 = 5 * heal / T. Nil when base
    -- regen is zero (cannot sustain anything).
    local function SustainedInterval(cost, interval)
        if cost <= 0 then return interval end
        local T
        if castingRegen > 0 and cost <= 5 * castingRegen then
            T = cost / castingRegen
        elseif baseRegen > 0 then
            T = 5 + (cost - 5 * castingRegen) / baseRegen
        else
            return nil
        end
        return math.max(T, interval)
    end
    local function CastsToOOM(cost, interval)
        return RankMath:CastsToOOM(cost, interval, mana, castingRegen)
    end
    RankMath.info = { bonus = bonus, statBonus = statBonus, treeAura = treeAura, inTree = MD:InTreeForm(),
                      mana = mana, castingRegen = castingRegen, baseRegen = baseRegen, crit = crit,
                      simulated = next(sim) ~= nil,
                      live = { heal = liveBonus, crit = liveCrit * 100, casting = liveCasting * 5,
                               base = liveBase * 5, mana = liveMana } }

    local goN = 1 + 0.02 * MD:TalentRank("Gift of Nature")
    local empTouch = 1 + 0.10 * MD:TalentRank("Empowered Touch")
    local empRejuv = 1 + 0.04 * MD:TalentRank("Empowered Rejuvenation")
    local impRejuv = 1 + 0.05 * MD:TalentRank("Improved Rejuvenation")
    local regrowthCrit = math.min(1, crit + 0.10 * MD:TalentRank("Improved Regrowth"))
    local naturalist = 0.1 * MD:TalentRank("Naturalist") -- -0.1s HT cast per rank

    for _, family in ipairs(SD.familyOrder) do
        local info = SD.families[family]
        local allIDs = SD.all[family]
        if info and not info.exclude and allIDs and #allIDs > 0 then
            local rows = {}
            for _, id in ipairs(allIDs) do
                local s = SD.spells[id]
                local pen = Penalty(s.level, playerLevel)
                local heal, castTime

                if info.type == "direct" then
                    castTime = math.max(s.cast - naturalist, 1.5)
                    local coef = math.min(math.max(s.cast, 1.5), 3.5) / 3.5
                    local avg = (s.healMin + s.healMax) / 2
                    heal = (avg + bonus * coef * pen * empTouch) * goN * (1 + 0.5 * crit)

                elseif info.type == "hot" then
                    castTime = 1.5 -- GCD
                    local coef = s.hotDuration / 15
                    heal = (s.hotTotal + bonus * coef * pen * empRejuv) * goN * impRejuv

                elseif info.type == "hybrid" then
                    castTime = math.max(s.cast, 1.5)
                    local c = math.min(math.max(s.cast, 1.5), 3.5) / 3.5
                    local h = s.hotDuration / 15
                    local dCoef = c * c / (c + h)
                    local hCoef = h * h / (c + h)
                    local avg = (s.healMin + s.healMax) / 2
                    local direct = (avg + bonus * dCoef * pen) * goN * (1 + 0.5 * regrowthCrit)
                    local hot = (s.hotTotal + bonus * hCoef * pen * empRejuv) * goN
                    heal = direct + hot

                elseif info.type == "lifebloom" then
                    castTime = 1.5 -- GCD
                    -- One application ticking to completion plus its bloom.
                    -- Empowered Rejuvenation on the bloom portion is unverified,
                    -- so it is applied to the tick portion only (conservative).
                    local hot = (s.hotTotal + bonus * SD.lifebloomHotCoef * pen * empRejuv) * goN
                    local bloom = (s.bloom + bonus * SD.lifebloomBloomCoef * pen) * goN
                    heal = hot + bloom
                end

                if heal then
                    local cost = SD:GetCost(id)
                    rows[#rows + 1] = {
                        id = id, rank = s.rank, level = s.level,
                        cost = cost, cast = castTime, heal = heal,
                        hpm = cost > 0 and heal / cost or 0,
                        hps = heal / castTime,
                        hp5 = (function() local T = SustainedInterval(cost, castTime) return T and 5 * heal / T or nil end)(),
                        casts = CastsToOOM(cost, castTime),
                        known = SD.knownSet[id] or false,
                        isMax = SD.maxRank[family] == id,
                    }

                    -- Rolling Lifebloom stacks: each refresh cast is paid for
                    -- with 6 ticks at the stack's multiplier (one tick is lost
                    -- to the refresh) and never a bloom (the stack is renewed
                    -- before it expires). Informational rows: excluded from
                    -- Pareto / suggestion because they are a different activity
                    -- from a single application.
                    if info.type == "lifebloom" then
                        local tick = (s.hotTotal + bonus * SD.lifebloomHotCoef * pen * empRejuv) * goN / 7
                        for stacks = 2, 3 do
                            local h = tick * 6 * stacks
                            rows[#rows + 1] = {
                                id = id, rank = s.rank, level = s.level,
                                rankLabel = "x" .. stacks, virtual = true,
                                cost = cost, cast = castTime, heal = h,
                                hpm = cost > 0 and h / cost or 0,
                                hps = h / castTime,
                                hp5 = (function() local T = SustainedInterval(cost, castTime) return T and 5 * h / T or nil end)(),
                                casts = CastsToOOM(cost, castTime),
                                known = SD.knownSet[id] or false,
                                isMax = false,
                            }
                        end
                    end
                end
            end

            -- Pareto dominance on (HPM, HPS) — among KNOWN, real ranks only.
            for i = 1, #rows do
                if rows[i].known and not rows[i].virtual then
                    for j = 1, #rows do
                        if i ~= j and rows[j].known and not rows[j].virtual
                            and rows[j].hpm >= rows[i].hpm and rows[j].hps >= rows[i].hps
                            and (rows[j].hpm > rows[i].hpm or rows[j].hps > rows[i].hps) then
                            rows[i].dominated = true
                            break
                        end
                    end
                end
            end

            -- Suggested rank: highest-HPM known non-dominated rank that still
            -- heals >= 40% of the max known rank (assumption: below that,
            -- cast-count pressure outweighs efficiency).
            local maxRow
            for i = 1, #rows do
                if rows[i].isMax then maxRow = rows[i] end
            end
            local suggested
            for i = 1, #rows do
                local r = rows[i]
                if r.known and not r.virtual and not r.dominated and maxRow and r.heal >= 0.4 * maxRow.heal then
                    if not suggested or r.hpm > suggested.hpm then
                        suggested = r
                    end
                end
            end
            suggested = suggested or maxRow
            if suggested then suggested.suggested = true end

            local callout
            if suggested and maxRow and suggested ~= maxRow then
                callout = string.format(
                    "R%d: %d heal for %d mana (%.2f HPM). R%d costs %.1fx the mana for %.1fx the heal.",
                    suggested.rank, suggested.heal, suggested.cost, suggested.hpm,
                    maxRow.rank, maxRow.cost / suggested.cost, maxRow.heal / suggested.heal)
            elseif suggested then
                callout = string.format("Max rank (R%d) is also your most efficient usable rank.", suggested.rank)
            end

            results[family] = {
                label = info.label,
                tol = info.tol,
                rows = rows,
                suggestedID = suggested and suggested.id or nil,
                callout = callout,
            }
        end
    end

    return results
end

-- Map of family -> suggested rank number, for the gear-change toast diff.
function RankMath:SuggestedRanks()
    local out = {}
    for family, res in pairs(RankMath:Compute()) do
        if res.suggestedID then
            out[family] = MD.SpellData.spells[res.suggestedID].rank
        end
    end
    return out
end
