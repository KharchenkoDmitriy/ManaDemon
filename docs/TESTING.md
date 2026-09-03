# ManaDemon — what to test now (v0.4.8)

Everything below is done on the druid, in-game, with the Debug Console open
(`/md options` → General → Misc → Debug Console → tick **Enable Debug Logging**).
After each test: **Copy** in the console, paste into a file under `.logs/`
(gitignored) named like the test. Three to five files per session is plenty.

Install: `make install WOW_ADDONS="/path/to/_anniversary_/Interface/AddOns"` (or copy
`dist/main/ManaDemon`), then `/reload`.

## 1. Smoke test of the new UI (5 min)
- `/md options`: tabs switch, frame drags by the tab strip, position survives `/reload`,
  ESC closes. Every checkbox reflects its slash command (`/md mute` then reopen → ticked).
- Half-life slider: drag, type a value in the box + Enter, value clamps to 5–60.
- `/md`: spell tabs highlight, Settings button opens the options, Simulate boxes accept
  numbers and clear, "SIMULATION" prefix appears and disappears.
- Debug Console: category checkboxes filter, Clear empties, Copy popup selects all,
  Ctrl+C works, ESC closes it. Watch for Lua errors (`/console scriptErrors 1`).
- Minimap button: left = dashboard, right = options, hover shows the clock.
- ElvUI: both datatexts show, tooltip has the "Dreamstate mp5 (added)" line when talented.

## 2. Data checks (2 min)
- `/md verify` — expect **0 COST mismatches** now (Innervate is skipped). Any CAST line
  other than Naturalist is a bug. Paste the output.

## 3. Tree of Life aura on heals — DONE 2026-09-03 (confirmed; keep for regression)
Tooltips on this client show BASE values only (932 in and out of form), so use the
**Heal** log category (v0.4.7+): every heal / HoT tick you land is logged with amount,
overheal and `[tree]` when in form. Being at full health is fine (overheal is still
reported with the full amount).
1. Out of form: cast Rejuvenation R12 on yourself, wait for 2 ticks.
2. Shift to Tree of Life, cast it again on yourself, wait for 2 ticks.
3. Copy. Expected tick out of form = `(932 + 450 × 0.8 × 1.20) × 1.10 × 1.15 / 4`; in form,
   if the aura counts, +healing becomes 450 + 0.25 × Spirit for the same formula. The
   dashboard's Heal/cast (1725 vs 1810) already shows the two predictions — the log says
   which one is real.

## 4. Empowered Rejuvenation on the Lifebloom bloom — DONE 2026-09-03 (confirmed)
1. Cast **one** Lifebloom on yourself out of combat (out of form is simplest), let it
   expire (7s). The log shows 7 ticks and one non-tick "Lifebloom" line = the bloom.
2. Expected tick = `(273 + 450 × 0.5187 × 1.20) × 1.10 / 7`; bloom without EmpRejuv =
   `(600 + 450 × 0.3422) × 1.10`, with = `(600 + 450 × 0.3422 × 1.20) × 1.10`.
3. Copy the lines.

## 4b. Relic slot (1 min)
`/md verify` now prints the equipped relic and whether the table knows it. If it says NOT in
the relic table, paste the idol's name and tooltip text. Then cast one Rejuvenation on
yourself out of form: the tick should now match the dashboard's Heal/cast ÷ 4 within 1.

## 5. One real fight with logging on (the clock's constants)
- Any dungeon boss or a long trash pull (≥ 90s) where you actually heal.
- Keep the widget visible; do not read it during the pull, just heal.
- Afterwards: Copy the log (all categories on). The `[tto]` lines every 5s show what was
  displayed vs the model's T. What I will check: was `OOM` roughly honest at the end
  (did you go OOM near when it said), how often the shown number jumped, how long the
  `~` / warm-up state lasted. Your one-line impression next to the paste helps:
  "too jumpy", "too pessimistic", "fine".

## 6. To OOM / HP5 sanity (already done once; repeat only if something looks off)
- `/md spamtest`, then chain-cast one spell to OOM. Prediction vs measured on one line.

## 7. Simulate strip
- Put next tier's +healing into "+heal" and see whether the efficient rank (gold row)
  moves for Healing Touch and Regrowth. Set "mana" to 2000 and read To OOM. Clear.

## Reporting
Paste the `.logs/*.txt` files (or their names if committed locally) and, for §3/§4, the
raw numbers. I turn them into `Data/SpellData.lua` / `Engine/RankMath.lua` changes and
record the outcome in `docs/DECISIONS.md` + `docs/HISTORY.md`.
