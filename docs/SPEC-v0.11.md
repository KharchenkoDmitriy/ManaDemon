# ManaDemon v0.11 — one window, four groups: implementation spec

**This is the document to implement from.** The author, 2026-09-07:

> "Merge settings and dashboard windows. Keep the colour schema more like in settings. Do
> grouping of the views like ElvUI does — top level categories are tabs/buttons in a left vertical
> column, nested categories are tabs/buttons in a horizontal line on top, and if there are more
> levels of sub-categories they are drawn inside a box which has the same rule, again tabs on the
> left then on the top. I want to group spell efficiency into a group, reports based on logs like
> wasted mana into a separate group, simulation as a third group, and settings as a fourth."

Read first: `UI/Style.lua` (the whole kit), `UI/Dashboard.lua`, `UI/OptionsFrame.lua`,
`UI/Options_General.lua`, and the four pane files the dashboard hosts today.

Conventions as always: Lua 5.1, no libraries, no bare `|` in a rendered string, `.toc` order,
all eight suites green before every commit, `make release`, merge to local master per version.

---

## 1. What is wrong with two windows

`/md` opens a 912 × 617 dashboard whose top edge carries **eight** buttons: six spell families,
Waste, Review — plus a Settings button that opens a *second*, differently coloured window with
its own tab strip. The two windows disagree about what a tab looks like, one of them is movable
and the other is not, and a view that belongs to neither (the simulator, `/md sim`) is a third
window again. There is no room left along that top edge, which is why Review and Waste ended up
beside `Healing Touch` as if they were spell ranks.

The grouping the author asks for is not decoration: it is the thing that makes room.

---

## 2. The shape

One movable window. Two levels of navigation, and a third only where it is needed:

```
+----------------------------------------------------------------+
| ManaDemon                                                    X  |
+----------+-----------------------------------------------------+
| Spells   |  [Healing Touch] [Regrowth] [Rejuvenation] [Life...] |   <- level 2, horizontal
| Reports  |  ................................................... |
| Simulate |  .          the pane for (level 1, level 2)        . |
| Settings |  ................................................... |
|          |  +-----------------------------------------------+  |
|          |  | Sub | [tab] [tab]                             |  |   <- level 3, same rule,
|          |  |     |  content                                |  |      inside a box
|          |  +-----------------------------------------------+  |
+----------+-----------------------------------------------------+
```

- **Level 1** (left column, vertical): `Spells`, `Reports`, `Simulate`, `Settings`.
- **Level 2** (top of the content area, horizontal): that group's views.
- **Level 3**: only inside a pane that needs it, drawn in a bordered box that repeats the rule —
  its own left column, its own top row. Nothing in v0.11 needs level 3 yet; the box exists so the
  next thing that does is not a fourth window.

### 2.1 The four groups

| level 1 | level 2 | comes from |
|---|---|---|
| **Spells** | Healing Touch, Regrowth, Rejuvenation, Lifebloom, Swiftmend, Tranquility | today's family tabs + `UI/Dashboard_Rows.lua` |
| **Reports** | Waste, Review, Runs | `UI/Dashboard_Waste.lua`, `UI/Dashboard_Review.lua` (the run selector becomes its own level-2 view rather than a button group inside Review) |
| **Simulate** | Build a fight, From recordings | `UI/SimWindow.lua`, which stops being a separate window |
| **Settings** | General, About | `UI/Options_General.lua`, `UI/Options_About.lua`, which stop being a separate window |

The **Simulate strip** (`UI/Dashboard_Simulate.lua`) is a property of the Spells group — it is a
what-if over the rank table — and stays pinned above the rank table there, not in the Simulate
group. Naming is the only thing they share.

### 2.2 Colour

The settings window's palette wins, everywhere: `UI.CreateFrame`'s flat panel, the options frame's
header, `accent-hover` buttons, the titled-pane borders. The dashboard's own darker table
background goes. Concretely, one place decides — `UI/Style.lua` gains `UI.PALETTE` with the values
the options frame uses today, and every window reads it rather than repeating literals.

---

## 3. The kit: `UI.CreateNavFrame`

The whole point is that this is written **once** and the panes stay dumb.

```lua
local nav = UI.CreateNavFrame("ManaDemon", "ManaDemonFrame", W, H, {
    { id = "spells",   text = "Spells",   views = { { id = "HealingTouch", text = "Healing Touch" }, ... } },
    { id = "reports",  text = "Reports",  views = { ... } },
    ...
}, onSelect)          -- onSelect(groupID, viewID, contentFrame)
```

- `nav:Select(group, view)` — also what `/md`, `/md sim`, `/md options` and every existing
  entry point call, so `/md sim` becomes `nav:Select("simulate", "build")` and keeps working.
- `nav:Content()` — the frame a pane parents itself to. Panes are created **lazily**, on first
  selection, and cached: a druid who never opens Simulate never builds it.
- `nav:SetViews(group, views)` — for a group whose level 2 is dynamic (Reports/Runs).
- The level-3 box is `UI.CreateNavBox(parent, w, h, groups, onSelect)`, the same code with a
  border and no header.

Selection is remembered in `db.uiPath = { group, view }` and restored on open.

---

## 4. Delivery order

| version | ships |
|---|---|
| **v0.11.0** | `UI.PALETTE` + `UI.CreateNavFrame` / `UI.CreateNavBox` in `UI/Style.lua`, with `tools/navui.lua` exercising them under the stub. No behaviour change anywhere else |
| **v0.11.1** | The dashboard moves into it: Spells and Reports groups, the old top strip removed, `/md` unchanged from the outside |
| **v0.11.2** | Settings moves in as the fourth group; `/md options` selects it; `UI/OptionsFrame.lua` becomes a thin shim |
| **v0.11.3** | Simulate moves in as the third group; `/md sim` selects it; the standalone window goes |
| **v0.11.4** | Runs becomes its own Reports view, and the level-3 box gets its first real use if the run card needs one |

Each version leaves every entry point working. No version is allowed to strand a view.

---

## 5. What must not regress

- **`/md`, `/md sim`, `/md options`, `/md replay`** keep working exactly as they do now. The
  replay window stays separate: it is a player, not a view, and it wants the whole screen.
- **The Review tab's buttons** (Validate / Coach / Coach pull / Play / Pin / Export / Start run)
  keep their behaviour, including the shift-click paths.
- **`tools/reviewui.lua` and `tools/replayui.lua` keep passing** — they drive the panes, not the
  window, and if they need changing beyond the parent frame then the pane has been coupled to the
  window and that is the bug.
- Nothing may open in combat that could not before.

## 6. Rejected

- **A scroll frame for the left column.** Four groups. If it ever needs scrolling, that is a
  design failure to fix, not to paper over.
- **Making the replay window a fifth group.** It is 900+ pixels of unit frames on its own clock.
- **Porting ElvUI's options library.** No libraries; the kit is 40 lines of button group and a
  content frame.
- **Keeping the dashboard's palette anywhere.** One palette, in one file.
