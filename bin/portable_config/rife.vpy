import vapoursynth as vs
import os
import sys

core = vs.core

# Add site-packages to path for vsmlrt
script_dir = os.path.dirname(os.path.abspath(__file__))
site_packages = os.path.join(os.path.dirname(script_dir), "Lib", "site-packages")
if site_packages not in sys.path:
    sys.path.insert(0, site_packages)

import vsmlrt
from fractions import Fraction

sys.path.insert(0, script_dir)
from vs_fps import assume_source_fps, target_fps

# Load config
config = {}
config_path = os.path.join(script_dir, "vs_config.conf")
if os.path.exists(config_path):
    with open(config_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                config[k.strip()] = v.strip()

def cfg_int(key, default):
    try: return int(config.get(key, default))
    except: return default

def cfg_float(key, default):
    try: return float(config.get(key, default))
    except: return default

rife_multi    = config.get("rife_multi", "auto")  # "auto" follows the display
rife_max_fps  = cfg_float("rife_max_fps", 60)     # cap for auto
rife_model_id = cfg_int("rife_model", 46)
rife_streams  = cfg_int("rife_streams", 2)
rife_fp16     = cfg_int("rife_fp16", 1)
rife_ensemble = cfg_int("rife_ensemble", 0)

# Map model ID to enum
model_map = {m.value: m for m in vsmlrt.RIFEModel}
rife_model = model_map.get(rife_model_id, vsmlrt.RIFEModel.v4_6)

clip = video_in

# mpv leaves video_in.fps at 0; take the rate from container_fps
clip = assume_source_fps(core, clip, globals().get("container_fps", 0))

# Fraction multipliers (e.g. 2.5) are supported; "auto" makes the output hit
# the display rate, or the largest even fraction of it within rife_max_fps
if str(rife_multi).strip().lower() == "auto":
    multi = target_fps("auto", globals().get("display_fps", 0), rife_max_fps) / clip.fps
else:
    multi = Fraction(str(rife_multi)).limit_denominator(10)

# RIFE needs RGB input
orig_w = clip.width
orig_h = clip.height

# Pad to multiple of 32 (RIFE requirement)
pad_w = (32 - orig_w % 32) % 32
pad_h = (32 - orig_h % 32) % 32
if pad_w or pad_h:
    clip = core.std.AddBorders(clip, right=pad_w, bottom=pad_h)

clip_rgb = core.resize.Bicubic(clip, format=vs.RGBS, matrix_in_s="709")

# Backend preference: TRT_RTX (fastest on RTX, native Blackwell support)
# > ORT_CUDA > ORT_DML (any GPU vendor).
plugins_dir = os.path.join(site_packages, "vapoursynth", "plugins")
vsort_dir   = os.path.join(plugins_dir, "vsort")
trt_rtx_exe = os.path.join(plugins_dir, "vsmlrt-cuda", "tensorrt_rtx.exe")
# The bundled vsort plugin is built against CUDA 13: requires cublas64_13.dll
# (CUDA 12's cublas64_12.dll is the wrong major version).
has_trt_rtx  = os.path.exists(trt_rtx_exe) and os.path.exists(os.path.join(plugins_dir, "vstrt_rtx.dll"))
has_cuda_dlls = os.path.exists(os.path.join(vsort_dir, "cublas64_13.dll"))

if has_trt_rtx:
    try:
        os.add_dll_directory(os.path.join(plugins_dir, "vsmlrt-cuda"))
    except (AttributeError, OSError):
        pass
    # fp16=False here: vsmlrt's fp16 path imports the `onnx` PyPI package to
    # rewrite the ONNX file in Python, which isn't installed in the embeddable
    # Python. TensorRT-RTX still runs on Tensor cores with fp32 I/O.
    backend = vsmlrt.Backend.TRT_RTX(
        num_streams=rife_streams,
        fp16=False,
        use_cuda_graph=True,
    )
elif has_cuda_dlls:
    # Ensure the loader finds CUDA/cuDNN DLLs we dropped next to onnxruntime.dll
    try:
        os.add_dll_directory(vsort_dir)
    except (AttributeError, OSError):
        pass
    backend = vsmlrt.Backend.ORT_CUDA(
        num_streams=rife_streams,
        fp16=bool(rife_fp16),
        cudnn_benchmark=True,
    )
else:
    backend = vsmlrt.Backend.ORT_DML(
        num_streams=rife_streams,
        fp16=bool(rife_fp16),
    )

# Nothing to interpolate when the source is already at or above the target
if multi > 1:
    clip_rgb = vsmlrt.RIFE(
        clip_rgb,
        multi=multi,
        model=rife_model,
        backend=backend,
        ensemble=bool(rife_ensemble),
        video_player=True,
    )

# Convert back to original format and crop padding
clip = core.resize.Bicubic(clip_rgb, format=clip.format.id if clip.format else vs.YUV420P8, matrix_s="709")
if pad_w or pad_h:
    clip = core.std.Crop(clip, right=pad_w, bottom=pad_h)
clip.set_output()
