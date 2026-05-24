import vapoursynth as vs
import os

core = vs.core

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
dst_fps     = cfg_int("dst_fps", 60)
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

# Assume source FPS if not set
if clip.fps.numerator == 0:
    clip = core.std.AssumeFPS(clip, fpsnum=24000, fpsden=1001)

sup = core.mv.Super(clip, pel=pel, sharp=sharp)
bvec = core.mv.Analyse(sup, isb=True, blksize=blksize, overlap=overlap,
                        search=search, searchparam=searchparam,
                        truemotion=truemotion, dct=dct)
fvec = core.mv.Analyse(sup, isb=False, blksize=blksize, overlap=overlap,
                        search=search, searchparam=searchparam,
                        truemotion=truemotion, dct=dct)

if use_flow:
    clip = core.mv.FlowFPS(clip, sup, bvec, fvec,
                            num=dst_fps, den=1,
                            blend=blend, thscd1=thscd1, thscd2=thscd2, ml=ml)
else:
    clip = core.mv.BlockFPS(clip, sup, bvec, fvec,
                             num=dst_fps, den=1, mode=mode,
                             blend=blend, thscd1=thscd1, thscd2=thscd2, ml=ml)

clip.set_output()
