# Spell Bracket Visualizer

A [Noita](https://noitagame.com/) mod that shows a wand's **cast structure**
Lisp/SLIME-style, so you can see at a glance which spells fire
**simultaneously** in each cast, which modifiers feed which projectile, what a
multicast gathers, what a trigger's payload is — and, crucially for rapid-fire
wands, **when the wand WRAPS** (a forced draw past the deck's end pulls cards
from the wand's start and forces the recharge).

Two views, both live while the inventory is open:

1. **Wand structure panel** (docked beside the held wand's box, so it tracks
   your selection and updates live as you rearrange spells): an indented tree
   of the held wand, one cast per section, rainbow nesting spines by depth,
   spell names colored by action type. Wrapping casts get a loud orange
   `WRAPS! -> recharge` banner and wrapped-in cards are marked `~`. When a
   wide wand leaves no room beside the boxes the panel drops below them, and
   it clamps to the screen (`... +N more`) instead of overflowing.
2. **Slot brackets** (in the wand UI itself): `[ ]` bracket glyphs hugging
   each group's first and last card — SLIME rainbow parens, color cycling by
   nesting depth, no text labels (the card art already says what the group
   is). Leading modifiers sit *outside* the brackets, matching Lisp
   notation; closes that share a card nest within it, outermost on the edge
   with its hooks wrapping the inner ones. **Orange marks the wrap**: the
   group the wrap happened in gets an orange `wraps to front` tag, orange brackets
   around the wrapped-in cards at the wand's start, and a carriage-return
   line under the row connecting the two — "the draw continues here".

## How it works

The panel simulates the engine's exact draw rules (verified from `gun.lua` in
`data.wak`): each cast draws the wand's *spells/cast* expressions; modifiers
(and every other card that force-draws one replacement, like Alpha)
prefix-attach; multicasts gather N cards; triggers open nested payloads; and
forced draws on an empty deck wrap the discard back in, in slot order, ending
the recharge cycle. Always-cast spells are listed separately (they join every
cast). Shuffle wands get an "order varies!" warning — the simulation shows
the slot-order outcome, one possible draw order of many.

The engine renders the inventory itself (no Lua hook exposes slot or box
positions), so the panel draws on its own Gui at safe coordinates, while the
slot brackets use a calibrated model of the wand-box layout: boxes stack with
per-wand heights of `max(37, 14 + 2 × sprite px)` engine units (each wand's
art height is read at runtime), so brackets stay put across wand pickups,
reordering, and selection changes.

## Settings (in the in-game mod settings menu)

- **Wand Structure Panel** — on/off (runtime; applies immediately).
- **Slot Brackets** — the in-UI rainbow brackets (runtime; on by default).
- **Calibration Overlay (debug)** — draws the computed slot-row lines and
  per-wand sprite reads; turn on + screenshot if brackets ever misalign.

## Project layout

```
init.lua                     # OnWorldPostUpdate: drives the overlay
settings.lua                 # mod settings menu
files/structure_meta.lua     # generated per-spell structural metadata (draws/group/payload)
files/wand_structure.lua     # pure deck simulator: casts, chaining, multicasts, wrap
files/grouping_overlay.lua   # reads the live wand + draws the panel / slot brackets
tools/gen_structure_meta.py  # regenerates structure_meta.lua from data.wak
tools/test_wand_structure.py # Python mirror of wand_structure.lua + tests
tools/gen_icons.py           # (retired icon-recolor feature; see below)
mod.xml, compatibility.xml
```

Regenerate `structure_meta.lua` after a game update:

```
python3 tools/gen_structure_meta.py
```

## Testing

1. Enable **Spell Bracket Visualizer** in the mod menu, start/continue a run.
2. Hold a wand and open the inventory: the panel docks beside its box; with
   Slot Brackets enabled, rainbow strips mark each group in the wand boxes.
3. `python3 tools/test_wand_structure.py` runs the simulator's test suite
   (a Python mirror — no Lua needed).

Unsafe Lua APIs are not requested (`request_no_api_restrictions="0"` in `mod.xml`).

## Retired: icon recolor

The mod originally re-pointed every vanilla spell's icon at a generated copy
with a type-colored border (red projectile, blue modifier, …). It was retired
2026-06-09 — the rainbow brackets made the borders redundant visual noise.
To revive it: `git log` for `files/recolor_actions.lua` / `files/known_ids.lua`
and the `OnModInit` hook in `init.lua`, and regenerate the icons with
`python3 tools/gen_icons.py`.

## Known limitations

- Only the standard spell set (`gun_actions.lua`) is modeled; mod-added spells
  appear in the panel as plain leaves.
- The panel can't know your mana or spell uses, so a cast that fizzles on mana
  (or skips a depleted spell) may differ from the simulation.
- Shuffle wands: the panel shows the slot-order outcome with a warning; the
  real draw order randomizes each cycle.
- The slot brackets' geometry is calibrated at GUI 640×360 (constants scale as
  fractions of GUI width, so other sizes should track) — if brackets ever
  misalign, flip **Calibration Overlay** and screenshot to recalibrate; the
  panel is always reliable regardless.
