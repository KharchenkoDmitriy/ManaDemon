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
