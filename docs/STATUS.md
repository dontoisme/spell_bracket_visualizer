# Spell Bracket Visualizer — project status

_A Noita wand-building aid. Last updated 2026-06-09._

## What the mod is

A wand-readability mod with two features:

1. **Spell icon recolor** (shipped, on `main`) — every spell's icon gets a border
   colored by its **action type** (projectile, modifier, multicast, material, …),
   so you can read a wand at a glance. Works everywhere spells are drawn.
2. **Grouping brackets** (in progress, on branch `grouping-brackets`) — show a
   wand's **cast structure** (which modifiers feed which projectile, what a
   multicast gathers, what a trigger's payload is) as nested Lisp/SLIME-style
   brackets. The end goal: help build rapid-fire / complex wands by showing when
   a spell is being "wrapped".

## Where the code lives

- Repo: `…/Noita/mods/testMod` (git, branches `main` + `grouping-brackets`).
- `main`: icon recolor only — done and verified in-game.
- `grouping-brackets`: everything below; **not yet merged**.

## Feature 1 — icon recolor (DONE)

- `init.lua` appends `files/recolor_actions.lua` onto the game's
  `gun_actions.lua`; it repoints each vanilla spell's `sprite` to a pre-bordered
  copy under `files/icons/<style>/<id>.png`.
- `tools/gen_icons.py` generates those 490 icons from `data.wak` (pure-stdlib PNG
  codec — no Pillow). Two styles (corner brackets / full frame).
- Settings: **Colored Brackets** on/off, **Bracket Style** corners/frame.
- ✅ Verified in-game: borders render correctly, both settings work.

## Feature 2 — grouping brackets (IN PROGRESS)

### Solid foundation (verified)

- **Cast model** reverse-engineered from `gun.lua`: cards pop off one flat deck;
  multicasts (`DRAW_MANY`) gather the next N cards, trigger projectiles open a
  nested sub-shot of `payload` cards, modifiers prefix-attach. → a Lisp-style
  parse, statically derivable.
- `tools/gen_structure_meta.py` → `files/structure_meta.lua`: per-spell type,
  multicast group size, trigger payload count, localized name (422 actions).
- `files/wand_structure.lua`: pure deck→tree parser; records each node's
  `first`/`last` slot span. Validated against hand-traced wands (Python mirror).
- Runtime reads confirmed working: `GameIsInventoryOpen()`, active wand via
  `Inventory2Component.mActiveItem`, cards via `ItemActionComponent.action_id`
  ordered by `ItemComponent.inventory_slot`.

### Companion panel (WORKS in-game)

- `files/grouping_overlay.lua` → `draw_panel`: a "Wand structure" text tree with
  rainbow nesting spines, colored by type, localized names. Center-top placement.
- ✅ Confirmed accurate in-game (correctly parsed a real multicast+trigger wand).
- Robust and resolution-independent. This is the **reliable fallback**.

### Slot brackets — the hard part (EXPERIMENTAL, being calibrated)

Goal: draw the brackets directly on a wand's **own box** spell row (the build
surface), per the user.

**The wall:** the inventory is engine-rendered (ImGui). Lua can read *which wand
is held* but **not** which wand a box is showing, nor where any box/slot is
drawn. Verified against `Inventory2Component`, `InventoryGuiComponent`,
`ControlsComponent`, and the full Lua API — only the raw mouse position exists.

**Current approach** (`draw_box_brackets`): enumerate every carried wand
(`GameGetAllInventoryItems`, ordered by slot), read each one's cards, and draw
brackets under each box's spell row using a **hand-calibrated stacking model**
(`BOX` table = GUI-screen-fraction constants). Bracketing *every* box sidesteps
"which is selected".

**Known fragility (accepted):**
- Box heights aren't uniform — the **selected box renders taller** (~304px vs
  ~243px measured), and there's no API to detect which is selected → that box
  will misalign.
- Window **aspect ratio** changes the pixel↔GUI mapping between sessions.
- Calibrated to a specific 3-wand layout; drifts as wand count/heights differ.

**Calibration aids in place** (`DEBUG_RULER = true` in `grouping_overlay.lua`):
on-screen GUI-dimension readout + a 10% grid, so the screenshot-pixel ↔
GUI-coordinate mapping can be measured exactly. Remove before release.

## Expected next steps

1. **Calibrate the slot brackets** (next action): from one full-window screenshot
   showing the debug grid + GUI-dims readout, measure the true wand-box spell-row
   positions and tune the `BOX` constants in `grouping_overlay.lua`.
2. **Assess the stacking model honestly.** If the selected-box drift and
   per-wand height variance make it too unreliable, decide between:
   - investing in a height model driven by each wand's capacity (read at runtime), or
   - accepting box brackets only for the non-selected boxes, or
   - falling back to the companion panel as the primary feature.
3. **Turn off `DEBUG_RULER`** once calibrated.
4. **Edge cases:** always-cast cards (currently sorted in with the rest),
   mod-added spells (unknown → leaf, fine), shuffle wands (deck order randomizes
   at cast — panel shows static slot order; document it), `cast count` > 1.
5. **Polish:** connector glyphs / spacing on the panel; optional position setting.
6. **Merge to `main`** once the grouping feature is at a satisfying, stable state;
   update the top-level `README.md`.
7. **Resolution robustness:** confirm behavior at a couple of window sizes; if the
   fraction model is too shaky, switch slot geometry to absolute GUI units.

## Caveats for whoever picks this up

- No Lua runtime on the dev machine → Lua is checked with a structural balance
  script, not executed. Verify in-game.
- `data.wak` can't be unpacked via `noita.exe -wizard_unpak` from WSL; the tools
  read it directly (format: 16-byte header, then `(u32 offset, u32 size,
  u32 path_len, path)` entries).
- Generated assets (`files/icons/`, `files/structure_meta.lua`,
  `files/known_ids.lua`) are committed; regenerate with the `tools/` scripts
  after a game update.
