# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A [Noita](https://noitagame.com/) mod ("Spell Bracket Visualizer") that makes wands
easier to read. Two features:

1. **Icon recolor** (shipped, lives on `main`): every vanilla spell's icon gets a
   border colored by its **action type** (projectile / modifier / multicast /
   material / …).
2. **Grouping brackets** (in progress, branch `grouping-brackets`): a companion
   panel + experimental in-UI brackets showing a wand's **cast structure** — which
   modifiers feed which projectile, what a multicast gathers, a trigger's payload.

The mod directory IS the install location (`…/Noita/mods/testMod`), so edits here
are live in the game on next run.

## Commands

There is no build/lint/test for the Lua mod — it loads directly. The Python tools
regenerate committed data files from the game's `data.wak`:

```bash
python3 tools/gen_icons.py            # regenerate files/icons/{corners,frame}/*.png + files/known_ids.lua
python3 tools/gen_structure_meta.py   # regenerate files/structure_meta.lua
python3 tools/test_wand_structure.py  # run the parser/simulator tests (Python mirror)
```

Both are pure stdlib (no Pillow/deps). They locate `data.wak` at `../../data/data.wak`
relative to the mod; override with `$NOITA_WAK` or argv[1] if the install differs.
Re-run after a Noita update or when changing colors/border style. The generated
outputs (`files/icons/`, `files/known_ids.lua`, `files/structure_meta.lua`) are
committed — don't hand-edit them; change the generator and re-run.

Testing is manual, in-game (the GUI game can't be launched headlessly from WSL):
enable the mod in Noita's mod menu, start/restart a run, open a wand or shop.

## Architecture — the key constraint

**Noita renders the spell inventory in the engine, not Lua.** There is no Lua draw
hook to paint over the spell-slot UI. Two consequences shape the whole design:

- **Recoloring** can't overlay borders, so it instead **swaps each spell's icon**
  for a pre-bordered copy. `init.lua`'s `OnModInit` uses `ModLuaFileAppend` to
  append `files/recolor_actions.lua` onto the game's `data/scripts/gun/gun_actions.lua`.
  That file is `dofile`d at the end of `gun_actions.lua`, so the vanilla `actions`
  table is **in scope** — the recolor pass repoints each known spell's `action.sprite`
  to `files/icons/<style>/<id>.png`. Because it runs inside the engine's spell-loading
  file, an error there breaks spell loading, so `recolor_actions.lua` is wrapped in
  `pcall` and fails open (vanilla icons stay).

- **Grouping brackets** can't read engine slot positions either. The companion panel
  (`files/grouping_overlay.lua`, driven every frame from `OnWorldPostUpdate`) draws
  with its own `GuiCreate()` at coordinates it fully controls. The experimental
  in-UI "slot brackets" (`draw_box_brackets`/`BOX` table) are a **hand-calibrated
  guess** at where the engine draws wand boxes (GUI-fraction constants tuned for
  640×360); they drift across resolutions and can't detect which box is selected.
  Treat that geometry as best-effort, not reliable.

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
 ├─ OnModInit          → append recolor_actions.lua onto gun_actions.lua (icon swap)
 └─ OnWorldPostUpdate  → grouping_overlay.update() each frame
                          reads active wand → wand_structure.build → draws panel + brackets
```

Settings (`settings.lua`): `show_colors`, `bracket_style` (NEW_GAME scope — apply at
run start), `show_grouping`, `show_slot_brackets` (RUNTIME scope). `recolor_actions.lua`
and `grouping_overlay.lua` read them via `ModSettingGet("testMod.<id>")`, defaulting
on if the API isn't reachable.

## Conventions

- The action-type → color palette is duplicated in two places that must stay in
  sync: `TYPE_COLOR` (0–255 RGB) in `tools/gen_icons.py` and `COLOR` (0–1 RGB) in
  `files/grouping_overlay.lua`. Update both together.
- Other mods' spells are deliberately left untouched: recolor only acts on ids in
  `files/known_ids.lua`; the parser falls back to `type="OTHER"` for unknown ids.
- `docs/STATUS.md` (overall project state) and `docs/GROUPING_DESIGN.md` (grouping
  rationale + verified engine behavior) are the design record; keep STATUS.md current
  when feature state changes.
