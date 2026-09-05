# Party B — rebuttal to Party A

All numbers re-measured from `/home/penek/projects/addons/ManaDemon/.logs/dungeon-BF-1.txt` unless marked *est*.
Standing correction that applies to both papers: **that log contains zero damage and zero HP events**
(`grep -c damage` = 0; tags present are mana 1425 / heal 1271 / tto 401 / regen 157 / spend 150 / combat 49 /
cast 21 / other 14 / chat 8). Every damage-side number either of us quotes is an estimate over infrastructure
that does not exist yet. That asymmetry decides two of the disagreements below.

---

## 1. WHERE A IS RIGHT AND I CONCEDE

- **C15, GCD vs latency.** A's measurement replicates exactly: inter-cast gaps p10 **1.50s**, p25 **1.52s** (n=358); only 16 gaps under 1.45s. The author queues at the GCD, so my "default 0.5s reaction on every action" was wrong — reaction applies only after an idle, and `nextAction = max(castEnd, lastCastStart + 1.5)` is the right rule.
- **C15, measured not guessed.** Deriving the post-idle reaction from the recordings with provenance beats both 0.3s and my 0.5s.
- **C10, `early` is broken for Lifebloom.** LB→LB gap median **4.73s** (p25 2.15, p75 6.62, n=235); a naive `early` rule flags most of 245 casts, i.e. 68% of all casts, as waste. Split into `early(Rejuvenation)` / `stack` as A says.
- **C10, `unclassified` bucket + the sum identity** (`Σ labels + utility + shifts = fight spend`). This is a falsification test I did not propose and it is strictly better governance than my "add a label when a finding does not fit".
- **C12/Missing-1, initial aura state.** I framed pre-pull HoTs as a coaching label (`prehot`); A is right that it is first a *replay correctness* requirement — snapshot spellID/stacks/remaining at `PLAYER_REGEN_DISABLED` or the mana curve diverges in second one. Both uses, A's first.
- **C12, overkill on the killing blow.** Real, cheap, and I missed it: without subtracting `overkill` the reconstructed HP curve ends below zero and pollutes the deviation metric.
- **C5/Missing-4, allocation.** ~1,500 events × 300 candidates of per-event tables is tens of MB of garbage and visible GC hitches. "Zero allocation in `Run`, pooled event heap, parallel arrays" is a design constraint, not an optimisation, and I only argued the storage half of it.
- **C5, event count.** A is closer than I was: the 2:47 boss shows **296 own heal events + 46 casts** in 167s (2.0/s) before any damage stream; 1,000–1,500 events is the right planning figure, not my 700–1,000. Per-plan cost 10–20 ms stands either way — the design's ~1 ms is wrong by 10×.
- **C5, early abort** on exceeding the incumbent's mana or an unrecoverable floor breach. Free ~2× and I did not mention it.
- **C9, the gate is biased and too tight.** At ≥20s/≥5 casts, 18 of 27 recorded fights qualify holding **51.1k of 60.3k** combat mana; at ≥15s/≥4 it is **25 of 27 and 59.1k (98%)**. A's looser gate for the summary tier is right.
- **C9, summary tier is nearly free.** `UI/Summary.lua` already keeps `MAX_HISTORY = 20` records of ~12 fields; 200 of them is *est* ~100 KB. Concede the tier (see §2 for the stream half).
- **C9, `SPELL_CAST_START` with no `SUCCESS`.** Without cancelled casts the sim reads a busy healer as idle — a bias that runs one way, and I missed it.
- **C9/Missing-8, raid scale must be decided before the format is persisted.** Retrofitting an assignment-scoped filter after SavedVariables carries the old shape is the expensive order.
- **C11, overfitting is the biggest credibility threat.** ~5 free parameters against a median of ~8–11 own casts is fitting noise; I under-weighted this and A's "one fight produces labels and a diff, never a *plan*" is the correct structural fix.
- **C13, "3× mean in a 2s window" fires everywhere** because melee is ~900-point swings every 2s. Defining a big hit as ≥15% of that target's own maxHP within 1s is better than my quantile framing and composes with it.
- **C14, gates beat prohibition.** ≥15% of spend saved, stable across ≥5 fights, at most one bind change per report — that is a superset of my "only at rank-learn" and it does not forfeit the raid case.
- **C8, published numeric gates.** A's are tighter than mine on mana (2%/5% of pool vs my 1%/3% — mine were, on reflection, tighter than a live-API cost accounting deserves given form shifts) and A's extra gate "≥90% of the fight's mana accounted for by modelled casts" directly catches the 12.6% utility hole I spent a page on. Take A's set.
- **C3, staleness must be an invariant written in the file, not an assumption.** `Plan:Decide(state, t)` holding no reference to the event list is the enforceable version of my causality demand.

---

## 2. WHERE A IS WRONG

### 2.1 The physical lower bound is not a number for the card
> "the card reads `you 6.2k | best rule plan 3.9k | physical floor 2.6k` … 3.9→2.6 is *what the five-button constraint costs you*."

The bound A specifies, `Σ max(0, D_i − (hp0_i − floor_i·maxHP_i)) / maxHPM`, spends the whole fight's headroom once. On the hard pull (0:40, 19 casts, healed 24,550 gross / 5,298 overheal → 19.3k effective) five targets at a 40% floor offer roughly 0.6 × (9.2k tank + 4 × ~5.5k) ≈ **18.7k of headroom** *est* against ~21k of damage — so the "floor" is ~2.6k HP of must-heal, ≈ **0.5k mana** at 5.5 HP/mana, not 2.6k. On every 20–45s trash pull (14 of the 18 qualifying fights) the bound degenerates to "you could have let everyone finish at 40% and healed almost nothing", which is arithmetically true and behaviourally insane. The gap 3.9→2.6 is also not one thing: it mixes foresight, HoT granularity, GCD feasibility and a `maxHPM` rank the author does not have bound. Keep the bound — as a **debug assertion** ("any plan scoring below it is a bug", which is its genuinely valuable half) and never as a third number a healer reads.

### 2.2 Monte Carlo replicates buy ~nothing on a replay
> "Three plans × 30 replicates × ~8 ms = 0.7 s … converts 'lowest 31%' into 'P(floor violation) 18%, P(death) 2%'."

On a *replay* the damage timeline is a fixed recorded array, so the only stochastic input left is crit — and A's own C1 arithmetic prices crit variance at ~2% of total healing (σ ≈ 530 HP on 25k). Thirty replicates of that will report P(death) = 0 on 27 of 27 fights in this log, because nobody died and the mana floor was 36%. The cost is not the objection; the objection is that a probability computed over the one input we can defend, on a fight whose hard input is frozen, is a number that never moves and therefore never informs. MC earns its keep only in **synthetic** mode, where C13's distribution is the whole point of the scenario and P(floor violation) is the question being asked. Ship it there, at v0.7.5 with Setup, not as a v0.7.4 addition to replay cards.

### 2.3 Held-out fitting on ≥5 same-zone recordings is the wrong instrument here
> "a **plan** requires ≥5 recordings in the same zone, is fitted on N−1 and scored on the held-out one."

The heterogeneity swamps the variance you are trying to measure: the five same-zone fights are a 3-mob pull, a 5-mob pull, a patrol add and a 2:47 boss (5 to 42 casts, 0.6k to 8.2k spend). A plan fitted on four of those and scored on the fifth mostly measures *scenario mismatch*, and a bad held-out number will be read as "the search overfitted" when it means "trash pulls are not boss fights". Worse, it collides with A's own C9: six full streams cannot reliably hold five same-zone qualifying recordings alongside any recency, so the first plan card waits for a second dungeon run *and* a retention policy that keeps the right five. The cheap instrument that answers the same question is the one I proposed in C1 and A independently reached for in C11's tie-break: **run the winning plan across every other retained recording and print how many it survives** — no train/test bookkeeping, no minimum corpus, and it degrades to "1 of 1 fight" honestly on day one. Keep A's rule that one fight yields *labels only, never "your plan"* — that is the part that matters.

### 2.4 Six full streams under FIFO makes the eviction problem worse, not better
> "full event streams for the last **6**, compact per-fight summaries for the last **200**."

At 18 qualifying fights per 28-minute wing, a 6-slot FIFO turns over in roughly **9 minutes of play** — the 2:47 boss (42 casts, 8.2k, the only fight with structure) is gone before the author leaves the instance, which is precisely the failure I raised against 12 and A's tier halves the time to it. Value retention costs one comparison: the **top 4 by mana spent per zone, plus the 2 most recent, plus a pin** holds the fights that matter — the top 6 fights in this run carry 28.8k of 60.3k combat mana (48%), the top 8 carry 56%. I concede the 200-summary tier outright (it is a 10× stretch of an existing 20-slot ring, *est* ~100 KB) and I concede 6 streams is enough *slots*; the disagreement is entirely about how they are filled.

### 2.5 A's "first win" is built on the one thing nobody has measured yet
> "First win: … 'this pull took 21.3k damage across 5 targets; the minimum mana that could have covered it is 2.6k'."

The 21.3k is *est* — the log contains no damage events at all, and neither does the addon today. A's v0.7.1 card therefore requires: a damage-taken recorder, per-target `maxHP` snapshots (buff-dependent), absorb handling, overkill correction, and the bound of §2.1 — five new things, any one of which can be wrong without being visibly wrong. Mine requires **one field**: `UnitHealth/UnitHealthMax` of `destGUID` at the player's own `SPELL_CAST_SUCCESS`, which the brief confirms is available, feeding a line whose other halves (`Overheal`'s per-event waste, `SpendTracker`'s per-cast cost and family, `Summary`'s "into full health") already ship. "14 of 19 casts on targets above 85%, 2.9k" is falsifiable by the author on the spot; "the physical floor was 2.6k" is not falsifiable by anyone. Do mine at v0.7.0 and A's at v0.7.1 — but not in the other order, and do not call A's the first win.

### 2.6 The foreign-heal *bracket* doubles the most expensive component to describe a number that is currently zero
> "report an interval: free-riding lower bound and self-sufficient upper bound … it is two runs of the same search on two timelines."

Two runs of a search we both price at 10–40 s of CPU is 20–80 s, for a fight where `foreignShare` is **0%** — in BF-1 all healing on the four party members was the player's. In the raid case where the bracket would matter, A's own Missing-8 says the recorder is out of budget at 40–80 events/s before the search is even reached, so the bracket is spent on content the pipeline cannot record yet. Take A's threshold ladder and drop the middle rung: `foreignShare ≤ 25%` → Coach on; above → Validate-only with the reason printed. One number, one gate, no doubled search.

### 2.7 The separate window is argued from provenance, and provenance does not need a window
> "It needs the same treatment: replay deviation, calibration drift … A separate window makes room for that; a tab would not."

Everything A lists is a hover surface, and this project already has the one place hover surfaces are built: `UI/Tooltip.lua` (`MD.Tip:Row`, `:Columns`, `:Fights`), which the dashboard rows already use to carry scope and borrowed-data marks. A Review row with a deviation column and a tooltip carrying drift, foreign share and death flags fits the existing Waste tab's footprint. The window becomes right when the per-target override *table with edit boxes* exists — that is v0.7.5 — and `MD.DashboardParts` already makes the move cheap. Building `UI/SimWindow.lua` at v0.7.4 buys a second frame lifecycle, tab bar and position-save to display a 12-row list.

### 2.8 One small one: `utility` must not merely be excluded from the denominator
> "`utility` (12 casts, ~7% of spend, must be excluded from the denominator or it becomes phantom waste)."

It is 10,014 mana = **12.6%** of the run and **26% of the hard pull** (Remove Curse 135 + ToL 332 + ToL 332 + MotW 445 + Thorns 400 = 1,644 of 6,200), and the 445-mana Mark of the Wild landed at +2192.56, *in combat, 11 seconds after the last heal*. Excluding it makes the classifier's percentages honest and the coaching blind to the single most changeable habit in the log ("buff before the pull"). Exclude from the healing denominator, report as its own bar, and give it a label.

---

## 3. SYNTHESIS I CAN LIVE WITH

- **C1.** Deterministic EV everywhere in replay+search; Monte Carlo (K≈30, three reported plans) only in synthetic Setup where C13 supplies a distribution; robustness in replay = re-run the winner on the other retained recordings.
- **C2.** Fixed-order family, shrunk toward 3 spells / 2 thresholds (tank floor, other floor) / 1 roll target, plus NS+HT and form shifts as expressible actions; A's physical bound kept as an internal assertion, not a card number.
- **C3.** Endogenous overheal only, enforced by the stated invariant (`Plan:Decide` sees state at `t − reaction`, never the event list), with sim-vs-`Overheal:FamilyFraction` printed as a named residual and treated as a validation curve.
- **C4.** Foreign heals as environment; single gate `foreignShare ≤ 25%` → Coach, else Validate-only with reason; no bracket, no foreign-healer policy simulation, ever.
- **C5.** Event-driven, budgeted at 1,000–1,500 events and 10–20 ms/plan, allocation-free inner loop with a pooled heap and early abort.
- **C6.** Review ships as a dashboard tab at v0.7.4 with provenance in an `MD.Tip` tooltip; `UI/SimWindow.lua` arrives with Setup at v0.7.5 and Review moves into it via `MD.DashboardParts`.
- **C7.** Wait first-class, `minActivity` default 0 and prominent, card reports `waitFraction` **and** `max(waitRun)` so a nine-second clairvoyant hole is visible.
- **C8.** A's gate set verbatim (mana mean ≤2% / max ≤5% of pool; HP mean ≤3% / max ≤10% of maxHP; no death; foreignShare ≤25%; drift <3% on spells ≥10% of spend; ≥90% of spend modelled), as settings with provenance; mana failure disables all, single-target HP failure excludes that target; plus record `RM.apiBase`/`apiCasting` per mana sample so a lingering drink buff is not read as a model failure.
- **C9.** Two tiers: 6 full streams filled by **value** (top 4 by mana per zone + 2 most recent + pin), 200 summaries at ≥15s/≥4 casts; flat parallel arrays; capture form transitions, every non-heal cast with cost, initial auras/stacks/durations, HP-fraction at own casts, NS/Innervate/potions, deaths, absorb misses, cancelled casts, per-snapshot maxHP and a `GetSpellBonusHealing()` sample.
- **C10.** A's corrected six (`early` split into `early(Rejuv)` / `stack`, plus `late`, `form`, `utility`, `sniped`) with `unclassified` printed and the sum identity enforced; every label carries HP-at-cast as evidence; habits block shows only the top three by mana; `idle` suppressed unless the drop was knowable ≥ reaction+cast earlier.
- **C11.** Lexicographic deaths → seconds-below-floor → mana → survives-most-other-recordings → fewer binds; multi-start coordinate descent as the only mode, ≤300 evaluations, cancel button; headline saving converted to drinking seconds via `PullBudget`, and the card must be able to say "you had 2.3k of headroom, nothing here needed to change".
- **C12.** Causality invariant; death anywhere in the group → Validate-only; overkill-corrected damage; foreign-heal gate from C4; threat/kill-speed coupling disclosed in the caveat line.
- **C13.** Per role: mean rate with a CI + p50/p90 of 2s windows + big-hit process defined as ≥15% of that target's maxHP in 1s, with `Data/SpellData.lua`-style provenance (n fights, seconds, zone, date); short pulls excluded from the fit.
- **C14.** Tune usage freely; at most one bind change per report, gated on ≥15% of spend saved, stable across ≥5 fights, agreeing with the dashboard's Pareto rank, and delivered through the existing rank/gear toast — the log's 20 of 27 fights at 100% max rank says the message must be rare to be read.
- **C15.** GCD as `max(castEnd, lastCastStart + 1.5)`; reaction charged only after an idle, default measured from the recordings; cast commitment (a started cast cannot be re-decided) modelled explicitly.
- **C16.** (0) HP-at-cast + habit line in the existing summary, one file; (1) `SimModel` mana half + `/md simreplay` against BF-1's mana curve, in parallel; (2) full recorder; (3) HP replay + A's validation gates; (3b) damage-taken "where the mana went" breakdown with the bound as an internal check; (4) classifier + card; (5) search; (6) Review; (7) synthetic Setup + Monte Carlo.

---

## 4. QUESTIONS ONLY THE AUTHOR CAN ANSWER

1. If the honest answer on 27 of 27 fights in a wing is "you had headroom, nothing needed to change", is that a feature you would keep running, or does the card need to find something?
2. When the planner's advice is causal (it may only see what you saw), the reported gap will shrink — my guess, to about half the design's 2.3k example. Is a smaller, defensible number still worth six components?
3. Which do you want first: the fight you *just* did, always reviewable (recency retention), or the boss pull from an hour ago still being there (value retention)?
4. Are heroics/raids close enough that raid-scale recording must be designed now, or can the v0.7 format be explicitly 5-man-only with a documented cutover?
5. Would you actually rebind a rank on a rotation card's say-so — given 20 of 27 fights in this log were 100% max rank while the dashboard was recommending a downrank the whole time?
