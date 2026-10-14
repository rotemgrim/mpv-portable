# gpumv

MVTools-style motion-compensated frame interpolation for VapourSynth, running on the GPU (CUDA).
It targets the output of `mv.Super` + `mv.Analyse` + `mv.BlockFPS`/`mv.FlowFPS`, not their internals,
and adds an adaptive mode plus handling for letterbox bars, fades, fast camera pans and animation
drawn on twos. Ideas taken from SVP come from its documentation, forum and public parameter names;
no SVP code is used.

In mpv: **Ctrl+G** opens the motion smoothing settings window (also in the right-click menu under
Interpolation): mode, smoothness, quality and the extras, in plain words, applied to the playing
video at once, with a live status line. Or use **Ctrl+8**, and **Ctrl+9** for animation (settings `gpumv_*` and `gpumv_anime_*` in
`bin/portable_config/vs_config.conf`, plus the shared `dst_fps`, `max_fps`, `pel`, `thscd1`,
`thscd2`, `ml`).

### Live action and animation

The two want opposite settings, so they are separate modes:

| | Ctrl+8 (default) | Ctrl+9 (anime) |
|---|---|---|
| `blksize` | 16 | 32 |
| `lambda` | 0.1 | 2.0 |
| `mask` | 0.5 | 1.0 |
| Live-action scenes (8) | best | up to 3.4 dB worse |
| Anime scenes (2), vs MVTools 34.15 dB | 33.37 dB | 34.23 dB |

Flat line art matches equally well almost anywhere, so it needs a much more coherent vector
field; live action has real, varied motion that strong coherence smooths away. Choosing the
coherence per block by texture (`lambdaflat`) doesn't replace the two modes: live action's
motion blur, soft backgrounds and dark areas look as flat as anime's colour fills.

## Build

Needs the CUDA toolkit (13.x) and the Visual Studio 2022 C++ build tools.

```
build.cmd
```

This builds `build\gpumv.dll` and copies it into `bin\Lib\site-packages\vapoursynth\plugins`.
Close mpv first, or the copy fails. The CUDA runtime is linked in, so other PCs only need an NVIDIA
driver. To ship it, rebuild the release payload with `tools\build-payload.ps1`, which packs the
whole plugins folder.

## Function

```
gpumv.Interpolate(clip clip, int num[, int den=1, int mode=2, int blksize=16, int pel=1,
                  int radius=4, int refine=2, float lambda=0.1, float lambdaflat=0, float texref=4,
                  int smooth=1, int split=0,
                  int thsad=250, int gmv=1, int temporal=1, int blend=0, int thscd1=400,
                  int thscd2=130, float scratio=3, float ml=100, float mask=0.5, float occsad=2,
                  int bars=1, float barsth=24, float static=0, int fades=1, int prefilter=0,
                  int dedup=1, int holdmax=3, float dupth=0.4, float strength=1, int nvof=0,
                  int device=0])
```

- `clip`: 8–16 bit integer YUV or Gray with a known frame rate
- `num`/`den`: output frame rate
- `mode`: 0 block (like BlockFPS), 1 flow (like FlowFPS), 2 adaptive (below)
- `blksize`: 8, 16 or 32; `pel`: 1, or 2 for half-pel refinement
- `radius`: exhaustive search radius at the coarsest pyramid level; `refine`: local search radius below it
- `lambda`: vector coherence penalty; `smooth`: 3x3 vector median
- `lambdaflat`, `texref`: per-block coherence, growing from `lambda` towards `lambdaflat` in blocks
  whose texture (8-bit mean deviation) is below `texref`. Off: it can't tell anime's flat colour
  from live action's blur and soft backgrounds, and cost live action up to 2.5 dB
- `split`: times a block whose match error is above `thsad` (8x8-block SAD, 8-bit) is split in four
  and searched again, like SVP's `refine`. Off: no gain measured
- `gmv`: camera motion. The best whole-frame shift at the coarsest level, up to a quarter of the
  frame width either way, seeds every level of the block search
- `temporal`: try the vector the block had in the previous frame pair
- `thscd1`, `thscd2`, `ml`: as in MVTools
- `blend`: at a scene change, 1 cross-fades, 0 shows the nearest real frame
- `scratio`: a pair whose match error is this many times its neighbours' is a scene change, which
  catches cuts in dark footage that the fixed thresholds miss (0 = off)
- `mask`: adaptive mode, how strongly areas no vector explains fall back to a plain blend (0-1)
- `occsad`: match error scale that marks a block as occluded (0 = vector convergence only)
- `bars`: detect letterbox bars (rows/columns at the edges whose brightest pixel stays under
  `barsth`, in matching pairs, held for 12 frame pairs) and keep them out of the interpolation
- `static`: adaptive mode, an extra rule keeping unchanged pixels still. Off: adaptive mode already
  keeps burned-in subtitles intact
- `fades`: scale one frame's brightness to the other's (around black) before matching
- `prefilter`: blur radius (0-2) of the copy used for matching. Off: no gain measured on grainy film
- `nvof`: motion from NVIDIA's optical-flow hardware (RTX 20 and later) instead of the block search:
  0 off, 1 fast, 2 medium, 3 slow. One vector per 4x4 pixels in both directions; occlusion, scene,
  bar and held-frame handling stay the same. Falls back to the block search without the hardware.
  Ctrl+8 uses 2 (best on the film set, +0.17 dB, and faster at 4K); Ctrl+9 keeps the block search
- `strength`: film look. 1 builds every in-between frame evenly; lower values keep each real frame
  on screen for part of the gap and move in the middle of it, keeping some of the original cadence
  (like SVP's 1m/2m modes). From 24 fps, 0.6 builds 40% of the output frames instead of 80%
- `dedup`: animation on twos or threes. Runs of up to `holdmax` identical frames (mean difference
  under `dupth`, quarter resolution) count as one drawing, and the motion to the next drawing is
  spread over the whole run. Longer runs are a still shot and stay as they are

Output frames carry `GpumvScene` (1 at a detected scene change), `GpumvScore` (the pair's mean
match error, 8-bit units), `GpumvArea` (active picture without bars), `GpumvGain` (fade
compensation) and `GpumvHeld` (source frames the motion was spread over).

### Adaptive mode

1. Each 8x8 tile of the frame being built tries the nearby forward and backward block vectors and
   keeps the one whose path lines A and B up best at that moment.
2. Each pixel picks between the four surrounding tile vectors by the same test, so the vector
   switches at an object's edge instead of being blended across it (the halo).
3. Content one frame can't see (poor match, or vectors converging as it gets covered) comes from
   the other frame only.
4. Where no vector fits and it isn't an occlusion, the result fades towards a plain frame blend
   (SVP's artifact masking).

## Structure compared with SVP

From SVPflow's public interface (registered functions and parameter names): `svp1.Super`
(pyramid) -> `svp1.Analyse` (block matching, both directions) -> `svp2.SmoothFps` (rendering,
OpenCL). gpumv runs the same three stages in one CUDA filter.

| SVP / MVTools | gpumv |
|---|---|
| `lambda`, `pnbour`, `pzero` | `lambda`, parent-neighbour and zero candidates |
| `pglobal` | `gmv` |
| `prev` | `temporal` |
| `refine` (`thsad`) | `split`, `thsad` |
| scene `limits` incl. `luma` | `thscd1`/`thscd2`, `scratio`; fades compensated instead of cut |
| black bar detection and crop | `bars` |
| `coarse.bad`, `trymany`, `plevel`, `lsad`, `pnew`, `satd` | not implemented |

Beyond what SVP documents: held-frame spreading (an open feature request on SVP's forum) and fade
compensation. SVP also has `SmoothFps_NVOF` (NVIDIA optical-flow vectors) and `SmoothFps_RIFE`.

## Tests

Run with the portable `bin\python.exe`. Most take a raw 8-bit YUV420 clip, drop every other frame,
rebuild it and score luma PSNR against the frames that were dropped.

- `test\quality.py <clip.yuv> <w> <h> [methods] [key=value]`: the basic comparison.
  `mv.<key>=<value>` changes an MVTools setting, anything else a gpumv one. `skipheld=1` leaves out
  dropped frames that copy a neighbour (animation on twos), where not moving scores best
- `test\testset.py <work dir> [methods] [key=value]`: the same over the real-film scenes listed in
  `test\testset.txt` (extracted once into the work dir)
- `test\scenes.py <a.yuv> <b.yuv> <w> <h>`: a hard cut, normal and darkened
- `test\letterbox.py <clip.yuv> <w> <h>`: 2.4:1 bars; scores next to and inside the bars, and checks
  the clip without bars isn't taken for letterboxed
- `test\overlay.py <clip.yuv> <w> <h>`: burned-in subtitle and logo
- `test\fades.py <clip.yuv> <w> <h>`: one-second fade towards black
- `test\pans.py <clip.yuv> <w> <h>`: synthetic camera pans at four speeds
- `test\held.py <clip.yuv> <w> <h>`: animation on twos and threes, and a still shot
- `test\credits.py`: rolling credits at four scroll speeds
- `test\crops.py <clip.yuv> <w> <h> <out.png> [methods] [pick=disagree]`: PNG grid of the hardest frame
- `test\bench.py <script.vpy> <w> <h> [frames] [inflight]`: throughput (`BENCH_DISPLAY_FPS` sets the
  display rate the script sees)

## Results (RTX 5080, 16-thread CPU)

Real films (`testset.py`, 10 scenes: action, anime, drama, 1990s grain, dark), 24 -> 12 -> 24, so
motion per frame is twice real playback. Mean / worst-10% PSNR, dB:

| | average | anime scenes | other scenes |
|---|---|---|---|
| MVTools, Ctrl+3 settings | 38.59 / 29.61 | 34.68 | 39.57 |
| gpumv flow | 39.65 / 29.91 | 33.83 | 41.10 |
| gpumv adaptive (default) | 39.92 / 30.01 | 33.93 | 41.42 |

Feature tests:

| Test | Without | With |
|---|---|---|
| Letterbox: bars stay black | 81 dB | 99 dB (exact) |
| Letterbox: picture next to bars | 32.98 / 38.49 dB | 33.52 / 39.22 dB |
| Clips without bars taken for letterboxed | — | 0 frames |
| Subtitle over motion (adaptive vs flow mode) | 25.5 / 21.5 dB | 31.7 / 24.5 dB |
| Fade, bright drama scene | 44.54 dB | 45.51 dB |
| Pan 200 px per frame pair, centre | 31.8 dB | 44.6 dB |
| Pan 400 px per frame pair, centre | 20.6 dB | 27.7 dB |
| Held frames on twos, two clips | 26.1 / 23.7 dB | 34.9 / 28.2 dB |
| Held frames on threes, two clips | 25.3 / 23.1 dB | 33.4 / 27.6 dB |
| Still shot left untouched | — | 99 dB (exact) |
| Real anime on twos, frames spread at 24 -> 60 | — | 71 of 174 (0 on live action) |

Speed, 4K 23.976 -> 120 fps inside VapourSynth: gpumv adaptive 308 fps, gpumv flow 592,
MVTools Ctrl+3 settings 204, MVTools bs16 overlap8 pel2 74.

## Known limits

- One CUDA stream, frames processed one at a time (`fmParallelRequests`)
- NVIDIA only
- No overlapped blocks; flow mode interpolates vectors between block centres instead
- Brightness flashes count as scene changes (no interpolation across them)
- mpv crashes while exiting after any VapourSynth filter, even a script that only passes the video
  through with no plugins loaded: an mpv/VapourSynth/embedded-Python shutdown issue, not gpumv. It
  happens after playback has ended
- New letterbox bars take 12 frame pairs (about half a second) to be used
- Interlaced and telecined sources (DVD, old TV) aren't handled: gpumv takes the frame rate from the
  file, so a deinterlacer that doubles the rate in front of it would make the motion run at the
  wrong speed. Progressive films and series (Blu-ray, web releases) are unaffected
