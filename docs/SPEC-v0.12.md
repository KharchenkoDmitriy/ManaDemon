# ManaDemon v0.12 — what the healer can see: implementation spec

**This is the document to implement from.** The author, 2026-09-07:

> "Healing with HoTs is a proactive play. When there is a 1.2k deficit and 350+ incoming damage
> it is already time to cast one Lifebloom with 0% overheal. I think we need to allow the
> simulation to look into the future a bit — not the exact future, but at least approximate
> incoming damage numbers and potential targets (if it is well indicated — a target spell or
> aggro — it knows the target; if not, it does not)."

and, on how to decide what counts as "indicated":

> "You can take a look at all the indication Cell does, and my settings, to understand what I am
> actually able to see."

and then, on the indicators they have switched off:

> "You can keep the indicators that I switched off. If there is an option to see it, then
> technically I could see it — if it is switched off it means I prefer clarity, or maybe I do see
> those in another way. Even so I would like an explanation on each coach cast on why it cast
> exactly this spell, on that target, at that moment (and ideally why casts from the recording
> were inefficient), so if I catch from the coach that I am missing some information because of a
> switched-off Cell option, even better."

So the rule for this version is not a judgement call, and it is not the *current* state of a
checkbox either. **The plan may know what a healer using this UI could see** — anything Cell is
able to display, whether or not it is displayed today. An indicator that is off is a preference
about clarity, not a limit on what is knowable, and the author reads some of it elsewhere anyway.

That cuts the other way too, and it is the better half of the deal: when the coach explains a
decision with something the author is not currently showing, **that is a finding about their UI**,
not a cheat. The explanation lines in §6 are what turn it into one.

Read first: `Engine/SimPlanner.lua`'s causality block, `Engine/SimModel.lua` (`SM.SeenDamage`,
`RecentDamage`, `ScenarioFromRecording`), `Engine/FightRecorder.lua`, `docs/DECISIONS.md` §v0.7.

---

## 1. What the author's frames actually show

Read from their Cell SavedVariables (account `124250034#1`, layout `default`) on 2026-09-07.
Enabled indicators, and what each one is driven by:

| Cell indicator | on | driven by | is it foresight? |
|---|---|---|---|
| Health Text (`deficit_short`) | yes | current health | no — **the deficit as a number**, which is how the author plays |
| Name / Status Text | yes | dead, ghost, offline, **drinking** | no |
| Status Icon, Role Icon, Leader, Raid Icon | yes | roster | no — role is already recorded |
| **Aggro (bar)** and **Aggro (border)** | yes | `UnitThreatSituation` | **yes** — who the mobs are on, before they are hit |
| **Targeted Spells** (1 icon, filtered list) | yes | `UnitCastingInfo` / `UnitChannelInfo` on hostile units, matched to a party member | **yes** — a cast is in the air and its target is named |
| Defensive Cooldowns, External Cooldowns | yes | buffs | no — recorded since v0.8.3 |
| Dispels, Debuffs (`raidDebuffs`) | yes | debuffs | no — recorded since v0.8.3 |
| AoE Healing | yes | how many are hurt nearby | no — derivable from health |
| Missing Buffs, Actions | yes | buffs | no |
| Power Text | off | party mana | **usable** — a healer can read another healer's mana |
| Health Thresholds | off | health | usable, and derivable from health anyway |
| Target Counter | off | how many mobs on a unit | **usable** — the count Cell can show |
| Combat Icon, Aggro (blink), Target Raid Icon, Party Assignment | off | present-tense state | usable; nothing new over what is above |

Two of those are foresight, and only two: **aggro** and **an enemy cast with a named target**.
Everything else is the present, and most of it the recorder already keeps.

The off/on column is kept as a record of what the author sees *today*, because §6's explanations
name it: a card that says "the tank had two mobs on him" when Target Counter is switched off is
telling them something their frames are not.

## 2. What the plan may therefore know

The causality budget grows by exactly two entries, both of which are *present-tense facts about
the world* rather than future events:

1. **Threat**: for each tracked target, `UnitThreatSituation` at time t — is a mob on them now.
2. **An incoming cast**: a hostile cast or channel in flight at time t, its spell, its target and
   **when it lands**. A cast bar is a promise the game itself is making; reading it is not
   clairvoyance, it is reading the screen.

Everything else stays as it is: health, mana, form, cooldowns, the player's own HoTs, and damage
**already taken** (`SM.RecentDamage`, `SM.SeenDamage`).

**Still forbidden**, and the harness must keep proving it: any event with `t' > t` that is not a
cast already in the air. A swing that has not been wound up, a mob that has not pulled, a
proc — none of those are visible to a healer and none may reach `Plan:Decide`.

## 3. v0.12.0 — recording what the frames show

`Engine/FightRecorder.lua` gains two event kinds. Both are cheap and neither is modelled.

```lua
K.THREAT = 13   -- tgt = roster index, amt = status (0..3), x = 0
K.ECAST  = 14   -- tgt = roster index (the cast's target), amt = seconds until it lands, x = spellID
```

- **Threat**: sampled with the existing 2 s HP snapshot, `UnitThreatSituation("player", unit)`
  per tracked target; only changes are written.
- **Enemy casts**: `SPELL_CAST_START` from a source that is not in the roster, whose destination
  *is* a tracked target. The combat log carries the cast time; a channel is `SPELL_CHANNEL_START`.
  A cast that is interrupted or misses is recorded as it happened — the plan sees the same cast
  bar the author saw, including the ones that never landed.

The stream stores the spell name (v0.10.1 already does this for own casts) so the replay window
can draw the same **Targeted Spells** icon the author has enabled, on the same corner of the
frame.

`db.recordThreat` (default true) turns the pair off for anyone who does not want the bytes.

## 4. v0.12.1 — the plan reads them

`Plan:Decide` gains, on the state it already receives:

```lua
S.threat[i]     -- 0..3, as of t
S.incoming[i]   -- { at = <t it lands>, spellID, name } or nil, the soonest cast aimed at i
```

Two uses, both narrow:

- **Rule 4's room** counts a cast in the air: `room = deficit + rate * horizon + incomingBefore(i, t + horizon) - pending`, where `incomingBefore` is the *recorded* damage of casts that will land inside the HoT's own duration. A Lifebloom cast into an incoming Shadow Bolt is not overheal, and the author's rule ("1.2k deficit, 350 incoming, cast now") is exactly this.
- **`Anchor`** prefers a target with threat over one without, before falling back to "who has taken the most". Today it prefers the TANK *role*; a mob that has left the tank is invisible to it.

The estimate of what an incoming cast will hit for is **the recording's own number** — what that
spell actually did to that target in this fight. No spell database, no guess. When the fight has
no sample of it yet, it counts as zero and the rule falls back to the damage rate.

## 5. v0.12.2 — showing it

The replay window draws what the author's frames draw and nothing more: the **Targeted Spells**
icon on the top-left corner of a frame while a cast is in the air (their position: `TOPLEFT`,
offset `-4, 4`, one icon, `showAllSpells = false`), and the **aggro border** in their thickness
(2 px). Both from the recorded events, both on the left column *and* the right, because both
columns are watching the same fight.

## 6. v0.12.3 — why it cast that, there, then

> "I would like an explanation on each coach cast on why it cast exactly this spell, on that
> target, at that moment — and ideally why casts from the recording were inefficient."

Today the suggested column can say **which rule** fired (`SP.RULE_NAMES`, on hover) and the left
column carries the classifier's one-word label. Neither says *why now*, and a rule name is not a
reason: "the HoT that fits the deficit" does not tell you that the deficit was 1.2k, that 350 a
second was coming in, and that all 1357 of a Lifebloom would therefore land.

### 6.1 The numbers that made the rule fire

`Plan:Decide` returns a third value already (the rule). It gains a fourth: a small **reason
record**, reused per decision so the search allocates nothing:

```lua
{ rule = 4, deficit = 1204, rate = 351, pending = 0, room = 3661, heal = 1357,
  hpm = 6.17, waitedFor = nil, threat = 2, incoming = { spellID = ..., at = 41.2 } }
```

The trace stores it beside the cast (the `why` slot becomes an index into a per-run reason list).
The window renders it as a sentence under the cast bar and in the hover:

```
Lifebloom on Penek at 32.4s
  1.2k missing, 350/s coming in -> all 1357 lands, none wasted
  6.17 healing per mana, the best this plan can buy
```

and for a wait, which is a decision too:

```
waiting at 28.0s -- 620 missing, 74/s coming in; a Lifebloom would waste 737
```

### 6.2 Why *your* cast was inefficient

The classifier already labels every recorded cast (`overheal`, `early`, `rank`, `spell`, `stack`,
`late`, `idle`). Each label gains the same treatment — the numbers behind it, from the recording:

```
Rejuvenation on Penek at 44.1s -- overheal
  target was at 92% (410 missing), the tick alone is 398: 1194 of 1592 wasted
Regrowth on Destroyka at 51.0s -- rank
  R9 healed 2702 into a 900 deficit; R6 would have covered it for 218 less mana
```

The label stays one word so the strip is readable; the sentence is the hover and the card.

### 6.3 Where they appear

- **The replay window**: under the cast in the strip, on both columns, for the cast that is
  landing; and in the hover for any cast marker on the scrubber.
- **The card**: a `why` section listing the plan's first divergence from the recording with both
  sentences side by side, which is the comparison the author keeps making by hand.
- **`tools/import.lua replay N`**: the same sentences, one per line, offline.

### 6.4 What it must not become

A reason is the inputs the rule read, in the units the author reads. It is **not** a
justification written after the fact, it may not cite anything `Decide` did not see (§2), and a
rule that fired on a number nobody can name is a rule that should not exist.

## 7. Harness

- `reccheck`: a scripted enemy cast on a tracked target is recorded with its landing time and its
  spell; a cast aimed at an untracked unit is not.
- `replaycheck`: **the causality test grows a second half** — a cast that starts at 38 s and lands
  at 40 s *may* change what the plan does from 38 s (it is on screen), and a swing at 40 s with no
  cast bar may not change anything before it. That pair is the whole of this version's ethics in
  two assertions.
- `replayui`: the targeted-spell icon appears for the seconds the cast was in the air, on both
  columns, and every cast in either column has a reason sentence carrying at least one number.
- `replaycheck`: a reason never cites a fact the plan was not given -- the reason record's fields
  are a subset of what `Decide` received, asserted field by field.

## 8. Rejected

- **Anything Cell cannot show at all.** That is the line, not the checkbox: an option that exists
  is knowable, an option that does not exist is not.
- **Boss timers and encounter journals.** Not in Cell, not on their screen, and a dungeon trash
  pull has none.
- **Predicting a swing.** A melee swing has no cast bar. The damage rate already carries it.
- **Reading Cell at runtime.** As ruled in v0.8.6: the settings are read once, by a human, and
  written down. This spec is that reading.
