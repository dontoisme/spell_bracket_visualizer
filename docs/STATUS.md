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

### Slot brackets — the hard part (EXPERIMENTAL, calibrated 2026-06-09)

Goal: draw the brackets directly on a wand's **own box** spell row (the build
surface), per the user.

**The wall:** the inventory is engine-rendered (ImGui). Lua can read *which wand
is held* but **not** which wand a box is showing, nor where any box/slot is
drawn. Verified against `Inventory2Component`, `InventoryGuiComponent`,
`ControlsComponent`, and the full Lua API — only the raw mouse position exists.

**Approach** (`draw_box_brackets`): enumerate every carried wand
(`GameGetAllInventoryItems`, ordered by slot), read each one's cards, and draw
brackets under each box's spell row using a **hand-calibrated stacking model**
(`BOX` table = GUI-screen-fraction constants). Bracketing *every* box sidesteps
"which is selected".

**Calibration result** (from the debug-grid screenshot):
- GUI canvas is **640×360**; on that capture `pixel = 2.5 × GUI`.
- Measured wand-box spell rows at GUI y ≈ 94 / 157 / 234; the model predicts
  93 / 157 / 222 → **boxes 1 & 2 land dead-on.**
- Box 3 was the **selected** box: it renders ~12 GUI taller, so its row sits ~12
  lower than the uniform model and the bracket reads ~12 high. **No API exposes
  which box is selected, so this can't be corrected** — it's the irreducible
  error. The box you're actively editing is, annoyingly, the one most affected.
- Slot geometry corrected to the measured row: `slot0_x≈GUI 76`, `pitch≈20.5`.
- `DEBUG_RULER` now `false`.

**Net:** brackets align well on **non-selected** wand boxes; the **selected**
box reads slightly high. Also still subject to: variable wand counts/heights,
window aspect changes (GUI may not always be 640×360), and the assumption that
each wand's cards start at slot 0 (leading empty slots would shift it).

## Expected next steps

1. **Re-test the calibrated build** (next action): restart, open the inventory,
   confirm brackets sit on the non-selected wand-box rows and span the right
   slots. Expect the selected box to read ~12 GUI high (see above).
2. **Decision point — is the box overlay worth keeping?** Calibration confirmed
   it's fundamentally limited: the box you edit (selected) is exactly the one it
   can't align, and it breaks with different wand counts / window sizes. Options:
   - **Recommended:** make the **companion panel the primary feature** (it's
     accurate and robust) and keep box brackets as an off-by-default experimental
     extra. Consider defaulting `show_slot_brackets` to false.
   - Try a capacity-driven height model so the selected box's extra height is
     predicted from the wand's stats (partial fix; still can't detect selection).
   - Drop the box overlay entirely.
3. **Handle leading empty slots:** map brackets to each card's real
   `inventory_slot.x`, not the sequential token index (currently assumes cards
   start at slot 0).
4. **Edge cases:** always-cast cards (sorted in with the rest), mod-added spells
   (unknown → leaf, fine), shuffle wands (deck order randomizes at cast — panel
   shows static slot order; document it), `cast count` > 1.
5. **Polish:** connector glyphs / spacing on the panel; optional position setting.
6. **Merge to `main`** once the feature is satisfying and stable; update the
   top-level `README.md`.
7. **Resolution robustness:** GUI was 640×360 here, but it can differ; if the
   fraction model is shaky across window sizes, anchor slot geometry to absolute
   GUI units and re-measure.

## Caveats for whoever picks this up

- No Lua runtime on the dev machine → Lua is checked with a structural balance
  script, not executed. Verify in-game.
- `data.wak` can't be unpacked via `noita.exe -wizard_unpak` from WSL; the tools
  read it directly (format: 16-byte header, then `(u32 offset, u32 size,
  u32 path_len, path)` entries).
- Generated assets (`files/icons/`, `files/structure_meta.lua`,
  `files/known_ids.lua`) are committed; regenerate with the `tools/` scripts
  after a game update.
