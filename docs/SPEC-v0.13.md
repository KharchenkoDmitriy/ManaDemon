# v0.13 — the solver: a spell is a series of deposits

## 1. Why

Five rules with five thresholds (`swiftmendBelow`, `directBelow`, `rollStacks`,
`hotBelow`, `filler`) is a fixed shape fitted to one healer at one gear level. Every
correction the author has made since v0.11.9 has been the same shape of complaint:
*the threshold is not the question*.

> "healing with hots is a proactive play, when there is 1.2k deficit and 350+ incoming
> its already the time to cast one lifebloom with 0% overheal"

> "in some cases I do apply rej if I expect more incoming damage then lifebloom can heal,
> not just on hp trashhold"

And the logs said it independently (v0.13 research, `tools/wclrules.py`): the #1 ranked
resto druid picks his spell by the **damage rate on the target**, not by its health.
Health medians across his four spells barely separate (80 / 73 / 58 %); the trailing
damage separates by seven times (872 / 2030 / 4993 / 6206).

A threshold cannot express that. A budget can.

## 2. The model

**Every spell is a series of deposits: `{ dt, amount }`.** A direct heal is one deposit
at the end of the cast. A HoT is one deposit per tick. Lifebloom is its ticks plus the
bloom at the end. Swiftmend is one deposit now that *removes* the remaining deposits of
the HoT it eats. Nothing else about a spell matters to the decision.

The amounts come from `RankMath:SpellKit()` — that is, from **the user's own stats**.
The same solver run by a level 64 druid in Hellfire and a level 70 druid in Sunwell
produces different schedules from identical code, because their deposits differ. There
is no table of thresholds to re-tune per character, which is the whole point.

## 3. The demand

Against the deposits stands the **demand**: the health that is missing now, plus the
health the forecast says will go missing over the horizon.

The forecast may read **only what §2 of `docs/SPEC-v0.12.md` allows** — the present, the
trailing damage, threat, and an enemy cast already in the air. It is a guess a human
could make from their own frames, and the causality test in `tools/replaycheck.lua`
continues to hold it to that. Scheduling against the damage that *actually* arrives
would make the coach clairvoyant and its advice unreproducible.

```
demand_i(tau) = deficit_i(t) + rate_i * (tau - t) + inbound lumps
rate_i        = max(trailing 5s / 5, damage seen this fight / elapsed)     -- SM.SeenDamage
```

## 4. The decision

Every candidate is a `(spell, target)` pair the healer can afford, plus **wait**. Each
one is scored by projecting the target's health over the horizon twice — with the cast
and without it — and measuring:

```
gap      = integral of missing health over the horizon      (health x seconds)
saved    = gap(without) - gap(with)                          -- what the cast BUYS
value    = saved / mana
```

`saved` is one number that already contains all three things the author asked for:

- **minimal hp gap** — it is literally the integral being reduced;
- **minimal overheal** — a deposit landing above full buys no gap reduction, so an
  overhealing cast scores itself down without a separate penalty term;
- **lowest mana** — it is per mana.

It also gets the timing right for free: a deposit that lands late reduces the gap less
than the same deposit landing now, so a deeply hurt target pulls a direct heal and
spread damage pulls a HoT, with no rule saying so.

**Safety comes first, as it always has.** If the projection has a target crossing the
measured danger line (`SM` danger, v0.10.3) inside the horizon, only candidates that
prevent that are considered, cheapest first. `deaths` and `floorSeconds` stay ahead of
mana in the lexicographic score; the solver changes how a cast is *chosen*, never how a
plan is *judged*.

**Waiting is a candidate with a value, not a fallback.** The same target is scored one
global cooldown later, with the deficit the forecast will have added and any HoT that
frees up by then. If waiting scores higher and nobody crosses the danger line meanwhile,
the plan waits — which is v0.11.13's "can they hold out until the efficient spell is
free" as a special case rather than a hand-written branch.

## 5. What survives

- `SP.OBJECTIVES` and the four strategies are unchanged: they read the same pool.
- `SM.ChainRun`, the gates, the replay, the trace and the reason records are unchanged.
- The reason a cast carries (v0.12.3) gets *better*, because the solver knows the number
  it decided on: `1.2k missing and 350/s coming -> Lifebloom lands 1357 of 1357 inside
  the gap, 6.2 health-seconds per mana; Rejuvenation buys 4.1`.
- The old threshold planner stays, as `plan.kind = "rules"`, so the two can be scored
  against each other on the same recording. It is the control.

## 6. What is tunable

The solver has **two** parameters where the rules had five:

- `minValue` — the efficiency floor under which it would rather wait and keep the mana.
  This is the mana-budget dial, and it is what the four strategy objectives move.
- `horizon` — how far ahead the forecast is taken seriously. Long enough for a HoT to
  land whole, short enough that the guess is still a guess. Ships at 12s (Rejuvenation's
  own duration) and the search may move it.

`SP.Search` is unchanged in shape: coordinate descent over whatever parameters the plan
declares.

**Measured on the author's five recordings (2026-09-08), against the rules as the control:**

```
rules (5 thresholds)                 deaths 0   floor 0.0s   mana 21900
solver, minValue 15, horizon 18      deaths 0   floor 0.0s   mana 12372     -43%
```

Two things the sweep said that the design did not predict. **`horizon` is the parameter
that matters and `minValue` is nearly inert** -- anything below 10 changes nothing at all,
because every candidate the solver looks at already clears ten health-seconds per mana.
And **a longer horizon is not monotonically better**: 12s leaves 2.1s under the danger
line, 18s leaves none, 24s leaves 1.4s. Too short and the dip is not seen coming; too long
and the forecast smears a burst into an average and under-reacts to it.

## 7. Harness

- `solvercheck`: a spell's deposits sum to the kit's total healing; Swiftmend's deposit
  removes the eaten HoT's remaining ones.
- `solvercheck`: an overhealing cast scores below a non-overhealing one of the same mana,
  with no overheal term in the code.
- `solvercheck`: a deeply hurt target with no incoming damage pulls a direct heal; the
  same deficit spread over the horizon pulls a HoT. Same code, same kit, different demand.
- `replaycheck`: the causality test passes for the solver as it does for the rules — a
  burst at 40 s may not change a cast made before it.
- The comparison, printed and not asserted: solver against rules on every real recording,
  same lexicographic score. The solver has to win or tie to replace anything.
