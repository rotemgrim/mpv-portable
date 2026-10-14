"""Runs quality.py over the real-footage test set in testset.txt.

    python.exe testset.py <work dir> [method ...] [key=value ...]

Each scene is extracted once (with the portable mpv) into <work dir> as a raw
8-bit YUV420 clip scaled to 1920 wide, then scored like quality.py: every other
frame is dropped and rebuilt (24 -> 12 -> 24 fps for films, so motion between
frames is twice what real playback sees; the numbers compare methods, they
aren't absolute). Prints one row per scene and the average.
"""
import os
import re
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.normpath(os.path.join(here, "..", ".."))
mpv = os.path.join(root, "bin", "mpv.exe")
python = os.path.join(root, "bin", "python.exe")

work = sys.argv[1]
rest = sys.argv[2:]
methods = [a for a in rest if "=" not in a] or ["mvtools", "gpumv-flow", "gpumv-adaptive"]
settings = [a for a in rest if "=" in a]
os.makedirs(work, exist_ok=True)

scenes = []
for line in open(os.path.join(here, "testset.txt"), encoding="utf-8"):
    line = line.strip()
    if line and not line.startswith("#"):
        label, path, start = (p.strip() for p in line.split("|"))
        scenes.append((label, path, start))


def extract(label, path, start):
    # FFmpeg's file reader: mpv's own gets 0-byte reads from some network shares
    # (see bin/portable_config/scripts/redfish-lavf.lua)
    path = "lavf://file:" + path
    out = os.path.join(work, label + ".yuv")
    info = os.path.join(work, label + ".txt")
    if not (os.path.exists(out) and os.path.exists(info)):
        subprocess.run([mpv, "--no-config", path, f"--start={start}", "--length=3", "--no-audio", "--no-sub",
                        "--vf=scale=1920:-2,format=yuv420p", f"--o={out}", "--of=rawvideo", "--ovc=rawvideo"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        probe = subprocess.run([mpv, "--no-config", path, f"--start={start}", "--frames=1", "--vo=null", "--ao=null",
                                "--vf=scale=1920:-2", "--term-playing-msg=SIZE ${video-out-params/w} ${video-out-params/h}"],
                               capture_output=True, encoding="utf-8", errors="replace")
        m = re.search(r"SIZE (\d+) (\d+)", probe.stdout + probe.stderr)
        open(info, "w").write(f"{m.group(1)} {m.group(2)}" if m else "")
    w, h = (int(v) for v in open(info).read().split())
    return out, w, h


totals = {m: [] for m in methods}
print(f"{'scene':<10} {'size':>9}  " + "  ".join(f"{m:>16}" for m in methods))
for label, path, start in scenes:
    clip, w, h = extract(label, path, start)
    res = subprocess.run([python, os.path.join(here, "quality.py"), clip, str(w), str(h)] + methods + settings,
                         capture_output=True, encoding="utf-8", errors="replace")
    scores = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if parts and parts[0] in methods:
            scores[parts[0]] = (float(parts[1]), float(parts[2]))
    for m in methods:
        if m in scores:
            totals[m].append(scores[m])
    cells = "  ".join(f"{scores[m][0]:7.2f} / {scores[m][1]:6.2f}" if m in scores else f"{'failed':>16}"
                      for m in methods)
    print(f"{label:<10} {w:>4}x{h:<4}  {cells}", flush=True)

print(f"{'average':<10} {'':>9}  " + "  ".join(
    f"{sum(s[0] for s in totals[m]) / len(totals[m]):7.2f} / {sum(s[1] for s in totals[m]) / len(totals[m]):6.2f}"
    if totals[m] else f"{'-':>16}" for m in methods))
print("(mean / worst-10% luma PSNR, dB)")
