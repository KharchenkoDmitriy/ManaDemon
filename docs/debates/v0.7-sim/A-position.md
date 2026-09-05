# Party A — Theorycrafter / Model Purist

Numbers below are measured from `.logs/dungeon-BF-1.txt` (30 pulls, ~28 min, level-64 Dreamstate
resto druid, Blood Furnace) unless marked *est*. Standing measurements used throughout:
casting regen **28.33/s**, resting regen **69.24/s** (ratio 2.44), pool 7009, 362 casts of which
**245 Lifebloom / 44 Rejuvenation / 20 Regrowth / 12 Swiftmend / 10 Tree of Life shifts /
12 utility**, 1979 heal events, 71 of them non-tick, 20 of those crits (28%).

---

## C1. Deterministic EV vs Monte Carlo

**POSITION.** EV for the *objective* (mana), Monte Carlo for the *constraint* (survival):
deterministic search, then K≈30 replicates of the 3 reported plans only.

**ARGUMENT.** The objective is a sum over ~40 casts, so the law of large numbers does the work:
crit-capable healing is ~30% of output by amount in this log (71 direct/bloom events against 1908
ticks), and over a 40s pull with 3 direct casts at p≈0.36 the σ of total healing from crit is
~530 HP on ~25k healed — 2%. EV is fine there. The *constraint* is a min over time of a single
target's HP, and a min is not linear: rule 2 of the design's own plan ("anyone under 45%:
Regrowth R7") is a bet whose payoff is 1282 or 2144 (log values for R9), a 67% swing, decided
once. `ok = true` printed from one EV run is a claim about the mean trajectory presented as a
claim about every trajectory, which is exactly the class of statement this project deleted from
the clock in v0.6 §2. Three plans × 30 replicates × ~8 ms *est* = 0.7 s, affordable after the
search, and it converts "lowest 31%" into "P(floor violation) 18%, P(death) 2%".

**CONCEDE.** No MC inside the search — 2000 × 30 evaluations is off the table, and EV ranking of
plans by mana is very unlikely to be reordered by crit noise.

**RISK.** Two numbers on the card (EV lowest-HP and MC violation probability) that can disagree,
and the author has to be told why.

---

## C2. Rule family vs richer policy space

**POSITION.** Keep the fixed-order rule family as the *output*, but stop calling its winner
"best". Add a policy-free physical lower bound so the card brackets the truth.

**ARGUMENT.** The family is right for the human constraint and the argument in §12.2 is sound.
The dishonesty is in the presentation: "best plan 3.9k" is the minimum over ~2,000 points of one
parameterisation, not over strategies, and there is no way to tell a good family from a bad
search. Both are fixed by a bound that costs one O(events) pass: for each assigned target,
`H_i = max(0, D_i − (hp0_i − floor_i·maxHP_i))` where `D_i` is total logged damage taken — the
effective healing that target *must* receive; then `manaFloor = Σ H_i / maxHPM` over the
zero-overheal, best-HPM known rank, with a feasibility check that `Σ casts × 1.5s ≤ duration`.
That is unattainable by construction (perfect timing, zero overheal, no reaction), so the card
reads `you 6.2k | best rule plan 3.9k | physical floor 2.6k` and the two gaps mean different
things: 6.2→3.9 is *your habits*, 3.9→2.6 is *what the five-button constraint costs you*. It
also falsifies the search: any plan scoring below the floor is a bug.

**CONCEDE.** No DP, no learned per-target thresholds. The family should gain a rule only when a
hand-written plan beats the search, as §12.2 says.

**RISK.** A third number on the card invites "why can't I have 2.6k?", which needs one line of
explanation every time.

---

## C3. Overheal endogenous vs blended measured fractions

**POSITION.** Endogenous only — but the cap alone will not reproduce reality, and the missing
mechanism is *information*, not a fudge factor: the plan must decide on HP as of `t − reaction`
and must never see the scenario's future events.

**ARGUMENT.** The design's own mock admits the gap: 12% simulated against 45% measured
Rejuvenation overheal. Blending the measured fraction in would double-count (§12.3 is right), but
leaving the gap unexplained makes every coaching card compare a human under uncertainty to an
oracle, and "you wasted 2.3k" is then partly a statement about clairvoyance. Most of the real
overheal is mechanistic and simulable: you commit a 2.0s Regrowth on a target at 60% and another
healer's heal or a HoT tick lands first. An event-driven sim over a *known* timeline makes
look-ahead trivially easy to write by accident (scheduling a heal to land just before a pulse) —
so the invariant has to be stated in the file, not assumed: `Plan:Decide(state, t)` receives
target HP/HoT/mana as of `t − reaction` and no reference to the event list. Then report the
decomposition — cap overheal, HoT-tick-on-full overheal, foreign-heal collision — against
`Overheal:FamilyFraction` as the residual.

**CONCEDE.** The residual will still be large (the log's Lifebloom ticks overheal 38% while
rolled on a full tank between pulls); it should be printed as a named unexplained fraction, not
absorbed.

**RISK.** Staling information by 0.3s makes the sim's overheal a function of a knob the author
can turn until the numbers flatter him.

---

## C4. Other healers as environment / assignment

**POSITION.** Insufficient as a point estimate. Foreign heals are a *control loop*, not
environment, so report an interval: free-riding lower bound (their heals kept) and self-sufficient
upper bound (their heals on assigned targets removed), and gate Coach on the share.

**ARGUMENT.** Treating foreign heals as fixed negative damage lets the optimizer bank savings that
only existed because someone else covered — and in reality that healer would have healed *less*
had the player's heal landed, or *more* had it not. In this log the effect is nil (a 5-man, one
healer: 100% of healing received on the four party members came from the player), which is exactly
why it will ambush the author later: the same code path in a 25-man will silently produce a card
saying "you could have spent 40% less". The recorder already has the data to police it —
`foreignShare = Σ foreign effective heal on assigned targets / Σ all effective heal on them` —
so: < 10% run normally, 10–25% print the bracket, > 25% Coach is disabled with the reason. The
bracket is cheap: it is two runs of the same search on two timelines.

**CONCEDE.** Simulating other healers' policies is out of scope and always will be; assignment is
the right abstraction for synthetic scenarios.

**RISK.** In raids the bracket may be wide enough (say 2.4k–5.1k) to be useless, which will read
as the feature not working rather than as an honest measurement.

---

## C5. Event-driven vs fixed step

**POSITION.** Event-driven, agreed — but the design's cost model is wrong by an order of
magnitude and the architecture has to be built for it.

**ARGUMENT.** Count the events properly for a 3-minute 5-man: Lifebloom ticks at 1s on 1–3
targets (~300), Rejuvenation ticks at 3s on up to 5 (~200), Regrowth ticks (~100), recorded damage
(*est* 400–600 for the 167s pull, given the player alone produced 279 heal events in it), plus
casts, expiries and 5SR lapses — **1,200–1,800 events**, not 700. Each event advances time for
every target (5 × integrate + clamp + floor test), dispatches, and at cast boundaries runs the
rule list (5 rules × 5 targets with HoT lookups). That is ~80–150 VM operations per event plus
~120 decisions × ~200, i.e. **150k–300k operations**, which in WoW Lua 5.1 is **3–15 ms**, not
"about a millisecond". 2,000 plans is therefore 6–30 s of compute, and at the design's own 8 ms
per frame that is 12–60 s of wall clock, not 1.9 s. Consequences that must be designed in now:
(a) full grid is dead, coordinate descent with ≤ 300 evaluations is the budget; (b) **zero table
allocation in the loop** — a per-event table is ~80 bytes, 1,500/sim × 300 sims = 36 MB of
garbage and repeated full GC pauses; use interleaved flat arrays and a pooled event heap;
(c) early abort — kill a candidate the instant `manaSpent` exceeds the incumbent or the floor is
violated past recovery, which typically halves the work.

**CONCEDE.** For the *analytic* damage shape a fixed 0.5s step would be simpler and the
quantisation error is bounded by 0.5 × dps; not worth two code paths.

**RISK.** Getting allocation-free right is fiddly and the first version will be slower than these
numbers until it is profiled in-game.

---

## C6. Separate window vs dashboard tab

**POSITION.** Separate window, agreed — with the condition that the Result pane carries provenance
inline, not in a footnote.

**ARGUMENT.** No theorycraft stake in the frame, but there is one in what the frame prints. This
project's whole convention is that a number travels with its scope: `roleSource` travels with
every role, the overheal tooltip labels family vs rank scope and shows a grey `?` for borrowed
data, the confidence gate refuses digits above `sigma/net = 0.7`. The Result mock as drawn prints
"mana 4.1k" and "lowest 31%" with the same authority as a dashboard row, with the calibration
state relegated to one grey line. It needs the same treatment: replay deviation, calibration
drift for the spells actually used, foreign-heal share, number of fights the plan was fitted on,
and whether a target died. A separate window makes room for that; a tab would not.

**CONCEDE.** Review/Setup/Result as three panes is right; the Review pane is the correct default.

**RISK.** A result card so hedged that the author stops reading the hedges.

---

## C7. "Wait" as a first-class action

**POSITION.** First-class, `minActivity` defaults to 0, and the default must *not* constrain it —
but `waitFraction` must be reported with the risk it buys.

**ARGUMENT.** The measurement is decisive: resting 69.24/s against casting 28.33/s is 2.44×, so
five seconds outside the FSR is worth 346 mana against 142 — a **+204 mana** delta, more than one
Lifebloom (176). And the author is already leaving it on the table: "spirit regen realized" is
30–45% in 25 of 30 pulls, best 67%. Idle time is not scarce either — the median gap between
consecutive casts across the run is 2.5s and p75 is 5.15s, so the 5s window is routinely almost
achieved and then broken by one cheap cast. Constraining it by default would suppress the single
largest finding the tool can make in 5-man content. The honest caveat is that waiting is a bet
against a spike, which is exactly what the C1 replicates price.

**CONCEDE.** `minActivity` must exist and should be prominent, because a plan that idles 40% is
psychologically unusable for many players regardless of arithmetic.

**RISK.** A card that says "stop casting 22% of the time" on a fight where a spike arrived in the
gap, and the author remembers the spike.

---

## C8. Replay validation first; what deviation is acceptable

**POSITION.** Yes, first — and with published numeric gates, plus Coach hard-disabled on a fight
that fails any of them.

**ARGUMENT.** §8 is the best decision in the document and it is under-specified: "mana ok, HP ok"
needs thresholds or it will be graded by eye. Proposed, and derivable from what the log already
shows: **mana** — mean |Δ| ≤ 2% of pool (140 on 7009) and max ≤ 5% (350), because the mana curve
is a pure accounting identity (costs are live from the API, regen is `GetManaRegen`, the 5SR
transitions are already logged) and anything worse is a real defect, not noise. **HP** — mean |Δ|
≤ 3% of maxHP per target, max ≤ 10%, over the snapshot anchors; HP is reconstructed from logged
damage plus modelled heals, so the residual isolates the heal model, and the tolerance has to be
that loose only because unlogged HP change (potions, bandages, out-of-combat regen) exists.
Gates for Coach: replay passes; no assigned target died; `foreignShare` ≤ 25%; calibration drift
< 3% for every spell that made up ≥ 10% of the fight's spend; ≥ 90% of the fight's mana accounted
for by modelled casts. Fail any one and the fight shows its curves and its reason, and the Coach
button is greyed. A coaching card on a fight the engine could not reproduce is worse than no
feature, because it is confidently wrong in a domain where the author cannot check it.

**CONCEDE.** The HP tolerance is a guess until the first recording; it should be a documented
setting with provenance, in the `db.oomConfidence` tradition, not a constant in the code.

**RISK.** Early on most fights fail a gate and the feature looks broken before it looks useful.

---

## C9. Recording scope and caps

**POSITION.** Wrong on both ends. The gate (≥20s, ≥5 casts) throws away the fights where the
waste is; the ring (12) is smaller than one dungeon run. Split storage: full event streams for the
last **6**, compact per-fight summaries for the last **200**.

**ARGUMENT.** Counted on this log: 30 pulls, of which **18 qualify** under ≥20s and ≥5 casts. One
Blood Furnace run overflows a 12-ring by 50% — "habits over the last 12 fights" is two-thirds of
a single instance, ~9.5 min of combat and ~150 casts, on which the design then tunes ~5 plan
parameters. Worse, the gate is *biased*: the excluded short pulls (17–19s, 5–6 casts) carry
overheal of 28%, 30%, 31%, at or above the run's average, so the habits are computed on
systematically cleaner fights than the ones being played. Drop to ≥15s and ≥4 casts (25 of 30
qualify) for the summary tier. Size: SavedVariables is serialised Lua *source*, so a per-event
table `{t=,target=,amount=}` costs 60–120 bytes of text, not 40 — 12 × 1,500 × 100 = 1.8 MB, a
file that is parsed at every login and rewritten at every logout. Interleaved flat arrays
(`{12.34,3,456, 12.51,1,88, ...}`) cut that ~3× and remove 4,000 table allocations per fight at
load; a packed string per fight would cut it 8×. **Not captured, and each of these breaks the
replay:** HoTs already rolling at t=0 (log-proven — Lifebloom and Regrowth were ticking on the
tank for 20s before the pull at +2153.81); form state and shifts (10 Tree of Life casts, 332 mana
each = 3.3k mana, and the Tree aura moves every heal by 25% of Spirit); a `GetSpellBonusHealing()`
sample alongside each mana sample (trinket procs otherwise land in the residual);
`UNIT_DIED`; per-snapshot `maxHP` (buffs change it); cancelled/interrupted casts
(`SPELL_CAST_START` with no `SPELL_CAST_SUCCESS`) — without them the sim reads a busy healer as
idle; and absorb events (`SPELL_MISSED`/`SWING_MISSED` with `ABSORB`), which are why a heal was
not needed. Also: use CLEU `SPELL_CAST_SUCCESS`'s `destGUID` for the player's own casts and delete
the first-heal matching heuristic entirely (the brief settles this; §11's open question is closed).

**CONCEDE.** 4,000 events per fight is fine for 5-mans (a 167s pull is *est* 700–1,000 with damage
included); it will be badly short in a 25-man where the recorder sees 25 players' damage taken and
every heal they receive — *est* 40–80 events/s, i.e. ~60–100s of a boss fight.

**RISK.** Two storage tiers is more code and one more thing to keep consistent.

---

## C10. The six coaching labels

**POSITION.** Necessary but not sufficient; two are mis-specified, and the set needs a residual
bucket before any of it can be trusted.

**ARGUMENT.** `early` is wrong for Lifebloom, which is 68% of this player's casts (245/362): a
recast on a live stack *adds a stack and resets the timer* — the design's own §4.2 says so — so
refreshing at 5s is correct rolling, not waste, yet the mock card labels exactly that as "early,
9 casts, 0.6k". The median Lifebloom→Lifebloom gap here is 4.96s (p25 2.3, p75 6.75), so a naive
`early` rule would flag most of the run and the habits list would be dominated by an artefact.
Split it: `early(Rejuvenation)` = pending ticks discarded, real mana loss; `stack` = maintaining
x3 where x1 covered the incoming damage. Missing labels: `late` (you cast, but after the dip — the
set has `idle` for not casting at all and nothing for mistimed); `form` (3.3k mana of shifting in
this run is invisible to all six); `utility` (12 casts, ~7% of spend, must be excluded from the
denominator or it becomes phantom waste); `sniped` (a foreign heal landed on the same target
inside your cast window — needs C4's data anyway). And mandatorily: **`unclassified`**, printed on
the card with its mana. A classifier with no residual category cannot be wrong, which means it
cannot be checked; if 20% of casts do not fit the plan's rules, the habits are not a finding.

**CONCEDE.** Six-ish actionable labels is the right *size*; this is a correction, not a demand for
twenty.

**RISK.** A visible `unclassified 18%` line makes the feature look unfinished when it is merely
honest.

---

## C11. Search, objective, tie-breaking, robustness

**POSITION.** Lexicographic (deaths → floor-violation seconds → mana → robustness → fewer binds),
multi-start coordinate descent, and — the important one — **the plan is fitted on pooled fights
and reported on a held-out fight**, never fitted and reported on the same 40s pull.

**ARGUMENT.** A weighted scalar score hides the trade the healer actually wants stated ("cheapest
thing that is safe"), and it needs weights nobody can defend; lexicographic needs none, and
"minimise seconds-below-floor" degrades gracefully when the scenario is infeasible, which the
design's "latest first violation" does not (a plan that dips at 0:39 for 1s ranks below one that
dips at 0:38 for 20s). The overfitting problem is the serious one: the design fits ~5 parameters
(2–3 thresholds, stack count, filler, 3–4 rank choices) to a single fight that contains **8 casts
at the median** (the qualifying fights here run 5–42 casts, median ~11). That is more free
parameters than data, and the resulting "plan" is a description of one pull's noise. Fix it
structurally: `Coach` on one fight produces *labels and a diff* only; a **plan** requires ≥5
recordings in the same zone, is fitted on N−1 and scored on the held-out one, and the card prints
both numbers. If held-out mana is much worse than fitted mana, the search overfitted and the card
says so. Coordinate descent on a landscape with discontinuous thresholds will also sit in local
optima — use 3 random restarts plus the two baselines as starts, and report the whole
near-optimal set (within 5% mana), because a plan 3% worse with one fewer bind or one that
survives ±20% on the damage rate is the better human answer.

**CONCEDE.** For a first release, fitting on one fight is acceptable *if* the card calls it "this
fight" and never "your plan".

**RISK.** Requiring 5 same-zone recordings delays the first satisfying card by a full evening of
play.

---

## C12. Replay traps

**POSITION.** Three real traps, one of them log-proven; all three need explicit handling or the
replay silently validates against a fiction.

**ARGUMENT.** (1) **Deaths truncate the damage stream.** A DPS who died at 0:25 of a 0:40 pull
contributes no damage for the last 15s; the optimizer, running on that timeline while keeping him
alive, sees a fight that got mysteriously easy and prescribes a cheaper plan — and the card then
scolds the player for the mana he spent trying to save him. Any fight with a death must be
excluded from Coach (it can still be replayed for validation, and the death is the finding).
(2) **Initial state is not empty.** The log shows Lifebloom and Regrowth ticking on the tank
continuously through `+2144`–`+2153` before the pull at `+2153.81`; a sim starting with a naked
roster will re-cast them, spend the mana, and both curves diverge from the first second. The
recording must capture active HoTs, their stacks and remaining durations, and the player's buffs,
at `PLAYER_REGEN_DISABLED`. (3) **Damage is not fully independent of healing** — threat from a
big heal can move a mob onto the healer, and mobs with low-HP-seeking abilities respond to HP the
sim is now setting differently. That one is genuinely out of scope, but it belongs in the card's
caveat line rather than in the "damage taken is independent of healing" assumption stated flatly.
Also: overkill on the killing blow means the last damage event overstates HP lost; use `overkill`
to correct it, or the reconstructed HP curve ends below zero and the deviation metric is polluted.

**CONCEDE.** Trap (3) cannot be modelled and should only be disclosed.

**RISK.** Excluding fights with deaths removes exactly the fights the author most wants reviewed.

---

## C13. Presets from recordings

**POSITION.** Mean-plus-pulse is the wrong summary and the "3× mean in a 2s window" detector will
fire almost everywhere. Summarise per role as (rate with a CI) + (distribution of 2s-window
damage: p50/p90/p99) + (big-hit process defined in units of the target's own maxHP).

**ARGUMENT.** Melee damage is bursty by construction: a tank taking 450 dps takes it as ~900-point
swings roughly every 2s, so a large fraction of 2s windows already sit at 2× the mean and a
meaningful fraction at 3× — the detector would report a "pulse" every few seconds and then compute
a nonsense mean gap. What actually threatens the floor is not a multiple of the mean but an
absolute fraction of the target's health: define a big hit as **≥15% of that target's maxHP within
1s**, and summarise its rate and size distribution. Keep the mean rate for the between-hits
baseline. Carry the variance, not just the mean, because a synthetic scenario without variance
cannot be run through C1's replicates and will always report "nobody dies". Provenance in the file
in the `Data/SpellData.lua` tradition: n fights, n seconds, zone, date, and the CI — with 18
qualifying fights per run and 771s of combat, a per-role rate estimate from one run has maybe
±15% *est* on it and should say so.

**CONCEDE.** For a first pass, mean + big-hit rate (no distribution) is enough and is still better
than mean + pulse.

**RISK.** Three numbers per role in the Setup table instead of two, on a screen already dense.

---

## C14. Should coaching suggest different binds?

**POSITION.** Yes, but rate-limited and evidence-gated: at most **one** bind change per report,
requiring ≥15% of fight spend saved, stability across ≥5 fights, and survival of the held-out
check from C11.

**ARGUMENT.** This project has already made this call once and should not contradict itself:
v0.5 §3 kept the Pareto filter and the suggested rank on *raw* values precisely so that a noisy
measurement could never silently move a recommendation and fire a "rebind?" toast. A search over
2,000 plans on a 40s pull is a far noisier instrument than the overheal fraction was. A
recommender that says "bind Regrowth R7" on Tuesday and "R9" on Thursday is worse than one that
never speaks, because the rebinding cost is paid every time and the credibility is spent once.
The gates above make the message rare and therefore worth reading. Tuning *how* the existing binds
are used has no such cost and can be reported freely.

**CONCEDE.** A downrank that is Pareto-dominant on the dashboard *and* wins in the sim is safe to
suggest immediately — the two instruments agreeing is the evidence.

**RISK.** The gates may be so strict that the feature's most striking output (a genuinely better
bind set) almost never appears.

---

## C15. GCD and latency

**POSITION.** The GCD is a hard 1.5s scheduling constraint, separate from cast time. Reaction
delay applies **only at decision points after idling**, not between chained casts — and its
default should be measured per player, not set to 0.3s.

**ARGUMENT.** With 68% of this player's casts being instants, the binding constraint on throughput
is the GCD, not cast time; folding it into `castTime` (as "instants sit at the GCD") happens to
work for a single spell but breaks the moment an instant follows a 2.0s cast whose GCD has already
elapsed. Model `nextAction = max(castEnd, lastCastStart + 1.5)`. On latency, the log is decisive
against the 0.3s default: the distribution of gaps between consecutive casts has **p10 = 1.50s and
p25 = 1.51s** — when chaining, the author hits the GCD exactly, because the client queues the next
cast. Charging 0.3s on every action would give 1.8s per instant instead of 1.5s, **17% fewer casts
per unit time**, and would make every plan look cheaper and safer than it is in a way that
compounds over a 3-minute fight. Reaction is real only after a pause, where the human has to
notice; take the default from the recordings themselves (the excess of the observed post-idle gap
over the GCD) with provenance, in the `db.oomConfidence` tradition.

**CONCEDE.** A single global 0.3s is defensible as a *conservative* setting for synthetic
scenarios, where there is no measurement to draw on.

**RISK.** Two latency concepts (post-idle reaction, and C3's information staleness) is subtle and
easy to double-count.

---

## C16. Delivery order and the first win

**POSITION.** Order is right. Insert the physical lower bound (C2) into v0.7.1, before the
planner. First win: **the Review list with replay deviations, and a per-fight "where the mana
went" breakdown that needs no planner at all.**

**ARGUMENT.** Recorder → engine → validation first is correct and is the same discipline that made
calibration worth having. But the first *convincing* artefact should not depend on the search
being right, because the search is the least trustworthy component and it arrives last. Everything
needed for a striking card exists at v0.7.1: the recording gives total damage taken per target, so
the physical floor `Σ max(0, D_i − headroom_i) / maxHPM` is computable, and the log already
supplies the rest — "this pull took 21.3k damage across 5 targets; the minimum mana that could
have covered it is 2.6k; you spent 6.2k; 1.7k of it landed on people at full health, 0.3k went on
form shifts, 0.4k on utility." That is falsifiable, needs no plan family, no search and no
coroutine, and it is the number the author is actually chasing. If it lands, the planner is worth
building; if the author shrugs at it, the planner would not have saved it.

**CONCEDE.** The bound needs the damage recorder, so it cannot precede v0.7.0.

**RISK.** A compelling v0.7.1 could make the planner look like diminishing returns and stall it.

---

## MISSING FROM THE DESIGN

**1. Initial state, and it is log-proven.** The recording starts at `PLAYER_REGEN_DISABLED`, but
the fight does not start there. In `dungeon-BF-1.txt` the tank has Lifebloom and Regrowth ticking
continuously from `+2135` through the pull at `+2153.81` — 19 seconds of pre-cast HoTs, applied
out of combat, worth several hundred HP of healing and ~350 mana already spent before t=0. A
replay that starts with an empty aura state will re-cast them (mana curve diverges immediately) or
under-heal the first ten seconds (HP curve diverges). The scenario needs `initialAuras` per target
— spellID, stacks, remaining duration — snapshot at the pull, plus the player's own buff state.
Related: mana at the pull is frequently not full (5299, 5594, 6184, 6459, 6549 in this run), which
the design does capture, and the sim's "OOM never" claims are only meaningful relative to that.

**2. Form is a time-varying model input, and nothing in the design tracks it.** The author shifted
to and from Tree of Life **10 times** in 28 minutes at 332 mana a shift — 3,320 mana, roughly half
a hard pull's entire spend, spent on something the plan family cannot express and the classifier
cannot label. Worse, form changes the *healing model*: the Tree aura adds 25% of Spirit to every
party member's healing received and `RankMath:Context` reads it as a static boolean. During a
replay the sim will apply a caster-form heal value to a heal cast in tree form (or vice versa) for
every cast on the wrong side of a shift. Calibration already had to build a `FORM_GRACE` window
for exactly this reason. The recorder must log form transitions as events and `SpellKit` must be
queryable at a time, not just at "now".

**3. No uncertainty propagation onto the card.** Every other surface in this addon carries its
scope: `roleSource` travels with the role, the overheal tooltip says whether a fraction is rank-
or family-scoped and marks borrowed data with a grey `?`, the clock refuses digits above
`sigma/net = 0.7`. The Result mock prints "mana 4.1k / lowest 31% / OOM never" with no error bars
at all, and those numbers are the product of a heal model whose own calibration is only "3 of 4
spells within 3%", a damage timeline of one sample, and a search that may be at a local optimum.
The card needs a compact provenance block: replay deviation, per-spell drift for spells ≥10% of
spend, foreign-heal share, fights fitted on, held-out result, and `unclassified` share. Without
it the sim will be the first component of this project whose output cannot be audited.

**4. Serialization format and GC, both of which will bite in-game.** SavedVariables is written as
Lua source and read back by the client's parser; a per-event table costs 60–120 bytes of *text*,
so the stated cap is ~1.8 MB of file that is parsed at every login and rewritten at every logout,
plus 48,000 table allocations at load. Interleaved flat numeric arrays cut it ~3× and remove the
allocations. The same discipline applies inside the simulator: ~1,500 events × ~80 bytes per
event-table × 300 candidate plans is ~36 MB of garbage per search, which in WoW means repeated
full collections and visible frame hitches during the very operation the design promises will be
smooth. Pool the event objects, use parallel arrays for the timeline, and never allocate inside
`Run`.

**5. No falsification test for the classifier.** Six labels with no residual category cannot be
wrong. Two checks make it auditable: an `unclassified` bucket printed with its mana, and the
identity `Σ mana over all labels + utility + form shifts = fight spend` — which, on this log, is
the check that would have caught the missing 3.3k of form shifts and 7% of utility casts
immediately. Any classification scheme where the parts do not sum to the whole is producing
percentages of an unknown denominator.

**6. Overfitting is unaddressed and is the largest threat to the feature's credibility.** Five-ish
free parameters fitted to a fight with a median of ~11 own casts will produce a "plan" that is a
description of that pull's noise, and the second time the author plays the same instance it will
recommend something different. Standard remedy, cheap here: pool same-zone recordings, fit on N−1,
report on the held-out fight, and print both. The gap between fitted and held-out mana *is* the
honesty metric, and it costs one extra simulation per candidate at the end, not per candidate in
the loop.

**7. A physically-grounded lower bound is absent, so "best" is unbounded below.** Nothing in the
design can distinguish "the family is near-optimal" from "the search is stuck". `Σ_i max(0, D_i −
(hp0_i − floor_i·maxHP_i)) / maxHPM`, with a `casts × 1.5s ≤ duration` feasibility check, costs
one pass over the recorded events and gives both a sanity bound on the search and the most
interesting number on the card — how much the five-button constraint itself costs.

**8. Raid scale is out of budget and is on the author's stated roadmap.** In a 25-man the recorder
sees damage taken by 25 players plus every heal they receive: *est* 40–80 events/s against
~5–8/s in this 5-man, so the 4,000-event cap covers ~60–100 seconds of a boss fight, and the
simulator's per-run cost scales with both the event count and the target loop (25 targets instead
of 5) — *est* 10–25× per simulation, which puts a search of even 100 plans past a minute. Decide
now whether raids are recorded in full (needs assignment-scoped filtering: record only assigned
targets plus tanks) or summarised; retrofitting a filter after the format is persisted is worse.

---

## MY TOP 3 DECISIONS THAT MATTER MOST

**1. Replay validation with published numeric gates, and Coach hard-disabled below them
(C8, C12).** Mana mean |Δ| ≤ 2% of pool, HP mean |Δ| ≤ 3% of maxHP; plus no deaths, foreign-heal
share ≤ 25%, calibration drift < 3% on spells ≥10% of spend, ≥90% of spend accounted for. This is
the only thing standing between a coaching feature and confidently-wrong advice the author cannot
check, and the traps that would defeat it (pre-pull HoTs, form shifts, truncated post-death damage)
are already visible in the one log we have.

**2. Bracket the answer instead of asserting it: physical lower bound below, held-out validation
around, foreign-heal interval beside (C2, C4, C11).** "you 6.2k | rule plan 3.9k | physical floor
2.6k, fitted on 5 fights, held-out 4.3k" is a defensible sentence; "best plan 3.9k" from a
2,000-point grid search on one 40s pull with 8 casts is not. The bound costs one O(events) pass
and simultaneously falsifies the search.

**3. EV for the objective, Monte Carlo for the constraint; and fix the two timing constants that
bias everything (C1, C15).** Report `P(floor violation)` from ~30 replicates of the three reported
plans rather than a deterministic `ok = true`, and stop charging 0.3s of reaction on chained casts
— the log's p10/p25 inter-cast gap is 1.50/1.51s, so the author queues at the GCD and a blanket
0.3s would understate his throughput by 17%, making every plan look cheaper and safer than it is.
