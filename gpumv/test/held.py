"""Held frames (animation drawn on twos or threes).

Turns a smooth raw 8-bit YUV420 60 fps clip into "on twos" (every drawing
shown twice: frames 0 0 2 2 4 4 ...) and "on threes", then runs gpumv at the
same frame rate. With dedup the held copies are replaced by in-between frames,
so the output should match the original smooth clip; without it, the copies
stay. Scores only the frames that were held copies. Also checks that a still
shot (one frame repeated) stays exactly as it is.

    python.exe held.py <clip.yuv> <width> <height> [key=value ...]
"""
import math
import os
import sys

sys.argv = [sys.argv[0]] + sys.argv[1:4] + ["gpumv-adaptive"] + sys.argv[4:]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quality as q  # noqa: E402

vs, core = q.vs, q.core
luma = lambda c: core.std.ShufflePlanes(c, 0, vs.GRAY)


def args(**extra):
    p = dict(q.overrides)
    p.update(extra)
    return {("lambda_" if k == "lambda" else k): (float(v) if isinstance(v, str) and "." in v else int(v))
            for k, v in p.items()}


def psnr_frames(a, b, frames):
    vals = []
    for i in frames:
        sq = core.std.Expr([luma(a[i]), luma(b[i])], "x y - dup *", format=vs.GRAYS).std.PlaneStats()
        mse = sq.get_frame(0).props["PlaneStatsAverage"]
        vals.append(99.0 if mse <= 1e-10 else 10 * math.log10(255 * 255 / mse))
    return sum(vals) / len(vals)


full = q.full
n = full.num_frames
for hold in (2, 3):
    held = core.std.SelectEvery(full, hold, [0] * hold)[:n]
    copies = [i for i in range(hold, n - 2 * hold) if i % hold]  # held copies with a next drawing in range
    row = []
    for dd in (1, 0):
        out = core.gpumv.Interpolate(held, num=60, den=1, **args(dedup=dd, holdmax=max(3, hold)))
        row.append(psnr_frames(out, full, copies))
    print(f"on {'twos' if hold == 2 else 'threes'}: held copies vs the smooth original  dedup=1 {row[0]:6.2f} dB   "
          f"dedup=0 {row[1]:6.2f} dB")

still = core.std.Loop(full[10], 40)
out = core.gpumv.Interpolate(still, num=60, den=1, **args(dedup=1))
print(f"still shot (one frame x40): output vs input {psnr_frames(out, still, range(5, 35)):6.2f} dB (99 = untouched)")
