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

## Root cause (measured in-game, 2026-08-05)

Under a non-pixel UI font, **fractional `scale` is broken in both directions,
and the two directions disagree**:

- `GuiText(gui, x, y, text, scale)` **ignores `scale`** and draws at ~1.0.
- `GuiGetTextDimensions(gui, text, scale)` shrinks **sub-linearly**.

The mod's own font probe, in game with Better Font active:

```
font probe "MWli0 |[]"  @1.0: 31.5 x 12.5   @0.6: 11.1 x 5.0
```

A requested 0.6 returned **0.352×** the width and **0.400×** the height of the
same font's own 1.0 reading — not 0.6×. So the panel is measured for 0.6-size
text and then painted with 1.0-size text: roughly **2.8× too big for the box it
was fitted into**.

The panel is right-anchored by design (since v1.2): its right edge is pinned at
`sw - RIGHT_MARGIN` and it grows *leftward* by its computed width. So the
overflow does not move the panel — it runs off the right edge of the screen.
And `line_h = text height + 2`, taken from the shrunken measured height, stacks
the rows nearly on top of each other. "Far right", "compressed", "can barely
read the info": all three reports, one cause.

Everything the panel lays out flows from `GuiGetTextDimensions` — row spacing,
the `"| "` nesting-spine advance, panel width, and `fit_label` truncation — so
the error compounds across every dimension at once.

## The measurements

From 2000×1125 screenshots (GUI 640×360, so 3.125 px per GUI unit), Better Font
active, same wand:

| drawn at | measured | rendered | effective scale |
|---|---|---|---|
| debug box, `scale = 1.0` | 214.4 GUI interior | 210.2 GUI widest line | **1.003** — fits |
| structure panel, fractional | 63.7 GUI panel (Tiny) | labels clipped off-screen | **~1.06** — scale ignored |

Panel width by text size, same wand:

| Text Size | panel width | outcome |
|---|---|---|
| Tiny (0.5) | 63.7 GUI | labels run off the right edge of the screen |
| Large (1.0) | 142.1 GUI | every label inside the box, nothing clipped |

**At 1.0 measuring and drawing agree exactly.** The debug box is the proof: it
is measured and drawn at 1.0 and fits its own text with 4 GUI to spare, in the
very same frame where the panel below it is unreadable. Its row pitch (45 px =
14.4 GUI) also matches its computed `line_h` (12.5 + 2), confirming the probe's
reported height is what the layout actually used.

## What v1.3.1 does about it

1. **`faithful_scale()` — the fix.** Before laying anything out, `draw_panel`
   asks the engine to measure one probe string at 1.0 and at the requested
   scale. If the width does not shrink by roughly the requested factor (15%
   relative tolerance), the active font cannot do fractional scale, and the
   panel falls back to 1.0 — the one scale where measurement and rendering
   agree. Two extra measurements per panel draw. It reads the **raw** engine
   call, not `text_dims`, since the floors would mask the degeneracy it is
   testing for.

   No font sniffing, so it covers font mods and TTF-font languages alike, and
   it is a no-op on the vanilla pixel font, which scales linearly.

2. **"Large" text size** (scale 1.0, new setting value). Still offered as a
   manual choice; it is also what the clamp selects.

3. **UTF-8-safe truncation.** Independent of the above: `fit_label` truncated
   **byte by byte** (`s:sub(1, #s - 1)`) assuming ASCII spell names. Localized
   names from `GameTextGet` are UTF-8, so Japanese names were split
   mid-character, feeding `GuiText` invalid byte sequences. It now counts and
   trims *characters*.

4. **Font probe in the Debug Info box.** Prints the raw `GuiGetTextDimensions`
   readings at 1.0 and 0.6, plus the derived `scale fidelity` ratio and whether
   the clamp engaged — so one screenshot shows both the font's behaviour and
   the mod's response to it. The debug box also derives its own line height
   from the measured font instead of a hardcoded 11.

5. **`text_dims()` floors** — retained, but **not** the fix. They are a narrow
   guard against a font measuring 0 or nil, which would collapse the layout
   outright. They sit below everything the vanilla pixel font returns
   (`data/fonts/font_pixel.xml`: mean letter advance 4.94 GUI at scale 1; only
   `i l . : ; '` are as narrow as 2), so they stay inert in the shipped
   configuration.

   An earlier revision of this document claimed the floors *were* the fix, on
   the theory that non-pixel fonts under-measure. That theory was wrong. The
   measurements are not degenerate — they are on a different curve than the
   renderer, and no floor can detect that.

## Validating the fix

`lua tools/test_font_compat.lua` (any Lua 5.1+/LuaJIT) drives the **real**
`draw_panel` and font helpers under four stubbed fonts:

- **pixel-like** — regression guard: the user's chosen size must survive at
  0.5/0.6/0.75, and the floors must stay inert.
- **nonlinear** — the reported font, reproduced from the in-game probe above
  (0.352 / 0.400 shrink instead of 0.6). Asserts the clamp fires, that every
  row is drawn at 1.0, that the panel is wide enough for the text actually
  drawn, and that nothing crosses the right screen edge.
- **zero-measuring** and **nil-returning** — degenerate fonts; the floors keep
  the panel usable.

On success it prints the in-game checklist for the half a script can't cover.

## Reference: vanilla font metrics

Read from the game's own `data/fonts/*.xml`. Noita's own non-pixel fonts measure
**larger** than the pixel font, not smaller — which is why "a TTF under-measures"
was never a viable theory:

| font | LineHeight | mean letter width |
|---|---|---|
| `font_pixel.xml` (vanilla UI) | 7 | 4.94 |
| `ubuntu_condensed_10.xml` | 11 | 6.14 |
| `ubuntu_condensed_18.xml` | 20 | 7.37 |

`GuiGetTextDimensions` returns the glyph quad height (`rect_h` = 11 for
`font_pixel.xml`), not `LineHeight` (7).

## Rejected: pinning the font explicitly

Both Gui calls accept optional tail arguments:

```
GuiGetTextDimensions( gui, text, scale = 1, line_spacing = 2, font = "", font_is_pixel_font = true )
GuiText( gui, x, y, text, scale = 1, font = "", font_is_pixel_font = true )
```

Forcing `data/fonts/font_pixel.xml` on both sides would guarantee that measuring
and drawing agree. Rejected for two reasons:

- **It would break localized spell names.** The vanilla pixel font has no
  Japanese glyphs, so pinning it would render exactly the names the UTF-8 fix
  exists to protect as garbage.
- **It wouldn't fix the reported case anyway.** Font mods override
  `data/fonts/font_pixel.xml` *in place*, so pinning that path still yields the
  modded font. The problem was never which font is selected.

## Verified in-game (2026-08-05)

| configuration | probe @1.0 | probe @0.6 | fidelity | result |
|---|---|---|---|---|
| vanilla pixel font | 43.0 × 11.0 | 25.8 × 6.6 | **x0.60 ok** | no clamp; Medium renders at 0.75 (row pitch 10.24 GUI vs 10.25 predicted) |
| Better Font (English) | 31.5 × 12.5 | 11.1 × 5.0 | **x0.35 BROKEN** | clamped to 1.0; 142.1-GUI panel, nothing clipped |
| Simplified Chinese (CJK) | 31.5 × 12.5 | 11.1 × 5.0 | **x0.35 BROKEN** | clamped to 1.0; 118.4-GUI panel, right edge 635.2 GUI of 640 |

The vanilla readings match `font_pixel.xml` exactly (summed `QuadChar` widths =
43.0; `rect_h` = 11), confirming how `GuiGetTextDimensions` computes both axes.

Note that Better Font and the CJK language font return **identical** probe
numbers. The engine appears to have one non-pixel measurement path, so the
0.35 signature is not specific to any one font — which is why a runtime check
generalises where font sniffing would not.

## Still open

- **The UTF-8 truncation fix has not been exercised in-game.** Under CJK the
  labels all fit, so `fit_label` never trimmed. The logic is covered by
  `tools/test_font_compat.lua`, which runs the real `fit_label` over multi-byte
  strings and asserts whole-glyph trimming and valid UTF-8 output — but no
  screenshot has yet shown a trimmed CJK label. To force one, a wand needs deep
  enough nesting (each `|` spine eats label budget) or a long enough localized
  name to exceed `max_panel_w`.
- Whether any font gets fractional scale *partly* right (e.g. honours 0.75 but
  not 0.5). The clamp falls all the way back to 1.0 rather than searching for
  the largest faithful scale. If a user reports Large being unnecessarily big,
  that search is the follow-up.
