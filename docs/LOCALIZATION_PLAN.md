# Localization plan — the mod's own UI text

Spell *names* already follow the game's language: `display_name()`
(`grouping_overlay.lua:79`) calls `GameTextGet(meta.name)` and falls back to a
prettified id. Everything the mod writes **itself** is still hardcoded English,
so in a Chinese run the panel reads `cast 2  -- WRAPS! -> recharge` above
`二重法术`. This plan closes that gap.

Noita ships 11 languages in `data/translations/common.csv`:
`en ru pt-br es-es de fr-fr it pl zh-cn jp ko`.

## 1. Scope

**Localize** — text a player reads while playing:

| string | source | notes |
|---|---|---|
| `Wand structure  (N/cast)` | `grouping_overlay.lua:1166` | panel title; **never truncated**, so it sets a floor on panel width |
| `cast N` | `:239` | per-cast header |
| `  -- WRAPS! -> recharge` | `:240` | appended to the header on a wrapping cast |
| `always: <names>` | `:233` | always-cast section |
| `... +N more` | `:929` | overflow row |
| `wraps to front` | `:450` | orange tag on the wand-box brackets |
| 6 × `ui_name` + `ui_description` | `settings.lua` | mod settings menu |
| `Tiny / Small / Medium / Large` | `settings.lua:18` | enum labels |

**Do not localize** — deliberately:

- The **Debug Info box** and the calibration/measure overlays (`:683`, `:976`,
  `:985`, `:1042`, `:1075`, `:1080`, `:1094`). These exist so users can send
  *you* a screenshot; a bug report in Korean that you can't read is worse than
  one in English. The vanilla game does the same thing with its dev overlays.
- `mod.xml` `name` / `description`. Static XML read by the mod list before any
  Lua runs — there is no hook. Same for the Workshop page.
- The `~` wrap prefix and `|` spine glyphs — symbols, not words.

## 2. Mechanism

Standard Noita approach: append rows to the shared translation CSV at init,
then read them back through the normal API.

```lua
-- init.lua, inside OnModPreInit (must be before OnMostPostInit)
local csv = ModTextFileGetContent("data/translations/common.csv")
ModTextFileSetContent("data/translations/common.csv", csv .. our_rows)
```

- `ModTextFileGetContent` returns the **current, already-modded** content, so
  reading before appending composes correctly with other mods that do the same.
  Never build from a stored copy of the vanilla file.
- `ModTextFileSetContent` is **only available in `init.lua`** and must not run
  after `OnMostPostInit`.
- Keys get a `sbv_` prefix (`sbv_panel_title`, `sbv_cast`, …) to avoid
  colliding with the game's ~3700 keys or another mod's.
- Read at draw time with `GameTextGet("$sbv_cast")`.

`init.lua` currently has no `ModTextFile*` use and no `OnModPreInit`, so this is
a new hook.

## 3. Terminology: reuse the game's own translations

**This is the highest-value part of the plan.** Noita already ships
professionally translated wand vocabulary in all 11 languages. Reusing those
keys costs nothing, needs no translator, and guarantees the panel matches the
words the player already sees in the vanilla inventory:

| concept | existing key | en | zh-cn | jp |
|---|---|---|---|---|
| wand | `$item_wand` | Wand | 魔杖 | 杖 |
| recharge | `$inventory_mod_rechargetime` | Recharge time | 充能时间 | リチャージ時間 |
| shuffle | `$inventory_shuffle` | Shuffle | 乱序 | シャッフル |
| spells per cast | `$inventory_actionspercast` | Spells/Cast | 法术数/施放 | 呪文/詠唱 |

Three tiers:

1. **Reuse** — compose from existing keys wherever the concept already exists.
   The panel title is literally "wand" + "structure"; the recharge banner can
   end in the game's own recharge noun.
2. **Derive** — for "cast" as a standalone noun there is no clean key, but
   `inventory_actionspercast` fixes the correct word in every language
   (施放 / 詠唱), so our `sbv_cast` should match it rather than inventing a
   synonym.
3. **New** — genuinely mod-specific concepts with no vanilla equivalent:
   `wraps to front`, `always:`, `... +N more`. These need real translation.

Because of tier 1 and 2, the actually-novel translation surface is small —
roughly 10 short strings plus the settings menu.

## 4. Fallback

`GameTextGet` returns **empty string**, not English, for a missing key —
`display_name()` already guards this (`if t and t ~= "" then`). So:

- **Fill every language column with the English text** for languages we haven't
  translated yet. Then `GameTextGet` never returns `""` and no Lua-side
  fallback is needed. Ship partial coverage as English-in-every-cell rather
  than blank cells.
- Keep a `t(key, fallback)` helper anyway that returns the English literal if
  the lookup comes back empty, so a malformed CSV degrades to today's behaviour
  instead of drawing blank rows.

## 5. Interaction with the v1.3.1 font work

Localizing makes the panel's text wider, which is exactly the axis we just
spent v1.3.1 fixing. Two consequences:

- **Prerequisite met.** UTF-8-safe `fit_label` (v1.3.1) is what makes localized
  labels truncatable at all; before it, trimming a CJK label produced invalid
  UTF-8. Localization would have been unshippable without it.
- **The title is the risk.** `draw_panel` never truncates the title, and
  `panel_w` is `max(title, widest row) + padding`. German and Russian run long,
  CJK glyphs are wide, and under a non-pixel font we're already forced to scale
  1.0. A verbose translated title could push the panel wider than intended.
  Mitigations, in order of preference: keep translated titles short (the CSV
  has a `max length` column convention for exactly this); or allow the title to
  truncate like any other row.

Recommend re-running the Better Font and CJK checks from
`docs/TEST_PLAN_v1.3.1.md` after localizing — same two configurations, now with
long localized strings in them.

## 6. Open questions — verify before building

1. **Does `settings.lua` support `GameTextGet`?** The mod settings menu builds
   `ui_name` from a plain Lua table at load time. If the translation CSV isn't
   populated yet, or `GameTextGet` isn't available in that context, settings
   stay English. Test with one setting before converting all six. If it fails,
   the fallback is to leave the menu in English — acceptable, since it's
   configuration rather than gameplay text.
2. **Do empty cells in an *existing* row fall back to English?** Irrelevant if
   we follow §4 and fill every cell, which is why §4 is written that way.
3. **CSV escaping.** Our strings contain commas (`always: a, b, c`) and the
   format uses `\n` for newlines. Quote fields properly and verify the game
   parses the appended rows.
4. **Load order with other translation mods.** Read-then-append is safe, but
   worth one test alongside another mod that also extends `common.csv`.

## 7. Phasing

1. **Plumbing** — `OnModPreInit` CSV append, `t()` helper, one key
   (`sbv_panel_title`) end to end. Confirms mechanism and answers Q1/Q3 cheaply.
2. **Panel strings** — the six gameplay strings, English-only in all columns.
   No visible change; proves nothing regressed.
3. **zh-cn + jp** — the two languages we can verify in-game right now, using
   tier-1/tier-2 terminology.
4. **Settings menu** — only if Q1 resolves favourably.
5. **Remaining 7 languages** — community contributions. Add a
   `docs/TRANSLATING.md` with the key list and the "match the game's own
   wording" rule; the CSV format makes a pull request trivial to review.

Steps 1–3 are the shippable unit. Step 5 can arrive language by language.

## 8. Testing

- `tools/test_font_compat.lua` already drives the real `draw_panel` with
  multi-byte strings — extend its row fixtures with realistic localized labels
  so width and truncation stay covered.
- Add a CSV-shape test: every appended row has the right column count, no
  unescaped commas, no empty cells.
- In-game: the two configurations from §5, plus a German run (longest strings)
  once translations exist.

## 9. Recommendation

Do steps 1–3. The reuse strategy in §3 means the panel becomes correct in
Chinese and Japanese for very little translation work, and those are the two
languages tied to the font problem users actually reported — the same players
who hit the squished panel are the ones reading `cast 2` in an otherwise
Chinese UI. The remaining languages are a nice-to-have that can trickle in
without further engineering.
