# Spell Bracket Visualizer

A [Noita](https://noitagame.com/) mod that draws colored brackets around spells in
the wand/inventory UI to visualize spell groupings and triggers — making wand
crafting more intuitive.

Bracket color is intended to encode each spell's action type:

| Action type        | Color  |
| ------------------ | ------ |
| Projectile         | Red    |
| Static projectile  | Green  |
| Modifier           | Blue   |
| Draw (draw many)   | Yellow |
| Material           | Purple |
| Other / unknown    | Gray   |

## Status

**Work in progress / revived from an earlier prototype.** Core wiring is in place
but the feature is unfinished — see [Known issues](#known-issues).

The mod folder is `testMod` (the in-game/internal id is `testMod`); the
player-facing name is **Spell Bracket Visualizer**. An earlier first attempt at the
same idea lives in the sibling `blocky` mod.

## How it works

`init.lua` hooks `OnModInit` and appends `files/gui/spell_brackets.lua` onto the
game's wand GUI script:

```lua
ModLuaFileAppend("data/scripts/gun/gui.lua", "mods/testMod/files/gui/spell_brackets.lua")
```

`spell_brackets.lua` then overrides the game's `draw_action_icon` to draw an opening
bracket before the spell icon and a closing bracket after it. Helpers
`GetSpellTriggerType` / `GetBracketColor` map an action's `type` to a label and an
RGB color.

`settings.lua` defines two mod settings (visible in the in-game mod settings menu):
- **Bracket Style** — square `[]`, round `()`, curly `{}`, or angle `<>`
- **Colored Brackets** — on/off

## Project layout

```
init.lua                     # mod entry point; appends the GUI override
settings.lua                 # mod settings menu (bracket style, colored toggle)
mod.xml                      # mod metadata (name, description)
compatibility.xml            # built-with version marker
files/gui/spell_brackets.lua # the actual feature: draw_action_icon override
```

### Leftover boilerplate (not wired up)

The following were copied from Noita's bundled `example` mod while scaffolding and
are **not referenced by `init.lua`**. They can be deleted once confirmed unneeded:

- `files/actions.lua`, `files/actions/sea_swamp.*` (still reference `mods/example/...`)
- `files/potion_appends.lua`, `files/materials_rainbow.xml`, `files/materials_gfx/rainbow.png`
- `files/magic_numbers.xml`, `files/audio_events.txt`
- `files/music.bank`, `files/my_mod_audio.bank` (~6 MB of unused example audio)
- `data/items_gfx/handgun.png`

## Known issues / TODO

- `draw_action_icon` always draws hardcoded square `[` / `]` (line ~54/60) — it reads
  the `bracket_style` setting into a local but never uses the `brackets` table.
- Bracket coloring is unimplemented: `GetBracketColor` exists but `GuiText` is called
  without applying color, and the `show_colors` setting isn't consulted.
- Bracket X offsets (`x - 4`, `x + 12`) are guesses and need tuning against real icon
  spacing.
- Debug `print` calls fire every frame / every icon — remove or gate before release.
- Brackets are drawn per-icon, not around contiguous *groups* of spells, so trigger
  groupings aren't actually visualized yet.

## Developing

This repo lives directly inside the Noita mods folder
(`steamapps/common/Noita/mods/testMod`), so edits are picked up by the game on the
next launch. To test:

1. Launch Noita, open the mod menu, enable **Spell Bracket Visualizer**.
2. Start/continue a run and open a wand to see the brackets in the spell UI.
3. Watch `logger.txt` in the Noita install dir for the `[TestMod]` debug prints.

Unsafe Lua APIs are not requested (`request_no_api_restrictions="0"` in `mod.xml`).
