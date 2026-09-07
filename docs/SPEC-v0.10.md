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
