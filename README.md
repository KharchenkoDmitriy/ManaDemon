# ManaDemon

Mana management for TBC Anniversary healers: a live **time-to-OOM** projection, a
**healing rank dashboard** for downranking decisions, and push alerts at the moments
that actually matter (Innervate/potion timing, "your efficient rank changed — rebind?",
drink reminders).

## Features

- **`OOM 1:24 ↓`** — one-line readout of when you'll run dry, as a floating widget and/or
  an ElvUI datatext. Pessimistic estimate; `~` marks an unstable read. The thin underline
  fills over 5s after each cast — full means spirit regen is running (five-second rule).
- **`/md`** — rank dashboard: per-rank heal / mana / HPM / HPS with *your* +healing,
  talents and TBC downranking penalties. Ranks that are worse on both efficiency and
  throughput are hidden. Druid-only for now; everything else works for any mana healer.
- **Advisor** — "Innervate now — you're down 4,200 mana", "Super Mana Potion now",
  "+52 healing — Regrowth R7 is now your efficient rank. Rebind?", "Drink."
- **End-of-combat line** — `3:42 · net -212 mp5 · spent 18.4k · overheal 31% ·
  spirit regen realized 64% · max-rank casts 71%`.

## Commands

`/md` dashboard · `/md unlock` / `lock` / `reset` widget · `/md mute` · `/md drink` ·
`/md window N` · `/md verify` · `/md fsrtest` · `/md help`

## First install

The widget appears unlocked for 60 seconds — drag it where you want it, then `/md lock`.
Run `/md verify` once: it checks the static TBC spell data against your client and prints
anything that needs fixing.

ElvUI users: enable the **ManaDemon** datatext in any datatext slot
(ElvUI config → DataTexts).
