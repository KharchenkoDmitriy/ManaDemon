# ManaDemon — what to test now (v0.7.0)

**Status 2026-09-05 (evening), v0.6.8:** the author ran `/md verify`, a `/reload`, `/md
profile` and `/md spamtest` on v0.6.7 (`.logs/regression/`). Results: **§2 verify passed**
(0 cost mismatches; the 13 CAST lines were all Naturalist and the harness now knows that);
**§6 spamtest passed** (13 predicted, 13 measured); **§8 Nature's Grace CONFIRMED** — two
casts after a crit read `live 1.50s`, the rest 2.00s; **§11 calibration caught a real
model error on its first run** (Regrowth's +healing split, fixed — see DECISIONS §15) and
exposed a sim leak (fixed). Also found: a false "cooldown used: Innervate" on every cast
(the GCD; fixed) and the `/md profile` paste came out **empty** (see §2b).

**Still to do, in this order:** §0b · §2b · **§12 roster in a group** (the biggest unknown)
· **§15 (new in v0.7.0, and it depends on §12 working)** · **§16 (new in v0.7.1)** · §5 (needs a hard pull) · §9
(needs one Innervate) · §11 again after a dungeon night · §13 · §14. §1, §3, §4, §4b, §7
are regression-only.

Everything below is done on the druid, in-game, with the Debug Console open
(`/md options` → General → Misc → Debug Console → tick **Enable Debug Logging**).
After each test: **Copy** in the console, paste into a file under `.logs/`
(gitignored) named like the test. Three to five files per session is plenty. The console
keeps 1000 lines by default — the **keep lines** box (top right, saved) raises it to 20000;
a fight with the Mana category on produces roughly 3 lines per second.

Install: `make install WOW_ADDONS="/path/to/_anniversary_/Interface/AddOns"` (or copy
`dist/combat-log-design-arch-ffb907/ManaDemon`), then `/reload`.

> **v0.5 and v0.6 both changed a lot of plumbing.** §0 and §0b are ten minutes of "did
> anything break"; do them first, because everything after is worthless if something is
> broken underneath.

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

## 0b. v0.6 regression pass (5 min) — NEW, DO THIS TOO
- **No red `OOM 0s`.** In the BF log it appeared nine times at 72–97% mana. It must never
  appear again; if it does, Copy the log around it.
- **`OOM >2:00 =` on quiet pulls.** When the projection's error is above 70% of its value
  the clock now shows a bound instead of digits (Options → Model → *OOM digits below
  error*). On an easy pull expect mostly `OOM >N:NN =  rest Ns`; on a hard one the digits
  come back and count down as before. Tell me if a pull you *felt* was hard showed only the
  bound — that is the 0.7 needing retuning.
- **HP5 column is gone**; Cast / To OOM / note shifted left. Nothing overlaps.
- **Dashboard opens on your most-cast spell** (Lifebloom), not Healing Touch, until you
  click a tab.
- **A fifth tab, `Waste`**, renders with four `by:` buttons and two `scope:` buttons.
  Before any healing it says "No heals recorded this session yet".
- The **advisor**, when it fires for the potion, now adds *"Innervate is ready too but worth
  ~N: hold it until you're down that far."*
- Debug Console: **ten** categories in two rows (new: `Calib`); nothing overlaps the "keep
  lines" box.

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

## 2b. `/md profile` came out empty — NEW, 30s
The regression paste of `/md profile` was a 0-byte file. Either the copy box was empty (a
bug — was there a Lua error? `/console scriptErrors 1`), or the paste failed. Run it again;
if the box is empty, tell me what the chat line said. `/md verify`'s snapshot section is the
same content, so nothing is lost meanwhile.

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

## 6. To OOM sanity (repeat only if something looks off)
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

## 8. Nature's Grace cast times — CONFIRMED 2026-09-05 (Regrowth); Healing Touch still worth one look
The spam test settled it: casts right after a CRIT read `live 1.50s`, all others `2.00s`
(`.logs/regression/spam-test`). The 0.5s and the GCD floor are real on this client. What is
left is only Healing Touch in caster form — Naturalist 5 makes R1 read 1.0s live, under the
model's 1.5s GCD floor, which is expected but worth seeing once.
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

## 11. Calibration — the model against your heals (one night, then 1 min) — NEW
The addon now compares every heal you land with what the model predicted for it, per
spell and event kind (tick / direct / bloom), non-crit only, and keeps the ratio.
1. Play a night. Nothing to do.
2. `/md calibrate` (or Options → Misc → *Copy profile*, which includes it). Paste it.
3. What I check: every row with n ≥ 30 should read **ratio 1.000 ± 0.03**. A `HIGH` or
   `LOW` row is a real finding — a relic the table does not know, a wrong coefficient, an
   unmodelled buff — and you will also have seen one yellow *calibration:* chat line about
   it during play (Options → Model → *Calibration drift alerts* turns those off).
4. The two skip counters at the bottom matter: *Lifebloom ticks with no clean stack fit*
   should be a small fraction of Lifebloom ticks; if it is large, tell me — that is the one
   weak spot in this design, on your most-cast spell.
5. **Relics.** If a drift alert fires on the family your idol affects, it now names the idol
   and says what value the data implies — e.g. *"You are wearing Harold's Rejuvenating
   Broach (table: +87, unverified); the data says about +50."* That number is the table
   correction; paste the line. Seven of the eight idols in the table are unverified.
6. The `crit` rows: observed crit rate vs what the model assumed. Regrowth with Improved
   Regrowth should sit near 25% + crit; a big gap there is a talent-model bug.

## 12. The Waste view and the roster (one dungeon, then 2 min) — NEW
1. After a run, `/md` → **Waste**. Try all four `by:` modes and both scopes.
2. **The question that matters:** in `by: Role`, are your party's roles TANK / HEALER /
   DAMAGER, or mostly `UNKNOWN`? And in `by: Target`, do names show a grey `?` after the
   role? The design assumes `UnitGroupRolesAssigned` returns the role people picked in the
   group finder. In a guild premade it may return nothing — the `roster:` line at each pull
   in the debug log (Combat category) says `NAME CLASS ROLE(source)` for everyone; paste one.
   If `(unknown)` is common, the fallback needs work and I want to know now.
3. Sanity: the tank should overheal ~40%, a mage's Water Elemental ~100% (Lifebloom on a
   pet), you yourself around 45%. A warlock who taps shows *Life Tap xN* next to the name.
4. The footer: *"X spent this session, ~Y (Z%) into targets at full health"* — the BF log
   was 24%. Your number, and whether it changes how you cast, is the whole point.
5. The fight summary line now carries *(LB 52%, RG 22%, RJ 14%, other 12%)* and *~1.5k into
   full health*. Check it reads sensibly against one pull you remember.

## 13. Pull budget (between two pulls, 30s) — NEW
Out of combat, hover the widget: two new lines, *Pull budget: N more, M after a drink* and
*a pull in <zone> costs ~X (median of n)*. The drink reminder now reads *"Drink? 62% --
recent pulls here cost ~2.3k -- 2 more, or 4 after a drink."* Does the count match what you
would have guessed? Too optimistic is the failure mode to report.

## 14. Export (1 min) — NEW
`/md export` opens a copy box of tab-separated fights, overheal buckets, roster and
calibration. Paste it once alongside the debug log; from now on I analyse this rather than
regexing prose. Also: **Copy in the Debug Console now prepends the full input snapshot**, so
a pasted log is self-describing — no need to add your talents by hand.

## 15. Cast labels and the new summary line (one pull, v0.7.0) — NEW
Turn on the **Sim** category in the Debug Console, then do one normal pull of 15 s or more
with at least four casts. Three chat lines now arrive at the end instead of one:

1. the usual fight line (`0:40 || net -85 mp5 || spent 3.8k (LB 52%, ...)`),
2. `N of M casts on targets above 85% (2.9k): Lifebloom 9, Rejuvenation 4, Regrowth 1 -
   utility/shifts 1.6k - buffed in combat: Mark of the Wild at 0:39`,
3. only if you pre-HoTted somebody at full health before the pull:
   `pre-pull HoTs on full targets: 0.4k in Lifebloom 2 (78% overheal)`.

What to check, and this is the whole test — **does line 2 match what you remember doing?**
If you rolled Lifebloom on a healthy tank the whole fight, most of your casts should be in
the "above 85%" count and Lifebloom should lead the list. If the count looks far too low,
health is not being read at cast time (see the `unknown` bucket below).

In the debug log, the **Sim** category prints one line per fight:
`labels: utility 300/2, shift 0/0, early 220/1, overheal 2900/14, ok 380/2 = 3800 (fight
spend 3800, delta +0)`. Two failure modes to report:
- a `label identity BROKEN` line — the labelled mana and the spend tracker disagree by more
  than 2%, which means casts are being missed or double counted;
- a large `unknown` HP bucket, visible as line 2 counting far fewer casts than you made —
  that is `UnitHealth` failing to resolve group members and it breaks everything in v0.7.

Also: history now keeps **200** fights instead of 20, and a fight with fewer than 4 of your
own casts is no longer recorded at all. After a dungeon night, `/md export` should list
many more fights than before.

## 16. Where does 116 mp5 come from? (5 min in a party, v0.7.1) — NEW, and the most interesting
Replaying the BF-1 hard pull through the new engine turned up something the model does not
know about. Over those 40 seconds, continuously inside the five-second rule, you gained
**2072 mana**. `GetManaRegen` accounts for 1141 of it. The other **931 (23 mana/s, 116 mp5)**
arrives as two clean periodic streams in your own log: **exactly 17 every 2.00 s**, and
**bursts of 13-15 on a ~3 s cycle**. Neither is Dreamstate (you have no points in it — the
log's regen lines carry no Dreamstate suffix).

The strong suspect is **Blessing of Wisdom** from the party's paladin: a periodic energize, so
`GetManaRegen` is blind to it exactly as it is to drinking. The ~3 s stream is unidentified.

Nothing is being added to the model on a guess. What settles it:

1. **Solo, out of group, no buffs.** `/md regentest 30` standing still. Then again while
   chain-casting (`/md fsrtest`). Note the tick sizes in the Mana category.
2. **Same character, in a party with a paladin, Blessing of Wisdom on you.** Repeat both.
   Copy the log. If the +17-every-2 s stream appears only in step 2, it is the blessing and
   the model gets a "buffs that energize" term.
3. If a stream shows up in step 1 as well, paste the log anyway — that is something on your
   own character and it is worth 116 mp5, which is more than most gear upgrades.

Also, for reference: `/md simrun` should print **10 tests, all ok**, and `/md simreplay
fixture` should print `spend ... (exact)` and a `measured ... -> PASS` line. Those two run
anywhere, including at the character select screen's login, and are worth doing once after
this update just to confirm nothing about your talents breaks the engine.

## Reporting
Paste the `.logs/*.txt` files (or their names if committed locally) and, for §3/§4, the
raw numbers. `/md profile` output is welcome with any report. I turn them into
`Data/SpellData.lua` / `Engine/*.lua` changes and record the outcome in
`docs/DECISIONS.md` + `docs/HISTORY.md`.
