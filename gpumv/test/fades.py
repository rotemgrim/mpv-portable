"""Fade handling.

Fades a raw 8-bit YUV420 60 fps clip towards black (brightness falls to a
tenth over one second, the colour with it), then, like quality.py, rebuilds every
other frame 30 -> 60 with gpumv, with fade compensation on and off. Reports
quality, and how many rebuilt frames were taken for scene changes (each one is
a repeated frame, a visible stutter in the fade).

    python.exe fades.py <clip.yuv> <width> <height> [key=value ...]
"""
import math
import os
import sys

sys.argv = [sys.argv[0]] + sys.argv[1:4] + ["gpumv-adaptive"] + sys.argv[4:]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quality as q  # noqa: E402

vs, core = q.vs, q.core
n = q.num_frames


def fade(clip):
    def frame(n, c=clip):
        # Full brightness, then down to a tenth over one second (60 frames), then dark
        g = 1.0 - 0.9 * min(max((n - 40) / 60, 0.0), 1.0)
        return core.std.Expr(c, [f"x 16 - {g} * 16 +", f"x 128 - {g} * 128 +"])
    return core.std.FrameEval(clip, frame)


full = fade(q.full)
half = full.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)
count = n // 2 - 1
truth = full.std.SelectEvery(2, 1)[:count]
luma = lambda c: core.std.ShufflePlanes(c, 0, vs.GRAY)


def args(**extra):
    p = dict(q.overrides)
    p.update(extra)
    return {("lambda_" if k == "lambda" else k): (float(v) if isinstance(v, str) and "." in v else int(v))
            for k, v in p.items()}


for fd in (1, 0):
    out = core.gpumv.Interpolate(half, num=60, den=1, **args(fades=fd)).std.SelectEvery(2, 1)[:count]
    sq = core.std.Expr([luma(out), luma(truth)], "x y - dup *", format=vs.GRAYS).std.PlaneStats()
    vals, scenes = [], 0
    for i, fr in enumerate(sq.frames()):
        mse = fr.props["PlaneStatsAverage"]
        vals.append(99.0 if mse <= 1e-10 else 10 * math.log10(255 * 255 / mse))
        scenes += out.get_frame(i).props.get("GpumvScene", 0)
    vals.sort()
    worst = vals[: max(1, len(vals) // 10)]
    print(f"fades={fd}  mean {sum(vals) / len(vals):6.2f} dB  worst 10% {sum(worst) / len(worst):6.2f} dB  "
          f"taken for scene changes: {scenes} of {count}")
