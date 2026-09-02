# ManaDemon

Mana management for TBC Anniversary healers: a live **time-to-OOM** projection, a
**healing rank dashboard** for downranking decisions, and push alerts at the moments
that actually matter (Innervate/potion timing, "your efficient rank changed — rebind?",
drink reminders).

## Features

- **`OOM 1:20 v  rest 2:10`** — one-line clock, as a floating widget and/or an ElvUI
  datatext. The label carries the sign: `OOM 1:20` while you are draining, `FULL 0:45`
  while regen wins (and out of combat, drinking included). `rest 2:10` is how long until
  full if you stop casting right now. `OOM >4:00` means the net rate is within noise;
  `~` marks an unstable read; `vv` in red under 20s. Digits are shown only as precisely
  as the model actually knows them. The thin underline fills over 5s after each cast —
  full means spirit regen is running (five-second rule).
- **`ManaDemon Regen`** — a second ElvUI datatext showing your *current* mp5 (casting
  regen inside the five-second rule, full regen outside), unlike the stock one.
- **`/md`** — rank dashboard: class tab, spell subtabs, every rank with heal / mana /
  HPM / HPS using *your* +healing, talents and TBC downranking penalties; Lifebloom
  shows x2 / x3 rolling-stack rows. Druid-only for now; everything else works for any
  mana healer. The Settings tab is the GUI for every option.
- **Advisor** — "Innervate now — you're down 4,200 mana", "Super Mana Potion now",
  "+52 healing — Regrowth R7 is now your efficient rank. Rebind?", "Drink."
- **End-of-combat line** — `3:42 | net -212 mp5 | spent 18.4k | overheal 31% |
  spirit regen realized 64% | max-rank casts 71%`.

## Commands

`/md` dashboard · `/md unlock` / `lock` / `reset` widget · `/md mute` · `/md drink` ·
`/md rest` · `/md window N` · `/md verify` · `/md fsrtest` · `/md help`

## First install

The widget appears unlocked for 60 seconds — drag it where you want it, then `/md lock`.
Run `/md verify` once: it checks the static TBC spell data against your client and prints
anything that needs fixing.

ElvUI users: enable the **ManaDemon** datatext in any datatext slot
(ElvUI config → DataTexts).
