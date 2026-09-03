# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**ManaDemon** is a World of Warcraft addon for **TBC Anniversary realms** (TBC Classic client, `## Interface: 20506`, Lua 5.1). It helps healers manage mana:

1. **Time-to-OOM (TTO)** — a live projection of when mana hits zero, shown as a one-line clock (`OOM 1:20 v  rest 2:10`; `FULL 0:45` when regen wins) in a floating widget and/or an ElvUI datatext (plus a second "current mp5" datatext). Class-generic. Rendered strings are **ASCII only** (WoW fonts have no arrow/infinity glyphs) and never contain a bare `|`.
2. **Rank dashboard** (`/md`) — per-rank mana efficiency (HPM), heal amount and HPS for the druid healing spells, with the player's current +healing, talents and TBC downranking penalties applied. **Druid-only in v1.**
3. **Advisor** — push alerts at decision moments: Innervate/mana-potion timing (fire when the deficit first exceeds the restored amount), gear-change "efficient rank shifted, rebind?" toast, and an out-of-combat drink reminder.
4. **End-of-combat summary** — one chat line per fight (net mp5, overheal %, spirit-regen-realized %, max-rank cast %, OOM moment). Last 5 fights kept in memory only.

Primary user is the author (Resto Druid); the TTO/advisor side is intentionally usable by any mana healer. Full design rationale and every debated decision live in **`docs/DECISIONS.md`** — read it before changing model behavior.

**Session continuity:** past work sessions are logged in **`docs/HISTORY.md`** (what was done, project state, next steps). Read it at the start of a session to recover context, and append a dated entry when a session ends with meaningful progress — this is the project's memory across conversations.

## Repo structure and load order

Load order is defined by `ManaDemon.toc` and matters — later files assume earlier ones populated the shared namespace:

| File | Role |
|---|---|
| `Core.lua` | Namespace, SavedVariables (`ManaDemonDB`), event dispatcher (`MD:On`), internal pub/sub (`MD:RegisterCallback`/`MD:Fire`), master 0.5s ticker (`MD:OnTick`), profile + talent scan, slash commands |
| `Data/SpellData.lua` | **Static** druid spell table (spellID → rank/level/cost/cast/heal) + known-rank index. `SD:GetCost()` is **live-first** (`GetSpellPowerCost` works on this client, verified 2026-09-03) with the static table + talent modifiers (`SD:StaticCost`) as fallback and as the reference `/md verify` diffs against |
| `Engine/RegenModel.lua` | Five-second-rule state machine + regen rates straight from `GetManaRegen()` (no algebra — see DECISIONS) **plus the one thing the client omits: Dreamstate** (`RM:Unreported()`, measured in-game); raw values stay in `RM.apiBase/apiCasting`. `RM:Effective()` weights the two rates by the measured FSR duty cycle for projections; out-of-combat observed mana-gain rate (drinking) is an EWMA over gain events |
| `Engine/SpendTracker.lua` | EWMA spend-rate estimator + its one-sigma spread (`ST:Estimate()` → rate, sigma, casts) from `UNIT_SPELLCAST_SUCCEEDED`, pull-time seed from fight history |
| `Engine/TTO.lua` | Raw state (`MD:GetManaState()`: mode oom/hold/full/warmup/ooc, tto/ttf/bound/rest) computed once per tick, plus the render-only display layer (sigma-derived digit precision, value/mode latch, arrow from the shown value) behind `MD:GetDisplayString` |
| `Engine/RankMath.lua` | Coefficients, downrank/sub-20 penalties, talent multipliers, crit weighting, Pareto filter, suggested rank |
| `UI/Style.lua` | Widget kit in Cell's options-UI style (`MD.UI`: flat panels, accent buttons/button groups, check buttons, titled panes, scroll frame, slider, movable frame with header, private tooltip). No libraries |
| `UI/Widget.lua` | Floating one-liner + 5SR underline; **all** show/hide goes through `MD:UpdateVisibility()` |
| `UI/Dashboard.lua` | `/md` rank dashboard frame (spell tabs + "Settings" button) |
| `UI/OptionsFrame.lua` | `/md options` settings window: tab buttons on the top edge, fires `ShowOptionsTab`; `UI/Options_General.lua` / `UI/Options_About.lua` are the tabs |
| `UI/DebugConsole.lua` | `MD:Debug(category, fmt, ...)` sink (Core.lua defines the entry point): 1000-line memory ring, filterable window, Copy popup. `/md debug` |
| `UI/Advisor.lua` | Innervate/potion advisor, gear toast, drink reminder |
| `UI/Summary.lua` | Fight tracking, combat-log overheal, history ring |
| `Integrations/ElvUIDatatext.lua` | `DT:RegisterDatatext` glue; only active when ElvUI is installed (`## OptionalDeps: ElvUI`) |
| `Verify.lua` | `/md verify` (static data vs live client, input snapshot), `/md fsrtest` (FSR anchor logging), `/md regentest` (idle observed regen vs `GetManaRegen`: is Dreamstate included?) |
| `release.sh` / `Makefile` | `make release` builds from the main checkout or any git worktree (interactive menu, or `SRC=<name>`) into the **top-level** `dist/<name>/ManaDemon/` + versioned zip, from the `.toc`'s own file list (dev files excluded by construction). `make install WOW_ADDONS=<AddOns dir>` also copies it into the game. `dist/` is gitignored |

Every file starts with `local _, MD = ...` to pull the shared addon table. `MD.db` is account-wide settings, `MD.cdb` is per-character.

## Conventions and constraints

- **No libraries.** Plain event frame, no Ace3. Keep it that way unless a hard need appears.
- **The model is event-driven; tickers only accumulate/render.** Never gate model updates behind UI visibility.
- **Widget visibility has a single owner** (`MD:UpdateVisibility` in `UI/Widget.lua`) with 90%/95% hysteresis. Do not call `Show()`/`Hide()` on the widget elsewhere.
- **API defensiveness:** the anniversary client's API surface is uncertain; wrap maybe-missing globals in `pcall`/existence checks (see `MD:On`, `ResolveCost`, `MD:HasBuff` for the pattern).
- **`Data/SpellData.lua` values are best-effort and frozen** — any change must come from `/md verify` output or an in-game measurement, never from memory (costs were corrected that way on 2026-09-03; heal values for unlearned ranks are still `-- VERIFY`). Unverified formulas are listed in `docs/DECISIONS.md` §Open verification items.
- **Regen the client does not report** goes through `RM:Unreported()` only after an in-game `/md regentest` proves the API omits it (Dreamstate: proven). Adding a term the API already includes double counts.
- enUS only for now (drink-buff names in `UI/Advisor.lua` are literal English strings).
- **Debug logging:** `MD:Debug("category", fmt, ...)` with category in regen / mana / spend / tto / combat / chat / other; it is a no-op unless enabled in the Debug Console, so it is safe on hot paths. Log state transitions and inputs, not every tick.
- **New settings UI goes through `MD.UI`** (`UI/Style.lua`) into a pane of `UI/Options_General.lua`, not into the dashboard.

## Verifying changes

There is no build system or test suite. A change is "verified" when:
1. `luac -p <file>` passes (any Lua ≥5.1 syntax check is fine), and
2. the file is listed in `ManaDemon.toc` in a position consistent with what it reads from `MD`.

Functional testing happens in-game: `/md verify` first (data + input snapshot), `/md fsrtest` for the five-second-rule anchor, then play. The neighboring `../ElvUI*` folders (if present in the parent AddOns checkout) are read-only reference code for datatext patterns.
