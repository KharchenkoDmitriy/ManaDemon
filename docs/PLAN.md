# ManaDemon — plan (from 2026-09-03)

Two phases. Phase 1 finishes and hardens the druid experience on the author's own
character, where everything can be measured. Phase 2 opens the dashboard to other
classes, where testing is harder (no alts), so it is built on verified generic parts.

Status legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[?]` needs in-game data.

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
- [ ] **Nature's Grace** as an expected-value cast-time term: `cast − 0.5 × crit`
  for HT / Regrowth chains (floor 1.5s). Show in the Cast column when active.
- [ ] **Innervate-aware clock**: second figure on the tooltip / rest segment
  ("OOM 1:20, 2:40 with Innervate") using the advisor's readiness check.
- [ ] **Overheal-calibrated HPM**: per-spell overheal from the combat log (plumbing exists
  in `UI/Summary.lua`), shown as "effective HPM" once ≥ N casts of that spell were seen.
- [ ] **Persist fight history** (last 20 per character in `MD.cdb`) so the pull-time seed
  and a "last time here" reference survive a reload.

### 1c. UX
- [ ] **Per-row tooltips on the dashboard**: base heal, bonus contribution, penalty,
  talent multipliers, cost source (live/table), HP5 interval, To OOM net per cast.
- [ ] **Simulate strip: Tree form toggle and Moonglow rank box.**
- [ ] **One tooltip builder** shared by the datatext, minimap button and widget hover.
- [ ] **`/md profile`**: one-block dump of every model input (stats, talents, regen raw +
  model, form, costs of known max ranks, settings) for bug reports.

### 1d. Housekeeping
- [x] Commit v0.4.6, remove the stale worktree.
- [ ] Split `UI/Dashboard.lua` rendering from row building if tooltips make it long.

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
- [ ] **Advisor**: replace the Innervate branch with a per-class "big regen cooldown"
  (Shadowfiend, Mana Tide, Divine Illumination) and the mana-potion branch stays generic.
- [ ] **Testing without alts**: `/md verify`, `/md regentest`, `/md spamtest` and the
  debug console Copy are the hand-off — ask a guildmate of that class for three pastes.
