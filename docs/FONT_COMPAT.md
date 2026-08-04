# Font compatibility — the "panel squished at the right edge" reports

## The reports (Steam Workshop comments, July 2026)

- **BourbonCrow, Jul 26**: "i got some issue wit the ui floating all the way to
  the right side of screen and its like compressed and smaller then it should
  so can barly read the info" — then self-diagnosed: "i found what caused it..
  its the Better Font (English)" (Workshop id 2098567286), and added that "the
  issue also happends with the default langauges that are not pixelated like
  japanese and so on".
- **shinylavawarrior, Jul 24**: "I'm also having an alignment issue (it's on
  the far right of the screen)".

## The common factor: a non-pixel (TrueType) UI font

Noita's English UI uses a bitmap **pixel font**. Two things replace it with a
smooth TrueType font:

1. Font mods — "Better Font (English)" swaps the pixel font for a TTF.
2. Several default localizations (Japanese, and the other "not pixelated"
   languages) ship TTF fonts out of the box.

Both reported triggers are the same underlying condition: **the active UI font
is no longer the pixel font the mod was calibrated against.** A mod's own
`GuiText` always draws with the game's current language font — we cannot keep
the pixel font for ourselves.

## Why that produces exactly the reported symptoms

Every dimension of the structure panel flows from `GuiGetTextDimensions`
(`draw_panel` in `files/grouping_overlay.lua`):

- row spacing: `line_h = text height + 2`
- nesting-spine advance: width of `"| "`
- panel width: widest measured label + padding
- label truncation: `fit_label` measures candidate strings

and the panel is **right-anchored by design** (since v1.2): its right edge is
pinned at `sw - RIGHT_MARGIN` and it grows *leftward* by its computed width.

The pixel font measures exactly like it renders — every calibration in this
mod assumed that. A TTF does not: it reports smaller metrics than the pixel
font, and fractional scales (the panel ships at 0.6 "Small"; all three
original sizes were 0.5/0.6/0.75) render a TTF far smaller and blurrier than
they render the chunky pixel font. So with a non-pixel font:

- under-reported **widths** shrink the panel — and because it is
  right-anchored, a too-narrow panel doesn't drift off position, it collapses
  into a sliver **at the right screen edge** ("floating all the way to the
  right side of screen");
- an under-reported **height** collapses `line_h`, stacking the rows onto each
  other ("like compressed");
- a fractional scale on a TTF renders tiny, unhinted text ("smaller then it
  should so can barly read the info").

A separate, unconditional bug for TTF *languages*: `fit_label` truncated
labels **byte by byte** (`s:sub(1, #s - 1)`) on the assumption that spell
names are ASCII. Localized names from `GameTextGet` are UTF-8 — Japanese names
got split mid-character, feeding `GuiText` invalid byte sequences.

## What v1.3.1 does about it

1. **Metric floors** (`text_dims`): all panel sizing goes through a wrapper
   that clamps measurements to a lower bound shaped like the pixel font's
   smallest plausible metrics (3 GUI/char advance, 6 GUI height, × scale).
   The floors sit below everything the vanilla pixel font actually returns,
   so the shipped pixel-font layout is byte-identical; they only engage when
   a font measures degenerately, and then they keep the panel wide and the
   rows apart instead of letting the layout collapse.
2. **"Large" text size** (scale 1.0, new setting value): 1.0 is the one scale
   every font renders crisply. This is the recommended setting for font-mod
   users and TTF-font languages until scale handling can be verified in-game
   against a TTF.
3. **UTF-8-safe truncation**: `fit_label` now counts and trims *characters*,
   never splitting a multi-byte glyph.
4. **Font probe in the Debug Info box**: the debug readout now prints the RAW
   `GuiGetTextDimensions` readings of a fixed probe string at scale 1.0 and
   0.6. With the vanilla pixel font the 0.6 numbers are ~0.6× the 1.0 numbers
   and none are near zero. One screenshot from an affected user now
   confirms or refutes this whole analysis. (The debug box also derives its
   own line height from the measured font instead of a hardcoded 11, so a
   tall TTF can't overlap the very readout used to diagnose it.)

## Status / open questions

The exact numbers a TTF returns from `GuiGetTextDimensions` (and whether
`GuiText`'s scale is applied identically for pixel and TTF fonts) have **not
been verified in-game** — we don't run the font mod or a TTF language locally.
The mitigation is therefore defensive: floors that cannot regress the pixel
font path, an escape-hatch scale that every font renders well, and
instrumentation to get ground truth from affected users.

Follow-ups once a probe screenshot arrives:

- If the TTF readings are sane (just smaller), consider auto-detecting a
  non-pixel font (probe reading far from the pixel font's known values) and
  bumping the effective panel scale to 1.0 automatically.
- Newer Noita builds accept optional `font, is_pixel_font` tail arguments on
  `GuiText` / `GuiGetTextDimensions`; forcing the vanilla pixel font would
  make the panel immune to font mods — but would break localized (Japanese)
  spell names, whose glyphs the pixel font lacks. Only worth it as an opt-in.
