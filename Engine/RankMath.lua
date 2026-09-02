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

-- Returns family -> { label, tol, rows = {...}, suggestedID, callout }.
-- Row: { id, rank, cost, cast, heal, hpm, hps, dominated, suggested, isMax }
function RankMath:Compute()
    local SD = MD.SpellData
    local results = {}
    if not MD.player.isDruid then return results end

    local bonus = BonusHealing()
    local crit = NatureCrit()
    local playerLevel = MD.player.level

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
                        known = SD.knownSet[id] or false,
                        isMax = SD.maxRank[family] == id,
                    }
                end
            end

            -- Pareto dominance on (HPM, HPS) — among KNOWN ranks only.
            for i = 1, #rows do
                if rows[i].known then
                    for j = 1, #rows do
                        if i ~= j and rows[j].known
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
                if r.known and not r.dominated and maxRow and r.heal >= 0.4 * maxRow.heal then
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
