# ManaDemon v0.7 — combat simulation: design and architecture

Find the cheapest healing strategy that keeps everyone alive in a described situation, and
say it in words a human can bind to five buttons.

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

Everything the simulator knows about a heal comes from `RankMath` — the same model
`Engine/Calibration.lua` is checking against reality. **The simulator is exactly as
trustworthy as the calibration table says the model is**, no more.

---

## 1. Scope

**In:**
- Party presets: solo · 2 · 3 · 5 · 10 · 25. Roles and HP by preset, from the live roster
  when in a group.
- Damage presets: AoE · one steady target (tank) · two steady targets · dungeon (one steady
  + one or two occasional). Per target: a constant rate and/or a periodic pulse.
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
damage spikes (pulses are periodic and deterministic); other healers' casts (assignment
stands in for them); movement, interrupts, threat; deaths cascading into more damage.
Crit is its **expected value**. §12 records what it would cost to bring each back.

---

## 2. Architecture

### 2.1 Files

| File | State | Role |
|---|---|---|
| `Data/SimPresets.lua` | **new** | Party / damage / situation presets, HP defaults per role and level |
| `Engine/SimModel.lua` | **new** | Scenario → event-driven simulation of one strategy → trace and score. **The only source of truth.** |
| `Engine/SimPlanner.lua` | **new** | The rule library, plan generation, the search |
| `UI/SimWindow.lua` | **new** | `/md sim`: Setup pane (presets + override table) and Result pane (rotation card, comparison, timeline) |
| `Engine/RankMath.lua` | **change** | `RankMath:SpellKit(ctx)` — per-spell numbers in the shape the simulator consumes; `Context(opts)` gains healer overrides |
| `Core.lua` | **change** | `/md sim`, `/md simreplay` |
| `Verify.lua` | **change** | `/md simreplay <fight>` — replay a logged fight's casts through the model (§8) |

### 2.2 Load order

```
...
Engine\RankMath.lua
Engine\Calibration.lua
Engine\PullBudget.lua
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
presets + overrides ----> Scenario ----------------------------+
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

**Damage.** `dps` is continuous and integrated exactly between events; `pulse` lands
`amount` every `period` seconds from `offset`. That is the whole damage model; "occasional"
is a pulse. **Deterministic by design** — §12.1.

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

---

## 6. `UI/SimWindow.lua` — `/md sim`

A separate Cell-style window (the dashboard is at 760px and five tabs; this needs its own
room), two panes on the top edge: **Setup** and **Result**.

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
party size. HP defaults are per level bracket, **assumed** until "use my group" has been
seen on a few real groups — the roster line from v0.6.1 already logs max HP, so the
defaults can be tuned from the same logs.

---

## 8. Validation — how we know the simulator is right

Three checks, in order of cost:

1. **One cast, one target, no damage.** The simulated heal must equal the dashboard row's
   heal to the unit; the mana drop must equal the row's cost. Runs on `/md simrun` as a
   self-test. **derived**, no in-game data needed.
2. **Chain-cast to OOM.** The simulated cast count from full mana must equal the To OOM
   column and the `/md spamtest` measurement (13 for Regrowth R9 in the regression log).
3. **Replay a real fight.** `/md simreplay` takes a logged fight's cast sequence (the
   `spend` lines carry spell and time) and runs the model with the *real* casts as the plan,
   then compares the simulated mana curve with the logged `mana` lines. The hard pull in
   `dungeon-BF-1.txt` (6.2k spent in 40s) is the first candidate. If the curves agree, the
   engine — regen, costs, 5SR — is right, independently of any strategy question. If they
   do not, the gap says which piece is off.

Check 3 is the one that matters, and it needs no new play: the logs already exist.

---

## 9. Data model and settings

Nothing persisted by default. `MD.db.simPresets` holds user-saved scenarios ("Save as
preset"): name → scenario, without healer overrides (those are always live unless typed).
`MD.db.simFloor` (0.30), `MD.db.simReaction` (0.3) remember the two knobs.

---

## 10. Delivery order

| version | contents | verifiable by |
|---|---|---|
| **v0.7.0** | `RankMath:SpellKit`, `Engine/SimModel.lua`, `/md simrun` self-test with a built-in scenario and a fixed plan, text report | §8 checks 1 and 2 pass from the command line |
| **v0.7.1** | `/md simreplay` on the BF-1 hard pull | §8 check 3: simulated vs logged mana curve, reported as max deviation |
| **v0.7.2** | `Data/SimPresets.lua`, `Engine/SimPlanner.lua` rule library, the three baselines, text card | the card for the built-in dungeon scenario reads sensibly |
| **v0.7.3** | the search (coroutine, coordinate descent, progress) | best plan beats both baselines on the built-in scenario |
| **v0.7.4** | `UI/SimWindow.lua` Setup + Result, "use my group", Copy card | the author runs it |
| **v0.7.5** | healer overrides, horizon "stable", `utilityMp5`, `minActivity`, Save as preset | — |
| **v0.7.6** | docs, TESTING, DECISIONS | — |

**v0.7.1 before any planner work is deliberate:** if the engine cannot reproduce a fight
that actually happened, optimizing over it is theatre.

---

## 11. Open questions, and what settles each

| question | settled by |
|---|---|
| Does refreshing Rejuvenation early lose the remaining ticks on this client? | one refresh with the `heal` category on: count the ticks |
| Does Lifebloom's bloom scale with stacks? (modelled: no) | one 3-stack allowed to bloom |
| Swiftmend consumes which HoT when both are present? (modelled: Regrowth first, as the client prefers) | one Swiftmend with both up |
| Realistic HP defaults per role and level | roster lines from the next groups |
| Does the sim's mana curve match the BF-1 hard pull? | `/md simreplay`, v0.7.1 |
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
8. **Replay validation before the planner exists.** Cheap, uses logs already on disk, and
   the only thing that makes "the simulator says" worth believing.
