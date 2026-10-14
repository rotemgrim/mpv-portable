import vapoursynth as vs
import os
import sys

core = vs.core

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vs_fps import assume_source_fps, target_fps

# Load config from vs_config.conf next to this script
config = {}
config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vs_config.conf")
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

# Shares the MVTools settings so Ctrl+3 and Ctrl+8 are directly comparable
dst_fps = config.get("dst_fps", "auto")
max_fps = cfg_float("max_fps", 120)

# gpumv_anime.vpy (Ctrl+9) runs this script with ANIME set: flat line art wants
# bigger blocks and a more coherent vector field than live action
anime = globals().get("ANIME", False)
tuned = (("gpumv_anime_blksize", 32), ("gpumv_anime_lambda", 2.0), ("gpumv_anime_mask", 1.0)) if anime else \
        (("gpumv_blksize", 16), ("gpumv_lambda", 0.1), ("gpumv_mask", 0.5))
blksize, lam, mask = cfg_int(*tuned[0]), cfg_float(*tuned[1]), cfg_float(*tuned[2])

clip = video_in

# mpv leaves video_in.fps at 0; take the rate from container_fps
clip = assume_source_fps(core, clip, globals().get("container_fps", 0))
dst = target_fps(dst_fps, globals().get("display_fps", 0), max_fps)

# Nothing to interpolate when the source is already at or above the target
if dst > clip.fps:
    clip = core.gpumv.Interpolate(
        clip, num=dst.numerator, den=dst.denominator,
        mode=cfg_int("gpumv_mode", 2),
        blksize=blksize,
        lambda_=lam,
        pel=cfg_int("pel", 1),
        blend=cfg_int("gpumv_blend", 0),
        thscd1=cfg_int("thscd1", 400),
        thscd2=cfg_int("thscd2", 130),
        ml=cfg_float("ml", 100.0),
        mask=mask,
        dedup=cfg_int("gpumv_dedup", 1),
        bars=cfg_int("gpumv_bars", 1),
        fades=cfg_int("gpumv_fades", 1),
    )

clip.set_output()
