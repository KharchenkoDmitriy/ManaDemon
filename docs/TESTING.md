# ManaDemon — what to test now (v0.5.4)

**Status 2026-09-05:** §1–§4b, §6, §7 passed on v0.4.8 and are kept for regression.
**Outstanding: §5 (the clock's constants) and the three new tests §8, §9, §10.**

Everything below is done on the druid, in-game, with the Debug Console open
(`/md options` → General → Misc → Debug Console → tick **Enable Debug Logging**).
After each test: **Copy** in the console, paste into a file under `.logs/`
(gitignored) named like the test. Three to five files per session is plenty. The console
keeps 1000 lines by default — the **keep lines** box (top right, saved) raises it to 20000;
a fight with the Mana category on produces roughly 3 lines per second.

Install: `make install WOW_ADDONS="/path/to/_anniversary_/Interface/AddOns"` (or copy
`dist/combat-log-design-arch-ffb907/ManaDemon`), then `/reload`.

> **v0.5 changed a lot of plumbing.** §0 is a five-minute check that nothing regressed;
> do it first, because §8–§10 are worthless if something is broken underneath.

## 0. v0.5 regression pass (5 min) — DO THIS FIRST
The v0.5.0 architecture pass rewrote four tooltips and the rank math's internals with no
intended change to any number. What to confirm:
- **`/md verify`** — output must be **identical to before** (0 COST mismatches, no CAST
  lines but Naturalist). Paste it.
- **Dashboard numbers** — Heal/cast, HPM, HPS, HP5 and To OOM unchanged from v0.4.9 for
  the ranks you know by heart. The **Cast** column is the one exception: Healing Touch and
  Regrowth now read e.g. `2.9s*` instead of `3.0s` (§8).
- **Tooltips** — ElvUI datatext, minimap button and the **widget** (new: hover it) all show
  the same mana block. The widget now takes mouse input; if that gets in your way,
  Options → OOM Widget → untick **Tooltip on hover**.
- **Widget left-click** opens the dashboard (new).
- Watch for Lua errors throughout (`/console scriptErrors 1`).

## 1. Smoke test of the UI (5 min)
- `/md options`: tabs switch, frame drags by the tab strip, position survives `/reload`,
  ESC closes. The General tab grew — check **nothing overlaps** at the bottom of the
  Model and Misc panes (new: *Average in Nature's Grace*, *Reset overheal data*,
  *Copy profile*, *Show mana cooldown*, *Tooltip on hover*).
- Half-life slider: drag, type a value in the box + Enter, value clamps to 5–60.
- `/md`: spell tabs highlight, Settings opens the options, the **two-row** Simulate strip
  fits inside the frame, the header/callout/hint lines above the table do **not** wrap onto
  the rows (this is the layout risk in this build — say so if any of them does).
- Debug Console: category checkboxes filter (there is a new **Cast** one), Clear empties,
  Copy popup selects all, Ctrl+C works, ESC closes it.
- Minimap button: left = dashboard, right = options, hover shows the clock.

## 2. Data checks (2 min)
- `/md verify` — expect **0 COST mismatches** (Innervate is skipped). Any CAST line other
  than Naturalist is a bug. Paste the output.
- **`/md profile`** (new) — opens a copy box with every model input, the max ranks'
  live-vs-static costs, the clock state and all settings. Paste it once so the baseline is
  on record; from now on this is the thing to attach to any "this number looks wrong".

## 3. Tree of Life aura on heals — DONE 2026-09-03 (confirmed; keep for regression)
Tooltips on this client show BASE values only (932 in and out of form), so use the
**Heal** log category: every heal / HoT tick you land is logged with amount, overheal and
`[tree]` when in form. Being at full health is fine (overheal is still reported).
1. Out of form: cast Rejuvenation R12 on yourself, wait for 2 ticks.
2. Shift to Tree of Life, cast it again on yourself, wait for 2 ticks.
3. Copy. Expected tick out of form = `(932 + 450 × 0.8 × 1.20) × 1.10 × 1.15 / 4`; in form,
   if the aura counts, +healing becomes 450 + 0.25 × Spirit for the same formula.

## 4. Empowered Rejuvenation on the Lifebloom bloom — DONE 2026-09-03 (confirmed)
1. Cast **one** Lifebloom on yourself out of combat, let it expire (7s). The log shows
   7 ticks and one non-tick "Lifebloom" line = the bloom.
2. Expected tick = `(273 + 450 × 0.5187 × 1.20) × 1.10 / 7`; bloom with EmpRejuv =
   `(600 + 450 × 0.3422 × 1.20) × 1.10`.

## 4b. Relic slot (1 min)
`/md verify` prints the equipped relic and whether the table knows it. If it says NOT in
the relic table, paste the idol's name and tooltip text.

## 5. One real fight with logging on (the clock's constants) — STILL OUTSTANDING
- Any dungeon boss or a long trash pull (≥ 90s) where you actually heal.
- Keep the widget visible; do not read it during the pull, just heal.
- Afterwards: Copy the log (all categories on). The `[tto]` lines every 5s show what was
  displayed vs the model's T. What I will check: was `OOM` roughly honest at the end, how
  often the shown number jumped, how long the `~` / warm-up state lasted. Your one-line
  impression next to the paste helps: "too jumpy", "too pessimistic", "fine".
- **New in this build:** the same log now also answers §9 and §10, so one good fight
  covers three tests. Use Innervate during it.

## 6. To OOM / HP5 sanity (repeat only if something looks off)
- `/md spamtest`, then chain-cast one spell to OOM. Prediction vs measured on one line.

## 7. Simulate strip (2 min, partly new)
- Put next tier's +healing into **+heal** and see whether the gold row moves for Healing
  Touch and Regrowth. Set **mana** to 2000 and read To OOM. Clear.
- **New second row.** Set **form** to `Tree` while standing in caster form: HoT costs
  should drop ~20% and the stats line should say *costs from the static table while
  simulating form/talents*. Set **Moonglow** to 3 (or to 0 if you have 3): Healing Touch,
  Regrowth and Rejuvenation costs move 3% per rank. `Live` and `Clear` put everything back.
- The interesting question this answers: **does a Moonglow respec change your efficient
  rank?** Tell me if it does.

## 8. Nature's Grace cast times (2 min) — NEW, settles an assumption
The model now assumes a spell crit takes **0.5s** off your next cast (floor 1.5s) and
averages that into the Cast column, HPS, HP5 and To OOM. Neither the 0.5s nor Naturalist's
effect is visible in a spellbook tooltip, so:
1. Debug Console → tick the new **Cast** category.
2. Stand still and cast **six Healing Touch R11** in a row on yourself.
3. Copy. Each line reads `live X.XXs - model base Y.YYs, after a crit Z.ZZs (table 3.5s)`.
4. What I check: do the non-crit casts match `model base` (that confirms Naturalist), and
   do the casts right after a crit match `after a crit` (that confirms the 0.5s)?
- Repeat with two or three **Regrowth** casts — with Improved Regrowth those crit almost
  every time, so nearly every cast should show the reduced time.
- If the numbers disagree: Options → Model → untick **Average in Nature's Grace** puts the
  Cast column back to the old behaviour while I fix it.

## 9. Innervate's value (1 min inside §5) — NEW, settles an assumption
The clock now shows `inn 2:10` when you are under 90s to OOM with Innervate ready, and the
advisor quotes the same number. Both assume the 400% multiplies **only the Spirit share**
of your regen, not flat mp5 or Dreamstate.
1. With the **Regen** category on, use Innervate mid-fight (§5 is the natural place).
2. The log prints one line as the buff goes up and one as it fades:
   `mana cooldown UP: GetManaRegen base X casting Y; model expects Z/s while up (...)`.
3. What I check: does the client's `casting` value while the buff is up match the model's
   `Z`? If it is higher, flat mp5 is being multiplied too and the value model is low.
- Also worth one sentence: **did `inn 2:10` replacing `rest 2:10` help or annoy you?**
  Options → OOM Widget → **Show mana cooldown** turns it off. This is the one call in this
  build I am least sure about.

## 10. Overheal-calibrated numbers (needs one real raid/dungeon night) — NEW
The dashboard learns your overheal per spell from the combat log and can apply it.
1. Play normally for a night. Nothing to do — it records in and out of combat.
2. Open `/md`, tick **Effective** (top right, next to Settings). Heal, HPM, HPS and HP5
   become overheal-adjusted and their headers turn your class colour. A grey `?` means
   that rank has no measurement of its own yet and is showing the raw number.
3. Hover a row: the tooltip says the fraction, how many events it is from, and whether it
   is *measured on this rank* or a *family average*.
4. Copy `/md profile` — it lists every family and rank with its fraction and sample count.
5. What I check: are the counts growing sensibly, and does the family-vs-rank split ever
   have enough per-rank data to be interesting? **Deliberately not applied** to the gold
   "efficient rank" or the "rebind?" toast — a noisy measurement should not move those.
- **Also worth a look:** the fight-summary line's `overheal N%`. If it looks obviously
  wrong (say, doubled or halved), the combat log's `amount` convention was latched the
  wrong way — `/md profile` prints which one it picked under *combat log 'amount'
  convention*. Tell me what it says.

## Reporting
Paste the `.logs/*.txt` files (or their names if committed locally) and, for §3/§4, the
raw numbers. `/md profile` output is welcome with any report. I turn them into
`Data/SpellData.lua` / `Engine/*.lua` changes and record the outcome in
`docs/DECISIONS.md` + `docs/HISTORY.md`.
