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

rife_multi    = cfg_float("rife_multi", 2)
rife_model_id = cfg_int("rife_model", 46)
rife_streams  = cfg_int("rife_streams", 2)
rife_fp16     = cfg_int("rife_fp16", 1)
rife_ensemble = cfg_int("rife_ensemble", 0)

# Map model ID to enum
model_map = {m.value: m for m in vsmlrt.RIFEModel}
rife_model = model_map.get(rife_model_id, vsmlrt.RIFEModel.v4_6)

clip = video_in

# Assume source FPS if not set
if clip.fps.numerator == 0:
    clip = core.std.AssumeFPS(clip, fpsnum=24000, fpsden=1001)

# RIFE needs RGB input
clip_rgb = core.resize.Bicubic(clip, format=vs.RGBS, matrix_in_s="709")

from fractions import Fraction

# Convert multi to Fraction for RIFE (supports 2.5 etc)
rife_multi_frac = Fraction(rife_multi).limit_denominator(10)

# Run RIFE via ORT DirectML (GPU)
clip_rgb = vsmlrt.RIFE(
    clip_rgb,
    multi=rife_multi_frac,
    model=rife_model,
    backend=vsmlrt.Backend.ORT_DML(
        num_streams=rife_streams,
        fp16=bool(rife_fp16),
    ),
    ensemble=bool(rife_ensemble),
    video_player=True,
)

# Convert back to original format
clip = core.resize.Bicubic(clip_rgb, format=clip.format.id if clip.format else vs.YUV420P8, matrix_s="709")
clip.set_output()
