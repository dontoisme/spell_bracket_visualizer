#!/usr/bin/env python3
"""Generate per-type color-bordered versions of every Noita spell icon.

Reads icons straight out of data.wak, decodes them (PNG color types 2/3/6,
8-bit), draws a type-colored border in two styles (corner brackets / full
frame), and writes RGBA PNGs into the mod's files/icons/<style>/<id>.png.
Pure stdlib (zlib) — no Pillow.
"""
import struct, zlib, re, os, sys

# Paths are derived from this script's location (mods/testMod/tools/gen_icons.py):
#   MOD  = the mod root (parent of tools/)
#   WAK  = <Noita install>/data/data.wak  (mods/<mod> -> ../../data/data.wak)
# Override the wak path with argv[1] or $NOITA_WAK if your install differs.
MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAK = (sys.argv[1] if len(sys.argv) > 1 else
       os.environ.get("NOITA_WAK",
       os.path.normpath(os.path.join(MOD, "..", "..", "data", "data.wak"))))
OUT = os.path.join(MOD, "files", "icons")

# Border color per action type (RGB). Matches the original GetBracketColor
# mapping (0.8/0.2 -> 204/51), with cyan/orange added for the two types the
# original code never handled.
TYPE_COLOR = {
    "ACTION_TYPE_PROJECTILE":        (204, 51, 51),    # red
    "ACTION_TYPE_STATIC_PROJECTILE": (51, 204, 51),    # green
    "ACTION_TYPE_MODIFIER":          (51, 51, 204),    # blue
    "ACTION_TYPE_DRAW_MANY":         (204, 204, 51),   # yellow
    "ACTION_TYPE_MATERIAL":          (204, 51, 204),   # purple
    "ACTION_TYPE_UTILITY":           (51, 204, 204),   # cyan
    "ACTION_TYPE_PASSIVE":           (230, 140, 40),   # orange
    "ACTION_TYPE_OTHER":             (178, 178, 178),  # gray
}

# ---------------------------------------------------------------- wak index
def load_wak():
    buf = open(WAK, "rb").read()
    count = struct.unpack_from("<I", buf, 4)[0]
    pos = 16; ent = {}
    for _ in range(count):
        off, size, plen = struct.unpack_from("<III", buf, pos); pos += 12
        name = buf[pos:pos+plen].decode("utf-8", "replace"); pos += plen
        ent[name] = buf[off:off+size]
    return ent

# ---------------------------------------------------------------- PNG decode
def _unfilter(raw, w, h, bpp):
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    i = 0
    for _ in range(h):
        ft = raw[i]; i += 1
        line = bytearray(raw[i:i+stride]); i += stride
        if ft == 1:      # Sub
            for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 255
        elif ft == 2:    # Up
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif ft == 3:    # Average
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif ft == 4:    # Paeth
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line; prev = line
    return out

def decode_png(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8; w = h = bit = col = None
    plte = trns = None; idat = bytearray()
    while pos < len(data):
        ln = struct.unpack_from(">I", data, pos)[0]; typ = data[pos+4:pos+8]
        body = data[pos+8:pos+8+ln]; pos += 12 + ln
        if typ == b"IHDR":
            w, h, bit, col = struct.unpack(">IIBB", body[:10])
        elif typ == b"PLTE": plte = body
        elif typ == b"tRNS": trns = body
        elif typ == b"IDAT": idat += body
        elif typ == b"IEND": break
    raw = zlib.decompress(bytes(idat))
    bpp = {2: 3, 3: 1, 6: 4}[col]
    px = _unfilter(raw, w, h, bpp)
    rgba = bytearray(w * h * 4)
    for j in range(w * h):
        if col == 6:
            rgba[j*4:j*4+4] = px[j*4:j*4+4]
        elif col == 2:
            r, g, b = px[j*3], px[j*3+1], px[j*3+2]
            a = 255
            if trns and len(trns) >= 6:
                tr, tg, tb = trns[1], trns[3], trns[5]
                if (r, g, b) == (tr, tg, tb): a = 0
            rgba[j*4:j*4+4] = bytes((r, g, b, a))
        elif col == 3:
            idx = px[j]
            r, g, b = plte[idx*3], plte[idx*3+1], plte[idx*3+2]
            a = trns[idx] if (trns and idx < len(trns)) else 255
            rgba[j*4:j*4+4] = bytes((r, g, b, a))
    return w, h, rgba

# ---------------------------------------------------------------- PNG encode
def encode_png(w, h, rgba):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: None
        raw += rgba[y*w*4:(y+1)*w*4]
    comp = zlib.compress(bytes(raw), 9)
    def chunk(typ, body):
        return struct.pack(">I", len(body)) + typ + body + \
               struct.pack(">I", zlib.crc32(typ + body) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + \
           chunk(b"IDAT", comp) + chunk(b"IEND", b"")

# ---------------------------------------------------------------- draw border
def _set(rgba, w, x, y, rgb):
    i = (y*w + x) * 4
    rgba[i:i+4] = bytes((rgb[0], rgb[1], rgb[2], 255))

def draw_corners(rgba, w, h, rgb, arm=5):
    mx, my = w-1, h-1
    for k in range(arm):
        _set(rgba, w, k, 0, rgb);      _set(rgba, w, 0, k, rgb)       # TL
        _set(rgba, w, mx-k, 0, rgb);   _set(rgba, w, mx, k, rgb)      # TR
        _set(rgba, w, k, my, rgb);     _set(rgba, w, 0, my-k, rgb)    # BL
        _set(rgba, w, mx-k, my, rgb);  _set(rgba, w, mx, my-k, rgb)   # BR

def draw_frame(rgba, w, h, rgb):
    for x in range(w):
        _set(rgba, w, x, 0, rgb); _set(rgba, w, x, h-1, rgb)
    for y in range(h):
        _set(rgba, w, 0, y, rgb); _set(rgba, w, w-1, y, rgb)

# ---------------------------------------------------------------- parse actions
def parse_actions(src):
    """Return list of (id, type, sprite_path) from gun_actions.lua."""
    out = []
    # split into per-action chunks on each `id = "..."`
    marks = [(m.start(), m.group(1)) for m in re.finditer(r'\bid\s*=\s*"([^"]+)"', src)]
    for i, (start, aid) in enumerate(marks):
        end = marks[i+1][0] if i+1 < len(marks) else len(src)
        chunk = src[start:end]
        t = re.search(r'\btype\s*=\s*(ACTION_TYPE_\w+)', chunk)
        sp = re.search(r'\bsprite\s*=\s*"([^"]+\.png)"', chunk)
        out.append((aid, t.group(1) if t else None, sp.group(1) if sp else None))
    return out

# ---------------------------------------------------------------- main
def main():
    ent = load_wak()
    src = ent["data/scripts/gun/gun_actions.lua"].decode("utf-8", "replace")
    actions = parse_actions(src)
    for style in ("corners", "frame"):
        os.makedirs(os.path.join(OUT, style), exist_ok=True)
    made = skipped = 0; skips = []
    manifest = {}
    for aid, atype, sprite in actions:
        if not sprite or sprite not in ent:
            skipped += 1; skips.append((aid, sprite)); continue
        rgb = TYPE_COLOR.get(atype, TYPE_COLOR["ACTION_TYPE_OTHER"])
        try:
            w, h, base = decode_png(ent[sprite])
        except Exception as e:
            skipped += 1; skips.append((aid, f"decode:{e}")); continue
        for style, fn in (("corners", draw_corners), ("frame", draw_frame)):
            buf = bytearray(base)
            fn(buf, w, h, rgb)
            open(os.path.join(OUT, style, aid + ".png"), "wb").write(encode_png(w, h, buf))
        manifest[aid] = atype
        made += 1
    print(f"generated {made} icons x2 styles; skipped {skipped}")
    if skips: print("  skips (first 12):", skips[:12])
    # Emit the set of ids we generated icons for, so the runtime recolor only
    # touches vanilla spells it has art for (never mod-added spells).
    ids = sorted(manifest)
    lua = ["-- AUTO-GENERATED by gen_icons.py. Set of spell action ids that",
           "-- have generated bordered icons. Do not edit by hand.",
           "return {"]
    lua += [f'\t["{i}"] = true,' for i in ids]
    lua.append("}")
    open(os.path.join(MOD, "files", "known_ids.lua"), "w").write("\n".join(lua) + "\n")
    print(f"wrote known_ids.lua ({len(ids)} ids)")
    return made

if __name__ == "__main__":
    main()
