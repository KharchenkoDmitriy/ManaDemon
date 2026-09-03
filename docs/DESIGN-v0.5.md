# ManaDemon v0.5 — design and architecture

Detailed design for everything left in **Phase 1** of `docs/PLAN.md` (§1b model
improvements, §1c UX, §1d housekeeping), plus the seams Phase 2 will need so the
refactors below are done once.

**Not covered here:** §1a's clock-constant tuning (`K_SIGMA` / `CV_STABLE`) and the
unlearned-rank heal values. Both need the author's in-game combat log
(`docs/TESTING.md` §5), which is coming later. Nothing in this document depends on
them, and nothing here changes those constants.

Status of every statement: **derived** = follows from code already in the repo;
**measured** = proven in-game (see `docs/HISTORY.md`); **assumed** = a modelling
choice that needs an in-game check, listed in §7.

---

## 1. Architecture

### 1.0 Current shape

```
  Blizzard events                 Core.lua                       consumers
  ---------------                 --------                       ---------
  UNIT_SPELLCAST_SUCCEEDED  -->  MD:On dispatch  --> SpendTracker  --\
  UNIT_POWER / mana drop    -->                  --> RegenModel   ----+--> TTO ---> Widget
  COMBAT_LOG_EVENT_UNFIL.   -->                  --> Summary  (x2 handlers)  |      Datatext
  PLAYER_REGEN_*            -->                  --> Advisor                 |      Minimap
                                 MD:OnTick 0.5s  --> TTO / Advisor / Dash    |
                                 MD:Fire pub/sub --> Dashboard, Options      \--> RankMath --> Dashboard
```

Three problems this design fixes:

1. **`RankMath:Compute()` is one 150-line function** that builds its inputs, computes
   every row and does the Pareto pass in a single scope. A per-row tooltip needs the
   intermediate terms, and `/md profile` needs the inputs — neither is reachable.
2. **Four separate tooltip implementations** (ElvUI datatext, minimap button, the
   dashboard's stats line, nothing on the widget) drift apart and duplicate the same
   `RM:Components()` formatting.
3. **Two `COMBAT_LOG_EVENT_UNFILTERED` handlers in `UI/Summary.lua`** parse the same
   event twice, and neither keeps per-spell data. Everything overheal-calibrated hangs
   off that parse.

### 1.1 New and changed files

| File | State | Role |
|---|---|---|
| `Engine/RankMath.lua` | **refactor** | split into `Context()` / `RowFor()` / `Compute()` / `Explain()` |
| `Data/SpellData.lua` | **change** | `SD:StaticCost(id, ctx)` takes an override context; percent modifiers **sum** (client behaviour) instead of multiplying |
| `Engine/Overheal.lua` | **new** | per-family / per-rank overheal fraction from the combat log, persisted |
| `Engine/ManaCooldowns.lua` | **new** | class table of big mana cooldowns + carried potions; one value model shared by the clock and the advisor |
| `Engine/TTO.lua` | **change** | `state.cd` (the best mana cooldown and the clock it buys), one extra display segment |
| `UI/Tooltip.lua` | **new** | the single line builder: `MD.Tip:Mana()`, `:Row()`, `:Fights()`, `:Render(tt, lines)` |
| `UI/Dashboard_Rows.lua` | **new** | column table, row pool, hover + row tooltip |
| `UI/Dashboard_Simulate.lua` | **new** | the two-row Simulate strip |
| `UI/Dashboard.lua` | **shrink** | frame, tabs, header lines, refresh orchestration only |
| `UI/Summary.lua` | **change** | one combat-log handler; fight history persisted to `MD.cdb` |
| `UI/Advisor.lua` | **change** | Innervate/potion branches replaced by `ManaCooldowns` |
| `UI/DebugConsole.lua` | **change** | copy popup extracted as `MD:ShowCopyPopup(title, text)` |
| `Verify.lua` | **change** | input snapshot extracted as `MD:Snapshot()` (lines), reused by `/md profile` |
| `Core.lua` | **change** | `/md profile`, new defaults, `cast` debug category |

### 1.2 Load order (`ManaDemon.toc`)

```
Core.lua
Data\SpellData.lua
Engine\RegenModel.lua
Engine\SpendTracker.lua
Engine\Overheal.lua           <- new: needs Core only (registers a CL consumer)
Engine\ManaCooldowns.lua      <- new: needs SpellData (cost) + RegenModel (components)
Engine\TTO.lua                <- now reads ManaCooldowns
Engine\RankMath.lua           <- now reads Overheal
UI\Style.lua
UI\Tooltip.lua                <- new: needs Style; reads the model lazily at call time
UI\Widget.lua
UI\Dashboard_Rows.lua         <- new: exports MD.DashboardParts.CreateTable(parent)
UI\Dashboard_Simulate.lua     <- new: exports MD.DashboardParts.CreateStrip(parent, anchor)
UI\Dashboard.lua              <- consumes both
UI\OptionsFrame.lua
UI\Options_General.lua
UI\Options_About.lua
UI\DebugConsole.lua
UI\MinimapButton.lua
UI\Advisor.lua
UI\Summary.lua                <- feeds Overheal + persists history
Integrations\ElvUIDatatext.lua
Verify.lua
```

`Dashboard_Rows` / `Dashboard_Simulate` load **before** `Dashboard.lua` and only define
constructors on `MD.DashboardParts`; `Dashboard.lua` calls them from its `MD_READY`
handler. No new pub/sub events are needed.

### 1.3 `RankMath` split

The one change everything in §1c rests on.

```lua
-- Every input the rank math reads, resolved once. Simulation overrides
-- (MD.sim) are applied here and nowhere else.
function RankMath:Context()
    return {
        bonus, statBonus, treeAura, inTree, relic, crit,
        mana, castingRegen, baseRegen,
        goN, empTouch, empRejuv, impRejuv, regrowthCrit, naturalist,
        naturesGrace,            -- 0 or 0.5 (seconds), gated by talent + setting
        playerLevel,
        simulated, live = { ... },
        CostFor = function(id) ... end,   -- live cost, or static-with-overrides
                                          -- returns cost, source
    }
end

-- One row from one spell. `explain` fills row.calc with every intermediate
-- term; without it nothing extra is allocated (the 2s dashboard re-render
-- must not churn 50 tables).
function RankMath:RowFor(spellID, ctx, variant, explain)  -- variant: nil | 2 | 3 (LB stacks)
    ...
    return row     -- + row.calc when explain
end

function RankMath:Compute()      -- ctx + families + Pareto + suggestion (as today)
function RankMath:Explain(spellID, variant)   -- ctx + RowFor(explain=true)
```

`RankMath.info` stays as-is (it is the context, minus the closures) so the dashboard
header and `/md verify` keep working unchanged.

`row.calc` shape (direct spell; HoT/hybrid/lifebloom carry the analogous fields):

```lua
row.calc = {
  base       = 2364,             -- (healMin+healMax)/2
  relicFlat  = 0,
  bonus      = 525,              -- statBonus + treeAura fed in
  coef       = 1.00,             -- clamp(cast,1.5,3.5)/3.5
  penalty    = 1.00,             -- downrank * sub20
  bonusMult  = 1.10,             -- Empowered Touch / Empowered Rejuvenation
  bonusOut   = 578,              -- bonus*coef*penalty*bonusMult
  talentMult = 1.10,             -- Gift of Nature (* Imp Rejuv for HoTs)
  critMult   = 1.075,            -- 1 + 0.5*crit  (nil for HoTs)
  castBase   = 3.00,             -- after Naturalist, floored at GCD
  castNG     = 2.93,             -- Nature's Grace expected value
  costSource = "api",            -- "api" | "table" | "table (simulated)"
  overheal   = { frac = 0.31, n = 142, scope = "family" },   -- nil when unmeasured
}
```

### 1.4 Cost context

`SD:StaticCost(spellID, ctx)` — `ctx` defaults to the live talents and form, so every
existing call site is unchanged:

```lua
ctx = { inTree = <bool>, moonglow = 0..3, tranquilSpirit = 0..5 }
```

Two changes at once:

* **Percent modifiers sum, not multiply.** The current comment already records the
  client's behaviour ("the client SUMS same-type percent modifiers: Moonglow + Tree
  of Life = −29%, not ×0.91 × ×0.8") and calls the multiplicative fallback a known
  ~2% error. The simulate strip is about to *depend* on that path, so it gets fixed:
  `cost = round(base * (1 - (0.03*moonglow + 0.02*tranquil + 0.20*tree)))` with each
  term applied only to the families it covers. Rounding stays (**measured**:
  Swiftmend 216.8 → 217).
* `ctx.CostFor(id)` in `RankMath` uses the **live** cost (still live-first, still
  exact) unless a cost-affecting simulation override is set (`sim.tree`,
  `sim.moonglow`), in which case it uses `StaticCost(id, ctx)` and labels the source
  `table (simulated)` so the tooltip can say so.

---

## 2. F1 — Nature's Grace as an expected-value cast term

**What it is.** One talent point, Balance: a spell critical reduces the cast time of
the *next* spell by 0.5s. It cannot take a cast below the 1.5s GCD.

**Model.** In a steady chain of one spell, the fraction of casts that follow a crit is
the crit chance `p`, so the throughput-correct cast time is the mixture — not
`cast − 0.5p` floored, which clips wrongly at the boundary:

```
T0    = max(baseCast - 0.1 * Naturalist, 1.5)       -- today's castTime
E[T]  = (1 - p) * T0 + p * max(T0 - 0.5, 1.5)
```

`p` is the nature crit chance for Healing Touch, and `min(1, crit + 0.10 × Improved
Regrowth)` for Regrowth (the value `RankMath` already computes as `regrowthCrit`).
For HoTs `p = 0` **and** `T0 = 1.5`, so the term is a no-op for Rejuvenation and
Lifebloom for two independent reasons — worth stating in the tooltip, because "why
doesn't my Rejuv get faster" is the obvious question.

Why the mixture and not `E[heal]/E[cast]` per cast: over a chain, throughput is
`n·heal / (n·E[T]) = heal / E[T]`. Averaging the cast time is exactly right for a
sustained-throughput column; averaging `heal/T` per cast would not be.

**Worked values** (level 64 druid, Naturalist 5, ~15% nature crit, Imp Regrowth 5):

| Spell | `T0` | after a crit | `p` | `E[T]` |
|---|---|---|---|---|
| Healing Touch R11 | 3.00s | 2.50s | 0.15 | **2.93s** |
| Regrowth R9 | 2.00s | 1.50s | 0.65 | **1.68s** |
| Rejuvenation R12 | 1.50s | 1.50s | 0 | 1.50s |

**Where it applies.** `E[T]` replaces `castTime` everywhere in the row: HPS, the HP5
floor interval, and the To OOM cast interval. That last one *reduces* the To OOM count
(a shorter interval earns less regen per cast) — correct, and the direction is worth
noting so it does not read as a bug.

**Honest caveat, shown in the tooltip.** In a real mixed rotation an instant cast eats
the Nature's Grace buff for no benefit, so the chain-cast figure is an upper bound.
The dashboard's HPS / HP5 / To OOM are explicitly chain-cast metrics, so the
assumption is internally consistent, but the tooltip says it.

**Setting.** `db.naturesGrace` (default `true`), Options > Model, "Average in Nature's
Grace". Off = today's numbers. Gated on `MD:TalentRank("Nature's Grace") > 0`, so it is
invisible to anyone without the point.

**Display.** The `Cast` column shows `2.9s*`; the grey `*` means "averaged". The hint
line gains `* = Nature's Grace averaged in`. Full arithmetic in the row tooltip.

**Verification.** New `cast` debug category: on `UNIT_SPELLCAST_START`, log the client's
own cast duration from `UnitCastingInfo` against `T0` and `T0 − 0.5`. One log with a few
Healing Touches confirms both Naturalist and the 0.5s in the same lines. **assumed**
until then (the 0.5s and the GCD floor are TBC-documented, not measured on this client).

---

## 3. F2 — Innervate-aware clock, via a class-generic cooldown model

### 3.1 `Engine/ManaCooldowns.lua`

Today the Innervate value lives in `UI/Advisor.lua` as `spiritPerSec * 3.5 * 20` ("rough,
conservative"), and the clock does not know about it at all. If the clock grows its own
estimate they will disagree on screen. One owner:

```lua
MC.byClass = {
    DRUID   = { { id = 29166, name = "Innervate",  duration = 20, value = InnervateValue } },
    -- Phase 2 stubs, not wired until someone of that class can log one:
    PRIEST  = { { id = 34433, name = "Shadowfiend", duration = 15, value = nil } },
    SHAMAN  = { { id = 16190, name = "Mana Tide Totem", duration = 12, value = nil } },
    PALADIN = { { id = 31842, name = "Divine Illumination", duration = 15, value = nil } },
}
MC.potions = { ... }        -- the table moved verbatim out of Advisor.lua

MC:Best()   -- best usable source now: { name, delta, ready, cdRemaining, kind }
MC:All()    -- everything known, for the tooltip
MC:Active() -- true while the cooldown's buff is up
```

**Innervate value (TBC).** 400% mana regeneration for 20s, and regeneration continues
at full rate while casting. Taking `S`, `G`, `U` from `RM:Components()` (spirit share,
flat gear/buff mp5, unreported Dreamstate — all per second):

```
rateInnervate = 5*S + G + U            -- no five-second-rule penalty for 20s
delta         = max(0, rateInnervate - RM:Effective()) * 20 - GetCost(29166)
```

`RM:Effective()` is the duty-weighted rate the clock is *already* projecting, so
`delta` is the marginal gain, not the gross — subtracting it twice was the easy bug
here. The 400% multiplies the **spirit** share only; flat mp5 and Dreamstate are not
spirit-based and are not multiplied (**assumed**, see §7). Innervate's own cost is
subtracted because it is cheap to be exact.

`MC:Active()` suppresses the whole feature while the buff is up: during Innervate
`GetManaRegen()` already reports the boosted rate, so the clock is right on its own and
a second figure would double count.

### 3.2 The clock

`Engine/TTO.lua` `Compute()` gains:

```lua
s.cd = { name = "Innervate", delta = 4200, ready = true, cdRemaining = 0,
         tto = (mana + delta) / net }        -- ttf/bound analogues per mode
```

**Display rule.** The one-liner is a hard ASCII one-line contract with at most one
secondary segment. Priority, in combat:

| Condition | Secondary segment |
|---|---|
| mode `oom`, cooldown usable, `tto < 90s`, `delta ≥ 0.10 × manaMax` | `inn 2:10` |
| otherwise, `showRest` and it differs ≥25% from the primary | `rest 2:10` |
| otherwise | none |

```
OOM 1:20 v   rest 2:10        <- today, unchanged
OOM 45s vv   inn 2:10         <- Innervate ready and it moves the needle
OOM 45s vv   rest 2:10        <- Innervate on a 4-minute cooldown: unchanged
```

Rationale: when the clock is under 90 seconds, "what does my cooldown buy" is the only
decision left, and `rest` (stop casting entirely) is the one you are least likely to
take. Outside that window `rest` is the more useful number. `db.showInnervate`
(default `true`) turns the segment off; it is independent of `db.showRest`. The
tooltip always shows both, plus the cooldown remaining when it is not ready.

**Advisor.** The Innervate and potion branches become one loop over `MC:All()`,
alerting the first tick a source's `delta` fits entirely into the deficit — the same
"none of it will be wasted" rule, now with the same numbers the clock shows.

**Verification.** Add an Innervate-gain / -fade line to the `regen` category logging
`GetManaRegen()` on both sides of the buff. One in-game Innervate with logging on
settles whether the API's boosted rate matches `5*S + G + U`. **assumed** until then.

---

## 4. F3 — Overheal-calibrated HPM

### 4.1 The combat-log parse

`UI/Summary.lua` currently registers `COMBAT_LOG_EVENT_UNFILTERED` **twice** and calls
`CombatLogGetCurrentEventInfo()` three times per event. One handler, one call:

```lua
MD:On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local _, sub, _, srcGUID, _, _, _, _, dstName, _, _,
          spellID, spellName, _, amount, overheal, _, crit = CombatLogGetCurrentEventInfo()
    if srcGUID ~= MD.player.guid then return end
    if sub ~= "SPELL_HEAL" and sub ~= "SPELL_PERIODIC_HEAL" then return end
    MD.Overheal:Record(spellID, amount, overheal)      -- always, in and out of combat
    if fight then ... end                              -- fight totals, as today
    MD:Debug("heal", ...)                              -- as today
end)
```

Overheal is recorded out of combat too: rolling Lifebloom on a tank between pulls is
exactly the sort of casting whose overheal you want counted.

### 4.2 `Engine/Overheal.lua`

```lua
OH.stats = {}       -- key -> { h, o, n }   weighted healed / overhealed / event count
-- keys: "f:Rejuvenation" (family) and "s:26981" (rank)
local HALF = 150    -- events; decay factor r = 0.5^(1/HALF) applied per record
local MIN  = 40     -- events before a scope is usable

function OH:Record(spellID, amount, overheal)   -- decays and adds to both keys
function OH:Fraction(spellID)                   -- -> frac, n, scope("rank"|"family") or nil
```

Rank scope wins when it has `MIN` events, otherwise the family, otherwise nothing.
Weighting is by **amount**, not by event, so a 4-tick Rejuvenation and a Healing Touch
contribute in proportion to the healing they actually did.

**The bias, stated plainly.** Until a rank has its own 40 events, every rank of a family
shares one fraction — which *understates* the case for downranking, because a smaller
heal overheals less. The tooltip labels the scope (`family average` vs `measured on
this rank`) so the number is never read as more precise than it is. It also means the
family-scope fraction scales every rank of a family by the same factor, so it cannot
reorder them.

**Persistence.** `MD.cdb.overheal` (per character; play style and content, not account
state). "Reset overheal data" button in Options > Model, because gear and content
changes invalidate it and a 150-event half-life takes a while to forget a bad night.

### 4.3 Use in the dashboard

Not a new column — the table is already ten columns at 760px. A checkbox on the hint
line instead:

```
[x] Effective (overheal-adjusted)      measured 31% over 142 Rejuvenation ticks
```

When on: `Heal/cast`, `HPM`, `HPS` and `HP5` show `value × (1 − frac)` and their headers
read `eff Heal/cast`, `eff HPM`, … in the accent colour. `Mana`, `Cast` and `To OOM` are
untouched — mana spent is mana spent. Rows with no measurement fall back to raw and
are marked in the note column. Setting `db.effectiveMode` (default `false`).

**The Pareto filter and the suggested rank stay on raw values.** With a family-scope
fraction the ranking within a family is unchanged anyway; the only thing that *would*
move is the "heals ≥40% of max rank" gate, and letting a noisy measurement silently
change which rank the addon recommends — and therefore fire a "rebind?" toast — is not
a trade worth making yet. Revisit when per-rank scopes routinely fill.

---

## 5. F4 — Persisted fight history

```lua
MD.cdb.fights = {          -- newest last, capped at 20
  { t = <time()>, dur = 128.4, spend = 34.2, netMp5 = -180, oomAt = 96.2,
    healed = 41233, overhealed = 12905, zone = "Karazhan", summary = "<the chat line>" },
}
```

`MD.fightHistory` keeps its name and shape (nothing else has to change), is loaded from
`MD.cdb.fights` at `MD_READY`, capped at 20 instead of 5, and written back on
`FIGHT_RECORDED`. 20 entries is ~3KB of SavedVariables.

**Pull-time seed** (`Engine/SpendTracker.lua`) becomes zone-aware: the median
`avgSpendRate` of the last 5 fights **in the current zone** when at least 2 exist,
otherwise the median of the last 5 overall — the "last time here" reference from the
plan, for free. The debug line says which pool it used.

**UI.** The recap line at the bottom of the dashboard becomes hoverable: the tooltip
lists the last 5 fights (`MD.Tip:Fights(5)`), one line each with duration, net mp5,
overheal % and the OOM mark.

---

## 6. UX

### 6.1 F5 — Per-row tooltips

Rows become mouse-enabled with a Cell-style accent highlight at 10% alpha, and hover
calls `RankMath:Explain(row.id, row.variant)` → `MD.Tip:Row(calc)` → the private
`MD.UI` tooltip.

```
+---------------------------------------------------------------+
| Rejuvenation (Rank 12)                        efficient rank  |
|---------------------------------------------------------------|
| Heal                                    1289 over 12s (4 ticks)|
|   base                                                     932 |
|   relic  Idol of Rejuvenation                              +50 |
|   +healing  525 x 0.80 coef x 1.00 downrank x 1.20 EmpRej  +504|
|   talents   x1.10 Gift of Nature  x1.15 Imp Rejuvenation       |
|---------------------------------------------------------------|
| Mana                            304   live client value, Tree  |
| Cast                            1.5s  GCD (instant)            |
|---------------------------------------------------------------|
| HPM   heal per mana                                       4.24 |
| HPS   heal committed per second of cast                    859 |
| HP5   sustained at 0 mana                190  (interval 33.8s) |
| To OOM  from 6544 mana                    21 casts (net 283ea) |
|---------------------------------------------------------------|
| Overheal  31% (family average, 142 events)                     |
| Effective                        HPM 2.93     heal/cast 889    |
+---------------------------------------------------------------+
```

Healing Touch rows additionally carry the Nature's Grace line:

```
| Cast                       2.9s* 3.0s base, 2.5s after a crit, |
|                                  15% crit -> 2.93s average     |
|        * chain-casting one spell; an instant cast in between   |
|          eats the buff for nothing.                            |
```

Lifebloom stack rows explain the variant instead of the bloom
(`x3: three applications refreshed before expiry — 6 ticks per refresh at the stack
multiplier, no bloom`).

### 6.2 F6 — Simulate strip, second row

The strip is already at the width of the frame; form and Moonglow go on a second row
(frame 496 → 514 tall):

```
Simulate:  +heal [    ] crit% [    ] casting mp5 [    ] resting mp5 [    ] mana [    ]
           form [ Live ][ Caster ][ Tree ]    Moonglow [  ]              [ Clear ]
```

* `form` is a three-state button group, not a checkbox — `Live` (follow the real form),
  `Caster`, `Tree`. `MD.sim.tree = nil | false | true`.
* `Moonglow` is a 0–3 box; blank = live talent rank. `MD.sim.moonglow`.
* Both feed `ctx` only. `MD:InTreeForm()` itself is never overridden, so the clock,
  the advisor and the gear toast keep using the real form (the toast is already
  suppressed while simulating).
* Because a simulated form or Moonglow rank invalidates the live cost, `ctx.CostFor`
  falls back to `SD:StaticCost(id, ctx)` and the stats line adds
  `costs from the static table while simulating form/talents`.

### 6.3 F7 — One tooltip builder

```lua
-- UI/Tooltip.lua
MD.Tip:Mana()        -- clock, spend +- sigma, regen decomposition, duty, cooldowns
MD.Tip:Row(calc)     -- the breakdown above
MD.Tip:Fights(n)     -- the last n fights
MD.Tip:Render(tt, lines)

-- line = { l = "left", r = "right", c = {r,g,b}, rc = {r,g,b}, wrap = bool }
-- {} renders a blank line; l with no r renders AddLine
```

`{l, r}` pairs are the right abstraction because both `GameTooltip` and ElvUI's
`DT.tooltip` take `AddDoubleLine`. Consumers: the two ElvUI datatexts (`OnEnter`), the
minimap button, the floating widget (**gains a hover tooltip it does not have today**),
and the dashboard's rows and recap line.

### 6.4 F8 — `/md profile`

`MD:Profile()` returns the lines; `/md profile` puts the text straight into the copy
popup (`MD:ShowCopyPopup("ManaDemon profile", text)`, extracted from
`UI/DebugConsole.lua`) and prints one chat line saying so. Chat-spamming 40 lines is
not a bug report; a Ctrl+C box is.

`Verify.lua`'s input snapshot is extracted as `MD:Snapshot()` returning lines, so
`/md verify` and `/md profile` cannot drift apart. Sections:

```
addon      version, client build, interface, ElvUI present
character  class, level, talents (relevant), form, relic (id + name)
stats      Int, Spirit, +healing, nature crit, mana pool
regen      GetManaRegen raw base/casting, unreported, S/G split, duty, observed fill
spend      rate +- sigma, n, half-life, seed source, unpriced spellIDs
state      mode, tto/ttf/rest/bound, the rendered display string
costs      every known max rank: live vs static, source
overheal   per family/rank: fraction, n, scope
fights     last 5 summaries
settings   the whole MD.db minus positions
```

---

## 7. What needs in-game data

| Item | Status | How it gets settled |
|---|---|---|
| Nature's Grace 0.5s, GCD floor | **assumed** | new `cast` debug category; a few Healing Touches |
| Innervate = 5×spirit only (not flat mp5 / Dreamstate) | **assumed** | `regen` log line on buff gain/fade, one Innervate |
| `K_SIGMA` / `CV_STABLE` | **open** (§1a) | the author's combat log, `docs/TESTING.md` §5 — unchanged by this design |
| Overheal half-life 150 / gate 40 | **assumed** | one raid; the numbers are visible in `/md profile` |
| Summed vs multiplied cost percentages | **measured** (client sums; recorded in the code comment) | already known, this just applies it |
| Unlearned-rank heal values | **open** (§1a) | spellbook tooltips at 65–70 |

Nothing in §2–§6 is blocked on the first two: both features ship with the assumption
documented in the tooltip and a debug line that proves or disproves it on the next
play session.

---

## 8. Settings and saved variables

New `MD.db` keys (all merged by `FillDefaults`, so old saved variables upgrade silently):

| Key | Default | Where |
|---|---|---|
| `naturesGrace` | `true` | Options > Model |
| `showInnervate` | `true` | Options > OOM Widget |
| `effectiveMode` | `false` | dashboard hint-line checkbox (persisted) |
| `debug.categories.cast` | `true` | Debug Console |

New `MD.cdb` keys: `fights` (array of 20), `overheal` (map).

Options > Model grows from 120 to ~165px (two checkboxes and a "Reset overheal data"
button), so `MD.optionsTabHeight.general` goes 270 → 330.

New slash commands: `/md profile`. `MD.COMMANDS` and the About tab pick it up
automatically.

---

## 9. Delivery order

Each step is independently shippable and independently `luac -p`-checkable; each one
says what the author can see change.

| Version | Contents | Visible change |
|---|---|---|
| **v0.5.0** | Architecture only: `RankMath` split, `StaticCost(id, ctx)` + summed percentages, single combat-log handler, `UI/Tooltip.lua` + all consumers moved onto it, `MD:ShowCopyPopup` / `MD:Snapshot` extraction, dashboard file split | none intended — the widget gains a hover tooltip; `/md verify` output must be identical |
| **v0.5.1** | Nature's Grace + `cast` debug category | `Cast` column shows `2.9s*` for HT/Regrowth |
| **v0.5.2** | `Engine/ManaCooldowns.lua`, Innervate-aware clock, advisor rewired | `inn 2:10` segment under 90s; advisor numbers now match the clock |
| **v0.5.3** | `Engine/Overheal.lua`, effective mode, persisted fight history | Effective checkbox; history survives `/reload` |
| **v0.5.4** | Row tooltips, Simulate second row, `/md profile` | the big UX step |
| **v0.5.5** | `docs/TESTING.md` for the new surface, `DECISIONS.md` entries, release | — |

v0.5.0 first is deliberate: it is the only step with a real regression risk (four
tooltips rewritten at once), and shipping it alone means any breakage has one obvious
cause.

---

## 10. Phase 2 seams

The refactors above are shaped so Phase 2 (`docs/PLAN.md`) adds files rather than
reopening these:

* **Spell data** — `Data/SpellData.lua` keeps the framework (families, cost API, known
  index); the druid table moves to `Data/Spells_Druid.lua`, loaded by `SD:Load(class)`.
  A Priest table is then a new file plus one `.toc` line.
* **Rank math** — the per-family branch in `RowFor` becomes `MD.ClassRules[class]`:
  coefficient rule per family type (`direct` / `hot` / `hybrid` / `channel`), the talent
  multipliers, and the crit school. `Context()` calls the class's `Talents(ctx)`.
* **Mana cooldowns** — `MC.byClass` already has the Phase 2 stubs; each needs one
  `value()` function and one in-game log from someone of that class.
* **Unreported regen** — `RM:Unreported()` and `IN_FSR_TALENT` are already per class;
  Shaman Unrelenting Storm goes in only after a `/md regentest` paste, per the standing
  rule.
* **Overheal, fight history, tooltips, `/md profile`** are class-generic by
  construction — they key off spellIDs and the live client, never the druid table.

---

## 11. Calls worth arguing about before implementing

1. **`inn` on the one-liner vs tooltip-only.** §3.2 spends the addon's one secondary
   segment on it under 90s. The counter-argument: the widget's value is that it never
   changes shape, and the advisor already shouts when Innervate is worth using.
2. **Overheal scope.** Family-average is the only thing that will have data for months,
   but it is precisely the wrong shape for the question ("does downranking help?"). The
   alternative is to show effective numbers *only* for ranks with their own samples and
   leave the rest raw — honest, but a mostly-empty column.
3. **Effective mode as a toggle vs an eleventh column.** A toggle keeps the width; a
   column lets you see raw and effective at once, which is the actual comparison.
4. **Nature's Grace in To OOM / HP5, or HPS only.** Feeding it everywhere is
   self-consistent; feeding it to HPS only keeps the mana columns free of a
   crit-dependent assumption.
5. **Whether persisted overheal should decay with time or gear**, not just with events.

These are the five where a different answer produces a different addon, and the ones
worth a debate round before v0.5.2.
