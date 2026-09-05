# ManaDemon v0.6 — design and architecture

Detailed design for the v0.6 line: the fixes and features chosen after analysing
`.logs/dungeon-BF-1.txt` (Blood Furnace, 28.8 min, 5600 lines, 30 pulls, 355 casts, on a
v0.5.x build).

Priority set by the author: **C1 self-calibration -> A waste report -> D1 logging -> B1
pull budget -> D2 Cell (investigate)**, with the P0 fixes from the log first because they
are cheap and one is a visible bug.

Status of every statement: **measured** = read out of the log; **derived** = follows from
code in the repo; **assumed** = a modelling choice that needs in-game data (listed in §12).

---

## 0. What the log established — and what it does not

The run was a **level 61 dungeon on a level 64 druid**. Heroics and raids have longer
encounters and different damage patterns. Nothing tuned from this log is settled; it is a
*sample of how the author heals*, not a specification. Two consequences run through the
whole document:

1. **No constant derived from this log is hard-coded.** Anything tuned from it becomes a
   setting with its provenance recorded, to be re-derived against heroic and raid data.
2. **This is the argument for C1.** Stats, content and spec all change. A model that
   verifies itself against what actually happened is worth more than a model tuned once.

### Measured

| | |
|---|---|
| Overheal | **38.0%** of gross healing; **561 events were 100% wasted** (~19k of 79.7k mana, ~24%) |
| Per-spell overheal | Regrowth direct 10.8% · Swiftmend 25.7% · Lifebloom tick 38.2% · Rejuv tick 45.0% · Lifebloom bloom 49.8% · Regrowth HoT tick 51.2% |
| Per-target overheal | tank 40.6% · the author (self) 46.4% · two DPS 21–22% · a third 42.9% · a mage's Water Elemental **100%** |
| Cast mix | Lifebloom **69%** of casts / 54% of mana · Rejuv 12% / 16% · Regrowth 6% / 11.5% · Healing Touch **1 cast in 29 min** |
| Utility spend | ~7% of mana (Mark of the Wild, Thorns, dispels, form shifts) — invisible to every current view |
| Fights | 17–45s, one 2:47; mana floor 36%, reached once |
| Combat-log convention | **GROSS** — `amount` includes overheal (561 events `amount == overheal`, 0 events `amount == 0`) |
| Regen | 346 mp5 out of the 5SR, 142 mp5 casting; pool 7009 |

### The clock, on the one hard pull

154 mana/s, −508 net mp5, 6.2k in 40s, ending at the run's floor:

```
+2154  hold  OOM >10m    rest 5s    97%   net  -5.4/s
+2164  hold  OOM >5:30   rest 18s   84%   net  +8.5/s
+2166  oom   OOM ~5:00   rest 28s   75%   net +19.3/s   <- warm-up, marked ~
+2171  oom   OOM 3:00    rest 35s   70%   net +25.8/s
+2174  ALERT Major Mana Potion now - down 2400, none wasted
+2176  oom   OOM 2:00 v  rest 35s   66%   net +31.1/s
+2181  oom   OOM 2:00    rest 45s   56%   net +38.8/s
+2186  oom   OOM 1:00    inn 3:30   49%   net +43.3/s   <- v0.5.2 segment, first real test
+2191  oom   OOM 2:00    rest 55s   50%   net +35.3/s
+2194  fight ends at 39%
```

Monotone descent, no flapping. **The projection works when there is pressure.** It is only
noisy when there is not — and the two separate cleanly on the projection's own relative
error:

| | sigma / net |
|---|---|
| the hard pull, `oom` mode, after warm-up | median **0.41**, range 0.34–0.66 |
| every other `oom`-mode sample | median **0.73**, range 0.17–0.99 |
| `hold`-mode samples | > 1 by definition (they already show a bound) |

Everywhere else: 181 mode transitions in 28 minutes, shown value changed on 79% of
consecutive samples, `rest` was the stable and useful number (median 13s).

---

## 1. Architecture

### 1.1 Current shape and what changes

```
COMBAT_LOG_EVENT_UNFILTERED (one handler, UI/Summary.lua, since v0.5.0)
  |
  |-- fight totals                     (today)
  |-- Overheal:Record(id, amount, oh)  (today: family + spell)
  `-- "heal" debug line                (today)

v0.6:
  |-- Targets:Lookup(destGUID) ---------------> class, role, roleSource
  |-- Overheal:Record(id, KIND, amount, oh, destGUID)
  |       `-- buckets: family, spell, spell:kind, role, class, target
  |-- Calibration:Observe(id, kind, amount, crit)
  |       `-- RankMath:EventPrediction(id) -> ratio observed / predicted
  |-- fight totals + per-spell spend
  `-- "heal" debug line
```

### 1.2 New and changed files

| File | State | Role |
|---|---|---|
| `Engine/Targets.lua` | **new** | Group roster: GUID -> name, class, role, roleSource. The single source of "who was that heal on". |
| `Engine/Calibration.lua` | **new** | Model vs reality per spell / event kind. Reports drift; **never feeds back** into the model. |
| `Engine/PullBudget.lua` | **new** | "How many more pulls before I drink", from persisted fight history. |
| `UI/Dashboard_Waste.lua` | **new** | The Waste view: where mana went, where healing was wasted. |
| `Engine/Overheal.lua` | **change** | Event-kind, role, class and per-target buckets; wasted-mana accounting. |
| `Engine/RankMath.lua` | **change** | HP5 removed; `EventPrediction()`; Lifebloom rolling rows use tick-scope overheal. |
| `Engine/TTO.lua` | **change** | The `OOM 0s` fix; confidence gate on the point estimate. |
| `UI/Summary.lua` | **change** | Per-spell spend per fight; roster line at the pull; passes kind + destGUID. |
| `UI/Dashboard.lua` | **change** | `currentFamily` -> `currentView`; Waste tab; default view from usage. |
| `UI/DebugConsole.lua` | **change** | Copy prepends `MD:Snapshot()`; shown-string-change logging. |
| `UI/Advisor.lua` | **change** | Names the same cooldown the clock names; says why a cheaper one fires first. |
| `Engine/SpendTracker.lua` | **change** | `cast` debug line: Naturalist only on Healing Touch; adds the Nature's Grace rank. |
| `Verify.lua` | **change** | `/md calibrate`, `/md export`. |

### 1.3 Load order (`ManaDemon.toc`)

```
Core.lua
Data\SpellData.lua
Engine\RegenModel.lua
Engine\SpendTracker.lua
Engine\Targets.lua          <- new: Core only
Engine\Overheal.lua         <- now reads Targets
Engine\ManaCooldowns.lua
Engine\TTO.lua
Engine\RankMath.lua
Engine\Calibration.lua      <- new: reads RankMath and Overheal, so after both
Engine\PullBudget.lua       <- new: reads MD.fightHistory at call time
UI\Style.lua
UI\Tooltip.lua
UI\Widget.lua
UI\Dashboard_Rows.lua
UI\Dashboard_Simulate.lua
UI\Dashboard_Waste.lua      <- new: exports MD.DashboardParts.CreateWaste
UI\Dashboard.lua
UI\OptionsFrame.lua ... Verify.lua   (unchanged order)
```

### 1.4 The one architectural rule for C1

**Calibration reads the model; the model never reads calibration.**

It would be easy to have `RankMath` multiply its output by the observed drift ratio and
call the numbers "corrected". That would be wrong: the dashboard would then always agree
with reality while `Data/SpellData.lua` stayed wrong, and every real finding — a missing
relic, a wrong coefficient, an unmodelled talent — would be silently absorbed instead of
surfaced. Drift is a **report to a human**, who fixes the data. This is how the Idol of
Rejuvenation went from "Rejuv runs 3% high" to a table entry; C1 automates the noticing,
not the fixing.

---

## 2. F1 — HP5 removed

The author's intended definition was "healing per 5s sustainable on regenerated mana while
still casting", i.e. permanently inside the five-second rule. Worked through, that is

```
T   = max(cost / castingRegen, castTime)
HP5 = 5 * heal / T   =   5 * castingRegen * HPM     (whenever the spell costs more than
                                                     regen delivers during its own cast)
```

so **HP5 orders every rank exactly like HPM** — a unit conversion, not a new axis. The
author's call, on review: *it does not provide new insights; remove it.* The column, the
`SustainedInterval` closure, the tooltip and glossary lines and the `effHp5` field are gone
in v0.6.0; the Cast / To OOM / note columns shift left and the note column widens
(`UI/Dashboard_Rows.lua`). The regen figure the hint line used to attach to HP5 now sits
with To OOM, which is the column that actually consumes it.

---

## 3. F2 — The clock: stop fabricating zero, stop fabricating precision

### 3a. The `OOM 0s vv` false alarm

**Bug, measured:** red `OOM 0s vv` at 72–97% mana, 9+ times in one run, always on an
`oom -> hold` transition.

```
09:00:00 [tto] mode oom -> hold (shown: OOM 0s vv  inn >10m)  | mana 5518/7009
```

**Mechanism, derived:** `hold` sets `s.bound`, not `s.tto`. The mode latch deliberately
holds `disp.mode == "oom"` for two ticks when news *improves*, so during that window the
display layer reads `state.tto`, gets `nil`, and `Engine/TTO.lua`'s `v = v or 0` turns "no
value" into "zero seconds" — into the `< 20s` critical band, red, on every surface.
v0.5.2's cooldown segment then appended `inn >10m` because `v <= 90` is true of 0.

**Fix, two places:**
* The tick keeps the previous shown value when the latched mode has no value in the
  current state (`disp.stale = true`) instead of nil-ing it.
* `GetDisplayString` renders grey `OOM --` when there is genuinely no value, matching the
  existing `FULL --` idiom. **`v or 0` is deleted.**

### 3b. Confidence gate on the point estimate

```
s.rel       = sigma / net                 -- relative error of the projection (net > 0)
s.confident = s.rel <= db.oomConfidence   -- default 0.7
```

| state | today | v0.6 |
|---|---|---|
| oom, confident | `OOM 2:00 v  rest 35s` | unchanged |
| oom, **not** confident | `OOM 8:00 =  rest 22s` (the 8:00 is ±100%) | `OOM >5m =  rest 22s` |
| oom, not confident, cooldown ready & worth it | `OOM 1:00 =  inn 3:30` | unchanged — the `inn` gate already requires `v <= 90`, which implies confidence in practice |
| hold | `OOM >10m =  rest 8s` | unchanged |
| latched oom, state moved on, no value | **`OOM 0s vv`** | `OOM --  rest 22s` |

When not confident, `rest` shows **unconditionally** rather than only when it differs from
the primary by 25% — the primary is a bound now, not a number to compare against.

`db.oomConfidence` default **0.7** is *derived from a single level-61 dungeon* and is
recorded as provenance, not truth. Inside `oom` mode — the only place the gate acts — 0.7
keeps **all 6** hard-pull samples and drops **29 of 53 (55%)** quiet ones; it sits exactly at
the quiet median. (An earlier draft claimed 80% removed; that figure had mixed in `hold`
samples, which are above 1 by construction and never showed digits anyway.) The digits come
back only after two consecutive confident ticks, so a value hovering at the threshold does
not flip the display's shape. **Re-derive from the first heroic and raid logs** — Options >
Model exposes it as a percentage slider with that caveat in its tooltip.

Deliberately *not* a change to `K_SIGMA` or `CV_STABLE` (`docs/PLAN.md` §1a stays open):
the mode logic was right; only the decision to print digits was wrong.

---

## 4. F3 — C1: continuous self-calibration

### 4.1 What is compared, and why per event

The combat log reports the amount the server actually computed. `RankMath` predicts it.
Compare per **event**, split three ways so nothing is averaged that should not be:

| kind | combat-log source | predicted by |
|---|---|---|
| `direct` | `SPELL_HEAL` from a direct or hybrid spell | direct portion, **crit stripped** |
| `tick` | `SPELL_PERIODIC_HEAL` | HoT total / tick count |
| `bloom` | `SPELL_HEAL` whose spellID is Lifebloom | bloom portion |

Crits are separated rather than averaged: `RankMath`'s direct heal carries an expected
`(1 + 0.5 x crit)` factor, which cannot be compared to an individual event. Non-crit events
go against the non-crit prediction; the **crit rate** itself becomes an independent second
check against `GetSpellCritChance(4)`.

### 4.2 `RankMath:EventPrediction(spellID)`

Sits on the v0.5.0 Context/RowFor split — every term already exists in `row.calc`:

```lua
-- returns { direct = <non-crit direct>, tick = <per tick>, bloom = <bloom>,
--           ticks = <n>, critMult = <1 + 0.5 * crit>, stacks = <Lifebloom stack count or nil> }
function RankMath:EventPrediction(spellID)
```

**Lifebloom ticks scale with stack count** (the log shows 99 and 198 on the same target —
x1 and x2). The stack count is not in the combat log, so Lifebloom ticks are calibrated
per-target using the last observed tick as a stack estimate, or skipped when ambiguous.
This is the one messy case, and it is called out rather than smoothed over.

### 4.3 `Engine/Calibration.lua`

```lua
CAL.stats["<spellID>:<kind>"] = { n = 44, obs = 19580, pred = 18964, obsSq = ... }
CAL.crit["<spellID>"]         = { events = 20, crits = 13 }

function CAL:Observe(spellID, kind, amount, crit)   -- crits counted, not compared
function CAL:Ratio(spellID, kind)                   -- -> ratio, n, sigma
function CAL:Report()                               -- lines: /md calibrate, /md profile
```

**No decay.** The statistic is a *ratio*, so it is gear-invariant: when +healing rises,
observed and predicted rise together. Anything that accumulates is therefore a model error —
exactly what should accumulate. Reset on `TALENTS_CHANGED` (the model itself changed) and
by hand.

**Known noise, documented not hidden:**
* A HoT tick lands up to 21s after the cast; the prediction is made at *event* time. Tree
  of Life's aura is dynamic (measured), so this is usually right, but events within 2s of a
  `FORM_CHANGED` are **excluded**.
* An external +healing buff the client does not report shows as uniform drift across every
  spell — which is itself the useful signal.

### 4.4 Worked example: how this would have found the relic

```
Rejuvenation R12, tick, +450 healing, Tree form, Gift of Nature 5, Imp Rejuv 3:
  predicted per tick   (932 + 450 x 0.8 x 1.20) x 1.10 x 1.15 / 4   = 431
  observed mean, 44 ticks                                            = 445
  ratio 1.032   n = 44   -> drift alert (threshold 5%? no -- see below)
```

At 3.2% this sits under the 5% alert line — so the alert threshold is **3%**, with n >= 30,
and it fires once per session per spell:

> *Rejuvenation R12 is healing 3.2% above the model over 44 ticks. Check SpellData, the
> relic table, or an unmodelled buff — `/md calibrate` for the table.*

### 4.5 Output

```
/md calibrate
  spell                kind    n     observed   predicted   ratio   verdict
  Lifebloom R1         tick    1624       97.3        97.0   1.003   ok
  Lifebloom R1         bloom     18      993.9       991.2   1.003   ok
  Rejuvenation R12     tick     151      481.2       466.0   1.033   HIGH  <- check relic / data
  Regrowth R9          direct    20     1921.4      1904.7   1.009   ok    (7 crits of 20 = 35%; API says 24%)
  Regrowth R9          tick     133      242.5       243.0   0.998   ok
  Swiftmend            direct    12     1925.8      1918.3   1.004   ok
  Healing Touch R11    direct     1        -           -       -     too few
```

Plus a `calib` debug category and a section in `/md profile`.

---

## 5. F4 — A: where the mana went, where the healing was wasted

### 5.1 `Engine/Targets.lua` — who was that heal on

Role is **read, not inferred.** `RaidFrames/UnitButton_Vanilla.lua` — the file
`Cell_TBC.toc` actually loads — calls `UnitGroupRolesAssigned(unit)` unguarded, and
`roleIcon` ships **enabled by default** in `Layout_Defaults_TBC_Vanilla.lua`. Cell would not
do that if the API returned nothing on this client. Source order:

| # | source | covers | roleSource |
|---|---|---|---|
| 1 | `UnitGroupRolesAssigned(unit)` | the player's own selection; solves ferals outright | `assigned` |
| 2 | `GetPartyAssignment("MAINTANK" / "MAINASSIST", unit)` | raid-side; Cell ships a "Party Assignment Icon" for exactly this | `partyassign` |
| 3 | class-implied | Mage, Warlock, Rogue, Hunter -> DAMAGER | `class` |
| 4 | — | everything else | `unknown` |

```lua
Targets.byGUID[guid] = { name = "Dëstroyka", class = "WARRIOR", role = "TANK", roleSource = "assigned" }
function Targets:Lookup(guid)      -- also resolves the player and pets (pet -> owner's role, class "PET")
```

Rebuilt on `GROUP_ROSTER_UPDATE` / `PLAYER_ENTERING_WORLD`. **`roleSource` travels into
every report:** a guessed role is never presented like a read one.

`UnitGroupRolesAssigned` returns what someone *selected*, so a guild premade may be all
`NONE`. How often that happens in the author's groups is unknown — `Targets` logs the roster
at each pull (F6), and one night of logs settles whether the fallback is an edge case or the
common path. **This is why F6 ships before this feature.**

Talent-based inference was rejected outright: it cannot separate a feral tank from a feral
cat, and the author raised exactly that case.

### 5.2 `Engine/Overheal.lua` — new dimensions

Existing keys keep working; saved data stays valid.

| key | dimension | persisted | needed by |
|---|---|---|---|
| `f:<family>`, `s:<id>` | as today | yes | effective mode (v0.5.3) |
| `k:<id>:<kind>` | tick / direct / bloom | yes | **calibration (F3) and Lifebloom economics (F5)** |
| `r:<role>` | TANK / HEALER / DAMAGER / UNKNOWN | yes | Waste by role |
| `c:<class>` | target class | yes | Waste by class |
| `u:<guid>` | one target | **session only**, pruned on roster change | Waste by target |

**Wasted-mana accounting.** An event with `gross > 0` and `effective == 0` is fully wasted;
its share of the cast's mana is attributed:

```
single-target HoT tick :  cost / ticks                 Lifebloom 176 / 7 = 25 mana per wasted tick
direct heal            :  cost
AoE tick (Tranquility) :  cost / (ticks x targets)      780 / (4 x 5) = 39 per wasted tick-on-a-target
Lifebloom bloom        :  0  (the cast's mana is already on its ticks)
```

Measured in the log: 431 wasted Lifebloom ticks ≈ 10.8k, 64 Regrowth ticks ≈ 4.2k, 50
Rejuvenation ticks ≈ 3.7k — **~19k of 79.7k mana (24%) went into targets at full health.**

**Why role and class, in the author's words:** overhealing a tank is usually fine, a DPS is
not, yourself is a judgement call; some classes self-heal, while a warlock's Life Tap makes a
pre-emptive HoT *correct*. That last one is measurable rather than assumed — Life Tap is a
visible combat-log event, so "targets that reliably make room" becomes a statistic. Deferred
to **v0.6.4**.

### 5.3 `UI/Dashboard_Waste.lua` — the view

The dashboard's tab row switches spell families today. It becomes a **view** switch, with
`Waste` after the four families; reuses the frame, the tab group and the row pool.
`currentFamily` becomes `currentView`.

```
+-[ Healing Touch ][ Lifebloom ][ Rejuvenation ][ Regrowth ][ Waste ]--------[ Settings ]-+
| by:  [ Spell ][ Role ][ Class ][ Target ]                  scope: [ session ][ 20 fights ] |
|                                                                                          |
| Spell               Casts    Mana   Healing  Overheal   Wasted mana   Fully wasted        |
| Lifebloom (ticks)     245   43296    259154     38.2%        10837     431 ticks           |
| Lifebloom (bloom)       -       -     17890     49.8%            -       7 blooms          |
| Rejuvenation           44   13024     72654     45.0%         3700      50 ticks           |
| Regrowth (direct)      20    9200     38427     10.8%            0       0 casts           |
| Regrowth (HoT)          -       -     32258     51.2%         4206      64 ticks           |
| Swiftmend              12    2604     23110     25.7%            0       0                 |
| Tranquility             1     780     20372     50.6%          351       9 tick-targets    |
|                                                                                          |
| 79.7k spent this session, ~19.1k (24%) into targets at full health.                       |
+------------------------------------------------------------------------------------------+
```

`by: Role` and `by: Class` drop Casts and Mana (mana belongs to the spell, not the target):

```
| Role                Healing  Overheal   Wasted mana   Targets                             |
| TANK                 318355     40.6%        11.2k    Dëstroyka                            |
| DAMAGER               85394     22.5%         3.1k    Alkandari, Abufaisall  (+1 guessed) |
| HEALER (you)          44825     46.4%         4.4k    Penek                               |
| UNKNOWN               20444     44.7%         0.4k    Trécoda, Water Elemental             |
```

```
| Target              Class      Role          Healing  Overheal   Wasted mana              |
| Dëstroyka           Warrior    TANK           318355     40.6%        11.2k                |
| Alkandari           Mage       DAMAGER         65629     22.0%         2.3k                |
| Penek               Druid      HEALER          44825     46.4%         4.4k                |
| Trécoda             Paladin    DAMAGER?        19765     42.9%         0.3k   role guessed |
| Abufaisall          Warlock    DAMAGER         17970     21.0%         0.8k                |
| Water Elemental     pet        (Alkandari)       679    100.0%         0.1k                |
```

The `?` and *role guessed* markers are `roleSource ~= "assigned"` made visible.

**Also here:** the per-fight spend breakdown, so the ~7% on Mark of the Wild, Thorns,
dispels and form shifts stops being invisible. Fight summary line gains a `top:` clause:

```
0:40 || net -508 mp5 || spent 6.2k (LB 52%, RG 22%, RJ 14%, other 12%) || overheal 21% || ...
```

---

## 6. F5 — A3: Lifebloom economics

69% of the author's casts, and the effective-accounting answer is counter-intuitive: the
**bloom overheals 49.8% while ticks overheal 38.2%**, so rolling a stack and never letting
it bloom may beat letting it bloom — the opposite of the usual advice.

The rolling-stack rows already exist in `RankMath` but are excluded from comparison as
"informational". With `k:<id>:<kind>` from §5.2 they become answerable:

```
single application  : 7 ticks x (1 - 0.382) + bloom x (1 - 0.498)     effective per 176 mana
rolling x1 refresh  : 6 ticks x (1 - 0.382)                           effective per 176 mana
rolling x3 refresh  : 6 ticks x 3 x (1 - 0.382)                       effective per 176 mana
```

Worked, with the log's tick 99 and bloom 994 at x1:

| mode | raw heal / cast | effective / cast | eff HPM |
|---|---|---|---|
| single (7 ticks + bloom) | 1687 | 428 + 499 = **927** | 5.27 |
| rolling x1 (6 ticks, no bloom) | 594 | **367** | 2.09 |
| rolling x3 (18 ticks) | 1782 | **1101** | 6.26 |

So at the author's measured overheal, a maintained 3-stack beats a single cast on effective
HPM, and a 1-stack roll is a poor use of mana. The callout line states it for **this
player's measured overheal**; the rows stay out of the Pareto filter (a different activity
from a single cast).

---

## 7. F6 — D1: logs that answer next time's questions

Analysing `dungeon-BF-1.txt` needed regex over prose, and three questions were
unanswerable: was Nature's Grace even talented, was the potion actually drunk, how often did
the *shown* string really change.

| # | change | line format |
|---|---|---|
| 1 | **Copy prepends `MD:Snapshot()`** — every pasted log becomes self-describing | the existing snapshot block, then `--- log ---` |
| 2 | roster at each pull | `[combat] roster: Dëstroyka WARRIOR TANK(assigned), Alkandari MAGE DAMAGER(class), Trécoda PALADIN UNKNOWN, ...` |
| 3 | shown string on **change**, not only every 5s | `[tto] shown: 'OOM 2:00 v  rest 35s' (was 'OOM 3:00 =  rest 35s', 4.9s)` |
| 4 | cooldown consumption | `[spend] cooldown used: Major Mana Potion (+2250 -> 5891/7009)` |
| 5 | `cast` line: Naturalist only on Healing Touch, Nature's Grace rank shown | `[cast] Regrowth R9: live 2.00s - model 2.00s (NG rank 0: no reduction expected)` |
| 6 | `/md export` — TSV, no quoting problems | see below |

```
/md export
# manademon 0.6.x  Penek-Realm  DRUID 64  2026-09-05 09:21
# fights
t	zone	dur	spent	netMp5	overheal	oomAt
1757062360	Hellfire Citadel	40.3	6198	-508	0.216	
...
# overheal
key	n	healed	overhealed
f:Lifebloom	1642	176106	107856
k:33763:tick	1624	160216	98938
r:TANK	...
# calibration
spell	kind	n	obs	pred
...
```

The `cast` Naturalist bug is real: the debug line subtracts Naturalist from every spell,
but the talent only affects Healing Touch. Harmless today at rank 0, wrong the moment the
author respecs.

---

## 8. F7 — B1: pull budget

`Engine/PullBudget.lua`, from the persisted `MD.cdb.fights` (zone-preferred, as the pull
seed already is):

```
perPull  = median(spent) over the last 5 fights in this zone (>= 2), else overall
afford   = floor(mana / perPull)
afterDrink = floor(manaMax / perPull)
```

Out of combat, replacing the bare mana readout in the widget tooltip and — when below the
drink threshold — the drink reminder's text:

```
62% -- recent pulls here cost ~2.3k -- 2 more, or 4 after a drink.
```

**Rationale, measured:** all four potion alerts in the log went unanswered. The likely reason
is that the alert answered "is this potion efficient?" when the question being asked was
"can I pull again?". Fights are 17–45s with drinking between; **the pull is the unit of
decision** in 5-man content. This does not replace the OOM clock — it sits beside it, for
the 90% of time the clock (rightly) has nothing to say.

---

## 9. F8 — small fixes (v0.6.0)

* **Default dashboard view from actual usage.** It opens on Healing Touch, cast once in 29
  minutes. Pick the most-cast family from the spend tracker's session counts; fall back to
  the max-rank family with the most casts in persisted history; then Healing Touch.
* **Advisor and clock name the same cooldown.** On the hard pull the clock advertised
  `inn 3:30` while the advisor alerted the potion. Both were defensible — the clock shows the
  richest *ready* source, the advisor fires when nothing would be *wasted* — but the messages
  contradict. The advisor says why:

  > *Major Mana Potion now — you're down 2400 (worth ~2250, none wasted). Innervate is
  > ready too but worth ~5400: hold it until you're down that far.*

---

## 10. Settings and data

New `MD.db`:

| key | default | where | provenance |
|---|---|---|---|
| `oomConfidence` | `0.7` | Options > Model, slider 0.3–1.5 | dungeon-BF-1, **re-derive** from heroic/raid |
| `calibAlert` | `0.03` | Options > Model | the Idol case was 3.2% |
| `wasteScope` | `"session"` | Waste view toggle | — |
| `debug.categories.calib` | `true` | Debug Console | — |

New `MD.cdb`: `calibration` (map, see §4.3). `overheal` gains the key families in §5.2;
`u:<guid>` buckets are session-only so SavedVariables cannot grow with every stranger
healed in a pug.

Options > Model grows by a slider and a checkbox; General tab height 350 -> ~400.

---

## 11. Delivery order

| version | contents | visible change |
|---|---|---|
| **v0.6.0** | F1 HP5 removed, F2 both halves, F8 | no red `OOM 0s`; quiet fights show `OOM >2:00` instead of invented digits; HP5 column gone; dashboard opens on the most-cast spell |
| **v0.6.1** | F6 logging + `Engine/Targets.lua` | richer logs; roster at each pull; `/md export` |
| **v0.6.2** | F3 `Engine/Calibration.lua`, `/md calibrate`, drift alerts | the model starts checking itself |
| **v0.6.3** | F4 Overheal dimensions, wasted mana, `UI/Dashboard_Waste.lua`, spend breakdown | the Waste view |
| **v0.6.4** | F5 Lifebloom economics; Life Tap detection | rolling-vs-bloom answered |
| **v0.6.5** | F7 pull budget | the between-pulls readout |
| **v0.6.6** | docs, TESTING for the new surface | — |

**F6 before F4 is deliberate:** the waste report's role dimension rests on
`UnitGroupRolesAssigned` returning real values in the author's groups, and the roster line
is what proves it. **F3 before F4** is the author's priority.

---

## 12. Open questions, and what settles each

| question | settled by |
|---|---|
| Does `UnitGroupRolesAssigned` return non-`NONE` in the author's groups, how often? | F6 roster line, one night |
| `db.oomConfidence` = 0.7 | re-derive from the first heroic and raid logs |
| Lifebloom stack count for per-tick calibration | per-target last-tick estimate; ambiguous ticks skipped — check the skip rate in `/md calibrate` |
| `K_SIGMA` / `CV_STABLE` | still `docs/PLAN.md` §1a — **untouched by v0.6** |
| Nature's Grace 0.5s; Naturalist | `cast` category, once Healing Touch is cast in caster form |
| Innervate = spirit share only | one Innervate with `regen` on — never cast in this log |
| Haste | **not modelled anywhere.** The `cast` category exposes it if live undercuts the model |

---

## 13. Calls worth arguing about before implementing

1. **Calibration per event, not per cast.** Per cast would match `RankMath`'s row directly
   but needs cast->tick attribution across overlapping HoTs on several targets. Per event is
   simpler and honest, at the cost of the Lifebloom stack wrinkle (§4.2).
2. **Calibration never decays.** Gear-invariant because it is a ratio — but a *model* change
   that is not a talent change (a new relic the table does not know) would accumulate as
   permanent drift. That is the intended behaviour; the alert is the fix.
3. **Role falls back to class, then unknown — not to combat-log inference.** Inference
   (who eats boss melee) would fill the gaps but adds a mechanism that can be wrong quietly.
   Decision: start without it, let F6 measure how often `NONE` actually happens.
4. **F6 before F4** inverts the author's stated order by one step, for the reason in §11.
5. ~~HP5 duplicates HPM's ordering~~ — **decided: removed** (v0.6.0). The freed column is
   not reassigned yet; *effective* HPM as a permanent column is the candidate.
6. **`oomConfidence` as a user-facing slider** vs an internal constant. A slider invites
   fiddling; a constant invites being forgotten. Slider, with the provenance in its tooltip.
7. **Per-target overheal session-only.** Persisting it would enable "Dëstroyka always eats
   40%" across nights, at the cost of SavedVariables growing with every pug.

---

## 14. D2 — Cell integration: investigation brief

Not code. The author maintains a Cell fork and has the upstream maintainer's ear; the
questions to ask before any work:

1. Is Cell's **indicator API** stable enough for a third-party addon to register a custom
   indicator, or is `Indicators/Custom.lua` the only supported route?
2. Could **`LibGroupInfo` be made loadable on TBC**? It is absent from `Cell_TBC.toc`. If it
   worked there, *spec* (not just role) would be available, and §5.1's fallback chain
   mostly disappears.
3. Would an **overheal-risk indicator** — "this target has taken 90% overheal from your HoTs
   recently" — belong in Cell itself rather than as a ManaDemon overlay?

The natural first deliverable is read-only: ManaDemon publishes per-target overheal on
`MD.Overheal:Target(guid)`, Cell optionally displays it. No shared state, no load-order
coupling.
