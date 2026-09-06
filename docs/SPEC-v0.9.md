# ManaDemon v0.9 — runs, the measured character, and the drink: implementation spec

**This is the document to implement from.** v0.9 does three things the author asked for on
2026-09-06, in the order that makes each one honest:

1. **The engine sees the character as it is.** The regen the API does not report is
   *measured* on this character and stored with its date (v0.7.1's finding, now with three
   solo recordings behind it); the profile the offline tool needs is persisted. After this,
   a recorded fight can pass the mana gate and the import tool's caveat goes away.
2. **A dungeon is a run, not a pull.** Manual checkpoints record every pull *and the gaps
   between them* — drinking, mana at each pull start, deaths, the clock — stored separately
   from the 8 single fights, selectable on the Review tab, readable by the import tool.
3. **The run has a score a fight cannot have**: total time, and how much of it was drinking.
   The engine chains the pulls with mana carried over and coaches the run — "you drank 4×
   (3:10); this plan needs 2× (1:20)" — the *"wait is a valid action"* decision of v0.7 at
   the scale where it matters.

Nothing here is up for re-litigation; "author question" items have defaults that apply until
answered. Read first: `docs/SPEC-v0.7.md` §3–§6, `docs/SPEC-v0.8.md`, `Engine/RegenModel.lua`
(`RM:Unreported`), `Engine/FightRecorder.lua`, `Engine/SimModel.lua` (`ScenarioFromRecording`,
`Validate`), `Engine/SimPlanner.lua` (`Coach`, `Search`, `Score`), `UI/Dashboard_Review.lua`,
`tools/import.lua`, `Verify.lua` (`RunRegenTest`, `Snapshot`, `Export`).

Conventions as in v0.7/v0.8: Lua 5.1, no libraries, `pcall` around uncertain API, ASCII-only
rendered strings with no bare `|`, `MD:Debug("sim"|"regen"|"combat", ...)` for transitions
never per tick, `.toc` order, version bump per release, **all seven suites green before every
commit** (`simcheck reccheck simwindow regencheck replaycheck replayui` and the new
`runcheck`), `make release SRC=<worktree>`, merge to local master after each version.

---

## 0. Delivery order (one commit each; nothing skips ahead)

| version | ships | verifiable by |
|---|---|---|
| **v0.9.0** | measured mp5 (`cdb.mp5`) from `/md regentest` into `RM:Unreported()` and into every recording's `initial.energize`; the profile snapshot (`cdb.profile`); `tools/import.lua` uses both | `/md regentest 30` solo stores a value; `import validate 2` on the 87 s Hellfire fight passes the mana gate; the tool prints `kit: the character's (as of ...)` |
| **v0.9.1** | `Engine/RunRecorder.lua`: `/md run start [name]` / `stop` / `status`; every pull plus the gaps; `cdb.runs`; auto-stop; `# run` export; `tools/runcheck.lua` | a scripted run of three pulls with a drink between them records as one run with the right stats |
| **v0.9.2** | Review tab run selector; pulls of a run listed with every existing button; `import.lua runs` / `--run N` | the author records a dungeon and reviews its pulls in the tab |
| **v0.9.3** | the run in the engine: `SM.ChainRun`, the gap model with the run's own measured drink rate, `SP.CoachRun`, the run card | on the scripted run the card's drink count and time match the script; a plan that spends less needs fewer drinks |
| **v0.9.4** | the run strip in the replay window: pulls and drinks on one timeline, click to play a pull; run-level Play | the author plays through a dungeon pull by pull |

Docs at every step: `docs/HISTORY.md`, `docs/TESTING.md` (§27–§31), `docs/PLAN.md`;
`docs/DECISIONS.md` only when a call here is changed by evidence.

---

## 1. Decisions this spec encodes (author, 2026-09-06)

1. **Runs are manual.** `/md run start` / `/md run stop`, plus buttons. **Auto-start on
   entering a 5-man instance is reserved** — the recorder must be built so it is one `if`
   away (a `Start(reason)` that the instance event can call), and a `db.runAutoStart`
   setting that ships `false`.
2. **Runs live in SavedVariables**, under their own key, separate from the ring of 8 single
   fights. An addon writes no other file; the SavedVariables *is* the file, and
   `tools/import.lua` reads it. Two runs kept, pinnable.
3. **Every pull of a run is kept**, including the ones under the 20 s / 5 casts gate: they are
   what a dungeon is. The gate stays for *coaching from* a pull.
4. **The measured mp5 enters the model as a measurement, never a constant** (default: option 1
   of the DECISIONS addendum — measured by `/md regentest`, stored per character with the
   date, re-taken on a gear change). Option 2, reading equipped-item tooltips, is an author
   question and stays out unless asked for.

Standing rules carried over: calibration never feeds the model; the causality invariant;
nothing enters the model on a guess; the search never traces.

---

## 2. v0.9.0 — the character as it is

### 2.1 Measured mp5

`/md regentest` already prints the tick histogram and labels a 2 s beat that is not the
spirit tick as "N mp5 the API does not report". v0.9.0 **stores** it:

```lua
cdb.mp5 = { perSec = 6.2, mp5 = 31, at = time(), source = "regentest",
            ticks = 14,            -- how many beats the histogram saw
            level = 64, hint = "Hellfire Peninsula" }   -- where it was measured
```

Stored only when the test was **clean**: no mana spent, no drink, out of the 5SR the whole
window, ≥ 5 beats seen, and the beat's size within ±1 of constant. A dirty test prints why it
did not store. Storing overwrites; the chat line says the old and new values.

`RM:Unreported()` adds `cdb.mp5.perSec` to both rates, exactly as it adds Dreamstate — the
bucket is in force in and out of the five-second rule, which is what the three solo
recordings showed. `MD:Snapshot()` prints it with its date. **The recorder writes
`stream.initial.energize = cdb.mp5.perSec` at each pull start**, so a replay uses what was
known *then*, and `ScenarioFromRecording` passes it through (it already reads
`initial.energize`).

**Gear change**: on `PLAYER_EQUIPMENT_CHANGED` (once per session, out of combat) —
`item mp5 was measured on <date>; gear changed since: /md regentest to re-measure`. Nothing
is invalidated automatically: an old measurement is still a measurement.

**What it is not**: a per-source list. The bucket catches whatever lands in it (an idol, a
blessing that happens to be up during the test); the histogram's line says what it saw. A
Blessing of Wisdom measured in is a Blessing of Wisdom assumed present — which is why the test
is to be run **solo**, and TESTING §27 says so.

### 2.2 The profile snapshot

The offline kit is the harness's because the character is not in the file. v0.9.0 persists
what `RankMath:Context()` needs:

```lua
cdb.profile = { at = time(), level = 64, class = "DRUID",
                healing = 812, crit = 15.2, spirit = 380, intellect = 425,
                talents = { ["Gift of Nature"] = 5, ... },   -- every rank RankMath reads
                relic = 27886, form = "tree", moonglow = 3 }
```

Written at login, after a talent change, and after a gear change (cheap; a few numbers).
`tools/import.lua` applies it to the stub — `MD:TalentRank`, `GetSpellBonusHealing`,
`GetSpellCritChance`, `UnitStat`, `UnitLevel`, the relic — before building the kit, and
prints `kit: the character's (as of 2026-09-06 11:47)` instead of the caveat. Without a
profile in the file the caveat stays.

### 2.3 `docs/TESTING.md` §27

Solo, out of a group, no buffs, out of combat: `/md regentest 30`. It should print the
histogram and `stored: 31 mp5 (was: none)`. Then `/reload` and, on the machine,
`tools/run.sh tools/import.lua validate 2`: the 87 s Hellfire fight should pass the mana gate
it failed on 2026-09-06 (`mana mean 3.3%` → under 2%). Report both lines.

### 2.4 Harness

`regencheck` gains: a clean scripted test stores `cdb.mp5` with the right value; a dirty one
(a spend inside the window) does not. `replaycheck` gains: a recording whose `initial.energize`
is set replays with it (the mana curve shifts by `energize × t`). `simcheck`'s fixture is
unchanged (its energize is the measured 23.1 with its own provenance).

---

## 3. v0.9.1 — the run recorder

### 3.1 Commands

- `/md run start [name]` — begins a run; name defaults to `<zone> <HH:MM>`. If a pull is in
  progress it joins the run. Refuses if a run is already active (says its name).
- `/md run stop` — ends it, prints the run line (§3.4), stores it.
- `/md run status` — name, elapsed, pulls so far, drinks so far, event budget used.
- Buttons **Start run / Stop run** on the Review tab (v0.9.2 makes them; v0.9.1 ships the
  commands).

### 3.2 What a run records (`Engine/RunRecorder.lua`)

```lua
run = {
    v = 1, id = time(), name = "Blood Furnace 21:14", zone = "Blood Furnace",
    t0 = GetTime(), dur = 0, pool = UnitPowerMax("player", 0),
    pulls = { <FightRecorder streams, in order; each carries run-relative t0 and `short` when under the gate> },
    -- the gaps, run-relative time, parallel arrays
    mana  = { t = {}, v = {} },                    -- every 2s for the whole run, in and out of combat
    ev    = { t = {}, kind = {}, a = {}, b = {} },   -- RUN_K below
    stats = <§3.4, computed at stop>,
    truncated = false, pinned = false, reason = "manual",   -- "manual" | "auto" (reserved)
}
RunRecorder.K = { PULL = 1, PULL_END = 2, DRINK = 3, DRINK_END = 4, DEAD = 5, ALIVE = 6,
                  ZONE = 7, INNERVATE = 8, POTION = 9 }
```

- **Pulls**: `FightRecorder:Finish` hands the finished stream to the run when one is active
  (**instead of** the ring of 8 — the run is the container; it is pinnable as a whole).
  Streams under the gate are kept with `short = true`. `PULL` / `PULL_END` events carry the
  pull index and, on `PULL`, the mana at pull start (`a`) as a fraction of the pool (`b`).
- **Drinks**: the master ticker polls `MD:HasBuff("Drink")` (the same three names
  `UI/Advisor.lua` uses); `DRINK` at the first tick it is up with the mana then, `DRINK_END`
  at the first tick it is down with the mana then. The **observed drink rate** is
  `(mana_end - mana_start) / (t_end - t_start)` per drink; the run's `stats.drinkRate` is the
  median. This is the number §5's gap model uses — measured on this run, never a preset.
- **Deaths**: `PLAYER_DEAD` → `DEAD`; `PLAYER_UNGHOST` / `PLAYER_ALIVE` → `ALIVE`. Time
  between is `stats.deadTime`.
- **Mana**: every 2 s (the recorder's `MANA_SAMPLE_TICKS`), the whole run. Between pulls this
  is what shows the drink and the regen; inside pulls the pull's own stream has the same
  samples — the duplication is a few hundred numbers and keeps the run self-contained.
- **Innervate / potion** used between pulls: `INNERVATE`, `POTION` (from
  `UNIT_SPELLCAST_SUCCEEDED` 29166 and the potion item ids `Engine/ManaCooldowns.lua` knows).
- **Zone**: `ZONE` on `ZONE_CHANGED_NEW_AREA` with the new zone name in the string table
  `run.zones[]` (index in `a`).

### 3.3 Limits, auto-stop, retention

- **Budget**: `MAX_RUN_EV = 30 000` recorded events across the run's pulls (their own `n`
  summed) plus the run's own arrays. Past it, new pulls are still *summarised* (the fight
  history is untouched) but not *recorded*, and `run.truncated = true`; the stop line says so.
  A 30-pull Blood Furnace at BF-1's density is ~9 000.
- **Auto-stop**: leaving the instance (`ZONE_CHANGED_NEW_AREA` with `IsInInstance()` false
  after 30 s of grace — a corpse run leaves and returns), `PLAYER_LOGOUT`, and a ceiling of
  `db.runMaxMinutes` (default 90). Each prints the run line with its reason.
- **Retention**: `cdb.runs` keeps **2**; the victim is the oldest run that is not pinned
  (`MAX_PINNED_RUNS = 1`). If both are pinned the new run is not stored and the start command
  says so *before* recording.
- `db.recordRuns` (default `true`) — when off, `/md run start` refuses with the reason.

### 3.4 The run line and `stats`

```lua
stats = { pulls = 30, recorded = 30, long = 4,           -- long: pulls >= 60s
          wall = 1730, combat = 986, combatPct = 0.57,
          drinks = 4, drinkTime = 190, drinkRate = 143.2, -- mana/s, median over the drinks
          manaAtPull = { 0.71, 0.62, ... }, manaAtPullP50 = 0.71,
          deaths = 1, deadTime = 95, innervates = 2, potions = 0, spent = 41200 }
```

Chat, at stop: `run Blood Furnace 21:14: 30 pulls, 28:50, combat 57%, drank 4x (3:10), mana
at pull p50 71%, 1 death (1:35 dead), 41.2k spent`.

### 3.5 Export

`/md export` gains a `# run` section per run: the header line with `stats`, the gap events,
the mana samples, and each pull's `# recording` section as today with `run <id> pull <k>`
appended to its header. `tools/import.lua` (§4.3) reads it back.

### 3.6 `tools/runcheck.lua` (≥ 15 assertions)

Drives a scripted run under the stub: `start`, three pulls (one under the gate), a drink
between the first two (mana rising at a scripted rate), a death and release before the third,
`stop`. Asserts: three pulls in order, the short one flagged, `PULL` mana fractions, one
`DRINK`/`DRINK_END` pair with the rate within 2% of the script, `DEAD`/`ALIVE` and
`deadTime`, `stats` fields, the ring of 8 untouched by the run's pulls, the budget flag when
`MAX_RUN_EV` is lowered to force it, auto-stop on a zone change out of an instance, refusal
when both stored runs are pinned, and `/md export`'s `# run` section rendering without error.

---

## 4. v0.9.2 — the Review tab knows runs

### 4.1 The selector

A button group above the list: `[Fights]` then one button per stored run (`Blood Furnace
21:14`). `Fights` is today's list of the 8 single recordings. A run shows **its pulls** in the
same columns, in order, with `short` in the validate column for the ones under the gate
(greyed, Coach disabled with the reason "under the recording gate"). Above the list, the run
line from §3.4 and, once v0.9.3 exists, the run card's one-line verdict.

### 4.2 Buttons

Validate / Coach / Play / Export work per selected pull exactly as today (`FR:Get(n)` gains a
run-aware sibling `Runs:GetPull(runIdx, k)`; the commands accept `run:k`, e.g. `/md replay
2:7`). **Pin** on a run pins the run. **Start run / Stop run** appear at the left of the button
row; their state follows the recorder.

### 4.3 `tools/import.lua`

`runs` lists stored runs with their stats; `list --run N` lists a run's pulls; `validate`,
`replay`, `coach`, `export` accept `--run N` and address pulls within it; `export --run N`
writes the whole run (`.logs/runs/<id>.txt`).

### 4.4 `docs/TESTING.md` §29

One dungeon: `/md run start` at the entrance, play, `/md run stop` at the end (or just leave —
the auto-stop should fire and say so). Review tab: the run's button appears; its pulls list;
the run line's numbers match your memory of the run (how many drinks, roughly how long); Play
on a pull opens the replay as before. Report the run line verbatim.

---

## 5. v0.9.3 — the run in the engine

### 5.1 The chain

`SM.ChainRun(run, kit, opts)` builds a scenario per pull (`ScenarioFromRecording`, unchanged)
and runs them **in order with mana carried over**, with a gap model between consecutive pulls:

```
gap g between pull k and k+1, recorded length G (wall clock):
  mana regenerates at the base rate + measured mp5 for G, out of the 5SR
  the healer drinks if the DRINK POLICY says so:
      policy = { below = 0.60, upTo = 0.95 }        -- drink when under 60%, stop at 95%
      drink for min(needed, remaining gap) at run.stats.drinkRate, where
      needed = (upTo - mana/pool) * pool / drinkRate
  if the drink would take longer than the gap: the run takes LONGER by the excess
      (added time is a score term); the next pull starts at `upTo`
  a recorded Innervate / potion in the gap is applied as recorded
```

The **healer's own** decisions are the plan (per pull, as today) plus the drink policy; the
damage, the other healers, the deaths of others, the gap lengths are recorded. A pull the
gates rejected still runs in the chain — its *mana* is what matters here, and the mana gate is
the one that v0.9.0 makes pass — but the card says how many pulls were rejected and why.

`ReplayPlan` for the run = the recorded casts per pull **and the recorded drinks** (the
policy that reproduces them: `below` = the highest mana fraction at which the healer actually
drank, `upTo` = the median fraction they stopped at). That is the "you" row.

### 5.2 The score

Lexicographic, lower is better, extending v0.7's tuple **with time before mana**:

```
(deaths, floorSeconds, addedTime, drinks, manaSpent, -heldOn, #binds, overhealSim)
```

`addedTime` is the time the run got longer because a drink did not fit its gap. `drinks` next,
because each is ~40 s of the group standing still even when it fits. Mana after that: mana is
only valuable in a dungeon as time saved. Author question (§8): whether `drinks` should rank
above `addedTime` — the default says a forced longer run is worse than one more drink that fit.

### 5.3 The search

`SP.SearchRun(run, opts, onProgress, onDone)`: the v0.7.5 coordinate descent over the plan's
parameters **plus the two drink-policy parameters** (`below` ∈ {0.4, 0.5, 0.6, 0.7, 0.8},
`upTo` ∈ {0.8, 0.9, 1.0}), one plan for the whole run (a human keeps one plan), evaluated by
`ChainRun`. Budget 300 evaluations as before; a 30-pull chain is ~30 × a pull's cost, so the
slicing on `debugprofilestop()` matters more here — the search may take a minute across
frames and says so.

### 5.4 The run card

```
Run: Blood Furnace 21:14 -- 30 pulls, 28:50 (combat 57%)
  you        drank 4x (3:10)   never forced   41.2k spent   lowest 18% (Trecoda, pull 12)
  best       drank 2x (1:20)   never forced   33.9k spent   lowest 31%
  the plan: [the five rules as today]   drink under 60%, to 95%
  where it differs: pulls 7, 12, 19 (Regrowth where a Rejuvenation held; two Lifebloom
  stacks kept rolling)
  per pull: [k  dur  you-spent  best-spent  lowest  label counts]  (30 rows, in the copy popup)
  pulls not replayed: 3 (foreign healing 41% on pull 4; deaths on 12 and 25)
  caveat: EV crit; gap lengths and others' healing as recorded; drink rate measured on this run
```

### 5.5 Harness

`runcheck` gains: `ChainRun` on the scripted run carries mana across the pulls exactly (the
mana at each pull start equals the recorded one within the gate); with a plan that spends
half, the chain needs fewer drinks and the card's `drank` count drops; a gap too short for
the needed drink produces `addedTime` > 0; the "you" policy reproduces the recorded drinks.

### 5.6 `docs/TESTING.md` §30

Coach a recorded run. Report the two `drank` lines and whether the plan's drink count is one
you would believe of yourself; and the `where it differs` pulls — open one with Play and say
whether the difference is real.

---

## 6. v0.9.4 — the run strip

In the replay window, when a pull belongs to a run: a strip under the header — pulls as
blocks proportional to their length (class-coloured by the lowest target's class? no: a flat
accent, the current pull bright), drinks as blue blocks, deaths as red marks, the gaps as
gaps. Click a block to open that pull (the window re-opens on it, same clock controls).
`/md replay run 2` opens the first pull of run 2 with the strip. A run-level **Play** on the
Review tab does the same. No run-level "play through" at v0.9.4: a dungeon at 1× is half an
hour; pull-by-pull with the strip as the map is the feature. **Author question**: a
"next pull" button that advances automatically at the end of each pull — default yes, since
it costs nothing.

---

## 7. Files and `.toc` positions

| file | role | after |
|---|---|---|
| `Engine/RunRecorder.lua` | runs: start/stop, gaps, stats, retention, export | `Engine/FightRecorder.lua` |
| `tools/runcheck.lua` | harness (not shipped) | — |

`Engine/RegenModel.lua` gains the measured term; `Verify.lua`'s `RunRegenTest` stores it and
`Snapshot` prints it; `Core.lua` writes `cdb.profile` and gains `/md run`, `db.recordRuns`,
`db.runMaxMinutes`, `db.runAutoStart` (reserved, `false`); `Engine/FightRecorder.lua` hands
streams to the run and writes `initial.energize`; `Engine/SimModel.lua` gains `ChainRun`;
`Engine/SimPlanner.lua` gains `CoachRun`, `SearchRun`, the run card and the run score;
`UI/Dashboard_Review.lua` the selector and the buttons; `UI/ReplayWindow.lua` the strip;
`tools/import.lua` the profile, `runs` and `--run`. `tools/harness.lua`'s list follows the
`.toc`.

---

## 8. Rejected and reserved

### Reserved

- **Auto-start on entering an instance** (`db.runAutoStart`, ships `false`; `Start("auto")`
  exists from v0.9.1).
- **Coach inside the replay** and **defensives as a decision input** (SPEC-v0.8 §7) — the run
  data does not change either.
- **Reading item mp5 from tooltips** (option 2) — only if the measured route proves annoying.

### Rejected (do not re-propose)

- **Writing runs to a file.** An addon cannot. The SavedVariables is the file.
- **Runs consuming the ring of 8.** A run is its own container; a boss inside a run is found
  through the run.
- **A preset drink rate.** The run measures its own; without a drink in the run, the gap
  model uses `RM:ObservedFill()`'s session value and the card says so.
- **A blended run score.** Time and mana are not the same unit; the tuple ranks them.
- **A run-level "play through" at 1×.** Half an hour of watching is not review; the strip and
  pull-by-pull is.
- **Per-source mp5 (naming the idol, the blessing).** The bucket is measured as a whole; the
  histogram's line names what it saw.

---

## 9. Author questions with defaults

| question | default until answered |
|---|---|
| measured mp5: `/md regentest` (1) or tooltip scan (2) | 1 |
| `drinks` above `addedTime` in the run score | no — a forced longer run is worse |
| runs kept | 2, one pinnable |
| run ceiling | 90 min |
| "next pull" auto-advance in the strip | yes |
| a run's pulls under the gate shown | yes, greyed, Coach disabled |
