# mpv-portable

Portable mpv player setup with VapourSynth frame interpolation plugins.

## Contents

- **mpv** — video player (gpu-hq profile, display-resample)
- **VapourSynth** — embedded Python 3.14 + VapourSynth scripting
- **MVTools** — CPU-based motion-compensated interpolation
- **SVPflow** — GPU-accelerated (OpenCL) motion-compensated interpolation
- **RIFE** — AI-based frame interpolation (GPU via ONNX Runtime: CUDA on NVIDIA, DirectML elsewhere)
- **ONNX models** — RIFE v4.6 and v4.10

## Interpolation Modes (Keybindings)

| Key      | Mode                              | Engine            |
|----------|-----------------------------------|-------------------|
| Ctrl+1   | No interpolation                  | —                 |
| Ctrl+2   | Built-in oversample               | GPU (mpv)         |
| Ctrl+3   | MVTools (60fps)                   | CPU               |
| Ctrl+4   | RIFE AI interpolation             | GPU (CUDA / DML)  |
| Ctrl+5   | Built-in sphinx                   | GPU (mpv)         |
| Ctrl+6   | minterpolate (FFmpeg)             | CPU               |
| Ctrl+7   | SVPflow (60fps)                   | GPU (OpenCL)      |

## Configuration

Edit `portable_config/vs_config.conf` to adjust:
- Target FPS, block size, search params (MVTools/SVPflow)
- RIFE model, multiplier, precision, ensemble mode

## Usage

Just run `mpv.exe` — everything is self-contained and portable.

## Getting a build

- **End users**: download `mpv-portable.exe` from the [latest release](../../releases/latest), double-click, choose a folder, and the portable install is extracted there. Run `bin\mpv.exe` to launch.
- **From source (dev)**: clone this repo, then run `./bootstrap.ps1` once. It downloads the binary payload (mpv.exe, VapourSynth plugins, ONNX models, ...) from the `payload` release tag and extracts it into `bin/`. The repo itself only tracks small text/config/script files; binaries are kept out of git to avoid LFS bandwidth limits.

## Refreshing the binary payload

Run `./tools/build-payload.ps1` whenever you update something heavy under `bin/` (new mpv build, updated VS plugin, new ONNX model). It packs the gitignored binaries into `payload.7z` and uploads to the rolling `payload` release tag (requires the `gh` CLI). The next CI build, and any fresh `bootstrap.ps1` invocation, will pick it up automatically.

## Optional: NVIDIA CUDA acceleration for RIFE

By default RIFE runs on **DirectML** (works on any GPU). On NVIDIA GPUs, CUDA is ~1.5–2× faster.

The CUDA 13 + cuDNN 9 runtime DLLs (~2 GB extracted) are **not committed to git**. To enable CUDA:

1. Double-click `setup-cuda.bat` (or run `powershell -ExecutionPolicy Bypass -File setup-cuda.ps1`).
2. It downloads the required components straight from NVIDIA and extracts them into `Lib\site-packages\vapoursynth\plugins\vsort\`:
   - CUDA 13.2 redistributables: `cuda_cudart`, `libcublas`, `libcufft`, `cuda_cupti`
   - cuDNN **9.19.0.56** for CUDA 13 (pinned: the bundled `onnxruntime_providers_cuda.dll` was linked against this exact version; newer cuDNN 9.22 from PyPI breaks the frontend ABI with `CUDNN_BACKEND_API_FAILED`)
3. Restart mpv. `rife.vpy` auto-detects `cublas64_13.dll` and switches to `ORT_CUDA`. If the DLLs aren't present, it transparently falls back to DirectML.

Requires a recent NVIDIA driver (CUDA 13 compatible, i.e. R580+ / 580.xx or later).

## Optional: NVIDIA TensorRT-RTX acceleration for RIFE

Even faster than CUDA on RTX GPUs (Ampere/Ada/Blackwell). The TensorRT-RTX
runtime (~3 GB extracted) is **not committed to git or shipped in the
release**. To enable:

```powershell
powershell -ExecutionPolicy Bypass -File bin\setup-trt.ps1
```

It downloads the `vsmlrt-cuda` and `vstrt-rtx` parts of the upstream
[vs-mlrt](https://github.com/AmusementClub/vs-mlrt) release and extracts
the TensorRT-RTX runtime into `bin\Lib\site-packages\vapoursynth\plugins\vsmlrt-cuda\`.
First RIFE run JIT-builds an engine for your specific GPU (~10-30 s);
subsequent runs use the cached engine.

### Troubleshooting

If RIFE fails with `cuda DLL preloading failed`, set `VSORT_VERBOSE=1` and check stderr — vsort will print which DLL is missing. The full list it requires (filename-prefix match) is in [`vsort/win32.cpp`](https://github.com/AmusementClub/vs-mlrt/blob/master/vsort/win32.cpp): `cudart64`, `cublas64`, `cublasLt64`, `cufft64`, `cudnn*64` (full stack), `cupti64`.
