#!/usr/bin/env python3
"""Python mirror of files/wand_structure.lua + hand-traced test wands.

CROSS-CHECK only. tools/test_wand_structure.lua is now the PRIMARY test --
it runs the real wand_structure.lua under Lua. This file re-implements the
simulator line-for-line (same draw/wrap/chain rules, same node shapes) as an
independent second opinion: a divergence shows up as one harness passing and
the other failing. If you change wand_structure.lua, change simulate() here to
match and re-run BOTH:

    lua tools/test_wand_structure.lua   # real source (primary)
    python3 tools/test_wand_structure.py

(The mirror is slated to be retired in a later release once the Lua harness is
fully trusted; until then keep the two in sync.) It loads per-card metadata
from the real generated files/structure_meta.lua, so it also catches generator
regressions.
"""
import os, re, sys

MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_meta():
    src = open(os.path.join(MOD, "files", "structure_meta.lua")).read()
    meta = {}
    for m in re.finditer(r'\["([^"]+)"\] = \{ ([^}]*) \},', src):
        rec = {}
        body = m.group(2)
        for k, v in re.findall(r'(\w+)=("[^"]*"|-?\d+)', body):
            rec[k] = v.strip('"') if v.startswith('"') else int(v)
        meta[m.group(1)] = rec
    assert len(meta) > 400, "structure_meta.lua parse failed"
    return meta


# ---- mirror of wand_structure.lua ------------------------------------------

def meta_for(meta, aid):
    return meta.get(aid, {"type": "OTHER"})


def card_fires(uses_remaining):
    # Mirror of M.card_fires: a 0-use card is depleted (won't fire); -1/-2/>0 keep.
    return uses_remaining != 0


# Mirror of M.GREEK_SPELLS / M.has_greek: the 8 Greek alphabet spells re-cast cards
# by position, so a wand containing any of them keeps depleted cards (filter off).
GREEK_SPELLS = {"ALPHA", "GAMMA", "TAU", "OMEGA", "MU", "PHI", "SIGMA", "ZETA"}


def has_greek(ids):
    return any(i in GREEK_SPELLS for i in ids)


def chains(m):
    return m.get("draws") == 1 and "payload" not in m and m["type"] != "DRAW_MANY"


def is_multicast(m):
    d = m.get("draws")
    return d is not None and (d >= 2 or d == -1)


def simulate(tokens, meta, spells_per_cast=None):
    spc = spells_per_cast
    if spc is not None and spc < 1:
        spc = 1

    deck = [{"i": i + 1, "id": aid} for i, aid in enumerate(tokens)]
    discard, hand = [], []
    state = {"wraps": 0, "wrapped_now": False}

    def draw(forced):
        nonlocal deck, discard
        if not deck:
            if forced and discard:
                deck = sorted(discard, key=lambda c: c["i"])
                discard = []
                state["wraps"] += 1
                state["wrapped_now"] = True
            else:
                return None
        card = deck.pop(0)
        if state["wrapped_now"]:
            card["w"] = True
        hand.append(card)
        return card

    def parse_expr(forced):
        wraps_before = state["wraps"]
        mods = []
        span = {"first": None, "last": None, "wfirst": None, "wlast": None}

        def note(c):
            span["first"] = c["i"] if span["first"] is None else min(span["first"], c["i"])
            span["last"] = c["i"] if span["last"] is None else max(span["last"], c["i"])
            if c.get("w"):
                span["wfirst"] = c["i"] if span["wfirst"] is None else min(span["wfirst"], c["i"])
                span["wlast"] = c["i"] if span["wlast"] is None else max(span["wlast"], c["i"])

        card = draw(forced)
        if card is None:
            return None
        m = meta_for(meta, card["id"])

        while chains(m):
            mods.append(card["id"])
            note(card)
            card = draw(True)
            if card is None:
                node = {"kind": "leaf", "id": mods[-1], "atype": "MODIFIER",
                        "modifiers": mods, "dangling": True,
                        "first": span["first"], "last": span["last"],
                        "wfirst": span["wfirst"], "wlast": span["wlast"]}
                if state["wraps"] > wraps_before:
                    node["wrap"] = True
                return node
            m = meta_for(meta, card["id"])

        note(card)
        node = {"id": card["id"], "atype": m["type"], "modifiers": mods,
                "head": card["i"]}

        if is_multicast(m):
            node["kind"] = "multicast"
            node["group"] = m["draws"]
            count = m["draws"]
            if count == -1:
                count = len(deck)
            node["children"] = parse_seq(count, True)
        elif "payload" in m:
            node["kind"] = "trigger"
            node["trigger"] = m.get("trigger")
            node["payload"] = m["payload"]
            node["children"] = parse_seq(m["payload"], True)
        else:
            node["kind"] = "leaf"

        for ch in node.get("children", []):
            if ch.get("first") is not None:
                span["first"] = min(span["first"], ch["first"])
                span["last"] = max(span["last"], ch["last"])
            if ch.get("wfirst") is not None:
                span["wfirst"] = ch["wfirst"] if span["wfirst"] is None else min(span["wfirst"], ch["wfirst"])
                span["wlast"] = ch["wlast"] if span["wlast"] is None else max(span["wlast"], ch["wlast"])
        node["first"], node["last"] = span["first"], span["last"]
        node["wfirst"], node["wlast"] = span["wfirst"], span["wlast"]
        if state["wraps"] > wraps_before:
            node["wrap"] = True
        return node

    def parse_seq(limit, forced):
        out = []
        while limit is None or len(out) < limit:
            node = parse_expr(forced)
            if node is None:
                break
            out.append(node)
        return out

    casts = []
    any_wrapped = False
    while deck and len(casts) < 64:
        wraps_before = state["wraps"]
        hand.clear()
        state["wrapped_now"] = False
        nodes = parse_seq(spc, False)
        wrapped = state["wraps"] > wraps_before
        casts.append({"nodes": nodes, "wrapped": wrapped})
        discard.extend(hand)
        hand.clear()
        if wrapped:
            any_wrapped = True
            break

    return {"casts": casts, "wrapped": any_wrapped}


# ---- compact tree printer for assertions ------------------------------------

def show_node(n):
    mods = "[" + ",".join(n["modifiers"]) + "]" if n["modifiers"] else ""
    tag = ""
    if n["kind"] == "multicast":
        tag = "x%s" % ("all" if n["group"] == -1 else n["group"])
    elif n["kind"] == "trigger":
        tag = "trig%d" % n["payload"]
    if n.get("dangling"):
        tag = "dangling"
    if n.get("wrap"):
        tag += "~WRAP"
    head = mods + n["id"] + (":" + tag if tag else "")
    kids = n.get("children", [])
    if kids:
        return "(%s %s)" % (head, " ".join(show_node(c) for c in kids))
    return head


def show(sim):
    parts = []
    for c in sim["casts"]:
        body = " ".join(show_node(n) for n in c["nodes"])
        parts.append("{%s}%s" % (body, "W" if c["wrapped"] else ""))
    return " | ".join(parts)


# ---- tests -------------------------------------------------------------------

def main():
    meta = load_meta()
    failures = 0

    def check(name, tokens, spc, expect):
        nonlocal failures
        got = show(simulate(tokens, meta, spc))
        ok = got == expect
        if not ok:
            failures += 1
        print("%s %s\n    expect %s\n    got    %s" %
              ("PASS" if ok else "FAIL", name, expect, got))

    # Original docs example, whole deck as one cast (old build() behavior).
    check("doc example, one cast",
          ["DAMAGE", "BURST_2", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER", "MAGIC_SHOT"],
          None,
          "{([DAMAGE]BURST_2:x2 LIGHT_BULLET (LIGHT_BULLET_TRIGGER:trig1 MAGIC_SHOT))}")

    # Cast boundaries: spells/cast 2 -> two simultaneous projectiles per cast.
    check("spells/cast=2 splits casts",
          ["LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET"], 2,
          "{LIGHT_BULLET LIGHT_BULLET} | {LIGHT_BULLET LIGHT_BULLET}")

    # Root draws do NOT wrap: 3 cards, casts 2 -> second cast gets just one.
    check("root draws don't wrap",
          ["LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET"], 2,
          "{LIGHT_BULLET LIGHT_BULLET} | {LIGHT_BULLET}")

    # THE classic rapid-fire wrap: trigger at deck end pulls the wand's start.
    # Both the trigger and the wrapped-in payload card carry the WRAP mark.
    check("trigger payload wraps to wand start",
          ["LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER"], 1,
          "{LIGHT_BULLET} | {LIGHT_BULLET} | "
          "{(LIGHT_BULLET_TRIGGER:trig1~WRAP LIGHT_BULLET:~WRAP)}W")

    # Modifier at deck end force-draws -> wraps onto the wand's first card.
    check("trailing modifier wraps",
          ["LIGHT_BULLET", "DAMAGE"], 1,
          "{LIGHT_BULLET} | {[DAMAGE]LIGHT_BULLET:~WRAP}W")

    # Lone modifier, nothing to wrap in (empty discard) -> dangling leaf
    # (its id is the last modifier in the chain).
    check("dangling modifier, no wrap possible",
          ["DAMAGE"], 1,
          "{[DAMAGE]DAMAGE:dangling}")

    # Under-filled multicast wraps for its missing card.
    check("multicast wraps for missing child",
          ["LIGHT_BULLET", "BURST_2", "MAGIC_SHOT"], 1,
          "{LIGHT_BULLET} | {(BURST_2:x2~WRAP MAGIC_SHOT LIGHT_BULLET:~WRAP)}W")

    # RANDOM_MODIFIER draws 0 -> terminal, does NOT chain.
    check("RANDOM_MODIFIER is terminal",
          ["RANDOM_MODIFIER", "LIGHT_BULLET"], 1,
          "{RANDOM_MODIFIER} | {LIGHT_BULLET}")

    # ALPHA (type OTHER) draws 1 -> chains like a modifier.
    check("ALPHA chains",
          ["ALPHA", "LIGHT_BULLET"], 1,
          "{[ALPHA]LIGHT_BULLET}")

    # BURST_X gathers the whole remaining deck.
    check("BURST_X takes rest of deck",
          ["BURST_X", "LIGHT_BULLET", "MAGIC_SHOT", "SPITTER"], 1,
          "{(BURST_X:xall LIGHT_BULLET MAGIC_SHOT SPITTER)}")

    # Wrap pulls discard in SLOT order (slot 1 first), not cast order.
    check("wrap restores slot order",
          ["MAGIC_SHOT", "LIGHT_BULLET", "BURST_2"], 1,
          "{MAGIC_SHOT} | {LIGHT_BULLET} | "
          "{(BURST_2:x2~WRAP MAGIC_SHOT:~WRAP LIGHT_BULLET)}W")

    # first/last spans: wrapping trigger reaches back to slot 1.
    sim = simulate(["LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER"], meta, 1)
    node = sim["casts"][2]["nodes"][0]
    span_ok = node["first"] == 1 and node["last"] == 3
    if not span_ok:
        failures += 1
    print("%s wrap span reaches slot 1 (first=%s last=%s)" %
          ("PASS" if span_ok else "FAIL", node["first"], node["last"]))

    # head excludes the leading-modifier prefix: [DAMAGE] BURST_2 (...) has
    # first=1 (Damage) but head=2 (the multicast card itself).
    sim = simulate(["DAMAGE", "BURST_2", "LIGHT_BULLET", "MAGIC_SHOT"], meta, None)
    node = sim["casts"][0]["nodes"][0]
    head_ok = node["first"] == 1 and node["head"] == 2 and node["last"] == 4
    if not head_ok:
        failures += 1
    print("%s head excludes modifier prefix (first=%s head=%s last=%s)" %
          ("PASS" if head_ok else "FAIL", node["first"], node["head"], node["last"]))

    # wrapped span: the user's wand [BURST(1), SCATTER_2(2), LIGHT(3),
    # BOUNCE(4)] @1/cast -- cast 2's multicast wraps, pulling slot 1 back in.
    # Forward span head..last = 2..4, wrapped span wfirst..wlast = 1..1.
    sim = simulate(["BOUNCY_ORB", "SCATTER_2", "LIGHT", "BOUNCE"], meta, 1)
    node = sim["casts"][1]["nodes"][0]
    wrap_ok = (node["head"] == 2 and node["last"] == 4
               and node["wfirst"] == 1 and node["wlast"] == 1 and node.get("wrap"))
    if not wrap_ok:
        failures += 1
    print("%s wrapped span tracked (head=%s last=%s wfirst=%s wlast=%s)" %
          ("PASS" if wrap_ok else "FAIL", node["head"], node["last"],
           node["wfirst"], node["wlast"]))

    # Depleted-card rule (read_deck drops uses_remaining == 0 before simulating).
    def passck(name, ok):
        nonlocal failures
        if not ok:
            failures += 1
        print("%s %s" % ("PASS" if ok else "FAIL", name))

    passck("card_fires: 0 depleted", card_fires(0) is False)
    passck("card_fires: -1 unlimited keeps", card_fires(-1) is True)
    passck("card_fires: -2 unlimited-unlimited keeps", card_fires(-2) is True)
    passck("card_fires: 3 charges keeps", card_fires(3) is True)
    passck("card_fires: None (unreadable) keeps", card_fires(None) is True)

    # End-to-end: a depleted MODIFIER drops out, so it no longer chains onto the
    # next projectile. [LIGHT, DAMAGE@0, LIGHT] @1/cast -> filter -> [LIGHT, LIGHT].
    def keep_fires(cards):  # cards = [(id, uses)], mirrors read_deck's filter
        return [cid for cid, uses in cards if card_fires(uses)]
    filtered = keep_fires([("LIGHT_BULLET", -1), ("DAMAGE", 0), ("LIGHT_BULLET", 5)])
    check("depleted modifier filtered before sim", filtered, 1,
          "{LIGHT_BULLET} | {LIGHT_BULLET}")

    # Greek override: a wand with a Greek spell KEEPS depleted cards.
    passck("has_greek: TAU present", has_greek(["LIGHT_BULLET", "TAU", "DAMAGE"]) is True)
    passck("has_greek: none", has_greek(["LIGHT_BULLET", "DAMAGE"]) is False)
    passck("has_greek: DIVIDE is not Greek", has_greek(["DIVIDE_10", "LIGHT_BULLET"]) is False)

    def read_deck_keep(cards):  # [(id, uses)]; mirrors read_deck's Greek gate
        greek = has_greek([cid for cid, _ in cards])
        return [cid for cid, uses in cards if greek or card_fires(uses)]
    greek_kept = read_deck_keep(
        [("TAU", -1), ("LIGHT_BULLET", -1), ("DAMAGE", 0), ("LIGHT_BULLET", 5)])
    check("greek wand keeps depleted card", greek_kept, 1,
          "{[TAU]LIGHT_BULLET} | {[DAMAGE]LIGHT_BULLET}")

    print("\n%d failure(s)" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
