# Spell Bracket Visualizer — project status

_A Noita wand-building aid. Last updated 2026-06-09 (casts + wrapping landed)._

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

## Decisions taken 2026-06-09

- **Panel is the primary feature; box overlay demoted.** `show_slot_brackets`
  now defaults to **false** (labelled experimental in the settings menu). The
  box overlay still works and gained: per-wand spells/cast simulation, wrap
  coloring (orange + "~wrap" label), and real `inventory_slot.x` mapping (fixes
  leading/interior empty slots — old next-step 3).
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
