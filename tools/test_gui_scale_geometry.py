#!/usr/bin/env python3
"""Regression guard for GUI-RESOLUTION invariance of the bracket/box geometry.

The real bug (verified in-game 2026-06-18 via the mod's own debug readout):
    Noita draws the spell inventory in FIXED GUI-unit positions, but it varies the
    GUI *resolution* with the window/monitor -- always keeping it 16:9, letterboxing
    other window aspects. Observed:
        window 640x480  -> GUI 640x360   (aspect 1.778)  -> brackets ALIGNED
        window 1080x1024-> GUI 640x360   (aspect 1.778)  -> brackets ALIGNED
        window 720x480  -> GUI 720x405   (aspect 1.778)  -> brackets DRIFT (down)
        window 1152x864 -> GUI 720x405   (aspect 1.778)  -> brackets DRIFT (down)
    The engine's inventory positions DON'T scale with the GUI resolution, but
    grouping_overlay.lua scaled every coordinate by the LIVE GUI width sw. sw only
    equals the calibration width (640) when the GUI happens to be 640x360, so any
    other GUI resolution mis-scales everything -- drift compounds DOWN the box stack
    and RIGHT across columns. (The earlier "aspect ratio" theory was wrong: the GUI
    aspect is always 16:9, so aspect never varies. It's pure resolution scaling.)

The fix: scale geometry by the CONSTANT CAL_W (640, the calibration width), not sw.
Then bracket/box positions are identical at every GUI resolution -- which is exactly
what the engine does. At GUI 640x360, CAL_W == sw, so the common case is unchanged.

What this test does (no Lua runtime, like test_box_geometry.py):
  1. Parses the LIVE constants (slot0_x/pitch/halfw/U/top0/CAL_W) AND the live SCALE
     expression actually used in the draw lines (now `refw`, resolved through its
     `local refw = CAL_W` definition) straight out of grouping_overlay.lua.
  2. For a sweep of 16:9 GUI RESOLUTIONS (the ones Noita actually produces), asserts
     the predicted absolute GUI x of each slot column, and the box-top y, equal their
     640x360 reference.

Run against the CURRENT code -> PASSES (constant CAL_W). Revert geometry to scale by
sw (or by sh*CAL_ASPECT, the earlier half-fix) -> FAILS at 720x405 etc., reproducing
the drift. So it guards the fix AND rejects both prior broken models.
"""
import ast
import os
import re
import sys

LUA = os.path.join(os.path.dirname(__file__), "..", "files", "grouping_overlay.lua")

# (label, GUI width, GUI height) -- the 16:9 GUI resolutions Noita produces. 640x360
# is the calibration / reference; 720x405 is the in-game-confirmed drift case.
GUI_RES = [
    ("GUI 640x360  (1920x1080, 640x480, 1080x1024 windows) -- reference", 640, 360),
    ("GUI 720x405  (720x480, 720x576, 1152x864 windows) -- confirmed drift", 720, 405),
    ("GUI 480x270  (small window)", 480, 270),
    ("GUI 854x480", 854, 480),
    ("GUI 1024x576", 1024, 576),
    ("GUI 1280x720", 1280, 720),
]
REF_W, REF_H = 640, 360                 # the calibration resolution
COLUMNS = [0, 5, 12, 25]                # drift compounds with column index
TOL_GUI = 0.05                          # invariance is geometric, demand near-exact


def grab_float(src, name):
    m = re.search(r"\b%s\s*=\s*(-?[\d.]+)" % re.escape(name), src)
    if not m:
        raise SystemExit("FAIL: constant %r not found in grouping_overlay.lua" % name)
    return float(m.group(1))


def collect_locals(src):
    """Map every `local NAME = EXPR` (arithmetic expr) so scale tokens like
    `refw` / `CAL_W` / `CAL_ASPECT` resolve. Last definition wins."""
    out = {}
    for m in re.finditer(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*([^\n]+)", src):
        name, expr = m.group(1), m.group(2).strip().rstrip(",")
        if re.fullmatch(r"[\sA-Za-z_0-9.+\-*/()]+", expr):
            out[name] = expr
    return out


def extract_scale(src, pattern, what):
    m = re.search(pattern, src)
    if not m:
        raise SystemExit("FAIL: could not locate the %s scale expression "
                         "(draw line moved? update the test pattern)" % what)
    return m.group(1).strip()


class Evaluator:
    """Tiny safe arithmetic evaluator. Names resolve from `env` (sw/sh per
    resolution) first, then recursively from parsed `locals` (refw, CAL_W, ...)."""

    def __init__(self, locals_map):
        self.locals = locals_map

    def eval(self, expr, env, depth=0):
        if depth > 32:
            raise SystemExit("FAIL: scale expr recursion too deep (cycle?): %r" % expr)
        return self._node(ast.parse(expr, mode="eval").body, env, depth)

    def _node(self, n, env, depth):
        if isinstance(n, ast.BinOp):
            a, b = self._node(n.left, env, depth), self._node(n.right, env, depth)
            if isinstance(n.op, ast.Add):  return a + b
            if isinstance(n.op, ast.Sub):  return a - b
            if isinstance(n.op, ast.Mult): return a * b
            if isinstance(n.op, ast.Div):  return a / b
            raise SystemExit("FAIL: unsupported operator in scale expr")
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub):
            return -self._node(n.operand, env, depth)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)):
            return float(n.value)
        if isinstance(n, ast.Name):
            if n.id in env:
                return env[n.id]
            if n.id in self.locals:
                return self.eval(self.locals[n.id], env, depth + 1)
            raise SystemExit("FAIL: scale expr references unknown name %r" % n.id)
        raise SystemExit("FAIL: unsupported syntax in scale expr: %r" % ast.dump(n))


def main():
    src = open(LUA, encoding="utf-8").read()

    slot0_x = grab_float(src, "slot0_x")
    pitch   = grab_float(src, "pitch")
    halfw   = grab_float(src, "halfw")
    top0    = grab_float(src, "top0")
    U       = grab_float(src, "U")

    ev = Evaluator(collect_locals(src))

    h_scale = extract_scale(
        src, r"\blx\s*=\s*(\([^()]*\)|[A-Za-z_]\w*)\s*\*\s*\(BOX\.slot0_x", "horizontal")
    v_scale = extract_scale(
        src, r"box_top\s*\*\s*U\s*\*\s*(\([^()]*\)|[A-Za-z_]\w*)", "vertical")
    print("live horizontal scale factor: %s" % h_scale)
    print("live vertical   scale factor: %s\n" % v_scale)

    def env_for(w, h):
        return {"sw": float(w), "sh": float(h)}

    def slot_x(w, h, col):
        return ev.eval(h_scale, env_for(w, h)) * (slot0_x + col * pitch + halfw)

    def box_top_y(w, h):
        return top0 * U * ev.eval(v_scale, env_for(w, h))

    fails = []

    print("Horizontal bracket x vs 640x360 reference (GUI units):")
    for col in COLUMNS:
        ref = slot_x(REF_W, REF_H, col)
        for label, w, h in GUI_RES:
            got = slot_x(w, h, col)
            drift = got - ref
            one_slot = slot_x(w, h, 1) - slot_x(w, h, 0)
            ok = abs(drift) <= TOL_GUI
            print("  %s col %2d: %.2f  (ref %.2f, drift %+.2f GUI = %+.2f slots)  %s"
                  % ("PASS" if ok else "FAIL", col, got, ref, drift, drift / one_slot, label))
            if not ok:
                fails.append("col %d @ %s drifts %+.2f GUI (%.2f slots)"
                             % (col, label.split()[1], drift, drift / one_slot))
        print()

    print("Vertical box-top y vs 640x360 reference (GUI units):")
    ref_y = box_top_y(REF_W, REF_H)
    for label, w, h in GUI_RES:
        got = box_top_y(w, h)
        drift = got - ref_y
        ok = abs(drift) <= TOL_GUI
        print("  %s box-top: %.2f  (ref %.2f, drift %+.2f GUI)  %s"
              % ("PASS" if ok else "FAIL", got, ref_y, drift, label))
        if not ok:
            fails.append("box-top @ %s drifts %+.2f GUI" % (label.split()[1], drift))
    print()

    if fails:
        print("%d failure(s) -- geometry is NOT GUI-resolution-invariant "
              "(the drift bug):" % len(fails))
        for f in fails:
            print("  - " + f)
        sys.exit(1)
    print("0 failure(s) -- bracket/box geometry is GUI-resolution-invariant")


if __name__ == "__main__":
    main()
