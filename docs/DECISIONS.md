# ManaDemon — design decisions and rationale

This documents the full design process: two AI agents ("Party A: Theorycrafter" — math
correctness first; "Party B: UX Pragmatist" — glanceable, decision-driving UI first)
brainstormed independently, exchanged rebuttals, and critiqued the implementation plan;
a judge synthesized; the author (NeRgY, Resto Druid, TBC Anniversary) made the final calls.
Date: 2026-09-01.

## v1 scope (final)

1. **Static spell data table** (`Data/SpellData.lua`) — ships first: the 2.5.x client does
   not reliably expose per-rank mana costs, so a frozen hand-built table is the foundation
   *and* the schedule risk. Verified once in-game via `/md verify`.
2. **TTO engine** — spend rate from casts (EWMA), regen rate analytic, FSR state machine.
3. **One-line combat UI** — floating widget + ElvUI datatext, both rendering
   `MD:GetDisplayString()`. 5SR underline on the widget.
4. **Rank dashboard** (`/md`) — druid-only, Pareto-filtered.
5. **Advisor extras** — Innervate/potion advisor, gear-change rank toast, drink reminder
   (all four extras chosen by the author; the drink reminder was disputed — A called it a
   nag, B proposed it — author sided with B).
6. **End-of-combat summary** + last-5-fights in-memory history.

**Cut from v1** (explicit decisions, not omissions):
- **History-based fine-tuning of the OOM prediction** — both parties converged on cutting
  it: the decision it drives ("pot now or in 20s?") is coarse; weeks of modeling to move a
  number the player rounds anyway. Survives only as: (a) pull-time seeding of the spend
  EWMA from the last ~5 fights' median rate, (b) a "last fight" reference line. No
  SavedVariables persistence of history, no curve fitting.
- **Non-druid rank dashboard** — per-class coefficients/spell lists are real work; the TTO
  engine is class-generic for free (see FSR decision below), so TTO+advisor work for any
  healer and the dashboard says so.
- **Confidence band in the UI** — A wanted p25/p75 shown; B argued a band isn't actionable.
  Merged: the single displayed number is the *pessimistic* edge (p75 of the spend
  distribution) and instability is carried by one `~` prefix + grey, driven by a
  suppression rule (≥6 casts in window AND IQR ≤ 40% of median).
- **Config UI** — slash commands + three checkboxes in the dashboard footer.
- Raid comms/sync, graphs/animations/themes, "efficiency scores", per-rank
  overheal-calibrated recommender (v2 candidate — needs a corpus of the author's logs).

## Model decisions (who won which argument)

| Decision | Outcome | Why |
|---|---|---|
| TTO before dashboard | **B** (A conceded) | TTO needs only cost+cast-time; the dashboard's dependency chain (coefficients, talents, Lifebloom split) is deeper, not shallower. |
| EWMA over 10s sliding window | **A** | Spirit regen ticks every 2s; a 10s window catches 3–5 ticks (±40% swing) and extrapolates chain-cast bursts into eternity. EWMA is also less code. |
| Regen analytic, never regressed from raw mana | **A** (B conceded) | Regressing raw mana entangles spend and regen; Innervate/potions poison the sample. |
| Use `GetManaRegen()` returns **directly** (base = out of FSR, casting = in FSR) | **A's self-correction** | Decomposing into spirit/mp5 components and re-weighting double-counts Intensity (casting already includes it). The spirit/mp5 decomposition exists for display only. Refreshed every tick because the value can go stale mid-combat on Classic clients. |
| FSR trigger = any player mana *decrease* on `UNIT_POWER_UPDATE` | **A (plan critique)** | Spell-table-independent: catches wands, off-spec casts, any class — this is what makes TTO class-generic. `UNIT_SPELLCAST_SUCCEEDED` alone misses spenders and the deduction anchor is unverified (hence `/md fsrtest`). Known false-positive: enemy mana burns (accepted). |
| Sustainable sentinel instead of TTO=∞ | **A (plan critique)** | `mana / max(0, spend−regen)` divides by zero when regen wins. |
| Spend-cost fallback = `GetSpellPowerCost` (pcall), then **log**, never UnitPower-delta sampling | **B (plan critique)** | Delta sampling races spirit ticks and Innervate; a missing cost is exactly what `/md verify` should report, not paper over. |
| Drop dominated-rank rows behind "show all"; never highlight raw best-HPM | **A** (B conceded) | Raw HPM monotonically favors rank 1 — an HPM-only dashboard always answers "HT R1". Pareto filter on (HPM, HPS); "suggested" = highest-HPM non-dominated rank healing ≥40% of max rank (labeled assumption). |
| Mana-cost modifier pipeline (Moonglow −3%/r on HT/Regrowth/Rejuv, Tranquil Spirit −2%/r on HT/Tranquility, Tree of Life −20% on HoTs, floor at the end) | **A (plan critique)** | Without it every HT HPM figure is off by up to ~18% for a typical resto build. |
| Talents scanned by **name** across all tabs, re-scanned on respec events | **A (plan critique)** | Positional `(tab, index)` silently returns the wrong talent when builds shift. |
| Widget: single visibility owner, 90/95% hysteresis, frames created at login, position persisted, `/md unlock`+`reset`, first-run 60s forced preview | **B (plan critique)** | Prevents flicker at the threshold, mid-pull frame creation, unrecoverable off-screen drags, and the "fresh install shows nothing" trap. |
| Model event-driven; tickers only accumulate/render | **A (plan critique)** | The draft ran the 0.25s recompute "only while the widget is shown", which would stall the estimator while hidden. |
| ElvUI datatext built-in (not a separate addon), `## OptionalDeps: ElvUI`, clamp ElvUI's first `elapsed=20000` OnUpdate call, take theme color from `ApplySettings` | **B** (A conceded v1 placement) | Verified against vendored ElvUI TBC build: `DT:RegisterDatatext` exists, comparable datatexts are 19–72 lines. |
| One attention event per fight (pulse at TTO<30s), no sound | **B** | Alert fatigue kills combat UIs. |
| 5SR underline stays in v1 | **Author** (B tried to defer its own idea) | Author explicitly selected it. |
| Drink reminder in v1 | **Author** (against A's cut vote) | |

## Formulas encoded in `Engine/RankMath.lua`

- Direct coefficient: `clamp(baseCastTime, 1.5, 3.5) / 3.5`
- HoT coefficient: `duration / 15`
- Hybrid (Regrowth, c = cast/3.5, h = dur/15): direct `c²/(c+h)` ≈ 0.1657, HoT `h²/(c+h)` ≈ 0.9941
- Sub-level-20 malus: `1 − (20 − spellLevel) × 0.0375` (3.75%/level, **not** 5%)
- Downrank penalty: `min(1, (spellLevel + 11) / casterLevel)`
- Penalties apply to the **bonus-healing contribution only**, not base heal
- Healing crits are **1.5×**; HoTs never crit; Improved Regrowth is +10% crit *chance*/rank (Regrowth only)
- Talent multipliers applied after coefficients: Gift of Nature +2%/r (all), Improved
  Rejuvenation +5%/r, Empowered Rejuvenation +4%/r on the bonus portion of HoTs,
  Empowered Touch +10%/r on the bonus portion of HT, Naturalist −0.1s/r HT cast
- Lifebloom: HoT coefficient 0.5187 total, bloom 0.3422 (empirical 2.4-era values)

## Open verification items (run `/md verify` in-game)

- All `-- VERIFY` rows in `SpellData.lua` (high-rank costs/heals are the least certain).
- `GetManaRegen()` unit (assumed mana **per second**; ElvUI's TBC datatext ×5 agrees) and
  its combat staleness behavior.
- FSR anchor: cast start vs. mana deduction vs. cast completion → `/md fsrtest`.
- ~~Whether talent-modified costs floor or round~~ — **round** (Swiftmend 216.8 → 217, 2026-09-03). Tree of Life also discounts Tranquility.
- ~~Lifebloom coefficients and whether Empowered Rejuvenation touches the bloom~~ — **confirmed 2026-09-03** (heal log): 0.5187 / 0.3422 exact, Emp Rejuv applies to the bloom
  (assumed **not** — applied to tick portion only, conservative).
- `GetSpellPowerCost` presence on the anniversary client (harness reports either way).
- Downrank penalty exact form vs. tooltip reality at level < 70.

## v2+ backlog (from the debates)

- ~~Overheal-calibrated effective HPM~~ — **shipped v0.5.3** (`Engine/Overheal.lua`).
- ~~Per-boss "last time you sustained X mps" reference~~ — **shipped v0.5.3** as a
  zone-scoped pull seed (`MD.cdb.fights`); per-boss would need encounter IDs.
- ~~TTO-with-cooldowns second line~~ — **shipped v0.5.2** as the `inn 2:10` segment.
- Non-druid rank dashboards (priest first).
- Rank→keybind/macro helper; localization.

## Feedback round 3 (2026-09-02): OOM + FULL display, estimator stability

The author reported the readout "changes a lot and it is hard to catch what it really
means" and asked for OOM time and time-to-full "at the same place". Same two-party
debate (A Theorycrafter, B UX Pragmatist) with a rebuttal round; judged by Fable.
Both parties converged on most of the math; the table records who won the rest.

| Decision | Won by | Why |
|---|---|---|
| One signed clock, label carries the sign (`OOM 1:20` / `FULL 0:45`), not two permanent slots | **both** | One of the two is structurally dead (`--`) in every state; a permanent dead slot is the confusion being fixed. |
| Secondary `rest 2:10` segment = time to full if you stop casting now, combat only, hidden when within 25% of the primary or next to a FULL clock; `/md rest` toggle | **A** (B conceded, then A conceded back — judge kept it) | Every input is exact (mana, `GetManaRegen`, FSR clock) so it is ~zero-variance; it is the cost of the decision the primary provokes (drop out / Innervate / pot) and it is live during warm-up. It is also the literal "both at the same place" the author asked for. |
| Separator is two spaces, never `\|` | **B** | A bare pipe opens a WoW colour escape and eats the rest of the line. |
| Drop `max(EWMA, p75-of-six-buckets)`; pessimistic = `rate + 1.0 * sigma`, `sigma = lambda * sqrt(sum w^2 c^2)` | **A** (B conceded) | `max()` of two estimators is upward-biased by an unstatable amount and kinks when the argmax switches; the 6-bucket order statistic re-sorts every 5s. Sigma is continuous, calibrated (`sigma/rate = 1/sqrt(n)` for equal casts), one extra accumulator in the same loop, and it feeds display precision and the stability flag for free. Caveat: real casting is autocorrelated, so sigma understates; `K=1.0`, `CV<=0.35` are first guesses. |
| Regen for projection = FSR-duty-weighted `duty*casting + (1-duty)*base`, duty = EWMA of in-FSR (half-life 20s), reset to 1 at pull | **both** | Instantaneous `RM:Current()` flips the denominator by the whole spirit share every time a casting gap crosses 5s — the single biggest source of jumps. Both `GetManaRegen` returns are still consumed raw; nothing is decomposed. `RM:Current()` keeps driving the 5SR underline. |
| Display precision derived from uncertainty: step = smallest of {1,5,10,15,30,60} >= 0.5*sigma_TTO (floor 1s/5s, cap 60s); step coarsens at once, refines only after holding 5s | **A** + B's ratchet | Showing `1:23` when sigma is 20s is a lie of precision. Zero bias: only rendering resolution changes. The ratchet stops the granularity itself from flickering. |
| Latch, not a smoothing filter, on the shown value: change after 2 consecutive ticks, except worsening by >2 steps or crossing 60s/20s downward (instant) | **A** (B conceded its asymmetric follower) | `TTO = mana/net` is convex in `net`, so time-averaging the horizon is biased optimistic (Jensen). The latch has no bias in either direction. Raw `GetManaState()` stays unsmoothed for the advisor/summary. |
| `hold` mode when `\|net\| <= sigma`: print the one-sided bound `OOM >4:00 =` (`mana/(net+sigma)`), `OOM >10m` when unbounded; mode changes toward "better" also need 2 ticks | **A** (B conceded its 1.10/0.98 label hysteresis) | A true statement instead of a point estimate that is statistically zero; the hysteresis falls out of the statistics instead of being bolted on. Replaces the old "sustainable" sentinel. |
| Arrow derived from the SHOWN value over ~10s, adjusted for the 1s/s countdown (`=` steady drain, `v` losing ground faster, `^` recovering); no arrow in FULL or out of combat | **A** (B: "the best idea in A's proposal") | Arrow and number can no longer contradict each other; the old raw-net ring could. |
| Out of combat: fill = max(observed mana-gain EWMA (half-life 5s, >=2 gains), FSR-aware `GetManaRegen`) | **B** (A conceded) | Drink/food are periodic energize effects `GetManaRegen` does not report; without this the FULL clock would read ~10x too long in the widget's most common OOC state. `/md verify` now prints the drink-buff state next to `GetManaRegen` to confirm the premise. |
| Half-life stays 15s (user-settable 5–60) | **A** | Noise falls as `1/sqrt(H)`; 4x half-life buys 2x less noise and an 86s window straddles fight phases. Sigma now expresses the uncertainty honestly instead of hiding it. (Each party conceded the other's number; judge kept the default.) |
| Widget text left-anchored, 190px, render 0.25s (underline stays 0.1s), `>10m` cap | **B** | Centred text slides when the digit count changes; beyond 10 minutes the raw number is both enormous and relatively unstable and drives no different action. |
| Rejected: counterfactual "at fight-average spend" second clock; confidence band; second line | **B** | A readout the player must be taught fails the one-second glance test. |

Supersedes the v1 rows "pessimistic edge = p75" and "sustainable sentinel".

## Talent audit (2026-09-03)

Reviewed every talent that touches heal size, mana cost or regen against `Engine/RankMath.lua`,
`Data/SpellData.lua` and `Engine/RegenModel.lua`.

| Talent | Where | Status |
|---|---|---|
| Gift of Nature +2%/r | RankMath, all families incl. Lifebloom bloom | OK |
| Improved Rejuvenation +5%/r | RankMath (whole Rejuv heal) | OK, but see stacking below |
| Empowered Rejuvenation +4%/r on HoT bonus | Rejuv, Regrowth HoT, Lifebloom ticks (+x2/x3 rows) | OK; bloom deliberately excluded pending verification |
| Empowered Touch | RankMath, HT bonus × (1 + 0.1r) | **Wrong shape**: the talent ADDS 0.1r to the coefficient. Identical for HT R5+ (coef 1.0), low for R1–R4 |
| Improved Regrowth +10% crit/r | RankMath (Regrowth direct only) | OK |
| Naturalist −0.1s/r HT | RankMath cast time; coefficient still from base cast | OK |
| Nature's Grace (−0.5s next cast after a crit) | — | **Not modelled**; ≈ −0.5·crit s per chain-cast HT/Regrowth (a few % HPS) |
| Moonglow −3%/r (HT, Regrowth, Rejuv) | SpellData:GetCost | OK, but see stacking |
| Tranquil Spirit −2%/r (HT, Tranquility) | SpellData:GetCost | OK, but see stacking |
| Tree of Life −20% cost on form HoTs; castable set | SpellData:GetCost, families.tol | OK |
| Intensity, Living Spirit, Dreamstate, Lunar Guidance, Natural Perfection, Tree aura | via `GetManaRegen` / `UnitStat` / `GetSpellBonusHealing` / `GetSpellCritChance` | Implicit, no double count — **except Dreamstate, which the author reports is NOT in the reported mp5** |
| Omen of Clarity | — | Melee-proc only in TBC; irrelevant to a healer's spend |

**Percent-modifier stacking.** The code multiplies same-type percent mods; the TBC client
sums them first (spellmod pct accumulation). GoN 5 + Imp Rejuv 3 = +25%, not +26.5%;
HT cost with Moonglow 3 + Tranquil Spirit 5 = −19%, not −18.1%; Rejuv/Regrowth in Tree
with Moonglow 3 = −29%, not −27.2% (≈7 mana per Rejuv). The cost half shows up directly as
COST mismatches in `/md verify`; that output decides it (open item, not changed yet).

**Dreamstate.** Measured 2026-09-03 (`/md regentest`, two specs, same character): the raw
`GetManaRegen()` EXCLUDES it — ticks ran ~34 mp5 above the API with the talent and matched
the API without. `RegenModel` now adds `{4,7,10}% × Int / 5` per second to both rates
(`RM.unreported`); the raw values are kept in `RM.apiBase/apiCasting` and the test compares
against those, so the verdict remains valid. Not extended to other classes' int-based regen
talents (Shaman Unrelenting Storm) until measured.

**Costs, superseding "the 2.5.x client does not reliably expose per-rank costs" (v1 scope) and
"mana-cost modifier pipeline" (model decisions):** `GetSpellPowerCost` works on this client
(44 costs checked), so `SD:GetCost()` is live-first and the static table is the fallback +
verify reference. Static Rejuvenation R6–R12, Tranquility R1–R4 and Swiftmend costs were
wrong and are now the live values; Innervate is a percentage of base mana and has no static
cost. With live costs the cost-side stacking question is moot; the heal-side one (GoN +
Improved Rejuvenation, ≈1%) stays open.

**Spirit share decomposition (display only):** the level-70 constant read 2× low at level 64,
so `RM:Components()` now derives it from the API's own two numbers and the in-5SR talent
fraction: `S = (base − casting) / (1 − f)`, `G = base − S`. Cross-checked: G = 21 mp5 in both
specs of the test character.

**Display latch:** the shown value now latches on a candidate within one step of the previous
candidate (jitter-tolerant); and the OOC observed-fill estimate is an EWMA over gain events
(gain / interval), not a per-tick EWMA of a 2s-periodic signal. Fixes `FULL 2:05` stuck at a
true 94s.

**Tree of Life form (2026-09-03, v0.4.2).** Cost: live via `GetSpellPowerCost`, refreshed on
`FORM_CHANGED`. Heal: the form's aura is +25% of Spirit as healing *received* by party members
(the tree included), invisible to `GetSpellBonusHealing()`; `RankMath` adds it to the +healing
input while in form (`db.treeAura`, default on) because it takes the same coefficient and
downrank path as caster +healing (MaNGOS-era `SpellHealingBonus`: taken advertised benefit ×
coeff). Only true for party targets, which is why it is a setting and labelled on the
dashboard. **Confirmed 2026-09-03** (heal log): Rejuv ticks +21 and Lifebloom ticks +7 / bloom +32
in form = 70 Spirit × coefficient × Emp Rejuv × talent multipliers, i.e. exactly "+healing on the
target". The aura is target-side and dynamic: a HoT already running gains it the moment the
tree shifts. **Relics:** the same log showed Rejuvenation ~3% above the model with Lifebloom
exact — the signature of a flat +50 on Rejuvenation (Idol of Rejuvenation); `SD.relics` +
`SD:Relic()` read the relic slot and add flat / per-tick / aura bonuses (best-effort table,
VERIFY per idol). With the idol, GoN × Improved Rejuvenation fits multiplicative (1.265) better
than additive (1.25); kept multiplicative.

## Settings window and debug console (2026-09-03)

| Decision | Why |
|---|---|
| Mimic Cell's options UI (flat 0.115-grey panels, 1px black borders, class-colour accent, tab buttons on the frame's top edge, titled panes, 13/14px fonts) with a from-scratch kit in `UI/Style.lua` | Author's explicit ask ("I like their settings in general"). No dependency on Cell or its libraries; no pixel-perfect layer — plain sizes are enough for one fixed-width window. |
| Settings live in their own frame (`/md options`), the dashboard keeps only a "Settings" button | Cell separates the options frame from the unit frames; the rank table and the options have different widths and lifetimes. |
| Debug console = Cell's DebugConsole concept: `MD:Debug()` is a no-op unless enabled, memory-only ring (1000 lines), category filters, Copy popup with select-all edit box | Author's ask ("debug logs concept"). Memory-only keeps SavedVariables clean; the Copy popup is the only way to get text out of the client. |
| Explicit categories on each `MD:Debug` call (regen / mana / spend / tto / combat / chat / other) instead of Cell's pattern-matching on the text | Cheaper and never misfiles a line. |
| `MD:Print` mirrors into the `chat` category | `/md verify` and the regen test output become copyable without a second code path. |
| Timestamp = wall clock + seconds since load with 2 decimals | Sub-second spacing is the point for mana ticks and 5SR edges; wall clock ties it to the author's notes. |
| `/md regentest` measures instead of assuming (observed gain vs time-weighted API, diff vs `{4,7,10}% × Int / 5`) | The only honest way to answer whether the API includes Dreamstate on this client. |


## v0.5 (2026-09-05): design calls made without a debate round

Design in `docs/DESIGN-v0.5.md`; the author approved it and said to implement. The five
calls its §11 flagged as arguable were decided as follows — all reversible, and each one
notes what would change my mind.

**1. `inn 2:10` takes the one-liner's secondary segment (under 90s), rather than living
only in the tooltip.** The widget's value is that it never changes shape, so this spends
its single secondary slot. Justification: under 90s the cooldown is the only decision
left, and `rest` ("stop casting entirely") is the option you are least likely to take.
Gated on the cooldown being ready AND worth ≥10% of the pool, so it stays quiet otherwise.
`db.showCooldown` turns it off. **Would change my mind:** the author finding it noisy in
one real fight (`docs/TESTING.md` §9 asks directly).

**2. Overheal keyed by family, refined per rank at 40 events.** Per-rank-only would be an
empty column for months; family-average is precisely the wrong shape for "does downranking
overheal less", since one factor on every rank of a family cannot reorder them. Both are
true, so both are shown: the tooltip labels the scope, and a rank with no data of its own
shows the raw number with a grey `?` rather than a borrowed one dressed up as measured.

**3. The Pareto filter and the suggested rank stay on RAW values.** With a family-scope
fraction the ranking cannot move anyway; the only thing that *would* move is the
"heals ≥40% of max rank" gate. Letting a noisy measurement silently change the recommended
rank — and therefore fire a "rebind?" toast — is not a trade worth making yet. Revisit when
per-rank scopes routinely fill.

**4. Effective mode is a toggle, not an eleventh column.** The table is already ten columns
at 760px. A column would let you see raw and effective at once, which is the real
comparison — that comparison now lives in the row tooltip instead, which shows both.

**5. Nature's Grace feeds HPS, HP5 *and* To OOM, not HPS alone.** They are all
chain-cast metrics from the same cast interval; feeding one and not the others would make
the row internally inconsistent. The visible consequence is that To OOM goes slightly
*down* (a faster cast earns less regen per cast), which is correct and is stated in the
tooltip.

**6. The Nature's Grace term is the exact mixture, not the plan's shorthand.**
`docs/PLAN.md` wrote `cast − 0.5 × crit` floored at 1.5s. That clips the wrong branch:
with `T0 = 2.0` and `p = 0.65` the floored form gives `max(1.675, 1.5) = 1.675` while the
truth is `0.35 × 2.0 + 0.65 × 1.5 = 1.675` — equal here, but at `T0 = 1.8, p = 0.5` the
floored form gives 1.55 and the mixture gives 1.65, because half the casts cannot go below
the GCD. Implemented as `(1 − p)·T0 + p·max(T0 − 0.5, 1.5)`. Throughput over a chain is
`heal / E[T]` exactly, so averaging the cast time (not `heal/T` per cast) is the right
statistic for a sustained column.

**7. Innervate's value is MARGINAL, not gross.** `(boosted − RM:Effective()) × 20 − cost`,
where `boosted = 5·S + G + U`. The clock already projects `RM:Effective()`; adding the
gross figure to the pool would double count it. Suppressed entirely while the buff is up,
because `GetManaRegen` reports the boosted rate then and the clock is already right.
**Assumed** (§9 in TESTING): that the 400% multiplies the Spirit share only, and not flat
gear/buff mp5 or Dreamstate — neither is spirit-based.

**8. Static cost percentages now SUM.** The code already documented that the client sums
same-type modifiers (Moonglow + Tree of Life = −29%, not ×0.91 × ×0.8) and called the
multiplicative fallback a known ~2% error. The Simulate strip's form/Moonglow overrides
depend on that path, so it was fixed rather than inherited.

**9. The combat log's `amount` convention is detected, not assumed.** WoW documents
`SPELL_HEAL`'s `amount` both ways across versions (gross, of which `overhealing` was
wasted / net, with `overhealing` on top), and the fight summary had quietly assumed net. A
full overheal discriminates: gross reports `amount == overheal`, net reports `amount == 0`.
The first unambiguous sample latches `db.healAmountGross`, and `OH:Split()` then feeds both
the dashboard and the summary. Net stays the default until proven, so nothing moves on its
own.

### Still assumed, with the log line that settles each

| Assumption | Where | Settled by |
|---|---|---|
| Nature's Grace is 0.5s, floored at the GCD | `Engine/RankMath.lua` `ctx.ExpectedCast` | `cast` debug category, TESTING §8 |
| Innervate's 400% is spirit-share only | `Engine/ManaCooldowns.lua` `InnervateValue` | `regen` line on buff gain/fade, TESTING §9 |
| Overheal half-life 150 events, 40-event gate | `Engine/Overheal.lua` | one raid; counts visible in `/md profile` |
| `K_SIGMA` / `CV_STABLE` | `Engine/TTO.lua` | TESTING §5 — **unchanged by v0.5** |


## v0.6 (2026-09-05): calls made from the dungeon-BF-1 log

Full design in `docs/DESIGN-v0.6.md`. The log was a **level 61 dungeon on a level 64
druid** — a sample of how the author heals, not a specification. Every constant taken from
it is a setting with recorded provenance, to be re-derived from heroic and raid data.

**1. HP5 redefined to "sustained while chain-casting".** The author's intent was healing
per 5s on regenerated mana *while still casting* — permanently inside the five-second
rule. The old formula let you drop out of the FSR between casts and collect full regen, a
more optimistic and different question. Now `T = max(cost/castingRegen, castTime)`. This
simplifies to `HP5 = 5 x castingRegen x HPM` in the normal case, so the column rank-orders
exactly like HPM — that is stated in the tooltip rather than left to imply independence.
The old figure survives as a tooltip line ("if you let the 5SR lapse between casts"), being
the honest ceiling.

**2. `v = v or 0` is deleted from the clock.** It turned "no value yet" into "zero
seconds", which lands in the red critical band. Seen 9+ times in one run at 72-97% mana,
because the mode latch holds `disp.mode == "oom"` for two ticks after the state moves to
`hold`, and `hold` sets `bound`, not `tto`. Now: keep the last shown value, or render
`OOM --`.

**3. Digits are gated on the projection's own error, not retuned.** `sigma/net` separated
the one hard pull (median 0.43) from everything else (median 1.01) cleanly. Above
`db.oomConfidence` (default 0.7) the clock shows the one-sided bound it already has for
`hold` instead of a point estimate. `K_SIGMA` and `CV_STABLE` are deliberately NOT touched:
the mode logic was right, only the decision to print digits was wrong. **Would change my
mind:** heroic/raid logs where 0.7 hides a projection that was in fact actionable.

**4. Calibration reads the model; the model never reads calibration.** Multiplying
`RankMath`'s output by an observed drift ratio would make the dashboard agree with reality
while `Data/SpellData.lua` stayed wrong, silently absorbing every real finding — a missing
relic, a wrong coefficient, an unmodelled talent. Drift is a report to a human, who fixes
the data. This is exactly how the Idol of Rejuvenation was found by hand, automated.

**5. Calibration compares EVENTS, with crits separated, and does not decay.** A predicted
`(1 + 0.5 x crit)` expected value cannot be compared against an individual event, so
non-crit events are compared against the non-crit prediction and the crit *rate* becomes an
independent second check. No decay because the statistic is a ratio and therefore
gear-invariant: when +healing rises, observed and predicted rise together, so anything that
accumulates is a model error. Reset on talent change only.

**6. Role is READ, not inferred — correcting an earlier error in this session.** I first
concluded TBC exposed no role API, having checked `Cell/Utils.lua` and `LibGroupInfo.lua`
and stopped. Wrong: `RaidFrames/UnitButton_Vanilla.lua`, the file `Cell_TBC.toc` actually
loads, calls `UnitGroupRolesAssigned(unit)` unguarded, and `roleIcon` ships enabled by
default in `Layout_Defaults_TBC_Vanilla.lua`. Source order is
`UnitGroupRolesAssigned` -> `GetPartyAssignment` -> class-implied -> unknown, and
**`roleSource` travels with every report** so a guessed role is never presented like a read
one. Talent-based inference was rejected outright: it cannot separate a feral tank from a
feral cat.

**7. Overheal gains an event-kind dimension (tick / direct / bloom).** Needed twice over:
calibration compares per event kind, and Lifebloom's economics turn on the bloom
overhealing 49.8% against the ticks' 38.2%. Shared plumbing.

**8. Per-target overheal is session-only.** `u:<guid>` buckets are pruned on roster change
so SavedVariables cannot grow with every stranger healed in a pug. Family, spell, kind,
role and class buckets persist.

**9. The pull is the unit of decision in 5-man content.** All four potion alerts in the log
were ignored; the likely reason is that the alert answered "is this potion efficient?" when
the question was "can I pull again?". Hence `Engine/PullBudget.lua`.

**10. HP5 removed rather than redefined.** Redefining it to the author's intent (sustained
while chain-casting, i.e. inside the 5SR) reduces to `5 x castingRegen x HPM`, which orders
every rank exactly like HPM. On review the author agreed it carried no insight of its own.
Gone in v0.6.0: column, closure, tooltip lines, `effHp5`. Recorded so nobody reintroduces it
as a "new" metric.

**11. The confidence gate's numbers, corrected.** Inside `oom` mode (the only place it acts)
the hard pull sat at median 0.41 and the quiet pulls at median 0.73; a 0.7 gate keeps all six
hard-pull samples and drops 55% of quiet digits — not the 80% first claimed, which had mixed
in `hold` samples that are above 1 by construction. Still the right default; still to be
re-derived on raid logs.

**12. Two deviations from `docs/DESIGN-v0.6.md` made while implementing.** (a) The drift
threshold is a constant (3%, `Engine/Calibration.lua ALERT_REL`) with an on/off checkbox,
not a user-facing threshold setting — the Idol case pins 3% and a slider would invite
turning a real finding into noise. (b) Hybrid (Regrowth) wasted-mana attribution splits the
cost half to the direct hit and half across the seven ticks; the design table only covered
single-kind spells. Both are stated in the code.

**13. The Waste tab works for any class.** Only the rank tabs are druid-only; overheal by
target, role and class needs no spell table.

**14. Relics: checked, corrected, and made self-verifying (v0.6.7).** The author asked
why calibration should "find" an idol the slot check already reads. It should not — a
*known* idol is applied exactly by `SD:Relic()`; calibration's job is the value the table
holds when that value was never measured. So `verify` became data instead of a comment, and
the drift alert now names the equipped relic and solves for it
(`implied = table + (observed − predicted) × ticks / talentMult`), turning "3.2% high" into
the exact table edit. Looking the IDs up rather than trusting memory found **two wrong
entries**: Idol of Health (22399) is a −0.15s Healing Touch cast relic, not +100 healing;
Idol of the Emerald Queen (27886) is +88 to Lifebloom's *total* periodic healing
(~12.6/tick), not +47/tick. My remembered ID for Idol of Budding Life (33076) was a PvP
idol; it is 33508. Added the TBC set: Budding Life (−36 Rejuv mana), Crescent Goddess
(30051, −65 Regrowth mana) as cost-only relics the live cost already covers, and Harold's
Broach at +87 (one source says 86 — calibration will settle it). Everything but the measured
Idol of Rejuvenation is flagged `verify`.

### Priority, set by the author

C1 self-calibration -> A waste report -> D1 logging -> B1 pull budget -> D2 Cell
(investigate only). **F6 logging ships before F4 waste** because the waste report's role
dimension rests on `UnitGroupRolesAssigned` returning real values in the author's groups,
and the roster log line is what proves it.
