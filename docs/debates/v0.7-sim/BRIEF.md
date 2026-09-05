# Debate brief: ManaDemon v0.7 — fight recording, replay, coaching, combat simulation

Read, in this order:
1. /home/penek/projects/addons/ManaDemon/.claude/worktrees/combat-log-design-arch-ffb907/CLAUDE.md  (what the addon is, conventions)
2. /home/penek/projects/addons/ManaDemon/.claude/worktrees/combat-log-design-arch-ffb907/docs/DESIGN-v0.7.md  (THE design under debate, rev 2)
3. /home/penek/projects/addons/ManaDemon/.claude/worktrees/combat-log-design-arch-ffb907/docs/DECISIONS.md  — the "v0.5" and "v0.6" sections only (how earlier calls were made and why)
4. Skim /home/penek/projects/addons/ManaDemon/.claude/worktrees/combat-log-design-arch-ffb907/Engine/RankMath.lua, Engine/Calibration.lua, Engine/Overheal.lua, UI/Summary.lua (the code the sim builds on)
5. The real log the design will be validated against: /home/penek/projects/addons/ManaDemon/.logs/dungeon-BF-1.txt (5600 lines; read the first 300 and grep around "+2154" for the hard pull)

## Facts established since the design was written (treat as given)
- WoW TBC Anniversary client, Lua 5.1, no libraries. Combat log via CombatLogGetCurrentEventInfo().
- SPELL_CAST_SUCCESS carries destGUID/destName (Details! addon reads them) -> the healer's own cast TARGET is available directly. The design's "match cast to first heal" is unnecessary.
- In *_DAMAGE events `amount` is the HP actually lost; `absorbed` is a separate field (Details adds it back to credit the attacker; for HP-lost, ignore it). Full absorbs arrive as SWING_MISSED/SPELL_MISSED with missType "ABSORB" and never reduce HP.
- Arg layout after the 11-field prefix: SWING_DAMAGE: amount, overkill, school, resisted, blocked, absorbed, critical...; SPELL_DAMAGE/SPELL_PERIODIC_DAMAGE/RANGE_DAMAGE: spellId, spellName, school, amount, overkill, ...; ENVIRONMENTAL_DAMAGE: envType, amount...; SPELL_HEAL/SPELL_PERIODIC_HEAL: spellId, spellName, school, amount, overhealing, absorbed, critical. `amount` on heals is GROSS (includes overheal) on this client.
- The author: Resto druid, level 64, currently a Dreamstate build (no Tree of Life), plays non-heroic 5-mans now, heroics and raids later. Says: "wait" (not casting) is a valid action because less drinking = faster runs; replay/coaching from real logs is the killer feature; damage presets should come from recordings and be improved from logs over time.
- The dashboard already computes per-rank heal/HPM/HPS with Pareto-non-dominated known ranks. Calibration compares model vs reality per event kind; the Regrowth hybrid split was just corrected from it.
- No Lua interpreter on the dev machine; syntax check only. Functional testing is in-game by the author, who reads logs back.

## The calls to argue (take a position on EACH, then add any the design missed)
C1. Deterministic expected-value simulation vs Monte Carlo (crit, pulse jitter, recorded-timeline resampling).
C2. Rule-based, fixed-order plan family (triage -> tank roll -> maintenance -> filler; <=5 binds, <=2 ranks/spell) vs a richer policy space (learned thresholds per target, per-phase plans, optimal control / DP on a coarse grid).
C3. Overheal endogenous via the HP cap only vs blending in the measured overheal fractions.
C4. Other healers: environment (their heals as negative damage on the recorded timeline) in replays; assignment in synthetic. Is that sufficient? What about the optimizer "stealing" heals other healers would have done?
C5. Event-driven simulation vs fixed time step.
C6. Separate window (/md sim with Review/Setup/Result panes) vs dashboard tabs.
C7. "Wait" as first-class action, reported as waitFraction; minActivity knob. Should the default constrain it?
C8. Replay validation before any planner work; what deviation is "ok" (mana curve, HP curves)? Should Coach be disabled on a fight that fails validation?
C9. Recording scope and caps: last 12 fights, 4000 events each, fights >=20s with >=5 own casts; HP snapshots every 5s; recordFights default on. Right numbers? What must be captured that isn't (buffs? deaths? target death? enemy count? player position/movement)?
C10. The six coaching labels (fine / overheal / rank / spell / early / idle) and "habits" summed over recordings. Sufficient? Actionable? Missing labels?
C11. Search: coordinate descent over ranks x thresholds, coroutine-sliced. Objective: minimize mana subject to nobody below a comfort floor after a grace period. Alternatives: lexicographic (deaths, min HP, mana), or a weighted score. What about tie-breaking and "robustness" (plan that survives small perturbations)?
C12. The scenario's damage timeline for coaching is the RECORDED one, which already includes the effect of the player's own heals on targets' behaviour? (It does not: damage taken is independent of healing, except deaths.) But recorded HP snapshots reflect the player's real heals; the sim recomputes HP from damage + simulated heals. Any trap here (e.g., a target that died in reality and stopped taking damage)?
C13. Presets from recordings: per-role mean rate + pulse detection (2s window > 3x mean). Sound? Better summarization?
C14. Should coaching ever suggest DIFFERENT binds than the player currently uses, or only tune how they use what they have? (Human factor: rebinding mid-progression.)
C15. Where does the GCD/reaction delay live, and should latency be modelled (0.3s default)?
C16. Delivery order: recorder -> engine + replay -> planner + classification -> search -> Review UI -> synthetic Setup -> docs. Agree? What is the smallest thing that proves the whole idea to the author (the "first win")?

## Output format (STRICT)
Write a markdown file at the path given in your instructions. For each call C1..C16: a heading, your POSITION in one line, the STRONGEST argument (3-6 sentences, concrete, referencing the code/log where possible), what you would CONCEDE, and a one-line RISK if your position is adopted. Then a section "MISSING FROM THE DESIGN" (3-8 items, each one paragraph). Then "MY TOP 3 DECISIONS THAT MATTER MOST". Be specific and technical; no throat-clearing; no restating the design back. Where you can quantify (events per fight, ms per simulation, bytes per recording, sample sizes), do.
