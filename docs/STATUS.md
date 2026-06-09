# Spell Bracket Visualizer — project status

_A Noita wand-building aid. Last updated 2026-06-09 (casts + wrapping landed)._

## What the mod is

A wand-readability mod with two features:

1. **Spell icon recolor** (RETIRED 2026-06-09) — every spell's icon got a border
   colored by its action type. Removed at the user's request once the rainbow
   brackets landed: the borders became redundant visual noise next to them.
   Code/assets live in git history (`recolor_actions.lua`, `known_ids.lua`,
   `files/icons/`, the `OnModInit` hook); `tools/gen_icons.py` remains.
2. **Grouping brackets** (✅ shipped, merged to `main` 2026-06-09) — shows a
   wand's **cast structure** (which modifiers feed which projectile, what a
   multicast gathers, what a trigger's payload is) as nested Lisp/SLIME-style
   brackets, grouped per cast (simultaneity), with rapid-fire **wrap**
   detection ("WRAPS! -> recharge" banner + "~" on wrapped-in cards).

## Where the code lives

- Repo: `…/Noita/mods/testMod` (git). Branch `grouping-brackets` was **merged
  to `main` 2026-06-09** after in-game verification — `main` now has both
  features (icon recolor + grouping panel).

## Feature 1 — icon recolor (RETIRED; history below)

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
- **Casts + wrapping** (added 2026-06-09, verified line-by-line from `gun.lua`;
  see `GROUPING_DESIGN.md`): a cast draws `actions_per_round` root expressions
  (root draws never wrap); every *card-forced* draw (`draw_actions(N, true)`,
  trigger payloads) **wraps** on an empty deck — the discard returns in slot
  order and drawing continues from the wand's start, and the cycle then ends
  (recharge). Chaining is decided by the card's `draws` count, not its type
  (ALPHA/I_SHOT chain; RANDOM_MODIFIER doesn't; BURST_X takes the whole deck).
- `tools/gen_structure_meta.py` → `files/structure_meta.lua`: per-spell type,
  **`draws` count**, multicast group size, trigger payload count, localized
  name (422 actions).
- `files/wand_structure.lua`: pure **deck simulator** —
  `simulate(tokens, meta, {spells_per_cast=N})` → per-cast trees with
  `wrapped`/`wrap` flags and slot spans. `build()` kept as the one-cast wrapper.
- `tools/test_wand_structure.py`: Python mirror + 12 hand-traced tests
  (cast splits, trigger/modifier/multicast wraps, slot-order restore, …). All
  pass. **Keep the mirror in sync when editing wand_structure.lua.**
- Runtime reads confirmed working: `GameIsInventoryOpen()`, active wand via
  `Inventory2Component.mActiveItem`, cards via `ItemActionComponent.action_id`
  ordered by `ItemComponent.inventory_slot`. New reads (need in-game check):
  `AbilityComponent.gun_config` → `actions_per_round` / `shuffle_deck_when_empty`
  via `ComponentObjectGetValue2`, `ItemComponent.permanently_attached`
  (always-cast detection).

### Companion panel (✅ VERIFIED in-game, casts + wrapping included)

- `files/grouping_overlay.lua` → `draw_panel`: a "Wand structure" text tree with
  rainbow nesting spines, colored by type, localized names. Center-top placement.
- Shows: title with spells/cast + shuffle warning, an "always:" line for
  always-cast cards, per-cast headers when the wand has multiple casts, and a
  loud orange "cast N -- WRAPS! -> recharge" banner with "~" markers on the
  wrapped-in cards. This is the **primary feature**.
- ✅ Verified in-game 2026-06-09 (screenshot): a shuffle 1/cast wand with deck
  `[Light, Bomb, Double scatter, Spark bolt]` rendered exactly the engine
  behavior — cast 1 `[Light] Bomb`; cast 2 `Double scatter x2` gathering
  `Spark bolt` + a forced draw that **wrapped** in `~ [Light] Bomb`, with the
  orange banner. Title showed `(1/cast, shuffle: order varies!)`, confirming
  the `gun_config` reads. Slot brackets also drew the wrap span in orange and
  sat correctly on a wand with a leading empty slot (the `inventory_slot.x`
  fix). Not yet observed in-game: the "always:" line (no always-cast wand on
  hand; the read is pcall-guarded and fails soft).

### Slot brackets — final form (v5, user-approved 2026-06-09)

Iterated v2→v5 against in-game screenshots + a user mockup. Final design:

- **[ ] glyphs** (1-GUI bar + 3-GUI hooks pointing into the group), card-frame
  height, SLIME **rainbow by nesting depth** (`RAINBOW`/`nest_color`); wrap
  groups override to orange. Label (`x2`/`trig N`) above the opening bracket.
- Open `[` sits 1 GUI left of the group's own card (`OPEN_NUDGE`), over the
  slot's left edge. **Leading modifiers sit outside the parens** (span starts
  at `node.head`, not `node.first`), matching the panel's `[mods] name` text.
- Closes stack on the END card: two-pass render (`collect_delims` counts per
  column first), outermost `]` ON the card's right edge (`CLOSE_NUDGE`) and
  TALLEST (hooks wrap the inner ones), inner ones step 1.5 GUI left over the
  card art — reads inner→outer left-to-right, contained within the card.
- Drawn at **z = -10**: in front of the engine's spell-frame layer ("lower z
  = front"; z 1 lost to the frames).
- User: "This look super good."

### Slot brackets v2 history — paren-style delimiters (superseded)

User feedback on v1: long underline brackets misaligned (sat ~2 slots right and
above the row) and ugly when a group's cards have empty slots between them.
v2 changes:

- **Delimiters, not underlines.** Each group draws Lisp-style `[` `]` bars
  (slot height, ticks pointing inward) hugging its first/last card, label above
  the opening bar. No line spans the gap between non-contiguous cards.
- **Recalibrated** from an in-game screenshot (2000×1125 px, GUI 640×360):
  slot-row bottoms 0.295 / 0.465 / 0.686 of height → `bottom0=0.295`,
  `step=0.170`; first slot center `0.056` of width, `pitch=0.0325`. The old
  `slot0_x=0.119` was simply wrong (~2 slots right).
- **Selected-box offset SOLVED.** The earlier "no selection API" claim was
  wrong: the taller (selected) box is the held wand's box, and the held wand
  IS `Inventory2Component.mActiveItem`. The selected box and every box below
  it get `sel_extra=0.051` of height added.
- Nested delimiters at the same column nudge outward (`NEST_GAP`); a parent's
  `]` is placed after its children's so it lands outside.

### Slot brackets v1 history (superseded)

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

## Decisions taken 2026-06-09

- **Panel is the primary feature; box overlay demoted.** `show_slot_brackets`
  now defaults to **false** (labelled experimental in the settings menu). The
  box overlay still works and gained: per-wand spells/cast simulation, wrap
  coloring (orange + "~wrap" label), and real `inventory_slot.x` mapping (fixes
  leading/interior empty slots — old next-step 3).
  *(Reversed after the v5 iteration the same day: brackets user-approved →
  default **true**, "experimental" label dropped.)*
- **Always-cast cards** are read via `permanently_attached` and excluded from
  the deck sim (they also no longer corrupt slot mapping) — old next-step 4.
- **Shuffle wands** are flagged in the panel title ("order varies!") — the
  slot-order sim is one possible outcome.
- `cast count > 1` (spells/cast) is now fully modeled — that *is* the cast
  grouping feature.

## Expected next steps

1. ~~Verify in-game~~ ✅ done 2026-06-09 (see panel section above). Casts,
   wrap banner, shuffle warning, gun_config reads and slot-x mapping all
   confirmed against a real wrap wand. Outstanding small checks: the
   "always:" line (need an always-cast wand) and a multi-`spells/cast` wand's
   per-cast headers (only 1/cast wands were on hand).
2. **Merge to `main`** + update the top-level `README.md` (its "no grouping"
   limitation no longer holds).
3. **Polish (later):** connector glyphs / spacing on the panel; optional
   position setting; maybe dim spells that never fire this cycle (after a
   wrap).
4. **Resolution robustness** (only if box overlay graduates): GUI was 640×360
   here, but it can differ; anchor slot geometry to absolute GUI units and
   re-measure if the fraction model is shaky across window sizes.

## Caveats for whoever picks this up

- No Lua runtime on the dev machine → Lua is checked with a structural balance
  script, not executed. Verify in-game.
- `data.wak` can't be unpacked via `noita.exe -wizard_unpak` from WSL; the tools
  read it directly (format: 16-byte header, then `(u32 offset, u32 size,
  u32 path_len, path)` entries).
- Generated assets (`files/icons/`, `files/structure_meta.lua`,
  `files/known_ids.lua`) are committed; regenerate with the `tools/` scripts
  after a game update.
