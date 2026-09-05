# ManaDemon v0.7 — implementation spec

**This is the document to implement from.** It encodes the outcome of the design debate
(`docs/debates/v0.7-sim/JUDGE.md`; decisions recorded in `docs/DECISIONS.md` §v0.7). Where
`docs/DESIGN-v0.7.md` and this spec differ, this spec wins. Nothing here is up for
re-litigation; "author question" items have defaults that apply until answered.

Read first: `CLAUDE.md` (conventions), `docs/DECISIONS.md` §v0.6 and §v0.7, `Engine/RankMath.lua`,
`Engine/Calibration.lua`, `Engine/Overheal.lua`, `Engine/Targets.lua`, `UI/Summary.lua`,
`Engine/SpendTracker.lua`, `UI/Dashboard_Waste.lua` (the pattern for a dashboard tab).

Conventions that apply to every line of v0.7: Lua 5.1, no libraries, every file starts
`local _, MD = ...`, `pcall` around any API that might not exist on the 2.5.x client,
ASCII-only rendered strings with no bare `|`, `MD:Debug("sim", ...)` for state transitions and
timings (never per event), `luaparser` syntax check before every commit
(`python3 /home/penek/.claude/jobs/330e6a3d/tmp/luacheck.py`), `.toc` order consistent with what a
file reads from `MD`, version bump per release, `make release SRC=<worktree>` builds.

---

## 0. Delivery order (one commit each; nothing skips ahead)

| version | ships | verifiable by |
|---|---|---|
| **v0.7.0** | HP-at-cast + cost + form on every own cast; 20s pre-pull cast ring; plan-free labels; summary rows to 200 with new fields; one new fight-summary line | the line appears after a pull and is right when checked against memory of the pull |
| **v0.7.1** | `RankMath:SpellKit`; `Engine/SimModel.lua` (engine, mana half); `/md simrun` self-tests; `Data/SimFixture_BF1.lua`; `/md simreplay fixture` | self-tests pass; fixture mana curve within gates |
| **v0.7.2** | `Engine/FightRecorder.lua` (full streams); `/md export` `# recording` section | a recording appears after a pull; counts sane |
| **v0.7.3** | HP half of replay; the six gates; `/md simreplay [n]`; Validate | first recorded fight validates or says why not |
| **v0.7.4** | `Engine/SimPlanner.lua` rules + classifier; text card; loop closure | card for a recording reads sensibly; sum identity holds |
| **v0.7.5** | the search | best plan beats both baselines on a recording within 10s |
| **v0.7.6** | `UI/Dashboard_Review.lua` (Review tab) | author reviews a real pull in the dashboard |
| **v0.7.7** | `UI/SimWindow.lua`, `Data/SimPresets.lua`, `FromRecordings`, Monte Carlo replicates | a synthetic scenario runs |

Docs at every step: `docs/HISTORY.md` entry, `docs/TESTING.md` section, `docs/PLAN.md` tick;
`docs/DECISIONS.md` only when a call here is changed by evidence.

---

## 1. Combat-log facts (verified against Details! on this client)

`CombatLogGetCurrentEventInfo()` returns the 11-field prefix
`timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags`
followed by the payload:

| subevent | payload after the prefix |
|---|---|
| `SWING_DAMAGE` | `amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand` |
| `SPELL_DAMAGE`, `SPELL_PERIODIC_DAMAGE`, `RANGE_DAMAGE`, `SPELL_BUILDING_DAMAGE`, `DAMAGE_SHIELD`, `DAMAGE_SPLIT` | `spellId, spellName, school, amount, overkill, school2, resisted, blocked, absorbed, critical, ...` |
| `ENVIRONMENTAL_DAMAGE` | `envType, amount, overkill, ...` |
| `SWING_MISSED` | `missType, isOffHand, amountMissed` |
| `SPELL_MISSED` | `spellId, spellName, school, missType, isOffHand, amountMissed` |
| `SPELL_HEAL`, `SPELL_PERIODIC_HEAL` | `spellId, spellName, school, amount, overhealing, absorbed, critical` |
| `SPELL_CAST_SUCCESS`, `SPELL_CAST_START` | `spellId, spellName, school` — **`destGUID`/`destName` in the prefix are the cast's target** |
| `UNIT_DIED` | (none) |

Rules: **`amount` on damage is the HP actually lost** (Details adds `absorbed` back only to credit
the attacker; we never do). Full absorbs arrive as `*_MISSED` with `missType == "ABSORB"` and
never touch HP — count them, do not subtract them. `amount` on heals is **gross** on this client
(`db.healAmountGross` is latched `true`; use `OH:Split` regardless). A killing blow's `amount`
includes `overkill`; store `amount - overkill`.

All of this goes through the **single existing handler** in `UI/Summary.lua`, which already
unpacks the event once; it forwards to `MD.FightRecorder` (v0.7.2) and the v0.7.0 cast capture.

---

## 2. v0.7.0 — HP-at-cast, the pre-pull ring, plan-free labels, summaries to 200

### 2.1 Own-cast capture (`UI/Summary.lua` handler, `SPELL_CAST_SUCCESS` with `sourceGUID == MD.player.guid`)

```lua
-- one record per own cast, appended to MD.Recorder.ring (always) and to the live
-- fight's casts (in combat). Never allocate per event beyond this one table.
{ t = GetTime(), spellID = spellID, cost = SD:GetCost(spellID) or -1,
  tgt = <roster index via MD.Targets:Lookup(destGUID, destName) or -1>,
  hpAtCast = <UnitHealth(e.unit) / UnitHealthMax(e.unit), or -1 if unresolved>,
  form = MD:InTreeForm() and 1 or 0,
  kind = <"heal" if SD.spells[spellID] and family not excluded; "utility" if priced and not a heal;
          "shift" if spellID is a shapeshift (Tree 33891, Bear 5487/9634, Cat 768, Travel 783, Aquatic 1066, Moonkin 24858)> }
```
`Targets.byGUID[guid].unit` already exists; `hpAtCast` uses it. **Unavailable = −1, never 0.**

Pre-pull ring: `MD.Recorder.ring` keeps the last **20 s** of own casts (prune on append). At
`PLAYER_REGEN_DISABLED` the ring is copied into `fight.precasts`.

### 2.2 Plan-free labels (computed at `PLAYER_REGEN_ENABLED`, no simulator needed)

One label per own cast in the fight, precedence in this order; every cast gets exactly one:

| label | rule |
|---|---|
| `utility` | `kind == "utility"` |
| `shift` | `kind == "shift"` |
| `early` | Rejuvenation or Regrowth cast on a target that still had the same family's HoT from the player with **≥ 2 ticks pending** (tracked by the recorder from the player's own periodic heal events: per (target, family) the last-cast time and tick count seen) |
| `overheal` | heal cast with `hpAtCast >= db.simFullHp` (**0.85**) |
| `ok` | everything else |

`prehot` is a per-fight flag, not a cast label: any ring cast on a target at `hpAtCast >= 0.95`
whose subsequent ticks (before the pull) were ≥ 50% overheal. Reported on its own line; its
mana is outside fight spend.

Identity, asserted in `Debug("sim")` and printed on the summary tooltip:
`utility + shift + early + overheal + ok == fight spend`.

### 2.3 Summary rows (`MD.cdb.fights`)

`MAX_HISTORY = 200`, gate: keep a row iff `duration >= 15` and `ownCasts >= 4` (was 15 s / any).
New fields per row (existing rows lack them → `nil`, excluded from habits):

```lua
labels = { utility = <mana>, shift = <mana>, early = <mana>, overheal = <mana>, ok = <mana> },
labelCasts = { ... same keys, counts ... },
hpBuckets = { [1] = n(hpAtCast < 0.5), [2] = n(0.5..0.85), [3] = n(>= 0.85), [4] = n(unknown) },
prehot = <mana or 0>, foreignShare = <0..1 or nil until v0.7.2>, lowestMana = <fraction>,
ownCasts = n, streamID = <id in recordings or nil>
```

### 2.4 The summary line (the "first win")

Appended after the existing fight line, only when `ownCasts >= 4`:

```
14 of 19 casts on targets above 85% (2.9k): Lifebloom 9, Rejuvenation 4, Regrowth 1 - utility/shifts 1.6k - buffed in combat: Mark of the Wild at 0:39
```
Format: `"%d of %d casts on targets above %d%% (%s): %s%s%s"` — the per-family list is
descending by count, top 3; `- utility/shifts X` only when > 0; `- buffed in combat: <spell> at m:ss`
for each utility cast whose spell is a buff (MotW, Thorns) — max 2, then `(+N more)`.
`prehot` adds a second line only when > 0: `"pre-pull HoTs on full targets: %s (%d%% overheal)"`.

### 2.5 Habits (Review tab, v0.7.6; the data exists from v0.7.0)

Over the last 200 summary rows with `labels ~= nil`: sum mana per label, print the **top 3 by
mana** with counts and the dominant family; `ok` is never a habit.

---

## 3. v0.7.1 — `RankMath:SpellKit`, `Engine/SimModel.lua`, self-tests, the fixture

### 3.1 `RankMath:SpellKit(ctx)` (in `Engine/RankMath.lua`)

Built from `RowFor(spellID, ctx, nil, true)` for every known rank of every family (Tranquility
and Swiftmend included), **once per form per run** (`kit.caster`, `kit.tree`), from
`Context({ live = true, healer = <overrides or nil> })`. `Context(opts)` gains
`opts.healer = { heal, crit, casting, base, mana, inTree }` applied exactly like `MD.sim` but
only when `opts.healer` is given; `opts.live` still suppresses `MD.sim`.

```lua
kit[form][spellID] = {
  family, rank, type,                  -- "direct" | "hot" | "hybrid" | "lifebloom" | "instant" | "channel"
  cost,                                -- live cost (replay uses the RECORDED cost instead)
  cast,                                -- E[T] incl. Nature's Grace (RankMath castTime); 1.5 for instants
  gcd = 1.5,
  direct = <non-crit direct>, directCrit = <crit chance used>,   -- direct/hybrid only
  tick, ticks, tickPeriod, duration,   -- hot/hybrid/lifebloom; lifebloom tick is per stack at x1
  bloom,                               -- lifebloom
  swiftmendRejuv, swiftmendRegrowth,   -- instant: heal = remaining ticks of the consumed HoT (12s / 18s worth)
  channelTick, channelTicks,           -- Tranquility: 4 ticks on every party target, 10 min CD, caster only
}
```
Crit is **never** baked into `direct`; the engine applies it (§3.3).

### 3.2 Scenario (input to the engine)

```lua
scenario = {
  dur, pool, floor = db.simFloor, grace = 6, reaction = db.simReaction, minActivity = db.simMinActivity,
  targets = { { name, role, maxHP, hp0, tracked = true }, ... },   -- index = roster index
  initial = { mana, apiBase, apiCasting, form, auras = { { target, spellID, stacks, remaining } }, buffs = {...} },
  -- damage / foreign-heal timeline (recorded) : parallel arrays, sorted by t
  ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} },
  -- OR analytic (synthetic only): targets[i].dps, targets[i].pulse = { amount, period, offset }
  forms = { {t, form} },                  -- form changes to honour in REPLAY (plan runs choose form by kit)
  costs = <function(spellID) or nil>,     -- replay: recorded cost per cast; nil -> kit cost
  rates = { {t, apiBase, apiCasting} },   -- replay: recorded regen rates; nil -> initial rates
}
```

### 3.3 Event kinds (the `kind` enum — same numbers in the recorder, the fixture and the engine)

| kind | meaning | `tgt` | `amt` | `x` |
|---|---|---|---|---|
| 1 `DMG` | damage taken | roster idx | HP lost (post-absorb, minus overkill) | spellID or 0 (swing) |
| 2 `FHEAL` | foreign heal | roster idx | effective heal (positive) | source class id or 0 |
| 3 `OWNCAST` | own `SPELL_CAST_SUCCESS` | roster idx or −1 | cost | spellID |
| 4 `OWNHEAL` | own heal landed | roster idx | gross | spellID; crit in high bit: `x = spellID + (crit and 100000 or 0)`; periodic: `amt < 0`? **no** — periodic flag lives in `kind` 5 |
| 5 `OWNTICK` | own periodic heal landed | roster idx | gross | spellID (+100000 if crit) |
| 6 `CASTSTART` | own `SPELL_CAST_START` | roster idx or −1 | 0 | spellID |
| 7 `CANCEL` | cast start with no success by the next own event | −1 | busy seconds | spellID |
| 8 `FORM` | form change | −1 | 1 tree / 0 caster | 0 |
| 9 `DIED` | tracked target died | roster idx | 0 | 0 |
| 10 `ABSORB` | full absorb (`*_MISSED` ABSORB) | roster idx | amountMissed | spellID or 0 |
| 11 `CD` | cooldown/consumable used (NS 17116, Innervate 29166, potion item) | −1 | mana gained or 0 | spellID/itemID |
| 12 `MANA` | mana sample (every 2 s) | −1 | mana | `apiBase*1000 + apiCasting` packed? **no** — mana samples live in their own arrays (§4.3); kind 12 is unused in `ev` |

Engine heap tie-break for equal `t`: `DMG < FHEAL < tick < expiry/bloom < cast-landed < 5SR-lapse < decision`.

### 3.4 `SimModel:Run(scenario, plan, opts) -> result`

`plan` is either a `Plan` (§5) or a **replay plan** built from a recording's `OWNCAST` events
(`SimModel.ReplayPlan(recording)`), which casts exactly what was cast, when it was cast, at the
recorded cost, in the recorded form, and treats `CANCEL` as busy time.

`opts = { critMode = "ev" | "roll", seed = n, abortAbove = <mana>, trace = bool }`.

**Zero allocation inside `Run`.** The engine owns a pool: pending-event binary heap keyed
`(t, seq)`, per-target scratch (hp, hot state per family: `expires, nextTick, ticksLeft,
stacks`), and trace arrays. `Run` takes them from `SimModel.pool` and returns them; a
second concurrent `Run` (search inside coroutine) uses a second pool slot. Timeline arrays are
read by index, never copied.

Loop:

```
t = 0; apply initial (auras -> scheduled ticks/expiries; mana; form; buffs -> regen mods)
while heap not empty and t < dur:
    e = pop()
    integrate analytic dps for every target over (t .. e.t)   -- recorded timelines have no dps
    t = e.t
    apply e (see 3.5)
    if healer is free at t and no decision is scheduled: schedule DECISION at t
    on DECISION: action = plan:Decide(state, t); schedule per 3.6
    early abort: manaSpent > opts.abortAbove, or floorSeconds already exceeds incumbent's
```

### 3.5 Applying events

| | |
|---|---|
| `DMG` | `hp[tgt] = max(0, hp - amt)`; if `hp == 0` and not already dead: death event, target stops (no further heals land; damage ignored) |
| `FHEAL` | `hp = min(maxHP, hp + amt)` |
| tick | `hp = min(maxHP, hp + tick × stacks)`; overheal accounted per family; schedule next tick unless `ticksLeft == 0` |
| expiry | Lifebloom: bloom **once** regardless of stacks, then clear; others: clear |
| cast landed | see 3.6 |
| 5SR lapse | regen rate switches to `base` |
| `FORM` (replay) | current form; kit lookups from now use it |
| `CD` (replay) | Innervate: regen per `ManaCooldowns` for 20 s; potion: `mana += amt`; NS: next cast instant |

Heals are applied through **one function** `Land(target, amount, family, kind, critMode)`:
`critMode == "ev"` multiplies direct/bloom amounts by `(1 + 0.5 × critChance)`; `"roll"` rolls
the seeded RNG. Ticks never crit. Overheal = amount above `maxHP`, attributed per family.

Refreshing a HoT: **remaining ticks are lost**; the new application schedules a full set
(TBC behaviour; open question §11 — the engine has a flag `opts.refreshKeepsTicks` default
`false` so a one-line change fixes it if the client disagrees). Lifebloom recast on a live stack:
`stacks = min(3, stacks + 1)`, duration reset to 7 s.

Swiftmend consumes Regrowth first, else Rejuvenation; heal = the consumed HoT's remaining
ticks (`swiftmendRejuv` / `swiftmendRegrowth` from the kit); 15 s cooldown.

### 3.6 Scheduling a decision's action

`nextAction = max(castEnd, lastCastStart + 1.5)`. **Cast commitment:** a started cast is locked
until it lands; the plan is next asked at `landsAt`. Reaction delay `db.simReaction` (**0.5 s**,
provenance "B; post-idle only; log p10/p25 inter-cast gap 1.50/1.52 s shows chaining at the
GCD") is added **only** when the previous decision was `wait`. `wait` schedules the next decision
at the next heap event (never later than 0.5 s ahead, so a wait can end promptly — but causally,
§5.2). Mana is deducted at cast **start**; 5SR restarts at cast start.

### 3.7 `result`

```lua
result = {
  ok,                         -- no tracked death and floorSeconds == 0
  deaths = { {tgt, t} },
  floorSeconds,               -- Σ over tracked targets of seconds spent below floor after grace
  manaSpent, manaEnd, lowestMana, oomAt,
  lowest = { tgt, hp = fraction, t },
  casts, byFamily = { family = count }, byLabel = nil,           -- byLabel filled by the classifier
  waitFraction, maxWaitRun = { len, t },
  overheal = { byFamily = { family = fraction } },               -- simulated
  timeline = { t = {}, mana = {}, hp = { [tgt] = {} } },         -- at 1 s, only when opts.trace
  manaCurve = { {t, mana} },                                     -- at the scenario's mana sample times (replay validation)
  hpCurve = { [tgt] = { {t, hp} } },                             -- at the scenario's HP snapshot times
  evals = 1, ms = <elapsed>,
}
```

### 3.8 `/md simrun` self-tests (all must print `ok`)

1. One Rejuvenation R(max) on a full-HP single target, no damage: total healed == dashboard row heal ± 1; mana drop == row cost.
2. Chain-cast Regrowth R9 from full mana, zero damage, until unaffordable: cast count == To OOM column == **13** (the regression spamtest).
3. Rejuvenation refreshed after 2 ticks: total ticks landed == 4 + 4 − 2 (ticks lost).
4. Lifebloom x3 allowed to expire: exactly one bloom.
5. Swiftmend with both HoTs up consumes Regrowth.
6. A target dies between a tick and a scheduled cast: the cast is not landed on the corpse.
7. 5SR: a cast at t = 0 then nothing: regen is `casting` until 5.0, `base` after.
8. GCD: two instants at t = 0 land at 0 and 1.5.
9. `Run` allocation check: `collectgarbage("count")` before/after a 1,500-event run differs by < 4 KB.

### 3.9 `Data/SimFixture_BF1.lua` and `/md simreplay fixture`

The fixture is generated from the log (header states it is hand-transcribed and approximate on
initial auras). `/md simreplay fixture` builds a scenario from it (no damage events; targets'
HP irrelevant), replays `casts` at recorded costs with the recorded forms and rates, and prints
mean and max |Δ| of `manaCurve` vs the fixture's `mana` in % of pool. **Expected: mean ≤ 2%,
max ≤ 5%.** If it fails, the engine is wrong before anything else is built.

---

## 4. v0.7.2 — `Engine/FightRecorder.lua`

### 4.1 Tracked targets

`tracked` = all group members (self included) when `GetNumGroupMembers() <= 5`; in a raid:
the player's subgroup (`GetRaidRosterInfo` subgroup) plus every unit for which
`GetPartyAssignment("MAINTANK", unit)` is true. **Untracked targets are never recorded** (no
damage, no foreign heals, no snapshots). Author question (default applies): subgroup + main
tanks in raids.

### 4.2 What is recorded, from which event

| field | source | when unavailable |
|---|---|---|
| damage per tracked target | §1 damage subevents, `destGUID` tracked | — |
| full absorbs | `*_MISSED` with `missType == "ABSORB"` | — |
| foreign heals | `SPELL_HEAL`/`SPELL_PERIODIC_HEAL`, `sourceGUID ~= player`, dest tracked, `effective` via `OH:Split` | — |
| own casts | `SPELL_CAST_SUCCESS` (§2.1 record) | tgt −1, hpAtCast −1 |
| own heals | `SPELL_HEAL`/`_PERIODIC_HEAL` from player: kind 4/5, gross, crit | — |
| cast starts / cancels | `SPELL_CAST_START`; `CANCEL` synthesized when the next own event is not the matching success | — |
| mana samples | `MD:OnTick` every 4th tick (2 s): `{t, mana, RM.apiBase, RM.apiCasting}` | — |
| HP snapshots | at pull, every 5 s, at end: `{t, hp[i], maxHP[i]}` for tracked | −1 for out-of-range units |
| deaths | `UNIT_DIED` with dest tracked | — |
| form changes | `FORM_CHANGED` callback | — |
| cooldowns / consumables | `SPELL_CAST_SUCCESS` for 17116/29166; `ManaCooldowns`' "cooldown used" transition for potions with the mana jump | — |
| initial state | at `PLAYER_REGEN_DISABLED` (§4.4) | — |
| roster | `Targets.byGUID` at pull: `{name, class, role, roleSource, maxHP}` | — |
| precasts | the 20 s ring (§2.1) | — |

### 4.3 Stream layout (numbers only in arrays; `kind` per §3.3)

```lua
MD.cdb.recordings[i] = {
  v = 1, id = <time()>, zone, t0 = <GetTime at pull>, dur, pool,
  roster = { {name, class, role, roleSource, maxHP}, ... }, tracked = { idx, ... },
  initial = { mana, apiBase, apiCasting, form, auras = { {target, spellID, stacks, remaining}, ... },
              buffs = { {spellID, remaining}, ... } },
  ev   = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} },
  hp   = { t = {}, hp = { [idx] = {} }, max = { [idx] = {} } },
  mana = { t = {}, v = {}, base = {}, cast = {} },
  precasts = { {t, spellID, cost, tgt, hpAtCast, form}, ... },
  foreignShare, deaths = { {idx, t} }, spent, ownCasts, pinned = false,
  labels = <same as the summary row's>,
}
```
Capacity: `ev` is cut at **4,000** events (the fight keeps recording summaries; the stream is
marked `truncated = true`). Target serialisation ≈ 15 chars/event; 8 streams ≈ 180 KB on disk.

### 4.4 Initial state at `PLAYER_REGEN_DISABLED`

For every tracked unit: `for i = 1, 40: name, _, count, _, duration, expirationTime, source, _, _, spellID = UnitAura(unit, i, "HELPFUL|PLAYER")`
— keep entries whose `spellID` is in `SD.spells` (the player's own HoTs); `remaining =
expirationTime - GetTime()`, `stacks = count > 0 and count or 1`. Player: form (`MD:InTreeForm()`),
mana, `RM.apiBase/apiCasting`, and buffs from `UnitAura("player", i, "HELPFUL")` whose name is
Drink / Innervate / a mana potion (`remaining` as above). `pcall` the whole scan.

### 4.5 Gates and retention

Stream gate: `dur >= 20 and ownCasts >= 5`. Summary gate (§2.3): `dur >= 15 and ownCasts >= 4`.

```
on fight end, if stream gate passes:
    if #recordings < 8: append
    else:
        protected = pinned (<= 2) ∪ the 3 most recent by id
        victim = argmin spent over recordings not in protected
        replace victim
recordings are sorted by id descending for display
```
`db.recordFights` (default `true`) turns the recorder off entirely; summaries still run.
`/md export` gains `# recording <n>` : the parallel arrays as TSV, one event per row
`t kind tgt amt x`, then `# hp`, `# mana` blocks.

---

## 5. v0.7.4 — `Engine/SimPlanner.lua`: plans, the causality invariant, the classifier

### 5.1 Plan

```lua
plan = {
  binds = { "Lifebloom:33763", "Rejuvenation:26981", "Regrowth:9858", "Swiftmend:18562" }, -- <= 5, <= 2 ranks per family
  rules = {
    { "swiftmend", below = T_s },                       -- T_s ∈ {0.30, 0.40}
    { "direct",    below = T_d, spell = <bind> },       -- T_d ∈ {0.35, 0.45, 0.55}; Regrowth or Healing Touch
    { "roll",      spell = <Lifebloom bind>, stacks = N }, -- N ∈ {0, 1, 3}; 0 = no roll
    { "hot",       below = T_h, spell = <Rejuvenation bind> }, -- T_h ∈ {0.60, 0.80, 0.90}
    { "filler",    spell = nil | <Lifebloom bind> },    -- wait, or Lifebloom x1 on the tank
  },
}
```
Order is fixed in code. Target choice inside a rule: **lowest HP fraction first, tank on ties**;
`roll` and `filler` target the tank (`role == "TANK"`, else the target with the most damage
taken so far). Rule 2 fires when `hp + <non-crit direct> <= maxHP` would still leave the target
below `below` after the cast — i.e. the deficit test uses the **non-crit** amount. `hot` fires only
if the target has no live HoT of that family from the player.

Rank space: **binds fixed** by default — the ranks the player cast in this recording (fallback:
ranks cast across the last 20 summaries; fallback: max known rank per family). With
`db.simAllowRebinds == true`: the dashboard's known, Pareto-non-dominated ranks per family.

### 5.2 Causality invariant (paste at the top of the file)

```
-- CAUSALITY: Plan:Decide(state, t) receives, and may read, ONLY: t; each target's hp,
-- maxHP, alive, and the player's own HoT state on it as of t; mana, form, cooldowns as of
-- t; and ONE derived input: each target's damage taken over the trailing 5 s, computed
-- from events already applied. It holds no reference to the scenario's event arrays and
-- nothing it schedules may depend on any event with t' > t. A cast, once started, is
-- locked until it lands. This is what makes the card advice rather than hindsight.
```

### 5.3 Score (lexicographic tuple, lower is better)

`(deaths, floorSeconds, manaSpent, -heldOn, #binds, overhealSim)` where `heldOn` = number of
other retained streams on which the plan finishes with `deaths == 0 and floorSeconds == 0`
(computed only for the final top 3, §6). Comparison is element-wise.

### 5.4 Baselines (always run on a Coach)

1. **you** — the replay plan; 2. **max rank everything** — rules with `T_s .30, T_d .45, N 3, T_h .80, filler wait`, max ranks; 3. **HoTs only, max rank** — rule 2 disabled; 4. **best**.

### 5.5 Classifier (plan-relative labels, Coach only)

Run the best plan on the recording **in lockstep** with the replay: at each own cast in the
recording, ask the best plan what it would have done at that `t` with the recording's state.
Label the real cast:

| label | rule (first match wins, in this order) |
|---|---|
| `utility` / `shift` | as §2.2 |
| `fine` | the plan would cast the same family at that t (any rank), or the target was below the plan's threshold for that family |
| `rank` | same family, plan's bind is a cheaper rank |
| `spell` | plan casts a different family on that target at that t |
| `early` | as §2.2 (HoT with ≥ 2 ticks pending) |
| `stack` | Lifebloom recast on a stack already at the plan's N |
| `overheal` | `hpAtCast >= db.simFullHp` and the plan would wait |
| `late` | the plan cast on this target ≥ 3 s earlier (its cast landed before the real one started) |
| `unclassified` | none of the above — printed with its mana |

`idle` is a virtual entry: a plan cast with no real cast within ±(reaction + cast time), listed
only if the target was below the floor for ≥ reaction + cast time before it (knowability).

Identity printed on the card: `Σ mana over all labels (utility, shift, fine, rank, spell, early,
stack, overheal, late, unclassified) == fight spend`. `Debug("sim")` asserts it.

### 5.6 Loop closure

When a card is shown: `MD.cdb.coachMarks[zone] = { t = time(), overhealFrac, manaPerPull, topHabit }`
(overhealFrac = share of heal casts labelled `overheal` in that fight; manaPerPull from
`PullBudget`). The Review tab prints, once ≥ 3 later same-zone summaries exist:
`"since your last card (N fights): overheal 39% -> 31%, mana/pull -0.8k"`.

### 5.7 Card text template

```
<zone>, <when> (<m:ss>, <targets> targets)          you <spent>k   best <spent>k   diff <k>
VERDICT LINE:  "you had X.Xk headroom -- nothing here needed to change"   (if lowestMana - PullBudget.perPull >= 0, n >= 2 in zone)
               "~ one fewer drink per N pulls"                              (only if PullBudget n >= 4)
  Bind: <binds>                                    (rebinds allowed: changed ranks marked "(was R12)")
  1. Anyone under <T_s>% with a HoT: Swiftmend
  2. Anyone under <T_d>%: <direct spell>
  3. Keep Lifebloom x<N> rolling on <tank>           (omitted when N == 0)
  4. Anyone under <T_h>% without Rejuvenation: Rejuvenation R<n>
  5. Otherwise wait -- <waitFraction>% of the fight, longest gap <s>s at <m:ss>
  you            <spent>   lowest <hp>%   overheal <sim%>      (sim vs measured <family>: X% / Y%)
  max rank       <spent>   lowest <hp>%
  HoTs only      <spent>   lowest <hp>%
  best           <spent>   lowest <hp>%   held on <N> of <M> (hardest and most recent retained fights)
  overheal   <n> casts <k>   <family> on <names> above 85%
  early      <n> casts <k>
  rank / spell / stack / late / idle ... (non-zero only)
  unclassified <n> casts <k>
  utility <k>  shifts <k>  (outside the healing denominator)
  caveat: EV crit; other healers as recorded; threat/kill speed not modelled; <gates summary>
```

---

## 6. v0.7.5 — the search (`SimPlanner:Search(scenario, opts, onProgress, onDone)`)

- Coordinate descent, **the only mode**. Seeds (4): max-rank baseline, HoTs-only baseline, the
  player's binds with rule defaults (`T_s .30, T_d .45, N 3, T_h .80, filler wait`), one random
  point. From each seed: sweep one parameter at a time over its domain, accept improvements,
  repeat until a full pass changes nothing. Then the best of the four.
- Budget: **≤ 300 evaluations total**, early abort per §3.4, coroutine resumed from an `OnUpdate`
  slice of **≤ 8 ms**, progress callback `(evals, best)`, a **Cancel** that stops at the next slice.
  Target wall-clock 10 s (author question; default 10 s).
- After the search: run the top 3 on every other retained stream for `heldOn` (§5.3), then the
  classifier on the winner. Alternates within 5% mana with fewer binds go in the card's tooltip.
- `Debug("sim")`: evaluations, ms, best tuple, and the physical-floor assertion
  `best.manaSpent >= Σ max(0, D_i − (hp0_i − floor·maxHP_i)) / maxHPM` (never shown on a card).

---

## 7. v0.7.3 — the six validation gates (settings, defaults, provenance strings)

| setting | default | disables Coach? | provenance string |
|---|---|---|---|
| `simGateManaMean` | 0.02 of pool | yes | "judge; server regen tick quantises samples by ~2% of pool" |
| `simGateManaMax` | 0.05 of pool | yes | same |
| `simGateHpMean` | 0.05 of maxHP | excludes the target | "B; reconstructed through pets/absorbs/range" |
| `simGateHpMax` | 0.15 of maxHP | excludes the target | same |
| death of a tracked target | — | yes | "post-death damage truncation" |
| `simForeignShare` | 0.25 | yes | "A's number; BF-1 measured 0%; prior" |
| calibration drift ≥ 3% on a spell ≥ 10% of the fight's spend | — | yes (uncalibrated = printed, not failing) | "Calibration ALERT_REL" |
| spend coverage: modelled casts ≥ 90% of fight spend | — | yes | "12.6% utility hole in BF-1" |

Deviations are computed only at recorded anchors (mana samples; HP snapshots per target).
All results print on the Review row's tooltip every time. Replay uses the recorded rates and
recorded costs. Failed fights stay listed, greyed, with the failing number (author question;
default greyed). Promotion rule for the overheal curve: becomes a gate at ≤ 10% |Δ| once ≥ 5
recordings pass everything else — record in DECISIONS when it happens.

---

## 8. v0.7.6 — `UI/Dashboard_Review.lua`

Sixth dashboard tab "Review" after Waste (pattern: `Dashboard_Waste.lua`, constructor on
`MD.DashboardParts`, `currentFamily == "Review"`). Works for any class (the stream is
class-agnostic; Coach needs the druid kit).

```
#  when          zone            dur    tgts  casts  spent   low mana   validate
1  today 21:14   Blood Furnace   0:40   5     19     6.2k    36%        ok
2  today 21:12   Blood Furnace   0:37   5     16     3.7k    52%        HP: Trecoda 18%
3  today 20:58   Blood Furnace   2:47   5     42     8.2k    41%        mana +4%       (greyed)
                                              [ Validate ] [ Coach ] [ Pin ] [ Export ]
Habits over the last N fights:   overheal 31 casts 9.4k  Lifebloom on people above 85%
                                 early    48 casts 3.1k   ...
since your last card (4 fights): overheal 39% -> 31%, mana/pull -0.8k
```
Row tooltip (`MD.Tip`): all six gate results, per-spell drift for spells ≥ 10% of spend,
foreignShare, sim-vs-measured overheal per family. Card tooltip adds: held on N of M,
evaluations and ms, `unclassified` mana, rebinds allowed or not, the two alternates.
Coach button disabled with the reason when any disabling gate failed.

---

## 9. v0.7.7 — `UI/SimWindow.lua`, `Data/SimPresets.lua`, `FromRecordings`, Monte Carlo

- Window: Setup + Result panes as in `docs/DESIGN-v0.7.md` §6.1–6.2 (Review stays on the
  dashboard; move it later only if the author asks).
- Presets: party (solo/2/3/5/10/25 with role and HP defaults per level bracket), damage
  (analytic: tank steady 450, two steady 450/300, dungeon 450 + pulses 1500/12 s and 1200/17 s,
  aoe 120 all + 330 tank, tank+aoe), situation (full / all 30% / tank 50% dps 10% / spread
  100-70-40-20). All numbers are placeholders with a provenance comment.
- `SP.FromRecordings(zone, n)`: per **target** (tagged by role): baseline rate = mean
  damage/s outside big hits; big hit = ≥ `db.simBigHit` (**0.15**) of that target's maxHP within
  1 s; report rate and size p50/p90; exclude fights < 20 s; provenance (n fights, seconds, zone,
  date, ± CI). "Use as preset" on one recording = its own timeline verbatim.
- Monte Carlo: `K = 30` replicates with `critMode = "roll"` and big-hit sizes sampled p50..p90,
  **only** for the three reported plans in synthetic mode; prints `P(floor violation)`.
- Utility in synthetic mode: `db.simUtilityPerFight` (default = median utility mana per fight
  from summaries once ≥ 5 exist, else 0), applied as one lump at t = 0.

---

## 10. Settings (all in `Options_General` panes via `MD.UI`; defaults; provenance in tooltips)

`recordFights = true`, `simFloor = 0.30`, `simReaction = 0.5`, `simMinActivity = 0`,
`simForeignShare = 0.25`, `simFullHp = 0.85`, `simBigHit = 0.15`, `simAllowRebinds = false`,
`simGateManaMean = 0.02`, `simGateManaMax = 0.05`, `simGateHpMean = 0.05`, `simGateHpMax = 0.15`,
`simUtilityPerFight = nil` (derived). New debug category `sim` (add to `Core.lua` defaults and
`UI/DebugConsole.lua`'s list; logs state transitions, per-run timing, the two assertions).

---

## 11. Open questions with defaults (do not block on these)

| question | default until answered | how it gets answered |
|---|---|---|
| refreshing a HoT early loses remaining ticks? | yes (`opts.refreshKeepsTicks = false`) | one refresh with the `heal` category on |
| Lifebloom bloom scales with stacks? | no | one 3-stack allowed to bloom |
| Swiftmend consumes which HoT first? | Regrowth | one cast with both up |
| failed-validation rows greyed or hidden? | greyed | author |
| raid tracking scope | subgroup + main tanks | author |
| Coach wall-clock | 10 s (≈ 300 evals) | author |
| rebind on a proven 15% saving? | no — binds fixed | author |

---

## 12. `.toc` additions (positions)

```
Engine\PullBudget.lua
Engine\FightRecorder.lua      (v0.7.2)   after Targets/Overheal/SpendTracker; before Summary consumers at call time
Data\SimFixture_BF1.lua       (v0.7.1)   after SpellData
Engine\SimModel.lua           (v0.7.1)   after RankMath, Calibration, ManaCooldowns
Engine\SimPlanner.lua         (v0.7.4)   after SimModel
Data\SimPresets.lua           (v0.7.7)   after SimModel
UI\Dashboard_Waste.lua
UI\Dashboard_Review.lua       (v0.7.6)   before UI\Dashboard.lua
UI\Dashboard.lua
UI\SimWindow.lua              (v0.7.7)   after OptionsFrame
```

---

## 13. Rejected — do not re-propose (from the judge)

Monte Carlo inside the search or on replay cards · the physical lower bound as a card number ·
foreign-heal bracket · DP / learned thresholds / per-phase plans · tank/other threshold split ·
blending measured overheal into scoring · fixed time step · a separate window at Review time ·
`minActivity > 0` default · all-or-nothing validation · 12- or 6-slot FIFO, ≥ 25 s / ≥ 8-cast
stream gate, per-zone quotas · cast→first-heal matching · N−1 held-out fitting · weighted scalar
objective · full-grid enumeration · downtime as the headline · marginal-quantile presets ·
3×-mean pulse detector · Coach-originated rebind toasts · blanket reaction delay on chained
casts · `utilityMp5` drip · conditioning v0.7.1+ on a behavioural test · `sniped` label ·
free-form labels or no `unclassified` · planning Innervate/potions/Tranquility in v0.7.

---

## 14. Checklist crosswalk (the judge's 28 items → where each is specified)

1 §3.3 · 2 §4.1 · 3 §4.2 · 4 §4.4 · 5 §4.2/§3.2 · 6 §2.1 · 7 §4.5 · 8 §2.3 · 9 §3.4/§3.7 · 10 §3.5 ·
11 §5.2/§3.6 · 12 §3.6 · 13 §5.1 · 14 §5.3/§6 · 15 §7 · 16 §2.2/§5.5 · 17 §5.7 · 18 §5.3/§6 ·
19 §8 · 20 §5.6 · 21 §3.8 · 22 §3.9 + `Data/SimFixture_BF1.lua` · 23 §3.1 · 24 §10 · 25 §10 ·
26 §12 · 27 §4.5 · 28 §0.
