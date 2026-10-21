#!/usr/bin/env python3
"""Checks a render-sweep folder: every index.json entry has a PNG, every PNG is listed, none is a single flat colour.
Usage: Tools/render-sweep-check.py [--list] <folder>; --list also prints each entry (file, screen, theme). Needs only the standard library plus macOS `sips` is NOT used; PNGs are decoded by zlib."""
import json, os, struct, sys, zlib

def decode(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w, h, depth, ctype = 8, b"", 0, 0, 8, 6
    while pos < len(data):
        n, t = struct.unpack(">I4s", data[pos:pos+8]); body = data[pos+8:pos+8+n]; pos += 12 + n
        if t == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif t == b"IDAT": idat += body
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]; bpp = ch * depth // 8
    raw = zlib.decompress(idat); stride = w * bpp; rows = []; prev = bytearray(stride); i = 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    return w, h, rows

def main(folder, show=False):
    idx = json.load(open(os.path.join(folder, "index.json")))
    entries = idx if isinstance(idx, list) else idx.get("entries", idx.get("renders", []))
    listed = {e["file"] for e in entries}
    pngs = {f for f in os.listdir(folder) if f.endswith(".png")}
    bad = []
    for f in sorted(listed - pngs): bad.append((f, "listed but missing"))
    for f in sorted(pngs - listed): bad.append((f, "PNG not in index.json"))
    for f in sorted(pngs):
        try:
            w, h, rows = decode(os.path.join(folder, f))
            if len(set(rows)) == 1 and len(set(rows[0][i:i+4] for i in range(0, len(rows[0]), 4))) == 1:
                bad.append((f, "uniform colour"))
        except Exception as e: bad.append((f, f"unreadable: {e}"))
    print(f"{len(pngs)} PNGs, {len(listed)} index entries, {len(bad)} problems")
    for f, why in bad: print(" ", f, why)
    if show:
        for e in entries: print(f"  {e['file']}  ({e.get('screen', '?')}, {e.get('theme', '?')})")
    return 1 if bad else 0

args = sys.argv[1:]
sys.exit(main(next(a for a in args if a != "--list"), "--list" in args))
