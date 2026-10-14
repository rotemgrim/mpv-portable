"""Camera pans.

Pans a 1920x800 window across one frame of a raw 8-bit YUV420 clip, enlarged
2x, at several speeds (pixels per 60 fps frame), drops every other frame and
rebuilds 30 -> 60 with gpumv. Because the motion is a pure pan the real frames
are known exactly. Fast pans move further per frame pair than the block search
reaches on its own, which is where a global (camera) motion estimate matters.

    python.exe pans.py <clip.yuv> <width> <height> [key=value ...]
"""
import ctypes
import math
import mmap
import sys

import vapoursynth as vs

core = vs.core
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
params = {}
for a in sys.argv[4:]:
    k, v = a.split("=", 1)
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
ow, oh = 1920, 800


def pan(speed, frames=120):
    span = still.width - ow
    def window(n, c=still):
        x = int(n * speed) % (2 * span)
        x = x if x <= span else 2 * span - x  # bounce at the edges
        y = (still.height - oh) // 2
        return c.std.Crop(left=x // 2 * 2, top=y // 2 * 2, right=still.width - ow - x // 2 * 2,
                          bottom=still.height - oh - y // 2 * 2)
    src = core.std.BlankClip(width=ow, height=oh, format=vs.YUV420P8, length=frames, fpsnum=60, fpsden=1)
    return core.std.FrameEval(src, window)


def score(speed, extra):
    full = pan(speed)
    half = full.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)
    count = full.num_frames // 2 - 1
    out = core.gpumv.Interpolate(half, num=60, den=1, **{**params, **extra}).std.SelectEvery(2, 1)[:count]
    truth = full.std.SelectEvery(2, 1)[:count]
    # Whole frame, and the centre only: picture entering at the edges was never
    # seen by one of the two frames, which no method can rebuild
    m = 2 * speed + 16
    res = []
    for crop in ({}, dict(left=m, right=m)):
        g = out.std.ShufflePlanes(0, vs.GRAY).std.Crop(**crop)
        r = truth.std.ShufflePlanes(0, vs.GRAY).std.Crop(**crop)
        sq = core.std.Expr([g, r], "x y - dup *", format=vs.GRAYS).std.PlaneStats()
        vals = [10 * math.log10(255 * 255 / max(f.props["PlaneStatsAverage"], 1e-10)) for f in sq.frames()]
        res.append(sum(vals) / len(vals))
    return res


variants = [("gmv=1", {"gmv": 1}), ("gmv=0", {"gmv": 0})]
print(f"{'pan speed':<22}" + "".join(f"{label + ' whole / centre':>26}" for label, _ in variants))
for speed in (8, 40, 100, 200):
    cells = "".join("{:>14.2f} / {:6.2f} dB".format(*score(speed, extra)) for _, extra in variants)
    print(f"{speed:>4} px/frame ({2 * speed:>3}/pair)" + cells, flush=True)
