#!/usr/bin/env python3
"""Python mirror of files/wand_structure.lua + hand-traced test wands.

There is no Lua runtime on the dev machine, so this mirrors the simulator
line-for-line (same draw/wrap/chain rules, same node shapes) and asserts the
structure of known wands -- including cast splitting and wand wrapping. If you
change wand_structure.lua, change simulate() here to match and re-run:

    python3 tools/test_wand_structure.py

It loads per-card metadata from the real generated files/structure_meta.lua,
so it also catches generator regressions.
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
    state = {"wraps": 0}

    def draw(forced):
        nonlocal deck, discard
        if not deck:
            if forced and discard:
                deck = sorted(discard, key=lambda c: c["i"])
                discard = []
                state["wraps"] += 1
            else:
                return None
        card = deck.pop(0)
        hand.append(card)
        return card

    def parse_expr(forced):
        wraps_before = state["wraps"]
        mods, first, last = [], None, None
        card = draw(forced)
        if card is None:
            return None
        m = meta_for(meta, card["id"])

        while chains(m):
            mods.append(card["id"])
            first = card["i"] if first is None else min(first, card["i"])
            last = card["i"] if last is None else max(last, card["i"])
            card = draw(True)
            if card is None:
                node = {"kind": "leaf", "id": mods[-1], "atype": "MODIFIER",
                        "modifiers": mods, "dangling": True,
                        "first": first, "last": last}
                if state["wraps"] > wraps_before:
                    node["wrap"] = True
                return node
            m = meta_for(meta, card["id"])

        first = card["i"] if first is None else min(first, card["i"])
        last = card["i"] if last is None else max(last, card["i"])
        node = {"id": card["id"], "atype": m["type"], "modifiers": mods}

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
                first = min(first, ch["first"])
                last = max(last, ch["last"])
        node["first"], node["last"] = first, last
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

    print("\n%d failure(s)" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
