#!/usr/bin/env python3
"""Regression guard for the wand-BOX vertical geometry model.

Noita renders the wand inventory in C++ with no Lua API for box positions, so
files/grouping_overlay.lua MODELS each box from the wand sprite THICKNESS (art
height h in px). Both the slot-row offset and the box height are LINEAR in h:
    row_offset = row_a + row_b * h          (box top  -> slot-row top)
    box_h      = row_offset + below_c        (box top  -> box bottom)
2026-06-17 THICKNESS MODEL: box height is driven by sprite thickness, NOT the
diagonal 0.7071*(w+h) (which averaged width+thickness, so long-thin vs short-fat
wands with equal w+h got the same wrong box). Ground-truth (thickness -> box_h):
h7 -> 35.0/36.2u, h9 -> 38.2u, h15 -> 45.6u -> box_h = 26.9 + 1.25*h, fitting all
within ~0.65u including big wands. Validated by the "Shuffle" rows down a stack.
The constants are fit to in-game measurements; a bad edit used to ship silently.
This test parses the LIVE constants out of grouping_overlay.lua and asserts the
model still reproduces every measured anchor. Run it (and test_wand_structure.py)
after any BOX edit. Add a row to the anchor lists each time a new wand is measured.

No Lua runtime here -- we re-implement the (tiny) formula and check it against
the same constants the mod ships.
"""
import os
import re
import sys

LUA = os.path.join(os.path.dirname(__file__), "..", "files", "grouping_overlay.lua")

# (label, sprite thickness h [px], measured box-top -> slot-row-top offset [u], tol).
# Derived as box_h - below_c(15.6). The h7 pair spans 35.0/36.2u box_h (length
# adds ~0.17u/px, not modeled), so the h7 anchor uses the midpoint with a looser tol.
ROW_ANCHORS = [
    ("h7 wand (wand_0492/0511)", 7,  20.00, 0.8),
    ("h9 wand (wand_0531)",      9,  22.60, 0.6),
    ("h15 wand (wand_0860)",     15, 30.00, 0.6),
]
# (label, thickness h, measured box-top -> box-bottom [box height, u], tol). Read
# from box-bottom borders + "Shuffle"-row stacking checks. h7 midpoint (35.0/36.2).
BOX_H_ANCHORS = [
    ("h7 wand (wand_0492/0511)", 7,  35.60, 0.8),
    ("h9 wand (wand_0531)",      9,  38.20, 0.6),
    ("h15 wand (wand_0860)",     15, 45.60, 0.6),
]


def grab(src, name, kind="field"):
    pat = (r"\blocal\s+%s\s*=\s*(-?[\d.]+)" if kind == "local"
           else r"\b%s\s*=\s*(-?[\d.]+)") % re.escape(name)
    m = re.search(pat, src)
    if not m:
        raise SystemExit("FAIL: could not find constant %r in grouping_overlay.lua" % name)
    return float(m.group(1))


def main():
    src = open(LUA, encoding="utf-8").read()

    row_a   = grab(src, "row_a")
    row_b   = grab(src, "row_b")
    below_c = grab(src, "below_c")

    def row_top(h):
        return row_a + row_b * h

    def box_h(h):
        return row_top(h) + below_c

    fails = []

    for label, h, meas, tol in ROW_ANCHORS:
        got = row_top(h)
        ok = abs(got - meas) <= tol
        print("%s row_top(h=%d): model %.2fu vs measured %.2fu  err %+.2fu  [%s]"
              % ("PASS" if ok else "FAIL", h, got, meas, got - meas, label))
        if not ok:
            fails.append("%s row_top off %+.2fu (tol %.2f)" % (label, got - meas, tol))

    for label, h, meas, tol in BOX_H_ANCHORS:
        got = box_h(h)
        ok = abs(got - meas) <= tol
        print("%s box_h(h=%d):  model %.2fu vs measured %.2fu  err %+.2fu  [%s]"
              % ("PASS" if ok else "FAIL", h, got, meas, got - meas, label))
        if not ok:
            fails.append("%s box_h off %+.2fu (tol %.2f)" % (label, got - meas, tol))

    # sanity: both linear & strictly increasing, and the box bottom is always
    # below the row top by exactly below_c (the stacking depends on box_h).
    if not (row_top(5) < row_top(10) < row_top(15)):
        fails.append("row_top not strictly increasing -- linear model broken")
    elif abs((box_h(11.0) - row_top(11.0)) - below_c) > 1e-9:
        fails.append("box_h - row_top != below_c -- box-height coupling broken")
    else:
        print("PASS row_top & box_h linear/increasing; box_h - row_top == below_c (%.2fu)" % below_c)

    print()
    if fails:
        print("%d failure(s):" % len(fails))
        for f in fails:
            print("  - " + f)
        sys.exit(1)
    print("0 failure(s)")


if __name__ == "__main__":
    main()
