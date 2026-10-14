"""Throughput of a .vpy interpolation script on a moving synthetic texture.

    python.exe bench.py <script.vpy> <width> <height> [frames] [inflight]

Run with the portable bin\\python.exe so the VapourSynth plugins are found.
"""
import sys
import time
from collections import deque

import vapoursynth as vs

core = vs.core

vpy, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
n = int(sys.argv[4]) if len(sys.argv) > 4 else 240
inflight = int(sys.argv[5]) if len(sys.argv) > 5 else 8

def texture(width, height):
    # Rows are shifted slices of one long irregular row: 2D structure without numpy
    import ctypes, math
    row = bytes(int(128 + 70 * math.sin(i * 0.05) * math.cos(i * 0.0173) + 40 * math.sin(i * 0.31))
                for i in range(width + 7919))
    blank = core.std.BlankClip(width=width, height=height, format=vs.GRAY8, length=1)
    def fill(n, f):
        f = f.copy()
        ptr, stride = f.get_write_ptr(0).value, f.get_stride(0)
        for y in range(height):
            off = (y * 37 + (y // 9) * 101) % 7919
            ctypes.memmove(ptr + y * stride, row[off:off + width], width)
        return f
    frame = blank.std.ModifyFrame(blank, fill).get_frame(0)
    return core.std.Loop(blank.std.ModifyFrame(blank, lambda n, f: frame), 2000)

base = texture(w + 128, h)
def shift(n, c=base):
    s = (n * 6) % 128
    return core.std.Crop(c, left=s, right=128 - s)
luma = core.std.FrameEval(core.std.BlankClip(width=w, height=h, format=vs.GRAY8, length=2000), shift)
uv = core.std.BlankClip(width=w // 2, height=h // 2, format=vs.GRAY8, length=2000, color=128)
src = core.std.ShufflePlanes([luma, uv, uv], [0, 0, 0], vs.YUV)
src = core.std.AssumeFPS(src, fpsnum=24000, fpsden=1001)

import os
g = {"video_in": src, "__file__": vpy, "container_fps": 24000 / 1001,
     "display_fps": float(os.environ.get("BENCH_DISPLAY_FPS", 60))}
t0 = time.time()
exec(compile(open(vpy).read(), vpy, "exec"), g)
out = vs.get_output(0)
out = out.clip if hasattr(out, "clip") else out
init = time.time() - t0

for i in range(8):
    out.get_frame(i)
q = deque()
i = 8
t0 = time.time()
while i < 8 + n or q:
    while i < 8 + n and len(q) < inflight:
        q.append(out.get_frame_async(i))
        i += 1
    q.popleft().result()
dt = time.time() - t0
print("%dx%d -> %s fps: init %.2fs, %d frames in %.2fs = %.1f fps" % (w, h, out.fps, init, n, dt, n / dt))
