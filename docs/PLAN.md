# ManaDemon — plan (from 2026-09-03)

Two phases. Phase 1 finishes and hardens the druid experience on the author's own
character, where everything can be measured. Phase 2 opens the dashboard to other
classes, where testing is harder (no alts), so it is built on verified generic parts.

Status legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[?]` needs in-game data.

**Design for everything below in §1b/§1c/§1d: `docs/DESIGN-v0.5.md`** (architecture,
formulas, UI mockups, delivery order v0.5.0–v0.5.5). **All of §1b, §1c and §1d shipped in
v0.5.0–v0.5.4**; the calls made along the way are recorded in `docs/DECISIONS.md` §v0.5.
What remains in Phase 1 is §1a: the author's in-game logs (`docs/TESTING.md` §5, §8, §9,
§10), which confirm three model assumptions and tune the clock's constants.

## Phase 1 — druid, verify and improve

### 1a. Close the open verification items (cheap, needs the author in-game)
- [x] **Tree of Life aura on heals** — confirmed: +25% Spirit acts as +healing on the
  target (dynamic, HoTs already running gain it). Model unchanged.
- [x] **Empowered Rejuvenation on the Lifebloom bloom** — confirmed yes; applied.
  Lifebloom coefficients 0.5187 / 0.3422 confirmed exact.
- [x] **Relic slot** — author confirmed the idol; `SD.relics` reads slot 18. Other idols
  still VERIFY as they get equipped.
- [?] **Heal values for unlearned ranks** (`-- VERIFY` in `Data/SpellData.lua`): read the
  spellbook tooltips as ranks are learned (65–70); freeze the table.
- [x] **Heal-side percent stacking** (Gift of Nature + Improved Rejuvenation): with the
  relic confirmed the data fits multiplicative (1.265). Kept.
- [?] **Clock constants** `K_SIGMA` / `CV_STABLE` (`Engine/TTO.lua`): one logged real
  fight (`TESTING.md` §5). Judge: was the shown OOM time honest, jumpy, pessimistic?

### 1b. Model improvements (already justified)
- [x] **Nature's Grace** as an expected-value cast-time term — shipped in v0.5.1 as the
  exact mixture `(1−p)·T0 + p·max(T0−0.5, 1.5)` (the floored form clips the wrong branch
  at the GCD); grey `*` in the Cast column, derivation in the row tooltip. The 0.5s is
  [?] until the new `cast` debug category confirms it in-game.
- [x] **Innervate-aware clock** — shipped in v0.5.2 via `Engine/ManaCooldowns.lua`, which
  now owns every mana source (Innervate, potions, Phase 2 class stubs) and the one value
  model the clock AND the advisor read. `inn 2:10` takes the secondary segment under 90s.
  [?] the "400% on the spirit share only" split, until the `regen` log around one Innervate.
- [x] **Overheal-calibrated HPM** — v0.5.3 (`Engine/Overheal.lua`): amount-weighted, per
  family and per rank, 150-event half-life, 40-event gate, persisted per character. An
  "Effective" toggle on the dashboard; the Pareto filter and suggested rank stay on raw
  values on purpose (`docs/DECISIONS.md` v0.5 §3).
- [x] **Persist fight history** — v0.5.3: last 20 in `MD.cdb.fights` with zone and heal
  totals; the pull-time seed prefers same-zone fights, which is the "last time here"
  reference.

### 1c. UX
- [x] **Per-row tooltips on the dashboard** — v0.5.4, via `RankMath:Explain()`; the header
  row hovers to a column glossary (which also fixed the hint paragraph wrapping onto the
  table).
- [x] **Simulate strip: Tree form toggle and Moonglow rank box** — v0.5.4, on a second
  row; costs fall back to the static table while either is overridden.
- [x] **One tooltip builder** — v0.5.0 (`UI/Tooltip.lua`); the widget gained a hover
  tooltip it never had.
- [x] **`/md profile`** — v0.5.4; opens the copy popup, shares `MD:Snapshot()` with
  `/md verify`.

### 1d. Housekeeping
- [x] Commit v0.4.6, remove the stale worktree.
- [x] Split `UI/Dashboard.lua` into `_Rows` (columns, pool, rendering) and `_Simulate`
  (the what-if strip) — v0.5.0.

## Phase 1.5 — from the first real dungeon log (v0.6)

`dungeon-BF-1.txt` (Blood Furnace, 28.8 min, 30 pulls) produced both a bug and a change of
emphasis: the author's mana problem is **waste, not running out** (38% overheal, 561 fully
wasted ticks, never below 36% mana except once). Design and architecture:
**`docs/DESIGN-v0.6.md`**; the calls are in `docs/DECISIONS.md` §v0.6.

- [x] **v0.6.0** HP5 **removed** (author: no new insight — it orders like HPM); the `OOM 0s`
  false alarm; digits gated on `sigma/net` (0.7, a slider, provenance in its tooltip);
  default view from usage; advisor names the richer cooldown it is holding.
- [x] **v0.6.1** `Engine/Targets.lua` (roster: class + role, read not inferred) and richer
  logs — snapshot on Copy, roster at each pull, shown-string changes, cooldown use.
- [x] **v0.6.2** `Engine/Calibration.lua` — the model checks itself against every heal
  landed, and reports drift. **Top priority:** stats, content and spec all change.
- [x] **v0.6.3** Waste view — overheal by spell / role / class / target, wasted mana, and
  the per-fight spend breakdown (~7% of mana is currently invisible).
- [x] **v0.6.4** Lifebloom rolling-vs-bloom economics; Life Tap detection.
- [x] **v0.6.5** `Engine/PullBudget.lua` — "2 more pulls, or 4 after a drink".
- [x] **v0.6.6** docs, TESTING §0b/§11–§14 for the new surface (`/md export` shipped in v0.6.1).
- [ ] **D2** Cell integration — investigation brief only (`docs/DESIGN-v0.6.md` §13).

**Caveat carried through all of it:** that log was a level 61 dungeon on a level 64 druid.
Heroics and raids differ. No constant from it is hard-coded.

## Phase 1.7 — fight recording, replay, coaching, simulation (v0.7)

Design `docs/DESIGN-v0.7.md`, debated (`docs/debates/v0.7-sim/`), decided (`docs/DECISIONS.md`
§v0.7), specified for implementation in **`docs/SPEC-v0.7.md`**. Order is fixed; each step is
one commit with its "verifiable by" line in the spec §0.

- [x] **v0.7.0** HP-at-cast + cost + form on every own cast; 20 s pre-pull ring; plan-free
  labels; summaries to 200 rows; the one-line "N of M casts on targets above 85%" summary.
  *(shipped; in-game check is TESTING §15)*
- [x] **v0.7.1** `RankMath:SpellKit`; `Engine/SimModel.lua`; `/md simrun` self-tests;
  `/md simreplay fixture` against `Data/SimFixture_BF1.lua`. *(shipped; ten self-tests and the
  fixture gate pass offline via `tools/run.sh tools/simcheck.lua`. The fixture exposed ~23
  mana/s of unreported energize — TESTING §16.)*
- [x] **v0.7.2** `Engine/FightRecorder.lua`; `/md export` recording section. *(shipped; verified
  end to end offline by `tools/run.sh tools/reccheck.lua`, 20 assertions.)*
- [x] **v0.7.3** HP half of replay; the six gates; `/md simreplay [n]`; Validate. *(shipped;
  the gates correctly reject the scripted pull in `tools/reccheck.lua`.)*
- [x] **v0.7.4** `Engine/SimPlanner.lua` rules + classifier; card; loop closure. *(shipped;
  `/md coach [n]`. The classifier's mana identity holds exactly in `tools/reccheck.lua`.)*
- [x] **v0.7.5** the search. *(shipped; coordinate descent, 4 seeds, <= 300 evaluations,
  sliced on `debugprofilestop`. Beats both baselines on the harness fight.)*
- [x] **v0.7.6** `UI/Dashboard_Review.lua` (Review tab) + the Fight recording settings pane.
  *(shipped; UI is in-game-only verification -- TESTING §20.)*
- [x] **v0.7.7** `UI/SimWindow.lua`, `Data/SimPresets.lua`, `FromRecordings`, Monte Carlo.
  *(shipped; the synthetic path is covered by `tools/run.sh tools/simwindow.lua`, the window
  itself only in-game -- TESTING §21.)*

## Phase 1.8 — replay visualisation (v0.8)

Two columns of unit frames on one clock — the fight as the healer played it, the fight as the
coached plan would have — both from the engine, the recorder's real HP snapshots drawn as
ticks. Spec: **`docs/SPEC-v0.8.md`**; the three calls are in `docs/DECISIONS.md` §v0.8.

- [x] **v0.8.0** the trace (`opts.trace` on `SM:Run`), `Engine/ReplayTrace.lua`, `SP.Replay`,
  `tools/replaycheck.lua`. *(shipped; 27 assertions offline, nothing to see in-game yet)*
- [x] **v0.8.1** `UI/ReplayWindow.lua` — frames, healer strip, damage pulses, cast flashes,
  snapshot ticks, scrubber; `/md replay [n]`; Play on the Review row. *(shipped; painted
  offline by `tools/replayui.lua`, the look itself is TESTING §23)*
- [x] **v0.8.2** HoT indicators; per-cast labels at the moment of the cast; the right column's
  waits. *(shipped; `tools/replayui.lua` sees the squares, the dot, the `early` label and the
  wait band; the look is TESTING §24)*
- [x] **v0.8.3** recorder: defensive cooldowns (whitelist) and debuffs on tracked targets;
  icons on the frames. *(shipped; every id in `Data/AuraList.lua` is VERIFY until seen in a
  recording — TESTING §25)*

### Phase 1.9 — the loop closes offline
- [x] **`tools/import.lua`** (2026-09-06): the game's SavedVariables as the addon's database;
  list / validate / replay / coach / export on real recordings without the game. First run on
  three solo fights measured the character's own unreported regen at ~31 mp5 (TESTING §16 A).

## Phase 1.10 — runs, the measured character, the drink (v0.9)

Spec: **`docs/SPEC-v0.9.md`**; the calls in `docs/DECISIONS.md` §v0.9.

- [x] **v0.9.0** measured mp5 (`cdb.mp5` from `/md regentest`) into `RM:Unreported()` and every
  recording's `initial.energize`; the profile snapshot; the import tool uses both. *(2026-09-06;
  an older recording gets the current measurement with `energizeAssumed` stated in the report.
  In-game: TESTING §27.)*
- [x] **v0.9.1** `Engine/RunRecorder.lua`: `/md run start|stop|status`, every pull plus the gaps
  (drinks, deaths, mana every 2 s), `cdb.runs`, auto-stop, `# run` export, `tools/runcheck.lua`.
  *(2026-09-06; the run's own drink rate is measured across the drink's interior. In-game:
  TESTING §28.)*
- [x] **v0.9.2** Review tab run selector; pulls of a run with every button; `import.lua runs`.
  *(2026-09-06; one address, `run:pull`, shared by the tab, `/md replay 2:7` and the tool's
  `--run K`. New suite `tools/reviewui.lua`. In-game: TESTING §29.)*
- [x] **v0.9.3** the run in the engine: `ChainRun`, the gap model with the run's own drink rate,
  `CoachRun`, the run card — "you drank 4x (3:10); this plan needs 2x (1:20)". *(2026-09-06;
  `/md coachrun N`, Coach run on the tab, `import.lua coach --run K`. Innervates in the gaps are
  counted, not modelled: the recording carries the total regen rate, not the spirit split.
  In-game: TESTING §30.)*
- [ ] **v0.9.4** the run strip in the replay window; pull-by-pull Play through a dungeon.

## Phase 2 — other classes (after 1 is green)

Generic parts already work for any mana class: the OOM clock, widget, datatexts,
regen model (except class-specific unreported regen), spend tracker (live costs),
fight summary, drink reminder. Class-specific: the rank dashboard, the advisor's
Innervate branch, unreported regen talents.

- [ ] **Data**: per-class spell tables (Priest first: Lesser/Greater Heal, Flash Heal,
  Renew, PoM, PoH, CoH; then Paladin, Shaman). Heal values marked VERIFY until someone
  with the class runs `/md verify`.
- [ ] **RankMath**: class table of coefficient rules (direct / HoT / hybrid / channel),
  talent multipliers per class, in-5SR talent per class (Meditation etc. — the
  `IN_FSR_TALENT` table in `RegenModel` already has Priest/Mage).
- [ ] **Unreported regen**: Shaman Unrelenting Storm and any int-based mp5 talent —
  only after someone runs `/md regentest` on that class.
- [~] **Advisor**: done structurally in v0.5.2 — `Engine/ManaCooldowns.lua` owns the
  per-class table (Shadowfiend / Mana Tide / Divine Illumination are present as stubs) and
  the generic potion branch, and both the advisor and the clock read it. Each stub still
  needs a value model plus one in-game log from someone of that class.
- [ ] **Testing without alts**: `/md verify`, `/md regentest`, `/md spamtest` and the
  debug console Copy are the hand-off — ask a guildmate of that class for three pastes.
