"""Side-by-side crops of the hardest interpolated frame, for eyeballing artifacts.

Like quality.py: drops every other frame of a raw 8-bit YUV420 60 fps clip and
rebuilds it 30 -> 60. Picks the rebuilt frame and region where the reference
method (first one given) differs most from the real frame, and writes a PNG
grid: real frame, then each method.

    python.exe crops.py <clip.yuv> <width> <height> <out.png> [method ...] [pick=disagree] [key=value]

Methods as in quality.py; gpumv key=value settings apply to every gpumv method.
"""
import ctypes
import os
import struct
import sys
import zlib

sys.argv = [sys.argv[0], sys.argv[1], sys.argv[2], sys.argv[3]] + sys.argv[5:] + ["__out=" + sys.argv[4]]
# The portable Python's ._pth file leaves the script folder off the import path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quality as q  # noqa: E402

vs, core = q.vs, q.core
out_path = q.overrides.pop("__out")
pick = q.overrides.pop("pick", "error")
methods = [m for m in q.methods if m in q.build] or ["mvtools", "gpumv-flow", "gpumv-adaptive"]
count = q.num_frames // 2 - 1
truth = q.full.std.SelectEvery(2, 1)[:count]
outs = [q.build[m](q.half).std.SelectEvery(2, 1)[:count] for m in methods]

# Worst frame of the first method, or (pick=disagree) where the first and
# last methods differ most, which skips flashes that every method gets wrong
luma = lambda c: core.std.ShufflePlanes(c, 0, vs.GRAY)
other = outs[-1] if pick == "disagree" else truth
diff = core.std.Expr([luma(outs[0]), luma(other)], "x y - abs", format=vs.GRAYS)
stats = diff.std.PlaneStats()
worst = max(range(count), key=lambda i: stats.get_frame(i).props["PlaneStatsAverage"])

# Worst 480x270 region of that frame
cw, ch = 480, 270
small = diff[worst].resize.Bilinear(q.w // 30, q.h // 30)
fr = small.get_frame(0)
ptr, stride = fr.get_read_ptr(0).value, fr.get_stride(0)
sw, sh = small.width, small.height
best, bx, by = -1.0, 0, 0
gw, gh = cw // 30, ch // 30
for y in range(sh - gh + 1):
    for x in range(sw - gw + 1):
        s = 0.0
        for yy in range(y, y + gh):
            row = (ctypes.c_float * sw).from_address(ptr + yy * stride)
            s += sum(row[x:x + gw])
        if s > best:
            best, bx, by = s, x, y
x0, y0 = bx * 30, by * 30


def rgb_crop(clip):
    c = clip[worst].std.Crop(left=x0, top=y0, right=q.w - x0 - cw, bottom=q.h - y0 - ch)
    c = c.resize.Bicubic(format=vs.RGB24, matrix_in_s="709")
    f = c.get_frame(0)
    planes = []
    for p in range(3):
        ptr, stride = f.get_read_ptr(p).value, f.get_stride(p)
        planes.append([bytes((ctypes.c_ubyte * cw).from_address(ptr + y * stride)) for y in range(ch)])
    return planes


tiles = [rgb_crop(truth)] + [rgb_crop(o) for o in outs]
cols = 2
rows_n = (len(tiles) + cols - 1) // cols
W, H = cw * cols, ch * rows_n
raw = bytearray()
for ty in range(rows_n):
    for y in range(ch):
        raw.append(0)
        for tx in range(cols):
            k = ty * cols + tx
            if k < len(tiles):
                r, g, b = (tiles[k][p][y] for p in range(3))
                line = bytearray(cw * 3)
                line[0::3], line[1::3], line[2::3] = r, g, b
                raw += line
            else:
                raw += bytes(cw * 3)


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


with open(out_path, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))
print(f"frame {worst * 2 + 1}, region {x0},{y0} {cw}x{ch}; grid: real, " + ", ".join(methods))
