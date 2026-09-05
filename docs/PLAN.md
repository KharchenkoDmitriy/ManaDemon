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
