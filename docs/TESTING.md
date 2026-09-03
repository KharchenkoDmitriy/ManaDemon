# ManaDemon — what to test now (v0.4.6)

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

## 3. Tree of Life aura on heals (10 min) — decides an open model item
Goal: does a heal on a party member (yourself counts) gain 25% of your Spirit as if it
were +healing?
1. Out of form, at full health you cannot see ticks — take some damage first (fall, or
   let a mob hit you and leave combat), or read the **spellbook tooltip** of
   Rejuvenation R12 in and out of form: TBC tooltips include your +healing.
2. Note: your Spirit (character sheet), your +healing, Rejuv tooltip total out of form.
3. Shift to Tree of Life, read the same tooltip. Expected if the aura counts:
   `+ 0.25 × Spirit × 0.8 × (1 + 0.04 × EmpRejuv) × (1 + 0.02 × GoN) × (1 + 0.05 × ImpRejuv)`
   (for R12 at 64 the downrank penalty is 1). If the tooltip does NOT change, cast it on
   yourself and compare tick sizes in the combat log / debug log instead — the tooltip
   may only show caster-side bonuses.
4. Paste the four numbers (Spirit, +healing, tooltip out, tooltip/tick in).

## 4. Empowered Rejuvenation on the Lifebloom bloom (5 min)
1. Cast **one** Lifebloom on yourself out of combat and let it expire (7s).
2. From the combat log take one tick and the bloom.
3. Expected tick = `(273 + bonus × 0.5187 × 1.20) × GoN / 7`; bloom without EmpRejuv =
   `(600 + bonus × 0.3422) × GoN`, with = `(600 + bonus × 0.3422 × 1.20) × GoN`, where
   bonus = +healing (+ 25% Spirit if §3 says the aura counts and you are in form). Paste
   tick, bloom, +healing, form.

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
