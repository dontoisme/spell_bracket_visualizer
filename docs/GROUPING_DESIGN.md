# Grouping brackets (Lisp/SLIME-style) — design

**Goal:** show a wand's *cast structure* — which modifiers feed which projectile,
which cards a multicast gathers, and what a trigger's payload is — as nested
brackets, the way SLIME shows Lisp expression structure.

Status: **shipped on `main` 2026-06-09** (the `grouping-brackets` branch was
merged and deleted) — companion panel with cast grouping + wrap detection,
plus the in-UI rainbow slot brackets with the orange wrap carriage-return
line. Both on by default. See `STATUS.md` for the full iteration history.

## How Noita actually builds a shot (verified from data.wak)

`data/scripts/gun/gun.lua` resolves a shot by popping cards off **one flat deck**
in order (`draw_action` → `deck[1]`). Structure comes from three mechanisms:

| Mechanism | Engine call | Structural meaning |
| --------- | ----------- | ------------------ |
| **Multicast** (`DRAW_MANY`, e.g. BURST_2, CIRCLE_SHAPE) | `draw_actions(N)` | the next **N** drawn cards join this shot as a group |
| **Trigger / timer** projectile (e.g. SPARK_BOLT_TRIGGER, DELAYED_SPELL) | `add_projectile_trigger_*(entity, [delay,] count)` → `draw_shot(create_shot(count))` | opens a **nested sub-shot** of `count` cards as the payload |
| **Modifier** (`ACTION_TYPE_MODIFIER`) | mutates shot state `c.*` | prefix-attaches to the projectile it precedes |

Because draws are sequential from one stream, a wand's deck parses like a Lisp
token stream: multicast/trigger counts introduce sub-expressions. This is fully
derivable **statically** from each card's metadata — no need to run the engine.

## Casts and wand wrapping (verified from gun.lua, 2026-06-09)

The two facts the user actually builds wands around — *what fires together* and
*when the wand wraps* — fall out of `draw_action(instant_reload_if_empty)`:

- **A cast** (`_start_shot` → `_draw_actions_for_shot`) draws
  `gun.actions_per_round` (the wand's *spells/cast*) root expressions, passing
  `instant_reload_if_empty = false`: if the deck is empty on a root draw, the
  cast simply ends (and the cycle reloads). **Root draws never wrap.**
- **Every card-forced draw passes `true`**: all 203 `draw_actions(N, ...)` calls
  in `gun_actions.lua` pass `true`, and trigger payloads use
  `draw_shot(create_shot(N), true)`. On a forced draw with an empty deck the
  engine calls `move_discarded_to_deck()` + `order_deck()` — **the WRAP**: cards
  cast earlier this recharge cycle come back (sorted by `deck_index`, i.e. slot
  order, for non-shuffle wands; shuffled otherwise) and drawing continues from
  the wand's start. It also sets `start_reload`, so the recharge cycle ends
  after the wrapping cast — cards after that point never fire that cycle.
- **Chaining is decided by the card's body, not its type.** A card that calls
  `draw_actions(1, true)` consumes itself and pulls the next card — that is what
  "modifier" means structurally. 142/143 MODIFIERs and all 5 PASSIVEs do this,
  but so do 13 OTHERs (ALPHA, GAMMA, DUPLICATE, …) and 11 UTILITYs (I_SHOT, …).
  `RANDOM_MODIFIER` draws nothing → terminates a chain. `BURST_X` draws `#deck`
  (the whole remaining deck) → recorded as `draws = -1`.

`structure_meta.lua` therefore carries a `draws` field per card, and
`wand_structure.lua` is a **deck simulator**, not just a parser:
`M.simulate(tokens, meta, { spells_per_cast = N })` returns
`{ casts = { { nodes, wrapped }, ... }, wrapped }`, with `wrap = true` on every
node parsed across a wrap (the wrapping group *and* the wrapped-in cards),
`first`/`last` spans that reach back to the wand's start when wrapped,
`head` = the node's own card (the span excluding its leading-modifier prefix —
Lisp-wise modifiers sit outside the parens), and `wfirst`/`wlast` = the span
of cards drawn *after* the wrap (tagged at draw time), which renderers use to
show forward-segment + carriage-return + wrapped-segment.
Validated by `tools/test_wand_structure.py` — a line-for-line Python mirror
(no Lua runtime on the dev machine) with hand-traced wands: cast splitting,
the classic trigger-at-deck-end wrap, trailing-modifier wrap, under-filled
multicast wrap, slot-order restore on wrap, BURST_X, RANDOM_MODIFIER.

**Always-cast cards** (`permanently_attached`) never sit in the deck — the
engine plays them at the start of every cast — so the overlay reads them
separately and excludes them from the simulation (they used to corrupt the
slot mapping).

## Foundation (landed on this branch)

- **`tools/gen_structure_meta.py`** — parses `gun_actions.lua` out of `data.wak`
  and emits per-card metadata: `type`, `group` (multicast draw count),
  `trigger`/`payload` (nested sub-shot). Pure stdlib.
- **`files/structure_meta.lua`** — generated table, 422 actions
  (13 multicast, 28 trigger).
- **`files/wand_structure.lua`** — `M.build(tokens, meta)`: the pure
  deck→tree parser (recursive descent matching the rules above). No game APIs,
  so it is unit-testable. Validated against hand-traced wands (nested multicasts,
  trigger payloads, modifier attachment, dangling modifiers, under-filled
  multicasts) — see commit message / `tools` validation.

Example — deck `[DAMAGE, BURST_2, LIGHT_BULLET, LIGHT_BULLET_TRIGGER, MAGIC_BOLT]`:

```
[DAMAGE] (BURST_2 x2
  LIGHT_BULLET
  (LIGHT_BULLET_TRIGGER ->payload1
    MAGIC_BOLT))
```

## Runtime data (verified available)

- **Detect inventory open:** `GameIsInventoryOpen() -> bool`.
- **Read the wand's cards in order:** held wand entity →
  `EntityGetAllChildren(wand)`; each card child has an `ItemActionComponent`
  (`action_id`) and an `ItemComponent` (`inventory_slot` → order). Read with
  `ComponentGetValue2`. Active wand via the player's inventory
  (`GameGetAllInventoryItems(player)` + the selected quick-slot).

So both inputs the renderer needs — *is the inventory open* and *the ordered
card list* — are readily available from Lua.

## Open decision: rendering

The wand spell **inventory is rendered entirely by the engine** — there is no
Lua inventory GUI (confirmed: no `data/scripts/gui/`, no `draw_action_icon`,
nothing). Mods can only draw their own GUI via `GuiCreate`/`GuiStartFrame`, and
**the engine never exposes where it drew the spell slots**. GUI coordinates also
*scale with resolution* (`GuiGetScreenDimensions` is resolution-dependent). That
forces a choice in how we present the brackets:

- **A. Overlay on the native slots.** Draw bracket glyphs/lines directly over the
  wand's spell row in the inventory. Matches the original vision exactly, *but*
  requires hardcoding/measuring the slot origin + pitch in GUI space and tracking
  it across resolutions, UI scale, and the quick- vs full-inventory views. Most
  fragile; most likely to break on a game update.
- **B. Companion "structure" panel.** When the inventory is open, draw our own
  panel (coords we fully control) that lists the wand's spells in order with
  indentation + nesting brackets and the type colors from `main`. Always correct,
  resolution-proof, can show deep nesting clearly. Trade-off: it sits beside the
  native slots rather than literally on them.
- **C. Hybrid.** Ship B first (guaranteed working), then attempt A as an optional
  overlay layer once B's tree rendering is solid.

**Recommendation: C** — build B now (it reuses the whole validated foundation and
can't be blocked by the slot-position problem), then treat the native overlay as
an enhancement we can tune against a real screen.

## Implemented (panel — phase 1)

- **`files/grouping_overlay.lua`** — reads the active wand (`Inventory2Component.
  mActiveItem`) and its cards (`ItemActionComponent.action_id`, ordered by
  `ItemComponent.inventory_slot`), builds the tree, flattens it to indented
  color-coded lines, and draws a panel via our own `Gui` while
  `GameIsInventoryOpen()`.
- **`init.lua`** — `OnWorldPostUpdate` calls it, lazily loaded and `pcall`-guarded
  so any failure disables the panel instead of breaking the game.
- **`settings.lua`** — `show_grouping` toggle (RUNTIME scope).
- Colors reuse the per-type palette from `main`.

## Remaining work (HISTORICAL — all items since resolved; STATUS.md is current)

Kept as the design-time record. How each closed out: (1) everything verified
in-game over 2026-06-09..11; (2) always-cast cards got their own "always:"
line (verified), mod spells fall back to leaves, shuffle wands now show
NOTHING at all (no panel, no brackets — user call), multi-cast splits are
the cast-grouping feature itself; (3) the slot overlay shipped as a co-equal
feature — the "selected box is taller" limitation turned out to be FALSE
(tall wand sprite in disguise; selection changes nothing); (4) localized
`$action_*` names landed in the panel.

1. **Verify in-game** (needs a real run) — confirm `mActiveItem` reads, slot
   ordering, and panel placement; tune position/width/legibility.
2. **Edge cases:** always-cast cards (currently sorted by slot like the rest —
   may want a separate section), mod-added spells (unknown → leaf, OK),
   shuffle wands (deck order randomizes at cast — panel shows static slot order;
   note this), `cast count` > 1 (panel shows whole deck, not per-shot split).
3. **Phase 2 — wand-box slot overlay** (the build-aid vision): *calibrated, but
   fundamentally limited.* `draw_box_brackets` enumerates every carried wand and
   draws grouping brackets under each wand box's spell row (`BOX` table = GUI-
   fraction geometry). Calibrated against GUI 640×360 (px = 2.5×GUI): non-selected
   boxes align; the **selected box renders ~12 GUI taller and can't be detected**,
   so the box you're editing reads slightly high. Toggle: `show_slot_brackets`.
   See `STATUS.md` for the decision point (likely make the panel primary). Panel
   remains the reliable fallback.
4. **Polish:** friendlier names via the `$action_*` translations instead of
   prettified ids; optional connector glyphs.
