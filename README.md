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
   notation. **Casts are bracketed too**, one level outside the groups they
   contain, so what fires together is visible at a glance; the rainbow is one
   continuous progression across both axes, advancing per cast *and* per
   nesting level. A cast firing a single spell isn't bracketed — there is no
   simultaneity to show. Brackets that share a card edge stack outward from it,
   the outermost's hooks reaching past the inner ones.
   **Orange marks the wrap**: one enclosing bracket around the whole looping
   structure, from the first card the wrap pulled back in to where the cast ran
   out of deck, tagged `wraps to front` at its closing end:

   ```
   [ chainsaw, chainsaw, [Double spell, Spitter [Double spell, Spitter]] ]
   ^ the wrap                                              closing wrap ^
   ```

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

**What a bracket means**

> A bracket encloses exactly the cards the engine removed from the deck
> while executing the bracket's head card. A cast bracket encloses the
> cards removed from the deck during one cast. A card a spell re-casts by
> reference (Alpha, Omega, …) is not removed, so it is never inside a
> bracket — the panel names it as a copy instead.

Trigger payloads stay nested because they're consumed by the forced draw
even though they fire later; Divide By and Add Trigger are prefixes, not
single-card wrappers, since they consume a variable number of cards; and
Greek spells get no bracket to the card they copy, since the panel names
the copy in text instead.

The panel simulates the engine's exact draw rules (verified from `gun.lua` in
`data.wak`): each cast draws the wand's *spells/cast* expressions; modifiers
(and every other card that force-draws one replacement, like Alpha)
prefix-attach; multicasts gather N cards; triggers open nested payloads; and
forced draws on an empty deck wrap the discard back in, in slot order, ending
the recharge cycle. The Divide By spells prefix-attach too — their bodies
invoke the next card directly rather than drawing it — but on an empty deck
they do nothing, so unlike a modifier they never wrap. Always-cast spells are listed separately (they join every
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
- **Wand Structure Panel: Text Size** — Tiny / Small / Medium / Large. With a
  font mod (e.g. Better Font) or a language with a smooth non-pixel font
  (Japanese, …) the game ignores the smaller sizes; the panel detects that and
  switches itself to **Large** automatically (see `docs/FONT_COMPAT.md`).
- **Slot Brackets** — the in-UI rainbow brackets (on by default).
- **Ignore Depleted Spells** — model spells with 0 charges the way the game
  does it (they're skipped and the next card drawn instead), giving the right
  wand structure and wrap points. Turn off to pretend every card fires,
  depleted or not (on by default).
- **Greek Wands: Keep Depleted Spells** — no longer does anything; the mod now
  models depleted spells correctly for all wands. This option will be removed
  in the next release.
- **Uncertain Wands: Slot Brackets** — a wand holding a spell whose deck effect
  the mod can't follow exactly (Greek spells, IF spells, random draws, unknown
  modded spells) draws no slot brackets by default and shows a small `?` at the
  end of the row; Hide keeps that rule, Show draws the brackets anyway for
  players who want the approximation (Hide by default).
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
tools/preview_wand.lua       # prints any wand's brackets as a Lisp line, no game needed
tools/test_wand_structure.lua # runs the real wand_structure.lua + tests (primary)
tools/test_gun_differential.lua # differential check against Noita's own gun.lua (via .gun_ref/)
tools/gun_harness.lua        # runs the extracted gun.lua from .gun_ref/ over test wands
tools/extract_gun.py         # extracts gun.lua, gun_actions.lua from data.wak into .gun_ref/
tools/test_slot_delims.lua   # runs the real slot-bracket planner (nesting, casts, wrap)
tools/test_panel_rows.lua    # runs the real panel row clamp (+N more fold, sticky legend)
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
   the real `wand_structure.lua`.
4. `lua tools/test_gun_differential.lua` runs a differential check against
   Noita's own `gun.lua`, verifying the simulator on every test wand. Requires
   `python3 tools/extract_gun.py` first (writes gitignored `.gun_ref/`);
   therefore local-only.
5. `lua tools/test_slot_delims.lua` runs the real slot-bracket planner —
   nesting depth, cast brackets, the wrap enclosure, stacking on a shared card
   edge, wands with empty slots.
6. `lua tools/test_panel_rows.lua` runs the real panel row clamp — the
   `... +N more` fold and the sticky `?` legend that has to survive it.
7. `lua tools/test_font_compat.lua` validates the non-pixel-font fixes
   (`docs/FONT_COMPAT.md`) by driving the real panel layout with stubbed
   pixel-like / zero-measuring / nil-returning fonts, then prints the in-game
   checklist for verifying against the Better Font mod or a TTF language.

To eyeball a specific wand without starting a run, `tools/preview_wand.lua`
prints its delimiters as a Lisp line, coloured with the rainbow the mod would
actually draw:

```
$ lua tools/preview_wand.lua CHAINSAW,CHAINSAW,BURST_2,SPITTER,BURST_2,SPITTER

  [Chainsaw, Chainsaw, [Burst 2, Spitter, [Burst 2, Spitter]]]
```

It drives the same `collect_wand_delims`/`plan_delims` the overlay does, so the
structure is exactly what would land on the slot row. It says nothing about the
*geometry* — where the wand box sits, how the glyphs meet the card art — which
is calibrated from screenshots and still needs the game.

Pass `--tier` to check the wand's structure confidence (exact/approximate/unknown) and name any cards that block a fully determined simulation, e.g. `lua tools/preview_wand.lua ADD_TRIGGER,DAMAGE,LIGHT_BULLET,BOMB --tier --mana`.
Pass `--mana` to print the mana cost of each cast alongside the spells it contains.
Pass `--uses=SLOT:N,SLOT:N` to mark depleted spells (0 charges) for the simulator to track through wraps, e.g. `lua tools/preview_wand.lua LIGHT_BULLET,LIGHT_BULLET,DAMAGE --per-cast=1 --uses=3:0 --mana`.

Unsafe Lua APIs are not requested (`request_no_api_restrictions="0"` in `mod.xml`).

## Retired: icon recolor

The mod originally re-pointed every vanilla spell's icon at a generated copy
with a type-colored border (red projectile, blue modifier, …). It was retired
2026-06-09 — the rainbow brackets made the borders redundant visual noise.
To revive it: `git log` for `files/recolor_actions.lua` / `files/known_ids.lua`
and the `OnModInit` hook in `init.lua`, and regenerate the icons with
`python3 tools/gen_icons.py`.

## Known limitations

- Mod-added spells get their *type* from the game's live spell table, so modded
  modifiers and multicasts group the way vanilla ones do -- but how many cards a
  modded spell really draws isn't known yet, so a wand holding one is marked
  uncertain and hides its slot brackets by default (see the setting above).
- A Divide By followed by a multicast or trigger is approximated: the game
  re-invokes the divided card, drawing *fresh* cards on each invocation; the
  panel shows the first invocation's grouping.
- The panel can't know your mana, so a cast that fizzles mid-way on mana may
  differ from the simulation. (Depleted 0-charge spells *are* handled — see
  the settings above.)
- Spells whose effect depends on the game state at cast time are marked `?`
  in the panel: the Requirement (If) spells skip part of the wand when their
  condition is false, and the random-draw spells (Random Spell, Draw
  Random, …) cast extra cards chosen at cast time. The structure shown is the
  condition-true / no-extras path.
- Shuffle wands get **no panel and no brackets** — the real draw order
  randomizes each cycle, so any displayed structure would be just one
  arrangement of many.
- With a non-pixel UI font — font mods ("Better Font") and the smooth-font
  languages (Japanese, …) — Noita ignores fractional text scales when *drawing*
  while still shrinking them when *measuring*, so the panel used to be built
  ~3× too small for its own text and spilled off the right edge of the screen.
  v1.3.1 detects that from the engine's own measurements and pins the panel to
  the one scale where the two agree (Large); on the vanilla pixel font nothing
  changes and your chosen size is kept. Analysis: `docs/FONT_COMPAT.md`.
- The slot brackets' geometry is a *model* of the engine's wand-box layout (no
  Lua API exposes the real positions). It's calibrated against GUI 640×360 and
  scaled by that constant, so it holds at every GUI resolution Noita produces,
  but an unusual wand sprite can still sit ~1 engine unit off, and a game update
  could shift the layout. Turn on **Debug Info** and send a screenshot if so;
  the panel is always reliable regardless.
