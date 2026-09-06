# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**ManaDemon** is a World of Warcraft addon for **TBC Anniversary realms** (TBC Classic client, `## Interface: 20506`, Lua 5.1). It helps healers manage mana:

1. **Time-to-OOM (TTO)** — a live projection of when mana hits zero, shown as a one-line clock (`OOM 1:20 v  rest 2:10`; `FULL 0:45` when regen wins) in a floating widget and/or an ElvUI datatext (plus a second "current mp5" datatext). Class-generic. Rendered strings are **ASCII only** (WoW fonts have no arrow/infinity glyphs) and never contain a bare `|`.
2. **Rank dashboard** (`/md`) — per-rank mana efficiency (HPM), heal amount and HPS for the druid healing spells, with the player's current +healing, talents and TBC downranking penalties applied. **Druid-only in v1.**
3. **Advisor** — push alerts at decision moments: Innervate/mana-potion timing (fire when the deficit first exceeds the restored amount), gear-change "efficient rank shifted, rebind?" toast, and an out-of-combat drink reminder.
4. **End-of-combat summary** — one chat line per fight (net mp5, spend by spell, mana into full health, overheal %, spirit-regen-realized %, max-rank cast %, OOM moment), plus (v0.7.0) a second line counting casts on targets already above `db.simFullHp` and a third for pre-pull HoTs on full targets. Every own cast is captured with cost / target / HP-at-cast / form into a 20 s ring and labelled `utility|shift|early|overheal|ok` at the end of the fight. Last **200** fights persisted per character (`MD.cdb.fights`), zone-tagged; fights under 4 own casts are not kept.
5. **Self-calibration** (`Engine/Calibration.lua`) — every heal landed is compared with the model's prediction for it; drift is reported (`/md calibrate`, a chat line), **never fed back into the model**.
6. **Waste view** (`/md` → Waste) — overheal and wasted mana by spell / role / class / target from the combat log; **pull budget** between pulls.

Primary user is the author (Resto Druid); the TTO/advisor side is intentionally usable by any mana healer. Full design rationale and every debated decision live in **`docs/DECISIONS.md`** — read it before changing model behavior.

**v0.7 (fight recording, replay, coaching, simulation) is specified in `docs/SPEC-v0.7.md`** —
implement from it, not from `docs/DESIGN-v0.7.md`; the debate that produced it is in
`docs/debates/v0.7-sim/` and its rulings in `docs/DECISIONS.md` §v0.7.

**Session continuity:** past work sessions are logged in **`docs/HISTORY.md`** (what was done, project state, next steps). Read it at the start of a session to recover context, and append a dated entry when a session ends with meaningful progress — this is the project's memory across conversations. **`docs/PLAN.md`** is the agreed roadmap (Phase 1 druid verification + improvements, Phase 2 other classes) — tick items there as they land. **`docs/TESTING.md`** tells the author what to test in-game and how to report it.

## Repo structure and load order

Load order is defined by `ManaDemon.toc` and matters — later files assume earlier ones populated the shared namespace:

| File | Role |
|---|---|
| `Core.lua` | Namespace, SavedVariables (`ManaDemonDB`), event dispatcher (`MD:On`), internal pub/sub (`MD:RegisterCallback`/`MD:Fire`), master 0.5s ticker (`MD:OnTick`), profile + talent scan, slash commands |
| `Data/SpellData.lua` | **Static** druid spell table (spellID → rank/level/cost/cast/heal) + known-rank index. `SD:GetCost()` is **live-first** (`GetSpellPowerCost` works on this client, verified 2026-09-03) with the static table + talent modifiers (`SD:StaticCost`) as fallback and as the reference `/md verify` diffs against |
| `Engine/RegenModel.lua` | Five-second-rule state machine + regen rates straight from `GetManaRegen()` (no algebra — see DECISIONS) **plus the one thing the client omits: Dreamstate** (`RM:Unreported()`, measured in-game); raw values stay in `RM.apiBase/apiCasting`. `RM:Effective()` weights the two rates by the measured FSR duty cycle for projections; out-of-combat observed mana-gain rate (drinking) is an EWMA over gain events |
| `Engine/SpendTracker.lua` | EWMA spend-rate estimator + its one-sigma spread (`ST:Estimate()` → rate, sigma, casts) from `UNIT_SPELLCAST_SUCCEEDED`, pull-time seed from fight history |
| `Engine/TTO.lua` | Raw state (`MD:GetManaState()`: mode oom/hold/full/warmup/ooc, tto/ttf/bound/rest, `rel`/`confident`, `cd`) computed once per tick, plus the render-only display layer (sigma-derived digit precision, value/mode latch, **confidence gate**: digits only while `sigma/net <= db.oomConfidence`, else the bound; arrow from the shown value) behind `MD:GetDisplayString`. **Never `v or 0`** — a missing value renders `OOM --` |
| `Engine/Targets.lua` | Group roster GUID → name, class, **role and roleSource** (`UnitGroupRolesAssigned` → `GetPartyAssignment` → class-implied → unknown; read, never inferred from talents). Life Tap counts per member. Fires `ROSTER_CHANGED` |
| `Engine/Overheal.lua` | Measured overheal from the combat log in six dimensions (family, spell, spell:kind, role, class, per-target session-only); wasted-mana attribution per event; persisted store decays (150-event half-life), session store does not. Latches whether the log's `amount` includes overheal (`OH:Split`) — **it does on this client (GROSS)** |
| `Engine/Calibration.lua` | Observed / predicted per spell and event kind, crits separated, no decay (a ratio is gear-invariant); resets only when the talent build changes. Reports via `/md calibrate` and a 3% drift alert. **Reads RankMath; RankMath never reads it** |
| `Engine/PullBudget.lua` | Median mana per pull in this zone from fight history → "N more, M after a drink" |
| `Engine/ManaCooldowns.lua` | Per-class big mana cooldowns (Druid live; Priest/Shaman/Paladin stubs) + carried potions, each returning the **marginal** mana it buys over `RM:Effective()`. Read by both `Engine/TTO.lua` and `UI/Advisor.lua` |
| `Engine/SimModel.lua` | **The simulation engine** (v0.7.1): one event-driven loop over a scenario, driven either by a recorded script (replay) or by a plan that decides. Binary heap for HoT ticks/expiries/decisions; recorded timelines read by cursor, never copied; per-run state from a reused pool slot. Mana leaves and the 5SR restarts when a cast **succeeds** (what the client does); regen integrated continuously. `SM.K` are the recorded event kinds — do not renumber |
| `Engine/RankMath.lua` | `Context()` (every input, incl. `MD.sim` overrides) → `RowFor(spell, ctx, variant, explain)` → `Compute()`; `Explain()` rebuilds one row with `row.calc` for the tooltip; `EventPrediction()` for calibration. Coefficients, downrank/sub-20 penalties, talent multipliers, Nature's Grace expected cast, crit weighting, Lifebloom tick/bloom effective values, Pareto filter, suggested rank. `SpellKit(opts)` flattens every known rank into plain numbers, once per form — **the single boundary between the rank math and `Engine/SimModel.lua`, which must never call `RowFor`**. `Context(opts)` takes `opts.live` (ignore the Simulate strip) and `opts.healer` (the simulator's own stat overrides). **HP5 was removed in v0.6.0** (it ordered like HPM) |
| `UI/Style.lua` | Widget kit in Cell's options-UI style (`MD.UI`: flat panels, accent buttons/button groups, check buttons, titled panes, scroll frame, slider, movable frame with header, private tooltip). No libraries |
| `UI/Tooltip.lua` | **The one tooltip line builder** (`MD.Tip`): `{l, r}` line tables rendered into GameTooltip or ElvUI's `DT.tooltip`. `Tip:Mana()`, `:Row()`, `:Columns()`, `:Fights()`, `:Clock()`. Every hover surface goes through it |
| `UI/Widget.lua` | Floating one-liner + 5SR underline; **all** show/hide goes through `MD:UpdateVisibility()`. Hover tooltip + left-click gated by `db.widgetTooltip` (it needs mouse input on the frame) |
| `UI/Dashboard_Rows.lua` | Column layout, row frame pool, row rendering, hover → row tooltip, "Effective" (overheal-adjusted) mode |
| `UI/Dashboard_Simulate.lua` | The two-row "Simulate" what-if strip (`MD.sim`: stats, form, Moonglow) |
| `UI/Dashboard_Waste.lua` | The Waste tab: by spell (per event kind) / role / class / target, session or persisted scope |
| `UI/Dashboard.lua` | `/md` rank dashboard frame (spell tabs, header lines, recap); the two files above export constructors on `MD.DashboardParts` and load first |
| `UI/OptionsFrame.lua` | `/md options` settings window: tab buttons on the top edge, fires `ShowOptionsTab`; `UI/Options_General.lua` / `UI/Options_About.lua` are the tabs |
| `UI/DebugConsole.lua` | `MD:Debug(category, fmt, ...)` sink (Core.lua defines the entry point): 1000-line memory ring, filterable window, Copy popup. `/md debug` |
| `UI/Advisor.lua` | Innervate/potion advisor, gear toast, drink reminder |
| `UI/Summary.lua` | Fight tracking, combat-log overheal, history ring, **own-cast capture (`MD.Recorder`) and the plan-free cast labels** (SPEC-v0.7 §2) |
| `Integrations/ElvUIDatatext.lua` | `DT:RegisterDatatext` glue; only active when ElvUI is installed (`## OptionalDeps: ElvUI`) |
| `Verify.lua` | `MD:Snapshot()` (every model input, shared), `/md verify` (static data vs live client), `/md profile` (snapshot + costs + clock + settings into the copy popup), `/md fsrtest`, `/md regentest`, `/md spamtest` |
| `tools/` | **Offline harness** — `tools/run.sh <script>` builds a real Lua 5.1 into `tools/.lua` (gitignored) and runs a script against this checkout; `tools/wowstub.lua` fakes just enough client API for the non-UI files to load; `tools/harness.lua` loads them and returns `MD`; `tools/simcheck.lua` runs `/md simrun` + `/md simreplay fixture` (`--curve` prints the mana curve next to the log's). Not shipped: `release.sh` builds from the `.toc`'s file list |
| `release.sh` / `Makefile` | `make release` builds from the main checkout or any git worktree (interactive menu, or `SRC=<name>`) into the **top-level** `dist/<name>/ManaDemon/` + versioned zip, from the `.toc`'s own file list (dev files excluded by construction). `make install WOW_ADDONS=<AddOns dir>` also copies it into the game. `dist/` is gitignored |

Every file starts with `local _, MD = ...` to pull the shared addon table. `MD.db` is account-wide settings, `MD.cdb` is per-character.

## Conventions and constraints

- **No libraries.** Plain event frame, no Ace3. Keep it that way unless a hard need appears.
- **The model is event-driven; tickers only accumulate/render.** Never gate model updates behind UI visibility.
- **Widget visibility has a single owner** (`MD:UpdateVisibility` in `UI/Widget.lua`) with 90%/95% hysteresis. Do not call `Show()`/`Hide()` on the widget elsewhere.
- **API defensiveness:** the anniversary client's API surface is uncertain; wrap maybe-missing globals in `pcall`/existence checks (see `MD:On`, `ResolveCost`, `MD:HasBuff` for the pattern).
- **`Data/SpellData.lua` values are best-effort and frozen** — any change must come from `/md verify` output or an in-game measurement, never from memory (costs were corrected that way on 2026-09-03; heal values for unlearned ranks are still `-- VERIFY`). Unverified formulas are listed in `docs/DECISIONS.md` §Open verification items.
- **Regen the client does not report** goes through `RM:Unreported()` only after an in-game `/md regentest` proves the API omits it (Dreamstate: proven). Adding a term the API already includes double counts.
- **Calibration never feeds the model.** `Engine/Calibration.lua` reports drift to a human; fixing it means changing `Data/SpellData.lua` or a formula, never scaling output by an observed ratio.
- **Lua multi-return trap:** `a and f() or b` truncates `f()` to one value. It bit twice in `UI/Summary.lua` around `Overheal:Split`; write the `if` out.
- **Constants derived from one log are settings with provenance** (`db.oomConfidence`), not hard-coded truths — the first log was a level 61 dungeon on a level 64 druid.
- enUS only for now (drink-buff names in `UI/Advisor.lua` are literal English strings).
- **Debug logging:** `MD:Debug("category", fmt, ...)` with category in regen / mana / spend / tto / heal / cast / calib / combat / chat / sim / other; it is a no-op unless enabled in the Debug Console, so it is safe on hot paths. Log state transitions and inputs, not every tick.
- **New settings UI goes through `MD.UI`** (`UI/Style.lua`) into a pane of `UI/Options_General.lua`, not into the dashboard.

## Verifying changes

There is no build system. A change is "verified" when:
1. `luac -p <file>` passes (any Lua ≥5.1 syntax check is fine),
2. the file is listed in `ManaDemon.toc` in a position consistent with what it reads from `MD`, and
3. **for anything the engine touches, `tools/run.sh tools/simcheck.lua` still passes** — ten
   self-tests over `Engine/SimModel.lua` plus the BF-1 fixture replay. It runs the real files
   under a stub client, so it catches ordering and arithmetic bugs a syntax check cannot (it
   found the sample-ordering bug in the engine's first cut). It is the closest thing this
   repo has to a test suite; keep `tools/harness.lua`'s file list in step with the `.toc`.

Functional testing happens in-game: `/md verify` first (data + input snapshot), `/md fsrtest` for the five-second-rule anchor, then play. The neighboring `../ElvUI*` folders (if present in the parent AddOns checkout) are read-only reference code for datatext patterns.
