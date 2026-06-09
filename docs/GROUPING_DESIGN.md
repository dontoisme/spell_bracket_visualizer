# Grouping brackets (Lisp/SLIME-style) — design

**Goal:** show a wand's *cast structure* — which modifiers feed which projectile,
which cards a multicast gathers, and what a trigger's payload is — as nested
brackets, the way SLIME shows Lisp expression structure.

Branch: `grouping-brackets`. Status: foundation landed; renderer pending a
decision (see [Open decision](#open-decision-rendering)).

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

## Remaining work

1. **Renderer** (depends on the decision above): walk the tree, draw brackets +
   spell icons/colors. Reuse `main`'s per-type colors.
2. **Runtime glue:** an `OnWorldPostUpdate`/GUI loop gated on
   `GameIsInventoryOpen()`, reading the active wand's deck and feeding
   `wand_structure.build`.
3. **Settings:** a toggle for the grouping view (independent of the icon recolor).
4. **Edge cases:** always-cast cards, mod-added spells (unknown → leaf),
   shuffle wands (deck order is randomized at cast — show static slot order and
   note it), per-cast `cast count` > 1.
5. **Verify in-game** (needs a real run; can't launch the GUI game from WSL here).
