"""Letterbox handling.

Puts 2.4:1 letterbox bars on a raw 8-bit YUV420 60 fps clip, then, like
quality.py, rebuilds every other frame 30 -> 60 with gpumv, with bar handling
on and off. Scores the picture next to the bars (where motion used to drag
black in or picture out), the bars themselves (must stay black) and the whole
frame, and checks that the clip without bars isn't taken for letterboxed.

    python.exe letterbox.py <clip.yuv> <width> <height> [key=value ...]
"""
import math
import os
import sys

sys.argv = [sys.argv[0]] + sys.argv[1:4] + ["gpumv-adaptive"] + sys.argv[4:]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quality as q  # noqa: E402

vs, core = q.vs, q.core
w, h = q.w, q.h
bar = (h - w * 9 // 21) // 2 // 2 * 2  # 2.4:1 picture inside the frame
band = 64                               # rows of picture next to each bar that are scored
black = [16, 128, 128]

boxed = core.std.AddBorders(core.std.Crop(q.full, top=bar, bottom=bar), top=bar, bottom=bar, color=black)
half = boxed.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)
count = q.num_frames // 2 - 1
truth = boxed.std.SelectEvery(2, 1)[:count]
luma = lambda c: core.std.ShufflePlanes(c, 0, vs.GRAY)


def psnr(got, ref, top, bottom):
    g = luma(got).std.Crop(top=top, bottom=bottom)
    r = luma(ref).std.Crop(top=top, bottom=bottom)
    sq = core.std.Expr([g, r], "x y - dup *", format=vs.GRAYS).std.PlaneStats()
    vals = []
    for fr in sq.frames():
        mse = fr.props["PlaneStatsAverage"]
        vals.append(99.0 if mse <= 1e-10 else 10 * math.log10(255 * 255 / mse))
    return sum(vals) / len(vals)


def run(label, **extra):
    params = {k: v for k, v in q.overrides.items()}
    params.update(extra)
    args = {("lambda_" if k == "lambda" else k): (float(v) if isinstance(v, str) and "." in v else int(v))
            for k, v in params.items()}
    out = core.gpumv.Interpolate(half, num=60, den=1, **args).std.SelectEvery(2, 1)[:count]
    edge_top = psnr(out, truth, bar, h - bar - band)
    edge_bottom = psnr(out, truth, h - bar - band, bar)
    bars_ok = psnr(out, truth, 0, h - bar)
    whole = psnr(out, truth, 0, 0)
    # New bars are only used after they have held for a while, so read the area last
    area = list(out.get_frame(count - 1).props["GpumvArea"])
    print(f"{label:<12} area {area}  next to bars {edge_top:6.2f} / {edge_bottom:6.2f} dB   "
          f"bars {bars_ok:5.1f} dB   whole {whole:6.2f} dB")


print(f"{w}x{h}, bars {bar} px top and bottom")
run("bars=1", bars=1)
run("bars=0", bars=0)

# The clip without bars must keep its full frame
plain = core.gpumv.Interpolate(q.half, num=60, den=1).std.SelectEvery(2, 1)[:count]
wrong = sum(1 for fr in plain.frames() if list(fr.props["GpumvArea"]) != [0, 0, w, h])
print(f"original clip: {wrong} of {count} interpolated frames taken for letterboxed")
