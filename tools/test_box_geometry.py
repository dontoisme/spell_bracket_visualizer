#!/usr/bin/env python3
"""Regression guard for the wand-BOX vertical geometry model.

Noita renders the wand inventory in C++ with no Lua API for box positions, so
files/grouping_overlay.lua MODELS each box from the wand sprite diagonal
D = 0.7071*(w+h). Both the slot-row offset and the box height are LINEAR in D
(v3, 2026-06-16, from Measure-tool readings):
    row_offset = row_a + row_b * D          (box top  -> slot-row top)
    box_h      = row_offset + below_c        (box top  -> box bottom)
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

# box-top -> slot-row-top offset (the dy "(N.NNu)" Measure value). 16:9, units.
ROW_ANCHORS = [
    ("small wand", 12.0, 19.38, 0.6),
    ("mid wand",   14.1, 21.88, 0.6),
    ("big wand",   22.6, 28.13, 0.6),
]
# box-top -> box-bottom (box height). Noisier (the outline border has thickness),
# so a slightly looser tolerance. Derived from the box-bottom offset readings.
BOX_H_ANCHORS = [
    ("small wand", 12.0, 34.35, 0.8),
    ("mid wand",   14.1, 36.85, 0.8),
    ("big wand",   22.6, 43.16, 0.8),
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

    def row_top(D):
        return row_a + row_b * D

    def box_h(D):
        return row_top(D) + below_c

    fails = []

    for label, D, meas, tol in ROW_ANCHORS:
        got = row_top(D)
        ok = abs(got - meas) <= tol
        print("%s row_top(D=%.1f): model %.2fu vs measured %.2fu  err %+.2fu  [%s]"
              % ("PASS" if ok else "FAIL", D, got, meas, got - meas, label))
        if not ok:
            fails.append("%s row_top off %+.2fu (tol %.2f)" % (label, got - meas, tol))

    for label, D, meas, tol in BOX_H_ANCHORS:
        got = box_h(D)
        ok = abs(got - meas) <= tol
        print("%s box_h(D=%.1f):  model %.2fu vs measured %.2fu  err %+.2fu  [%s]"
              % ("PASS" if ok else "FAIL", D, got, meas, got - meas, label))
        if not ok:
            fails.append("%s box_h off %+.2fu (tol %.2f)" % (label, got - meas, tol))

    # sanity: both linear & strictly increasing, and the box bottom is always
    # below the row top by exactly below_c (the stacking depends on box_h).
    if not (row_top(10) < row_top(20) < row_top(30)):
        fails.append("row_top not strictly increasing -- linear model broken")
    elif abs((box_h(17.0) - row_top(17.0)) - below_c) > 1e-9:
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
