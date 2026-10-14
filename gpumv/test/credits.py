"""Rolling credits.

White blocky text lines scrolling up over black, as end credits do, at several
speeds (pixels per 60 fps frame). Every other frame is dropped and rebuilt
30 -> 60 with gpumv; the real frames are known exactly. Scores luma PSNR.

    python.exe credits.py [key=value ...]
"""
import ctypes
import math
import random
import sys

import vapoursynth as vs

core = vs.core
params = {}
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    params["lambda_" if k == "lambda" else k] = float(v) if "." in v else int(v)

w, h, tall = 1920, 1080, 4000
rng = random.Random(3)
page = bytearray([16]) * (w * tall)
y = 60
while y + 40 < tall:
    width = rng.randrange(300, 900)
    x = (w - width) // 2
    for gx in range(x, x + width, 22):  # glyphs: 14 px wide, 4 px strokes
        if rng.random() < 0.15:
            continue
        for yy in range(y, y + 28):
            for xx in (gx, gx + 10):
                page[yy * w + xx: yy * w + xx + 4] = b"\xeb" * 4
        for yy in (y, y + 12, y + 24):
            page[yy * w + gx: yy * w + gx + 14] = b"\xeb" * 14
    y += rng.choice((60, 60, 60, 140))


def still():
    blank = core.std.BlankClip(width=w, height=tall, format=vs.GRAY8, length=1)
    def fill(n, f):
        f = f.copy()
        ptr, stride = f.get_write_ptr(0).value, f.get_stride(0)
        for yy in range(tall):
            ctypes.memmove(ptr + yy * stride, bytes(page[yy * w:(yy + 1) * w]), w)
        return f
    frame = blank.std.ModifyFrame(blank, fill).get_frame(0)
    return blank.std.ModifyFrame(blank, lambda n, f: frame)


page_clip = still()


def scroll(speed, frames=120):
    def window(n, c=page_clip):
        top = int(n * speed) // 2 * 2
        return c.std.Crop(top=top, bottom=tall - h - top)
    luma = core.std.FrameEval(core.std.BlankClip(width=w, height=h, format=vs.GRAY8, length=frames), window)
    uv = core.std.BlankClip(width=w // 2, height=h // 2, format=vs.GRAY8, length=frames, color=128)
    return core.std.ShufflePlanes([luma, uv, uv], [0, 0, 0], vs.YUV).std.AssumeFPS(fpsnum=60, fpsden=1)


print(f"{'scroll speed':<26}{'gpumv':>10}{'blend':>10}")
for speed in (2, 4, 8, 16):
    full = scroll(speed)
    half = full.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)
    count = full.num_frames // 2 - 1
    truth = full.std.SelectEvery(2, 1)[:count]
    outs = {
        "gpumv": core.gpumv.Interpolate(half, num=60, den=1, **params).std.SelectEvery(2, 1)[:count],
        "blend": core.std.Merge(half, half[1:] + half[-1])[:count],
    }
    cells = []
    for name, out in outs.items():
        sq = core.std.Expr([out.std.ShufflePlanes(0, vs.GRAY), truth.std.ShufflePlanes(0, vs.GRAY)], "x y - dup *",
                           format=vs.GRAYS).std.PlaneStats()
        vals = [10 * math.log10(255 * 255 / max(f.props["PlaneStatsAverage"], 1e-10)) for f in sq.frames()]
        cells.append(f"{sum(vals) / len(vals):7.2f} dB")
    print(f"{speed:>3} px/frame ({2 * speed:>2} per pair)  " + "".join(f"{c:>10}" for c in cells), flush=True)
