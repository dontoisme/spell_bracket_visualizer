#!/usr/bin/env python3
"""Extract per-spell structural metadata from Noita's gun_actions.lua.

The cast engine (data/scripts/gun/gun.lua) builds a wand's shot by popping
cards off one flat deck in order. Structure comes from two mechanisms:

  * DRAW_MANY cards (multicast) call draw_actions(N) -> the next N drawn cards
    join the same shot as a group.
  * Trigger/timer projectiles call add_projectile_trigger_*(entity, [delay,]
    count) -> draw_shot(create_shot(count)), a NESTED sub-shot of `count`
    cards drawn as the trigger payload.
  * Modifiers mutate shot state -> they prefix-attach to the next projectile.

So a wand's deck parses like a Lisp token stream: multicast/trigger counts
introduce sub-expressions. This script captures, per action id:
    type   - ACTION_TYPE_* (PROJECTILE/MODIFIER/DRAW_MANY/...)
    group  - N, for DRAW_MANY multicast cards (how many siblings they gather)
    payload/trigger - N + kind, for trigger projectiles (nested sub-shot size)

Output: files/structure_meta.lua (a Lua table the mod loads at runtime).
Pure stdlib. Run from anywhere; paths derive from this file's location.
"""
import struct, re, os, sys

MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAK = (sys.argv[1] if len(sys.argv) > 1 else
       os.environ.get("NOITA_WAK",
       os.path.normpath(os.path.join(MOD, "..", "..", "data", "data.wak"))))
OUT = os.path.join(MOD, "files", "structure_meta.lua")


def read_gun_actions():
    buf = open(WAK, "rb").read()
    count = struct.unpack_from("<I", buf, 4)[0]
    pos = 16
    for _ in range(count):
        off, size, plen = struct.unpack_from("<III", buf, pos); pos += 12
        name = buf[pos:pos+plen].decode("utf-8", "replace"); pos += plen
        if name == "data/scripts/gun/gun_actions.lua":
            return buf[off:off+size].decode("utf-8", "replace")
    raise SystemExit("gun_actions.lua not found in wak")


# Structural facts the regexes below cannot see, merged over the parsed data.
#
# chain=True -- attaches to the next card WITHOUT a forced draw. The DIVIDE_*
#   bodies read deck[1] and invoke its action directly (data.action(...)),
#   never calling draw_actions(), so the draws-regex finds nothing; yet in
#   play "Divide By N" casts the next spell with itself, exactly like a
#   modifier prefix. Unlike a modifier's draw_actions(1, true), an empty deck
#   means divide simply does nothing: NO wrap, no reload.
#
# dynamic="conditional" -- the IF_* requirement spells skip part of the deck
#   (up to the matching IF_ELSE / IF_END) when their condition is false at
#   cast time, so the static structure is only the condition-true path.
# dynamic="random" -- these draw/cast additional cards chosen at random at
#   cast time; no static structure exists for what they add.
OVERRIDES = {
    # scan=True -- the Add Trigger family. The draws/trigger regexes below see
    # `add_projectile_trigger_hit_world(target, 1)` in these bodies and conclude
    # "trigger head, 1-card payload drawn from the next slot". That is wrong in
    # three ways, and produced the mis-grouping this override fixes:
    #   * the body first scans FORWARD past MODIFIER/PASSIVE/OTHER/DRAW_MANY
    #     cards (running each modifier inline against the trigger projectile)
    #     and consumes the WHOLE scan plus the projectile it lands on -- a
    #     variable number of cards, removed directly with no forced draw;
    #   * the payload size is the TARGET's related_projectiles[2] (`rp` below),
    #     not the literal 1 in the trigger call, which is repeated rp times;
    #   * if no projectile-ish card remains in the deck afterwards, the body
    #     casts the card plainly and spawns no trigger at all.
    # `trigger` is kept (the kind); `payload` is dropped, since it comes from
    # the target card at simulate time. See wand_structure.lua's scan branch.
    "ADD_TRIGGER":       {"scan": True, "trigger": "hit_world"},
    "ADD_TIMER":         {"scan": True, "trigger": "timer"},
    "ADD_DEATH_TRIGGER": {"scan": True, "trigger": "death"},
    # consumes="rest" -- RESET. Its body (gun_actions.lua:10439) calls no
    # draw_actions at all, so the draws-regex sees nothing and the card would
    # read as a plain UTILITY leaf. What it actually does is move EVERY card in
    # `hand` and in `deck` to `discarded` and empty both -- direct removal, no
    # forced draw, so it can never wrap for a card. Under the bracket definition
    # (docs/ADVANCED_SCENARIOS_PLAN.md Sec.0.1) that makes its bracket the whole
    # remaining deck. The tail of the body is the part Sec.4 D6 missed and the
    # differential harness found: unless `force_stop_draws` is already set it
    # sets it and calls move_discarded_to_deck() + order_deck(), so the deck
    # comes straight back FULL, in slot order. See wand_structure.lua's
    # consumes=="rest" branch for what that means for the cast.
    "RESET":     {"consumes": "rest"},
    "DIVIDE_2":  {"chain": True},
    "DIVIDE_3":  {"chain": True},
    "DIVIDE_4":  {"chain": True},
    "DIVIDE_10": {"chain": True},
    # tier="approximate": modeled, but position- or state-dependent at cast
    # time (docs/ADVANCED_SCENARIOS_PLAN.md Sec.2). IF_END is deliberately
    # excluded below: it is a plain draws=1 card with no branch of its own.
    "IF_ELSE":       {"dynamic": "conditional", "tier": "approximate"},
    "IF_END":        {"dynamic": "conditional"},
    "IF_ENEMY":      {"dynamic": "conditional", "tier": "approximate"},
    "IF_HALF":       {"dynamic": "conditional", "tier": "approximate"},
    "IF_HP":         {"dynamic": "conditional", "tier": "approximate"},
    "IF_PROJECTILE": {"dynamic": "conditional", "tier": "approximate"},
    "DRAW_RANDOM":     {"dynamic": "random", "tier": "approximate"},
    "DRAW_RANDOM_X3":  {"dynamic": "random", "tier": "approximate"},
    "DRAW_3_RANDOM":   {"dynamic": "random", "tier": "approximate"},
    "RANDOM_SPELL":    {"dynamic": "random", "tier": "approximate"},
    # RANDOM_MODIFIER's body picks a random MODIFIER action and calls its
    # `.action()` directly -- it never calls draw_actions() itself, so the
    # draws-regex finds nothing here. But nearly every MODIFIER body ends
    # with draw_actions(1, true), so in play the picked modifier pulls in
    # the next card anyway -- confirmed by test_gun_differential.lua running
    # this against the real gun.lua three times with three different random
    # picks, all of which chained. Which modifier is picked is random (so
    # this is not knowable exactly), but "chains" is right in nearly every
    # case, unlike terminating the chain, which is wrong in nearly every case.
    "RANDOM_MODIFIER": {"draws": 1, "dynamic": "random", "tier": "approximate"},
    # ALPHA/GAMMA/TAU copy a card live (position-dependent); OMEGA/PHI/MU/SIGMA
    # copy a whole class with copies suppressed -- both are "approximate" per
    # the plan's tier table (Sec.2, D3 classes 1 and 2).
    "ALPHA": {"tier": "approximate"},
    "GAMMA": {"tier": "approximate"},
    "TAU":   {"tier": "approximate"},
    "OMEGA": {"tier": "approximate"},
    "PHI":   {"tier": "approximate"},
    "MU":    {"tier": "approximate"},
    "SIGMA": {"tier": "approximate"},
    # ZETA reads the player's OTHER wands and seeds RNG from position + frame
    # number: unknowable statically (D3 class 3), unlike RANDOM_MODIFIER/
    # RANDOM_SPELL/etc, which at least pick from this wand's own deck/actions.
    "ZETA": {"tier": "unknown"},
}


# ACTION_MANA_DRAIN_DEFAULT from gun.lua:5 -- the cost the engine charges any
# card whose body doesn't set `mana` (see docs/ADVANCED_SCENARIOS_PLAN.md Sec.5).
DEFAULT_MANA = 10


def strip_line_comments(text):
    # Drop `--` line comments (to end of line) so a commented-out
    # draw_actions()/add_projectile_trigger_*() call isn't mistaken for a
    # live one. ALPHA/GAMMA/TAU's bodies end with a commented-out
    # `--draw_actions( 1, true )` (a leftover from when they used to chain);
    # without this, the generator read that dead line and wrongly emitted
    # draws=1, making all three chain onto the next card in the mod when the
    # game does not (confirmed by tools/test_gun_differential.lua against the
    # real gun.lua). Naive `--.*$` would also eat a `--` that appears INSIDE a
    # string literal, but `grep -c '"[^"]*--[^"]*"' .gun_ref/.../gun_actions.lua`
    # finds zero such strings in the whole file, so a per-line strip after the
    # first `--` is exact here, not just a heuristic.
    return re.sub(r'--.*$', '', text, flags=re.M)


def parse(src):
    # Drop block comments so commented-out template actions are ignored.
    src = re.sub(r'--\[\[.*?\]\]', '', src, flags=re.S)
    marks = [(m.start(), m.group(1)) for m in re.finditer(r'\bid\s*=\s*"([^"]+)"', src)]
    out = {}
    for i, (st, aid) in enumerate(marks):
        end = marks[i+1][0] if i+1 < len(marks) else len(src)
        body = src[st:end]
        code = strip_line_comments(body)
        t = re.search(r'\btype\s*=\s*(ACTION_TYPE_\w+)', body)
        typ = t.group(1).replace("ACTION_TYPE_", "") if t else "OTHER"
        rec = {"type": typ}
        nm = re.search(r'\bname\s*=\s*"([^"]*)"', body)
        if nm:
            rec["name"] = nm.group(1)
        # How many extra cards this action force-draws (draw_actions(N, true)).
        # This, not the action type, is what makes a card chain or multicast:
        # all PASSIVEs and almost all MODIFIERs draw 1 (RANDOM_MODIFIER doesn't),
        # and some OTHER/UTILITY cards (I_SHOT, ...) draw 1 too.
        # BURST_X draws #deck (the whole remaining deck) -> encoded as -1.
        # Matched against `code` (comments stripped) -- see strip_line_comments.
        dm = re.search(r'draw_actions\(\s*(\d+|#deck)', code)
        if dm:
            rec["draws"] = -1 if dm.group(1) == "#deck" else int(dm.group(1))
        if typ == "DRAW_MANY" and rec.get("draws"):
            rec["group"] = rec["draws"]
        tg = re.search(r'add_projectile_trigger_(timer|hit_world|death)\([^)]*?(\d+)\s*\)', code)
        if tg:
            rec["trigger"] = tg.group(1)
            rec["payload"] = int(tg.group(2))
        # related_projectiles = {"file.xml"[, N]} -- N is how many trigger
        # projectiles the Add Trigger family spawns off this card, each drawing
        # a 1-card payload, so it is also this card's payload size when it is
        # the scan target. Absent second element means 1.
        rp = re.search(r'related_projectiles\s*=\s*\{\s*"[^"]*"\s*(?:,\s*(\d+)\s*)?\}', body)
        if rp:
            rec["rp"] = int(rp.group(1)) if rp.group(1) else 1
        # Mana cost (gun.lua:236: `action.mana or ACTION_MANA_DRAIN_DEFAULT`).
        # Emitted for EVERY id, defaulting to 10 when the field is absent, so
        # downstream mana math (Sec.5) never has to special-case a missing field.
        mn = re.search(r'\bmana\s*=\s*(-?\d+(?:\.\d+)?)', code)
        if mn:
            val = float(mn.group(1))
            rec["mana"] = int(val) if val.is_integer() else val
        else:
            rec["mana"] = DEFAULT_MANA
        rec.update(OVERRIDES.get(aid, {}))
        if rec.get("scan"):
            # the trigger call inside the scan body is not this card's payload
            rec.pop("payload", None)
        out[aid] = rec
    return out


def to_lua(meta):
    def fmt(rec):
        parts = ['type="%s"' % rec["type"]]
        if "name" in rec:    parts.append('name="%s"' % rec["name"])
        if "draws" in rec:   parts.append("draws=%d" % rec["draws"])
        if "group" in rec:   parts.append("group=%d" % rec["group"])
        if "payload" in rec: parts.append('trigger="%s", payload=%d' % (rec["trigger"], rec["payload"]))
        if "scan" in rec:    parts.append('trigger="%s", scan=true' % rec["trigger"])
        if "rp" in rec:      parts.append("rp=%d" % rec["rp"])
        if "chain" in rec:   parts.append("chain=true")
        if "consumes" in rec: parts.append('consumes="%s"' % rec["consumes"])
        if "dynamic" in rec: parts.append('dynamic="%s"' % rec["dynamic"])
        if "tier" in rec:    parts.append('tier="%s"' % rec["tier"])
        if "mana" in rec:
            m = rec["mana"]
            parts.append("mana=%d" % m if isinstance(m, int) else "mana=%s" % m)
        return "{ " + ", ".join(parts) + " }"
    lines = [
        "-- AUTO-GENERATED by tools/gen_structure_meta.py. Do not edit by hand.",
        "-- Per-spell structural metadata used to parse a wand's deck into a tree.",
        "-- type: PROJECTILE/STATIC_PROJECTILE/MODIFIER/DRAW_MANY/MATERIAL/UTILITY/PASSIVE/OTHER",
        "-- draws: how many cards the action force-draws (1 = chains like a",
        "--        modifier; >=2 = multicast; -1 = the whole remaining deck).",
        "-- group: multicast draw count (DRAW_MANY). trigger/payload: nested sub-shot.",
        "-- scan: the Add Trigger family -- steps forward over MODIFIER/PASSIVE/OTHER/",
        "--        DRAW_MANY cards, consumes the whole scan plus the projectile it",
        "--        lands on (directly, no forced draw, so it never wraps), then draws",
        "--        that card's rp payloads. No trigger at all if no projectile-ish",
        "--        card is left in the deck.",
        "-- rp: related_projectiles count -- payload size when this card is the",
        "--        target of a scan; also marks the card as able to carry a trigger.",
        "-- chain: attaches to the next card with NO forced draw (DIVIDE_*: an",
        "--        empty deck means it does nothing -- never wraps).",
        '-- consumes: cards removed from the deck DIRECTLY, with no forced draw.',
        '--        "rest" (RESET) = the entire remaining deck, which the body then',
        "--        hands straight back as a full deck in slot order.",
        '-- dynamic: "conditional" (IF_*: skips deck cards when false at cast time)',
        '--        or "random" (casts extra cards chosen at random at cast time).',
        '-- tier: "approximate" (position/state-dependent -- Greeks, IF_* branches,',
        '--        the DRAW_RANDOM/RANDOM_* family) or "unknown" (ZETA: reads other',
        "--        wands, unknowable statically). Omitted means exact.",
        "-- mana: this card's mana cost (gun.lua's action.mana), defaulting to 10",
        "--        (ACTION_MANA_DRAIN_DEFAULT) when the body doesn't set it. Always",
        "--        present.",
        "return {",
    ]
    for aid in sorted(meta):
        lines.append('\t["%s"] = %s,' % (aid, fmt(meta[aid])))
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    meta = parse(read_gun_actions())
    open(OUT, "w").write(to_lua(meta))
    n_group = sum("group" in r for r in meta.values())
    n_trig = sum("payload" in r for r in meta.values())
    n_scan = sum("scan" in r for r in meta.values())
    n_rp = sum("rp" in r for r in meta.values())
    n_approx = sum(r.get("tier") == "approximate" for r in meta.values())
    n_unknown = sum(r.get("tier") == "unknown" for r in meta.values())
    n_consumes = sum("consumes" in r for r in meta.values())
    n_mana = sum("mana" in r for r in meta.values())
    n_mana_default = sum(r.get("mana") == DEFAULT_MANA for r in meta.values())
    print(f"wrote structure_meta.lua: {len(meta)} actions "
          f"({n_group} multicast, {n_trig} trigger, {n_scan} scan, {n_rp} rp, "
          f"{n_consumes} direct-consume, "
          f"{n_approx} approximate, {n_unknown} unknown, "
          f"{n_mana} mana ({n_mana_default} at default {DEFAULT_MANA}))")


if __name__ == "__main__":
    main()
