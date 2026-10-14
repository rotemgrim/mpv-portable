"""Scene cut handling.

Joins two raw 8-bit YUV420 clips (same size) into one with a hard cut, keeps
every other frame (30 fps) and interpolates to 60 with gpumv. Reports which
interpolated frames were flagged as scene changes (GpumvScene), whether the
frames around the cut are real frames rather than a morph, and repeats the
test with the clips darkened, where fixed thresholds tend to miss cuts.

    python.exe scenes.py <a.yuv> <b.yuv> <width> <height> [key=value ...]
"""
import ctypes
import math
import mmap
import sys

import vapoursynth as vs

core = vs.core
pa, pb, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
params = {}
for a in sys.argv[5:]:
    k, v = a.split("=", 1)
    params["lambda_" if k == "lambda" else k] = float(v) if "." in v else int(v)
frame_size = w * h * 3 // 2
_mappings = []


def raw_clip(path, frames):
    fh = open(path, "rb")
    mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_COPY)
    base = ctypes.addressof(ctypes.c_char.from_buffer(mm))
    n = min(frames, len(mm) // frame_size)

    def load(n, f):
        fr = f.copy()
        off = base + n * frame_size
        for p, (pw, ph) in enumerate([(w, h), (w // 2, h // 2), (w // 2, h // 2)]):
            dst, stride = fr.get_write_ptr(p).value, fr.get_stride(p)
            for y in range(ph):
                ctypes.memmove(dst + y * stride, off + y * pw, pw)
            off += pw * ph
        return fr

    blank = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=n, fpsnum=60, fpsden=1)
    clip = blank.std.ModifyFrame(blank, load)
    _mappings.append((fh, mm))  # load() only holds the raw address
    return clip


def psnr(a, b):
    sq = core.std.Expr([a.std.ShufflePlanes(0, vs.GRAY), b.std.ShufflePlanes(0, vs.GRAY)], "x y - dup *",
                       format=vs.GRAYS).std.PlaneStats()
    mse = sq.get_frame(0).props["PlaneStatsAverage"]
    return 99.0 if mse <= 1e-10 else 10 * math.log10(255 * 255 / mse)


A, B = raw_clip(pa, 120), raw_clip(pb, 120)
for label, dark in (("normal", False), ("dark (x0.25)", True)):
    a, b = A, B
    if dark:
        a = core.std.Expr(A, ["x 0.25 * 16 +", ""])
        b = core.std.Expr(B, ["x 0.25 * 16 +", ""])
    joined = a + b
    half = joined.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)
    cut = a.num_frames // 2  # first frame of clip b in half
    out = core.gpumv.Interpolate(half, num=60, den=1, **params)
    flagged, scores = [], {}
    for k in range(half.num_frames - 1):
        f = out.get_frame(2 * k + 1)
        scores[k] = f.props.get("GpumvScore", 0.0)
        if f.props.get("GpumvScene", 0):
            flagged.append(k)
    mid = out[2 * (cut - 1) + 1]
    near = max(psnr(mid, half[cut - 1]), psnr(mid, half[cut]))
    false = [k for k in flagged if k != cut - 1]
    print(f"{label:<13} cut between half frames {cut - 1} and {cut}: "
          f"{'detected' if cut - 1 in flagged else 'MISSED'}; frame at the cut matches a real frame at "
          f"{near:.1f} dB ({'clean' if near > 40 else 'morphed'}); false detections: {len(false)} {false[:10]}")
    print(f"{'':<13} pair errors around the cut: " +
          ", ".join(f"{k}:{scores[k]:.1f}" for k in range(cut - 3, cut + 2)))
