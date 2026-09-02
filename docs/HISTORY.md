# ManaDemon — session history

Running log of work sessions. Newest entry last. Any Claude session working on this
repo should read this file plus `docs/DECISIONS.md` before making changes, and append
a dated entry here when a session ends with meaningful progress.

---

## 2026-09-01 — Project inception: design debate + full v1 implementation

**Process:** The author requested a multi-agent workflow: two Opus agents brainstormed
from opposing stances ("Party A: Theorycrafter" — math correctness first; "Party B: UX
Pragmatist" — glanceable decision-driving UI first), exchanged rebuttals, the author
picked between disputed features, a draft implementation plan was written and both
agents critiqued it, and the judged synthesis was implemented. All contested calls,
who won each, and the formulas are in `docs/DECISIONS.md` — that file is the authority
on *why* the code is shaped the way it is.

**Author's decisions this session:**
- All four disputed extras in v1: Innervate/potion advisor, gear-change rank toast,
  5SR underline, drink reminder (drink reminder kept against Party A's cut vote).
- History fine-tuning of the OOM prediction: cut (only pull-time EWMA seeding from the
  last ~5 in-memory fights + "last fight" reference survive; no persistence).
- Class scope: TTO/advisor class-generic, rank dashboard druid-only.

**Built (v1 complete, 12 Lua files, all syntax-checked via python3+luaparser — no Lua
interpreter on this machine):**
- `ManaDemon.toc` (Interface 20506, `## OptionalDeps: ElvUI`), `Core.lua` (namespace,
  `MD:On`/`MD:RegisterCallback`/`MD:Fire`/`MD:OnTick`, talent scan by name, slash cmds),
  `Data/SpellData.lua` (static druid spell table + cost modifiers),
  `Engine/` (RegenModel with FSR state machine, SpendTracker EWMA + bucket stats,
  TTO + shared display string, RankMath with Pareto filter),
  `UI/` (Widget with 5SR underline + visibility hysteresis, Dashboard, Advisor,
  Summary), `Integrations/ElvUIDatatext.lua`, `Verify.lua` (`/md verify`, `/md fsrtest`).
- Docs: `CLAUDE.md`, `README.md`, `docs/DECISIONS.md`, this file.
- Bugs caught in self-review and fixed: widget not draggable during first-run preview;
  widget position saved without relativePoint (would shift after reload); FSR-test
  logger couldn't be detached (dispatcher has no unregister — flag pattern used).

**State at session end:**
- NOT committed to git (author hasn't asked; repo has zero commits).
- NOT tested in-game. `Data/SpellData.lua` values are best-effort from TBC references —
  the `-- VERIFY` rows (high-rank HT/Rejuv/Regrowth costs and heals, Tranquility costs,
  Lifebloom coefficients) are unconfirmed.

**Next steps (in order):**
1. Author runs `/md verify` in-game and reports output → fix `SpellData.lua` from it.
2. Author runs `/md fsrtest` → confirm the FSR anchor (cast completion vs mana deduction).
3. Confirm `GetManaRegen()` units and combat freshness on the anniversary client.
4. First git commit once data is verified (or before, if the author wants a snapshot).
5. v2 backlog lives at the bottom of `docs/DECISIONS.md`.

**Addendum 2 (same day) — v0.2.0 after first in-game test.** Author feedback:
1. *Boxes instead of `↓`/`∞`* — WoW's default fonts lack those glyphs. Fixed: display
   string is ASCII-only now (`^` up / `v` down / `vv` crit / `=` flat / `--` sustainable);
   summary separator switched from U+00B7 to `|`. RULE: no non-ASCII glyphs in any
   rendered string.
2. *Dashboard restructure* — now class tab (Druid) + Settings tab, spell subtabs
   (HT/Lifebloom/Rejuv/Regrowth), and per-spell a table of ALL ranks incl. unlearned
   (dimmed "not learned"), columns Rank/Lvl/Mana/Heal-per-cast/HPM/HPS/Cast/note.
   Pareto now marks rows ("dominated") instead of hiding them; `showDominated` setting
   removed. RankMath computes all ranks with a `known` flag (Pareto/suggested among
   known only).
3. *GUI settings* — Settings tab: mute, drink reminder, widget lock, minimap button
   toggle, widget position reset, spend half-life slider (5–60s).
4. *MinimapButtonButton integration* — new `UI/MinimapButton.lua`: standard named
   Button parented to Minimap (the pattern collectors adopt), left-click dashboard,
   right-click settings, draggable around the rim, angle persisted in `db.minimap`.
Version bumped to 0.2.0; release rebuilt (15 files). Still not committed, still
pending in-game `/md verify`.

**Addendum (same day):** Added `docs/HISTORY.md` + CLAUDE.md continuity instructions
(the author noted new Claude sessions don't remember old ones), and `release.sh` —
builds `dist/ManaDemon/` + `dist/ManaDemon-<version>.zip` from the `.toc`'s file list,
optionally installs into an AddOns folder passed as arg or `WOW_ADDONS` env var.
Tested: 14 files packaged. `dist/` gitignored. The author's WoW install path is not
yet known (auto-detection through /mnt was too slow) — ask for it once and record it here.
