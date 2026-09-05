# JUDGE — ManaDemon v0.7 design debate: final verdicts

Judge's own checks against `.logs/dungeon-BF-1.txt` (30 pulls): gate ≥20s/≥5 casts passes **18**, ≥15s/≥4 passes **25**, ≥25s/≥8 passes only **13**; median fight 24.6s and **6** own casts (B's "8" and A's "~11 among qualifiers" both overstate); LB→LB gap median **5.02s** (p25 2.33, p75 6.75 — A's figure); inter-cast gap p10/p25 **1.50/1.52s**, 17 gaps under 1.45s (both parties correct); the six most expensive fights spend 28.7k of ~60k combat mana (B correct). Per-fight spend from the `[spend]` lines matches the `[combat] end` lines (hard pull 6,169 = "6.2k"). Nothing either party built an argument on was materially wrong; where they diverged the verdicts below say who carried.

Context weighed throughout: solo author = only tester; non-heroic 5-mans now, heroics/raids later; "wait" is a valid action; replay/coaching is the killer feature; no Lua interpreter off-game; everything must be executable from the spec without re-litigation.

---

## Verdicts

### C1. Deterministic EV vs Monte Carlo

**VERDICT: Deterministic expected value everywhere in v0.7 replay and search. Triage rules are sized on the NON-CRIT heal. Robustness on a replay card = re-run the winning plan on every other retained full stream and print "held on N of M". Monte Carlo (K = 30 crit/jitter replicates of the 3 reported plans only) ships with synthetic Setup (v0.7.7), never inside the search, never on a replay card.**

RATIONALE: B's rebuttal §2.2 carried: on a replay the damage stream is frozen, the only stochastic input left is crit, whose σ is ~2% of total healing (A's own arithmetic), so 30 replicates report P(death)=0 on 27 of 27 fights and never inform. A's point that a single triage Regrowth is a 1282-vs-2144 bet is real but is answered by sizing the triage rule on the non-crit heal (both parties converged), not by sampling. A's cross-scenario vs within-scenario distinction is correct and is why MC survives — in synthetic mode, where C13 supplies a distribution and P(floor violation) is the question being asked.

IMPLEMENTATION NOTE: `SimModel` applies every heal through ONE function that takes `critMode = "ev" | "roll"` (and a seeded RNG for "roll") so the replicate path is a flag, not a fork. `RankMath:EventPrediction`'s `direct` (crit stripped) is what rule 2 compares against the deficit; the EV crit multiplier applies to landed amounts only.

### C2. Rule family vs richer policy space

**VERDICT: The fixed-order five-rule family stands (≤5 binds, ≤2 ranks per spell), with these exact parameters: (1) `swiftmend below=T_s`, T_s ∈ {0.30, 0.40}; (2) `direct below=T_d spell=<Regrowth|Healing Touch>:<rank>`, T_d ∈ {0.35, 0.45, 0.55}; (3) `roll Lifebloom:<rank> x N on tank`, N ∈ {0, 1, 3} (0 = no roll); (4) `hot Rejuvenation:<rank> below=T_h` on any tracked target without it, T_h ∈ {0.60, 0.80, 0.90}; (5) `filler` ∈ {wait, Lifebloom:1 on tank}. No DP, no learned thresholds, no per-phase plans. The ENGINE models every action the log contains (NS+HT, shapeshifts, utility casts, Innervate, potions, Tranquility) for replay; the PLANNER emits only the five rules. A's physical lower bound is kept as a Debug-console assertion only, never a card number.**

RATIONALE: A's rebuttal separating engine expressiveness (mandatory for replay) from planner expressiveness (deliberately small) resolved B's "a family that cannot express NS+HT cannot reproduce the fight" — reproduction is the engine's job. B's rebuttal §2.1 carried against the bound on the card: on 14 of 18 qualifying pulls the headroom formula degenerates to "heal almost nothing" (~0.5k), which is arithmetically true and behaviourally useless; its genuine value is falsifying the search. B's "shrink to 3 spells / 2 thresholds" is rejected in favour of the C14 decision (binds fixed to what the player uses by default), which shrinks the search far more effectively without amputating the family. B's tank/other threshold split is not adopted: with 6 median casts per fight the parameter count must go down, not up.

IMPLEMENTATION NOTE: `SimPlanner` rule evaluation order is fixed in code; target choice inside a rule is lowest HP fraction first, tank on ties. `Debug("sim", ...)` logs `manaFloor = Σ max(0, D_i − (hp0_i − floor·maxHP_i)) / maxHPM` per Coach run and asserts `best.manaSpent >= manaFloor`.

### C3. Overheal endogenous vs blended

**VERDICT: Endogenous only (HP cap). The two mechanisms that close the simulated-vs-measured gap are causality (C12) and cast commitment (Additional). Simulated overheal per family is printed on every card beside `Overheal:FamilyFraction` as a NAMED residual ("sim 14% / measured 39% Lifebloom"). On a replay of the real casts, simulated effective healing vs logged effective healing is a reported validation curve (per fight, per family), not a pass/fail gate in v0.7.**

RATIONALE: Both parties converged on endogenous; B's position that the replay overheal curve is the most sensitive validation signal is right, and A's caution that it be promoted to a gate only once commitment and causality exist is also right — for v0.7 it is reported, with a documented promotion rule. Blending the measured fraction anywhere on the scoring path double-counts (design §12.3 ratified).

IMPLEMENTATION NOTE: `result.overheal = { byFamily = {...}, measured = {...} }`; Review row tooltip shows "effective healing: sim X / logged Y (Δ %)". Promotion rule to write in DECISIONS: becomes a gate at ≤10% |Δ| once ≥5 recordings pass all other gates.

### C4. Other healers

**VERDICT: Environment in replay, assignment in synthetic — ratified. One gate, no bracket: `foreignShare = Σ foreign effective heal on tracked targets / Σ all effective heal on them`; Coach enabled iff `foreignShare <= db.simForeignShare` (default 0.25); above it the fight is Validate-only with the reason printed. The share is printed on every Review row regardless.**

RATIONALE: B's rebuttal §2.6 carried: A's bracket doubles the most expensive component (a second full search) to describe a number that is 0% in all the author's current content, and the raid case where it would matter is out of recorder budget anyway. A's threshold ladder is collapsed to its top rung; 25% is A's own number and B accepted it.

IMPLEMENTATION NOTE: The recorder stores foreign heal events as `{t, target, -effective}` (via `OH:Split`); `foreignShare` is computed at fight end and stored in the stream header and the summary row. Setting `db.simForeignShare = 0.25` with provenance "BF-1: 0% foreign; threshold is a prior".

### C5. Event-driven vs fixed step

**VERDICT: Event-driven, ratified as low-stakes. Budget assumptions written into the spec: 1,000–1,500 events per 3-minute 5-man run, 10–20 ms per plan evaluation (not 1 ms), zero table allocation inside `SimModel:Run` (pooled event heap, parallel flat arrays for the timeline and trace), early abort when `manaSpent` exceeds the incumbent or a floor breach is unrecoverable.**

RATIONALE: Both converged; A's cost re-estimate (10× the design's) was accepted by B and drives C11's evaluation cap. B's scheduler-bug list (refresh cancelling a scheduled tick, expiry vs bloom order, death between tick and cast) is the real cost and is addressed by the `/md simrun` self-tests below.

IMPLEMENTATION NOTE: Pending events in a binary heap keyed by (t, seq); ties broken by kind order: damage < foreign heal < tick < expiry/bloom < cast-landed < 5SR-lapse < decision. `Run` takes preallocated scratch tables from a pool and returns them.

### C6. Separate window vs dashboard tabs

**VERDICT: Review ships as the sixth dashboard tab (`UI/Dashboard_Review.lua`, constructor exported on `MD.DashboardParts`), with all provenance in `MD.Tip` tooltips on the row and the card. `UI/SimWindow.lua` arrives with Setup (v0.7.7) and Review moves into it then.**

RATIONALE: B carried on cost and on where the author already is after a run; A conceded in rebuttal. A's demand that provenance travel with every number is adopted — B showed it needs a tooltip, not a window (`MD.Tip:Row/:Columns/:Fights` already do this for the Waste tab).

IMPLEMENTATION NOTE: Tab label "Review". Row: `# | when | zone | dur | targets | casts | spent | lowest mana | validate` with the validate cell reading `ok` / `mana +4%` / `HP: Trecoda 18%` / `death` / `foreign 40%`. Buttons: Validate, Coach, Pin, Export.

### C7. "Wait" as a first-class action

**VERDICT: First-class. `minActivity` default 0, shown prominently. The card reports BOTH `waitFraction` and `maxWaitRun` (length and start time of the longest idle). A wait is causal by construction (C12): the planner decides at events it has seen, so it cannot end a wait "just before" a hit it has not yet seen.**

RATIONALE: Both converged; B's `max(waitRun)` is the single variable that distinguishes an unhurried human from a machine reading the future, and A conceded. The author's stated preference ("less drinking = faster runs") settles the default.

IMPLEMENTATION NOTE: Card line 5 reads "Otherwise wait — X% of the fight, longest gap Ns at m:ss". `db.simMinActivity = 0`.

### C8. Replay validation, deviation gates, Coach disable

**VERDICT: Validation before any planner work — ratified. Gates, each a setting with provenance: mana curve mean |Δ| ≤ 2% of pool and max ≤ 5% (`db.simGateManaMean = 0.02`, `db.simGateManaMax = 0.05`); per-target HP at snapshot anchors mean |Δ| ≤ 5% of maxHP and max ≤ 15% (`db.simGateHpMean = 0.05`, `db.simGateHpMax = 0.15`); no death of any tracked target; `foreignShare ≤ 0.25`; calibration drift < 3% for every spell ≥ 10% of the fight's spend (a spell with fewer than `MIN_N` calibration events is "uncalibrated", printed, not failing); ≥ 90% of the fight's mana accounted for by modelled casts. Split gate: mana failure or death or foreign or spend-coverage failure disables Coach; a single target's HP failure excludes that target from the diff and the card says so. Each mana sample records `RM.apiBase` and `RM.apiCasting`; replay uses the recorded rates. Failed fights stay listed, greyed, with the failing number.**

RATIONALE: Each party ended up conceding the other's tolerances; the judge takes the LOOSER of each pair on purpose: mana samples are quantised by the 2s server regen tick (one resting tick is 138 mana ≈ 2% of pool), so B's 1% mean would fail on quantisation alone; HP is reconstructed through pets, absorbs, range and unlogged potions, so B's 5%/15% is the honest first setting. A's extra gates (drift, spend coverage) are what catch the 12.6% utility hole. B's split gate and `apiBase/apiCasting` per sample (the in-combat drink buff at +2212.81) were the two best catches on this call and A conceded both.

IMPLEMENTATION NOTE: Deviations are computed only at recorded anchors (mana samples, HP snapshots). Print all six results on the Review tooltip every time, pass or fail. Numbers to be re-derived after the first 5 recordings; note the provenance string in each setting.

AUTHOR QUESTION: "On a fight that fails validation, do you want the row greyed with the reason (default) or hidden?" Default: greyed, curves viewable, Coach button disabled.

### C9. Recording scope and caps

**VERDICT: Two tiers. FULL STREAMS: 8 slots, gate ≥ 20s and ≥ 5 own casts, cap 4,000 events per fight; retention when full — never evict pinned (≤ 2) or the 3 most recent, otherwise evict the lowest mana spent. SUMMARIES: extend `MD.cdb.fights` from 20 to 200 rows, gate ≥ 15s and ≥ 4 own casts, each row gaining plan-free label totals, HP-at-cast buckets, utility and shift mana, foreignShare, lowest mana. `db.recordFights` default on. Storage is parallel flat arrays. The cast target comes from CLEU `SPELL_CAST_SUCCESS` `destGUID`; the first-heal matching heuristic is deleted. Raid scope is decided now: the recorder tracks a `tracked` GUID list — all party members in a group of ≤ 5; in a raid, the player's subgroup plus `GetPartyAssignment("MAINTANK")` units — and records damage, foreign heals and HP snapshots only for tracked targets. Stream header carries `v = 1`, `tracked`, `zone`, `t0`.**

RATIONALE: Both converged on two tiers and flat arrays; B's rebuttal §2.4 carried on retention (a 6-slot FIFO turns over in ~9 minutes and evicts the one 2:47 boss), A carried on the summary gate (the excluded short pulls carry 28–31% overheal, at or above average; measured: 25 of 30 pass ≥15s/≥4). A's ≥25s/≥8 stream gate is rejected: it passes 13 of 30 and would keep the median pull (24.6s, 6 casts) from ever being reviewable, defeating "the pull I just did". The "top 4 per zone" formulation is replaced by a zone-free rule because 8 slots cannot honour per-zone quotas; zone tags remain on every record.

IMPLEMENTATION NOTE: Capture list (all mandatory): damage per tracked target (post-absorb `amount`, killing blow minus `overkill`); foreign heals (effective); every own `SPELL_CAST_SUCCESS` with spellID, cost (SpendTracker), target roster index, `hpAtCast` fraction, form; own heal events (kind, gross, overheal, crit); `SPELL_CAST_START` without SUCCESS (cancelled, as busy intervals); mana samples every 2s `{t, mana, apiBase, apiCasting}`; HP snapshots every 5s `{t, hp[], maxHP[]}` plus at pull and end; `UNIT_DIED`; ABSORB misses; form changes (`UPDATE_SHAPESHIFT_FORM`); cooldown/consumable use (NS, Innervate, potion); initial auras at pull; the pre-pull own-cast ring (20s). Stream = `{ t = {}, kind = {}, tgt = {}, amt = {}, x = {} }` with kind as a small integer enum documented in the file header; snapshots in their own parallel arrays.

AUTHOR QUESTION: "In raids, record your subgroup + main tanks (default), or only your assigned targets?" Default: subgroup + main tanks.

### C10. Coaching labels and habits

**VERDICT: Final label set, in two classes. PLAN-FREE (computed at fight end from the recorder's own-cast data, stored on every summary row, summed into habits): `overheal` (heal cast with `hpAtCast ≥ db.simFullHp` = 0.85; evidence = `Overheal`'s wasted-mana attribution for that cast), `early` (Rejuvenation/Regrowth refreshed with ≥ 2 ticks pending), `utility` (non-heal, non-form casts with cost), `shift` (form changes), `prehot` (a pre-pull HoT on a target at ≥ 95% whose ticks overhealed ≥ 50% — reported on its own line, outside fight spend). PLAN-RELATIVE (only from Coach on a full stream, shown on the card): `fine`, `rank`, `spell`, `stack` (Lifebloom held at more stacks than the plan's N), `late` (cast after the dip the plan would have pre-empted), `idle` (plan casts, you did not — suppressed unless the target was below the floor ≥ reaction + cast time before), `unclassified` (printed with its mana). Identity enforced and printed: Σ mana over all in-fight labels = fight spend. Habits block = top 3 by mana over the 200-row summary tier. Every label carries HP-at-cast as evidence. `sniped` is deferred.**

RATIONALE: A's `early` split and `unclassified` + sum identity carried (B conceded both: a naive `early` flags most of 245 Lifebloom casts); B's `utility`, `shift`, `prehot` and HP-at-cast-as-evidence carried (A conceded all: 10,014 mana was invisible to the original six). The plan-free/plan-relative split is the judge's addition: habits over 200 summaries cannot depend on a plan that only exists for 8 streams, and B's first-win line needs the plan-free class alone.

IMPLEMENTATION NOTE: A cast gets exactly one label; precedence for plan-relative classification: utility > shift > fine > rank > spell > early > stack > overheal > late > unclassified; `idle` is a virtual entry (no cast) listed with the plan's cast that had no counterpart. `db.simFullHp = 0.85`, provenance "B's line; re-derive from HP-at-cast distribution after 20 fights".

### C11. Search, objective, ties, robustness

**VERDICT: Lexicographic: deaths → seconds below floor after grace (summed over tracked targets) → manaSpent → number of other retained streams the plan survives → fewer binds → lower simulated overheal. Coordinate descent is the ONLY mode, multi-start from four seeds (max-rank baseline, HoTs-only baseline, the player's actual bind set with the rules' default thresholds, one random), ≤ 300 evaluations total, early abort, coroutine sliced ≤ 8 ms per frame, progress line and a Cancel button. Headline currency is MANA; directly under it a verdict line: if `lowestMana − PullBudget.perPull ≥ 0` (n ≥ 2 in zone) the card leads with "you had X.Xk headroom — nothing here needed to change" and still shows the diff; the downtime conversion ("≈ one fewer drink per N pulls") is printed only when PullBudget has n ≥ 4 same-zone fights. One fight yields labels and "a plan for this pull", never "your plan". No N−1 held-out fitting in v0.7.**

RATIONALE: Both agreed on lexicographic (A's seconds-below-floor degrades gracefully where "latest first violation" does not). A's rebuttal carried on the headline: mana is the calibrated primitive, `PullBudget.afford` is a floor over a 5-sample median and swings across wings; B carried on the verdict line — an addon that can say "you were fine" is one that is believed when it says otherwise, and on this log that is 27 of 27 fights. B's rebuttal §2.3 carried against held-out fitting (heterogeneity swamps the signal; needs a second run and a retention policy that keeps the right five); the cross-stream "held on N of M" line answers the same question on day one. C14's binds-fixed default makes the grid ~108 points, so ≤ 300 evaluations is effectively exhaustive there.

IMPLEMENTATION NOTE: `result.floorSeconds` is the objective's second key; the "held on N of M" line states that M is "the hardest and most recent retained fights", since retention selects on spend. Card lists up to 2 alternates within 5% mana that have fewer binds, in the tooltip.

AUTHOR QUESTION: "Acceptable wall-clock for one Coach run: 3 s, 10 s or 30 s?" Default: 10 s (≈ 300 evaluations at ~15 ms sliced 8 ms/frame).

### C12. Traps in coaching on a recorded timeline

**VERDICT: Four hard rules. (1) Causality invariant written in `SimPlanner`: `Plan:Decide(state, t)` receives target HP/HoT/mana as of `t` and holds no reference to the event list; nothing scheduled by the plan may depend on an event with `t' > t`. (2) Any fight with a tracked-target death is Validate-only. (3) Killing-blow damage is reduced by `overkill`; the reconstructed HP curve is clamped at 0. (4) Initial state is snapshotted at `PLAYER_REGEN_DISABLED` (see Additional). The threat/kill-speed coupling is disclosed in the card's caveat line, not modelled.**

RATIONALE: B's causality argument is the single most important correction in the debate and A conceded it is "most of the gap, not a correction to it". A's death-truncation trap and pre-pull HoT evidence (Lifebloom + Regrowth ticking on the tank from +2135 to the pull at +2153.81) are log-proven and B conceded both. Overkill was A's catch, conceded.

IMPLEMENTATION NOTE: The planner's "anticipation without prophecy" (B) is allowed as ONE derived input: each target's damage taken over the trailing 5 s, computed from events already applied. Nothing else about the future.

### C13. Presets from recordings

**VERDICT: "Use as preset" on one fight = that fight's own recorded timeline (a joint sample) — this is the primary synthetic scenario. `SP.FromRecordings(zone, n)` summarises PER TARGET, tagged by role (never pooled by role first): baseline rate = mean damage/s outside big hits; big hit = ≥ 15% of that target's maxHP within 1 s, with rate and size p50/p90; fights < 20s excluded from the fit; provenance in the file (n fights, seconds, zone, date, ±CI). No composition of marginal quantiles ("tank at p90, others at p50"). The 2s-window 3×-mean pulse detector is rejected.**

RATIONALE: A carried on the detector (melee arrives as ~900-point swings every 2 s, so 3× mean fires everywhere) and on the marginal-quantile trap (correlated targets; B's own risk line admitted the consequence). B carried on per-target rather than per-role (one target took 61% of heal events) and A conceded. Both agree the hard-coded 450/1500/12s numbers are placeholders to be replaced by recordings.

IMPLEMENTATION NOTE: Big-hit threshold `db.simBigHit = 0.15` of maxHP. A summarised preset regenerates a timeline deterministically from (rate, big-hit rate, size p50) for EV runs and samples sizes between p50 and p90 for MC replicates.

### C14. Different binds vs tune usage

**VERDICT: Default Coach TUNES USAGE with the player's binds fixed: the rank space is restricted to the ranks the player actually cast in that recording (fallback: the ranks cast in the last 20 summaries). A checkbox "allow rebinds" (default off, remembered in `db.simAllowRebinds`) frees the Pareto-non-dominated known ranks. Rank/bind advice reaches the player only (a) through the existing new-rank/gear toast when a rank is learned, or (b) as a passive Review line when the dashboard's Pareto suggestion and ≥ 5 Coach runs with rebinds allowed independently agree on the same rank and the saving is ≥ 15% of spend — never a toast from Coach.**

RATIONALE: B's compliance evidence carried (73–100% max-rank casts against a dashboard that has recommended a downrank for versions; 0 of 4 potion alerts acted on) and A conceded that its five-gate scheme was a slower road to the same answer. Fixing binds by default also halves the search space, which is why C11 can be near-exhaustive. The raid case where a rank change is the biggest win is preserved by the checkbox.

IMPLEMENTATION NOTE: Card "Bind:" line reads exactly the player's binds by default; with rebinds allowed, changed ranks are marked "(was R12)".

AUTHOR QUESTION: "Would you rebind a healing rank mid-progression if the card proved a 15% saving?" Default: no — binds fixed, checkbox off.

### C15. GCD and reaction delay

**VERDICT: GCD is a hard scheduling constraint separate from cast time: `nextAction = max(castEnd, lastCastStart + 1.5)`. Reaction delay (`db.simReaction`, default 0.5 s) applies ONLY at a decision that follows an idle (the previous decision was "wait"); between chained casts it is zero. Cast commitment: a started cast is locked until it lands. The default is a provenance-tagged prior to be replaced by the measured post-idle gap excess over the GCD from recordings (reported in `/md profile` once ≥ 50 post-idle gaps exist).**

RATIONALE: A's measurement carried and B replicated it (p10/p25 inter-cast gap 1.50/1.52 s — the author queues at the GCD, so a blanket delay would cut throughput 17–25% and flatter every plan); B's 0.5 s carried for the post-idle case (0.3 s is latency, not human reaction) and A conceded. B's cast-commitment catch is adopted unanimously.

IMPLEMENTATION NOTE: Nature's Grace enters as `ctx.ExpectedCast` (EV). Instants occupy the GCD; a cancelled real cast in a replay occupies its recorded busy interval.

### C16. Delivery order and the first win

**VERDICT: v0.7.0 HP-at-cast field + pre-pull cast ring + plan-free labels + one new summary line (existing `UI/Summary.lua` / `Engine/SpendTracker.lua`, no new engine). v0.7.1 `RankMath:SpellKit`, `SimModel` mana half, `/md simrun` self-tests (checks 1–2), and `/md simreplay fixture` against a hand-transcribed fixture of the BF-1 hard pull (19 casts + mana samples) in `Data/SimFixture_BF1.lua`. v0.7.2 full recorder (`Engine/FightRecorder.lua`). v0.7.3 HP-half replay, gates, `/md simreplay [n]`, Validate. v0.7.4 classifier (plan-relative labels), text card, loop-closure delta line. v0.7.5 search. v0.7.6 Review tab. v0.7.7 `UI/SimWindow.lua` + Setup + `Data/SimPresets.lua` + `FromRecordings` + MC replicates. DECISIONS/TESTING/HISTORY updated at every step. Nothing after v0.7.0 is conditioned on a behavioural test of the habit line.**

RATIONALE: B's first win carried outright (one field, one line, falsifiable on the spot, attacks the ~23k of 80k mana the log already shows going into full-health targets) and A conceded it is strictly cheaper and sooner. A's rebuttal carried against B's two-week gate: an n = 1 behaviour test on a fraction that moves with content is a decision rule that kills the feature on noise, and the author has already said replay/coaching is the killer feature. The design's ordering principle (record first so material accumulates; engine validated before any planner) is ratified by all three.

IMPLEMENTATION NOTE: The BF-1 fixture is the only way to run check 3's mana half before a recording exists — the addon cannot read the text log, so the fixture is transcribed by hand and stated as such in its header.

---

## Additional decisions

### Cast commitment
**VERDICT: A cast started by the plan or the replay is locked until it lands; the plan is not re-asked until `castEnd`. HoT ticks and damage still apply during the cast.** RATIONALE: B's catch, conceded by A as the best mechanical catch in either paper; without it the sim under-reports overheal on exactly the direct heals triage depends on. IMPLEMENTATION NOTE: `state.casting = { spellID, target, landsAt }`; decisions are scheduled at `landsAt`, never earlier.

### Initial state at pull
**VERDICT: At `PLAYER_REGEN_DISABLED` the recorder snapshots, for every tracked target, the player's own HoTs via `UnitAura` (spellID, stacks, expiry → remaining), HP and maxHP; for the player: form, mana, `RM.apiBase/apiCasting`, active drink/Innervate/potion buffs and their remaining durations. The sim starts from that state.** RATIONALE: Log-proven (HoTs ticking 19 s before the pull; second pull started with a drink buff); both parties conceded. IMPLEMENTATION NOTE: `recording.initial = { auras = {...}, form, mana, apiBase, apiCasting, buffs = {...} }`.

### Form tracking
**VERDICT: Form changes are events in the stream; `RankMath:SpellKit(ctx)` is built once per form (caster, tree) per run and the replay picks the kit by the form in force at cast time; each cast's cost is the recorded live cost, never recomputed.** RATIONALE: 10 shifts in 28 minutes, twice inside twelve seconds of the hard pull; the Tree aura moves every heal; `Calibration` already needed `FORM_GRACE` for this. IMPLEMENTATION NOTE: Kits keyed `kit[form]`; a heal landing within 2 s of a shift uses the form at cast start.

### Utility mana accounting
**VERDICT: Every own cast with a cost is recorded and deducted in replay; the card shows `utility` and `shift` as their own bars, excluded from the healing denominator; `utilityMp5` as a continuous drip is deleted from the scenario. In synthetic mode, utility is a per-fight lump (`db.simUtilityPerFight`, default = the median utility mana per fight from summaries, 0 until ≥ 5 exist).** RATIONALE: 10,014 mana = 12.6% of the run, 26% of the hard pull, arriving as 445-mana lumps; "spent 6.2k" is a quarter buffs. Both parties agreed.

### HP-at-cast field
**VERDICT: On the player's own `SPELL_CAST_SUCCESS`, resolve `destGUID` to a unit via `Engine/Targets.lua` and store `UnitHealth/UnitHealthMax` as a fraction; unresolved = −1 (printed as "?"). It is recorded from v0.7.0 on every cast, in and out of combat (the pre-pull ring).** RATIONALE: The marginal recorded field with the highest evidentiary return; makes every label falsifiable at the event level; needs no simulator.

### Loop closure
**VERDICT: When a Coach card is shown, `MD.cdb.coachMarks[zone] = { t, overhealFrac, manaPerPull, topHabit }`. The Review tab prints, once ≥ 3 later same-zone summaries exist: "since your last card (N fights): overheal 39% → 31%, mana/pull −0.8k". Ships with the card (v0.7.4), not after.** RATIONALE: B's Missing #8; A conceded it is the only thing in either paper that measures whether the feature works.

### Validation gates — numbers
Settled in C8. All six printed every time; four disable Coach, one excludes a target, one (drift) fails only with `n ≥ MIN_N`.

### Retention — numbers
Settled in C9: 8 streams (≥ 20 s, ≥ 5 casts, 4,000 events), 3 most recent + ≤ 2 pinned protected, evict lowest spend; 200 summaries (≥ 15 s, ≥ 4 casts).

### Storage layout
**VERDICT: Per stream: `{ v=1, zone, t0, dur, roster = { {name, class, role, roleSource, maxHP} ... }, tracked = {idx...}, initial = {...}, ev = { t={}, kind={}, tgt={}, amt={}, x={} }, hp = { t={}, hp={{...}}, max={{...}} }, mana = { t={}, v={}, base={}, cast={} }, precasts = {...}, foreignShare, deaths = {...} }`. Numbers only in the arrays; `kind` is an integer enum. Target ~15 chars per event serialised: 8 × 1,500 × 15 ≈ 180 KB on disk.** RATIONALE: SavedVariables is Lua source parsed at every login and rewritten at every `/reload`; a table per event costs 100–120 B resident and 4,000 allocations per fight at load (both parties).

### Perf budget
**VERDICT: `SimModel:Run` ≤ 20 ms for a 1,500-event 5-target run; search slices ≤ 8 ms per `OnUpdate`; ≤ 300 evaluations; target ≤ 10 s wall; Cancel button; per-run timings logged under a new Debug category `sim` (added to the console's category list).**

### Cancelled casts
**VERDICT: `SPELL_CAST_START` without a matching `SPELL_CAST_SUCCESS` is recorded as a busy interval (start, end at the next own event or interrupt). Replay occupies the interval; the classifier does not label it; the summary counts it.** RATIONALE: A's catch, B conceded — without it the sim reads a busy healer as idle, a one-way bias.

### Baselines on every card
**VERDICT: (1) you (the replay); (2) max rank everything; (3) HoTs only, max rank; (4) best plan. Cooldowns and consumables (Innervate, NS, potions) are replayed where the player used them and never planned in v0.7; the card notes their use.**

### Provenance block
**VERDICT: Every card and Review row carries, in its `MD.Tip` tooltip: replay deviations (all six), per-spell drift for spells ≥ 10% of spend, foreignShare, "held on N of M", evaluations run and time, `unclassified` mana, and whether rebinds were allowed.** RATIONALE: A's Missing #3 — this project's convention is that a number travels with its scope.

### Comfort floor and grace
**VERDICT: `db.simFloor = 0.30`, `grace = 6 s` — ratified from the design.**

---

## The first win

The first thing the author sees is one new line under the fight summary he already reads after every pull, built from one new recorded field: *"14 of 19 casts on targets above 85% (2.9k): Lifebloom 9, Rejuvenation 4, Regrowth 1 — utility/shifts 1.6k — buffed in combat: Mark of the Wild at 0:39"*. He can check it against what he remembers doing thirty seconds ago, it names the spell and the number, and on this log it points at roughly 23k of the 80k mana he spent. It needs no simulator, no planner, no search, and it is the plan-free half of the habits list the Review tab will later sum over 200 fights — so nothing built for it is thrown away. The second win, one version later, is `/md simreplay fixture` reproducing the BF-1 hard pull's mana curve within 2%: that is the sentence "the engine can replay a fight that actually happened", which is what makes every later card worth reading.

---

## What the spec must contain

1. The `kind` enum for stream events, with the exact per-kind meaning of `tgt`, `amt`, `x`, and the tie-break order for same-`t` events in the sim heap.
2. The `tracked` rule (party ≤ 5: all; raid: subgroup + MAINTANK) and the statement that untracked targets are never recorded.
3. The full capture list from C9 with the source event for each field and what is stored when a field is unavailable (`−1`, never `0`).
4. The initial-state snapshot: exact `UnitAura` filter, which buffs count, how remaining duration is derived.
5. The mana sample record `{t, mana, apiBase, apiCasting}` at 2 s cadence, plus the recorded cost per own cast; replay uses recorded rates and costs, never live ones.
6. HP-at-cast resolution path (`destGUID` → unit via `Targets`) and the pre-pull 20 s own-cast ring.
7. Retention algorithm as pseudocode (pinned, 3 most recent, evict min spend) and the two gates (20/5 streams, 15/4 summaries).
8. The summary-row field list (new fields on `MD.cdb.fights`, `MAX_HISTORY = 200`) and the migration of existing rows.
9. `SimModel:Run(scenario, plan)` signature, `result` table fields (including `floorSeconds`, `waitFraction`, `maxWaitRun`, `overheal.byFamily`, `deaths`, `timeline`), and the zero-allocation rule with the pool API.
10. The single heal-application function with `critMode`, and where EV vs non-crit values are used (landed amounts vs rule 2's deficit test).
11. The causality invariant text to paste at the top of `SimPlanner.lua`, the cast-commitment rule, and the one allowed derived input (trailing 5 s damage).
12. GCD rule `nextAction = max(castEnd, lastCastStart + 1.5)`; reaction 0.5 s post-idle only; `db.simReaction` provenance string.
13. The plan table schema, the five rules in order, every parameter's domain, target choice within a rule, and the rank space (binds-fixed by default; Pareto set when `db.simAllowRebinds`).
14. Lexicographic score as an ordered key tuple, the four search seeds, ≤ 300 evaluations, early-abort conditions, coroutine slice 8 ms, Cancel.
15. The six validation gates with setting names, defaults, provenance strings, which disable Coach vs exclude a target, and what "uncalibrated" prints.
16. The label list with class (plan-free / plan-relative), each label's exact rule, precedence order, `db.simFullHp = 0.85`, the `idle` knowability condition, and the printed sum identity.
17. The card text template (baselines, verdict line, headroom rule `lowestMana − perPull ≥ 0`, downtime line only when `n ≥ 4`, wait line with longest gap, caveat line, `unclassified` line).
18. "Held on N of M" computation and the wording that M is hardest + most recent.
19. The provenance tooltip contents for Review rows and cards.
20. Loop-closure record shape and the ≥ 3-fight condition.
21. `/md simrun` self-test list (one cast = dashboard row; chain-cast count = To OOM column and the 13-Regrowth spam test; refresh loses ticks; bloom once; Swiftmend consumption order; death between tick and cast; 5SR lapse boundary).
22. `Data/SimFixture_BF1.lua` contents (19 casts with t/spellID/cost, mana samples, initial mana 6833, rates 69.24/28.33) and the expected deviation.
23. `RankMath:SpellKit(ctx)` field list per spell kind, built per form, and the rule that `Context({live = true})` is used for anything compared with reality.
24. New settings and their defaults: `recordFights`, `simFloor`, `simReaction`, `simMinActivity`, `simForeignShare`, `simFullHp`, `simBigHit`, `simAllowRebinds`, the six gate settings, `simUtilityPerFight` — all in `Options_General` panes via `MD.UI`.
25. New Debug category `sim` and what is logged (state transitions, per-run timing, the physical-floor assertion), not per event.
26. `.toc` load positions for `Engine/FightRecorder.lua`, `Data/SimFixture_BF1.lua`, `Engine/SimModel.lua`, `Engine/SimPlanner.lua`, `UI/Dashboard_Review.lua` (before `UI/Dashboard.lua`), and later `Data/SimPresets.lua`, `UI/SimWindow.lua`.
27. The `/md export` recording section format (TSV of the parallel arrays).
28. Version-by-version "verifiable by" line for v0.7.0 … v0.7.7 and the docs to touch at each.

---

## Rejected

- Monte Carlo inside the search, or on replay cards — variance of the one stochastic input is ~2% and P(death) never moves on a frozen timeline (v0.7 scope; synthetic only).
- A's physical lower bound as a card number — degenerates to ~0.5k on trash pulls; kept as a debug assertion.
- Foreign-heal bracket (two searches) — doubles the most expensive component for a number that is 0% today.
- DP / optimal control, learned per-target thresholds, per-phase plans — not human-castable, not fittable on 6 casts.
- B's tank/other threshold split and "shrink to 3 spells" — parameter count must fall; C14's fixed binds achieve that.
- Blending measured overheal fractions into scoring — double counts the HP cap.
- Fixed time step — no performance win, loses the 5SR and tick grid.
- Separate window at Review time — a 12-row list does not need a second frame lifecycle.
- `minActivity` default above 0 — would hide the finding the author asked for.
- All-or-nothing validation gate — one pet's HP curve would disable coaching on a good fight.
- 12-slot FIFO, 6-slot FIFO, and the ≥ 25 s / ≥ 8-cast stream gate (13 of 30 pass; the median pull would never be reviewable).
- "Top 4 per zone" retention quota — cannot be honoured in 8 slots across zones.
- Cast → first-heal target matching — `SPELL_CAST_SUCCESS` carries `destGUID`.
- N−1 held-out fitting on ≥ 5 same-zone recordings — heterogeneity swamps the signal and it delays the first card by a run.
- Weighted scalar objective — needs an exchange rate nobody can defend.
- Full-grid enumeration as a mode — 2,000 × 15 ms is 30 s of CPU.
- Downtime (drinking seconds) as the headline — a floor over a 5-sample median; it is a secondary line with `n ≥ 4`.
- Marginal-quantile preset composition ("tank p90 + others p50") — a vector of marginals is not a scenario.
- The 2 s-window 3×-mean pulse detector — fires on ordinary melee swings.
- Coach-originated rebind toasts, and any bind advice outside the new-rank toast / passive Review line.
- Blanket reaction delay (0.3 s or 0.5 s) on chained casts — the log shows the author queues at the GCD.
- `utilityMp5` as a continuous drip — utility arrives as 445-mana lumps.
- Conditioning v0.7.1+ on a two-week behavioural test of the habit line — n = 1, noise, and the author already asked for coaching.
- `sniped` label in v0.7 — needs foreign heals, which are 0% in the author's content.
- Free-form labels or a label set without `unclassified` — a classifier with no residual cannot be wrong, so cannot be checked.
- Planning Innervate/potions/Tranquility inside the rule family in v0.7 — replay only.
