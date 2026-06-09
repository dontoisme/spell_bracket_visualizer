# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A [Noita](https://noitagame.com/) mod ("Spell Bracket Visualizer") showing a wand's
**cast structure** Lisp/SLIME-style: a companion panel + in-UI rainbow bracket
strips showing which spells fire simultaneously each cast, which modifiers feed
which projectile, what a multicast gathers, a trigger's payload — and when the
wand **wraps** (the rapid-fire mechanic).

A first feature — recoloring every spell icon with a type-colored border — was
**retired 2026-06-09** (redundant next to the rainbow brackets). Its code
(`recolor_actions.lua`, `known_ids.lua`, `files/icons/`, the `OnModInit`
`ModLuaFileAppend` hook) lives in git history; `tools/gen_icons.py` remains.

The mod directory IS the install location (`…/Noita/mods/testMod`), so edits here
are live in the game on next run-load (quit to menu → Continue).

## Commands

There is no build/lint/test for the Lua mod — it loads directly. The Python tools
regenerate committed data files from the game's `data.wak`:

```bash
python3 tools/gen_structure_meta.py   # regenerate files/structure_meta.lua
python3 tools/test_wand_structure.py  # run the parser/simulator tests (Python mirror)
python3 tools/gen_icons.py            # (retired feature) regenerate bordered icons
```

All pure stdlib (no Pillow/deps). They locate `data.wak` at `../../data/data.wak`
relative to the mod; override with `$NOITA_WAK` or argv[1] if the install differs.
Re-run the meta generator after a Noita update. `files/structure_meta.lua` is
committed and generated — don't hand-edit it; change the generator and re-run.

Testing is manual, in-game (the GUI game can't be launched headlessly from WSL):
enable the mod in Noita's mod menu, start/restart a run, open a wand or shop.

## Architecture — the key constraint

**Noita renders the spell inventory in the engine, not Lua.** There is no Lua draw
hook to paint over the spell-slot UI, and the engine never exposes where it drew
the wand boxes or slots. Consequences:

- The companion panel (`files/grouping_overlay.lua`, driven every frame from
  `OnWorldPostUpdate`) draws with its own `GuiCreate()` at coordinates it fully
  controls — always correct, resolution-proof.
- The in-UI "slot brackets" (`collect_delims`/`draw_delims`/`BOX` table) overlay
  rainbow `[ ]` glyphs on a **calibrated model** of the wand-box layout, in
  engine-UI units (1u = 0.0025·GUI width). Boxes stack with per-wand heights
  `max(37u, 14u + 2u·sprite px)` — each wand's art height is read at runtime
  (`SpriteComponent.image_file` → `GuiGetImageDimensions`). Selection changes
  NOTHING (two earlier "selected box is taller" theories were a tall wand
  sprite in disguise — see docs/STATUS.md). Wrapping is drawn as an orange
  carriage-return line from the forward close back to orange brackets around
  the wrapped-in cards, emitted only by the innermost wrapping group; group
  brackets always keep their rainbow depth color. Drawn at z = -10 (lower z =
  front) to beat the engine's spell-frame layer. If geometry drifts, the
  "Calibration Overlay" mod setting draws computed rows + sprite reads for
  recalibration from one screenshot.
- (The retired icon-recolor worked around the same constraint by swapping each
  spell's `action.sprite` via `ModLuaFileAppend` onto `gun_actions.lua` — see
  git history if reviving.)

## The cast-structure model

The grouping feature rests on a source-verified model of how `gun.lua` resolves a
shot: cards pop off **one flat ordered deck**. A *cast* draws `actions_per_round`
root expressions (root draws never wrap). A card that force-draws (`draws=1`)
prefix-attaches like a modifier; `draws>=2` is a multicast gathering that many
cards; a trigger projectile opens a nested sub-shot of `payload` cards. On a
*forced* draw with an empty deck the wand **wraps**: the discard pile returns (slot
order on non-shuffle wands) and drawing continues from the wand's start, ending the
recharge cycle after that cast. Chaining is decided by the card's `draws` count,
NOT its action type (ALPHA/I_SHOT chain; RANDOM_MODIFIER doesn't; BURST_X = whole
deck, `draws=-1`). See `docs/GROUPING_DESIGN.md` for the verified details.

- `tools/gen_structure_meta.py` extracts that per-card metadata (`type`, `draws`,
  multicast `group`, `trigger`/`payload`) from `gun_actions.lua` →
  `files/structure_meta.lua`.
- `files/wand_structure.lua` is the **pure deck simulator**:
  `simulate(tokens, meta, {spells_per_cast=N})` returns per-cast node trees with
  `wrapped`/`wrap` flags. No game APIs — this is the unit-testable core.
  `tools/test_wand_structure.py` is a **line-for-line Python mirror** with the
  tests (there is no Lua runtime on the dev machine) — keep it in sync when
  changing the Lua.
- `files/grouping_overlay.lua` reads the live wand's cards (sorted by inventory
  slot, always-cast cards separated via `permanently_attached`), its
  `gun_config` (spells/cast, shuffle), runs the simulation, and renders per-cast
  trees with wrap indicators.

## Data flow at runtime

```
init.lua
 └─ OnWorldPostUpdate  → grouping_overlay.update() each frame (pcall; first error
                          disables the overlay + GamePrints it)
                          reads active wand + gun_config → wand_structure.simulate
                          → draws panel + slot-bracket strips
```

Settings (`settings.lua`): `show_grouping` (default on), `show_slot_brackets`
(default off) — both RUNTIME scope, read via `ModSettingGet("testMod.<id>")`.

## Conventions

- Mod-added spells are deliberately untouched: the parser falls back to
  `type="OTHER"` (plain leaf) for ids missing from `structure_meta.lua`.
- Mod Lua reloads only when a run loads — after editing, quit to menu →
  Continue. In-game look verification happens via user screenshots; geometry
  calibration constants in `BOX` are derived from them (note the screenshot's
  pixel-to-GUI scale first).
- `docs/STATUS.md` (overall project state) and `docs/GROUPING_DESIGN.md` (grouping
  rationale + verified engine behavior) are the design record; keep STATUS.md current
  when feature state changes.
