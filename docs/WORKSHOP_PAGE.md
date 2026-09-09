# Workshop page — manual steps and current state

The Steam Workshop page is the one artifact that is **not** built from this repo
automatically. This file is the runbook, and the record of what was last done.

## The clobber problem (read first)

Noita's uploader pushes `workshop.xml`'s `description=` attribute to the
Workshop page **on every upload**, overwriting whatever is there. That attribute
is a single XML line, so it can never hold the real description (BBCode,
headings, images).

So after **every** Workshop upload:

1. Open the item → **Edit title & description**.
2. Paste `docs/workshop_description.bbcode` over what the upload left behind.
3. Save.

`workshop.xml`'s description is kept as a shortened version of the .bbcode lead
for exactly this reason: when the page gets clobbered, it should at least be
clobbered with the current message rather than a stale one. Keep the two in
sync when the lead changes.

## Release notes — v1.4.0 — 2026-09-08

Confidence tiers for spells (exact/approximate/uncertain), live spell table for mods, depleted spell modeling, fixed Add Trigger/Timer/Death Trigger grouping, corrected Greek chaining, mana cost tracking, and verification against Noita's own gun.lua.

Updated settings: Uncertain Wands: Slot Brackets (new), Ignore Depleted Spells (redefined), Greek Wands: Keep Depleted Spells (deprecated no-op). Updated Settings section, known limitations, and changelog in all docs.

## Description rewrite — 2026-08-24

Reordered around reader intent rather than feature list. What changed and why:

- The page used to open with "Lisp/SLIME-style", an analogy only programmers
  read, and never stated what the mod is **for** (learning how wands draw and
  group spells). A page that reads like a power tool gets measured against
  power tools — which is the frame behind the "why not just use WandDBG"
  Workshop comments.
- New order: who it's for → what the brackets mean, with a worked example →
  the wrap → **what this is and isn't** → known limits → settings → changelog.
- **"What this is, and what it isn't"** is the new section and the load-bearing
  one. It says plainly that this shows *structure*, not evaluation; names
  **WandDBG** as the complement for exact numbers; and states the method (the
  draw rules are read out of the game's own `gun.lua`) so "it's guessing" is
  not the reader's default assumption.
- Known limits moved up out of the footer — they are what a confused player
  needs *before* filing a report.
- v1.3.2 / v1.3.1 / v1.3.0 changelog sections condensed into one "Earlier
  updates" block, since Steam now carries its own per-update change notes. The
  **BourbonCrow** and **shinylavawarrior** credits were kept verbatim.

Two calls worth revisiting if they don't sit right:

- **WandDBG is named directly.** Sharper positioning, but it does put a rival
  mod's name on the page. Cutting it back to an implication is a one-line edit.
- The older changelog entries were **condensed, not preserved in full**. Git
  history has the originals if they should come back.

## Images — PENDING

Three `[img]` slots are in place in `docs/workshop_description.bbcode`, each
holding a placeholder token that must be swapped for a real URL:

| Token | Position | Shot to use |
| ----- | -------- | ----------- |
| `REPLACE_URL_1_SIMPLE_WAND` | after the intro | a **small** wand with obvious nesting — not the 26-spell one, which is impressive and unreadable |
| `REPLACE_URL_2_WRAP` | after the wrap section | the orange enclosure with the `wraps to front` tag |
| `REPLACE_URL_3_PANEL` | after "Two views" | the structure panel docked beside a wand |

To fill them:

1. Item page → **Add/edit images & videos** → upload the screenshots. (They
   appear in the carousel at the top of the page, which is worth doing on its
   own.)
2. Open each uploaded image, copy its direct URL — a
   `steamuserimages-*.akamaihd.net/...` link.
3. Replace the token; the `[img]...[/img]` tags are already around it.

**Test one first.** Steam's BBCode support differs between guides, profiles and
Workshop items, and `[img]` on item descriptions is the tag that varies most.
Preview before building a layout around it.

## Change notes (the uploader prompt)

`workshop_upload` asks for change notes as a single line, using `\n` for
newlines (same convention as `mod.xml`'s description). Avoid `"` — the prompt's
own example wraps the value in quotes — and avoid `&`, `<`, `>`. Plain text
only; BBCode belongs in the page description, not here.

## Release checklist

1. Merge to `main`, bump `VERSION` in `files/grouping_overlay.lua`.
2. `tools/make_release.sh` → `dist/spell_bracket_visualizer-<version>.zip`
   (version is read from `VERSION`, so it cannot drift).
3. `git push origin main`.
4. `gh release create <version> dist/<zip> --title "..." --notes-file <file>`.
5. Noita → mod menu → `workshop_upload` → change notes.
6. **Re-paste the description** (see the clobber problem above).
