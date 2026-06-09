# Spell Bracket Visualizer

A [Noita](https://noitagame.com/) mod that frames every spell with a colored
border based on its **action type**, so you can read a wand's layout at a glance —
which cards are projectiles, which are modifiers, which draw more cards, etc.

Border color by action type:

| Action type        | Color  |
| ------------------ | ------ |
| Projectile         | Red    |
| Static projectile  | Green  |
| Modifier           | Blue   |
| Draw (draw many)   | Yellow |
| Material           | Purple |
| Utility            | Cyan   |
| Passive            | Orange |
| Other / unknown    | Gray   |

The coloring shows up everywhere spells are drawn — the wand-edit screen, the
inventory, shops, and Tinker tables.

## How it works

The catch with Noita: **the spell inventory is rendered by the engine, not Lua.**
There is no `draw_action_icon` (or any Lua draw hook) to override — so you can't
paint brackets over the UI from a mod. (The original prototype tried to override
`draw_action_icon` on `data/scripts/gun/gun.lua`'s GUI; that function doesn't
exist, so it never did anything.)

Instead, this mod swaps the **icon** each spell uses:

1. `init.lua` → `OnModInit` appends `files/recolor_actions.lua` onto the game's
   `data/scripts/gun/gun_actions.lua` (via `ModLuaFileAppend`, which `dofile`s it
   at the end of that file — so the vanilla `actions` table is in scope).
2. `recolor_actions.lua` reads the mod settings and, for every vanilla spell we
   have art for, repoints `action.sprite` at a pre-generated bordered copy under
   `files/icons/<style>/<id>.png`.
3. The engine then draws those bordered icons wherever spells appear.

Spells added by *other* mods are left untouched — `recolor_actions.lua` only
touches ids listed in `files/known_ids.lua`.

### The icons

`files/icons/{corners,frame}/<ID>.png` — a bordered copy of each of the 490
vanilla spell icons, in two styles, colored by the spell's action type. These are
generated, not hand-drawn: `tools/gen_icons.py` reads the original 16×16 icons
straight out of `data.wak`, decodes them (a small pure-stdlib PNG codec — no
Pillow), draws the border, and re-encodes as RGBA. Re-run it after a game update
or to tweak colors/border style:

```
python3 tools/gen_icons.py
```

## Settings (in the in-game mod settings menu)

- **Colored Brackets** — on/off. Off restores the vanilla icons.
- **Bracket Style** — *Corner brackets* (subtle L's in each corner) or *Full frame*
  (a solid 1px border).

Both are `MOD_SETTING_SCOPE_NEW_GAME`: change them in the menu, then start or
restart a run for the new spell list to pick them up.

## Project layout

```
init.lua                  # OnModInit: appends recolor_actions.lua onto gun_actions.lua
settings.lua              # mod settings menu (on/off, corners vs frame)
files/recolor_actions.lua # the recolor pass; runs in gun_actions.lua's scope
files/known_ids.lua       # generated set of vanilla spell ids we have art for
files/icons/corners/*.png # generated corner-bracket icons, colored by type
files/icons/frame/*.png   # generated full-frame icons, colored by type
tools/gen_icons.py        # regenerates the icons + known_ids.lua from data.wak
mod.xml, compatibility.xml
```

## Testing

1. Launch Noita, open the mod menu, enable **Spell Bracket Visualizer** (and place
   it appropriately in the load order — load order only matters relative to other
   mods that also edit `gun_actions.lua`).
2. Tweak the settings if you like, then start/continue a run.
3. Open a wand or a shop — every spell should be framed in its type color.

Unsafe Lua APIs are not requested (`request_no_api_restrictions="0"` in `mod.xml`).

## Known limitations

- **Per-type coloring, not per-group.** Borders encode each spell's *type*, not the
  dynamic projectile/modifier *grouping* within a specific wand. True grouping
  brackets would require a custom GUI overlay tracking the engine-drawn slot
  positions — fragile across resolutions; out of scope for now.
- Only the standard spell set (`gun_actions.lua`) is covered. The
  limited/petri/unlimited alternate action sets used by some special game modes
  are not recolored.
- Settings apply at run start (NEW_GAME scope), not instantly mid-run.
