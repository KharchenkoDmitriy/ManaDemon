# ManaDemon — design decisions and rationale

This documents the full design process: two AI agents ("Party A: Theorycrafter" — math
correctness first; "Party B: UX Pragmatist" — glanceable, decision-driving UI first)
brainstormed independently, exchanged rebuttals, and critiqued the implementation plan;
a judge synthesized; the author (NeRgY, Resto Druid, TBC Anniversary) made the final calls.
Date: 2026-09-01.

## v1 scope (final)

1. **Static spell data table** (`Data/SpellData.lua`) — ships first: the 2.5.x client does
   not reliably expose per-rank mana costs, so a frozen hand-built table is the foundation
   *and* the schedule risk. Verified once in-game via `/md verify`.
2. **TTO engine** — spend rate from casts (EWMA), regen rate analytic, FSR state machine.
3. **One-line combat UI** — floating widget + ElvUI datatext, both rendering
   `MD:GetDisplayString()`. 5SR underline on the widget.
4. **Rank dashboard** (`/md`) — druid-only, Pareto-filtered.
5. **Advisor extras** — Innervate/potion advisor, gear-change rank toast, drink reminder
   (all four extras chosen by the author; the drink reminder was disputed — A called it a
   nag, B proposed it — author sided with B).
6. **End-of-combat summary** + last-5-fights in-memory history.

**Cut from v1** (explicit decisions, not omissions):
- **History-based fine-tuning of the OOM prediction** — both parties converged on cutting
  it: the decision it drives ("pot now or in 20s?") is coarse; weeks of modeling to move a
  number the player rounds anyway. Survives only as: (a) pull-time seeding of the spend
  EWMA from the last ~5 fights' median rate, (b) a "last fight" reference line. No
  SavedVariables persistence of history, no curve fitting.
- **Non-druid rank dashboard** — per-class coefficients/spell lists are real work; the TTO
  engine is class-generic for free (see FSR decision below), so TTO+advisor work for any
  healer and the dashboard says so.
- **Confidence band in the UI** — A wanted p25/p75 shown; B argued a band isn't actionable.
  Merged: the single displayed number is the *pessimistic* edge (p75 of the spend
  distribution) and instability is carried by one `~` prefix + grey, driven by a
  suppression rule (≥6 casts in window AND IQR ≤ 40% of median).
- **Config UI** — slash commands + three checkboxes in the dashboard footer.
- Raid comms/sync, graphs/animations/themes, "efficiency scores", per-rank
  overheal-calibrated recommender (v2 candidate — needs a corpus of the author's logs).

## Model decisions (who won which argument)

| Decision | Outcome | Why |
|---|---|---|
| TTO before dashboard | **B** (A conceded) | TTO needs only cost+cast-time; the dashboard's dependency chain (coefficients, talents, Lifebloom split) is deeper, not shallower. |
| EWMA over 10s sliding window | **A** | Spirit regen ticks every 2s; a 10s window catches 3–5 ticks (±40% swing) and extrapolates chain-cast bursts into eternity. EWMA is also less code. |
| Regen analytic, never regressed from raw mana | **A** (B conceded) | Regressing raw mana entangles spend and regen; Innervate/potions poison the sample. |
| Use `GetManaRegen()` returns **directly** (base = out of FSR, casting = in FSR) | **A's self-correction** | Decomposing into spirit/mp5 components and re-weighting double-counts Intensity (casting already includes it). The spirit/mp5 decomposition exists for display only. Refreshed every tick because the value can go stale mid-combat on Classic clients. |
| FSR trigger = any player mana *decrease* on `UNIT_POWER_UPDATE` | **A (plan critique)** | Spell-table-independent: catches wands, off-spec casts, any class — this is what makes TTO class-generic. `UNIT_SPELLCAST_SUCCEEDED` alone misses spenders and the deduction anchor is unverified (hence `/md fsrtest`). Known false-positive: enemy mana burns (accepted). |
| Sustainable sentinel instead of TTO=∞ | **A (plan critique)** | `mana / max(0, spend−regen)` divides by zero when regen wins. |
| Spend-cost fallback = `GetSpellPowerCost` (pcall), then **log**, never UnitPower-delta sampling | **B (plan critique)** | Delta sampling races spirit ticks and Innervate; a missing cost is exactly what `/md verify` should report, not paper over. |
| Drop dominated-rank rows behind "show all"; never highlight raw best-HPM | **A** (B conceded) | Raw HPM monotonically favors rank 1 — an HPM-only dashboard always answers "HT R1". Pareto filter on (HPM, HPS); "suggested" = highest-HPM non-dominated rank healing ≥40% of max rank (labeled assumption). |
| Mana-cost modifier pipeline (Moonglow −3%/r on HT/Regrowth/Rejuv, Tranquil Spirit −2%/r on HT/Tranquility, Tree of Life −20% on HoTs, floor at the end) | **A (plan critique)** | Without it every HT HPM figure is off by up to ~18% for a typical resto build. |
| Talents scanned by **name** across all tabs, re-scanned on respec events | **A (plan critique)** | Positional `(tab, index)` silently returns the wrong talent when builds shift. |
| Widget: single visibility owner, 90/95% hysteresis, frames created at login, position persisted, `/md unlock`+`reset`, first-run 60s forced preview | **B (plan critique)** | Prevents flicker at the threshold, mid-pull frame creation, unrecoverable off-screen drags, and the "fresh install shows nothing" trap. |
| Model event-driven; tickers only accumulate/render | **A (plan critique)** | The draft ran the 0.25s recompute "only while the widget is shown", which would stall the estimator while hidden. |
| ElvUI datatext built-in (not a separate addon), `## OptionalDeps: ElvUI`, clamp ElvUI's first `elapsed=20000` OnUpdate call, take theme color from `ApplySettings` | **B** (A conceded v1 placement) | Verified against vendored ElvUI TBC build: `DT:RegisterDatatext` exists, comparable datatexts are 19–72 lines. |
| One attention event per fight (pulse at TTO<30s), no sound | **B** | Alert fatigue kills combat UIs. |
| 5SR underline stays in v1 | **Author** (B tried to defer its own idea) | Author explicitly selected it. |
| Drink reminder in v1 | **Author** (against A's cut vote) | |

## Formulas encoded in `Engine/RankMath.lua`

- Direct coefficient: `clamp(baseCastTime, 1.5, 3.5) / 3.5`
- HoT coefficient: `duration / 15`
- Hybrid (Regrowth, c = cast/3.5, h = dur/15): direct `c²/(c+h)` ≈ 0.1657, HoT `h²/(c+h)` ≈ 0.9941
- Sub-level-20 malus: `1 − (20 − spellLevel) × 0.0375` (3.75%/level, **not** 5%)
- Downrank penalty: `min(1, (spellLevel + 11) / casterLevel)`
- Penalties apply to the **bonus-healing contribution only**, not base heal
- Healing crits are **1.5×**; HoTs never crit; Improved Regrowth is +10% crit *chance*/rank (Regrowth only)
- Talent multipliers applied after coefficients: Gift of Nature +2%/r (all), Improved
  Rejuvenation +5%/r, Empowered Rejuvenation +4%/r on the bonus portion of HoTs,
  Empowered Touch +10%/r on the bonus portion of HT, Naturalist −0.1s/r HT cast
- Lifebloom: HoT coefficient 0.5187 total, bloom 0.3422 (empirical 2.4-era values)

## Open verification items (run `/md verify` in-game)

- All `-- VERIFY` rows in `SpellData.lua` (high-rank costs/heals are the least certain).
- `GetManaRegen()` unit (assumed mana **per second**; ElvUI's TBC datatext ×5 agrees) and
  its combat staleness behavior.
- FSR anchor: cast start vs. mana deduction vs. cast completion → `/md fsrtest`.
- Whether talent-modified costs floor or round (assumed floor).
- Lifebloom coefficients and whether Empowered Rejuvenation touches the bloom
  (assumed **not** — applied to tick portion only, conservative).
- `GetSpellPowerCost` presence on the anniversary client (harness reports either way).
- Downrank penalty exact form vs. tooltip reality at level < 70.

## v2+ backlog (from the debates)

- Overheal-calibrated effective HPM (`HPM × (1 − measuredOverheal[rank])`) once combat-log
  corpus exists — the plumbing (per-fight overheal totals) already ships in v1.
- Per-boss "last time you sustained X mps" reference (needs persistence).
- Non-druid rank dashboards (priest first).
- Rank→keybind/macro helper; TTO-with-cooldowns second line; localization.
