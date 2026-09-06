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

## 2026-09-02 — Feedback round 3 (v0.3.0): OOM+FULL clock, estimator rework, dashboard polish

**Git:** the harness required an isolated worktree for edits, which needs a commit to
branch from, so the previously uncommitted v0.2.0 state was committed as the initial
snapshot on `master` (`f2939b4`). This round's work is on branch
`worktree-feedback-round-3` (worktree `.claude/worktrees/feedback-round-3`, gitignored).
Merge it into `master` to pick it up: `git merge worktree-feedback-round-3`.

**Author feedback and what was done:**
1. *Second ElvUI datatext for current mana regen* — `ManaDemon Regen`: `Regen: 123` (mp5
   from `RM:Current()`, so casting regen inside the 5SR, `(5SR)` marker), same tooltip
   and click handling as the OOM datatext (shared code).
2. *OOM and FULL time at the same place* — debated (A/B + rebuttal, Fable judge; full
   table appended to `docs/DECISIONS.md`). Shipped: one clock whose label carries the
   sign (`OOM 1:20 v` / `FULL 0:45`), grey `rest 2:10` secondary (time to full if you
   stop casting), `OOM >4:00 =` when net rate is within noise, `>10m` cap, warm-up
   `OOM ...`, out of combat `FULL 1:12` / `FULL`. `/md rest` + Settings checkbox.
3. *Estimation jumps* — root causes were the p75-of-6-buckets pessimism (re-sorts every
   5s) and the binary FSR regen flip. Now: `rate + 1 sigma` from the EWMA loop
   (`ST:Estimate()`), FSR-duty-weighted regen (`RM:Effective()`), digit precision from
   sigma, value/mode latch (bad news instant, good news 2 ticks), arrow from the shown
   value. Out of combat the FULL clock uses observed mana gain so drinking is right.
4. *"Not learned" on ranks below a known one* — `SD:BuildKnown()` now finds the highest
   detectable rank per family and backfills every lower rank (they are prerequisites).
5. *Dashboard transparency* — flat near-opaque backdrop (0.06 grey, 95%).
6. *ElvUI-style tabs* — stock button textures gone; flat 0.1-grey backdrops, 1px black
   border, gold text + lighter backdrop on the active tab; same style for close/reset.
   No ElvUI dependency (values taken from ElvUI's defaults: backdrop 0.1, border black).
7. *Lifebloom x2 / x3* — virtual rows under Lifebloom: per refresh cast 6 ticks at the
   stack multiplier, no bloom; excluded from Pareto/suggestion (informational).

Also: `MD.version` now read from the .toc; `/md verify` prints drink-buff state and the
observed OOC fill next to `GetManaRegen` (premise check for item 3). All 13 Lua files
syntax-checked (python3 + luaparser). Release rebuilt as v0.3.0.

**Still pending:** in-game `/md verify` + `/md fsrtest` output; `K_SIGMA=1.0` and
`CV_STABLE=0.35` in `Engine/TTO.lua` are first guesses to tune from real fights.

**Addendum (same day) — Makefile.** Author asked for `make release` that prompts for the
source (main checkout or a worktree) and stacks output in the top-level `dist/` grouped
per source. `release.sh` gained `--src NAME|DIR`, `--out`, `--install`, `--list`, `--menu`
(repo root found via `git rev-parse --git-common-dir`, sources via `git worktree list`);
output is `dist/<name>/ManaDemon/` + zip, `<name>` = `main` or the worktree folder. The
`Makefile` wraps it (`release`, `install`, `list`, `clean`; `.RECIPEPREFIX = >`). Tested
from the worktree: menu, `SRC=main`, `SRC=feedback-round-3`, unknown source errors out.

## 2026-09-03 — Talent audit, Cell-style settings + debug console (v0.4.0)

**Talent audit (author asked "does our math consider talents?").** Verdict recorded in
`docs/DECISIONS.md` § Talent audit. Covered correctly: Gift of Nature, Improved /
Empowered Rejuvenation, Empowered Touch, Improved Regrowth, Naturalist (heal side);
Moonglow, Tranquil Spirit, Tree of Life (cost side); Intensity / Living Spirit /
Lunar Guidance / Natural Perfection / Tree aura via the client APIs. Found but NOT yet
changed (author to decide after `/md verify`): percent modifiers stack multiplicatively
in the code while the TBC client sums same-type percent mods (GoN + Imp Rejuv; Moonglow +
Tranquil Spirit; Moonglow + Tree of Life); Empowered Touch should ADD +10%/rank to the
HT coefficient, not multiply it (same for R5+, differs for R1–R4); Nature's Grace is not
modelled at all. Author then reported that **Dreamstate is not part of the mp5 value
Blizzard reports** — if true, both `GetManaRegen()` rates run low by 4/7/10% of Int per
5s in AND out of the 5SR and the whole in-combat clock is pessimistic by that constant.

**To settle it in-game the author asked for debug logs and a copyable log window "like
Cell does", plus Cell's settings-window style.** Done, mimicking `../Cell`:
- `UI/Style.lua` — widget kit written from scratch after Cell's `Widgets/Widgets.lua`:
  class-colour accent, 13/14px fonts (`MANADEMON_FONT*`), flat 0.115-grey backdrops with
  1px black border, buttons (`red`, `accent-hover`, ...), button groups (tab highlight),
  check buttons, titled panes, scroll frame with 5px accent thumb, scroll edit box,
  slider with value box, movable frame with 20px header bar, private flat tooltip.
- `UI/OptionsFrame.lua` — 432px options window; tab buttons on the top edge
  (`General | About  ManaDemon vX  ×`), height per tab, position saved in
  `db.optionsPos`, ESC closes. `/md options`, dashboard "Settings" button, minimap
  right-click all open it. Tabs subscribe to `ShowOptionsTab`.
- `UI/Options_General.lua` — panes: OOM Widget (lock, rest, reset position), Alerts
  (mute, drink), Model (half-life slider), Misc (minimap button, **Debug Console**,
  Verify spell data, Regen test). Replaces the dashboard's old Settings tab.
- `UI/Options_About.lua` — version, blurb, every command (`MD.COMMANDS`), verify steps.
- `UI/DebugConsole.lua` — Cell's DebugConsole concept: `MD:Debug(category, fmt, ...)`
  in Core (no-op unless `db.debug.enabled`), 1000-line memory ring, movable window with
  Enable checkbox, per-category filters (regen / mana / spend / tto / combat / chat /
  other), Clear, **Copy** (select-all edit box popup, Ctrl+C), Regen test button.
  `/md debug` toggles it. `MD:Print` mirrors into the `chat` category so `/md verify`
  output is copyable too.
- Log points: `GetManaRegen` value changes, 5SR start/end, every mana tick with
  `(5SR)` marker, every priced cast with source/max-rank, unpriced spells, pull seed,
  TTO mode transitions + a full state line every 5s in combat (15s out), pull/end of
  fight, talent scans, alerts.
- `/md regentest [N]` (`Verify.lua`) — the Dreamstate test: N s (default 30) idle,
  observed mana gain vs time-weighted `GetManaRegen`, diff compared with
  `{4,7,10}% × Int / 5`; prints a VERDICT (API includes / excludes Dreamstate) and
  flags mana spent, drink buff, 5SR time or <3 ticks as invalidating.
- `UI/Dashboard.lua` — rebuilt on the kit: header bar with title/close, spell tabs as an
  accent button group, "Settings" button top-right; settings pane removed.
- `Core.lua` — `DEFAULTS.debug`, `DEFAULTS.optionsPos`, recursive `FillDefaults`,
  `MD.RELEVANT_TALENTS` + `MD:TalentSummary()`, `MD.COMMANDS`, new slash commands.
- `.toc` 0.4.0; load order Style → Widget → Dashboard → OptionsFrame → Options_* →
  DebugConsole. All 18 files syntax-checked (python3 + luaparser).

**Next:** author runs `/md regentest` (idle, partial mana, no drink) and `/md verify`,
copies the console log. Then: add the Dreamstate term to `RegenModel` if excluded;
switch percent mods to additive if `/md verify` COST lines confirm; decide Nature's
Grace. `K_SIGMA` / `CV_STABLE` tuning still pending. The kept worktree
`.claude/worktrees/feedback-round-3` is identical to master and can be removed.

## 2026-09-03 (later) — Log review: Dreamstate confirmed, costs corrected (v0.4.1)

Author ran the console on a level 64 druid (342 Int, 299 Spi) and dropped three logs into
`.logs/` (gitignored, local evidence only): `spell-cast-test.txt` (verify + casts),
`no-dreamstate-regen-test.txt`, `dreamstate-regen-test.txt` (same character, respecced).

**Findings, with numbers**
- **Dreamstate is NOT in `GetManaRegen()`.** Without the talent: ticks +121/122 per 2s
  vs API base 60.16/s (diff −0.99/s over 30s, i.e. the API is exact). With Dreamstate 3
  (and Living Spirit dropped): API base 52.86/s but ticks +121 → observed 59.6/s; raw
  diff +9.4/s of which ~2.8/s was the test's 2.5s 5SR tail, leaving ≈6.6/s vs the
  expected 10% × 342 / 5 = 6.84/s. Cross-check: the gear/buff share derived from the
  API's own two numbers is 21 mp5 in BOTH specs (S = (base − casting)/(1 − Intensity)),
  so the missing 34 mp5 is exactly Dreamstate and nothing else changed.
- **`GetSpellPowerCost` works on this client** (44 costs checked) — the v1 premise "the
  2.5.x client does not reliably expose per-rank costs" was wrong.
- **Static costs were wrong** for Rejuvenation R6–R12 (live 160/195/235/280/335/360/370),
  Tranquility R1–R4 (525/705/975/1295), Swiftmend (271); Innervate costs 67 (a % of base
  mana, level-dependent). Actual mana drops in the cast log (−370 Rejuv R12, −575 Regrowth
  R9, −220 Lifebloom) confirm the live values. All cast times matched.
- **The level-70 spirit constant (0.009327) read 2× low at level 64**: modelled 25.8/s
  vs the real spirit share 56/s, so "gear ~171 mp5" was nonsense.
- **Display bug:** `FULL 2:05` stayed on screen for 15s+ while the model said 94s. Cause:
  the OOC fill EWMA was updated every 0.5s tick from a signal that only lands every 2s,
  so it oscillated ±10%; the latch demanded the identical quantized value on two
  consecutive ticks and never got it.

**Changes**
- `Engine/RegenModel.lua`: keeps raw `RM.apiBase/apiCasting`; `RM:Unreported()` adds
  Dreamstate (`{4,7,10}% × Int / 5`) to both rates (`RM.unreported`, shown in the
  dashboard line, datatext tooltip and verify snapshot). Observed OOC fill is now an
  EWMA over gain EVENTS (gain / interval), stale after 6s. `RM:Components()` derives the
  spirit share from the API's two numbers and the in-5SR talent (Druid Intensity, Priest
  Meditation, Mage Arcane Meditation) — no level constant. Refreshes on talent change.
- `Data/SpellData.lua`: `SD:GetCost()` is **live-first** (`SD:LiveCost`) with the static
  table as fallback, returns `cost, "api"|"table"`; `SD:StaticCost()` is the table-only
  figure the verify harness diffs against. Costs above corrected; Innervate has no static
  cost. The static fallback's multiplicative percent stacking is documented as a known
  ~2% error that only matters without the API.
- `Engine/TTO.lua`: the value latch accepts a candidate within one step of the previous
  candidate (jitter-tolerant) instead of demanding the identical value.
- `Verify.lua`: COST lines now say "static X, live Y (used)"; snapshot prints raw API +
  the Dreamstate term; `/md regentest` waits for the 5SR to end before measuring,
  compares against the RAW API (so the verdict stays valid now that the model adds
  Dreamstate) and prints observed − model as the residual to watch.

**Still open:** heal-side percent stacking (GoN + Imp Rejuv, ≈1%), Empowered Touch shape
(HT R1–R4 only), Nature's Grace, Lifebloom bloom × Empowered Rejuvenation, `K_SIGMA` /
`CV_STABLE` tuning from real fights. Other classes' int-based regen talents (Shaman
Unrelenting Storm) probably share Dreamstate's fate but are unmeasured, so not added.

## 2026-09-03 (later still) — Tree of Life form (v0.4.2)

Author: heal and cost values did not follow Tree of Life form — reduced HoT cost, and the
aura that adds 25% of the druid's Spirit as healing *received* by party members (not part
of the +healing stat). Done:
- `MD:InTreeForm()` uses `GetShapeshiftFormID() == TREE_FORM` (buff-name fallback);
  `UPDATE_SHAPESHIFT_FORM(S)` fires `FORM_CHANGED`; the dashboard refreshes on it (costs
  are live-first since v0.4.1, so the −20% shows as soon as it re-renders).
- `RankMath` adds `0.25 × Spirit` to the +healing input while in form (setting
  `db.treeAura`, default on, General > Model "Count Tree of Life aura"); the dashboard line
  shows `+450 healing (+75 Tree of Life aura on party targets)`; `RankMath.info` exposes the
  inputs. The aura goes through the same coefficient/penalty path as +healing (it is a
  "taken advertised benefit" in the MaNGOS-era formula) — unverified in-game, listed.
- Gear-change toast snapshots are keyed by form so shifting never triggers "rebind?".
- `/md verify` snapshot prints the form and the aura amount.

## 2026-09-03 (evening) — "To OOM" column (v0.4.3)

Author asked what HPS is (heal per cast / time the cast occupies; 1.5s GCD for instants —
throughput of chain-casting, healing *committed* per second for HoTs) and for a "casts to
OOM" column. `RankMath` rows now carry `casts = floor((mana − cost) / (cost − castingRegen ×
interval)) + 1` from the CURRENT mana at the in-5SR regen rate (`math.huge` → "inf" when
regen covers the cost; 0 when mana < cost). Dashboard: "To OOM" column, a grey hint line
explaining HPM / HPS / To OOM with the mana and mp5 used, and a 2s re-render while open so
the column follows mana (render only). `RankMath.info` gained `mana`, `castingRegen`.

**Addendum — HP5 column (v0.4.4).** The author's "HP5" idea: healing per 5s you can sustain
at zero mana, casting only as regen pays. 5SR-aware steady state: `T = cost / casting` if 5s of
casting regen cover the cost, else `T = 5 + (cost − 5·casting) / base`, never below the cast
interval; `HP5 = 5 · heal / T`. Dashboard widened to 760 for the extra column; hint line
explains all four metrics with the two regen rates used. Not part of the Pareto filter.

**Addendum — spamtest (v0.4.5).** Author chain-cast Lifebloom in Tree form: dashboard said 42,
OOM after 24. Even zero regen gives 37 from a full pool at 176/cast, so the start mana or the
real per-cast drop must differ from what the column used. `/md spamtest` now arms a counter:
first priced cast picks the spell, counts casts, real drops and regen until OOM (or 10s idle),
and prints the prediction from the armed mana next to the measured figures, flagging a
drop-vs-live-cost mismatch. `RankMath:CastsToOOM(cost, interval, mana, regen)` is public.

**Resolved (same day).** The 42-vs-24 discrepancy was a Clique misbinding: the author was
casting Rejuvenation (296 in Tree form, ~24 casts from 6544) instead of Lifebloom. Retested
with the right spell: the To OOM column matches. Consider the column verified in-game.

**Addendum — Simulate strip (v0.4.6).** Author asked for what-if inputs. `MD.sim` (session
only) holds overrides for +healing, crit %, casting mp5, resting mp5 and mana; `RankMath`
reads them (nil = live) and reports `info.simulated` + `info.live` for the labels. Dashboard:
a "Simulate:" row under the tabs with five edit boxes (blank = live, the live value in each
label), Clear button, orange SIMULATION prefix on the stats line while any override is set.
The gear-change toast is suppressed while simulating. Frame height 496.

## 2026-09-03 (night) — Commit, clean-up, plan

Committed v0.4.6 (`9da7dfe`, 22 files); removed the stale `feedback-round-3` worktree and
branch. Wrote `docs/PLAN.md` (Phase 1 druid: close verification items → model improvements
→ UX → housekeeping; Phase 2 other classes, Priest first, built on the generic parts) and
`docs/TESTING.md` (smoke test of the new UI, `/md verify`, Tree aura test, Lifebloom bloom
test, one logged real fight for the clock constants, spamtest, Simulate). Author agreed
with all suggestions; next session starts with whatever the tests return, then PLAN §1b.

## 2026-09-03 (late) — Smoke-test fixes, heal log (v0.4.7)

Author's smoke test: Simulate row overflowed the dashboard (live values were in the labels)
→ values are now grey placeholders inside the boxes, labels short. About tab rows overlapped
(fixed 14px rows, wrapped text) → rows sized by their text, frame height measured
(`MD.optionsTabHeight`). `/md verify` in Tree form showed the client ROUNDS modified costs
(Swiftmend 216.8 → 217; static fallback floored) and discounts **Tranquility** in form too →
both fixed in `SD:StaticCost`. Tooltips show base heal only (932 in/out of form), so the aura
and bloom tests need real heal amounts → new **heal** debug category logs every SPELL_HEAL /
SPELL_PERIODIC_HEAL the player lands (amount, overheal, crit, `[tree]`); console widened to
580. `docs/TESTING.md` §3/§4 rewritten around the heal log. Tests 1, 2, 6, 7 passed.

## 2026-09-03 (late) — Heal log results (v0.4.8)

Author's heal log: **Lifebloom matches the model exactly** (tick 87, bloom 864 with Emp Rejuv
on the bloom; 829 without) → coefficients confirmed, Emp Rejuv applied to the bloom. **Tree
aura confirmed** as +healing on the target (Rejuv +21/tick, Lifebloom +7/tick, bloom +32 = 70
Spirit through the normal path), dynamic on running HoTs. **Rejuvenation ran ~3% high** (445 vs
431/tick) while Lifebloom was exact → a flat +50 on Rejuvenation only, i.e. Idol of
Rejuvenation. Added `SD.relics` (Idol of Rejuvenation, Harold's Broach, Emerald Queen, Avian
Heart, Idol of Health, Raven Goddess — all but the first VERIFY) and `SD:Relic()` reading slot
18; RankMath adds flat to the base heal, per-tick to Lifebloom ticks, aura to the Tree aura;
dashboard line and `/md verify` show the relic. Awaiting the author's confirmation of the idol.

## 2026-09-03 (end of session) — State for the next session

**State:** master at v0.4.8 (+ docs commit), clean tree, `dist/main/` built. Phase 1a of
`docs/PLAN.md` is done except the clock-constant tuning, which needs `docs/TESTING.md` §5
(one real fight with logging on; author will do it later). The relic slot is confirmed
(Idol of Rejuvenation) and heal-side stacking is settled as multiplicative.

**Next session, in order:**
1. If a §5 log is available: read the `[tto]` lines vs what happened, tune `K_SIGMA` /
   `CV_STABLE` in `Engine/TTO.lua`, record in DECISIONS.
2. PLAN §1b: Nature's Grace (cast-time EV term), Innervate-aware clock (second figure),
   overheal-calibrated HPM (per-spell overheal from `UI/Summary.lua`), persisted fight
   history (last 20 per character in `MD.cdb`).
3. PLAN §1c: per-row dashboard tooltips (breakdown of every number), Simulate form/Moonglow
   inputs, shared tooltip builder, `/md profile`.
4. Then Phase 2 (Priest first) on the generic parts; testing via guildmates' pastes.

**Gotchas learned today:** a new build needs `/reload` before ElvUI datatexts re-register
(looked like a broken integration once); tooltips on this client show base heal only, so
formula checks go through the `heal` debug category; the user reads `.logs/*.txt` back to
me — ask for them instead of guessing.

## 2026-09-03 (design session) — v0.5 design and architecture

No code. The author deferred the `docs/TESTING.md` §5 combat-log run and asked for the
detailed design of everything still planned. Wrote **`docs/DESIGN-v0.5.md`**, covering
`docs/PLAN.md` §1b (Nature's Grace, Innervate-aware clock, overheal-calibrated HPM,
persisted fight history), §1c (row tooltips, Simulate form/Moonglow, one tooltip
builder, `/md profile`) and §1d, plus the Phase 2 seams.

**Architecture decided:** `RankMath` splits into `Context()` / `RowFor(spell, ctx,
variant, explain)` / `Compute()` / `Explain()` so a row's intermediate terms are
reachable for tooltips and `/md profile` without churning tables on the 2s re-render;
`SD:StaticCost(id, ctx)` takes an override context and **sums** percent cost modifiers
(the client's behaviour, already recorded in the code comment) because the simulate
strip now depends on that path; new `Engine/Overheal.lua`, `Engine/ManaCooldowns.lua`
(class table, Innervate value shared by the clock and the advisor, Phase 2 stubs),
`UI/Tooltip.lua` (one `{l, r}` line builder for both datatexts, the minimap, the widget
— which gains a hover tooltip — and the dashboard); `UI/Summary.lua`'s two duplicate
combat-log handlers collapse to one; `UI/Dashboard.lua` splits into `_Rows` / `_Simulate`;
copy popup and verify snapshot extracted as `MD:ShowCopyPopup` / `MD:Snapshot`.

**Model calls:** Nature's Grace as the exact mixture `(1-p)*T0 + p*max(T0-0.5, 1.5)`
rather than `cast - 0.5*crit` floored (the floor clips wrongly), fed to HPS, HP5 and To
OOM; Innervate as `max(0, (5*S + G + U) - RM:Effective()) * 20 - cost`, i.e. the marginal
gain over what the clock already projects, suppressed while the buff is up; overheal
weighted by amount with a 150-event half-life, rank scope when it has 40 events else
family, and the Pareto/suggested rank deliberately left on raw values so a noisy
measurement can never fire a "rebind?" toast.

**Delivery order:** v0.5.0 architecture alone (the only step with regression risk),
then NG, then cooldowns, then overheal + history, then the UX step.

**Open for the author:** §11 of the design lists the five contested calls (`inn` on the
one-liner vs tooltip-only; overheal family-average vs rank-only; effective mode as a
toggle vs a column; Nature's Grace in the mana columns or HPS only; time/gear decay on
persisted overheal). Offered the usual Opus-party + Fable-judge debate on those before
v0.5.2. Two model assumptions ship with a debug line that settles them next play
session: the 0.5s Nature's Grace value (new `cast` category) and whether Innervate's
400% touches anything but the spirit share (`regen` line on buff gain/fade).

## 2026-09-03 (implementation) — v0.5.0 to v0.5.2

Author approved the design and said to start implementing. Three of the six planned
releases landed; `docs/DESIGN-v0.5.md` §9 is the remaining order (overheal + persisted
history, then the UX step, then docs).

**v0.5.0 — architecture, no intended behaviour change.** `RankMath` split into
`Context()` / `RowFor(spell, ctx, variant, explain)` / `Compute()` / `Explain()`;
`row.calc` is only allocated when asked, so the dashboard's 2s re-render churns nothing.
`SD:StaticCost(id, ctx)` takes an override context and now **sums** percent cost
modifiers, which is what the client does (the multiplicative fallback was a documented
~2% error). New `UI/Tooltip.lua` is the single `{l, r}` line builder behind both ElvUI
datatexts, the minimap button and the widget — the widget gained a hover tooltip and a
left-click shortcut, which needs mouse input on the frame, hence `db.widgetTooltip`.
`UI/Summary.lua` went from two combat-log handlers and three
`CombatLogGetCurrentEventInfo()` calls to one of each. `UI/Dashboard.lua` split into
`_Rows` / `_Simulate` on `MD.DashboardParts`. `MD:ShowCopyPopup` and `MD:Snapshot`
extracted for the coming `/md profile`.

**v0.5.1 — Nature's Grace.** `E[T] = (1−p)·T0 + p·max(T0−0.5, 1.5)`, the mixture rather
than `cast − 0.5·crit` floored (that form clips the wrong branch when `T0−0.5` lands on
the GCD). Throughput over a chain is `heal / E[T]` exactly, so averaging the cast time is
correct for a sustained column. Feeds HPS, the HP5 interval floor and To OOM — To OOM
goes slightly **down**, because a faster cast earns less regen, which is right. Grey `*`
in the Cast column, `db.naturesGrace` in Options > Model, and a new `cast` debug category
logging the client's own cast duration against the model — the thing that will settle the
0.5s and Naturalist, neither of which is in the spellbook tooltip.

**v0.5.2 — mana cooldowns.** `Engine/ManaCooldowns.lua` owns the class table (Druid live;
Priest/Shaman/Paladin stubs awaiting a value model and one log from that class) plus the
potions, and returns the **marginal** mana a source buys:
`max(0, (5·S + G + U) − RM:Effective()) × 20 − cost`. Suppressed entirely while the buff
is up, since `GetManaRegen` already reports the boosted rate then. The clock's secondary
segment shows `inn 2:10` instead of `rest` when the clock is ≤90s, the cooldown is ready
and it is worth ≥10% of the pool (`db.showCooldown`); the advisor's own rough 3.5×
estimate is gone, so the two can no longer disagree on screen. Results are cached for
0.4s because the advisor and the clock both ask every tick.

**Next:** v0.5.3 (`Engine/Overheal.lua`, effective mode, `cdb.fights` + zone-aware seed),
v0.5.4 (row tooltips wired to hover, Simulate form/Moonglow row, `/md profile`), v0.5.5
(TESTING/DECISIONS + release). Two assumptions ship with a debug line that proves them on
the author's next play session: the 0.5s Nature's Grace value (`cast` category) and
whether Innervate's 400% touches anything beyond the spirit share (`regen` category, on
buff gain/fade).

## 2026-09-05 — v0.5.3 to v0.5.5: overheal, row tooltips, /md profile, docs

Finished the `docs/DESIGN-v0.5.md` delivery order. **All of `docs/PLAN.md` §1b, §1c and
§1d is now shipped**; what is left in Phase 1 is the author's in-game logs.

**v0.5.3 — overheal + persisted history.** `Engine/Overheal.lua` measures overheal per
family and per rank from the combat log, weighted by amount (so a 4-tick Rejuvenation and
a Healing Touch count in proportion to the healing they did), decayed per event with a
150-event half-life, gated at 40 events, persisted in `MD.cdb.overheal`. An "Effective"
checkbox on the dashboard switches Heal/HPM/HPS/HP5 to `value × (1 − overheal)` and turns
those four headers the class colour; Mana, Cast and To OOM never move. A rank with no data
of its own keeps its raw value and gets a grey `?`. The Pareto filter and the suggested
rank stay on raw values deliberately (DECISIONS v0.5 §3).

While doing it, found and fixed a latent ambiguity: WoW documents `SPELL_HEAL`'s `amount`
both ways (gross vs net of overheal) and `UI/Summary.lua` had quietly assumed net. A full
overheal discriminates — gross reports `amount == overheal`, net reports `amount == 0` —
so the first unambiguous sample latches `db.healAmountGross` and `OH:Split()` feeds both
the dashboard and the fight summary's `overheal N%`. Net stays the default until proven,
so nothing moves on its own. `/md profile` prints which way it latched.

Fight history persists: `MD.cdb.fights`, last 20, with timestamp, zone and heal totals;
`MD.fightHistory` is bound straight to it so nothing else changed. The pull-time seed now
prefers the median of recent fights **in the current zone** when ≥2 exist — spend rate is
content, not character.

**v0.5.4 — the UX step.** Dashboard rows hover to the full derivation of every number
(`RankMath:Explain()` rebuilds one row on demand, so the 2s re-render still allocates
nothing). The Simulate strip gained a second row: form (Live/Caster/Tree — three states,
because "follow my real form" is a distinct answer from "caster") and a Moonglow box;
neither touches `MD:InTreeForm()`, and simulating either falls costs back to
`SD:StaticCost(id, ctx)`. `/md profile` and a "Copy profile" button put every input, the
max ranks' live-vs-static costs, the clock state and all settings into the copy popup.

**Layout fix found while testing the math.** The hint paragraph under the callout was
~265 characters in a 728px slot 18px above the table — it was already at risk of wrapping
onto the rows, and Nature's Grace made it longer. Replaced with one short line; the full
column glossary moved to a tooltip on the **header row**, which is a better home for it
anyway. Flagged in `docs/TESTING.md` §1 as the layout risk to look at.

**v0.5.5 — docs.** `docs/TESTING.md` rewritten for this build: a new §0 regression pass
(v0.5.0 rewrote four tooltips and the rank math internals with no intended number change),
and new §8 (Nature's Grace cast times via the `cast` category), §9 (Innervate's value via
the `regen` lines around the buff) and §10 (overheal over a raid night). §5 still
outstanding and now yields §9 as a by-product, so one good fight covers three tests.
`docs/DECISIONS.md` gained a v0.5 section recording the nine calls made without a debate
round, each with what would change my mind, plus a table of the four remaining assumptions
and the log line that settles each. `CLAUDE.md`'s file table updated for the four new files.

**State:** v0.5.4 built to `dist/combat-log-design-arch-ffb907/`, tree clean, branch
`claude/combat-log-design-arch-ffb907` (6 commits ahead of master, not merged).

**Next session:** whatever the author's logs say. In priority order — TESTING §0 (did
anything regress), §8 and §9 (turn two assumptions into measurements), §5 (`K_SIGMA` /
`CV_STABLE`), §10 (overheal after a night). Then Phase 2, Priest first, on the seams
`Engine/ManaCooldowns.lua` and `RankMath:Context()/RowFor()` now provide.

## 2026-09-05 (later) — First real dungeon log analysed; v0.6 designed

Author supplied `.logs/dungeon-BF-1.txt` — Blood Furnace, 28.8 min, 5600 lines, 30 pulls,
355 casts, on a **v0.5.x** build (it carries `cast` lines and the v0.5.2 cooldown
segment). **Caveat the author supplied and that runs through the whole design: it was a
level 61 dungeon on a level 64 druid.** Heroics and raids differ in duration and damage
pattern, so nothing from it is set in stone — which is itself the argument for
self-calibration.

**What the log proved**

- **A real display bug.** `OOM 0s vv` in red at 72-97% mana, 9+ times. `hold` sets
  `s.bound`, not `s.tto`; the mode latch holds `disp.mode == "oom"` for two ticks after the
  state improves, so the display reads `state.tto`, gets nil, and `v = v or 0` fabricates
  zero seconds straight into the critical band. v0.5.2's segment then appended `inn >10m`.
- **The combat log's `amount` is GROSS.** 561 events with `amount == overheal`, zero with
  `amount == 0`. So the pre-v0.5.3 fight-summary formula `o/(a+o)` understated: real
  overheal for the run is **38.0%**, not 27.5%. The v0.5.3 detector would have latched
  correctly within seconds. Detecting rather than assuming was the right call.
- **Per-spell overheal spans 5x**: Regrowth direct 10.8%, Swiftmend 25.7%, Lifebloom tick
  38.2%, Rejuv tick 45.0%, Lifebloom bloom 49.8%, Regrowth HoT tick 51.2%.
- **Cast mix**: Lifebloom 69% of casts / 54% of mana; Healing Touch **one cast in 29
  minutes** (Tree form). The dashboard opens on Healing Touch. ~7% of mana went to buffs,
  dispels and form shifts, invisible to every view.
- **The clock works when it matters.** My first read called it noise; the author corrected
  me ("most fights were easy, but there was one where I went full out"). On that pull —
  154 mana/s, -508 net mp5, 6.2k in 40s — it tracked `5:00 -> 3:00 -> 2:00 -> 1:00`
  monotonically and showed `inn 3:30` at 49% mana / 80s. The v0.5.2 cooldown segment
  validated in its first real test. `sigma/net` separates that pull (median 0.43) from
  everything else (median 1.01), which is the whole fix: gate the digits, don't retune.
- **Innervate never cast**, so its value model is still unverified; all four potion alerts
  ignored. Nature's Grace inconclusive — 27 cast lines, all Regrowth at exactly 2.00s, and
  Naturalist is 0 (the debug line would print 1.50s base otherwise).

**A correction worth recording.** I claimed TBC exposes no role API, having checked
`Cell/Utils.lua` and `Libs/LibGroupInfo.lua`. The author pushed back ("cell already renders
role icons"). They were right: `RaidFrames/UnitButton_Vanilla.lua` — the file
`Cell_TBC.toc` actually loads — calls `UnitGroupRolesAssigned(unit)` unguarded, and
`roleIcon` ships enabled by default in `Layout_Defaults_TBC_Vanilla.lua`. Bad inference
from absence: I checked the files I expected to hold it and stopped rather than following
the feature to the file that draws it. Role is now **read, not inferred**, with
`roleSource` carried into every report.

**Shipped meanwhile:** v0.5.6, fixing the debug console's category filters — adding a
ninth category (Cast) overflowed a chained single row (~603px in a 580px frame) and
collided with the "keep lines" box at the same y. Now a fixed 5-column grid whose row count
follows the category count, console 580x480 -> 700x560.

**Written this session:** `docs/DESIGN-v0.6.md` (452 lines: architecture, the C1
calibration design, the waste report's dimensions, delivery order v0.6.0-v0.6.6, open
questions), `docs/DECISIONS.md` §v0.6 (nine calls with what would change my mind), and
`docs/PLAN.md` Phase 1.5.

**Priority, set by the author:** C1 self-calibration -> A waste report -> D1 logging -> B1
pull budget -> D2 Cell (investigate; they have the upstream maintainer's ear). Logging
(v0.6.1) ships before the waste view because the role dimension rests on
`UnitGroupRolesAssigned` returning real values in the author's groups, and the roster log
line is what proves it.

**Next:** implement v0.6.0 (HP5 redefinition + the two clock fixes + small fixes). Nothing
in v0.6 touches `K_SIGMA` / `CV_STABLE`, which remain `docs/PLAN.md` §1a.


## 2026-09-05 (implementation) — v0.6.0 to v0.6.6 shipped

Author reviewed `docs/DESIGN-v0.6.md` (published as a page), made one change — **remove
HP5 rather than redefine it** ("it does not provide new insights": chain-casting in the
5SR it reduces to `5 x castingRegen x HPM`) — and said to proceed. Seven releases, in
the design's order, each luaparser-checked and built; nothing run in-game yet.

**v0.6.0** — the red `OOM 0s` is gone: the tick keeps the last shown value while the mode
latch holds `oom` over a `hold` state, and the display renders `OOM --` when there is
none; `v or 0` deleted. Digits gated on `sigma/net <= db.oomConfidence` (0.7, a
percentage slider with its provenance in the tooltip): above it the clock shows the bound
`OOM >2:00 =`, `rest` shows unconditionally, the cooldown segment stays off; digits return
after two confident ticks. Re-derived inside `oom` mode only: hard pull median 0.41, quiet
median 0.73 — 0.7 keeps all six hard samples and drops 55% of quiet digits (not the 80%
first claimed, which had mixed in `hold`). HP5 column removed. Dashboard opens on the
most-cast family (`MD.cdb.familyCasts`). Advisor names the richer cooldown it is holding.

**v0.6.1** — `Engine/Targets.lua`: roster with class, role and **roleSource**, role read
from `UnitGroupRolesAssigned` → `GetPartyAssignment` → class-implied → unknown. Logs:
Copy prepends `MD:Snapshot()`; `roster:` at each pull; `shown:` on every display change;
`cooldown used:`; the `cast` line applies Naturalist only to Healing Touch (it applied it
to everything — harmless at rank 0) and states the Nature's Grace rank. `/md export` TSV.

**v0.6.2** — `Engine/Calibration.lua`: observed / predicted per spell and event kind, crits
separated (rate checked independently), no decay (a ratio is gear-invariant), reset only on
a changed talent build (TALENTS_CHANGED fires at every login, so the summary string is
compared). Lifebloom stack fitted from x1/x2/x3, ambiguous ticks skipped and counted; events
within 2s of a form change skipped. 3% drift alert at n ≥ 30 — the Idol case was 3.2%, a
5% line would have missed it. `RankMath:EventPrediction()` on `Explain()`. `/md calibrate`.
**Caught before shipping:** the same `a and f() or b` truncation of `Overheal:Split` that
v0.5.3 fixed once already in `UI/Summary.lua`. Now in CLAUDE.md as a named trap.

**v0.6.3** — `Engine/Overheal.lua` rewritten: six dimensions (family, spell, spell:kind,
role, class, per-target), two stores (persisted decayed / session undecayed; targets only in
session, pruned on `ROSTER_CHANGED`), wasted-mana attribution per event kind (cost/ticks;
cost; hybrid half/half; AoE cost/(ticks×group); bloom 0). `UI/Dashboard_Waste.lua`: the
fifth tab, by Spell / Role / Class / Target, session or all; any class. Spend tracker keeps
per-family spend for session and fight, "other" catching buffs/dispels/forms; the fight
line gains `(LB 52%, RG 22%, ...)` and `~1.5k into full health`.

**v0.6.4** — Lifebloom rows weighted tick/bloom separately via `OH:KindFraction`; the
callout says "keep the stack rolling" or "let it bloom" with both fractions and effective
HPMs. Life Tap counted per member from `SPELL_CAST_SUCCESS`, shown as `Life Tap xN` in
Target mode.

**v0.6.5** — `Engine/PullBudget.lua`: median mana per pull in this zone → "2 more, or 4
after a drink", in the OOC tooltip and as the drink reminder's text.

**v0.6.6** — docs. `docs/TESTING.md` §0b (v0.6 regression), §11 calibration, §12 Waste +
the roster question (are roles actually assigned in the author's groups?), §13 pull
budget, §14 export. `CLAUDE.md` file table and conventions (calibration never feeds the
model; the multi-return trap; constants from one log are settings). `docs/DECISIONS.md`
§v0.6 items 10–13.

**State:** branch `claude/combat-log-design-arch-ffb907` at v0.6.6, 11 commits ahead of
master (master is at v0.5.5). `dist/combat-log-design-arch-ffb907/` built. **Nothing in
v0.6 has run in-game.** The two things I most want from the next logs, in order: the
`roster:` lines (does `UnitGroupRolesAssigned` return roles in a guild premade?) and
`/md calibrate` after a night (are the ratios 1.000 — and how many Lifebloom ticks were
skipped for stack ambiguity?).

**Still open from before:** `K_SIGMA` / `CV_STABLE` (§5), Nature's Grace 0.5s (§8 — needs a
Healing Touch in caster form), Innervate's value model (§9 — never cast), haste (unmodelled).

**v0.6.7 (same day)** — relics. Author: "can't we just check if it's equipped?" — we do,
and the framing was wrong: the slot check applies a known idol exactly; calibration is for
the *value* when it was never measured. `verify` is now data; the drift alert names the
equipped relic and solves for its true value. Looked every ID up instead of trusting memory
and found two wrong entries (Idol of Health is a cast-time relic; Emerald Queen is +88 to
the HoT total, not +47/tick) and one wrong ID (Budding Life is 33508, not 33076). Added the
TBC cost-only idols (Budding Life, Crescent Goddess) and cast-time relics as kinds. Sources
in `Data/SpellData.lua`.

## 2026-09-05 (evening) — First regression logs on v0.6.7; v0.6.8

Author ran `/md verify`, a `/reload`, `/md profile` and `/md spamtest` (`.logs/regression/`).
**A respec happened between the two sessions**: the talent line now reads Intensity 3,
Dreamstate 3, Lunar Guidance 3, Moonglow 3, Nature's Grace 1 / Gift of Nature 1, Improved
Rejuvenation 3, Naturalist 5 — a Dreamstate build, **no Tree of Life**. Everything Tree-
specific is dormant; calibration's reset-on-build-change is exactly for this.

**Passed:** verify (0 cost mismatches), spamtest (13 predicted, 13 measured), the snapshot
header on every Copy, the overheal convention latching GROSS on the first heal, the
shown-string and cooldown log lines, `Drink.` falling back correctly with no fights recorded.
**Nature's Grace confirmed:** two casts after a crit at `live 1.50s`, the rest 2.00s.

**Calibration caught a real error on its first run.** Regrowth R9 direct: observed 1282
(11 non-crit), model 1488, ratio 0.862. Two things at once: (1) the model was reading the
Simulate strip — the implied simulated +healing is exactly 2400, a round number the author
had typed for TESTING §7 — so `EventPrediction` now uses `Context({ live = true })`; (2) with
live inputs the model was 1172, still 9% low, and the one HoT tick (209 observed vs 232
predicted) pointed at the split: **Regrowth's +healing is split by base amounts
(0.286 / 0.701), not by coefficients (0.166 / 0.994)** — the amount-weighted split predicts
the tick at 209.3. Switched; DECISIONS §15. A +3.7% residual on the direct remains and is
not the idol.

**Also fixed:** `GetSpellCooldown` returns the GCD for 1.5s after any cast, so "cooldown
used: Innervate" fired on every Regrowth (≤1.6s now means ready); the author's own heals
were filed under role UNKNOWN when solo (now `HEALER (self)`); `/md verify` compares against
the model's cast time so Naturalist no longer counts as 13 mismatches. **Relic:** the author
wears Communal Idol of Life (186054), an Anniversary green: +15 Rejuvenation, added,
unverified. **Open:** the `/md profile` paste was a 0-byte file — bug or paste failure
unknown (TESTING §2b).

**Still to test:** §0b, §2b, §12 roster in a group (the biggest unknown), §5, §9, §11 after
a night, §13, §14. Committed as v0.6.8 and fast-forwarded into local master; not pushed.

## 2026-09-05 (night) — v0.7 designed: combat simulation and fight review

Author asked for a combat simulator: presets for party size, incoming damage and starting
situation, overrides per target, and a search for the cheapest human-castable strategy that
keeps everyone alive. Wrote `docs/DESIGN-v0.7.md` (published as a page for review).

**Author's review reframed it.** Three points: (1) "wait" is a valid action — in a
non-heroic 5-man the less you drink the faster the run; (2) **replay is the killer
feature** — analysing real dungeon logs and suggesting improvements, so the healer
self-improves with each iteration; (3) the made-up damage numbers get replaced by presets
generated from recorded fights, and the hard-coded ones improved from logs over time.

**Rev 2 of the design** puts recording first: `Engine/FightRecorder.lua` captures per fight
every hit the group took, every heal anyone *else* landed (negative damage on the timeline
— which dissolves the "other healers" problem for replays), the healer's own casts and mana,
and HP snapshots; persisted, last 12 fights, capped at 4,000 events each. The simulator
takes damage as a **timeline** (recorded) or **analytic** (rate + pulse), both just events.
Review pane: **Validate** (real casts must reproduce the real mana and HP curves — the
engine is proven before any planner work) and **Coach** (the search on the real damage, then
each actual cast classified against the best plan's rules with six labels: fine / overheal /
rank / spell / early / idle; summed over fights into **habits** with their mana). Presets
from recordings carry provenance. Delivery: recording first (it needs runs to gather
material), engine + replay second, planner third, synthetic setup last.

**Open before implementation:** whether `UNIT_SPELLCAST_SUCCEEDED` carries the target on
this client (assumed not; cast→first-heal matching with a reported match rate); whether
`SWING_DAMAGE`'s amount is after absorbs; recording size in practice; the six labels'
sufficiency. Eleven contested calls in §12 — the author's debate round is on offer.

## 2026-09-05 (late) — v0.7 debated, decided, specified

Author: run the debate, make every crucial decision, produce a spec a fresh Opus session can
implement from. Also pointed at Details! for combat-log parsing.

**Details settled two recorder questions before the debate:** `SPELL_CAST_SUCCESS` carries
`destGUID` (the cast's target — no cast→first-heal matching), and `amount` on damage is HP
actually lost, `absorbed` separate, full absorbs as `*_MISSED ABSORB`; exact arg layouts in
`docs/SPEC-v0.7.md` §1.

**The debate:** two Opus parties (theorycrafter / healer pragmatist), rebuttals, Fable judge —
all six papers preserved in `docs/debates/v0.7-sim/`. The parties converged on most calls; the
judge ruled the rest and verified both parties' log numbers (gates pass 18/25/13 of 30; median
pull 24.6 s, 6 casts; LB→LB gap median 5.02 s; inter-cast gap p10/p25 1.50/1.52 s). The three
corrections that mattered most: the planner must be **causal** (B — otherwise it sells
prophecy as advice), **cast commitment** (B — the design's re-decide loop gave the sim a free
option), and the design's simulation cost was **10× optimistic** (A). Two log-proven traps:
HoTs ticking 19 s before the pull (initial state), and 10 form shifts = 3.3k mana plus a
healing multiplier the sim was blind to. Everything else is in DECISIONS §v0.7.

**Written:** `docs/SPEC-v0.7.md` (file-by-file: the `kind` enum, capture list, stream layout,
retention, `SpellKit`, `Run` and its zero-allocation rule, the causality invariant text, the
plan schema with parameter domains, the lexicographic score, the six gates with settings and
provenance, the label rules and precedence, the card template, self-tests, `.toc` positions, a
crosswalk to the judge's 28-item checklist) and **`Data/SimFixture_BF1.lua`**, generated from the
log — 19 casts, 90 mana samples, 5 form events, initial state — so the engine's mana half can be
validated before any fight is recorded.

**State:** branch at the spec commit, fast-forwarded into local master, not pushed. **Next
session:** implement v0.7.0 from `docs/SPEC-v0.7.md` §2; nothing in v0.7 re-opens a ruled call
without new in-game evidence.

## 2026-09-06 — v0.7.0: HP-at-cast, the pre-pull ring, plan-free labels

Author: "now as we have the specs — implement them." First step of `docs/SPEC-v0.7.md` §0.

**What shipped (spec §2, all of it in `UI/Summary.lua` plus two one-line settings):**

- **Own-cast capture.** The single combat-log handler now also takes `SPELL_CAST_SUCCESS`
  from the player and records `{ t, spellID, cost, tgt, hpAtCast, form, kind }`. The cast's
  target comes from the prefix `destGUID`/`destName` (settled against Details!, spec §1), so
  there is no cast→heal matching anywhere. `kind` is `shift` (seven shapeshift IDs), `heal`
  (`SD.families` member) or `utility` (everything else priced — Innervate, buffs, dispels).
  **Anything unreadable is −1, never 0** — the OOM-clock bug that fabricated a zero is the
  reason that rule exists.
- **The 20 s ring** (`MD.Recorder.ring`), pruned on append, copied into `fight.precasts` at
  `PLAYER_REGEN_DISABLED`. The log's proven trap — HoTs ticking 19 s before the pull — is now
  visible to the addon at the moment the pull starts.
- **HoT tick ownership.** A Rejuvenation/Regrowth/Lifebloom cast record owns the ticks that
  follow it (`ticksSeen`, `tickGross`, `tickOver`, keyed `guid\029family`). That makes both
  derived labels measurements rather than guesses: `early` is "≥2 ticks were still pending"
  and `prehot` is "its pre-pull ticks were ≥50% overheal". Lifebloom is tracked but exempt
  from `early` — refreshing it before the bloom is the play, which is the correction the
  debate made to the original design.
- **Plan-free labels** at `PLAYER_REGEN_ENABLED`, precedence `utility → shift → early →
  overheal → ok`, one per cast, with the identity `sum(labels) == fight spend` printed in the
  new **`sim`** debug category and shouted as `label identity BROKEN` past a 2%/50-mana
  tolerance. The two figures come from different sources on purpose (combat log vs
  `UNIT_SPELLCAST_SUCCEEDED`), so the check is real.
- **The summary line**, exactly the spec's format:
  `14 of 19 casts on targets above 85% (2.9k): Lifebloom 9, Rejuvenation 4, Regrowth 1 -
  utility/shifts 1.6k - buffed in combat: Mark of the Wild at 0:39`, plus a second line when
  anything was pre-HoTted onto a full-health target.
- **History to 200 rows** with `labels`, `labelCasts`, `hpBuckets`, `prehot`, `lowestMana`,
  `ownCasts` (`foreignShare`/`streamID` wait for v0.7.2), and a new gate: a fight under four
  own casts is no longer recorded at all — it says nothing about how the healer played and
  would poison both the spend seed and the habit counts.
- `db.simFullHp = 0.85` (a setting with provenance, not a constant) and the `sim` debug
  category in the console grid.

**Two judgement calls the spec left open.** The "N of M above 85%" clause counts *health at
cast*, independent of which label won the precedence, so an early refresh on a full tank is
counted in both places — the alternative made the headline number depend on label ordering.
And `hpBuckets` counts heal casts only; a shapeshift's "target health" is the player's and
means nothing.

**Verification:** syntax-checked (no Lua interpreter here; the harness is the python
checker). The real check is in-game and is written up as **TESTING §15** — it depends on §12
(roster/`UnitGroupRolesAssigned` in a group), because `hpAtCast` resolves through
`Targets.byGUID[guid].unit`. Solo, only the player's own health resolves.

**Next:** v0.7.1 — `RankMath:SpellKit`, `Engine/SimModel.lua` (mana half), `/md simrun`
self-tests, `/md simreplay fixture` against the already-generated `Data/SimFixture_BF1.lua`.
