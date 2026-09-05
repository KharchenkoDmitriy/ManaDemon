# Party B — the healer's position on ManaDemon v0.7

Numbers below come from `.logs/dungeon-BF-1.txt` (28 min, 30 fights, 5,600 lines) unless stated.
The facts that drive most of my positions:

| measured in BF-1 | value |
|---|---|
| total mana spent | **79,738** |
| spent on things that are not heals (ToL x10, MotW x6, Thorns x4, Abolish x6, Remove Curse x4, Bear/Cat) | **10,014 = 12.6%** |
| spent on Lifebloom | 43,296 = 54% of mana, 245 of 362 casts = **68%** |
| overheal by spell | LB 39% (107.9k of 277.0k), Rejuv **45%**, Regrowth 29%, Swiftmend 26%, Tranq 51% |
| mana into overheal (LB+Rejuv alone) | ~22.8k = **29% of all mana** |
| **times the author went OOM** | **0** |
| lowest mana all run | **2,536 / 7,009 = 36%** |
| drinks | **3** in 28 min |
| advisor alerts fired / acted on | **4 / 0** |
| max-rank cast share, per fight | **73–100%** (dashboard has been recommending a downrank for versions) |
| fights passing the design's gate (>=20s, >=5 casts) | **18 of 30, in 28 minutes** |
| median fight | **24s**, 8 casts; only 3 fights over 60s |

---

## C1. Deterministic EV vs Monte Carlo

**POSITION:** Deterministic EV — but the robustness answer MC is meant to give comes free from re-running the plan across the *other recordings*, not from sampling noise.

**ARGUMENT.** MC's only real product is "P(death)", and you cannot buy it at a sane price: §5.3 already needs 10–20 ms per run (see C11), so 200 samples x 400 plans is an hour. Meanwhile the author already owns an empirical ensemble — 18 qualifying pulls per dungeon wing — whose spikes, pull sizes and add counts are *real* and correlated the way real damage is, which is exactly the structure a Gaussian jitter knob destroys. "This plan held in 16 of your last 18 Blood Furnace pulls" is a stronger and cheaper claim than "P(death) = 0.04 under my noise model". One place EV is genuinely wrong: triage. The hard pull shows Regrowth R9 landing 2144 (crit) and 1361 (non-crit) — a 1.57x swing on the spell the `direct below=0.45` rule depends on. A triage rule sized on `heal x (1 + 0.5·crit)` will be short 25% of the time it matters most.

**CONCEDE:** triage rules must be evaluated at the **non-crit** heal (`RankMath:EventPrediction`'s `direct`, which already strips crit), with the crit upside only credited to sustained throughput.

**RISK:** the card never shows a probability, so a plan that is 5% from killing someone looks identical to one with 40% headroom until the cross-recording replay is built.

---

## C2. Fixed-order rule family vs a richer policy space

**POSITION:** Fixed order, and **shrink it further than proposed** — 3 spells, 2 thresholds, 1 roll target.

**ARGUMENT.** The log says the author's actual policy is already nearly degenerate: 68% of casts are Lifebloom, and the remaining families split 44 Rejuv / 20 Regrowth / 12 Swiftmend. A five-rule / five-bind family is not a constraint on that behaviour; it is *more* expressive than what the human does. The real risk in the design is the opposite of the one §12.2 defends against: rules 3 (`roll` LB on the tank) and 4 (`hot below=0.80`) both put a HoT on someone and will fight each other across the grid, producing parameter combinations that are behaviourally identical and inflating the plan count for nothing. Meanwhile the family is *missing* the two actions the hard pull actually used — Nature's Swiftness + Healing Touch (one instant 3,358 for 820), and shapeshifting. A family that can't express NS+HT can't reproduce the fight it is coaching.

**CONCEDE:** learned per-target thresholds are worth exactly one thing — separating "the tank" from "everyone else" — and that is better expressed as two threshold parameters (tank floor, other floor) than as a policy class.

**RISK:** the search's best plan will differ from the author's actual play mostly in one number (the Lifebloom rank), and the card will look thin.

---

## C3. Overheal endogenous (HP cap) vs blending measured fractions

**POSITION:** Endogenous only — agreed — but the **simulated-vs-measured overheal gap is a validation curve, not a footnote.**

**ARGUMENT.** §4.2 relegates the comparison to a footer that says "the scenario is gentler than your dungeons". That is backwards for a *replay*: on a replay the casts, the targets and the damage are all the real ones, so if the sim reproduces the mana curve and the HP snapshots but produces 8% overheal where `Engine/Overheal.lua` measured 39% on Lifebloom, then the sim is crediting ~30% more effective healing per cast than reality delivered, and every plan it scores is inflated by that. It is also the *most sensitive* curve available: HP snapshots every 5s can absorb a lot of error (a 5% max-HP deviation on a 9,200 tank is 460 hp — a whole Rejuv tick), whereas overheal integrates every event. Cheap: `Overheal:FamilyFraction` already exists and the recorder is already storing every heal event.

**CONCEDE:** blending the measured fraction in *anywhere* on the scoring path would double-count, and would also import the `u:<guid>` session-only / family-vs-rank scope mess that DECISIONS v0.5 §2–3 deliberately kept off the Pareto filter.

**RISK:** adds a third pass/fail gate that a first recording will probably fail, delaying the planner.

---

## C4. Other healers: environment in replay, assignment in synthetic

**POSITION:** Sufficient for the author's content **only if Coach is gated on the player having done the healing.** The "stealing" problem is real, asymmetric, and fatal in raids.

**ARGUMENT.** On a replay, another healer's heals enter as negative damage at fixed times. The optimizer then sees a target being restored for free and correctly declines to heal them — banking the other healer's mana as its own saving. In BF-1 that's harmless: one healer, 1,979 of the group's heal events are the player's. In the heroics and raids the author is heading for, it turns the card into "best plan 2.1k" against a real 6.2k, where 4k of the difference is a paladin who would have stopped casting the moment your HoT landed. The fix is one line of arithmetic the recorder already collects: sum other-source healing on roster members; if the player did **<70%** of the group's effective healing, the fight is Validate-only.

**CONCEDE:** in the synthetic mode, assignment is genuinely the right abstraction and simulating other healers' policies is a different project. No argument there.

**RISK:** the author's future raid recordings — the fights with the most to learn from — become validate-only, which will feel like the feature broke exactly when it got interesting.

---

## C5. Event-driven vs fixed time step

**POSITION:** Event-driven, agreed — and this is the **least consequential of the sixteen calls**; do not spend design capital on it.

**ARGUMENT.** A 0.25s step over a 167s boss fight is 668 steps against ~700–1000 events, so it is not even a performance win, and the accuracy it costs is bounded: at 28.33 mana/s casting regen a 0.25s quantum is 7 mana on a 7,009 pool, and a 1.68s Nature's-Grace cast quantizes to 1.75s (3% of one cast). Both are an order of magnitude below the model error calibration is already reporting (+3.7% on Regrowth's direct, DECISIONS v0.6 §15). What event-driven genuinely buys is that the 5SR boundary and the HoT tick grid land exactly, which matters because the 5SR is the single biggest lever in the model (69.24/s base vs 28.33/s casting — a **2.44x** ratio in this log).

**CONCEDE:** the sorted pending-event list is where the subtle bugs will live (refresh cancelling a scheduled tick, expiry vs bloom ordering, a death event landing between a tick and a cast) and a stepped loop has none of them.

**RISK:** ~200 lines of scheduler that must be right before anything downstream is trustworthy, with no Lua interpreter on the dev box to unit-test it.

---

## C6. Separate window vs dashboard tabs

**POSITION:** **Review ships as a 6th dashboard tab; the window waits for Setup.**

**ARGUMENT.** §12.6 justifies the window with "the setup table alone is taller than the dashboard's row area" — but Setup is delivered *last* (v0.7.5), and Review (v0.7.4) is a 12-row list plus three buttons plus a three-line habits block, which is smaller than the Waste tab that already lives in the dashboard. Building `UI/SimWindow.lua` at v0.7.4 means writing a second frame lifecycle, a second tab bar, a second position-save, and a second `MD.UI` scroll host to display a table. The Review pane is also the thing the author will open *right after a run*, which is when the dashboard is already open.

**CONCEDE:** once the per-target override table with edit boxes exists, it will not fit at 760px and the window is right; and moving a pane between frames later is cheap because `MD.DashboardParts` already established the constructor-export pattern.

**RISK:** a seventh dashboard tab (Review) becomes a permanent home and the window never gets built, leaving Setup cramped.

---

## C7. "Wait" as a first-class action; should the default constrain it?

**POSITION:** First-class, default `minActivity = 0` — but the card must report **the longest single wait**, not just `waitFraction`, because that is what separates a castable plan from clairvoyance.

**ARGUMENT.** The design frames idling as something the optimizer will "discover". The log says the author already does it: 96 five-second-rule lapses across the run, including mid-fight (`5SR end` at +2189.00, 35s into the hard pull). So "you can afford to stop casting 22% of the time" is not news. The failure mode that *is* news: an optimizer with the recorded timeline in hand will wait right up to the instant before a spike and then land a heal at t−1.5s. Twenty-two percent spread over forty 1-second gaps is a human being unhurried; 22% as one nine-second hole ending exactly when the pull's big hit arrives is a machine reading the future (see C12). Reporting `max(waitRun)` alongside `waitFraction` costs one variable and immediately exposes it.

**CONCEDE:** `minActivity` as a knob is fine and should exist, but defaulting it above 0 would hide precisely the finding — that in trash pulls the cheapest plan does almost nothing — that the author says he wants.

**RISK:** a card whose headline rule 5 is "otherwise wait" reads as the addon telling a healer to stop healing, which is the fastest way to lose trust.

---

## C8. Replay validation before planner; what deviation is "ok"; disable Coach on failure?

**POSITION:** The best call in the document. **Hard-disable Coach on a failed replay**, per-fight, with the deviation shown on the Review row.

**ARGUMENT.** This project already has the precedent and it is exactly on point: DECISIONS v0.6 §16 — calibration must never see the Simulate strip, because a comparison against reality contaminated by a what-if input produced "model 1487.7" against a real 1282. A coaching card built on a fight the engine could not reproduce is the same contamination with a friendlier face, and it is worse because the output is an instruction. Concrete tolerances, sized to the log: mana curve **mean ≤1%** and **max ≤3%** of pool (210 mana on 7,009 — one Lifebloom is 176, so 3% is "off by one cast"); per-target HP **mean ≤5%** and **max ≤15%** of maxHP; total simulated gross healing within **5%** of the logged gross (24,550+5,298 = 29,848 on the hard pull). Add the overheal curve from C3.

One thing §8 misses: BF-1's second pull began with a **drink buff still ticking** (`+2212.81 pull: regen base 239.24 casting 198.33`, +486/tick continuing to +2215.64 *in combat*). If the replay pulls regen from `RegenModel`'s current 69.24/28.33 it will be short ~170 mana/s for the first seconds of that fight and fail validation for a reason that has nothing to do with the model. **Record `RM.apiBase` and `RM.apiCasting` alongside each 2s mana sample** — two extra numbers per sample, ~90 per 3-minute fight.

**CONCEDE:** an all-or-nothing gate is brittle; a fight that fails only on one target's HP (a hunter's pet, a target out of range) still has usable coaching. Split the gate: mana failure disables everything; single-target HP failure excludes that target from the diff.

**RISK:** validation may simply never pass on real dungeon data given form shifts, absorbs and pets, and the planner never ships.

---

## C9. Recording scope and caps

**POSITION:** The gate and the caps are wrong for this content. **Retain by value, not FIFO**; raise the gate to **≥25s and ≥8 own casts**; and capture five things the design omits.

**ARGUMENT.** 18 of the 30 fights in this 28-minute run pass `≥20s, ≥5 casts`, so a 12-slot FIFO ring is **overwritten every ~20 minutes of play** — "habits over the last 12 fights" is really "habits over one wing", and 14 of those 18 are 20–45s trash pulls with 5–11 casts and no strategic content to coach. The 2:47 boss (42 casts, 8.2k, the one fight with real structure) is evicted by the next fifteen trash pulls. Keep 12 slots but fill them as: **the 8 most expensive fights per zone by mana spent, plus the 4 most recent**, with a manual pin.

**What must be captured that isn't:**
1. **Form state and every shapeshift.** 10 Tree of Life casts = 3,320 mana in this log, and the `[tree]` tag flips *within* the hard pull twice (caster at +2155.46, tree at +2156.98, caster at +2165.49, tree at +2167.48 — 664 mana in twelve seconds). The Tree aura is a healing multiplier on every event (`ctx.treeAura`); a replay that assumes one form for the fight mis-heals every event on the wrong side of a shift, and `Engine/Calibration.lua` already carries `FORM_GRACE = 2` because of exactly this.
2. **Every non-heal cast and its cost.** 10,014 mana (12.6%) across the run; **26% of the hard pull alone** (Remove Curse 135 + ToL 332 + ToL 332 + MotW 445 + Thorns 400 = 1,644 of 6,200). Without them the mana curve cannot close and "you spent 6.2k" is a lie by a quarter.
3. **Target HP fraction at the moment of each of your casts** (`UnitHealth(unit)/UnitHealthMax(unit)` at `SPELL_CAST_SUCCESS`, whose `destGUID` the brief confirms is available). This is the highest-value field in the whole design and it needs no simulator — see C16.
4. **Cooldown/consumable use:** Nature's Swiftness (the hard pull has one, turning an 820-mana Healing Touch instant), Innervate, potions. The plan family cannot reproduce a fight it cannot see.
5. **Deaths, and roster departures/pet despawns** (C12), plus **`SPELL_MISSED` ABSORB** — not for HP, but so an unexplained flat HP segment reads as "a shield was up" instead of a validation failure.

**Storage.** `{ t, target, amount }` per event is a Lua table per event: ~56 B header plus array part, call it 100–120 B in memory and ~30 chars serialized. 4,000 x 12 = 48,000 tables ≈ **5 MB resident**, and WoW rewrites the whole SavedVariables file on logout/reload. Three **parallel flat arrays** (`t[]`, `tgt[]`, `amt[]`) drop that to ~30 B/event resident and ~15 chars on disk — 1.5 MB / 700 KB. Same code shape, 3–5x cheaper, and it matters because `/reload` is the author's main debugging move.

**CONCEDE:** 4,000 events/fight is generous — the 2:47 boss produced 279 own-heal events + 42 casts, so with group damage a boss lands around 1,200–1,800. The cap is not the binding constraint; the retention policy is.

**RISK:** value-based retention means the author cannot reliably review "the pull I just did", which is the moment he will actually want to look. (Mitigated by the 4 most-recent slots.)

---

## C10. The six coaching labels

**POSITION:** They miss the three habits this log actually contains, and every label must carry **HP-at-cast** as its evidence.

**ARGUMENT.** The six labels describe deviations from a *plan*. The log's biggest inefficiencies are not deviations from a plan — they are categories the plan does not model:
- **`utility`** — 12.6% of all mana; 26% of the hard pull. Not a label at all today, and it is the single easiest thing to change (cast Mark of the Wild *before* the pull, not at +2192.56 while still combat-flagged).
- **`prehot`** — Regrowth ticking `243 (243 overheal)` six consecutive times on a full-health tank at +2144 through +2150, **before the pull at +2153**. Cast out of combat, so it is in no fight bracket and no recording, yet its mana is spent and its ticks are wasted. `overheal` as defined ("above the plan's threshold at cast time") does not reach it.
- **`shift`** — 664 mana of caster↔tree churn inside twelve seconds.

And `idle` ("the plan casts here and you did not") is the label most likely to be pure clairvoyance (C12); it should be suppressed unless the target was already below the floor **at a time the player could have known**, i.e. the drop happened ≥ reaction+cast seconds earlier.

The evidence point matters more than the taxonomy. "You overhealed" is arguable and will be argued with. "Rejuvenation R12 on Trecoda at **87%**, 296 mana, 45% of it wasted" is not. `Engine/Overheal.lua` already knows the 45%; the recording supplies the 87%.

**CONCEDE:** six fixed labels beat free-form, and the design's rule that the set grows by one when a real finding does not fit is the right governance.

**RISK:** nine labels is past the point where a healer reads the list; the habits block must still show only the top three by mana.

---

## C11. Search and objective

**POSITION:** Lexicographic (deaths → min HP → mana), yes. But **mana is the wrong headline currency for this content — convert it to seconds of downtime** — and the perf budget in §5.3 is off by 10–20x.

**ARGUMENT.** The objective as written ("minimize mana subject to nobody below the floor") optimizes a constraint that never bound: **zero OOM events in 28 minutes, minimum mana 36%, three drinks.** Told he could have spent 3.9k instead of 6.2k, the honest reaction is "and then what?" — the 2.3k bought nothing he needed. The currency that *is* scarce in a non-heroic 5-man is the thing the author himself named: time not spent drinking. `Engine/PullBudget.lua` already computes median mana per pull in this zone, so the conversion is arithmetic that exists: *"2.3k = one fewer drink per four pulls, about 12 seconds a wing"* — or, just as usefully, *"you had 2.3k of headroom; nothing here needed to change."* An addon that says "nothing to fix" once in a while is an addon that gets believed the time it says otherwise.

A weighted score is indefensible for a second reason: it needs an exchange rate between "someone spent 3s at 28%" and "400 mana", and no such rate exists that survives a wipe. Lexicographic with a **robustness tie-break** — among plans within 5% of the best mana, prefer the one that survives on the most *other* recordings (C1) — is the right shape.

**Performance.** §5.3's "~1 ms per plan" is optimistic. Per event: advance 5 targets' HP, pop from a ~15-entry pending list, apply, and re-evaluate a 5-rule x 5-target plan (25 comparisons plus table lookups) — call it 150–300 VM ops. At ~700–1,000 events and WoW's interpreted Lua at roughly 10M ops/s, that is **10–20 ms per plan**, not 1. So 2,000 plans is 20–40 s, and even coordinate descent's 200–400 plans is 2–8 s of CPU — spread at 8 ms/frame, **5–30 seconds of wall clock** with the client visibly hitching. Coordinate descent should be the *only* mode, not the fallback past 500 plans, and the progress line needs a cancel button.

**CONCEDE:** if the author's content moves to heroics and raids, mana becomes genuinely scarce and the mana objective becomes correct on its own terms. The downtime conversion should be presented alongside, not instead.

**RISK:** the downtime conversion inherits PullBudget's small sample (median over a handful of same-zone fights) and can swing wildly between wings.

---

## C12. Traps in coaching on a recorded timeline

**POSITION:** Three traps; one of them (clairvoyance) invalidates the feature if unaddressed, and the design does not mention it.

**ARGUMENT.**
1. **The planner sees the future.** It optimizes against the whole timeline, so it knows the 1,500 spike lands at t=12 and can hold a Regrowth until t=10.5. The human did not know. Every "you pre-cast and overhealed" label is then really "you lacked the information the optimizer was handed", and the advice that falls out of it — cast later, wait more, stop pre-HoTing — is advice that gets tanks killed. This is not a small correction: it is most of the gap. The author's 39% Lifebloom / 45% Rejuvenation overheal is largely the price of anticipation, and a clairvoyant optimizer charges the full price and refunds nothing. **Fix: the plan may only read events with `t' <= t_decision`.** Optionally give it the human's real advantage — a running estimate of each target's recent damage rate from the same timeline, which is anticipation without prophecy.
2. **Death decouples the timeline.** A target who died in reality stopped taking damage; if the sim keeps them alive, the recorded stream simply has no further damage for them and the sim shows them cruising. Symmetrically, a target the sim lets die keeps receiving damage from mobs that in reality retargeted. Both are wrong and neither is cheaply fixable. **Any recording containing a group death is validate-only.**
3. **Other healers' heals were a response to yours** (C4) — replacing your casts should have changed theirs, and it does not.

A fourth, minor: damage taken is not fully independent of healing — threat and kill speed both move it — but in a 5-man that is noise next to (1)–(3).

**CONCEDE:** for a boss fight with a scripted damage pattern the independence assumption is close to exact, and traps (2) and (3) are cheaply gated away by two flags the recorder already needs.

**RISK:** a strictly causal planner will find a much smaller gap (my guess: half the 2.3k in the design's example card), and the feature will look less impressive — which is the honest outcome.

---

## C13. Presets from recordings: per-role mean + 3x pulse detection

**POSITION:** Right idea, wrong statistic and wrong sample. Use **quantiles of the tank's 5-second damage windows**, not a mean, and exclude short pulls from the fit.

**ARGUMENT.** A healer does not size to the mean; he sizes so the p90 window does not kill anyone, and the difference between mean and p90 in a dungeon is exactly the pulse the design is trying to detect separately. Fitting "mean rate + pulses above 3x mean" over a corpus that is 14/18 trash pulls (C9) produces a "dungeon preset" that is mostly the shape of a 24s pull with three mobs — which is not the situation anyone needs to rehearse. And the per-**role** aggregation buries the structure: in BF-1 one target (Dëstroyka) took 1,200 of 1,979 heal events, 61%; "mean DAMAGER rate" over four very different targets is a number describing nobody. Better: per-fight, keep p50 and p90 of each target's 5s damage-taken windows plus their count, tag by role, and let the preset be "tank at p90, everyone else at p50" — the situation a healer actually prepares for.

**CONCEDE:** it is cheap, it has provenance in the file the way `Data/SpellData.lua` does, and any summarization beats the hard-coded 450/1500/12s guesses.

**RISK:** p90-shaped presets make every synthetic scenario harsher than a typical pull, and the plans that come out will be conservative and expensive — the exact opposite failure from the mean.

---

## C14. Should coaching suggest different binds, or only tune usage?

**POSITION:** **Tune usage only**, with exactly one exception. The evidence on rebinding compliance is already in.

**ARGUMENT.** This project has run the experiment. `max-rank casts` is **73–100% in every one of the 30 fights** — the dashboard has been computing and displaying a suggested downrank for several versions and the author still casts max rank, in content where he never went OOM (so he is not even wrong to). And DECISIONS v0.6 §9 records the other half: **all four potion alerts in this log were ignored**, diagnosed there as the alert answering a question the author was not asking. A rotation card whose headline is "bind Rejuvenation R9 instead of R12" is the same instruction with the same predictable compliance, and it costs an action bar slot, muscle memory and a re-learn mid-progression. Tuning usage costs nothing: "don't put a HoT on someone above 85%", "buff before the pull, not at +2192", "let the bloom land". Those are decisions made with the buttons already bound.

**CONCEDE:** one moment makes a rebind free — the instant a new rank is learned, when the bar is being edited anyway. The gear-change toast already knows how to fire at exactly that moment, so route rank advice there and nowhere else.

**RISK:** in a heroic or a raid, where mana genuinely binds, the rank change may be the biggest single win available and suppressing it leaves value on the table.

---

## C15. GCD and reaction delay

**POSITION:** GCD in the sim (it is a game rule); reaction in the plan as a parameter — **default 0.5s, not 0.3s** — and the thing that actually matters is missing: **cast commitment.**

**ARGUMENT.** 0.3s is round-trip latency, not human reaction. A healer sees a bar drop on a raid frame that updates on `UNIT_HEALTH`, recognizes it, and presses — 0.4–0.9s is the honest band, and this parameter is not cosmetic: it decides whether `direct below=0.45` on a target taking 450 dps is castable at all (450 dps x 0.5s = 225 hp of extra drop before the cast even starts, on top of the 2.0s cast). Set it too low and the search will emit thresholds a human cannot hit and will conclude they were fine.

More important, and entirely absent from §4.1's loop: **a cast in flight cannot be re-decided.** The human commits 2.0 seconds ahead; when a Regrowth started at t=10 lands at t=12 on a target another healer topped at t=11, that is not a judgment error, it is the game. The sim as specified re-asks the plan at every event and so never pays this cost — which means it will report lower overheal than the same policy achieves in reality, systematically, on exactly the direct heals the triage rule depends on. Fix: once the plan starts a cast, lock it until it lands. Perhaps ten lines, and it removes a bias that runs one way.

**CONCEDE:** for instants (Lifebloom, Rejuvenation, Swiftmend — 301 of 321 heal casts in this log) commitment is one GCD and nearly free; it only bites Regrowth and Healing Touch.

**RISK:** a 0.5s reaction plus cast locking makes the simulated healer visibly worse than the real one on spiky pulls, and validation tolerances (C8) must widen to absorb it.

---

## C16. Delivery order and the first win

**POSITION:** Recorder first, agreed. But **the first win is not the simulator** — it is one new recorded field and one report, shippable in a single file, and it attacks ~23k of the 80k mana this log already measures.

**ARGUMENT.** The design's first user-visible win arrives at **v0.7.4** — after a recorder, a `SpellKit` refactor, a simulator, a rule library, a classifier, and a coroutine search. Six components before the author sees anything he can act on, each with a failure mode that stops the chain (C8 validation being the big one). That is not a plan; it is a bet.

Here is the cheapest thing that proves the whole thesis. The recorder's marginal new field is **HP fraction of the cast target at `SPELL_CAST_SUCCESS`**. With it, and nothing else — no `SimModel`, no `SimPlanner`, no search — the fight summary gains:

```
casts on targets above 85%: 14 of 19 (2.9k)   Lifebloom 9, Rejuvenation 4, Regrowth 1
mana into full health: 1.6k    utility/shifts: 1.6k    heals: 3.0k
```

Everything in that block exists today except the HP number: `Engine/Overheal.lua` already computes wasted mana per event and measured 45% on Rejuvenation and 39% on Lifebloom; `UI/Summary.lua` already prints "into full health"; `Engine/SpendTracker.lua` already has per-cast cost and family. The HP-at-cast turns a fraction nobody acts on into a sentence with a name and a number in it.

**That is the test the whole v0.7 line should be conditioned on.** If, after two weeks of that line in his chat frame, the author's overheal has not moved — then the planner will not move it either, because a rotation card is the *same advice with more machinery*, and this project has 0-for-4 on advice at decision moments. If it does move, build the engine, validate the replay, and only then the planner.

Revised order: **(0)** HP-at-cast + habit line in the existing summary, one file. **(1)** `SimModel` mana half + `/md simreplay` against BF-1's mana curve — needs no new recording at all, the design says so itself in §3b, so it can be built in parallel with (0). **(2)** full recorder (flat arrays, forms, utility casts, cooldowns, deaths). **(3)** HP-half replay + validation gates. **(4)** classifier and the text card. **(5)** search. **(6)** Review UI. **(7)** synthetic Setup.

**CONCEDE:** the design's ordering principle — recording ships first so it gathers while the rest is built — is exactly right, and "engine validated before any planner work" is the sentence I would fight to keep.

**RISK:** starting with a habit line risks the author saying "I already knew that" and losing interest before the simulator, which is the part that answers questions he cannot answer himself.

---

## MISSING FROM THE DESIGN

**1. Utility mana and form state — 12.6% of all mana, unmodelled.** Tree of Life x10 (3,320), Mark of the Wild x6 (2,670), Thorns x4 (1,600), Abolish Poison x6 (1,056), Remove Curse x4 (540), Bear/Cat (828) = **10,014 mana**. The design's answer is `utilityMp5 = 0` — "the log's ~7%" — as a smooth continuous drip. It is neither 7% nor smooth: it is 26% of the hard pull, arriving as a 445-mana lump at +2192.56, eleven seconds after the last heal, while still combat-flagged. A replay cannot close the mana curve without these casts, and a coaching card comparing "you 6.2k" against "best plan 3.9k" is comparing a number that is a quarter buffs against one that is pure healing. Worse, the ToL shifts are a *healing* input too (`ctx.treeAura`, `ctx.inTree`, and the cost path via `SD:StaticCost`), and the log shows form flipping twice inside twelve seconds. Record every cast with its cost and the form at cast time; report utility as its own bar on the card.

**2. Causality.** Nowhere in the document does the planner's access to future events get bounded. Given the whole timeline it will hold heals until just before spikes, decline to pre-HoT, and idle through the exact window a human must fill blind — and then the classifier will label the human's anticipation `overheal` and `early`. The gap it reports is then not a gap in skill, it is the value of prophecy. One constraint (`t' <= t_decision`) fixes it; without it, the card is not advice and should not be shipped.

**3. Downtime, not mana, is the scarce resource in the content being played.** Zero OOM in 28 minutes, floor of 36% mana, three drinks. The objective as stated optimizes slack. `Engine/PullBudget.lua` already holds the conversion (median mana per pull in this zone), so the card can say "one fewer drink per four pulls" or, honestly, "you had 2.3k of headroom — nothing here needed to change." The second sentence is the one that buys the addon credibility for the day it says something else. Nothing in the design lets it ever say "you were fine".

**4. Cast commitment and anticipation.** §4.1's loop re-decides at every event, so the simulated healer never pays for a 2.0s Regrowth aimed at a target someone else topped mid-cast, and never pre-lands a HoT on a full-HP tank about to be hit. Both are what the human is doing when the log shows `243 (243 overheal)` six times running. Modelled as "cast locks until it lands", plus reaction at 0.5s, the sim's overheal moves toward the measured 39%/45% and the coaching gap becomes real instead of structural.

**5. Compliance evidence is already in hand and the design does not use it.** 0 of 4 advisor alerts acted on (DECISIONS v0.6 §9 diagnoses why); max-rank casts 73–100% despite a dashboard that has been suggesting a downrank for versions. The v0.7 card is advice at a decision moment delivered after the fact — a strictly weaker position. Every design choice should be pushed toward advice that needs no rebind and no in-combat decision (C14), and the delivery order should put a cheap compliance test first (C16).

**6. Performance and storage are both off by a multiple.** ~1 ms/plan should be **10–20 ms** (700–1,000 events x 150–300 VM ops at WoW-Lua speed), making the advertised "1,840 plans, 1.9s" more like 20–40 s of CPU and 5–30 s of wall clock at 8 ms/frame; coordinate descent must be the only mode and needs a cancel. Storage: a table per event is 100–120 B resident, so 12 x 4,000 is ~5 MB and a full SavedVariables rewrite on every `/reload`; three parallel flat number arrays cut that to ~1.5 MB resident / ~700 KB on disk for identical semantics.

**7. Retention policy, not just caps.** 18 of 30 fights in one wing pass the gate, so the FIFO ring turns over every ~20 minutes and the only fight worth coaching (the 2:47, 42-cast boss) is evicted by trash. Retain by mana spent per zone, plus the last few, plus a pin.

**8. There is no loop closure.** The design ends at the card. Nothing measures whether the author changed anything, or whether it worked. The cheapest version: after a Coach card is shown, tag the next N fights in the same zone and show the delta on the Review pane — "since your last card: overheal 39% → 31%, mana/pull −0.8k". That single line is what turns a report into a coach, and it is the only part of this design that would tell you the feature is working.

---

## MY TOP 3 DECISIONS THAT MATTER MOST

**1. Make the planner causal (C12).** It may only see events at or before the decision time. Without this, "best plan 3.9k" is the score of a healer who knew the future, and every `overheal` / `early` / `idle` label is charging the author for information he did not have. This is one constraint in the scheduler and it is the difference between a coach and a hindsight machine. It will also shrink the reported gap — which is the correct answer, and the design should want it.

**2. Ship the habit line before the simulator (C16, C9-3).** One new recorded field — target HP fraction at `SPELL_CAST_SUCCESS` — plus one summary line: *"14 of 19 casts on targets above 85%, 2.9k."* It needs no `SimModel`, no planner, no search; it uses `Overheal`'s existing per-event waste attribution; and it goes straight at the ~23k of 80k mana (29%) this log already shows going into full-health targets. It is also the compliance test the whole v0.7 line should be conditioned on: if that line does not change behaviour in two weeks, a rotation card will not either, and you will have learned it for one file instead of six.

**3. Report in downtime, and gate Coach hard (C11, C8, C4, C12-2).** Denominate the saving in seconds of drinking via `PullBudget`, and let the card say "nothing here needed to change" when — as in all 28 minutes of this log — mana never got close. Then refuse to show a card at all when the replay failed validation, when a group member died, or when the player did under 70% of the group's healing. Three cheap flags. They are what keep this from becoming the fifth alert the author ignores.
