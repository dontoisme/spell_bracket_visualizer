# Advanced scenarios plan — modded spells, Greeks, Add Trigger, mana

Response to the Workshop thread of Sep 2–3 (KoObEy's five points, Night's
"false results" report). The mod's own pitch has been "a teaching tool for
early-game wrapping"; this plan is what it takes to stop leaning on that and
to be *correct or explicitly silent* on every wand instead.

Everything here builds on what already exists: `wand_structure.lua` is a real
deck simulator, `structure_meta.lua` carries per-card draw facts, and the
`?` marking + shuffle-wand suppression already embody the right instinct
(hedge in text, never lie in brackets). Nothing gets rewritten; the
simulator grows three node kinds, the metadata gets a second (runtime)
source, and a confidence policy decides when the slot row stays blank.

Engine facts below are tagged **verified** (already checked against
`data.wak` for a shipped feature) or **VERIFY** (from memory of
`gun_actions.lua` / `gun.lua`; must be confirmed with the dump tool in §7
before code is written against them). Nothing tagged VERIFY should be
implemented from this document alone.

---

## 0. The feedback, mapped

| # | Who | Point | Where it lands |
|---|-----|-------|----------------|
| — | Night | modded modifiers / multicasts show as separate casts ("registers as projectile spells") | Track A (runtime metadata + probe) |
| 1 | KoObEy | a wand holding an unmodeled OTHER-type spell should get **no brackets at all** | Track C (confidence tiers) |
| 2 | KoObEy | learn what modded spells draw the way the game builds tooltips: empty shot state, execute, read back | Track A2 (the probe) |
| 3 | KoObEy | proper 0-charge logic | **Already shipped** (v1.2.6 → v1.3.0). One open verification, §4 D5 |
| 4 | KoObEy | Greeks etc. need a *stated definition* of what a bracket means; the four candidate definitions diverge | Track B (the definition) + Track D3 (Greek modeling) |
| 5 | KoObEy | mana: sum per cast vs. max mana, warn | Track E |

Point 3 is the easy win in the reply: KoObEy's "from the version I last
tried" predates 1.3.0. Ask them to retest with *Ignore Depleted Spells* on.

---

## 1. Track B — the definition (do this first; everything else hangs on it)

KoObEy's four readings of "the bracket around spell X contains Y":

1. Y was **drawn** during X's execution
2. Y was **executed** during X's execution
3. Y shares X's **shot state**
4. Y is **no longer in the deck** after X's execution

They coincide on ordinary wands and split exactly on the spells this plan
is about: a Greek *executes* a card it never *draws* (2 but not 1/4); Divide
By and Add Trigger *remove* a card they never `draw_actions()` (4 but not 1);
a trigger payload is *drawn and removed* but runs in its **own** shot state
(1, 4 but not 3); a depleted card is drawn and removed but never executed
(1, 4 but not 2).

The mod is a deck-stream visualizer, so the only definition it can honor
without simulating combat is **#4, consumption**:

> **A bracket encloses exactly the cards the engine removed from the deck
> while executing the bracket's head card. A cast bracket encloses the
> cards removed from the deck during one cast. A card a spell re-casts by
> reference (Alpha, Omega, …) is not removed, so it is never inside a
> bracket — the panel names it as a copy instead.**

Consequences, all of which are *features* of picking one definition:

- Trigger payloads stay nested (they are consumed by the trigger's forced
  draw). The bracket says "consumed here", not "fires now" — the panel's
  `trig` wording already carries the timing.
- Divide By stays a prefix (consumes the next card). Add Trigger becomes a
  prefix too (§4 D1).
- Greek spells get **no bracket to the card they copy**. What they *do*
  consume — the one card most of them force-draw afterwards, plus any cards
  the copied body itself force-draws — is bracketed under the Greek, because
  those cards really do leave the deck.
- The definition goes three places: `README.md` "How it works", the
  Workshop description ("What a bracket means"), and a one-line legend the
  panel can show (`[ ] = spells this card pulls from the wand`), reusing the
  sticky-footnote mechanism from the `?` legend.

Deliverable: text only, plus `docs/GROUPING_DESIGN.md` gets the definition
as its opening paragraph. Ship in the same release as Track C.

---

## 2. Track C — confidence tiers and the "no brackets" policy

Every card in a wand gets a **tier**, derived from its metadata record —
never from `ACTION_TYPE` alone (KoObEy's "OTHER that is not a note" is
really "OTHER whose body does something the simulator can't follow"; the
notes are structurally trivial leaves and should keep their brackets):

| tier | meaning | vanilla members |
|------|---------|-----------------|
| **exact** | the body's deck effects are fully captured by `draws` / `group` / `payload` / `chain` and are deterministic | every PROJECTILE / STATIC_PROJECTILE / MATERIAL leaf; every draws=1 MODIFIER / PASSIVE / UTILITY; every DRAW_MANY; trigger projectiles; DIVIDE_* (once D2 lands); ADD_TRIGGER family (once D1 lands); KANTELE_* / OCARINA_* notes; any OTHER/UTILITY whose body draws nothing (CESSATION, SUMMON_PORTAL, X_RAY, TEMPORARY_WALL, ALL_* …) |
| **approximate** | modeled, but position- or state-dependent: shown with `?` | the 8 Greeks (D3); IF_* requirement spells; RESET and ALL_SPELLS until their bodies are checked (§7) |
| **unknown** | no usable record: a mod spell the probe could not classify, or a probe error | anything not in `structure_meta.lua` and not probed |

Policy (new setting, `uncertain_brackets`, enum):

- **Hide (default)** — a wand containing any *unknown* card, or any
  *approximate* card, draws **no slot brackets**. A small dim `?` glyph at
  the right end of the slot row says why the row is blank (so "no brackets"
  reads as *uncertain*, not *broken*). The panel still draws the tree with
  `?` marks and the footnote names the spells responsible:
  `? = Alpha, Unknown Modded Spell: structure uncertain`.
- **Show** — brackets drawn anyway, `?` marks in the panel as today. For
  players who want the approximation and know what it is.

This is KoObEy's point 1 verbatim, generalized so it also covers mods
(Night's case) and future unknowns without a hand-maintained exception list.
The shuffle-wand suppression stays a separate, absolute rule.

Implementation notes:

- `wand_structure.lua`: `M.tier(meta_record)` (pure) and `M.wand_tier(ids, meta)`
  → `"exact" | "approximate" | "unknown"` with the offending ids. Tested
  in `tools/test_wand_structure.lua`.
- `grouping_overlay.lua`: `collect_wand_boxes` stamps `wd.tier`;
  `draw_box_brackets` checks it next to the shuffle check; `sim_rows`
  extends the existing `any_dynamic` footnote into a named list.
- Debug Info box: print the wand's tier and the offending ids.

---

## 3. Track A — runtime spell metadata (the modded-spell fix)

Today `meta_for()` returns `{ type = "OTHER" }` for any id not in
`structure_meta.lua`, so a modded modifier is a leaf that ends its cast and
a modded multicast gathers nothing — exactly Night's "multiple casts when
there is only one". Two layers fix it; the second is KoObEy's suggestion.

### A1 — read the game's live `actions` table (cheap, do first)

Every spell the game knows, including every spell other mods appended via
`ModLuaFileAppend("data/scripts/gun/gun_actions.lua", …)`, is an entry in
the global `actions` table produced by `dofile_once("data/scripts/gun/gun_actions.lua")`
(after `gun_enums.lua` for the `ACTION_TYPE_*` constants). Load it lazily
on the first `M.update()` (all mods have finished appending by then), inside
the usual `pcall`, and build `runtime_meta[id] = { type, name, mana, max_uses, related_projectiles ~= nil }`.

Merge order for `meta_for(id)`: **probe result (A2) > structure_meta.lua >
type-only fallback from A1 > `{type="OTHER"}`**. The type-only fallback:

| runtime `type` | assumed record | tier |
|----------------|----------------|------|
| MODIFIER, PASSIVE | `draws=1` | approximate (until probed) |
| DRAW_MANY | unknown count | unknown |
| PROJECTILE / STATIC_PROJECTILE / MATERIAL | leaf | approximate (could be a trigger) |
| UTILITY / OTHER | leaf | unknown |

A1 alone already turns most modded modifiers from "cast boundary" into
"prefix", which is the bulk of Night's complaint. The `name` field also
gives modded spells localized panel labels for free, and `mana` feeds Track E.

`structure_meta.lua` stays: it is the offline test fixture and the fallback
when the runtime read fails, and the generator should start emitting `mana=`
so the mana tests run without the game.

### A2 — the probe: execute each unknown spell in a stub shot state

KoObEy's observation is right and it is how the engine itself works:
`gun.lua` keeps a global `reflecting`, and every action body in
`gun_actions.lua` wraps its world side effects (entity loads, GamePrint,
material spawns) in `if not reflecting then … end` so the tooltip pass can
run the body harmlessly. Well-behaved modded spells honor it too, because
their tooltips go through the same pass.

So: for each id not fully described by `structure_meta.lua`, run
`actions[i].action()` **once, in a sandbox, with `reflecting = true`**, and
record what it did to the deck. The record *is* the metadata — no regex,
no guessing from type.

The sandbox (`files/action_probe.lua`, pure Lua, no game API so it runs
under `lua5.1`/`5.4` in the tools):

- **Globals the body sees** (via `setfenv` on the function when available,
  otherwise a plain global swap guarded by "only if `draw_actions == nil`
  in this VM", see §7): `deck`, `hand`, `discarded` (stub cards),
  `c` and `shot_effects` (tables with a `__index` that returns `0` for any
  unknown field, so `c.damage = c.damage + 1` and `c.extra_entities .. "x,"`
  both work), `reflecting = true`, `recursion_level = 0`, `mana = 1e9`,
  `current_reload_time`, `ACTION_TYPE_*` constants, the Lua stdlib, and
  **every uppercase-initial global (engine API) replaced by a no-op that
  returns 0** except a short allowlist (`Random`, `SetRandomSeed`,
  `GameGetFrameNum` → 0, `GetUpdatedEntityID` → 0, `EntityGetTransform` → 0,0).
- **Stubbed gun.lua functions, each recording**: `draw_actions(n, forced)`
  (records `n`; `n == #deck` at call time ⇒ `-1`; pops `n` stub cards to
  `hand`), `draw_shot`/`create_shot` and the three
  `add_projectile_trigger_*` (record `{ trigger = kind, payload = n }`,
  do **not** recurse), `add_projectile`, `check_recursion` (returns
  `recursion_level + 1`), `move_discarded_to_deck`, `order_deck`,
  `set_current_action`, `register_action`, `play_action`, `Reflection_*`.
- **Stub cards** are 16 dummies `{ id = "__PROBE_k", type = PROJECTILE, deck_index = k, uses_remaining = -1, action = <records "recast k"> }`.
  Their `action` recording is what detects a Greek-style re-cast by
  reference; the deck shrinking *without* a `draw_actions` call is what
  detects direct consumption (Divide By, Add Trigger, and any modded
  look-alike). The probe is run with `deck[1].type` set to each of
  PROJECTILE / MODIFIER / OTHER in turn so type-conditional bodies (Add
  Trigger only consumes a projectile) are seen both ways.
- **Determinism**: run 3× with different `SetRandomSeed`; a differing record
  ⇒ `dynamic = "random"`. Guard: the `draw_actions` stub errors after 64
  calls (a runaway loop against our stub deck terminates instead of hanging).
- **Any error** ⇒ the id is cached as `unknown` and never probed again this
  session (so a hostile or sloppy modded spell costs one `pcall`, once).
  Everything runs from `OnWorldPostUpdate` while the inventory is open, never
  inside a cast, and never touches the real gun state — the mod's Lua VM does
  not hold `gun.lua` (§7 confirms).

Record produced, superset of today's fields:

```lua
{ type, name, mana,
  draws = n | -1,            -- forced draws (draw_actions)
  consumes = n,              -- cards removed from deck[1] directly (no forced draw)
  consumes_type = "PROJECTILE" | nil,   -- only when deck[1] is of that type
  repeats = n,               -- times the consumed card's body was invoked (Divide)
  recasts = { "hand[1]" | "deck[last]" | "deck[1..2]" | "all" | … },
  trigger = kind, payload = n,
  dynamic = "random" | nil }
```

`chains()` / `is_multicast()` in `wand_structure.lua` keep working on the
same `draws`/`chain`/`payload` fields; `consumes`, `repeats`, `recasts` are
new and drive D1–D3.

### A3 — the probe as a regression test for the vanilla table

`tools/dump_gun_actions.py` (reuse the wak reader in `gen_structure_meta.py`)
writes `gun_actions.lua` to a scratch dir; `tools/probe_actions.lua` loads
it with `action_probe.lua` and prints a record for all 422 vanilla ids;
`tools/test_probe_vs_meta.lua` diffs that against `structure_meta.lua`.
Every disagreement is either a regex miss in the generator (ADD_TRIGGER,
§4 D1, is the known one) or a probe bug — both worth knowing before the
probe is trusted on other people's spells. Once they agree, the generator
can be *replaced* by the probe (`gen_structure_meta.py` → thin wrapper), and
the Python cross-check mirror `test_wand_structure.py` should be retired
rather than taught the new node kinds twice.

### A4 — settings and debug

- `probe_modded_spells` (default on): A2 on/off. With it off, A1's
  type-only fallback applies and those wands are *approximate* → no
  brackets under the default policy.
- Debug Info box: for the held wand, one line per card: `id  tier  src=meta|runtime|probe  draws/consumes/payload`.
  That is the screenshot that makes a modded-spell bug report actionable.

---

## 4. Track D — specific vanilla spells

### D1 — Add Trigger / Add Timer / Add Death Trigger (**likely a live bug**)

`structure_meta.lua` records them as `trigger=…, payload=1` with no
`draws`, so the simulator makes the Add Trigger card itself a trigger head
whose payload is the **next** card — for `ADD_TRIGGER, SPARK, BOMB` it draws
`(ADD_TRIGGER SPARK) BOMB`: Spark as the payload, Bomb in a new cast.

VERIFY: the body peeks `deck[1]`; if it is a PROJECTILE with
`related_projectiles`, it spawns that projectile itself as a trigger via
`add_projectile_trigger_hit_world(file, 1)` (which force-draws the 1-card
payload) and moves `deck[1]` to `discarded` **without** `draw_actions()`;
otherwise it does nothing and consumes nothing. If confirmed, the correct
structure is `(ADD_TRIGGER→SPARK BOMB)`: prefix on Spark, Bomb nested as the
payload, and — like Divide — an Add Trigger at the end of the wand does
nothing and cannot wrap, while the *payload* draw is forced and can.

Fix: meta `consumes=1, consumes_type="PROJECTILE", trigger="hit_world", payload=1`
(the probe in A2 produces exactly this); simulator: a `consumes` head reads
the next card without a forced draw, requires the type, then opens its
payload. Tests: the three cases above plus "Add Trigger before a modifier
does nothing", "trailing Add Trigger does not wrap", "payload wraps".

### D2 — Divide By followed by a multicast or trigger

Known limitation in the README: the divided card is invoked N times and
each invocation draws *fresh* cards. `DIVIDE_2, BURST_2, A, B, C, D` is one
expression `(DIVIDE_2 (BURST_2 A B) (BURST_2 C D))`. With `repeats=N` in
meta (VERIFY N: 2/3/4/10 — and whether the last invocation on an exhausted
deck wraps, since the *inner* `draw_actions` is forced even though Divide's
own read is not), `parse_expr` runs the consumed card's body `repeats`
times, collecting each invocation's children as siblings. Tier: exact.
Tests: the example above; divide → trigger; divide → divide; divide →
multicast at wand end (wrap inside repeat 2).

### D3 — the Greeks

Current model: draws=1 chaining cards, and `has_greek()` disables the
depleted filter. Under the Track B definition they become **recast nodes**:

- Panel: `Alpha ⇒ copy of Light Bullet` as a dim row under the Greek, no
  bracket bars of its own; if the copied card has `draws`/`payload`, its
  forced draws are real consumption and appear as bracketed children of the
  Greek's head (`Alpha ⇒ copy of Double Spell` then two consumed cards).
- Slot row: the copied card gets no bracket; the consumed cards do.
- Which card each Greek copies (VERIFY, and this is what decides the tier):
  Alpha `hand[1]` (first card drawn *this cast*, which is the wand's first
  card only on the first cast of a cycle), Gamma `deck[#deck]` (last card
  *still in the deck*, not the wand's last slot), Tau `deck[1]`,`deck[2]`,
  Omega every card in deck+hand+discarded, Mu / Phi / Sigma the same
  filtered by type, Zeta a random spell not on the wand. The simulator
  already tracks `hand`/`deck`/`discard` per cast, so the *static* answer
  for each cast is computable; it stays **approximate** because the piles
  depend on where the cycle is when the player fires.
- Zeta: `dynamic="random"`, `?`, never bracketed.

Ship D3 after A2, since the probe's `recasts` field is how the reference
rule gets recorded and cross-checked against the source dump.

### D4 — IF_* requirement spells

Stay `?` / approximate. A later option is to simulate both branches and
show the false-branch skip as a greyed span; not in this plan.

### D5 — depleted-card verification (KoObEy point 3)

Shipped rule (`card_fires`, v1.3.0): a 0-use card is dropped before
simulation, "as if the slot were empty". One VERIFY before claiming
"proper": in `gun.lua`, does `draw_actions(N)` **retry** after a depleted
card (so the card costs nothing) or **count it as one of the N** (so
`BURST_2, DEPLETED, A, B` gathers only A)? The repo comment says retry; if
it is instead counted, a depleted card is a *consumed blank*, which the
simulator can model as a node kind `spent` (bracketed, greyed) rather than
being filtered out. Also confirm the mana-discard path (§5) uses the same
mechanism, since the answer applies to both.

---

## 5. Track E — mana

Engine rule (VERIFY the retry-vs-count question with D5): a card the wand
cannot afford is drawn and discarded without executing, and drawing goes on
— so a mana shortfall shifts everything after it, and, as KoObEy says,
"allows later wrapping".

### E1 — per-cast mana total vs. max mana (ship with 1.4)

`mana` per card from A1's runtime table (vanilla fallback: emit `mana=` in
`structure_meta.lua`). `simulate` already knows every card each cast
consumed (its `hand` → the cast's slot spans); sum `mana` over them plus the
always-cast cards, store `cast.mana`. Wand `mana_max` from
`AbilityComponent` (`mana_max`, `mana_charge_speed`, current `mana` are all
readable next to `gun_config`).

Panel: cast header gains `  mana 210` and, when `cast.mana > mana_max`,
turns warning-colored with `> max 150` — a cast that costs more than the
wand can ever hold *never* fires as drawn. Footnote:
`mana = cost of this cast; > max means part of it will be discarded`.
Debug box: the per-cast totals and the wand's mana fields.

This is exactly KoObEy's middle ground: always true as a statement, never
pretends to know the current pool.

### E2 — optional "assume full mana" discard simulation (later)

Setting off by default. Simulate each cast with the pool at `mana_max`
(or the live `mana` — but that flickers as it regenerates, so full pool is
the honest static choice): the first card whose cost exceeds the remaining
pool is discarded blank, later cheaper cards may still fire, and the
resulting shifts and wraps are drawn with `?`. Needs D5's answer for how a
discarded card counts toward a multicast.

---

## 6. Release slicing

**v1.4.0 — "honest brackets"** (all vanilla, all testable offline):
Track B (definition, three places) · Track C (tiers, `uncertain_brackets`,
the `?` slot glyph, named footnote) · D1 Add Trigger fix · D5 verification
(and the `spent` node if it turns out to count) · E1 mana totals · A1
runtime table read (modded modifiers become prefixes; modded unknowns hide
brackets). This answers KoObEy 1, 3, 4, 5 and gives Night a correct, if
conservative, result immediately. Workshop post before release, as promised
in the thread, with the definition as its centerpiece.

**v1.5.0 — "modded spells"**: A2 probe · A3 probe-vs-meta test (retire the
Python mirror) · A4 settings/debug · D2 Divide repeats · D3 Greek recast
nodes. Ask Night for the mod list they play with and test against those
spells specifically.

**Later**: E2, D4.

Test discipline stays as it is: every simulator change lands with cases in
`tools/test_wand_structure.lua` (Lua 5.1-compatible code, run under whatever
`lua` the machine has — there is none in this remote environment, so the
suite runs locally), slot-row behavior in `tools/test_slot_delims.lua`, and
`tools/preview_wand.lua` gains `--tier` and `--mana` flags so a reported
wand can be reproduced from its spell list without the game.

---

## 7. Verification list (needs the game / `data.wak`; do before coding)

1. `tools/dump_gun_actions.py`: extract `gun_actions.lua` and `gun.lua` to
   the scratch dir (the wak reader already exists). Then read:
   - ADD_TRIGGER / ADD_TIMER / ADD_DEATH_TRIGGER bodies (D1)
   - DIVIDE_* bodies: repeat counts, and whether the consumed card is moved
     to `discarded` or `hand` (D2)
   - ALPHA / GAMMA / TAU / OMEGA / MU / PHI / SIGMA / ZETA: which pile and
     index each reads, and which of them call `draw_actions(1, true)` (D3)
   - RESET, ALL_SPELLS, SUMMON_PORTAL, CESSATION: any deck effect? (tiering)
   - `gun.lua` `draw_action` / `draw_actions`: depleted-card and
     insufficient-mana handling — retry or count (D5, E)
   - `gun.lua` tooltip / `reflecting` pass: which globals it sets up
     (the probe should mirror that setup, not invent one)
2. In-game, in this mod's VM: is `setfenv` available under
   `request_no_api_restrictions="0"`? Is `draw_actions` nil (i.e. the mod's
   Lua state does not share `gun.lua`'s globals)? Does
   `dofile_once("data/scripts/gun/gun_actions.lua")` from `OnWorldPostUpdate`
   return a table that includes another mod's appended spells? (Test with
   any spell-adding mod from the Workshop.)
3. Are `mana_max` / `mana_charge_speed` / `mana` readable on the wand's
   `AbilityComponent` with `ComponentGetValue2` (expected yes; same
   component as `gun_config`).

---

## 8. Thread reply, short form

- Thanks; the definition question (4) is the real one and the answer is
  "consumed from the deck" — brackets will be documented to mean that and
  nothing more.
- 0-charge handling (3) shipped in 1.3.0 — please retest.
- Next release: wands with a spell the mod can't follow get no brackets and
  a `?`, Add Trigger grouping fixed, per-cast mana vs. max shown.
- Release after: modded spells classified by running them in a stub shot
  state with `reflecting` on, as suggested; Greeks shown as copies with
  their real draws bracketed. Will post the design before shipping.
