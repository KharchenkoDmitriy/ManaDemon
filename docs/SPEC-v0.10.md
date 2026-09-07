# ManaDemon v0.10 — the casts that are not heals: implementation spec

**This is the document to implement from.** v0.10 answers one thing the author raised on
2026-09-07, looking at three solo recordings the engine refused to coach from:

> "I'm not sure 90% mana spent on heals is right. The fight may not be heavy on incoming damage
> and I can assist the damage dealers. I may also cast a lot of CC (Cyclone), which reduces
> incoming damage by a lot. We should not add CC and damage abilities to coach suggestions — too
> situational. But we could: check when casting damage abilities breaks the 5s rule and leaves
> too little mana for healing later; and treat CC casts as necessary at that moment, so they are
> in the record and in the coach variant at the same place."

Both halves are right, and the second one is not a nicety: it is what makes the comparison
honest at all. Read first: `docs/SPEC-v0.7.md` §5–§7, `Engine/SimModel.lua`
(`ScenarioFromRecording`, `Validate`, the run loop's scripted-cast cursor), `Engine/SimPlanner.lua`
(`RunPlan`, `Score`, `Classify`, `Card`), `docs/DECISIONS.md` §v0.7.

Conventions as always: Lua 5.1, no libraries, `pcall` around uncertain API, ASCII-only rendered
strings with no bare `|`, `.toc` order, all eight suites green before every commit
(`simcheck reccheck simwindow regencheck replaycheck replayui runcheck reviewui`),
`make release SRC=<worktree>`, merge to local master after each version.

---

## 0. Why the gate was wrong

`spend coverage` fails all three of the author's recordings (0%, 69%, 67%). Its stated purpose
is "the engine can reproduce this fight", and for the **mana curve** that purpose is already
served without it: the recorder stores each cast's real cost, so a replay reproduces the mana
even for spells the model has never heard of. Recording 2 sits at **1.0%** on the mana gate with
a third of its spend unpriced.

What the gate was standing in for is the **plan** side. `SP.RunPlan` removes `scenario.script`
before running a plan, so the simulated healer never casts the Moonfires, the Insect Swarms or
the Entangling Roots — it starts with that mana in hand and takes exactly the same incoming
damage. In recording 2 that is 2043 mana of free money, 31% of the fight's spend, and any card
built on it flatters the plan for spending less than a healer who never had to press anything.

A 90% threshold cannot fix that. Fixed points can.

---

## 0b. Delivery order (revised 2026-09-07, after §6b shipped first)

| version | ships | state |
|---|---|---|
| **v0.10.0** | §6b: the deficit priced as mana, the measured danger line, rule 4 casting the HoT that fits | **done** |
| **v0.10.1** | §2: the addon knows what it cast — the seed table, `MD:ClassifyCast`, the learned `cdb.spellbook`, per-stream names | |
| **v0.10.2** | §3: fixed points — non-healing casts happen in both columns; coverage counts what the engine reproduces | |
| **v0.10.3** | §4: what the damage casts cost, in mana and in five-second-rule regen | |
| **v0.10.4** | §6c: several strategies from one search, and the author picks | |

§6b shipped first because it was what the author kept seeing in the replay window; the rest
follows the original order.

## 1. Decisions this spec encodes (author, 2026-09-07)

1. **CC and damage never enter the plan's decision rules.** A Cyclone is not triggered by party
   health and trailing damage, and a plan that pretended otherwise would be confidently wrong.
2. **Every non-healing cast is a FIXED POINT**: it happens in the suggested column at the same
   moment, at the same cost, taking the same global cooldown and restarting the same
   five-second rule. The plan decides around them, never instead of them.
3. **Damage casts are fixed too, not optional.** If the plan could skip a Wrath it would pocket
   the mana while the fight still ended at the same second, because the recording's length
   already contains the effect of that damage. The same argument as the Cyclone: the damage you
   took is the damage you took *because* you rooted the thing. Dropping either makes the
   recording internally inconsistent.
4. **What the coach says about damage casts is their price, not a verdict**: mana spent plus
   spirit regen lost to the five-second rule they restarted, and whether that left too little
   for healing later.
5. **Spell identity comes from the client, never from memory.** Ids seeded from the TBC database
   are marked VERIFY until a recording proves them; the recorder learns names from
   `GetSpellInfo` as it sees them.

---

## 2. v0.10.0 — the addon knows what it cast

### 2.1 The seed table (`Data/DruidSpells.lua`)

Non-healing druid casts, keyed by spell id, with a family and a kind. Seeded from the TBC
database on 2026-09-07 and **corroborated against the author's own recordings**: four of the
five ids reproduce their recorded mana cost exactly, three of them only after Moonglow's -9%
is applied, which is a stronger check than a database lookup on its own.

| id | family | kind | base cost | recorded | check |
|---|---|---|---|---|---|
| 26987 | Moonfire (r11) | damage | 430 | 391 | 430 x 0.91 (Moonglow 3) = 391 |
| 25298 | Starfire | damage | 340 | 309 | 340 x 0.91 = 309 |
| 24977 | Insect Swarm | damage | 155 | 155 | Moonglow does not touch it |
| 9853 | Entangling Roots | cc | 125 | 125 | Moonglow does not touch it |
| 17329 | Nature's Grasp | cc | 0 | 0 | free, as recorded |
| 33786 | Cyclone | cc | 8% of base | - | VERIFY: not yet in a recording |

`kind` is one of `damage`, `cc`, `utility`. A wrong kind costs a label and a fixed-point
category, never a number — the cast's own cost is the recorded one either way. Every row is
`-- VERIFY` until it has been seen in a recording with a cost that matches.

### 2.2 The addon learns the rest

`GetSpellInfo(id)` names any spell in the client, so the table does not have to be complete:

- `MD:ClassifyCast(spellID)` → `family, kind`. Order: the healing kit (`Data/SpellData.lua`)
  first, then `Data/DruidSpells.lua` by id, then a **name table** (enUS families:
  Moonfire / Starfire / Wrath / Insect Swarm / Hurricane / Faerie Fire = damage; Entangling
  Roots / Nature's Grasp / Cyclone / Hibernate / Soothe Animal / Bash / Maim = cc; Mark of the
  Wild / Gift of the Wild / Thorns / Innervate / Rebirth / Remove Curse / Abolish Poison /
  Nature's Swiftness / Barkskin = utility), then `unknown`.
- Whatever it resolves is **written back** into `cdb.spellbook[id] = { name, family, kind }`,
  so the map grows from the client rather than from a website, and the offline tools inherit it.
- `Engine/FightRecorder.lua` stores a per-stream `names = { [id] = "Moonfire r11" }` for every
  id it records, so a recording is readable without the client. A few dozen bytes.

### 2.3 `/md verify` and the tools

`/md verify`'s "unpriced spells seen this session" line becomes "spells outside the healing
model", grouped by kind, with the ids — the author's list to correct. `tools/import.lua` prints
the same grouping for a recording, so a `-- VERIFY` row can be settled offline.

---

## 3. v0.10.1 — fixed points in the engine

### 3.1 The scenario carries two scripts

`SM.ScenarioFromRecording` splits the recorded own-casts:

```lua
scenario.script = { <casts the healing kit knows> }        -- the plan replaces these
scenario.fixed  = { {t, spellID, cost, tgt, castTime, kind}, ... }  -- the plan works around these
```

`SP.RunPlan` keeps dropping `script` and now **keeps `fixed`**. A replay (no plan) runs both, in
time order, exactly as today's single script does — the split changes nothing about a replay.

### 3.2 What a fixed cast does in the loop

At its recorded time: its recorded cost leaves the pool, the five-second rule restarts, the
healer is busy for `castTime` (from the recording's `CAST_START`/`SUCCESS` pair when there is
one, else the 1.5 s global cooldown), and nothing is healed. A second cursor beside the script
cursor; no new event kinds.

**A fixed cast preempts the plan.** If the plan has a cast in flight when a fixed cast arrives,
the plan's cast is **cancelled**: no mana spent, the time is lost. That is what actually happened
— the healer interrupted themselves to press it — and the alternative (delaying the fixed cast
until the healer is free) moves a recorded event, which the replay is not allowed to do. The
rejected third option is letting the plan see the fixed cast coming: that is clairvoyance and
breaks the causality invariant.

### 3.3 The gate becomes what it always meant

```
spend coverage = (mana the healing kit prices + mana replayed as fixed points) / total spend
```

Everything the engine reproduces counts, whichever way it reproduces it. `unknown` casts still
do not: a cast nobody can classify is a hole, and the gate is there to notice holes. On the
author's three recordings this goes 0% / 69% / 67% -> 100%, and they become coachable without
`force`.

### 3.4 The suggested column shows them

In the replay window both columns cast the fixed points, at the same moments, in a distinct
colour (not a healing family colour), with the kind in the status strip. Seeing the plan work
around your Cyclone is the whole point of putting it there.

---

## 4. v0.10.2 — what the damage casts cost

### 4.1 The measurement

`SM.CostOfCasts(rec, kit, kinds)` runs the recorded script **twice**: once complete, once with
the casts of the given kinds removed, and reports the difference:

- `mana` — the casts' own cost;
- `regen` — spirit regen lost because those casts restarted the five-second rule (the exact
  difference between the two runs, not a per-cast estimate: a heal a second later would have
  restarted it anyway, and only the two-run difference knows that);
- `lowest` — how much lower the mana floor got;
- `oom` — whether the fight reaches the OOM line in one run and not the other.

The counterfactual is stated wherever it is shown: **the fight would not have been the same
fight without them** — the mob lives longer, the damage timeline changes. The number answers
"what did pressing this cost my mana", not "should I have pressed it".

### 4.2 On the card

```
  damage casts: 8 for 2043 mana + 310 lost to the five-second rule = 2353 (35% of the fight)
                3 landed under 40% mana; without them your floor is 61% instead of 18%
  cc casts:     2 for 250 mana - kept as they were, in both columns
```

### 4.3 On the replay strip

A damage cast that restarts the five-second rule while mana is under `db.simFloor` gets a mark
on the scrubber and a label under the cast, the way the classifier's labels already work.

---

## 5. Harness

- `reccheck`: the classifier resolves a scripted Moonfire and Entangling Roots to
  `damage` / `cc`; the stream carries their names.
- `replaycheck`: a scenario built from a recording with non-healing casts has them in `fixed`
  and not in `script`; a plan run spends their mana at their times; a plan cast in flight when a
  fixed cast arrives is cancelled and costs nothing.
- `simcheck`: `CostOfCasts` on the BF-1 fixture with an injected damage cast returns exactly the
  cast's cost plus the regen difference between the two runs.
- `runcheck`: the chain's coverage counts fixed points.

## 6. In-game (docs/TESTING.md §33)

Record a solo pull where you DoT, root and heal yourself. It should now validate on spend
coverage, Coach should be enabled without forcing, and the card's `damage casts` line should
name a number you recognise. Report any spell that comes back `unknown` with its id.

---

---

## 6b. v0.10.3 — the deficit you still owe, and the danger line you measure

Raised by the author on 2026-09-07, from a forced replay whose suggested column spent 674 mana
and ended at 45% health where they had spent 3.9k and ended at 79%:

> "I don't want to force it to overheal, but I want it to find the optimal way to keep HP as
> high as possible while not overhealing. If the incoming biggest hit is small we can keep HP
> lower — but the same applies to: if we have enough mana for the future and we will anyway need
> to heal this HP loss, better to do it before than after."

### 6b.1 Why the plan under-heals today

The score gives health above `db.simFloor` (a flat 30%) **exactly zero value**, so the cheapest
plan that stays above it wins. On that fight the search found rules 1, 2, 4, 5 with Lifebloom
bound and never cast, and rule 5 reading "otherwise wait — 95% of the fight". It was not
choosing Rejuvenation over Lifebloom on the merits; it was choosing to heal as little as it
could get away with. The three baselines all spend 3.1k and hold 93%.

### 6b.2 The deficit is a debt, not a saving

The author's rule stated as an invariant: **health missing at the end of a fight is mana you
have not spent yet.** So charge for it.

```
manaOwed = cost of healing the remaining deficit with the most efficient bound spell
score's mana term = manaSpent + manaOwed
```

- A plan that leaves a target at 45% is charged what fixing it will cost, so it stops looking
  cheap. A plan that heals it during the fight pays the same mana and gets the safety for free.
- Nothing is earned above `db.simFullHp`: there is no deficit there, so no plan is pushed into
  overheal. This is "as high as possible while not overhealing" with a unit, not a weight.
- The efficient spell is used for the estimate because it is the cheapest way the debt *could*
  be settled — a lower bound, which is the conservative direction for a term that penalises.
- HoT ticks still pending at the end are healing already paid for and reduce the deficit before
  it is priced.

### 6b.3 The danger line is measured, not assumed

`db.simFloor = 0.30` becomes a fallback. The line that matters is **one hit from death**:

```
danger[i] = (largest single hit target i took in this fight) / maxHP[i]   -- p90 if > 8 hits
dangerSeconds = seconds a live tracked target spent below danger[i] * db.simDangerHits
```

`db.simDangerHits` ships at 1. On the author's fight the biggest hit was 371 against 5053 health
(7%), so 45% is six hits from death and the plan was not being reckless *there*. In a dungeon
where the tank eats 2.5k of 8k, one hit kills below 31%, and the same rule punishes the same
plan hard. Same score, fight-aware, nothing hard-coded. `floorSeconds` keeps its name and its
place in the tuple; only how the line is computed changes, and the card prints the line it used.

### 6b.4 The HoT rule may bind Lifebloom

Rule 4 hard-codes Rejuvenation, so no plan expressible today can say "put a Lifebloom on whoever
is hurt and let it bloom" — which on the author's gear is the most efficient heal in the book:

| spell | heal per mana |
|---|---|
| Lifebloom, left to bloom | 6.17 |
| Regrowth R9 | 5.17 |
| Rejuvenation R12 | 4.72 |
| Lifebloom, rolled and refreshed | 2.55 |

The bloom is 797 of Lifebloom's 1357: let it bloom and it is the best thing available, refresh it
and it is the worst. Rule 4 takes a bound family (`hotBind`, default Rejuvenation) exactly as
rule 2 chooses between Regrowth and Healing Touch, and the search may set it. Rule 3 (rolling on
the anchor) is unchanged and remains a different play with a different cost.

### 6b.5 In a run

The single-fight terms above are the approximation. The run has the real currency: ending a pull
low costs **eating time** before the next one, measured the way v0.9.1 measures the drink rate
(the same buff family, the same first-to-last-tick estimator). `SM.ChainRun` gains `eatTime`
beside `drinkTime`, and the run score ranks it with the other time terms rather than with mana.

### 6b.6 Harness

`simcheck`: a plan that ends with a target at 50% and mana in the bank must score worse than one
that spends that mana to top them up, and neither may be beaten by one that heals past
`simFullHp`. `replaycheck`: the measured danger line on the BF-1 fixture is the fixture's own
biggest hit, not 30%.

---

## 6c. v0.10.4 — several strategies, and the author picks

> "Make a few different coach strategies which we simulate at the same time and then pick the one
> based on the result (the least dead, the most HP healed, the least mana used, the most mana
> regenerated) — or we can even allow the user to select and look at different ones, to pick the
> one he likes the most."

This is the honest alternative to inventing a weight. A lexicographic tuple already refuses to
blend deaths, health and mana; showing the **corners of the trade-off** and letting a human pick
is the same refusal, made visible.

### 6c.1 It is free

`SP.Search` already evaluates up to 300 plans and keeps every one of them in `seen`. Picking the
best under a different objective is a scan of that table: **no extra simulation at all**. One
search, N winners.

### 6c.2 The objectives

Each is a lexicographic tuple over the same run result. Deaths lead every one of them: no
objective may trade a corpse for anything.

| key | name | tuple |
|---|---|---|
| `safe` | Safest | deaths, dangerSeconds, deficitArea, mana |
| `health` | Highest health | deaths, deficitArea, dangerSeconds, mana |
| `cheap` | Least mana | deaths, dangerSeconds, mana, deficitArea |
| `regen` | Most regen realised | deaths, dangerSeconds, -manaEnd, deficitArea |

- `deficitArea` is new and cheap: the time-integral of missing health over living tracked targets,
  as a fraction-second. "Most HP healed" as a statistic that cannot be gamed by overhealing —
  healing a full target adds nothing to it.
- `regen` maximises the mana actually in the pool at the end, which rewards *spacing* casts out
  of the five-second rule rather than simply casting less; `cheap` minimises what left the pool.
  They are different plans and the author asked for both.
- `mana` is v0.10.0's `manaSpent + manaOwed` throughout, so no objective can win by leaving the
  group hurt.

### 6c.3 What the author sees

The card gains a block, one row per strategy, with the numbers that separate them:

```
  strategies (one search, four ways of reading it)
    safe      1.6k mana   floor 71%   0.0s in danger   ends whole
    health    2.2k mana   floor 84%   0.0s in danger   ends whole
    cheap     1.1k mana   floor 49%   0.0s in danger   owes 0.3k
    regen     1.4k mana   floor 62%   0.0s in danger   ends whole, 1.1k more mana
  the same plan won three of them: safe = health = regen
```

Identical winners are collapsed rather than repeated: often two objectives agree, and saying so
is more useful than printing the same row twice.

### 6c.4 Picking one

`SP.strategies[rec.id]` holds the winners. `/md coach 1 health` (or `safe` / `cheap` / `regen`)
makes that one the plan the replay's suggested column draws, exactly as the overall winner is
today. In the replay window, a row of strategy buttons beside the SUGGESTED title switches the
column between them **without re-searching** — the traces are rebuilt from the cached plans.

The default winner stays `cheap`+ the standing tuple, so nothing changes for anyone who does not
touch it.

### 6c.5 Harness

`replaycheck`: four winners come out of one search; every objective's winner beats every other
plan in the pool *under its own tuple*; no objective ever prefers a plan with more deaths; the
collapse of identical winners is by plan identity, not by score.

## 7. Rejected and reserved

### Rejected (do not re-propose)

- **CC or damage in the plan's rules.** The author's call and the right one: the trigger for a
  Cyclone is not in the data the plan is allowed to see.
- **Letting the plan skip recorded damage casts.** Free mana against an unchanged damage
  timeline.
- **Dropping the spend-coverage gate.** A cast nobody can classify is exactly the hole it was
  built to notice; it now counts what the engine reproduces instead of what the healing kit
  prices.
- **Guessing spell ids from memory.** Seeded from the database, checked against recorded costs,
  marked VERIFY until a recording proves them.

### Reserved

- **A plain weight on health.** A weight with no unit means "heal more", and the plan satisfies
  it by overhealing. Every health term in 6b has a unit: mana it will cost, seconds below the
  line, seconds of eating.
- **Kill-speed modelling** (how much shorter the fight was because you cast Starfire). It needs
  target health, which the recorder does not keep for mobs.
- **CC as a damage-prevention term**, i.e. crediting a root with the damage that did not happen.
  Unmeasurable from one log.

## 8. Author questions with defaults

| question | default until answered |
|---|---|
| a fixed cast preempts an in-flight plan cast, or delays | preempts, cancelling the plan's cast |
| utility casts (Mark of the Wild) fixed too | yes, same rule, same reason |
| show fixed points in the suggested column | yes, in their own colour |
| `unknown` casts count towards coverage | no |
| the mana term includes the deficit left behind | yes (6b.2) |
| the danger line is the fight's biggest hit | yes, `db.simDangerHits` = 1 (6b.3) |
| rule 4 may bind Lifebloom | yes, `hotBind` (6b.4) |
| which strategy is the default | `cheap`, the standing tuple (6c.4) |
| strategies for a run as well as a fight | yes, same objectives over `ChainRun` |
