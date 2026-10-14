"""Static overlay handling (burned-in subtitles, logos).

Burns a static subtitle-like line (white strokes with a black outline) and a
semi-transparent corner logo into a raw 8-bit YUV420 60 fps clip, then, like
quality.py, rebuilds every other frame 30 -> 60 with gpumv adaptive mode, with
static handling on and off. Scores the subtitle and logo areas, the whole frame,
and the clip without overlays (for regressions).

    python.exe overlay.py <clip.yuv> <width> <height> [key=value ...]
"""
import ctypes
import math
import os
import random
import sys

sys.argv = [sys.argv[0]] + sys.argv[1:4] + ["gpumv-adaptive"] + sys.argv[4:]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quality as q  # noqa: E402

vs, core = q.vs, q.core
w, h = q.w, q.h
n = q.num_frames

# Subtitle: a row of blocky glyphs, 5 px strokes. It sits mid-frame, where these
# test clips move most; real subtitles sit low, but over moving film content
sub_box = (w // 4, h * 9 // 20 - 25, w * 3 // 4, h * 9 // 20 + 25)  # x0, y0, x1, y1
logo_box = (w - 260, 40, w - 60, 140)
mask = bytearray(w * h)
rng = random.Random(7)
x = sub_box[0]
while x + 28 < sub_box[2]:
    for _ in range(3):
        if rng.random() < 0.5:  # vertical stroke
            sx = x + rng.randrange(0, 22)
            for yy in range(sub_box[1] + 6, sub_box[3] - 6):
                mask[yy * w + sx: yy * w + sx + 5] = b"\xff" * 5
        else:  # horizontal stroke
            sy = sub_box[1] + 6 + rng.randrange(0, sub_box[3] - sub_box[1] - 17)
            for yy in range(sy, sy + 5):
                mask[yy * w + x: yy * w + x + 26] = b"\xff" * 26
    x += 34 if rng.random() < 0.85 else 60  # word gaps
logo = bytearray(w * h)
for yy in range(logo_box[1], logo_box[3]):
    for xx in range(logo_box[0], logo_box[2]):
        if ((xx - logo_box[0]) // 20 + (yy - logo_box[1]) // 20) % 2 == 0:
            logo[yy * w + xx] = 102  # 40% opacity


def mask_clip(data):
    blank = core.std.BlankClip(width=w, height=h, format=vs.GRAY8, length=1)
    def fill(n, f):
        f = f.copy()
        ptr, stride = f.get_write_ptr(0).value, f.get_stride(0)
        for yy in range(h):
            ctypes.memmove(ptr + yy * stride, bytes(data[yy * w:(yy + 1) * w]), w)
        return f
    frame = blank.std.ModifyFrame(blank, fill).get_frame(0)
    return core.std.Loop(blank.std.ModifyFrame(blank, lambda n, f: frame), q.num_frames)


sub_mask = mask_clip(mask)
outline = sub_mask.std.Maximum().std.Maximum()
logo_mask = mask_clip(logo)
white = core.std.BlankClip(q.full, color=[235, 128, 128])
blackc = core.std.BlankClip(q.full, color=[16, 128, 128])


def burn(clip):
    clip = core.std.MaskedMerge(clip, blackc, outline, first_plane=True)
    clip = core.std.MaskedMerge(clip, white, sub_mask, first_plane=True)
    return core.std.MaskedMerge(clip, white, logo_mask, first_plane=True)


full = burn(q.full)
half = full.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)
count = n // 2 - 1
truth = full.std.SelectEvery(2, 1)[:count]
luma = lambda c: core.std.ShufflePlanes(c, 0, vs.GRAY)


def psnr(got, ref, box=None):
    g, r = luma(got), luma(ref)
    if box:
        x0, y0, x1, y1 = box
        crop = dict(left=x0, top=y0, right=w - x1, bottom=h - y1)
        g, r = g.std.Crop(**crop), r.std.Crop(**crop)
    sq = core.std.Expr([g, r], "x y - dup *", format=vs.GRAYS).std.PlaneStats()
    vals = []
    for fr in sq.frames():
        mse = fr.props["PlaneStatsAverage"]
        vals.append(99.0 if mse <= 1e-10 else 10 * math.log10(255 * 255 / mse))
    return sum(vals) / len(vals)


def args(**extra):
    p = dict(q.overrides)
    p.update(extra)
    return {("lambda_" if k == "lambda" else k): (float(v) if isinstance(v, str) and "." in v else v)
            for k, v in p.items()}


if __name__ == "__main__":
    for st in (1.0, 0.0):
        out = core.gpumv.Interpolate(half, num=60, den=1, **args(static=st)).std.SelectEvery(2, 1)[:count]
        plain = core.gpumv.Interpolate(q.half, num=60, den=1, **args(static=st)).std.SelectEvery(2, 1)[:count]
        plain_truth = q.full.std.SelectEvery(2, 1)[:count]
        print(f"static={st:<4} subtitle {psnr(out, truth, sub_box):6.2f} dB   logo {psnr(out, truth, logo_box):6.2f} dB   "
              f"whole {psnr(out, truth):6.2f} dB   clip without overlays {psnr(plain, plain_truth):6.2f} dB")
