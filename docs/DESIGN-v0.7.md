# ManaDemon v0.7 — combat simulation and fight review: design and architecture

Find the cheapest healing strategy that keeps everyone alive in a situation — **first and
foremost a situation that actually happened** — and say it in words a human can bind to
five buttons. Then show the healer the gap between that and what they did.

Status of every statement: **derived** = follows from code in the repo; **assumed** = a
modelling choice that needs in-game data; **decision** = a design call, listed in §12 with
the alternative.

---

## 0. What this is, in one paragraph

The dashboard answers *"which rank is most efficient?"* one spell at a time. It cannot
answer *"in a 5-man where the tank takes 450 dps and two DPS get hit every twelve seconds,
what should I actually cast, and how long can I keep it up?"* — because that depends on
the mix, on the HoT timing, on the 5-second rule, on how low you let people sit. The
simulator answers it by **running the fight**: a scenario (party, incoming damage, starting
HP), the player's real stats and spells, and a candidate strategy, stepped through
event by event. A **planner** proposes strategies from a small family that is
human-castable by construction, a **search** picks the cheapest one that keeps everyone
above a comfort floor, and the result is a short **rotation card** with its mana cost, its
time-to-OOM, and how it compares with "max rank everything".

**The primary input is a recorded fight, not a preset.** `Engine/FightRecorder.lua`
captures every hit the group took, every heal anyone else landed, the healer's own casts and
mana, and the HP snapshots — the fight as a scenario. Replaying it does two things a preset
cannot: it **validates the engine** against what really happened (the real casts must
reproduce the real mana and HP curves), and it **coaches** — the optimizer runs on the real
damage and the card reads *"you spent 6.2k; this would have spent 3.9k with nobody below
30%; the difference was five Regrowths on people above 80%"*. Over many fights the habits
accumulate into a short list. That loop — play, review, adjust, play — is the feature; the
synthetic presets are how you rehearse a situation you have not recorded yet, and they are
generated from recordings once those exist.

Everything the simulator knows about a heal comes from `RankMath` — the same model
`Engine/Calibration.lua` is checking against reality. **The simulator is exactly as
trustworthy as the calibration table says the model is**, no more.

---

## 1. Scope

**In:**
- **Fight recording**: damage taken and healing received per group member, the healer's
  casts and mana, HP snapshots — per fight, persisted with caps (§3b).
- **Review**: replay a recorded fight — validation (real casts, compare curves) and coaching
  (optimized casts, compare cost and the habits behind the gap).
- Party presets: solo · 2 · 3 · 5 · 10 · 25. Roles and HP by preset, from the live roster
  when in a group.
- Damage as a **timeline** (recorded, or synthesized from recordings) or **analytic** (a
  constant rate and/or a periodic pulse per target). Presets: AoE · one steady target ·
  two steady · dungeon (one steady + one or two occasional) · *from my last N fights here*.
- Situation presets: everyone full · everyone low · tank half, DPS at 10% · spread.
- Per-target overrides: max HP, current HP, damage rate, pulse.
- Healer overrides (default live): +healing, crit, mp5 casting/resting, mana pool, form.
- Horizon: 30s · 1:00 · 3:00 · 5:00 · until stable.
- **Assignment** — which targets *you* are responsible for. Raid presets are assignments
  ("tank healing in a raid" = you heal the tank, the raid is someone else's problem).
- Objective: everyone above a **comfort floor** (default 30%) at all times → minimize mana.
  If impossible: the plan that keeps them alive longest.
- Constraint: **≤ 5 buttons, ≤ 2 ranks per spell**, rules in the order humans heal
  (triage → maintenance → filler).

**Out, by the author's call**, to keep it tractable: party members' defensives; random
damage spikes in *synthetic* scenarios (pulses are periodic and deterministic — a recorded
fight has its real spikes); other healers' casts in synthetic scenarios (assignment stands
in; in a replay their heals are part of the recorded environment); movement, interrupts,
threat; deaths cascading into more damage. Crit is its **expected value**. §12 records what
it would cost to bring each back.

"Wait" is a first-class action throughout: in a non-heroic 5-man the less you drink the
faster the run goes, so not casting is often the *right* call, and the card says how much
of the time it was.

---

## 2. Architecture

### 2.1 Files

| File | State | Role |
|---|---|---|
| `Engine/FightRecorder.lua` | **new** | Per-fight capture: damage taken and healing received per group member, own casts, mana, HP snapshots. Persisted with caps. |
| `Data/SimPresets.lua` | **new** | Party / damage / situation presets, HP defaults per role and level, **presets synthesized from recordings** |
| `Engine/SimModel.lua` | **new** | Scenario → event-driven simulation of one strategy → trace and score. **The only source of truth.** |
| `Engine/SimPlanner.lua` | **new** | The rule library, plan generation, the search |
| `UI/SimWindow.lua` | **new** | `/md sim`: **Review** pane (recorded fights → validate / coach), Setup pane (presets + override table), Result pane (rotation card, comparison, bars) |
| `Engine/RankMath.lua` | **change** | `RankMath:SpellKit(ctx)` — per-spell numbers in the shape the simulator consumes; `Context(opts)` gains healer overrides |
| `Core.lua` | **change** | `/md sim`, `/md simreplay` |
| `UI/Summary.lua` | **change** | The single combat-log handler forwards group damage/heal events to the recorder; fight start/end bracket a recording |
| `Verify.lua` | **change** | `/md simreplay [n]` — replay recording *n* (or the last) through the model (§8) |

### 2.2 Load order

```
...
Engine\RankMath.lua
Engine\Calibration.lua
Engine\PullBudget.lua
Engine\FightRecorder.lua    <- new: Core + Targets; fed by UI/Summary.lua's handler
Data\SimPresets.lua         <- new
Engine\SimModel.lua         <- new: reads RankMath, SpellData, RegenModel at call time
Engine\SimPlanner.lua       <- new: reads SimModel
UI\Style.lua
...
UI\Dashboard.lua
UI\SimWindow.lua            <- new
...
```

### 2.3 Data flow

```
combat log --> FightRecorder --> recording --+--> Scenario (replay) ---+
presets + overrides ------------------------+--> Scenario (synthetic)  |
                                                                       v
RankMath:SpellKit(ctx) --> per-spell numbers ------------> SimModel:Run(scenario, plan)
RegenModel (live/override) --> regen rates ---------------/         |
                                                                    v
SimPlanner:Search(scenario)  <--- proposes plans, calls Run ---  trace, score
        |
        v
best plan + baselines --> UI/SimWindow (rotation card, comparison, timeline)
```

### 2.4 Two rules that shape everything

**The simulator never invents a heal number.** Every amount comes from
`RankMath:SpellKit`, which is `RowFor` reshaped: base, per-tick, bloom, cast time, cost,
duration, GCD. If calibration says Regrowth's direct is 3.7% high, the simulator is 3.7% high
too, and says so in its footer.

**The planner never emits a plan a human cannot cast.** The plan family is a fixed rule
order with a handful of parameters; the search varies the parameters. There is no "cast
R6 then R3 then R9 then R2" — not because it would not be optimal, but because nobody can
do it, and a plan nobody can do is not a plan.

---

## 3. The scenario

```lua
scenario = {
  horizon   = 180,                      -- seconds; or "stable"
  floor     = 0.30,                     -- comfort: nobody below this after the triage grace
  grace     = 6,                        -- seconds allowed to bring a low starter above the floor
  reaction  = 0.3,                      -- seconds between "should cast" and the cast starting
  utilityMp5 = 0,                       -- mana per 5s on dispels / rebuffs (the log's ~7%)
  targets = {
    { name = "Tank", role = "TANK",   maxHP = 9200, hp = 9200, dps = 450, pulse = nil, assigned = true },
    { name = "DPS1", role = "DAMAGER", maxHP = 6100, hp = 6100, dps = 0,
      pulse = { amount = 1500, period = 12, offset = 4 }, assigned = true },
    ...
  },
  healer = { heal = nil, crit = nil, casting = nil, base = nil, mana = nil, inTree = nil },  -- nil = live
}
```

**Damage** is one of two shapes, both just events to the simulator:
- **analytic** — `dps` is continuous and integrated exactly between events; `pulse` lands
  `amount` every `period` seconds from `offset`. "Occasional" is a pulse. Deterministic —
  §12.1.
- **timeline** — `events = { {t, target, amount}, ... }`, negative amounts being heals from
  *other* sources. This is what a recording is. It has the fight's real spikes, and other
  healers are in it for free.

A target's `hp` at t=0 comes from the recording's first HP snapshot, or the situation
preset.

**Party presets** (roles; HP defaults scale with the player's level, level-64 shown):

| preset | targets | tank HP | dps HP | notes |
|---|---|---|---|---|
| solo | you | — | — | Tree aura on nobody |
| 2 / 3 | you + 1–2 dps | — | 6100 | |
| 5 | tank, you, 3 dps | 9200 | 6100 | Tree aura on all |
| 10 | 2 tanks, 3 healers, 5 dps | 9200 | 6100 | assignment default: tank 1 |
| 25 | 3 tanks, 7 healers, 15 dps | 9200 | 6100 | assignment default: tank 1; "raid healing" = 5 dps |

In a group the roster replaces the preset: real names, classes, roles and **max HP** from
`UnitHealthMax`, so the setup is one click.

**Damage presets** (rates are starting points, all overridable):

| preset | pattern |
|---|---|
| tank steady | tank 450 dps |
| two steady | tank 450, off-tank 300 |
| dungeon | tank 450; dps 1 pulse 1500/12s; dps 2 pulse 1200/17s |
| aoe | everyone 120 dps; tank +330 |
| tank + aoe | tank 450, everyone else 90 dps |

**Situation presets:** full · everyone at 30% · tank 50% / dps 10% · spread (100/70/40/20).

### 3b. `Engine/FightRecorder.lua` — the fight as a scenario

Recording runs between `PLAYER_REGEN_DISABLED` and `PLAYER_REGEN_ENABLED`, off the same
combat-log handler everything else uses (`UI/Summary.lua`), which already unpacks every
event once:

| captured | from | stored as |
|---|---|---|
| damage taken by a group member | `SWING_DAMAGE`, `SPELL_DAMAGE`, `SPELL_PERIODIC_DAMAGE`, `RANGE_DAMAGE`, `ENVIRONMENTAL_DAMAGE` with `destGUID` in the roster | `{ t, target, amount }` (amount **after** absorbs/resists — what the HP actually lost) |
| healing received from anyone but the player | `SPELL_HEAL`, `SPELL_PERIODIC_HEAL` with `sourceGUID ~= player`, effective part | `{ t, target, -effective }` |
| the healer's own casts | `UNIT_SPELLCAST_SUCCEEDED` (the spend tracker already has spellID, cost, time) | `{ t, spellID, target }` |
| mana | the `mana` category's own samples | `{ t, mana }` every 2s |
| HP snapshots | `UnitHealth` / `UnitHealthMax` of every roster member at the pull, then every 5s and at the end | `{ t, hp = {...} }` |
| roster | `Engine/Targets.lua` at the pull | name, class, role, roleSource, maxHP |

Target of the player's own cast: `UNIT_SPELLCAST_SUCCEEDED` does not carry it on this
client, so the cast's target is taken from the **first heal event of that spell** that
follows within its cast time (+0.5s); unmatched casts are kept without a target and
flagged. **assumed** — the match rate is reported per recording.

**Caps.** A recording is kept only for fights ≥ 20s with ≥ 5 own casts (trash pulls are
noise). `MD.cdb.recordings` keeps the **last 12**, each capped at 4,000 events (a 3-minute
fight is ~1,500); older ones drop off. Numbers are stored as plain arrays, ~40 bytes an
event, so the cap is ~2 MB of SavedVariables at the very worst and typically a few hundred
KB. The recorder can be turned off (`db.recordFights`), and `/md export` gains a
`# recording` section so a fight can leave the game as TSV.

**What the BF-1 log cannot do.** It has casts and mana but no damage-taken lines (nothing
logged them), so replaying it validates regen, costs and the 5SR against the real mana
curve — but not HP. The first recorded fight is the first full replay.

---

## 4. `Engine/SimModel.lua` — the simulator

### 4.1 Event-driven, not stepped

Time advances to the **next event**: a cast finishing, a HoT tick, a pulse, a HoT
expiring, the 5-second rule lapsing, the horizon. Between events damage is linear, so
HP is integrated exactly; no time step, no quantization of a 1.68s Nature's-Grace cast.
Events live in a small sorted list (a fight has tens of pending events, not thousands).

```
loop:
  t_next = min over pending events
  for each target: hp -= dps * (t_next - t); clamp; if hp <= 0 -> death event
  t = t_next; apply the event (tick / pulse / cast landed / expiry / 5SR lapse)
  if healer free at t: ask the plan for an action -> schedule cast finish at t + castTime
     (or "wait": schedule a decision at the next event)
```

### 4.2 What a cast does (all from `SpellKit`)

| spell type | on landing |
|---|---|
| direct (Healing Touch) | `hp += direct × critEV` at cast end |
| HoT (Rejuvenation) | schedule `ticks` events of `tick` each; refresh replaces the timer, the remaining ticks are **lost** (real TBC behaviour — refreshing early wastes ticks) |
| hybrid (Regrowth) | direct now + HoT as above |
| Lifebloom | tick events at 1s; a recast on a live stack **adds a stack** (tick × stacks) and resets the 7s; expiry = bloom **once**, regardless of stacks |
| Swiftmend | consumes the target's Rejuvenation (12s of ticks) or Regrowth (18s), instant; 15s cooldown; needs a HoT present |
| Tranquility | channel: 4 ticks of `tick` on every **party** target; 10-min cooldown; caster form only |
| Innervate | +mana per `ManaCooldowns`' value; once per fight; cast only when the plan says |

Overheal is **endogenous**: healing above `maxHP` is lost. This is the mechanism the
measured overheal *approximates*; the simulator gets it for free from the HP cap. A footer
shows the simulated overheal next to the player's measured one (`Overheal:FamilyFraction`)
so a big gap is visible — it usually means the scenario is gentler than real play.

### 4.3 Mana

`mana -= cost` at cast start (as the client does). Regen per second = `casting` while
within 5s of the last cast start, else `base`; both from `RegenModel` (raw API + Dreamstate)
or the healer overrides. `utilityMp5` drains continuously. Cast times and Nature's Grace
come from `RankMath` (expected value, §12.1). Costs are live.

### 4.4 Output

```lua
result = {
  ok = true,                         -- nobody below the floor after grace, nobody dead
  manaSpent = 4120, manaEnd = 3890, oomAt = nil,       -- or the second mana first hit 0
  lowest = { name = "DPS1", hp = 0.31, t = 42.5 },
  deaths = {},                                          -- { name, t } if any
  overheal = 0.12,                                      -- simulated
  casts = 61, byFamily = { Lifebloom = 38, Rejuvenation = 19, Regrowth = 4 },
  waitFraction = 0.22,                                  -- share of time not casting
  timeline = { { t, mana, hp = {...} }, ... },          -- every 5s, for the strip chart
  sustainable = true,                                   -- mana/s <= regen in the last third
}
```

---

## 5. `Engine/SimPlanner.lua` — strategies a human can cast

### 5.1 The plan

```lua
plan = {
  binds = { "Lifebloom:1", "Rejuvenation:9", "Regrowth:7", "Swiftmend" },   -- <= 5
  rules = {                                                                 -- fixed ORDER
    { "swiftmend",   below = 0.35 },                     -- 1. anyone this low with a HoT: Swiftmend
    { "direct",      below = 0.45, spell = "Regrowth:7" }, -- 2. anyone this low: the direct heal
    { "roll",        target = "tank", stacks = 3 },      -- 3. keep Lifebloom xN on the tank
    { "hot",         below = 0.80, spell = "Rejuvenation:9" }, -- 4. anyone this low without it
    { "filler",      spell = nil },                      -- 5. nothing to do: wait (or a cheap HoT on the tank)
  },
}
```

The **order is fixed** — triage, then the tank's roll, then maintenance, then filler —
because that is how healers actually think, and a card that reads in that order is
memorable. The **search varies the parameters**: which ranks are bound, the two or three
thresholds, the stack count, and whether the filler is "wait" or a cheap HoT. Target
choice within a rule is deterministic: lowest HP fraction first, tank on ties.

**Why "wait" is a real action:** not casting for 5s ends the five-second rule and roughly
doubles regen for the author's build. The optimizer will discover that on light damage the
cheapest plan idles a lot. The card reports `waitFraction` plainly — "you can afford to
stop casting 22% of the time" is a finding, not a failure — and a `minActivity` knob exists
for players who know they will not idle.

### 5.2 Baselines, always evaluated

- **max rank everything** — what most people do
- **HoTs only, max rank** — the Tree druid default
- **the best plan found**

The card shows all three; the gap between the first and the third is the value of the
whole exercise, in mana.

### 5.3 The search

Candidate ranks per family are the dashboard's **known, non-dominated** ranks (already
computed by `RankMath:Compute` — typically 2–4 per family), so the rank space is small and
every candidate is one a human might reasonably bind. Thresholds come from a coarse grid
(`below` ∈ {0.3, 0.45, 0.6, 0.8}; stacks ∈ {1, 3}). That is a few hundred to ~2,000 plans.

One simulation of a 3-minute, 5-target scenario is ~700 events; a plan evaluates in
about a millisecond of WoW Lua. Two thousand plans is two seconds — too long to block a
frame, fine spread across frames. The search runs in a **coroutine resumed from
`OnUpdate`**, ~8ms per frame, with a progress line ("evaluating 640 / 1,840 plans"), and
**coordinate descent** (fix all but one parameter, sweep it, repeat) replaces the full grid
when the grid exceeds ~500 plans. Best-so-far is shown as it improves.

Score: invalid plans (a death, or below the floor after grace) rank by *time of first
violation*, latest first; valid plans rank by `manaSpent`, ties by fewer binds, then lower
simulated overheal.

### 5.4 Coaching: the difference between what you did and what it would have done

On a recording, three runs happen:

1. **Replay** — the real casts, on the real timeline. Must reproduce the real mana and HP
   curves (§8). Also yields the *actual* score: mana spent, lowest HP, overheal.
2. **Best plan** — the search, on the same timeline, same starting HP, same roster.
3. **Classification of your actual casts** against the best plan's rules, one label each:

| label | meaning |
|---|---|
| `fine` | the best plan would have cast the same spell, or one of the same rank, at about that time |
| `overheal` | landed on a target that was above the plan's threshold and took no damage within the HoT's duration |
| `rank` | right spell, a costlier rank than the plan binds |
| `spell` | a direct heal where the plan uses a HoT (or vice versa) |
| `early` | a HoT refreshed with ticks remaining |
| `idle` | the plan casts here and you did not (someone was below the floor) |

The card then reads:

```
Blood Furnace, pull 4 (0:40, 5 targets)                you: 6.2k   best plan: 3.9k   diff 2.3k
  overheal   5 casts, 2.3k   Regrowth R9 on Alkandari / Trecoda above 80%
  early      9 casts, 0.6k   Lifebloom refreshed with 2+ ticks left
  rank       0
  idle       0 -- you never left anyone under the floor
  Lowest HP: you 36% (Dëstroyka at 0:31), best plan 44%.
```

Over the last N recordings the labels are summed into **habits** — the three most
expensive, with their mana — and that list is what a healer can actually change between
runs. It is the whole point of recording.

---

## 6. `UI/SimWindow.lua` — `/md sim`

A separate Cell-style window (the dashboard is at 760px and five tabs; this needs its own
room), three panes on the top edge: **Review**, **Setup**, **Result**.

### 6.0 Review — the default pane

```
+-[ Review ][ Setup ][ Result ]------------------------------------- ManaDemon Sim -- x -+
| Recorded fights (last 12)                                            [x] record fights |
| #  when          zone            dur    targets  casts  spent   lowest   replay          |
| 1  today 21:14   Blood Furnace   0:40   5        19     6.2k    36%      mana ok, HP ok  |
| 2  today 21:12   Blood Furnace   0:37   5        16     3.7k    52%      mana ok, HP ok  |
| 3  today 20:58   Blood Furnace   2:47   5        42     8.2k    41%      mana +4%  HP ok |
| ...                                                                                     |
|                                              [ Validate ]  [ Coach ]  [ Use as preset ] |
|                                                                                         |
| Habits over these 12 fights (2.1 min healing):                                          |
|   overheal   31 casts   9.4k    Regrowth on people above 80%                            |
|   early      48 casts   3.1k    Lifebloom refreshed with ticks left                     |
|   rank        6 casts   0.9k    Rejuvenation R12 where R9 would do                      |
+-----------------------------------------------------------------------------------------+
```

`Validate` runs the replay and shows the mana/HP deviation; `Coach` runs the search on the
recording and opens Result with the diff card; `Use as preset` turns the recording into a
synthetic scenario (its per-target rates and pulses summarized, §7) that Setup can then
edit.

### 6.1 Setup

```
+-[ Setup ][ Result ]------------------------------------------------- ManaDemon Sim -- x -+
| Party   [ solo ][ 2 ][ 3 ][ 5 ][ 10 ][ 25 ]   [ use my group ]                          |
| Damage  [ tank steady ][ two steady ][ dungeon ][ aoe ][ tank + aoe ]                     |
| Start   [ full ][ everyone 30% ][ tank 50 / dps 10 ][ spread ]                            |
| Horizon [ 0:30 ][ 1:00 ][ 3:00 ][ 5:00 ][ stable ]      floor [ 30 ]%  reaction [ 0.3 ]s  |
|                                                                                          |
| Target        Role      Max HP    HP now   Damage/s   Pulse            Mine              |
| Tank          TANK       9200      9200      450       -                [x]              |
| Penek         HEALER     6304      6304        0       -                [x]              |
| Alkandari     DAMAGER    6100      6100        0       1500 / 12s       [x]              |
| Abufaisall    DAMAGER    6100      6100        0       1200 / 17s       [x]              |
| Trecoda       DAMAGER    6100      6100        0       -                [x]              |
|                                                                                          |
| Healer: +heal [ 531 ] crit [ 10.8 ] casting mp5 [ 88 ] resting mp5 [ 244 ] mana [ 6304 ] |
|         form [ live ][ caster ][ tree ]   utility mp5 [ 0 ]   min activity [ 0 ]%        |
|                                                                        [ Run simulation ] |
+------------------------------------------------------------------------------------------+
```

Every cell in the target table is an edit box (the Simulate strip's placeholder idiom:
grey = preset value, typed = override). "Use my group" fills names, roles, classes and max
HP from `Engine/Targets.lua` and `UnitHealthMax`. The healer row reuses the Simulate
strip's boxes and semantics — it is the same `MD.sim` idea, scoped to this window.

### 6.2 Result

```
+-[ Setup ][ Result ]------------------------------------------------- ManaDemon Sim -- x -+
| 5-man, dungeon damage, everyone full, 3:00                    evaluated 1,840 plans, 1.9s |
|                                                                                          |
| BEST                                   mana 4.1k   ends 61%   OOM never   lowest 31%     |
|   Bind: Lifebloom R1 | Rejuvenation R9 | Regrowth R7 | Swiftmend                         |
|   1. Anyone under 35% with a HoT on them: Swiftmend                                      |
|   2. Anyone under 45%: Regrowth R7                                                       |
|   3. Keep Lifebloom x3 rolling on the tank                                               |
|   4. Anyone under 80% without Rejuvenation: Rejuvenation R9                              |
|   5. Otherwise wait -- you can afford to stop casting 22% of the time                    |
|                                                                                          |
| Max rank everything                    mana 7.9k   ends 12%   OOM 2:35    lowest 44%     |
| HoTs only, max rank                    mana 5.6k   ends 38%   OOM never   lowest 27% !   |
|                                                                                          |
| mana  ####################################......................................  61%    |
| Tank  ################################################################..........  81%    |
| DPS1  ##############################........................................  38% at 0:42 |
|                                                                                          |
| Simulated overheal 12%; your measured Rejuvenation overheal is 45% -- the scenario is   |
| gentler than your dungeons. Model confidence: /md calibrate, 3 of 4 spells within 3%.   |
|                                                  [ Copy card ]  [ Save as preset ]        |
+------------------------------------------------------------------------------------------+
```

The bars are the Cell-style status-bar texture, one per assigned target plus mana — the
minimum reached and when, not a full chart. **Copy card** puts the text into the copy popup.

---

## 7. Presets are data (`Data/SimPresets.lua`)

```lua
SP.party    = { solo = {...}, five = {...}, ten = {...}, twentyfive = {...} }
SP.damage   = { tankSteady = function(targets) ... end, dungeon = ..., aoe = ... }
SP.start    = { full = ..., everyoneLow = ..., tankHalfDpsTen = ..., spread = ... }
SP.hpByRole = { TANK = { [60] = 7400, [64] = 9200, [70] = 12500 }, DAMAGER = {...}, HEALER = {...} }
```

Damage presets are functions of the target list so "aoe" means "everyone" whatever the
party size. HP defaults are per level bracket.

**Presets from recordings.** The hard-coded numbers are starting points; the author's
recordings replace them. `SP.FromRecordings(zone, n)` summarizes the last *n* recordings
in a zone per **role**: mean damage rate outside pulses, and pulses detected as any 2s
window taking more than 3× the mean (amount = the window's total, period = the mean gap).
The result is a damage preset with provenance — *"dungeon (from 12 Blood Furnace pulls,
2026-09-05)"* — and `Use as preset` on one recording does the same for one fight. The
hard-coded presets are also **updated by hand** from the author's logs over time, with the
date and source in the file, as the spell table is.

The roster line and HP snapshots from recordings settle the per-role HP defaults the same
way.

---

## 8. Validation — how we know the simulator is right

Three checks, in order of cost:

1. **One cast, one target, no damage.** The simulated heal must equal the dashboard row's
   heal to the unit; the mana drop must equal the row's cost. Runs on `/md simrun` as a
   self-test. **derived**, no in-game data needed.
2. **Chain-cast to OOM.** The simulated cast count from full mana must equal the To OOM
   column and the `/md spamtest` measurement (13 for Regrowth R9 in the regression log).
3. **Replay a real fight.** `/md simreplay` runs a recording with the *real* casts as the
   plan and compares the simulated **mana** curve with the recorded one (regen, costs, 5SR)
   and the simulated **HP** curves with the recorded snapshots (heal amounts, HoT timing,
   the damage timeline itself). Reported as max and mean deviation per curve; the Review
   pane shows `mana ok, HP ok` or the number. If mana agrees and HP does not, the heal
   model is off (and calibration should be saying so too); if HP agrees and mana does not,
   regen or a cost is. The hard pull in `dungeon-BF-1.txt` gives the mana half of this
   before any new fight is recorded.

Check 3 is the one that matters. A coaching card on a fight the engine could not replay
is not advice.

---

## 9. Data model and settings

`MD.cdb.recordings` — the last 12 qualifying fights, capped as in §3b; `db.recordFights`
(default on). `MD.db.simPresets` holds user-saved scenarios ("Save as preset"): name →
scenario, without healer overrides (those are always live unless typed). `MD.db.simFloor`
(0.30), `MD.db.simReaction` (0.3) remember the two knobs.

---

## 10. Delivery order

| version | contents | verifiable by |
|---|---|---|
| **v0.7.0** | `Engine/FightRecorder.lua` + the handler forwarding + `/md export` section | a recorded fight appears in `/md export`; event counts and the cast→target match rate look sane |
| **v0.7.1** | `RankMath:SpellKit`, `Engine/SimModel.lua` (timeline + analytic damage), `/md simrun` self-test, `/md simreplay` | §8 checks 1–2 from the command line; check 3 on the BF-1 mana curve, then on the first recording |
| **v0.7.2** | `Engine/SimPlanner.lua` rule library, baselines, cast classification, text card | the coaching card for a recording reads sensibly |
| **v0.7.3** | the search (coroutine, coordinate descent, progress); habits over N recordings | best plan beats both baselines on a recording |
| **v0.7.4** | `UI/SimWindow.lua` Review pane (list, Validate, Coach) + Result | the author reviews a real pull |
| **v0.7.5** | `Data/SimPresets.lua` hard-coded + `FromRecordings`, Setup pane, "use my group", healer overrides, Save as preset | a synthetic scenario runs |
| **v0.7.6** | horizon "stable", `utilityMp5`, `minActivity`, docs, TESTING, DECISIONS | — |

**Recording first, engine second, planner third, synthetic last.** Recording needs a few
dungeon runs to accumulate material, so it ships first and gathers while the rest is built.
**The engine is validated before any planner work:** if it cannot reproduce a fight that
actually happened, optimizing over it is theatre.

---

## 11. Open questions, and what settles each

| question | settled by |
|---|---|
| Does refreshing Rejuvenation early lose the remaining ticks on this client? | one refresh with the `heal` category on: count the ticks |
| Does Lifebloom's bloom scale with stacks? (modelled: no) | one 3-stack allowed to bloom |
| Swiftmend consumes which HoT when both are present? (modelled: Regrowth first, as the client prefers) | one Swiftmend with both up |
| Realistic HP defaults per role and level | roster lines from the next groups |
| Does the sim's mana curve match the BF-1 hard pull? | `/md simreplay`, v0.7.1 |
| Does `UNIT_SPELLCAST_SUCCEEDED` carry the target on this client (it should not)? Match rate of cast→first-heal otherwise | the recorder reports it per fight |
| Is `amount` on `SWING_DAMAGE` after absorbs on this client? | the first recording's HP replay: a systematic HP overshoot means absorbs are being double-counted |
| Recording size in practice | `/md profile` reports the recordings' event counts |
| Is a plan's `waitFraction` something the author will actually do? | ask, after seeing a few cards |

---

## 12. Calls worth arguing about before implementing

1. **Deterministic expected value, not Monte Carlo.** Crit at EV, pulses on a fixed period.
   MC would give "probability of a death" instead of "nobody dies", at ~50× the cost, and
   random spikes are what the author asked to omit. EV first; a `jitter` knob on pulses
   later if the cards feel too clean.
2. **Rule-based plans, not optimal control.** A dynamic program over (HP × HoT state × mana
   × time) is intractable and would emit sequences nobody can cast. The rule family is the
   human-castable constraint made structural; its cost is that the true optimum may lie
   outside it. The baselines show how much the family is worth; if a hand-written plan ever
   beats the search, the family needs a rule, not the search a fix.
3. **Overheal endogenous (HP cap), not the measured fractions.** The cap is the mechanism;
   the measured fraction is reality's messiness on top (pre-casting, other healers). Using
   both would double-count. Show the two side by side instead.
4. **Other healers via assignment, not simulated.** "Tank healing in a raid" = you and the
   tank. Simulating six other healers' policies is a different, larger project.
5. **Event-driven, not time-stepped.** Exact integration and no cast-time quantization, for
   slightly more code.
6. **A separate window, not a sixth dashboard tab.** The setup table alone is taller than
   the dashboard's row area.
7. **"Wait" as a first-class action, reported not hidden.** The optimizer will idle; the
   card should say so rather than pad with casts. `minActivity` is the escape hatch.
8. **Replay validation before the planner exists.** Cheap, and the only thing that makes
   "the simulator says" worth believing.
9. **Other healers are environment in a replay, assignment in a synthetic scenario.** In a
   recording their heals are just negative damage on the timeline, so the optimizer never
   pretends to control them; the alternative — simulating their policies — is a different
   project. The seam between the two modes is that both are "events on a timeline".
10. **Recordings are capped hard (12 fights, 4,000 events each) rather than kept forever.**
    Habits are computed over what is kept; a longer memory would need a summary format. A
    fight can be exported before it drops off.
11. **The coaching labels are a fixed small set**, not free-form. Six labels a healer can act
    on beat a per-cast novel; if a real inefficiency does not fit one, the set grows by one.
