# mpv-portable

Portable mpv player setup with VapourSynth frame interpolation plugins.

## Contents

- **mpv** — video player (gpu-hq profile, display-resample)
- **VapourSynth** — embedded Python 3.14 + VapourSynth scripting
- **MVTools** — CPU-based motion-compensated interpolation
- **SVPflow** — GPU-accelerated (OpenCL) motion-compensated interpolation
- **RIFE** — AI-based frame interpolation (GPU via DirectML/ONNX Runtime)
- **ONNX models** — RIFE v4.6 and v4.10

## Interpolation Modes (Keybindings)

| Key      | Mode                              | Engine            |
|----------|-----------------------------------|-------------------|
| Ctrl+1   | No interpolation                  | —                 |
| Ctrl+2   | Built-in oversample               | GPU (mpv)         |
| Ctrl+3   | SVPflow (60fps)                   | GPU (OpenCL)      |
| Ctrl+4   | RIFE AI interpolation             | GPU (DirectML)    |
| Ctrl+5   | Built-in sphinx                   | GPU (mpv)         |
| Ctrl+6   | minterpolate (FFmpeg)             | CPU               |
| Ctrl+7   | MVTools (60fps)                   | CPU               |

## Configuration

Edit `portable_config/vs_config.conf` to adjust:
- Target FPS, block size, search params (MVTools/SVPflow)
- RIFE model, multiplier, precision, ensemble mode

## Usage

Just run `mpv.exe` — everything is self-contained and portable.
