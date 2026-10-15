# gpumv feature list

Ordered by impact on everyday movie watching, most impactful first.

## To do

1. [ ] **Publish the release payload** with `gpumv.dll`: run `tools\build-payload.ps1` (uploads to the `payload` release). CI already excludes the `gpumv/` source folder from the package
2. [ ] **Detect animation automatically** and switch to the anime settings, instead of Ctrl+9. Held frames alone aren't enough (one of the two anime test scenes has none)
6. [ ] **Lip-sync check with real speakers** and a **4K playback check** on a normally running display (tests so far used simulated audio, and the display was misreporting its refresh rate)
15. [ ] **Overlapped blocks** for smoother block-mode (`mode=0`) output; the default adaptive mode doesn't need it
16. [ ] **Vendor-neutral backend** (Vulkan compute) for AMD and Intel GPUs

## Done

- [x] **Anime mode re-tuned on 11 animation scenes** (`test/testset_animation.txt`): 32 px, lambda 0.5, mask 1.0, satd; the earlier lambda 2.0 / pnew 100 setting was overfitted to Golgo 13 and pulled characters along with panning backgrounds in Avatar
- [x] **Parallel processing**: analysis stays serial, rendering and copy-out run 3 frames at a time on their own streams (`fmParallel`); frames and fields being rendered from are protected from eviction. +21% at 4K, +31-35% at 1080p, identical output
- [x] ~~Hybrid with RIFE~~: dropped. RIFE can't sustain 120 fps (about 76 at 1080p) and reloads for seconds on every seek
- [x] **Motion search options** (`lsad`, `plevel`, `pnew`, `pzero`, `badsad`/`badrange`, `trymany`, `satd`): all implemented; Ctrl+9 uses `pnew=100` and `satd=1` (anime-1 34.67 -> 35.16, anime-2 33.77 -> 33.94, hardest frames 30.04 -> 30.65, no speed cost); the others showed no gain
- [x] **Zoom estimation** (`zoom`): shift + zoom + rotation fitted to each coarse level; zooms up to 2%/frame were already 54-56 dB without it, crash zooms (4-10%/frame) gain +0.1 to +0.6 dB; neutral elsewhere, ~6% slower in the block search
- [x] **NVIDIA optical-flow hardware** (`nvof`): RTX 5080 has it (`test/nvof_probe.cmd`: 1080p 0.8-1.8 ms, 4K 2-6 ms per pair). As gpumv's motion source it beats the block search on all 8 live-action film scenes (+0.17 dB average at the medium level) and is faster at 4K; Ctrl+8 uses it, Ctrl+9 keeps the block search
- [x] **mpv crash on exit**: not gpumv or any plugin; a do-nothing VapourSynth script with no plugins loaded crashes the same way at shutdown (mpv/VapourSynth/embedded Python). Documented, harmless
- [x] **Fast action and motion blur**: tested (`pans.py blur=1`), no change needed: blurred pans stay clean (116 dB at 80 px/pair, 40 dB at 200), masking strength makes no difference; blurred action in the film set already beats MVTools
- [x] **Rolling credits**: tested (`credits.py`): 68-111 dB at 2-16 px/frame, against 17-24 dB for blending
- [x] **Particles, water, fire, rain**: covered by artifact masking; revisit with a failing example
- [x] **Telecine / interlaced sources**: documented as a limit (README); not automated, since deinterlacing can double the frame rate behind gpumv's back
- [x] **Film look** (`strength`, Look: Smooth / Natural in the window): real frames held for part of each gap; from 24 fps, Natural builds 40% of the frames instead of 80%
- [x] **Settings window** (Ctrl+G, `smoothing-settings.ps1`): WPF window talking to mpv over its IPC pipe; replaces the old Ctrl+M text menu
- [x] **Per-block coherence by texture** (`lambdaflat`), to replace the two modes: tried, off. It hurts live action (blur and soft backgrounds look flat) before it helps anime enough
- [x] **Anime quality**: Ctrl+9 preset (32 px blocks, lambda 2.0, mask 1.0) beats MVTools on the anime scenes (34.23 vs 34.15 dB, worst frames 30.04 vs 28.03 on one); live action keeps Ctrl+8, where these settings would cost up to 3.4 dB
- [x] **Letterbox bars** (`bars`): detected in matching pairs and held for half a second before use; bars stay exactly black, picture next to them improves, no false detections on clips without bars
- [x] **Static overlays**: adaptive mode keeps burned-in subtitles intact (+3 to +6 dB over flow mode); the extra `static` rule added nothing and is off
- [x] **Real movie test set**: `test/testset.py` over 10 scenes from 5 films; gpumv adaptive beats MVTools by 1.3 dB on average
- [x] **Packaging**: CI no longer ships the `gpumv/` source folder; the DLL is already in the payload's plugins folder
- [x] **Fades** (`fades`): brightness compensation before matching, +1 dB on a bright fade
- [x] **Camera pans** (`gmv`): whole-frame shift search at the coarsest level; centre of a 200 px/pair pan from 31.8 to 44.6 dB
- [x] **Grain prefilter** (`prefilter`): implemented, no gain measured on grainy film, off
- [x] **Held frames** (`dedup`): animation on twos/threes gets the motion spread over the held frames (+4.5 to +8.7 dB); still shots untouched; no triggers on live action
- [x] CUDA plugin: pyramid, hierarchical block matching both directions, rendering
- [x] Block (BlockFPS-like), flow (FlowFPS-like) and adaptive modes
- [x] Scene cuts: fixed thresholds plus error spike against neighbouring pairs; nearest real frame instead of a cross-fade
- [x] Temporal candidate (SVP `prev`)
- [x] Block splitting (SVP `refine`), off: no gain on the test clips
- [x] Pinned-memory transfers
- [x] mpv integration: Ctrl+8, menu entry, `gpumv_*` settings, display-rate `auto` target, A/V sync
