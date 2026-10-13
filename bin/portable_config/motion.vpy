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

# Read all parameters
dst_fps     = config.get("dst_fps", "auto")  # "auto" follows the display
max_fps     = cfg_float("max_fps", 120)    # cap for auto
pel         = cfg_int("pel", 1)
sharp       = cfg_int("sharp", 2)
blksize     = cfg_int("blksize", 32)
overlap     = cfg_int("overlap", 0)
search      = cfg_int("search", 2)
searchparam = cfg_int("searchparam", 2)
truemotion  = cfg_int("truemotion", 1)
dct         = cfg_int("dct", 0)
mode        = cfg_int("mode", 3)
blend       = cfg_int("blend", 1)
thscd1      = cfg_int("thscd1", 400)
thscd2      = cfg_int("thscd2", 130)
ml          = cfg_float("ml", 100.0)
use_flow    = cfg_int("use_flow", 0)
threads     = cfg_int("threads", 4)

if threads > 0:
    core.num_threads = threads

clip = video_in

# mpv leaves video_in.fps at 0; take the rate from container_fps
clip = assume_source_fps(core, clip, globals().get("container_fps", 0))
dst = target_fps(dst_fps, globals().get("display_fps", 0), max_fps)

# Nothing to interpolate when the source is already at or above the target
if dst > clip.fps:
    sup = core.mv.Super(clip, pel=pel, sharp=sharp)
    bvec = core.mv.Analyse(sup, isb=True, blksize=blksize, overlap=overlap,
                            search=search, searchparam=searchparam,
                            truemotion=truemotion, dct=dct)
    fvec = core.mv.Analyse(sup, isb=False, blksize=blksize, overlap=overlap,
                            search=search, searchparam=searchparam,
                            truemotion=truemotion, dct=dct)

    if use_flow:
        clip = core.mv.FlowFPS(clip, sup, bvec, fvec,
                                num=dst.numerator, den=dst.denominator,
                                blend=blend, thscd1=thscd1, thscd2=thscd2, ml=ml)
    else:
        clip = core.mv.BlockFPS(clip, sup, bvec, fvec,
                                 num=dst.numerator, den=dst.denominator, mode=mode,
                                 blend=blend, thscd1=thscd1, thscd2=thscd2, ml=ml)

clip.set_output()
