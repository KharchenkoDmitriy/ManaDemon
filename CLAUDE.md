# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**ManaDemon** is a World of Warcraft addon for **TBC Anniversary realms** (TBC Classic client, `## Interface: 20506`, Lua 5.1). It helps healers manage mana:

1. **Time-to-OOM (TTO)** — a live projection of when mana hits zero, shown as a one-line readout (`OOM 1:24 ↓`) in a floating widget and/or an ElvUI datatext. Class-generic.
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
| `Data/SpellData.lua` | **Static** druid spell table (spellID → rank/level/cost/cast/heal) + cost modifiers (Moonglow, Tranquil Spirit, Tree of Life) + known-rank index. The 2.5.x client does not reliably expose per-rank costs; this table is the source of truth |
| `Engine/RegenModel.lua` | Five-second-rule state machine + regen rates straight from `GetManaRegen()` (no algebra — see DECISIONS) |
| `Engine/SpendTracker.lua` | EWMA spend-rate estimator from `UNIT_SPELLCAST_SUCCEEDED`, 5s-bucket window stats, pull-time seed from fight history |
| `Engine/TTO.lua` | TTO computation, trend arrow, shared display string (`MD:GetDisplayString`) used by both UI surfaces |
| `Engine/RankMath.lua` | Coefficients, downrank/sub-20 penalties, talent multipliers, crit weighting, Pareto filter, suggested rank |
| `UI/Widget.lua` | Floating one-liner + 5SR underline; **all** show/hide goes through `MD:UpdateVisibility()` |
| `UI/Dashboard.lua` | `/md` rank dashboard frame |
| `UI/Advisor.lua` | Innervate/potion advisor, gear toast, drink reminder |
| `UI/Summary.lua` | Fight tracking, combat-log overheal, history ring |
| `Integrations/ElvUIDatatext.lua` | `DT:RegisterDatatext` glue; only active when ElvUI is installed (`## OptionalDeps: ElvUI`) |
| `Verify.lua` | `/md verify` (static data vs live client, input snapshot) and `/md fsrtest` (FSR anchor logging) |
| `release.sh` | Builds `dist/ManaDemon/` + versioned zip from the `.toc`'s own file list (dev files excluded by construction); optional arg/`WOW_ADDONS` env installs into the game's AddOns folder. `dist/` is gitignored |

Every file starts with `local _, MD = ...` to pull the shared addon table. `MD.db` is account-wide settings, `MD.cdb` is per-character.

## Conventions and constraints

- **No libraries.** Plain event frame, no Ace3. Keep it that way unless a hard need appears.
- **The model is event-driven; tickers only accumulate/render.** Never gate model updates behind UI visibility.
- **Widget visibility has a single owner** (`MD:UpdateVisibility` in `UI/Widget.lua`) with 90%/95% hysteresis. Do not call `Show()`/`Hide()` on the widget elsewhere.
- **API defensiveness:** the anniversary client's API surface is uncertain; wrap maybe-missing globals in `pcall`/existence checks (see `MD:On`, `ResolveCost`, `MD:HasBuff` for the pattern).
- **`Data/SpellData.lua` values are best-effort and frozen** — any change must come from `/md verify` output or an in-game measurement, never from memory. `-- VERIFY` marks the least-certain entries. Unverified formulas are listed in `docs/DECISIONS.md` §Open verification items.
- enUS only for now (drink-buff names in `UI/Advisor.lua` are literal English strings).

## Verifying changes

There is no build system or test suite. A change is "verified" when:
1. `luac -p <file>` passes (any Lua ≥5.1 syntax check is fine), and
2. the file is listed in `ManaDemon.toc` in a position consistent with what it reads from `MD`.

Functional testing happens in-game: `/md verify` first (data + input snapshot), `/md fsrtest` for the five-second-rule anchor, then play. The neighboring `../ElvUI*` folders (if present in the parent AddOns checkout) are read-only reference code for datatext patterns.
