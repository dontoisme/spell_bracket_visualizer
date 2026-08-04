# Spell Bracket Visualizer

A [Noita](https://noitagame.com/) mod that shows a wand's **cast structure**
Lisp/SLIME-style, so you can see at a glance which spells fire
**simultaneously** in each cast, which modifiers feed which projectile, what a
multicast gathers, what a trigger's payload is — and, crucially for rapid-fire
wands, **when the wand WRAPS** (a forced draw past the deck's end pulls cards
from the wand's start and forces the recharge).

Two views, both live while the inventory is open:

1. **Wand structure panel** (anchored to the right of the screen, tracking the
   selected wand and updating live as you rearrange spells): an indented tree
   of the held wand, one cast per section, rainbow nesting spines by depth,
   spell names colored by action type. Wrapping casts get a loud orange
   `WRAPS! -> recharge` banner and wrapped-in cards are marked `~`. It pins to
   the selected wand's box when the structure is short and takes over the full
   right column when it isn't, drawing opaque and on top so it stays readable;
   long structures clamp to the screen (`... +N more`) instead of overflowing.
2. **Slot brackets** (in the wand UI itself): `[ ]` bracket glyphs hugging
   each group's first and last card — SLIME rainbow parens, color cycling by
   nesting depth, no text labels (the card art already says what the group
   is). Leading modifiers sit *outside* the brackets, matching Lisp
   notation; closes that share a card stack outward from its right edge,
   the outermost's hooks wrapping the inner ones. **Orange marks the wrap**: the
   group the wrap happened in gets an orange `wraps to front` tag, orange brackets
   around the wrapped-in cards at the wand's start, and a carriage-return
   line under the row connecting the two — "the draw continues here".

## Install

**Steam:** subscribe on the
[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3743473994).

**Everyone else (GOG / DRM-free / by hand):** grab the zip from the
[latest release](https://github.com/dontoisme/spell_bracket_visualizer/releases/latest)
and extract it into your Noita `mods` folder (the one next to `noita.exe`), so
that `Noita/mods/spell_bracket_visualizer/init.lua` exists. Then enable
**Spell Bracket Visualizer** in the game's Mods menu.

The folder must be named exactly `spell_bracket_visualizer` — the mod loads its
own files by that path, so GitHub's green "Download ZIP" button (which produces
`spell_bracket_visualizer-main`) will *not* work unless you rename it. The
release zip is already laid out correctly and contains only the files the game
needs; `INSTALL.txt` inside it has the long-form walkthrough and troubleshooting.

## How it works

The panel simulates the engine's exact draw rules (verified from `gun.lua` in
`data.wak`): each cast draws the wand's *spells/cast* expressions; modifiers
(and every other card that force-draws one replacement, like Alpha)
prefix-attach; multicasts gather N cards; triggers open nested payloads; and
forced draws on an empty deck wrap the discard back in, in slot order, ending
the recharge cycle. Always-cast spells are listed separately (they join every
cast). Shuffle wands show nothing at all — their draw order randomizes each
cycle, so there is no fixed structure to display.

The engine renders the inventory itself (no Lua hook exposes slot or box
positions), so the panel draws on its own Gui at safe coordinates, while the
slot brackets use a calibrated model of the wand-box layout: a wand's box height
is driven by its sprite THICKNESS (`26.9 + 1.25 x art height` engine units, read
live via `GuiGetImageDimensions`, with `wand_sprite_meta.lua` as the offline
lookup), and boxes stack from there — so brackets stay put across wand pickups,
reordering, and selection changes.

## Settings (in the in-game mod settings menu)

All settings are runtime-scoped and apply immediately.

- **Wand Structure Panel** — the text tree on/off.
- **Wand Structure Panel: Text Size** — Tiny / Small / Medium / Large. Pick
  **Large** if you use a font mod (e.g. Better Font) or a language with a
  smooth non-pixel font (Japanese, …): fractional sizes only render crisply
  with the default pixel font (see `docs/FONT_COMPAT.md`).
- **Slot Brackets** — the in-UI rainbow brackets (on by default).
- **Ignore Depleted Spells** — leave 0-charge spells out of the structure,
  since they can't fire (on by default).
- **Greek Wands: Keep Depleted Spells** — Greek spells (Alpha, Tau, Omega…)
  re-cast by slot *position*, so a depleted spell still shifts what they read;
  on those wands keep everything (on by default).
- **Debug Info (for bug reports)** — resolution/GUI readout plus per-box guide
  lines; screenshot this if the brackets ever misalign.

## Project layout

```
init.lua                     # OnWorldPostUpdate: drives the overlay
settings.lua                 # mod settings menu
files/structure_meta.lua     # generated per-spell structural metadata (draws/group/payload)
files/wand_structure.lua     # pure deck simulator: casts, chaining, multicasts, wrap
files/grouping_overlay.lua   # reads the live wand + draws the panel / slot brackets
tools/gen_structure_meta.py  # regenerates structure_meta.lua from data.wak
tools/test_wand_structure.lua # runs the real wand_structure.lua + tests (primary)
tools/test_wand_structure.py # Python cross-check mirror of wand_structure.lua
tools/gen_icons.py           # (retired icon-recolor feature; see below)
tools/make_release.sh        # builds dist/<mod>-<version>.zip for manual installs
INSTALL.txt                  # manual-install guide (shipped in the release zip)
mod.xml, compatibility.xml
workshop.xml                 # Steam Workshop manifest (name/desc/tags/excludes)
docs/workshop_description.bbcode # the Workshop page description (BBCode, pasted by hand)
workshop_preview_image.png   # Workshop thumbnail (16:9)
```

Regenerate `structure_meta.lua` after a game update:

```
python3 tools/gen_structure_meta.py
```

## Testing

1. Enable **Spell Bracket Visualizer** in the mod menu, start/continue a run.
2. Hold a wand and open the inventory: the panel docks beside its box; with
   Slot Brackets enabled, rainbow strips mark each group in the wand boxes.
3. `lua tools/test_wand_structure.lua` runs the simulator's test suite against
   the real `wand_structure.lua`; `python3 tools/test_wand_structure.py` runs the
   Python cross-check mirror (kept in sync; slated for retirement once the Lua
   harness is fully trusted).
4. `lua tools/test_font_compat.lua` validates the non-pixel-font fixes
   (`docs/FONT_COMPAT.md`) by driving the real panel layout with stubbed
   pixel-like / zero-measuring / nil-returning fonts, then prints the in-game
   checklist for verifying against the Better Font mod or a TTF language.

Unsafe Lua APIs are not requested (`request_no_api_restrictions="0"` in `mod.xml`).

## Retired: icon recolor

The mod originally re-pointed every vanilla spell's icon at a generated copy
with a type-colored border (red projectile, blue modifier, …). It was retired
2026-06-09 — the rainbow brackets made the borders redundant visual noise.
To revive it: `git log` for `files/recolor_actions.lua` / `files/known_ids.lua`
and the `OnModInit` hook in `init.lua`, and regenerate the icons with
`python3 tools/gen_icons.py`.

## Known limitations

- Only the standard spell set (`gun_actions.lua`) is modeled; mod-added spells
  appear in the panel as plain leaves.
- The panel can't know your mana, so a cast that fizzles mid-way on mana may
  differ from the simulation. (Depleted 0-charge spells *are* handled — see
  the settings above.)
- Shuffle wands get **no panel and no brackets** — the real draw order
  randomizes each cycle, so any displayed structure would be just one
  arrangement of many.
- The panel draws with the game's current UI font, and its layout is measured
  via `GuiGetTextDimensions` — which is only calibrated against the vanilla
  pixel font. Font mods ("Better Font") and TTF-font languages (Japanese, …)
  used to collapse the panel into a tiny sliver at the right screen edge;
  v1.3.1 floors the metrics so the layout survives, but with a non-pixel font
  set **Text Size: Large** for readable output. Analysis and remaining work:
  `docs/FONT_COMPAT.md`.
- The slot brackets' geometry is a *model* of the engine's wand-box layout (no
  Lua API exposes the real positions). It's calibrated against GUI 640×360 and
  scaled by that constant, so it holds at every GUI resolution Noita produces,
  but an unusual wand sprite can still sit ~1 engine unit off, and a game update
  could shift the layout. Turn on **Debug Info** and send a screenshot if so;
  the panel is always reliable regardless.
