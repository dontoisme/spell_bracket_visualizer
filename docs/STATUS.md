# Spell Bracket Visualizer — project status

_A Noita wand-building aid. Last updated 2026-06-12 (Workshop-ready: UX pass
done, debug stripped, mod id renamed; sprite-height read replaced by a
pregenerated table after it failed in-game — see Box geometry)._

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

- Repo: `…/Noita/mods/spell_bracket_visualizer` (git; folder + settings
  namespace renamed from `testMod` 2026-06-11, pre-Workshop — the user must
  re-enable the mod in Noita's mod menu once, and old `testMod.*` settings
  reset to defaults). Everything lives on **`main`**; the
  `grouping-brackets` branch was merged 2026-06-09 and deleted after the
  feature shipped. (The icon recolor was later retired; see below.)

## Feature 1 — icon recolor (RETIRED; history below)

- `init.lua` appends `files/recolor_actions.lua` onto the game's
  `gun_actions.lua`; it repoints each vanilla spell's `sprite` to a pre-bordered
  copy under `files/icons/<style>/<id>.png`.
- `tools/gen_icons.py` generates those 490 icons from `data.wak` (pure-stdlib PNG
  codec — no Pillow). Two styles (corner brackets / full frame).
- Settings: **Colored Brackets** on/off, **Bracket Style** corners/frame.
- ✅ Verified in-game: borders render correctly, both settings work.

## Feature 2 — grouping brackets (✅ SHIPPED, user-approved 2026-06-09)

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
  `wrapped`/`wrap` flags, slot spans (`first`/`last`/`head`), and the
  wrapped-in span (`wfirst`/`wlast` = cards drawn after the wrap, tagged at
  draw time). `build()` kept as the one-cast wrapper.
- `tools/test_wand_structure.py`: Python mirror + 14 hand-traced tests
  (cast splits, trigger/modifier/multicast wraps, slot-order restore,
  head/modifier-prefix spans, wrapped spans). All pass. **Keep the mirror in
  sync when editing wand_structure.lua.**
- Runtime reads confirmed working in-game: `GameIsInventoryOpen()`, active
  wand via `Inventory2Component.mActiveItem`, cards via
  `ItemActionComponent.action_id` ordered by `ItemComponent.inventory_slot`,
  `AbilityComponent.gun_config` → `actions_per_round` /
  `shuffle_deck_when_empty` via `ComponentObjectGetValue2`,
  `SpriteComponent.image_file` + `GuiGetImageDimensions` (box geometry),
  and — last one closed 2026-06-11 — `ItemComponent.permanently_attached`
  (always-cast detection: an "always: Bounce" wand showed the always line
  and correctly excluded Bounce from the cast tree; 11 bombs split 3/3/3/2
  at 3/cast). Every runtime read is now verified in-game.

### Companion panel (✅ VERIFIED in-game, casts + wrapping included)

- `files/grouping_overlay.lua` → `draw_panel`: a "Wand structure" text tree with
  rainbow nesting spines, colored by type, localized names.
- **UX rework 2026-06-11 (✅ dock verified in-game, user screenshots)** —
  pre-Workshop review found the old center-top placement collided with wide
  wand boxes (a capacity-26 box spans GUI x ≈ 21–571) and had no height limit
  (a 26×1/cast wand → ~53 rows ≈ 591 GUI on a 360 screen). Now:
  - The panel **docks beside the selected wand's box** (in the free column
    right of the boxes, top-aligned with the held wand's own box top; the
    "per-tail candidates" bullet below is the final placement algorithm).
    Selection-anchored, NOT hover-anchored, by user decision:
    the panel must stay put while rearranging spells so the cast order can be
    watched live. Falls back to centered **below the stack** when the boxes
    leave no room beside them (`RIGHT_KEEPOUT` guards the right HUD).
  - **Slides up when the selected wand sits low** (user catch on the bottom
    wand: top-aligning there folded most of the tree into "+7 more"):
    docked panels bottom-anchor against the screen edge and grow upward,
    floored at the stack top (the column right of the boxes is free).
    v2 fix (same day, in-game catch): the slide target and the row clamp now
    share one budget — the first slide aimed 2 GUI past the clamp, so every
    slid panel folded its last rows into "+2 more". Also DOCK_GAP 6→14
    (panel background was kissing the box borders) and BOTTOM_MARGIN 12.
    A Spell-Lab-style scroll bar was considered and rejected: the gui is
    deliberately NonInteractive (the fire-block fix, 7d9e3ac), and a scroll
    container would recapture the mouse.
  - **Height-clamped to the screen**: overflow rows fold into "... +N more"
    (after the slide, this only triggers on trees taller than the screen,
    or in the below-stack fallback which must not slide up over the boxes).
  - Geometry comes from `collect_wand_boxes` — the box-measuring pass split
    out of `draw_box_brackets`, shared by brackets and panel (also kills the
    duplicate per-frame simulate of the active wand).
  - **Box width has a header-driven MINIMUM** (in-game catch on the starting
    wands: the dock landed inside their boxes): right edge ≥ 164.5 GUI
    (`BOX.min_right`, pixel-measured) regardless of slots; width =
    max(header min, slot row). Caps ≤7 are header-bound, 8+ slot-bound.
  - **Per-tail dock candidates** (in-game catch: a 17-slot wand mid-stack
    pushed a wide panel into the below-stack fallback as a 2-row stub even
    though the space right of the narrow bottom box was free): a panel
    whose top is at box j's top can only intersect bands of boxes j..n, so
    each j is tried in order (top-aligned with the selected box when
    j ≤ sel), first-full-fit wins, best-partial otherwise, below-stack
    only if it beats them all. Verified by a Python dry-run mirror of the
    placement math against all prior screenshot layouts.
  - Panel text palette brightened (the old icon-border colors — dark red
    PROJECTILE etc. — were barely legible as 1px text on the dark panel).
- Shows: title with spells/cast, an "always:" line for always-cast cards,
  per-cast headers when the wand has multiple casts, and a loud orange
  "cast N -- WRAPS! -> recharge" banner with "~" markers on the wrapped-in
  cards. (The old shuffle "order varies!" title warning is gone — shuffle
  wands now show nothing at all; see Decisions.) This is the **primary
  feature**.
- ✅ Verified in-game 2026-06-09 (screenshot): a shuffle 1/cast wand with deck
  `[Light, Bomb, Double scatter, Spark bolt]` rendered exactly the engine
  behavior — cast 1 `[Light] Bomb`; cast 2 `Double scatter x2` gathering
  `Spark bolt` + a forced draw that **wrapped** in `~ [Light] Bomb`, with the
  orange banner. Title showed `(1/cast, shuffle: order varies!)`, confirming
  the `gun_config` reads. Slot brackets also drew the wrap span in orange and
  sat correctly on a wand with a leading empty slot (the `inventory_slot.x`
  fix). The "always:" line — the last unobserved piece — was verified
  2026-06-11 on an "always: Bounce" wand (line rendered, Bounce excluded
  from the tree, 3/cast splits correct).

### Slot brackets — final form (shipped, user-approved 2026-06-09)

Iterated v1→final against in-game screenshots + user mockups. Final design:

- **[ ] glyphs** (1-GUI bar + 3-GUI hooks pointing into the group), card-frame
  height, SLIME **rainbow by nesting depth** (`RAINBOW`/`nest_color`) — groups
  ALWAYS keep their rainbow color. ALL text labels REMOVED 2026-06-11
  (user calls: first the multicast `xN` — the card art already says x2/x3
  and labels collided, e.g. "trig 1x3" — then `trig N` too; the panel's
  `xN` and `(trig N)` suffixes went with them). Only the orange `wraps to front` tag
  remains. Same day: ALL bracket glyphs (opens, closes, the orange wrap
  pair) raised by `BRACKET_RAISE = 2` GUI so the top hooks overlap the card
  frame's top edge (user-tuned from screenshots; opens first, closes
  matched after the next screenshot).
- **"Post-wrap dead cards" is a NON-feature (analyzed 2026-06-11).** The UX
  review claimed cards after a wrapping cast "never fire" and deserve a
  marker. Wrong: a wrap only triggers on a forced draw with an EMPTY deck,
  so by wrap time every card has already fired this cycle; cards left in
  the deck after a wrapping cast are returned discard — they fired in
  earlier casts. Nothing to mark; the orange wrap segment + `~` already
  shows the cards that fire twice. Do not re-add.
- **Orange = the wrap, exclusively.** The innermost group a wrap happened in
  (deepest node with a wrapped span; ancestors inherit `wfirst` but don't
  redraw) gets, in `WRAP_COLOR`: a `wraps to front` tag (renamed from `~wrap` 2026-06-11: the font renders ~ as a quote), `[ ]` around the
  wrapped-in segment at the wand's start, and a **carriage-return line** that
  drops below the forward close, runs left under the row, and rises into the
  wrapped segment — "the draw continues here".
- Open `[` sits 1 GUI left of the group's own card (`OPEN_NUDGE`), over the
  slot's left edge. **Leading modifiers sit outside the parens** (span starts
  at `node.head`, not `node.first`), matching the panel's `[mods] name` text.
- Closes stack on the END card: two-pass render (`collect_delims` counts per
  column first), INNERMOST `]` ON the card's right edge, outer ones step
  1.5 GUI RIGHT into the slot gap, outermost TALLEST (hooks wrap the inner
  ones) — reads inner→outer left-to-right. Flipped 2026-06-11 (user call):
  they used to step LEFT over the card art; closes must start at the end of
  the slot, not push into it.
- Drawn at **z = -10**: in front of the engine's spell-frame layer ("lower z
  = front"; z 1 lost to the frames).
- On by default (`show_slot_brackets`, RUNTIME scope).

### Box geometry — DIAGONAL-BBOX model replaces the height law (2026-06-12)

Found while staging the Workshop preview screenshot: a grown box (the
purple wand) drew its brackets 13px (4.2 GUI) too high. THREE theories
died before the on-screen probe (`DEBUG_SPRITE_READ`, temporary — REMOVE
before upload) produced ground truth; the trap was that every art at or
below the floor threshold renders pixel-IDENTICALLY, so wrong hypotheses
kept "fitting":

1. "GuiGetImageDimensions silently fails → 9px fallback" — WRONG (but
   numerically consistent: any s ≤ 11.25 gives the floor layout).
2. "13px-tall art, table fixes it" — WRONG; the probe showed the wand is
   `wand_0430.png`, art **14×9 px**: only 9 TALL, box grown anyway.
3. The real law: the header draws the wand **rotated 45°** (at 1.5
   GUI/px — the art bbox in the user's 2560×1440 crop measured
   24×24.75 GUI = 1.5·0.7071·(14+9) exactly). The box grows with the
   art's **diagonal D = 0.7071·(w+h)** GUI, NOT its height. v8's "2u per
   px of art height" keyed on the wrong variable and the floor absorbed
   it for every wand ever tested (v9 probe boxes: all floor).

Second, independent bug, same screenshots: in a grown box the slot row is
NOT bottom-anchored (`row_off`); the engine drops the row only ~half of
the slope it grows the box by. Both laws, fitted to the measured stack
(floor wands handgun D=12.73 + bomb wand D=14.14, grown wand_0430
D=16.26; engine-exact to ≤1px on all three row tops at 2000×1125):

- box_h(u)  = min_h + 1.59·max(0, D − 14.5)   (`diag_box_slope`)
- row_top(u)= box_top + (min_h − row_off − slot_h) + 0.82·max(0, D − 14.5)
  (`diag_row_slope`; floor boxes bit-identical to the old math)

`tools/gen_wand_sprite_meta.py` → `files/wand_sprite_meta.lua` pregenerates
`image_file path → w+h` for all 1371 data/items_gfx images (pngs by pixel
dims; sprite XMLs — the starting wands use handgun.xml — by default-anim
frame_width+frame_height). `wand_art_wh` consults the table, then the live
GuiGetImageDimensions read (modded wands), then AbilityComponent
sprite_file, then 18 (handgun-sized). ⚠ The threshold 14.5 and both slopes
ride on ONE grown sample — exact for it, interpolated elsewhere;
recalibrate from a screenshot when a bigger wand (D ≫ 16) drifts.

✅ CONFIRMED in-game (probe screenshot, same day): all three wands
meta-hit, brackets landed at the designed offset to the pixel. Probe
removed (21d616d). Two follow-ups from the confirmation frame:

- **Selection moves NOTHING** — truly nothing: the selected box draws
  its decorative border inflated a few px outward; rows and content stay
  put. (This also explains how v9 concluded selection contributes
  nothing while v2-v5 kept "seeing" a taller selected box.)
- **BRACKET_RAISE 2 → 0** (user call): the 2-GUI lift tuned 2026-06-11
  was compensating the then-broken geometry; with rows engine-exact the
  user wants the glyphs flush on the card frames.

### Box geometry — PROBE-CALIBRATED final values (v9, 2026-06-09)

Supersedes the v8 numbers below. After the calibration HUD gained click
probes and plumb lines (middle-click = point, right-click = vertical line,
shift+right-click = horizontal line), every constant was measured in-game
rather than estimated from screenshots:

- **Horizontal** (8 vertical plumbs, columns 0–25, fit ±0.15 GUI): the slot
  grid is laid out in **GUI units** — pitch exactly **20.0 GUI**, col-0 frame
  left edge **26.0 GUI**, visible frame **17.5 GUI wide**. (The 65px → 64px
  "art-pixel cell" theories and the "wide boxes compress" hypothesis all
  died here; one pitch fits a capacity-26 box end to end.)
- **Vertical** (corner probes + 8 horizontal plumbs, fit ±0.7 GUI): row tops
  at **83.0 + 61.6·(box−1) GUI** for floor-height boxes; frames are
  **SQUARE, 17.5×17.5 GUI**. In code (5px units): min_h=36.5, gap=2,
  row_off=3.7, slot_h=10.94; sprite term unchanged (only tall art grows it).
- **Mouse**: `InputGetMousePosOnScreen` returns 1280×720 virtual-screen
  coords = exactly **2× GUI**.

### Box geometry — v8 history (superseded)

In engine-UI units (1u = 0.0025·GUI width = 5 screen px at 2000×1125; slots
are 13u pitch / 12u frames, first slot center 22.4u):

- Boxes stack from `top0 = 30u`; box height = `max(37u, 14u + 2u·sprite_px)`
  — a 37u FLOOR that most wands hit (art ≤ 11px), only tall art (13/15/17px)
  grows the box. Sprite height read at runtime (`SpriteComponent.image_file`
  → `GuiGetImageDimensions`, pcall, fallback 9 — the floor absorbs read error
  for small wands). 2u gap between boxes; slot-row bottom `row_off = 3u`
  above the box bottom (user-tuned in-game; screenshots said 2).
- **Selection contributes NOTHING.** Two earlier theories died here: v2-v5's
  "selected box is taller" and v6/v7's pure sprite scaling — the tall purple
  wand's sprite was behind both. Symptoms of the wrong models: brackets
  jumped when selecting another wand or a potion, drifted when a new wand was
  picked up. Vanilla wand art is 3..17px tall (verified across all 1016 pngs
  in data.wak), which pinned the 2u-per-px slope and the floor.
- **Calibration Overlay (debug)** mod setting: draws computed row lines + raw
  per-wand sprite reads; any future drift is one screenshot from an exact
  recalibration.

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
- **Shuffle wands show NOTHING** — no brackets and no panel (user calls,
  both 2026-06-11; the panel briefly survived with an "order varies!"
  title warning, then went too): the deck order randomizes at cast time,
  so any displayed structure is one arrangement of many. The
  `cfg.shuffle` read still gates both renderers.
- `cast count > 1` (spells/cast) is now fully modeled — that *is* the cast
  grouping feature.

## Workshop release state (2026-06-11)

Code-side everything is DONE — debug tooling stripped (in git history),
mod id renamed pre-upload, manifest hardened, preview image in place,
every runtime read verified in-game. The remaining steps are manual:

1. **Retake `workshop_preview_image.png`** from the final build (the current
   one is cropped from a pre-label-removal screenshot; must stay 16:9 —
   official requirement). The crop tooling: reuse `tools/gen_icons.py`'s
   PNG codec, as done for v1.
2. **Upload** (Windows, Steam running): `workshop_upload.bat` in the Noita
   install folder (or `noita_dev.exe -workshop_upload`), type
   `spell_bracket_visualizer` at the prompt. The first upload starts
   HIDDEN until the Steam Workshop Legal Agreement is accepted on Steam;
   then flip the item's visibility. Updates later:
   `noita_dev.exe -workshop_upload MOD_NAME -workshop_upload_change_notes "..."`.
3. **Commit the generated `workshop_id.txt`** — it pins future uploads to
   the same Workshop item. (Delete it only to re-create the item; "Steam -
   workshop upload failed: 2" usually means a stale id.)

Upload mechanics (verified from `READ_ME_FIRST.txt` + `noita_dev.exe`
strings): only `.txt/.csv/.bmp/.xml/.png/.lua/.frag/.vert/.bank/.bin/.plz`
files upload; `.git` is skipped automatically; workshop.xml additionally
excludes `tools|docs|.claude` and `.gitignore|CLAUDE.md`. The uploader
auto-generates `mod_id.txt` from the FOLDER NAME — which is why the
pre-upload rename mattered: the folder name is the permanent public mod id
that `mods/<id>/` paths resolve against on subscribers' machines.

Old next-steps, all resolved 2026-06-11:

- Always-cast line + multi-`spells/cast` per-cast headers: both verified
  in-game (the "always: Bounce" bomb wand rendered 4 cast headers at
  3/cast).
- "Dim spells that never fire after a wrap": disproven — a NON-feature
  (see the slot-brackets section); do not re-add.
- **Resolution robustness** remains the one open caveat: geometry is
  calibrated at 2000×1125 (GUI 640×360); constants are GUI-width fractions
  so other sizes should scale. If brackets drift on another setup, recover
  the calibration HUD from git history (removed for release:
  `draw_calibration_hud` + the `debug_boxes` setting) and screenshot.

## Caveats for whoever picks this up

- No Lua runtime on the dev machine → Lua is checked with a structural balance
  script, not executed. Mod Lua reloads only on run load (quit → Continue).
  Verify in-game; the user's screenshots are the verification channel.
- `data.wak` can't be unpacked via `noita.exe -wizard_unpak` from WSL; the tools
  read it directly (format: 16-byte header, then `(u32 offset, u32 size,
  u32 path_len, path)` entries).
- `files/structure_meta.lua` is committed and generated; re-run
  `tools/gen_structure_meta.py` after a game update.
- When editing `files/wand_structure.lua`, keep the Python mirror in
  `tools/test_wand_structure.py` in sync and run it.
