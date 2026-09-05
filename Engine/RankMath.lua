-- Rank math: per-rank effective heal / HPM / HPS with TBC downranking rules.
-- Formulas (per the design debate, confidence noted in docs/DECISIONS.md):
--   direct coefficient  = clamp(baseCast, 1.5, 3.5) / 3.5
--   HoT coefficient     = duration / 15
--   hybrid (Regrowth)   = portions weighted by c/(c+h), h/(c+h)
--   sub-level-20 malus  = 1 - (20 - spellLevel) * 0.0375
--   downrank penalty    = min(1, (spellLevel + 11) / casterLevel)
--   healing crits are 1.5x, HoTs never crit.
-- Penalties apply to the BONUS-healing contribution, not the base heal.
--
-- Structure (docs/DESIGN-v0.5.md §1.3): Context() resolves every input once
-- (simulation overrides are applied THERE and nowhere else), RowFor() turns one
-- spell into one row, Compute() runs every family plus the Pareto/suggestion
-- pass, and Explain() rebuilds a single row with its intermediate terms for the
-- dashboard tooltip. RowFor only allocates row.calc when asked, because the
-- dashboard re-renders every 2s and those tables would be pure garbage.
local _, MD = ...

local RankMath = {}
MD.RankMath = RankMath

local EMPTY = {}

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

--------------------------------------------------------------------------------
-- Context: every input the rank math reads, resolved once.
--
-- Tree of Life aura: party members (the tree included) receive extra healing
-- equal to 25% of the druid's Spirit. It is a "healing received" aura on the
-- targets, so GetSpellBonusHealing() never shows it, but it goes through the
-- same coefficient/penalty path as +healing (MaNGOS-era SpellHealingBonus:
-- taken advertised benefit * coeff). Counted while in form unless the setting
-- is off; only true for targets in your party.
--
-- Simulation overrides (MD.sim, session-only, set from the dashboard's
-- "Simulate" strip): nil = live value. Only the rank math reads them; the
-- clock, widget and advisor always use real inputs.
--------------------------------------------------------------------------------
function RankMath:Context()
    local SD = MD.SpellData
    local sim = MD.sim or EMPTY

    local liveBonus = BonusHealing()
    local statBonus = sim.heal or liveBonus
    local relic = SD:Relic()

    -- A simulated form changes the aura AND the costs; keep the two in step.
    local inTree
    if sim.tree ~= nil then inTree = sim.tree else inTree = MD:InTreeForm() end

    local treeAura = 0
    if inTree and not (MD.db and MD.db.treeAura == false) then
        treeAura = 0.25 * (UnitStat("player", 5) or 0) + (relic and relic.aura or 0)
    end

    local liveCrit = NatureCrit()
    local crit = sim.crit and (sim.crit / 100) or liveCrit

    -- Chain-cast budget: every cast nets (cost - castingRegen * interval);
    -- from the current mana that allows floor((mana - cost) / net) + 1 casts
    -- (interval = cast time, or the 1.5s GCD for instants). Casting regen is
    -- the in-5SR rate (Intensity, gear mp5, Dreamstate) since spamming keeps
    -- you inside the five-second rule the whole time.
    local liveMana = UnitPower("player", 0) or 0
    local liveCasting = MD.Regen and MD.Regen.casting or 0
    local liveBase = MD.Regen and MD.Regen.base or 0

    local ctx = {
        bonus = statBonus + treeAura,
        statBonus = statBonus,
        treeAura = treeAura,
        inTree = inTree,
        relic = relic,
        crit = crit,
        playerLevel = MD.player.level,
        mana = sim.mana or liveMana,
        castingRegen = sim.casting and (sim.casting / 5) or liveCasting,
        baseRegen = sim.base and (sim.base / 5) or liveBase,

        goN = 1 + 0.02 * MD:TalentRank("Gift of Nature"),
        empTouch = 1 + 0.10 * MD:TalentRank("Empowered Touch"),
        empRejuv = 1 + 0.04 * MD:TalentRank("Empowered Rejuvenation"),
        impRejuv = 1 + 0.05 * MD:TalentRank("Improved Rejuvenation"),
        naturalist = 0.1 * MD:TalentRank("Naturalist"), -- -0.1s HT cast per rank

        simulated = next(sim) ~= nil,
        live = { heal = liveBonus, crit = liveCrit * 100, casting = liveCasting * 5,
                 base = liveBase * 5, mana = liveMana },
    }
    ctx.regrowthCrit = math.min(1, crit + 0.10 * MD:TalentRank("Improved Regrowth"))

    -- Nature's Grace: a spell critical takes 0.5s off the NEXT cast, never
    -- below the 1.5s GCD. Chain-casting one spell, the fraction of casts that
    -- follow a crit is the crit chance, so the throughput-correct cast time is
    -- the MIXTURE -- not (cast - 0.5 * crit) floored, which clips the wrong
    -- branch when cast - 0.5 lands on the GCD. Throughput over a chain is
    -- heal / E[T] exactly, so averaging the cast time is right for a sustained
    -- column. HoTs never crit and sit at the GCD anyway, so it is a no-op for
    -- them twice over. Assumed 0.5s until the "cast" debug category confirms
    -- it on this client (docs/DESIGN-v0.5.md F1).
    ctx.naturesGrace = (MD:TalentRank("Nature's Grace") > 0
        and not (MD.db and MD.db.naturesGrace == false)) and 0.5 or 0
    ctx.ExpectedCast = function(T0, p)
        if ctx.naturesGrace <= 0 or p <= 0 then return T0 end
        return (1 - p) * T0 + p * math.max(T0 - ctx.naturesGrace, 1.5)
    end

    -- Cost source. The live client value is exact (it applies talents and form
    -- itself), so it stays the default. It is wrong the moment the dashboard
    -- simulates a form or a talent rank the player does not actually have, and
    -- only then does the static table (with those overrides) take over.
    local costOverride = (sim.tree ~= nil) or (sim.moonglow ~= nil)
    ctx.costCtx = costOverride and { inTree = inTree, moonglow = sim.moonglow } or nil
    ctx.CostFor = function(id)
        if ctx.costCtx then
            return SD:StaticCost(id, ctx.costCtx), "table (simulated)"
        end
        return SD:GetCost(id)
    end

    ctx.CastsToOOM = function(cost, interval)
        return RankMath:CastsToOOM(cost, interval, ctx.mana, ctx.castingRegen)
    end

    return ctx
end

--------------------------------------------------------------------------------
-- One row from one spell.
--   variant  nil for the real rank; 2 or 3 for the rolling Lifebloom stacks
--   explain  fills row.calc with every intermediate term (tooltip only)
-- Row: { id, rank, level, cost, cast, heal, hpm, hps, casts (chain-casts to
-- OOM from current mana, math.huge when regen covers the cost), known, isMax;
-- overheal + effHeal/effHpm/effHps when the combat log has enough samples;
-- dominated/suggested are set by Compute() }
-- HP5 ("sustained healing per 5s") was removed in v0.6.0: chain-casting inside
-- the 5SR it reduces to 5 x castingRegen x HPM, so it ordered every rank
-- exactly like HPM and carried no information of its own.
--------------------------------------------------------------------------------
function RankMath:RowFor(spellID, ctx, variant, explain)
    local SD = MD.SpellData
    local s = SD.spells[spellID]
    if not s then return nil end
    local info = SD.families[s.family]
    if not info then return nil end

    local pen = Penalty(s.level, ctx.playerLevel)
    local relic = ctx.relic
    -- relic bonus for this family: flat goes on the BASE heal, perTick on
    -- each Lifebloom tick
    local relicFlat = (relic and relic.family == s.family and relic.flat) or 0
    local relicTick = (relic and relic.family == s.family and relic.perTick) or 0
    local bonus = ctx.bonus

    local heal, castTime, calc

    local castBase, ngCrit

    if info.type == "direct" then
        castBase = math.max(s.cast - ctx.naturalist, 1.5)
        ngCrit = ctx.crit
        castTime = ctx.ExpectedCast(castBase, ngCrit)
        -- the coefficient uses the spell's BASE cast time, not the modified one
        local coef = math.min(math.max(s.cast, 1.5), 3.5) / 3.5
        local base = (s.healMin + s.healMax) / 2 + relicFlat
        local bonusOut = bonus * coef * pen * ctx.empTouch
        local critMult = 1 + 0.5 * ctx.crit
        heal = (base + bonusOut) * ctx.goN * critMult
        if explain then
            calc = { kind = "direct", base = (s.healMin + s.healMax) / 2, relicFlat = relicFlat,
                     bonus = bonus, coef = coef, penalty = pen, bonusMult = ctx.empTouch,
                     bonusMultName = "Empowered Touch", bonusOut = bonusOut,
                     talentMult = ctx.goN, critMult = critMult, crit = ctx.crit }
        end

    elseif info.type == "hot" then
        castTime = 1.5 -- GCD
        local coef = s.hotDuration / 15
        local bonusOut = bonus * coef * pen * ctx.empRejuv
        heal = (s.hotTotal + relicFlat + bonusOut) * ctx.goN * ctx.impRejuv
        if explain then
            calc = { kind = "hot", base = s.hotTotal, relicFlat = relicFlat,
                     bonus = bonus, coef = coef, penalty = pen, bonusMult = ctx.empRejuv,
                     bonusMultName = "Empowered Rejuvenation", bonusOut = bonusOut,
                     talentMult = ctx.goN * ctx.impRejuv,
                     duration = s.hotDuration, ticks = s.hotDuration / 3 }
        end

    elseif info.type == "hybrid" then
        castBase = math.max(s.cast, 1.5)
        ngCrit = ctx.regrowthCrit
        castTime = ctx.ExpectedCast(castBase, ngCrit)
        local c = math.min(math.max(s.cast, 1.5), 3.5) / 3.5
        local h = s.hotDuration / 15
        local dCoef = c * c / (c + h)
        local hCoef = h * h / (c + h)
        local base = (s.healMin + s.healMax) / 2 + relicFlat
        local dBonus = bonus * dCoef * pen
        local hBonus = bonus * hCoef * pen * ctx.empRejuv
        local critMult = 1 + 0.5 * ctx.regrowthCrit
        local direct = (base + dBonus) * ctx.goN * critMult
        local hot = (s.hotTotal + hBonus) * ctx.goN
        heal = direct + hot
        if explain then
            calc = { kind = "hybrid", base = (s.healMin + s.healMax) / 2, relicFlat = relicFlat,
                     bonus = bonus, penalty = pen, talentMult = ctx.goN,
                     directCoef = dCoef, directBonus = dBonus, direct = direct,
                     hotCoef = hCoef, hotBonus = hBonus, hot = hot, hotBase = s.hotTotal,
                     bonusMult = ctx.empRejuv, bonusMultName = "Empowered Rejuvenation",
                     critMult = critMult, crit = ctx.regrowthCrit,
                     duration = s.hotDuration }
        end

    elseif info.type == "lifebloom" then
        castTime = 1.5 -- GCD
        -- One application ticking to completion plus its bloom.
        -- Verified 2026-09-03 (heal log): tick 87 = (273 + 450*0.5187*1.2)*1.1/7,
        -- bloom 864 = (600 + 450*0.3422*1.2)*1.1 -> Empowered Rejuvenation
        -- applies to the bloom too.
        local hotBonus = bonus * SD.lifebloomHotCoef * pen * ctx.empRejuv
        local bloomBonus = bonus * SD.lifebloomBloomCoef * pen * ctx.empRejuv
        local hot = (s.hotTotal + 7 * relicTick + hotBonus) * ctx.goN
        local bloom = (s.bloom + bloomBonus) * ctx.goN
        if variant then
            -- Rolling stacks: each refresh cast is paid for with 6 ticks at the
            -- stack's multiplier (one tick is lost to the refresh) and never a
            -- bloom (the stack is renewed before it expires).
            heal = (hot / 7) * 6 * variant
        else
            heal = hot + bloom
        end
        if explain then
            calc = { kind = "lifebloom", base = s.hotTotal, relicTick = relicTick,
                     bonus = bonus, penalty = pen, bonusMult = ctx.empRejuv,
                     bonusMultName = "Empowered Rejuvenation", talentMult = ctx.goN,
                     hotCoef = SD.lifebloomHotCoef, hotBonus = hotBonus, hot = hot,
                     bloomCoef = SD.lifebloomBloomCoef, bloomBonus = bloomBonus,
                     bloomBase = s.bloom, bloom = bloom,
                     tick = hot / 7, stacks = variant, duration = s.hotDuration }
        end
    end

    if not heal then return nil end

    local cost, costSource = ctx.CostFor(spellID)
    cost = cost or 0

    local row = {
        id = spellID, rank = s.rank, level = s.level,
        cost = cost, cast = castTime, heal = heal,
        hpm = cost > 0 and heal / cost or 0,
        hps = heal / castTime,
        casts = ctx.CastsToOOM(cost, castTime),
        known = SD.knownSet[spellID] or false,
        isMax = (not variant) and SD.maxRank[s.family] == spellID or false,
        ng = castBase ~= nil and castTime < castBase - 0.001 or false,
    }
    if variant then
        row.variant = variant
        row.rankLabel = "x" .. variant
        row.virtual = true
    end

    -- Overheal calibration: what the spell is worth on the targets this player
    -- actually heals. Carried alongside the raw numbers, never instead of them
    -- -- the Pareto filter and the suggested rank stay on raw values so a noisy
    -- measurement can never fire a "rebind?" toast (docs/DESIGN-v0.5.md F3).
    if MD.Overheal then
        local frac, n, scope = MD.Overheal:Fraction(spellID)
        if frac then
            local k = 1 - frac
            row.overheal = { frac = frac, n = n, scope = scope }
            row.effHeal = row.heal * k
            row.effHpm = row.hpm * k
            row.effHps = row.hps * k
        end
    end

    if calc then
        calc.family = s.family
        calc.label = info.label
        calc.type = info.type
        calc.cost = cost
        calc.costSource = costSource
        calc.castBase = castBase or castTime
        calc.castNG = castTime
        calc.ngCrit = ngCrit
        calc.naturesGrace = ctx.naturesGrace
        calc.mana = ctx.mana
        calc.castingRegen = ctx.castingRegen
        calc.baseRegen = ctx.baseRegen
        calc.netPerCast = cost - ctx.castingRegen * castTime
        calc.overheal = row.overheal
        row.calc = calc
    end
    return row
end

-- One row plus its full breakdown, for the dashboard tooltip. Rebuilt from a
-- fresh context so it always matches what the table is showing.
function RankMath:Explain(spellID, variant)
    return RankMath:RowFor(spellID, RankMath:Context(), variant, true)
end

--------------------------------------------------------------------------------
-- Returns family -> { label, tol, rows = {...}, suggestedID, callout }; the
-- inputs used are left in RankMath.info (the context).
--------------------------------------------------------------------------------
function RankMath:Compute()
    local SD = MD.SpellData
    local results = {}
    if not MD.player.isDruid then return results end

    local ctx = RankMath:Context()
    RankMath.info = ctx

    for _, family in ipairs(SD.familyOrder) do
        local info = SD.families[family]
        local allIDs = SD.all[family]
        if info and not info.exclude and allIDs and #allIDs > 0 then
            local rows = {}
            for _, id in ipairs(allIDs) do
                local row = RankMath:RowFor(id, ctx)
                if row then
                    rows[#rows + 1] = row
                    -- Informational rolling-stack rows: excluded from Pareto /
                    -- suggestion because they are a different activity from a
                    -- single application.
                    if info.type == "lifebloom" then
                        for stacks = 2, 3 do
                            rows[#rows + 1] = RankMath:RowFor(id, ctx, stacks)
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
