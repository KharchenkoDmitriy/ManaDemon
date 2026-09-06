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

## 2026-09-06 — v0.7.1: the simulation engine, and a real test harness

**The biggest thing that happened is not in the addon.** There is now
`tools/run.sh tools/simcheck.lua`: a WoW API stub (`tools/wowstub.lua`) plus a real Lua 5.1
that `tools/run.sh` downloads and builds into `tools/.lua` on first use. It loads the actual
non-UI files and runs `/md simrun` and `/md simreplay fixture` outside the game. The repo has
never had a way to execute its own logic before, and it immediately earned its keep — see the
sample-ordering bug below. Keep `tools/harness.lua`'s file list in step with the `.toc`.

**Shipped (spec §3):**

- `RankMath:SpellKit(opts)` — every known rank of every family flattened to plain numbers,
  once per form, from `Context({ live = true, healer = ... })`. This is the only boundary
  between the rank math and the engine; the engine never calls `RowFor`. Crit is stripped
  from `direct` on purpose (the engine decides expectation vs roll). Swiftmend is valued off
  the highest known Rejuvenation/Regrowth; Tranquility is carried with `dataMissing = true`
  because `Data/SpellData.lua` has no heal values for it and a planner must not invent them.
- `Context(opts)` gained `opts.healer`, applied exactly where the Simulate strip's overrides
  are and nowhere else.
- `Engine/SimModel.lua` — the engine. Binary heap over parallel arrays keyed `(t, prio, seq)`
  for ticks, expiries, committed casts and decisions; recorded timelines (damage, foreign
  heals, forms, rates, script) read by **cursor**, never copied, so a 1,500-event fight costs
  three integers of state; per-run scratch from a reused pool slot. Scripted runs (replay,
  self-tests) and deciding runs (v0.7.4) share one code path.
- `/md simrun` — ten assertions, all passing: heal amount against the dashboard row, chain
  casts against `CastsToOOM`'s closed form, ticks dropped on refresh, one bloom per Lifebloom
  stack, Swiftmend eating Regrowth before Rejuvenation, nothing landing on a corpse, the 5SR
  switching rates at exactly 5.0, the GCD holding two instants 1.5 s apart, and Run's cost
  being flat in the timeline length.
- `/md simreplay fixture` — replays `Data/SimFixture_BF1.lua` and prints **three** numbers.

**Three spec corrections, all from evidence, all written up in DECISIONS §v0.7.1:** mana
leaves (and the 5SR restarts) when a cast *succeeds*, not when it starts — the log's `[mana]`,
`[spend]` and `5SR start` lines share the `UNIT_SPELLCAST_SUCCEEDED` timestamp; regen is
integrated continuously rather than in 2 s ticks; and a recorded sample sitting exactly on an
event's timestamp is read after **every** event at that instant. That last one was a genuine
bug the harness caught — a cast sharing its timestamp with a form change was sampled before it
had paid for itself, which put the fixture's worst error at 13.7%. Fixed: **2.8%**.

**Fixture result:** spend reproduced exactly (6169 vs 6169), `measured` mean **1.3%** / max
**2.8%** of pool — inside spec §3.9's 2% / 5% gate.

**And a finding worth more than the engine.** The fixture cannot be reproduced by the regen
model alone: over 40 s continuously in the five-second rule the player gained 2072 mana while
`GetManaRegen` accounts for 1141. The missing 931 (23 mana/s, **116 mp5**) arrives as two
clean periodic streams visible in the log — exactly 17 every 2.00 s, and bursts of 13-15 on a
~3 s cycle. Dreamstate is ruled out (no points in it). Blessing of Wisdom from the party's
paladin fits the first stream and would be invisible to `GetManaRegen` for the same reason
drinking is. Nothing has been added to the model: `docs/TESTING.md` **§16** is the in-game
test that settles it, and it is now the most valuable thing on the testing list.

**Drive-by:** `lbHot` / `lbBloom` in `RowFor` were globals — correct by luck, but `_G` writes
on a path the dashboard runs every 2 s.

**Next:** v0.7.2 — `Engine/FightRecorder.lua` (full streams) and the `/md export` recording
section.

## 2026-09-06 — v0.7.2: the fight recorder

`Engine/FightRecorder.lua` (spec §4). The full stream of one pull as parallel arrays of
numbers: damage on tracked targets (minus overkill), full absorbs, foreign heals, own casts,
own heals and ticks with the crit flag, cast starts with a synthesized `CANCEL` when no
success follows, form changes, mana samples every 2 s, HP snapshots every 5 s, deaths, the
initial aura scan and the 20 s pre-pull ring. Indexed by the **same session roster the v0.7.0
cast records use**, so a precast's `tgt` and a damage event's `tgt` mean the same person with
no translation anywhere.

Tracked is the party in a 5-man and the player's subgroup plus main tanks in a raid; nothing
about an untracked unit is recorded at all. Gate `dur >= 20 and ownCasts >= 5`; eight streams
kept, and the one that goes is the cheapest fight that is neither pinned nor one of the three
most recent — mana spent is the proxy for "did this pull have anything to teach". `/md export`
gained the `# recording n` blocks (roster, initial, precasts, ev, hp, mana).

`UI/Summary.lua`'s single handler now unpacks the 11-field prefix plus ten generic payload
slots and forwards them; the recorder decides what is worth keeping. That keeps the promise of
one `CombatLogGetCurrentEventInfo()` call per event.

**`tools/reccheck.lua`** drives a whole fake pull — a party of five, damage on the tank and the
mage, own casts including a utility buff, a Rejuvenation refreshed with ticks pending, a
Lifebloom on a full-health target, a foreign heal, a death, pre-pull HoTs that all overheal —
through the real handler, and asserts twenty things about the stream, the labels, the summary
row and `/md export`. All twenty pass. It found two real bugs while being written:

- `FightRecorder:Start` snapshotted the roster **before** the tracked set assigned indices to
  group members nobody had healed yet, so every stream's roster had one entry.
- and (in the test itself, which is worth recording because it is the trap CLAUDE.md names)
  splicing a helper's eleven return values into a non-final argument position truncated them
  to one, silently swallowing every scripted combat-log event.

**Next:** v0.7.3 — the HP half of replay, the six gates, `/md simreplay [n]`, Validate.

## 2026-09-06 — v0.7.3: replay, and eight gates a fight must pass to be coached from

`SM.ScenarioFromRecording(rec, kit)` turns a recorded fight into a scenario: everything the
healer did becomes a script (the recorded casts at their recorded costs, in the recorded
forms, against the recorded regen rates), everything that happened to the group stays the
recorded timeline. **The engine ignores the recorded own-heal events entirely and generates
its own from the spell kit** — that is the whole point. If the model's Rejuvenation is wrong,
the health bars will not come back, and the gates say so instead of the Coach quietly building
on a bad model.

The engine gained a second sample cursor so health is sampled on the recorder's own 5 s
schedule while mana keeps its 2 s one; merging them would invent readings neither stream has.

`SM:Validate(rec)` runs the eight gates from spec §7, each printing the **provenance of its own
threshold**: mana mean (2% of pool) and max (5%), health per target (5% mean / 15% worst of
max health), no tracked death, foreign share (25%), model calibration (3% drift on any spell
worth ≥ 10% of the fight's spend; "not yet calibrated" is printed, not failed), and spend
coverage (≥ 90% of the mana on spells the model prices). `/md simreplay [n]` prints the lot
with a verdict; `MD:ValidationReport` is what the Review tab's tooltip will show.

Two judgement calls while writing it, both tightening the gates:

- **A target that misses is excluded, not fatal.** One pet-heavy warlock should not
  disqualify the tank's timeline. The health gate passes if at least one damaged target
  reproduces, and names the ones that did not.
- **A target that took no damage is not scored at all.** It reproduces itself perfectly and
  proves nothing; the first cut counted two untouched party members as passes, which made the
  health gate meaningless. `tools/reccheck.lua` caught it.

`Engine/Calibration.lua` gained `CAL:Drift(spellID)` — worst |ratio − 1| over event kinds with
enough samples, `nil` when uncalibrated. `nil` means "unknown", not "fine", and the gate says
so.

**Verified:** `tools/run.sh tools/reccheck.lua` now 25 assertions, all passing, including that
the scripted pull — which has a death and 69% foreign healing — is **rejected**. A gate suite
that passed everything would be worth nothing.

**Next:** v0.7.4 — `Engine/SimPlanner.lua`, the rules plan, the classifier and the card.

## 2026-09-06 — v0.7.4: plans, the classifier, and the card

`Engine/SimPlanner.lua`. The causality invariant from spec §5.2 is pasted at the top of the
file, and the code keeps it: `Plan:Decide` reads the present state plus exactly one derived
input, each target's trailing-5 s damage, which the engine now maintains as a fixed circular
buffer per target (allocation-free after warm-up). The engine also grew spell cooldowns
(Swiftmend's 15 s) and a `plan:Reset()` call, so a plan that caches its anchor cannot carry it
between two runs the search is comparing.

A plan is five bound spells and five rules in a fixed order, with small parameter domains.
That is a deliberate constraint, not a simplification: "rank 7 here, rank 9 there" is not a
strategy a person can execute in a heroic, and the point of a card is that it can be followed.
Binds default to the ranks the player actually cast in that recording.

Score is the lexicographic tuple `(deaths, floorSeconds, manaSpent, -heldOn, #binds,
overhealSim)`, compared element-wise. Nothing is blended into a scalar — a plan that lets
somebody die is not redeemed by saving mana, and no weight exists that says otherwise.

The classifier runs the best plan **in lockstep** with the replay: at each real cast the engine
calls back with the recording's own state and the plan is asked what it would have done then.
Eight of the ten labels come from that. Two cannot — `late` and `idle` are about moments the
plan wanted and the player did not act — so they come from running the plan alone and
comparing timelines. **The card says so in its caveat line** rather than blurring the two.

The card leads with a verdict that is allowed to say *"you had 2.1k headroom — nothing here
needed to change"*, because most pulls do not need coaching and a card that always finds
something is a card nobody trusts twice. `SP.Mark` / `SP.Progress` close the loop per zone:
after three later fights there, the Review tab can say what actually changed.

`/md coach [n]` — and it **refuses** a fight that failed §18's gates, listing which ones;
`force` overrides and puts the failures in the caveat line.

**Verified:** `tools/reccheck.lua` is 30 assertions. The classifier's mana identity holds
exactly (2199 labelled vs 2199 spent) and the coach's refusal path is tested as well as the
card, because silence on a bad fight is the more important behaviour.

**Next:** v0.7.5 — the coordinate-descent search.

## 2026-09-06 — v0.7.5: the search

Coordinate descent from four seeds (max-rank baseline, HoTs-only, the player's binds with
default thresholds, one random point), sweeping one parameter at a time over its small domain
and accepting improvements until a full pass changes nothing. At most 300 evaluations, with
the incumbent's mana as an early-abort bound on every candidate. Alternates within 5% of the
winner with fewer binds are collected for the card's tooltip. Full-grid enumeration was
rejected in the debate and stays rejected; coordinate descent can stop on a ridge, so the
alternates are listed rather than hidden.

**The bug worth recording: `GetTime()` does not advance inside a frame.** It is the frame's
timestamp, so slicing the coroutine on it (`while GetTime() - started < 8ms`) would have run
the entire search in one frame and frozen the client for seconds — in exactly the moment the
feature is wanted, between two pulls. The search now slices on `debugprofilestop()`, the
sub-frame clock, with a fixed resume count as the fallback when it is missing. Both paths are
exercised by the harness.

Two more corrections the harness forced:

- **The physical-floor assertion only holds when nobody died.** A plan that let a target die
  did not have to heal the damage that target took, so the bound does not apply; the first run
  printed `IMPOSSIBLE, engine is wrong` about a plan that was merely allowed to lose someone.
- **Binds are the five families a rule can use.** They were being built from every family in
  the spell table, which put Tranquility in the count (6 binds, and the score's tie-break
  cares) — and Tranquility has no heal values in `Data/SpellData.lua` at all, so no plan may
  spend mana on it.

`/md coach [n]` now searches before drawing the card, across frames, with `/md coach cancel`.
`heldOn` — whether the winning plan also survives the other retained recordings — is computed
after the search, because that is the difference between a strategy and a curve fitted to one
pull.

**Verified:** `tools/reccheck.lua` is 34 assertions. The search finishes inside its budget,
beats the max-rank baseline it was seeded with, and yields across frames.

**Next:** v0.7.6 — the Review tab.

## 2026-09-06 — v0.7.6: the Review tab

Sixth dashboard tab after Waste, following `Dashboard_Waste.lua`'s pattern (constructor on
`MD.DashboardParts`, shown when `currentFamily == "Review"`). One row per recorded fight —
when, zone, duration, targets, casts, spend, mana low-water mark read back out of the recorded
samples — and a **validate** column that is blank until asked, because replaying is not free.

The validate column is the point of the tab. A fight the engine cannot reproduce is greyed,
shows the first gate that failed, and has its **Coach button disabled with the reason in its
tooltip**. Advice from a fight the model gets wrong is worse than no advice, and the UI should
say that rather than quietly produce a card anyway. The row tooltip carries all eight gate
results, the foreign share, and which targets were excluded and why.

Below the list: habits over every summary that carries labels (top three by mana, `ok` never
counts), and the since-your-last-card line once three fights in that zone have happened.
Pin protects a recording; Export is `/md export`.

Also `/md options` → General → **Fight recording**: the record toggle, "let Coach change
ranks" (off by default — a card that silently rebinds everything is somebody else's strategy),
and the two thresholds a player might reasonably move. The gate thresholds and the search's
internals stay in `Core.lua`'s DEFAULTS with their provenance comments, because a slider
invites tuning and those numbers are meant to be argued with. The General tab is 470px tall
now to fit the fourth pane.

Two API notes for future UI work here: `Enable()`/`Disable()` rather than `SetEnabled`, and
`MD.Tip:Show(frame, anchor, lines)` takes the anchor as its second argument — both were got
wrong first time and only a careful read caught them, since no harness covers UI.

**Next:** v0.7.7 — `UI/SimWindow.lua`, `Data/SimPresets.lua`, `FromRecordings`, Monte Carlo.

## 2026-09-06 — v0.7.7: the Simulation window, and the end of the v0.7 spec

`Data/SimPresets.lua` (party / incoming damage / situation, plus `BuildScenario` which turns a
preset into events on a 1 s grid), `SimPlanner.FromRecordings`, `SimPlanner.MonteCarlo` and
`UI/SimWindow.lua` (`/md sim`).

**The header of the presets file is the important part:** every number in it is a placeholder,
one healer's impression of what a 5-man feels like, written down so the window has something
to run before any fight has been recorded. The window says so in grey, and **From recordings**
replaces them with `FromRecordings` measurement — per target, tagged by role, splitting a
steady rate from "big hits" (a second's damage worth ≥ `db.simBigHit` of that target's max
health) with p50/p90 sizes and the provenance string printed next to it.

Monte Carlo runs in the synthetic window and nowhere else — not inside the search, not on a
replay card, both of which the debate rejected. Thirty replicates with damage perturbed and
**crits rolled**, answering one question: how often does this plan lose somebody when the
fight is not exactly average? The first run answered it usefully — the mana-optimal plan on
the dungeon preset holds everyone deterministically and violates the floor in **every**
replicate. A plan that only works on average crits is a bad plan, and this is the only place
that shows it.

That test also exposed that `critMode = "roll"` had never been implemented (it silently
returned the non-crit amount). It now rolls a seeded LCG, so a replicate is reproducible on
any client and `math.random`'s global state is never touched.

`tools/simwindow.lua` covers the synthetic path: all 120 preset combinations build a scenario
with sorted events, the search completes on one, the winner is no worse than the baseline it
was seeded with, the replicates run, and — the assertion worth having — **the replicates
restore the damage array they perturbed**, since the scenario is reused by the caller.

**v0.7 is now complete**: v0.7.0 labels, v0.7.1 engine, v0.7.2 recorder, v0.7.3 replay and
gates, v0.7.4 plans and the card, v0.7.5 search, v0.7.6 Review tab, v0.7.7 simulation. Three
offline harnesses (`simcheck` 10, `reccheck` 34, `simwindow` 8) all pass. Everything that
remains is in-game: TESTING §15-§21, and §16 (the 116 mp5 the regen API does not report) is
still the single most valuable one.

## 2026-09-06 — the second mana stream has a name

The author, who was in that party: *"second mana stream was probably shadow priest."* That is
checkable, so it was checked — against the whole 28-minute `dungeon-BF-1.txt`, not just the
one pull the fixture was cut from.

It holds, and the check produced something better than an identification. The 116 mp5
`GetManaRegen` does not report is **two sources of completely different kinds**:

**A — exactly 17, every 2.00 s, 497 times, never once a different value.** In combat and out
of it in the same proportion as the time (380 / 117). This is the mp5 bucket: gear, an idol,
or Blessing of Wisdom — all `MOD_POWER_REGEN`, all landing on the server's 2 s mana tick,
none of it in `GetManaRegen`. 8.45 mana/s = **42 mp5 that belongs to the character**.

**B — 13-15 at a time, on a 3.00 s beat.** The signature is unambiguous: **55% of its 378
events have a partner exactly 3.00 s later**, against a 9% baseline at 3.5 / 4 / 5 s, with one
to four phases overlapping (a burst of five inside 0.3 s, then the same burst 3.00 s later).
**373 of the 378 are in combat** although combat is only 57% of the log. And per pull it
yields between **0.0 and 17.6 mana/s** — exactly zero in two of the thirty.

5% of a shadow DoT ticking every 3 s is precisely that shape, which is Vampiric Touch, which
is the shadow priest. The log records names only — no classes — so this is corroboration
rather than proof, and the one thing that does not fit is that Vampiric Touch is a level-70
spell.

**The ruling does not depend on naming the spell**, and that is the part worth keeping:

- **A is a number about you** and may enter `RM:Unreported()` one day, by the same route
  Dreamstate did: an in-game measurement, never a guess.
- **B must never enter the model.** It is not yours, it is not in every group, and it is zero
  in two of the thirty pulls in the only log we have. A clock that quietly assumes a shadow
  priest is wrong precisely on the pull where being wrong costs someone their life. The
  recorder's treatment — measure it per fight, replay what was measured — is the only correct
  one.

Changed: `Data/SimFixture_BF1.lua` no longer presents 23.1 mana/s as one number with one
cause, and its roster classes are now marked **unverified** (they had been carried over from a
mockup table in `docs/DESIGN-v0.6.md`; the log has no class data, and at least one of them is
wrong). `docs/DECISIONS.md` §v0.7.1 carries the ruling. `docs/TESTING.md` §16 is rewritten as
a three-step test that separates A from B — solo, then with a paladin, then with and without a
shadow priest.

`/md regentest` gained a **tick histogram**: gain sizes clustered within ±1, each with its
count and its beat — the reported spirit tick, a 2 s beat (printed as the mp5 it implies) and
a 3 s beat ("a party energize, not yours"). A size is what a source gives; a cadence is which
source it is. That is the whole decomposition above, on one chat line, in 30 seconds, instead
of a script over a 400 KB log.

The beat is measured the way the log was read by hand — the share of a cluster's events that
have a partner exactly one period later — and **not** as a median spacing, because a median
is exactly what fails here: four overlapping 3.00 s phases read as ~1 s apart. `tools/
regencheck.lua` (new, 8 assertions) drives `/md regentest` against a scripted stream of that
shape and asserts the histogram recovers it.

No model behaviour changed. All harnesses pass (simcheck 10, reccheck 34, simwindow 8,
regencheck 8) and the fixture still replays at mean 1.3% / max 2.8%.

## 2026-09-06 — v0.8 specified: a replay that plays

The author's next feature, in their words: a replay window that renders two sets of unit
frames — what actually happened, and what the math suggested — "stupid simple" first (HP
bar, where each cast went), indicators added per iteration. Cell's layout preview as the look.

Three calls made in conversation, no debate round needed (it is a renderer over v0.7's
decided machinery): **one window, two columns, one clock**; **both columns from the engine**,
with the recorder's real 5 s HP snapshots drawn as ticks on the left bars so the
reconstruction's error is visible at every moment; **Play without a plan allowed** — the left
column is class-agnostic and works for any healer on day one.

`docs/SPEC-v0.8.md` written in the v0.7 shape: delivery order with a verifiable-by line per
version, the trace format (`SM.TK` kinds, fixed 0.25 s grid, drained strictly before the next
event — the v0.7.1 sample-ordering bug named so a second sampler cannot re-introduce it),
`Engine/ReplayTrace.lua` as a frame-free state machine so playback is harness-testable
(*seek == step* is the assertion), `SP.Replay` as the one call that builds both columns, the
window layout, the per-cast labels, and the recorder extension for defensive cooldowns and
debuffs (recorded, rendered, **never modelled** — the damage they changed was recorded as it
happened). A rejected list, so nothing gets re-proposed. `docs/PLAN.md` Phase 1.8 and
`docs/DECISIONS.md` §v0.8 carry the calls.

Nothing implemented yet; harnesses unchanged and green.

## 2026-09-06 — v0.8.0: the trace and the replay state machine

The engine can now write down what it did. `SM:Run(..., { trace = { dt = 0.25 } })` records
mana, form and each tracked target's HP on a fixed grid plus the discrete things between grid
points — cast start / succeed / cancel, HoT apply / end (with the bloom), deaths, form
changes, and the plan's waits — every one stamped with the `Plan:Decide` rule that caused it
(`why`; 0 on the recorded side, whose reasons are not on record). The grid is a third sampler
under the same rule as the recorded ones: drained strictly before the next event, so a grid
point on a cast's timestamp shows the mana *after* the cast paid — the v0.7.1 bug, asserted so
it cannot come back. Damage is not in the trace: it is identical in both columns by
construction and the window reads it from the scenario.

`Engine/ReplayTrace.lua` is the state machine the window will paint from, with no frames in
it: `Seek(t)` rescans from zero with the callback suppressed, `Advance(dt)` fires it for every
event crossed, and `Hp` / `Hot` / `Casting` / `Waiting` / `Score` answer for the moment.
Two rules stated in the file: nothing is interpolated (a heal is a jump), and events at t = 0
are initial state — a pre-pull HoT is in the state a fresh machine reports and never flashes.

`SP.Replay(rec, opts)` builds both columns in one call — the recorded casts on the left, the
plan on the right (the one passed in, else the one Coach now caches per fight in `SP.plans`,
so Play never searches), the classifier's per-cast labels (`cls.casts`, new) and the
recorder's real HP snapshots as fractions for the ticks.

`tools/replaycheck.lua` (27 assertions) drives the scripted pull — now shared with `reccheck`
as `tools/fakepull.lua` — and asserts the trace's shape, every own cast at its time, the
post-cast rule, the death, the fixture's pre-pull HoTs at t = 0, the grid agreeing with the
gate's own sampler to 1e-6, the right column's rules and wait lengths, and *seek == step* for
every accessor at ten times on both columns. Two of its first three failures were the
harness's own assumptions (the stub has no auras; t = 0 is initial state) — the third became
the rule above.

One thing seen and left alone: on the scripted pull the classifier labels a Lifebloom on a
full-health target `fine` when the plan wanted a Lifebloom on the anchor at that moment. The
v0.7.4 order says "same family, different target" before "target above 85%", which reads
wrong here; it is unchanged pending real pulls (the card's counts have not been seen in-game
yet), and the per-cast labels in the window will make it visible when it matters.

## 2026-09-06 — v0.8.1: the replay window

`UI/ReplayWindow.lua`: `/md replay [n]`, and **Play** on the Review row next to Coach. One
window, two columns of unit frames on one clock — ACTUAL on the left (the recorded casts
through the engine), SUGGESTED on the right (the plan Coach cached in `SP.plans`; without one
the window is a single narrower column and the hint says why). Per frame: role letter, name in
class colour, HP bar with the percentage, `dead` in grey. A cast flashes the target's border in
the family colour and prints `Regrowth R9` above the bar for a second; a foreign heal flashes
white; recorded damage washes the bar red in proportion to the hit — identical on both sides,
because the damage is. The recorder's real 5 s snapshots are **white ticks on the left bars**,
fading until the next one: the health gate's number, seen. The healer strip carries the mana
bar, the cast bar filling over the cast time (the right column shows `waiting 1.2s` while the
plan holds), and the running `spent / lowest / dead` line, which at the end equals the card.
A scrubber with markers (deaths red, big hits orange, the left column's casts as faint ticks),
play / pause, 1× 2× 4×, the clock. Position and speed persist (`db.replayPos`,
`db.replaySpeed`); the ticks can be hidden (`db.replayTicks`).

The file only paints. Every fact comes from `Engine/ReplayTrace.lua`; both states advance the
same `dt` from one `OnUpdate`; a seek clears every short-lived effect, because those belong to
events crossed while playing. No interpolation, no opening in combat, no search from Play.

**The window has an offline test**, the first UI file to get one: `tools/replayui.lua` loads
`UI/Style.lua`, `UI/Tooltip.lua` and the window under the stub — whose frames now store
text, values and colours, and whose no-op fallback is restricted to UpperCamelCase method
names so a frame can carry state fields — opens the scripted pull, plays it to the end one
0.1 s frame at a time, seeks, and reads back what was painted: five rows tank-first, the cast
text appearing on the tank, the pulse on the mage, the warlock reading `dead`, the strip's
`spent` equal to the recording's, no bare pipe in any painted string, the tick drawn on the
left and never on the right, the markers, the single-column path, the refusal in combat.
23 assertions. Three stub gaps surfaced on the way (fonts without `GetFont`, frames without
`GetFrameLevel`, and the fallback-eats-fields one); none were window bugs, all are the kind
that would have been a nil error on the first press of Play in-game.

Six suites green: simcheck 10, reccheck 34, simwindow 8, regencheck 8, replaycheck 27,
replayui 23. What only the game can answer is TESTING §23 — whether it *reads* at 1×.

## 2026-09-06 — v0.8.2: indicators and labels

The frames now carry what a healer's eye looks for. Three **HoT squares** under the role
letter — Rejuvenation, Regrowth, Lifebloom in the family colours — counting down their last
nine seconds as a digit; Lifebloom shows its stacks, brightens per stack, and goes **white in
its last second**, the bloom's warning. An orange **Swiftmend-ready dot** after them while
there is something to eat and the cooldown is up (`State:Ready`, from the trace's own casts
and `SM.SPELL_CD`, now exported). The classifier's **label under each left cast** as it
lands — `late` red, `overheal` orange, `early` / `stack` yellow — and the scrubber's cast
ticks in the same colours, so the fight's shape reads before play is pressed. On the right,
a **grey band** over the cast bar while the plan waits, and **hovering the bar names the
rule** behind the current cast (`rule 3: keep Lifebloom rolling on the anchor`) or says why
it is waiting — the `why` column from v0.8.0, rendered for the first time and the smallest
possible start of the coach-in-replay highlights the author reserved.

`tools/replayui.lua` grew to 33 assertions: during the play-through it sees the `early` label
on its cast, a Lifebloom square counting `1`, a Rejuvenation digit, the dot, a `why` on the
right bar, the band while waiting; the tooltip script runs without error; a labelled tick sits
on the scrubber; a seek clears the labels and no square shows at t = 0.

Six suites green. What only the game can answer is TESTING §24 — and the one question that
matters there: **did any label look wrong**, because that is how the classifier gets fixed.

## 2026-09-06 — v0.8.3: defensive cooldowns and debuffs, recorded and drawn

The recorder keeps two more things on tracked targets. **Defensive cooldowns** from a
whitelist (`Data/AuraList.lua`: Shield Wall, Last Stand, Barkskin, Evasion, Divine Shield,
Pain Suppression, every rank of Power Word: Shield, ...) — the author's example was a rogue
under Evasion, who is not urgent. And **every debuff**, capped at four per target and a tenth
of the stream's event budget, after which debuffs stop and `auraTruncated` says so while
defensives keep going. `K.AURA = 12`, appended; `x` carries the spell id plus a flag for
buffs, `amt` the stacks or -1 on removal. Every id in the list is from memory and marked
VERIFY: a wrong one costs an icon, never a number.

**Nothing in the engine reads them.** `ScenarioFromRecording` passes them through and the
loop ignores the kind: the damage a Shield Wall prevented was recorded as prevented. They
explain the dip; they do not cause it in the model. What they are the prerequisite for is
the reserved decision input in `docs/SPEC-v0.8.md` §7 — a plan that does not drop everything
for a target whose defensive is up — which waits for a recording that shows the case.

`Engine/ReplayTrace.lua` tracks them from the scenario's timeline (`State:Auras(ti)`, oldest
first, state whether or not visuals fire, cleared and rebuilt on a seek like everything else).
The window draws the first defensive as an icon with the accent border in front of the name
and up to three debuffs over the bar's right end with their stacks, `GetSpellTexture` under
`pcall` with a lettered grey square as the fallback, and a hover tooltip naming the aura, when
it was applied and for how long. `/md export`'s `# recording` line ends with the aura count.

The shared scripted pull gained a Shield Wall (kept), a Fortitude (not whitelisted, dropped),
a debuff on the mage stacking to two, and a debuff on a mob (untracked, dropped); `reccheck`
asserts exactly those four events, `replaycheck` that the state machine sees the Shield Wall at
5 s and not at 14 s and the debuff at two stacks, seek and step agreeing, and `replayui` that
the icons are drawn and hidden at the right times with their tooltips running clean.

**v0.8 is complete**: v0.8.0 trace, v0.8.1 window, v0.8.2 indicators and labels, v0.8.3
auras. Six suites green. TESTING §22–§25 are what only the game can answer, and the two
questions that matter most there are §24's "did any label look wrong" and §25's "would seeing
the tank's cooldown have changed what you cast".

## 2026-09-06 — v0.8.4: the first in-game replay, and what it corrected

The author recorded a 1v1 against an open-world mob and sent two screenshots. Four things:

- **Clarity.** The frame's cast text was anchored above the bar and collided with the strip's
  score line; the hint had no width and ran under the "ticks" checkbox; 11 px text on a 30 px
  row. Columns are 360 wide and rows 38 high now, names and numbers in the 13 px font, the
  **cast text and its label drawn inside the HP bar** (as Cell does), the scrubber on its own
  full-width row, the hint on its own line.
- **Instants blinked.** The spec said "flash the bar once" — wrong, and unreadable. An
  instant still costs the 1.5 s GCD, so the bar now **sweeps the GCD in grey** with the
  spell's name, and **the name stays, dimmed, until the next cast**. The strip answers "what
  was I doing", not "is a bar moving".
- **Real casts did not progress.** A bug: a recorded `CAST_START` carries no cast time, so
  the bar jumped to full and vanished. The trace is complete, so the state machine now takes
  the duration from the `CAST` (or `CANCEL`) that follows the start — the *recorded* cast
  time, for any spell, Insect Swarm included. The scripted pull gained a real cast start for
  its Regrowth so the harness can see the bar move.
- **Slow speeds.** 1/4× and 1/2× next to 1× 2× 4×.

Two smaller things from the same screenshots: "Lifebloom R1" (one rank; the rank is shown
only for families with more than one) and a lettered square where a Barkskin icon should be —
`GetSpellTexture` returned nothing on this client for that id, so the icon now also tries
`GetSpellInfo`'s third return and logs the id when both fail.

`tools/replayui.lua` asserts the bar progressing during the Regrowth, the GCD sweep after an
instant, the name persisting after the fight, and the five speeds. Six suites green.

## 2026-09-06 — v0.8.5: icons that sweep, like Cell

The author: "use icons, and instead of duration text a duration animation like Cell does" —
the top-to-bottom dimming over the icon. Done for the three HoT indicators (the spell's own
icon, 14 px, the elapsed share dimmed from the top with a 1 px spark at the edge; Lifebloom's
stacks bottom-right, its border white in the last second) and, since the recording knows when
every aura came off, for the defensive and debuff icons too — `State:Auras` now carries
`until_` from a look-ahead to the removal, so a Shield Wall's icon sweeps for exactly the
14 s it was up. Cell does it with a reverse-filled vertical StatusBar masking a desaturated
copy; ours is a plain overlay whose height the paint loop sets, which comes to the same
picture without mask textures. One icon builder serves all three kinds; textures are cached
per spell with the `GetSpellInfo` fallback and a debug line when neither resolves.
`tools/replayui.lua` now asserts the Rejuvenation icon's overlay partway down the icon while
it runs (42). Six suites green.

## 2026-09-06 — v0.8.6: the frames are the author's Cell frames

Two more screenshots and the real point: a row per unit cannot hold 25 people twice, and the
author's raid frames already exist. "Mimic what is in my saved settings; no need to read Cell
at runtime." So the layout was read once, from `WTF/.../Cell.lua` in the parent checkout,
into one `CELL` table at the top of `UI/ReplayWindow.lua` with its provenance: 66 × 46
buttons, vertical, five per column, 3 px spacing, `sortByRole` off; bar in the class colour
over a loss area at class × 0.2 (Cell's `class_color_dark`), a 2 px power strip; name centred
at 75% width; health text bottom-right as a short deficit; the 11 px role icon top-left from
Blizzard's role atlas; the author's `indicator1` "Healers" slot (top-right, 13 px, right to
left — Rejuvenation, Regrowth, Lifebloom first in its aura list) for the HoT icons;
`defensiveCooldowns` 12 × 20 on the left edge; `debuffs` bottom-left, 13 px, three; the
bottom status strip for the landed cast's name, then its label, or `dead`. A raid's tracked
set fills the next columns; two grids side by side.

**The one addition Cell has no slot for: the cast target.** The spell in flight to a unit is
drawn in Cell's `statusIcon` slot (top centre, 18 px) with the vertical sweep of its cast time,
the button's border in the family colour meanwhile, and the icon held a moment after it lands.
Foreign heals still flash the border white.

`tools/replayui.lua` now asserts roster order, Cell-sized buttons and the cast-target icon
sweeping on the tank during the Regrowth (43). Six suites green.

## 2026-09-06 — v0.8.7: frame levels

The first in-game look at the Cell-shaped buttons: solid class colour with a bare stack count
on top and no status strip. Not a texture problem — two children of one button (the health
bar and an icon) share a frame level by default, and the later-drawn bar covered the icons'
textures and the text drawn on the button, while font strings on the OVERLAY layer showed
through. Cell gives the bar level 1 and its indicators 5 and 10; the window now does the same
(bars +1, HoT and debuff icons +5, defensives +10, the cast-target icon +15, text and the
role icon on an overlay frame at +20). The hint is one short line now instead of wrapping
into the controls in a single-column window. Not something the stub can see; noted here so
the next indicator gets a level from the start.

## 2026-09-06 — v0.8.8: room, scale, and the cast target where it reads

Two more screenshots. The "ticks" checkbox fell off the right edge of a one-column window —
the control row was wider than the column; the window is wider now (a column is at least 420,
larger buttons, the scrubber row and the hint each on their own line) and the dashboard is 20%
bigger (912 × 617) at the author's request, since not everything fit there either. The cast
target loses its icon: no room in a 66 × 46 button, and the author liked the name in the bottom
strip — so the spell in flight is named there in the family colour, with the border to match,
and the strip draws no background when it has nothing to say. **Frames scale with the
head-count**: one person ×3.5 both ways, a party ×1.6 tall and stretched across the column,
up to ten ×1.25 in two columns, a raid at Cell's own size five per column — every slot keeps
its Cell position, offsets and icons grow with the scale, the bar and the name stretch with
the width (`f.Resize(W, H, s)`). `tools/replayui.lua` asserts the stretched party buttons and
the in-flight name with its border (43). Six suites green.
