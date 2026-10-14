"""Interpolation quality against ground truth.

Takes a raw 8-bit YUV420 clip recorded at 60 fps, drops every other frame,
interpolates 30 -> 60 with each method and scores the rebuilt frames against
the real ones (luma PSNR, higher is better).

    python.exe quality.py <clip.yuv> <width> <height> [method ...]

Methods: repeat, blend, mvtools, gpumv-block, gpumv-flow, gpumv-adaptive (default: all).
MVTools and gpumv read their settings from portable_config/vs_config.conf.
Extra gpumv settings can be given as key=value, e.g. lambda=0.2 blksize=16.
"""
import ctypes
import math
import mmap
import os
import sys

import vapoursynth as vs

core = vs.core

path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
args = sys.argv[4:]
methods = [a for a in args if "=" not in a] or ["repeat", "blend", "mvtools", "gpumv-block", "gpumv-flow", "gpumv-adaptive"]
overrides = dict(a.split("=", 1) for a in args if "=" in a)
# mv.<key>=<value> overrides an MVTools setting, everything else a gpumv one
mv_overrides = {k[3:]: v for k, v in overrides.items() if k.startswith("mv.")}
overrides = {k: v for k, v in overrides.items() if not k.startswith("mv.")}

frame_size = w * h * 3 // 2
fh = open(path, "rb")
mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_COPY)
base_addr = ctypes.addressof(ctypes.c_char.from_buffer(mm))
num_frames = len(mm) // frame_size

def load(n, f):
    fr = f.copy()
    off = base_addr + n * frame_size
    for p, (pw, ph) in enumerate([(w, h), (w // 2, h // 2), (w // 2, h // 2)]):
        dst, stride = fr.get_write_ptr(p).value, fr.get_stride(p)
        for y in range(ph):
            ctypes.memmove(dst + y * stride, off + y * pw, pw)
        off += pw * ph
    return fr

blank = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=num_frames, fpsnum=60, fpsden=1)
full = blank.std.ModifyFrame(blank, load)
half = full.std.SelectEvery(2, 0).std.AssumeFPS(fpsnum=30, fpsden=1)

config = {}
cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin", "portable_config", "vs_config.conf")
for line in open(cfg_path):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        config[k.strip()] = v.strip()
config.update(mv_overrides)
ci = lambda k, d: int(config.get(k, d))
cf = lambda k, d: float(config.get(k, d))


def mvtools(clip):
    sup = core.mv.Super(clip, pel=ci("pel", 1), sharp=ci("sharp", 2))
    an = dict(blksize=ci("blksize", 16), overlap=ci("overlap", 0), search=ci("search", 2),
              searchparam=ci("searchparam", 2), truemotion=ci("truemotion", 1), dct=ci("dct", 0))
    bv = core.mv.Analyse(sup, isb=True, **an)
    fv = core.mv.Analyse(sup, isb=False, **an)
    sc = dict(blend=ci("blend", 1), thscd1=ci("thscd1", 400), thscd2=ci("thscd2", 130), ml=cf("ml", 100))
    if ci("use_flow", 0):
        return core.mv.FlowFPS(clip, sup, bv, fv, num=60, den=1, **sc)
    return core.mv.BlockFPS(clip, sup, bv, fv, num=60, den=1, mode=ci("mode", 3), **sc)


def gpumv(clip, mode):
    p = dict(mode=mode, blksize=min(ci("blksize", 16), 32), pel=ci("pel", 1), blend=ci("blend", 1),
             thscd1=ci("thscd1", 400), thscd2=ci("thscd2", 130), ml=cf("ml", 100))
    for k, v in overrides.items():
        p["lambda_" if k == "lambda" else k] = float(v) if "." in v else int(v)
    return core.gpumv.Interpolate(clip, num=60, den=1, **p)


build = {
    "repeat": lambda c: core.std.Interleave([c, c]),
    "blend": lambda c: core.std.Interleave([c, core.std.Merge(c, c[1:] + c[-1])]),
    "mvtools": mvtools,
    "gpumv-block": lambda c: gpumv(c, 0),
    "gpumv-flow": lambda c: gpumv(c, 1),
    "gpumv-adaptive": lambda c: gpumv(c, 2),
}


def psnr_scores(out):
    # Interpolated frames are the odd ones; skip the last pair (no next frame)
    count = num_frames // 2 - 1
    got = out.std.SelectEvery(2, 1)[:count]
    ref = full.std.SelectEvery(2, 1)[:count]
    got = core.std.ShufflePlanes(got, 0, vs.GRAY)
    ref = core.std.ShufflePlanes(ref, 0, vs.GRAY)
    sq = core.std.Expr([got, ref], "x y - dup *", format=vs.GRAYS).std.PlaneStats()
    scores = []
    for fr in sq.frames():
        mse = fr.props["PlaneStatsAverage"]
        scores.append(99.0 if mse <= 1e-10 else 10 * math.log10(255 * 255 / mse))
    return scores


if __name__ == "__main__":
    print(f"{num_frames} frames {w}x{h}, settings: blksize={config.get('blksize')} pel={config.get('pel')} "
          f"mode={config.get('mode')} use_flow={config.get('use_flow')} {mv_overrides or ''} {overrides or ''}")
    print(f"{'method':<12} {'mean PSNR':>9} {'worst 10%':>9} {'min':>6}")
    for m in methods:
        s = sorted(psnr_scores(build[m](half)))
        worst = s[: max(1, len(s) // 10)]
        print(f"{m:<12} {sum(s) / len(s):9.2f} {sum(worst) / len(worst):9.2f} {s[0]:6.2f}")
