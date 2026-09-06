# ManaDemon v0.8 — replay visualisation: implementation spec

**This is the document to implement from.** v0.8 puts a picture on the machinery v0.7 built:
a window that *plays* a recorded fight as two columns of unit frames — what the healer did on
the left, what the coached plan would have done on the right — on one clock. It is a renderer
over decided machinery; the three design calls it needed were made by the author on
2026-09-06 and are recorded in `docs/DECISIONS.md` §v0.8. Nothing here is up for
re-litigation; "author question" items have defaults that apply until answered.

Read first: `CLAUDE.md`, `docs/SPEC-v0.7.md` §3 (the engine), §4 (the recorder's stream), §6
(the classifier), `Engine/SimModel.lua` (`Run`, `ScenarioFromRecording`), `Engine/SimPlanner.lua`
(`Classify`, `Coach`, `CoachAsync`), `UI/Dashboard_Review.lua`, `UI/SimWindow.lua` (the window
pattern), `UI/Style.lua`, and — for the look only — `../Cell/Modules/Layouts/Layouts.lua:22`
(Cell's layout preview is a real unit button with its events stripped and `isPreview = true`;
we copy the *look* through `MD.UI`, never the button).

Conventions that apply to every line of v0.8: Lua 5.1, no libraries, every file starts
`local _, MD = ...`, `pcall` around any API that might not exist on the 2.5.x client
(`GetSpellTexture` in particular), ASCII-only rendered strings with no bare `|`,
`MD:Debug("sim", ...)` for state transitions and timings (never per frame), `.toc` order
consistent with what a file reads from `MD`, version bump per release, all harnesses green
before every commit (`tools/run.sh tools/{simcheck,reccheck,simwindow,regencheck}.lua` plus
the new `replaycheck`), `make release SRC=<worktree>` builds.

---

## 0. Delivery order (one commit each; nothing skips ahead)

| version | ships | verifiable by |
|---|---|---|
| **v0.8.0** | the **trace** (`opts.trace` on `SM:Run`); `Engine/ReplayTrace.lua` (trace-reading state machine, no frames); `SP.Replay(rec, opts)`; `tools/replaycheck.lua` | harness: every recorded own cast appears in the left trace at its time; seek == step |
| **v0.8.1** | `UI/ReplayWindow.lua`: one window, two columns of frames, healer strip, damage pulses, cast flashes, snapshot ticks, scrubber; `/md replay [n]`; **Play** on the Review row | author plays a real recorded pull; left only when no plan exists |
| **v0.8.2** | HoT indicators on the frames; per-cast labels from the classifier shown at the moment of the cast; the right column's waits | the `late` / `overheal` labels appear under the casts they belong to |
| **v0.8.3** | recorder extension: whitelisted defensive cooldowns and debuffs on tracked targets (`SM.K.AURA`); icons on the frames | a Shield Wall / a boss debuff shows on the frame at the time it was up |

Docs at every step: `docs/HISTORY.md` entry, `docs/TESTING.md` section (§22–§25),
`docs/PLAN.md` tick; `docs/DECISIONS.md` only when a call here is changed by evidence.

---

## 1. Decisions this spec encodes (author, 2026-09-06)

1. **One window, two columns, one clock.** Not two windows: lockstep is the point, two windows
   drift and double the chrome.
2. **Both columns are engine output.** Left = `SM:Run` with the recorded casts
   (`ReplayPlan(rec)`), right = `SM:Run` with the coached plan. Same scenario, same recorded
   damage, same roster; the only thing that differs is the healer, so every visible difference
   is a healer decision, not a rendering artifact. **The recorder's real 5 s HP snapshots are
   drawn as ticks on the left bars**: the health gate's number turned into a picture. Trust in
   the right column is earned from the left one, same as the gates.
3. **Play without a plan is allowed** (left column only). The left column is class-agnostic:
   any healer can replay their fight the day v0.8.1 ships. The right column is Druid-only, like
   Coach.

Standing rules carried over from v0.7: the causality invariant (the right column's plan saw
only the present); the search never records a trace; no number enters the model from this
work — it is a view.

---

## 2. v0.8.0 — the trace

### 2.1 What a trace is

A trace is the engine's account of one run at a fixed grid, plus the discrete things that
happened between grid points. It is recorded only when asked for, allocated fresh per run
(it outlives the pool slot; the caller owns it), and **never in the search**.

```lua
-- SM:Run(scenario, plan, { trace = { dt = 0.25 } })  ->  r.trace
trace = {
    dt = 0.25, n = <grid points, floor(dur / dt) + 1>, dur = <scenario.dur>, nT = <targets>,
    mana = {},              -- [k] healer mana at t = (k - 1) * dt
    form = {},              -- [k] 1 tree / 0 caster
    hp   = { [ti] = {} },   -- [ti][k] HP fraction 0..1 (0 once dead), tracked targets only
    ev   = { t = {}, kind = {}, tgt = {}, a = {}, b = {}, why = {} },   -- parallel arrays, time order
    nEv  = 0,
}
```

`why` is the plan's reason for a `CAST` or a `WAIT`: the index of the `Plan:Decide` rule that
fired (1..5), `0` for a recorded cast (the left column has no reasons; the healer's are not
on record). It costs one number per event and is what a future "why did the plan differ here"
highlight stands on (§7, reserved). Nothing in v0.8 renders it beyond the tooltip in §4.3.

Event kinds `SM.TK` (a new table; `SM.K` is the *recorded* kinds and is not touched):

| kind | tgt | a | b | fired when |
|---|---|---|---|---|
| `CAST_START` | target | spellID | cast time (s) | a timed cast begins — from the recorded `CASTSTART` on the left, from the plan's decision on the right |
| `CAST` | target | spellID | cost | the cast **succeeds** (mana leaves; the moment `onCast` already fires) |
| `CANCEL` | target | spellID | 0 | recorded `CANCEL` (left only) |
| `HOT` | target | HoT index (`SM.HOT_INDEX`) | stacks | a HoT is applied or refreshed (Lifebloom: new stack count) |
| `HOT_END` | target | HoT index | 1 if it bloomed, else 0 | a HoT expires |
| `DEATH` | target | 0 | 0 | a tracked target dies |
| `FORM` | 0 | 1 tree / 0 caster | 0 | the form changes |
| `WAIT` | 0 | seconds | 0 | the plan chose to wait (right only) — one event per wait, its length known when it ends |

`SP.RunPlan` / `Plan:Decide` must report the rule that produced a decision so the trace can
record it: `Decide` returns `spellID, ti, rule` (a third value; existing callers ignore it).

Damage is **not** in the trace. It is identical in both columns by construction and the
renderer reads it from the scenario's recorded timeline (`scenario.ev` with `K.DMG`) directly.
Foreign heals likewise.

### 2.2 Sampling rule

Grid samples are drained **strictly before** the next event, exactly as the recorded mana
samples are (`Engine/SimModel.lua`, the loop head): a grid point that sits exactly on an
event's timestamp is taken on a later pass, once every event at that instant has been applied.
This is the sample-ordering bug of v0.7.1 and it must not be re-introduced by a second sampler.
`replaycheck` asserts it: a cast at `t = 3.00` with `dt = 0.25` shows the *post*-cast mana at
grid point `k = 13`.

### 2.3 Size guard

`dt` is a request. If `(nT + 2) * (dur / dt + 1)` would exceed **30 000** numbers, `dt` is
doubled until it does not, and `trace.dt` says what was used. (A 5-minute raid fight with 8
tracked targets at 0.25 s is 12 000 — the guard is for the pathological case, not the common
one.) `MD:Debug("sim", ...)` logs the chosen `dt` once per run.

### 2.4 `Engine/ReplayTrace.lua` — the state machine, no frames

Everything the window needs to *know* lives here; the window only paints. This is what makes
playback testable offline.

```lua
local RT = MD.ReplayTrace
local st = RT.New(trace, scenario, opts)   -- opts.onEvent(kind, tgt, a, b, t) for visuals
st:Seek(t)          -- rebuild state at t from the trace prefix, onEvent SUPPRESSED
st:Advance(dt)      -- step forward, firing onEvent for every event crossed; returns new t
st.t                -- current time
st:Mana()           -- healer mana at st.t (grid value, no interpolation)
st:Form()           -- "tree" | "caster"
st:Hp(ti)           -- HP fraction at st.t (grid value, no interpolation)
st:Dead(ti)         -- bool
st:Hot(ti, fi)      -- nil, or { stacks = n, remaining = s }   (v0.8.2 uses it; exists now)
st:Casting()        -- nil, or { spellID, target, startedAt, castTime }
st:Waiting()        -- nil, or seconds left in the plan's wait (right column)
st:Damage(ti, window) -- recorded damage on ti in the trailing `window` seconds (for the pulse)
```

**No interpolation anywhere.** A 3.3k Healing Touch landing is a jump and must look like one;
between grid points the bar holds. At 0.25 s the steps read as motion at 1× and 2×; at 4× they
are steps, which is honest.

**State at time `t` is a pure function of the trace prefix.** A seek rescans from 0 with
visuals suppressed; there is no incremental undo. Traces are hundreds of events; this is
nothing. `replaycheck` asserts *seek(t) == step-to(t)* for every field above at ten random `t`.

**Events at `t = 0` are initial state.** A pre-pull HoT or the opening swing is in the state a
fresh machine reports and never fires `onEvent`: the window paints from state every frame, so
nothing is lost, and there is no flash for something that happened before the window opened.

### 2.5 `SP.Replay(rec, opts)` — one call, both columns

```lua
local rp = MD.SimPlanner.Replay(rec, { plan = <plan or nil>, dt = 0.25 })
rp = {
    rec = rec, scenario = scenario, kit = kit, validation = <SM:Validate result>,
    left  = { trace = ..., snapshot = <the Snapshot() numbers of the run> },
    right = { trace = ..., snapshot = ..., plan = plan } or nil,   -- nil when no plan
    ticks = { t = rec.hp.t, hp = { [ti] = fraction[] } },          -- the recorder's snapshots
    casts = <v0.8.2: per-cast labels> or nil,
}
```

The plan comes from Coach. `SP.Coach` / `SP.CoachAsync` gain a `plan` field on what they
return, and `UI/Dashboard_Review.lua`'s per-`rec.id` cache (today it holds the validation)
holds the last coached plan too, so **Play never searches**: press Coach, then Play; or Play
alone for the left column. A recording that fails validation can still be played — the ticks
will show *why* it failed, which is the most useful thing the window can do with it — but the
right column is never built for it (the same rule as Coach's disabled button).

### 2.6 `tools/replaycheck.lua` (harness; ≥ 12 assertions)

Drives the `reccheck` scripted pull, then `SP.Replay` on the recording with a max-rank plan:

- a trace exists for the left column; `trace.n == floor(dur / dt) + 1`; every array has `n`
- every `OWNCAST` in the recording appears as a `CAST` trace event with the same spellID and
  the same target within 0.01 s, in the same order
- the post-cast mana rule (§2.2)
- the death appears as a `DEATH` event on the right target and `hp[ti][k] == 0` after it
- HP grid vs the recorder's snapshots: for each snapshot time, the grid value one step before
  or after brackets it within the health gate's max (`db.simGateHpMax`) — the same tolerance
  the gates use, because it is the same reconstruction
- the right trace exists, its `CAST` events differ from the left's, and its damage is not in
  the trace (there is no damage kind)
- seek == step at ten `t` values, every `RT` accessor
- `onEvent` fires exactly `nEv` times when stepping 0 → dur at `dt` and **zero** times on a
  seek
- a run **without** `opts.trace` returns `r.trace == nil` and the flat-allocation self-test in
  `/md simrun` still passes (the search path allocated nothing new)

---

## 3. v0.8.1 — the window

### 3.1 Entry points

- `/md replay [n]` — n as in `/md simreplay [n]` (1 = most recent recorded fight).
- **Play** button on the Review row, next to Coach. Runtime lookup
  (`MD.Replay and MD.Replay:Open(n)`), since `UI/Dashboard_Review.lua` loads before the window.
- Refuses to open in combat (`InCombatLockdown()` / `UnitAffectingCombat("player")`) with one
  chat line. It is a review tool.

### 3.2 Layout (`UI.CreateMovableFrame`, 660 × variable, `db.replayPos` saved)

```
+----------------------------------------------------------------------------+
| Replay  #2  Blood Furnace  0:40   mean 1.3% / max 2.8%           [x]       |  header
+-------------------------------------+--------------------------------------+
| ACTUAL                              | SUGGESTED  (your binds, 3 rules)     |  column titles
| [mana ######........ 4891 ]  [tree] | [mana ########...... 5210 ]  [tree]  |  healer strip
| [Regrowth R9 ->Destroyka ####...  ] | [Rejuvenation R12 ->Alkandari       ]|  cast bar
| spent 3.2k   lowest 41%   0 dead    | spent 2.4k   lowest 55%   0 dead     |  running score
+-------------------------------------+--------------------------------------+
| T Destroyka   [###########....] 71% | T Destroyka   [#############..] 82%  |  frames
| H Penek       [##############] 100% | H Penek       [##############] 100%  |
| D Alkandari   [######.........] 41% | D Alkandari   [#########......] 63%  |
| D Abufaisall  [.............. ] dead| D Abufaisall  [###............] 22%  |
| D Trecoda     [##############] 100% | D Trecoda     [##############] 100%  |
+----------------------------------------------------------------------------+
| [>] [1x][2x][4x]   0:23.5 / 0:40   |----o------------|--------x---|        |  scrubber
+----------------------------------------------------------------------------+
```

- **Frame order**: tanks, then healers, then the rest, each group in roster order. Raid = the
  tracked set (the player's subgroup plus main tanks — what the recorder kept). The healer is
  a tracked target like anyone else and has a frame.
- **Frame — the author's Cell button, since v0.8.6.** The row layout could not hold 25 × 2,
  and the author's raid frames already exist: the window is shaped to the `default` layout in
  their Cell SavedVariables (copied on 2026-09-06 into one `CELL` table at the top of the
  file; **not read from Cell at runtime, by the author's request**). 66 × 46 buttons, vertical,
  5 per column, 3 px spacing, columns for a raid's tracked set; health bar in the class colour
  with the loss area at class × 0.2 and a 2 px power strip (the healer's mana); name centred at
  75% width in the class colour; health text bottom-right as a short deficit; role icon
  top-left 11 px; Cell's `indicator1` "Healers" slot top-right (13 px, right-to-left) for the
  HoT icons; defensives 12 × 20 on the left edge; debuffs bottom-left 13 px × 3; the status
  strip at the bottom for the cast, then its label, or `dead`. **The one thing Cell has no
  slot for is the cast target**: while a spell is in flight to a unit its name sits in the
  bottom status strip in the family colour with the button's border in the same colour; when
  it lands the name stays a moment, then the label. (v0.8.6 tried the spell icon in Cell's
  `statusIcon` slot; the author, on seeing it: no room, and the bottom text reads better.)
  The strip's background is drawn only while it has text. Roster order (`sortByRole` is off
  in the layout). **Frames scale with the head-count** (v0.8.8): one person ×3.5, up to five
  ×1.6 tall and stretched across the column, up to ten ×1.25 in two columns, a raid at Cell's
  own size five per column — so a solo test reads and 25 × 2 still fits. Dead: bar empty, name grey, `dead` instead of
  the percentage. Untracked roster members are not shown.
- **Snapshot ticks** (left column only): a 1 px vertical line on the bar at the latest
  recorded snapshot's fraction, drawn in white at 90% and fading to 30% over the 5 s until the
  next snapshot. It is the truth mark; the bar is the reconstruction. `db.replayTicks`
  (default `true`) hides them.
- **Damage pulse** (both columns, identical): when a recorded `DMG` on the target crosses, the
  bar's background flashes red proportional to `amount / maxHP` for 0.4 s. Big hits (a
  second's damage ≥ `db.simBigHit` of max HP) also get a marker on the scrubber.
- **Cast flash**: on `CAST`, the target frame's border takes the family colour for 0.8 s and
  `Regrowth R9` appears above the bar, right-aligned, for 1.2 s. Foreign heals flash the
  border white for 0.4 s with no text. Family colours live in one table in the window file:
  Rejuvenation purple, Regrowth green, Lifebloom yellow-green, Healing Touch blue, Swiftmend
  orange, Tranquility teal, utility/shift grey.
- **Healer strip**: mana bar (blue, current number, the pool as max); form tag; cast bar that
  fills over the cast time from `CAST_START` — on the left the *recorded* time, taken from
  the `CAST` that follows (v0.8.4; a recorded `CAST_START` carries none) — and, for an
  instant, **sweeps the GCD in grey**: the healer is locked either way. The last cast's name
  **stays**, dimmed, until the next one: the strip answers "what was I doing", not "is a bar
  moving" (author, 2026-09-06, from the first in-game replay — a flash per instant was
  unreadable);
  the running score line `spent N  lowest H%  D dead` computed from the trace prefix (so it
  agrees with the card at the end). The right strip shows `waiting 1.2s` while `st:Waiting()`.
- **Scrubber**: a slider 0..dur on its own full-width row; play/pause; a `UI.CreateButtonGroup`
  for 1/4× / 1/2× / 1× / 2× / 4× (`db.replaySpeed`, default 1; the slow speeds were the
  author's first request after seeing it); `m:ss.s / m:ss`; markers along the track: deaths
  red, big hits orange, the left column's casts as 1 px grey ticks. Dragging seeks (§2.4);
  playback resumes from there.
- **Playback**: one `OnUpdate` on the window, `st:Advance(elapsed * speed)` for each column
  while playing, then paint. Both columns advance the same `dt` from the same call; there is
  no per-column clock. Reaching `dur` pauses. Painting is ~10 `SetValue` / `SetText` calls per
  frame per column; no allocation in the paint path (reuse the text buffers, cache the class
  colours per row at open).
- **No plan**: the right column is hidden and the window is 340 wide. The header says
  `no plan - press Coach first` in grey.

### 3.3 What it must not do

Never open during combat; never touch `MD.Recorder`/`FightRecorder` state; never run the
search (Play reads the cached plan or shows one column); never interpolate; never `Show()`
the widget (it has its single owner).

### 3.4 `docs/TESTING.md` §23

Open a recorded pull, play at 1×: a Healing Touch is a jump, a Rejuvenation is four steps 3 s
apart, the tank's tick sits inside the bar's reconstruction; scrub back and forth; play at 4×
to the end and confirm the strip's `spent` equals the card's; a death greys the frame at the
right moment; close and reopen with no plan and confirm the single column.

---

## 4. v0.8.2 — indicators and labels

### 4.1 HoT indicators (from `st:Hot(ti, fi)`, both columns)

Three **spell icons** at the frame's left, under the role letter (14 × 14): Rejuvenation,
Regrowth, Lifebloom. Remaining time is a **Cell-style vertical sweep** — the elapsed share of
the icon dimmed from the top down with a 1 px spark at the edge (`Cell/Indicators/Base.lua`
VerticalCooldown; ours is an overlay rather than a mask because the window paints every
frame) — **not a digit** (author, 2026-09-06, v0.8.5: "use icons and a duration animation
like Cell"). Lifebloom shows its stack count bottom-right and its border turns white for the
last second before a bloom. Defensive and debuff icons (§5.2) get the same sweep, exact,
because the recording knows when each came off.
A `Swiftmend`-ready dot (orange, 5 × 5) sits next to them while Rejuvenation or Regrowth is
active and the cooldown (`SM.Ready`) is up — the plan's rule 3 made visible.

### 4.2 Per-cast labels

`SP.Classify` gains `cls.casts[n] = { t = t, spellID = spellID, tgt = ti, label = label }`
in cast order (the aggregates stay; the card is unchanged). `SP.Replay` puts it on
`rp.casts` when a plan exists. On the left, when a `CAST` crosses, its label appears under the
`Regrowth R9` text for 1.5 s in the label colour: `late` red, `overheal` orange, `early` and
`stack` yellow, `spell` and `rank` light grey, `fine` dim grey, `utility` / `shift` nothing.
The scrubber's cast ticks take the same colours, so the fight's shape is readable before
pressing play.

`idle` (the plan cast and you did not) stays a count on the card in v0.8.2. **Author
question:** show each idle moment on the *right* column as a brief `you: idle` under the
plan's cast? Default: not yet — it needs the classifier to keep the moments, and the card's
count has not yet been seen in-game.

### 4.3 The right column's waits

`WAIT` events render as `waiting 1.2s` in the right strip (§3.2) and as a thin grey band on
the right cast bar for the wait's duration. This is the *"wait is a valid action"* decision
of v0.7 made visible, and the most likely thing the author will want to argue with. Hovering
the right cast bar shows the current cast's or wait's `why` as the rule's one-line name
(`rule 3: Swiftmend on a big hit`) — the smallest possible start of the coach-in-replay
highlights reserved in §7.

### 4.4 `docs/TESTING.md` §24

Play a coached pull: the `overheal` label lands on the cast you remember; Lifebloom's square
counts 1-2-3 and whitens before the bloom; the right column waits where the card said it
would.

---

## 5. v0.8.3 — recorder extension: defensive cooldowns and debuffs

### 5.1 Recorded kind

`SM.K.AURA = 12` (append; **never renumber**). Payload facts for `SPELL_AURA_APPLIED`,
`SPELL_AURA_REMOVED`, `SPELL_AURA_APPLIED_DOSE`, `SPELL_AURA_REMOVED_DOSE`, `SPELL_AURA_REFRESH`
after the 11-field prefix: `spellId, spellName, school, auraType[, amount]` where `auraType`
is `"BUFF"` or `"DEBUFF"` and `amount` is the stack count on the `_DOSE` events. Verify the
`_DOSE` shape against Details! on this client before relying on the stack count; record `1`
if it is absent.

Recorded, for **tracked targets only**:
- `x = spellID`, `amt = +stacks` on apply / refresh / dose, `-1` on remove;
- **buffs only from a whitelist** (`Data/AuraList.lua`, one table with a provenance comment
  per row): Shield Wall 871, Last Stand 12975, Barkskin 22812, Frenzied Regeneration 22842,
  Survival Instincts 61336, Divine Shield 642, Divine Protection 498, Ice Block 45438, Pain
  Suppression 33206, Power Word: Shield (all ranks), Innervate 29166, Nature's Swiftness 17116,
  Bloodrage no. IDs are TBC-era and each is `-- VERIFY` until seen in a recording;
- **every debuff**, capped at **4 concurrent per target** (the fifth is dropped, not
  displaced) and **10% of `MAX_EV` in total** per stream (after that, debuffs stop being
  recorded and `stream.auraTruncated = true`; defensive cooldowns keep being recorded).

`ScenarioFromRecording` **ignores `AURA` events**: they change nothing in the engine. Damage
was recorded as it happened, so a Shield Wall is already *in* the damage stream. The aura
explains the dip; it does not cause it in the model.

`/md export`'s `# recording` section gains an `aura` count.

### 5.2 Rendering

Both columns, identical (recorded). At the frame's right end, before the percentage: up to
3 debuff icons (14 × 14, `GetSpellTexture(spellID)` under `pcall`, a grey square with the
first letter of the name when the texture is missing) with their stack count; a defensive
cooldown as one 18 × 18 icon with the accent border at the frame's far left, in front of the
role letter, for as long as it is up. Tooltip on hover (`MD.Tip`): spell name, applied at,
duration so far.

### 5.3 `docs/TESTING.md` §25

One dungeon: a tank's Shield Wall or Last Stand shows when it was pressed; a boss debuff shows
with its stacks; `/md export` prints the aura count; a long raid-style fight reports
`auraTruncated` rather than silently losing anything.

---

## 6. Files and `.toc` positions

| file | role | after |
|---|---|---|
| `Engine/ReplayTrace.lua` | trace state machine, no frames | `Engine/SimPlanner.lua` |
| `Data/AuraList.lua` (v0.8.3) | defensive-cooldown whitelist with provenance | `Data/SimPresets.lua` |
| `UI/ReplayWindow.lua` | the window; exports `MD.Replay` | `UI/SimWindow.lua` |
| `tools/replaycheck.lua` | harness (not shipped) | — |

`Engine/SimModel.lua` gains `SM.TK` and the trace sampler; `Engine/SimPlanner.lua` gains
`SP.Replay`, the `plan` field on Coach's return and `cls.casts`; `Engine/FightRecorder.lua`
gains `AURA` (v0.8.3); `UI/Dashboard_Review.lua` gains the Play button and the cached plan;
`Core.lua` gains `/md replay`, `db.replaySpeed = 1`, `db.replayTicks = true`, `db.replayPos`.
`tools/harness.lua`'s file list follows the `.toc`.

---

## 7. Rejected and reserved

### Reserved — room deliberately kept (author, 2026-09-06)

- **Coach inside the replay.** Highlights on *where* the suggested column differs from the
  record and *why*: "at 0:23 the plan Swiftmended (rule 3: big hit on the tank); you cast
  Regrowth R9 — `late`". v0.8.0's `why` column and v0.8.2's per-cast labels are the data;
  the rendering (a diff marker on the scrubber, a side-by-side sentence when paused on one)
  is a v0.9 item, after the author has played real pulls and knows which differences matter.
- **Defensive cooldowns and debuffs as a decision input.** A rogue under Evasion is not
  urgent; a tank at 40% with Shield Wall up is not the same 40% as without it. That is a
  present-state input for `Plan:Decide` — legal under the causality invariant (the healer
  can see the buff too), next to trailing damage. v0.8.3's recording of `AURA` events is the
  prerequisite; the rule itself waits for recordings that show the case happening, so its
  threshold has a provenance. **Not** the engine changing damage (below): the damage a
  defensive prevented was recorded as prevented.

### Rejected (do not re-propose)

- **Two windows.** Decision 1.
- **Raw snapshots as the left column.** Decision 2 — a 5 s stair-step next to a smooth curve
  would look like a difference in healing when it is a difference in rendering. The snapshots
  are ticks instead.
- **Cell's real unit buttons** as the frames. A dependency on another addon's internals for a
  look we already reproduce.
- **Interpolation between grid points.** Heals are jumps.
- **Playing a live fight.** The recorder records; the window replays. Never in combat.
- **Monte Carlo playback.** Thirty replicates are a distribution, not a fight.
- **Running the search from Play.** Play shows what Coach found; it does not search. (Coach
  *annotations* inside the replay are reserved above — the distinction is search vs
  explanation.)
- **Defensive cooldowns / debuffs changing damage in the engine.** Damage is recorded as it
  happened, Evasion included. (Using them as a *decision* input is reserved above.)
- **Per-target smoothing of the pulse, or a "predicted" bar.** The right column *is* the
  prediction.

---

## 8. Author questions with defaults

| question | default until answered |
|---|---|
| grid `dt` | 0.25 s |
| default speed | 1× |
| idle moments shown on the right column (§4.2) | no |
| debuff cap per target (§5.1) | 4 |
| the healer's own frame in the list | yes (it is tracked) |
| window opens where | last position (`db.replayPos`), else centre |
