# ManaDemon v0.6 — design and architecture

Detailed design for the v0.6 line: the fixes and features chosen after analysing
`dungeon-BF-1.txt` (Blood Furnace, 28.8 min, 5600 lines, 30 pulls, 355 casts).

Priority agreed with the author: **C1 self-calibration -> A waste report -> D1 logging
-> B1 pull budget -> D2 Cell**, with the P0 fixes from the log going first because they
are cheap and one of them is a visible bug.

Status of every statement: **measured** = read out of the log; **derived** = follows
from code in the repo; **assumed** = a modelling choice that needs in-game data.

---

## 0. What the log established, and what it does NOT

The run was a **level 61 dungeon on a level 64 druid**. Heroics and raids have longer
encounters and different damage patterns. Nothing tuned from this log is settled — it is
a *sample of how the author heals*, not a specification. Two consequences run through
this whole document:

1. **No constant derived from this log is hard-coded.** Anything tuned from it becomes a
   setting with its provenance recorded, to be revisited against heroic and raid data.
2. **This is the argument for C1.** Stats, content and spec all change; a model that
   verifies itself against what actually happened is worth more than a model tuned once.

**Measured:**

| | |
|---|---|
| Overheal | **38.0%** of gross healing; 561 events were 100% wasted |
| Per-spell overheal | Regrowth direct 10.8% · Swiftmend 25.7% · Lifebloom tick 38.2% · Rejuv tick 45.0% · Lifebloom bloom 49.8% · Regrowth HoT tick 51.2% |
| Cast mix | Lifebloom **69%** of casts / 54% of mana · Rejuv 12% / 16% · Regrowth 6% / 11.5% · Healing Touch 1 cast in 29 min |
| Utility spend | ~7% of mana (Mark of the Wild, Thorns, dispels, form shifts) — invisible to every current view |
| Fight lengths | 17–45s, one 2:47 |
| Mana floor | 36%, reached once |
| Combat log convention | **GROSS** — `amount` includes overheal (561 events with `amount == overheal`, 0 with `amount == 0`) |

**The clock, on the one hard pull** (154 mana/s, −508 net mp5, 6.2k in 40s): tracked
`5:00 -> 3:00 -> 2:00 -> 1:00` monotonically as the fight escalated, showed `inn 3:30` at
49% mana / 80s to OOM, no flapping. **The projection works when there is pressure.** It is
only noisy when there is not, and the two separate cleanly on the projection's own
relative error:

| | sigma / net |
|---|---|
| The hard pull | median **0.43** (0.34–0.66 after warm-up) |
| Every other in-combat sample | median **1.01** |

---

## 1. Architecture

### 1.1 New and changed files

| File | State | Role |
|---|---|---|
| `Engine/Targets.lua` | **new** | Group roster: name/GUID -> class, role, roleSource. The single source of "who was that heal on". |
| `Engine/Calibration.lua` | **new** | Model vs reality per spell/rank/event-kind. Reports drift; never feeds back into the model. |
| `Engine/PullBudget.lua` | **new** | "How many more pulls before I drink", from persisted fight history. |
| `UI/Dashboard_Waste.lua` | **new** | The waste view: where mana went and where healing was wasted. |
| `Engine/Overheal.lua` | **change** | Gains event-kind (tick / direct / bloom), role, class and per-target dimensions; wasted-mana accounting. |
| `Engine/RankMath.lua` | **change** | HP5 redefined; `EventPrediction()` for calibration; Lifebloom rolling rows use the tick-scope overheal. |
| `Engine/TTO.lua` | **change** | The `OOM 0s` fix; a confidence gate on the point estimate. |
| `UI/Summary.lua` | **change** | Per-spell spend breakdown per fight; roster line at the pull. |
| `UI/Dashboard.lua` | **change** | `currentFamily` -> `currentView`; a "Waste" tab; default view from actual usage. |
| `UI/DebugConsole.lua` | **change** | Copy prepends `MD:Snapshot()`; shown-string-change logging. |
| `Verify.lua` | **change** | `/md calibrate`, `/md export`. |
| `Engine/SpendTracker.lua` | **change** | The `cast` debug line's Naturalist bug. |
| `UI/Advisor.lua` | **change** | Name the same cooldown the clock names, and say why a cheaper one fires first. |

### 1.2 Load order (`ManaDemon.toc`)

```
Core.lua
Data\SpellData.lua
Engine\RegenModel.lua
Engine\SpendTracker.lua
Engine\Targets.lua          <- new: needs Core only
Engine\Overheal.lua         <- now reads Targets
Engine\ManaCooldowns.lua
Engine\TTO.lua
Engine\RankMath.lua
Engine\Calibration.lua      <- new: reads RankMath + Overheal, AFTER both
Engine\PullBudget.lua       <- new: reads Summary's history at call time
UI\Style.lua
UI\Tooltip.lua
UI\Widget.lua
UI\Dashboard_Rows.lua
UI\Dashboard_Simulate.lua
UI\Dashboard_Waste.lua      <- new
UI\Dashboard.lua
...unchanged...
```

### 1.3 The one architectural rule for C1

**Calibration reads the model; the model never reads calibration.**

It would be easy to have `RankMath` multiply its output by the observed drift ratio and
call the numbers "corrected". That would be wrong: the dashboard would then always agree
with reality while the underlying `Data/SpellData.lua` stayed wrong, and every real
finding (a missing relic, a wrong coefficient, an unmodelled talent) would be silently
absorbed instead of surfaced. Drift is a **report to a human**, who fixes the data. This
is what turned the Idol of Rejuvenation from "Rejuv runs 3% high" into a table entry.

### 1.4 Data flow after v0.6

```
COMBAT_LOG (one handler, UI/Summary.lua)
  |-- Overheal:Record(spellID, kind, amount, overheal, destGUID)
  |     `-- Targets:Lookup(destGUID) -> class, role      -> per role/class/target buckets
  |-- Calibration:Observe(spellID, kind, amount, crit)
  |     `-- RankMath:EventPrediction(spellID)            -> ratio observed/predicted
  |-- fight totals + per-spell spend
  `-- "heal" debug category
```

---

## 2. F1 — HP5 redefined: sustained while chain-casting

**Author's definition:** healing per 5s sustainable on regenerated mana alone **while
still casting**, i.e. permanently inside the five-second rule.

Today's formula lets you drop out of the FSR between casts and collect full regen — a
different and more optimistic question. Replace it:

```
T    = max(cost / castingRegen, castTime)
HP5  = 5 * heal / T
```

In the normal case (a spell costs more than regen delivers during its own cast) this is

```
HP5 = 5 * castingRegen * HPM
```

so **HP5 rank-orders exactly like HPM**. That is not a defect — it converts HPM into
interpretable units — but the tooltip must say it, or the column implies information it
does not carry. When regen outruns the spell's cost rate the cast time binds instead and
HP5 = 5 x HPS (you are mana-positive).

At the log's 142 mp5 casting regen:

| | today | new |
|---|---|---|
| Lifebloom (176) | T 5.5s | **T 6.2s** |
| Rejuvenation (296) | T 7.2s | **T 10.4s** (−30% HP5) |

`ctx.SustainedInterval` becomes `ctx.ChainInterval`; the old formula survives as
`ctx.LapsedInterval`, shown in the row tooltip as "if you let the 5SR lapse between
casts: X" — the honest ceiling.

---

## 3. F2 — The clock: stop fabricating zero, stop fabricating precision

### 3a. The `OOM 0s vv` false alarm (bug, seen 9+ times at 72–97% mana)

`hold` sets `s.bound`, not `s.tto`. The mode latch deliberately holds `disp.mode == "oom"`
for two ticks when news improves, so during that window the display layer reads
`state.tto`, gets `nil`, and `Engine/TTO.lua`'s `v = v or 0` turns "no value" into "zero
seconds" — straight into the `< 20s` critical band, in red, on every surface. v0.5.2's
cooldown segment then appended `inn >10m` to it.

Fix, in two places:
* The tick keeps the previous shown value when the latched mode has no value in the
  current state, instead of nil-ing it (`disp.stale = true`).
* `GetDisplayString` renders `GREY "OOM --"` when there is genuinely no value, matching
  the existing `FULL --` idiom. **`v or 0` is deleted.**

### 3b. Confidence gate on the point estimate

`Compute()` gains

```
s.rel       = sigma / net           -- relative error of the projection (net > 0)
s.confident = s.rel <= db.oomConfidence
```

When not confident, the display shows the one-sided bound (`OOM >Nm`, already implemented
for `hold`) instead of a point estimate, and `rest` is shown unconditionally rather than
only when it differs from the primary by 25%.

`db.oomConfidence` default **0.7**, *derived from a single level-61 dungeon* — recorded as
provenance, not truth. At 0.7 the hard pull keeps 6 of its 7 samples (the one it drops is
the warm-up `~5:00`, already marked `~`) and 80% of the quiet chatter goes away.
**Re-derive from the first heroic and raid logs.**

This is deliberately *not* a change to `K_SIGMA` or `CV_STABLE`, which stay open (§1a of
`docs/PLAN.md`): the mode logic is fine, only the decision to print digits was wrong.

---

## 4. F3 — C1: continuous self-calibration

### 4.1 What is compared

The combat log reports the amount the server actually computed. `RankMath` predicts it.
Compare per **event**, not per cast, split three ways so nothing is averaged that should
not be:

| kind | source | predicted by |
|---|---|---|
| `direct` | `SPELL_HEAL` from a direct/hybrid spell | direct portion, **crit stripped** |
| `tick` | `SPELL_PERIODIC_HEAL` | HoT total / tick count |
| `bloom` | `SPELL_HEAL` from Lifebloom | bloom portion |

Crits are separated rather than averaged: `RankMath`'s direct heal carries an expected
`(1 + 0.5 x crit)` factor, which cannot be compared to an individual event. So non-crit
events are compared against the non-crit prediction, and the **crit rate itself** becomes
a second, independent check against `GetSpellCritChance(4)`.

### 4.2 `RankMath:EventPrediction(spellID)`

Sits on the Context/RowFor split from v0.5.0 — the terms already exist in `row.calc`:

```lua
-- { direct = <non-crit direct heal>, tick = <per-tick>, bloom = <bloom>,
--   ticks = <n>, critMult = <1 + 0.5*crit> }
function RankMath:EventPrediction(spellID)
```

### 4.3 `Engine/Calibration.lua`

```lua
CAL.stats[key] = { n, obs, pred, obsSq }   -- key = "<spellID>:<kind>"
function CAL:Observe(spellID, kind, amount, crit)   -- crit events skipped for amounts
function CAL:Ratio(spellID, kind)                   -- -> ratio, n
function CAL:Report()                               -- lines for /md calibrate and /md profile
```

**No decay.** The statistic is a *ratio*, so it is gear-invariant: when +healing rises,
both observed and predicted rise together. Drift therefore means a model error, which is
exactly what should accumulate. Reset on `TALENTS_CHANGED` (the model itself changed) and
by hand.

**Known noise sources, documented not hidden:**
* A HoT tick lands up to 21s after the cast; the prediction is made at *event* time. Tree
  of Life's aura is dynamic (measured), so this is usually right — but events within 2s of
  a `FORM_CHANGED` are **excluded**.
* External +healing buffs the client does not report would show as uniform drift across
  every spell, which is itself a useful signal.

### 4.4 Output

* `/md calibrate` — per spell/rank/kind: n, observed mean, predicted mean, ratio, verdict.
* A section in `/md profile` and a `calib` debug category.
* **A drift alert**: ratio off by >5% with n >= 30 fires once per session per spell —
  *"Rejuvenation R12 is healing 3% above the model over 44 ticks (check SpellData / relic)."*
  This is the mechanism that would have found the Idol of Rejuvenation without a
  hand-run test, and it is the project's answer to "verification needs the author".

---

## 5. F4 — A: where the mana went and where the healing was wasted

### 5.1 `Engine/Targets.lua` — who was that heal on

Role is **read, not inferred**. `UnitButton_Vanilla.lua` (the file `Cell_TBC.toc` actually
loads) calls `UnitGroupRolesAssigned(unit)` unguarded, and `roleIcon` ships enabled by
default in `Layout_Defaults_TBC_Vanilla.lua` — Cell would not do that if the API returned
nothing on this client. Source order:

1. `UnitGroupRolesAssigned(unit)` — exact, and it solves feral druids outright because it
   is the player's own assignment, not a reading of their talents.
2. `GetPartyAssignment("MAINTANK" / "MAINASSIST", unit)` — the raid-side signal; Cell
   ships a "Party Assignment Icon" next to the role icon for exactly this.
3. Class-implied, for the classes with only one option (Mage, Warlock, Rogue, Hunter).
4. `UNKNOWN`.

```lua
Targets.byGUID[guid] = { name, class, role, roleSource }  -- "assigned"|"partyassign"|"class"|"unknown"
function Targets:Lookup(guid)      -- also resolves the player and pets
```

Rebuilt on `GROUP_ROSTER_UPDATE` / `PLAYER_ENTERING_WORLD`. **`roleSource` is carried into
every report**: a role that was guessed must never be presented like one that was read.

`UnitGroupRolesAssigned` returns what someone *selected*, so a guild premade may be all
`NONE`. How often that happens is unknown — `Targets` logs the roster with class, role and
source at each pull (F6), and one night of logs settles whether the fallback is an edge
case or the common path. **This is why F6 ships before this feature.**

### 5.2 `Engine/Overheal.lua` — new dimensions

Existing keys (`f:<family>`, `s:<spellID>`) keep working; saved data stays valid.

| key | dimension | persisted |
|---|---|---|
| `f:<family>`, `s:<id>` | as today | yes |
| `k:<id>:<kind>` | tick vs direct vs bloom | yes |
| `r:<role>` | tank / healer / damager / unknown | yes |
| `c:<class>` | target class | yes |
| `u:<guid>` | individual target | **session only** (pruned at each roster change) |

Plus wasted-mana accounting: an event with `gross > 0` and `effective == 0` is fully
wasted, and its share of the cast's mana is `cost / ticks`. Per fight and per spell.

Why the author asked for role and class: overhealing a tank is usually fine, a DPS is
not, yourself is a judgement call — and some classes self-heal while a warlock's Life Tap
makes a pre-emptive HoT *correct*. That last one is measurable rather than assumed:
Life Tap is a visible combat-log event, so "targets that reliably make room" is a
statistic, not a rule of thumb. **Deferred to v0.6.4** — it needs the rest first.

### 5.3 `UI/Dashboard_Waste.lua` — the view

The dashboard's tab row currently switches spell families. It becomes a **view** switch,
with `Waste` after the four families. Reuses the frame, the tab group and the row pool.

```
+-[ Healing Touch ][ Lifebloom ][ Rejuvenation ][ Regrowth ][ Waste ]-----[ Settings ]-+
| by:  [ Spell ][ Role ][ Class ][ Target ]          this session / last 20 fights     |
|                                                                                      |
| Spell            Casts   Mana    Healing   Overheal   Wasted mana   Fully wasted     |
| Lifebloom          245  43296     277044      38.2%         16535          412 ticks |
| Rejuvenation        44  13024     105370      45.0%          5860           98 ticks |
| Regrowth (direct)   20   9200      38427      10.8%           994            3 casts |
| Regrowth (hot)       -      -      32258      51.2%          4712           61 ticks |
+--------------------------------------------------------------------------------------+
```

`by: Role` and `by: Class` swap the first column and drop Casts/Mana (a heal's mana is
attributed to the spell, not the target). `by: Target` lists individuals with their role
and a marker when the role was guessed.

**Also here:** the per-fight spend breakdown, so the ~7% spent on Mark of the Wild,
Thorns, dispels and form shifts stops being invisible.

---

## 6. F5 — A3: Lifebloom economics

69% of the author's casts, and the effective-accounting answer is counter-intuitive: the
**bloom overheals 49.8% while ticks overheal 38.2%**, so rolling a stack and never letting
it bloom may beat letting it bloom — the opposite of the usual advice.

The rolling-stack rows already exist in `RankMath` but are excluded from comparison as
"informational". With the `k:<id>:<kind>` overheal split from §5.2 they become answerable:

* single application -> tick overheal on the HoT portion, bloom overheal on the bloom
* rolling xN -> tick overheal only

and both get honest effective HPM. They stay out of the Pareto filter (they are a
different activity from a single cast) but the callout line can finally state which is
better **for this player's measured overheal**, which is the whole point.

---

## 7. F6 — D1: logs that answer next time's questions

Analysing `dungeon-BF-1.txt` needed regex over prose, and three questions were
unanswerable: was Nature's Grace even talented, was the potion actually drunk, and how
often did the *shown* string really change. So:

1. **Copy prepends `MD:Snapshot()`** — every pasted log becomes self-describing (version,
   talents, stats, relic, form, settings). Single highest-value change here.
2. **Roster line at each pull**: name, class, role, roleSource for the whole group.
3. **Log the shown string when it changes**, not only every 5s — jumpiness becomes
   measurable instead of estimated.
4. **Log cooldown consumption** (potion / Innervate actually used).
5. **`cast` line carries the Nature's Grace talent rank**, and stops subtracting
   Naturalist from every spell — it only applies to Healing Touch (harmless today at rank
   0, wrong the moment the author respecs).
6. **`/md export`** — TSV, no quoting problems: fights, per-spell overheal, calibration,
   roster. For analysis rather than reading.

---

## 8. F7 — B1: pull budget

`Engine/PullBudget.lua`, from the persisted `MD.cdb.fights` (zone-preferred, as the seed
already is): median mana cost per pull, and how many the current pool affords.

> *62% — recent pulls here cost ~2.3k — 2 more, or 4 after a drink.*

Shown in the widget tooltip and as the out-of-combat line. **Rationale:** the author
ignored all four potion alerts in the log, and the likely reason is that the alert
answered "is this potion efficient?" when the question being asked was "can I pull
again?". Fights are 17–45s with drinking between; the pull is the unit of decision.

---

## 9. F8 — small fixes (v0.6.0)

* **Default dashboard view from actual usage** — it opens on Healing Touch, cast once in
  29 minutes. Pick the most-cast family from the spend tracker instead.
* **Advisor / clock name the same cooldown.** On the hard pull the clock advertised
  `inn 3:30` while the advisor alerted the potion. Both were defensible (the clock shows
  the richest ready source, the advisor fires when nothing would be wasted), but the
  messages contradict. The advisor should say *why* the cheaper source fires first.

---

## 10. Data model

New `MD.cdb`: `calibration` (map), and `overheal` gains the key families in §5.2.
New `MD.db`: `oomConfidence` (0.7).

`u:<guid>` overheal buckets are session-only and pruned on roster change, so
SavedVariables cannot grow with every stranger healed in a pug.

---

## 11. Delivery order

| Version | Contents | Visible change |
|---|---|---|
| **v0.6.0** | F1 HP5, F2 clock (both halves), F8 small fixes | no more red `OOM 0s`; quiet fights stop showing invented digits; HP5 drops ~10–30% |
| **v0.6.1** | F6 logging + `Engine/Targets.lua` | richer logs; roster visible at each pull |
| **v0.6.2** | F3 `Engine/Calibration.lua`, `/md calibrate`, drift alerts | the model starts checking itself |
| **v0.6.3** | F4 Overheal dimensions, wasted mana, `UI/Dashboard_Waste.lua`, spend breakdown | the Waste view |
| **v0.6.4** | F5 Lifebloom economics; Life Tap detection | rolling-vs-bloom finally answered |
| **v0.6.5** | F7 pull budget | the between-pulls readout |
| **v0.6.6** | `/md export`, docs, TESTING for the new surface | — |

**F6 before F4** is deliberate: the waste report's role dimension rests on
`UnitGroupRolesAssigned` returning real values in the author's groups, and the roster log
line is what proves it.

---

## 12. Open questions and what settles each

| Question | Settled by |
|---|---|
| Does `UnitGroupRolesAssigned` return non-`NONE` in the author's groups, and how often? | F6's roster line, one night |
| `db.oomConfidence` = 0.7 | re-derive from the first heroic and raid logs |
| `K_SIGMA` / `CV_STABLE` | still `docs/PLAN.md` §1a — **untouched by v0.6** |
| Nature's Grace 0.5s; Naturalist | the `cast` category, once a Healing Touch is cast in caster form |
| Innervate's 400% = spirit share only | one Innervate with the `regen` category on — never cast in this log |
| Is haste modelled anywhere? | **No.** The `cast` category will expose it if the live cast time ever undercuts the model |

---

## 13. D2 — Cell integration: investigation brief

Not code. The author maintains a Cell fork and has the upstream maintainer's ear, so the
questions worth asking before any work:

1. Is Cell's **indicator API** stable enough for a third-party addon to register a custom
   indicator, or is `Indicators/Custom.lua` the only supported route?
2. Could **`LibGroupInfo` be made loadable on TBC**? It is absent from `Cell_TBC.toc`. If
   it worked there, spec (not just role) would be available, and §5.1's fallback chain
   mostly disappears.
3. Would an **overheal-risk indicator** — "this target has taken 90% overheal from your
   HoTs recently" — belong in Cell itself rather than as a ManaDemon overlay?

The natural first deliverable is read-only: ManaDemon publishes per-target overheal, Cell
optionally displays it. No shared state, no load-order coupling.
