"""Camera zooms.

Zooms into one frame of a raw 8-bit YUV420 clip (enlarged 2x) at several
rates per 60 fps frame, rendering every frame from the still so the real
frames are known exactly. Every other frame is dropped and rebuilt 30 -> 60
with gpumv, with and without the zoom fit. Motion grows towards the edges, so
the outer part of the frame is scored separately.

    python.exe zooms.py <clip.yuv> <width> <height> [rates=0.01,0.02] [key=value ...]
"""
import ctypes
import math
import mmap
import sys

import vapoursynth as vs

core = vs.core
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
params = {}
rates = (0.0025, 0.005, 0.01, 0.02)
for a in sys.argv[4:]:
    k, v = a.split("=", 1)
    if k == "rates":  # e.g. rates=0.05,0.08
        rates = tuple(float(x) for x in v.split(","))
        continue
    params["lambda_" if k == "lambda" else k] = float(v) if "." in v else int(v)

fs = w * h * 3 // 2
fh = open(path, "rb")
mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_COPY)
base = ctypes.addressof(ctypes.c_char.from_buffer(mm))
pick = min(len(mm) // fs - 1, 20)


def load(n, f):
    fr = f.copy()
    off = base + pick * fs
    for p, (pw, ph) in enumerate([(w, h), (w // 2, h // 2), (w // 2, h // 2)]):
        dst, stride = fr.get_write_ptr(p).value, fr.get_stride(p)
        for y in range(ph):
            ctypes.memmove(dst + y * stride, off + y * pw, pw)
        off += pw * ph
    return fr


blank = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=1)
still = blank.std.ModifyFrame(blank, load).resize.Spline36(w * 2, h * 2)
ow, oh = w, h


def zoom(rate, frames=120, direction=1):
    # Zoom in (direction 1) or out (-1) around the centre, at `rate` per frame
    def frame(n, c=still):
        z = 1.0 + rate * (n if direction > 0 else frames - 1 - n)
        cw, ch = still.width / 2 / z, still.height / 2 / z
        left, top = (still.width - cw) / 2, (still.height - ch) / 2
        return c.resize.Spline36(ow, oh, src_left=left, src_top=top, src_width=cw, src_height=ch)
    src = core.std.BlankClip(width=ow, height=oh, format=vs.YUV420P8, length=frames, fpsnum=60, fpsden=1)
    return core.std.FrameEval(src, frame)


def score(clip, extra):
    half = clip.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)
    count = clip.num_frames // 2 - 1
    out = core.gpumv.Interpolate(half, num=60, den=1, **{**params, **extra}).std.SelectEvery(2, 1)[:count]
    truth = clip.std.SelectEvery(2, 1)[:count]
    res = []
    # Whole frame, and the outer ring (where zoom motion is largest)
    for mask_inner in (False, True):
        g = out.std.ShufflePlanes(0, vs.GRAY)
        r = truth.std.ShufflePlanes(0, vs.GRAY)
        sq = core.std.Expr([g, r], "x y - dup *", format=vs.GRAYS)
        if mask_inner:
            ring = core.std.BlankClip(sq, color=1.0)
            inner = core.std.BlankClip(sq.std.Crop(left=ow // 4, right=ow // 4, top=oh // 4, bottom=oh // 4),
                                       color=0.0)
            ring = core.std.AddBorders(inner, left=ow // 4, right=ow // 4, top=oh // 4, bottom=oh // 4, color=1.0)
            sq = core.std.Expr([sq, ring], "x y *")
        st = sq.std.PlaneStats()
        frac = 0.75 if mask_inner else 1.0  # share of the frame scored
        vals = [10 * math.log10(255 * 255 / max(f.props["PlaneStatsAverage"] / frac, 1e-10)) for f in st.frames()]
        res.append(sum(vals) / len(vals))
    return res


variants = [("zoom=1", {"zoom": 1}), ("zoom=0", {"zoom": 0})]
print(f"{'zoom rate':<22}" + "".join(f"{label + ' whole / edges':>26}" for label, _ in variants))
for rate in rates:
    for direction in (1, -1):
        # Keep the end of fast zooms from shrinking the source window too far
        clip = zoom(rate, frames=min(120, int(2.0 / rate)), direction=direction)
        cells = "".join("{:>14.2f} / {:6.2f} dB".format(*score(clip, extra)) for _, extra in variants)
        print(f"{'in ' if direction > 0 else 'out'} {100 * rate:4.2f}%/frame".ljust(22) + cells, flush=True)
