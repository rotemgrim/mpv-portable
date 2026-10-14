# gpumv feature list

Ordered by impact on everyday movie watching, most impactful first.

## To do

1. [ ] **Publish the release payload** with `gpumv.dll`: run `tools\build-payload.ps1` (uploads to the `payload` release). CI already excludes the `gpumv/` source folder from the package
2. [ ] **Detect animation automatically** and switch to the anime settings, instead of Ctrl+9. Held frames alone aren't enough (one of the two anime test scenes has none)
3. [ ] **Interpolation strength / film look**: setting that keeps some of the original cadence, for people who dislike the soap-opera effect
4. [ ] **Fast action and motion blur**: fall back to blending where blur makes matching unreliable (very fast pans now work up to a quarter of the frame width per frame pair)
5. [ ] **NVIDIA optical-flow hardware**: confirm the RTX 5080 has it (probe program with NVIDIA's public SDK headers), then try it for motion vectors like SVP's `SmoothFps_NVOF`
6. [ ] **Lip-sync check with real speakers** and a **4K playback check** on a normally running display (tests so far used simulated audio, and the display was misreporting its refresh rate)
7. [ ] **Telecine / interlaced sources**: document or automate inverse telecine (`vf=ivtc`) before interpolation
8. [ ] **Particles, water, fire, rain**: detect areas with high motion variance and blend them
9. [ ] **Rolling credits and scrolling text**: check with the camera-motion search and adaptive mode
10. [ ] **Hybrid with RIFE**: AI frames combined with motion vectors, like SVP's `SmoothFps_RIFE`
11. [ ] **Zoom estimation**: camera motion currently covers pans only
12. [ ] **Motion search options from SVP / MVTools** not implemented yet:
    - [ ] `coarse.bad`: wider re-search at the coarse level for blocks that still match badly
    - [ ] `lsad`: weaken the coherence penalty where the match error is high
    - [ ] `plevel`: lambda scaling per pyramid level
    - [ ] `pnew`: penalty for vectors that differ from all predictors
    - [ ] `trymany`: try several starting predictors fully instead of picking one first
    - [ ] `satd`: Hadamard-transform matching cost instead of SAD
13. [ ] **mpv crash on exit** after any VapourSynth filter (also with MVTools and RIFE); harmless during playback
14. [ ] **Parallel processing**: several CUDA streams, overlapping uploads, compute and downloads. Speed is already 2.5x real time at 4K/120
15. [ ] **Overlapped blocks** for smoother block-mode (`mode=0`) output; the default adaptive mode doesn't need it
16. [ ] **Vendor-neutral backend** (Vulkan compute) for AMD and Intel GPUs

## Done

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
