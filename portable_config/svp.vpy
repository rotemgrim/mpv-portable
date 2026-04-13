import vapoursynth as vs
import os

core = vs.core

# Load config from vs_config.conf
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

dst_fps = cfg_int("dst_fps", 60)

clip = video_in
original_format = clip.format.id if clip.format else vs.YUV420P8

# Assume source FPS if not set
if clip.fps.numerator == 0:
    clip = core.std.AssumeFPS(clip, fpsnum=24000, fpsden=1001)

src_fps = clip.fps.numerator / clip.fps.denominator

# SVPflow requires YV12 (YUV420P8) for analysis
input_m8 = clip
if clip.format.id != vs.YUV420P8:
    input_m8 = core.resize.Bicubic(clip, format=vs.YUV420P8)

# SVPflow uses JSON-like strings for parameters
# gpu=1 enables OpenCL GPU acceleration

# Super: build multi-resolution representation, gpu=1 for GPU
super_params = "{gpu:1, pel:1, scale:{up:0}}"
sup = core.svp1.Super(input_m8, super_params)

# Analyse: find motion vectors, gpu=1 for GPU
analyse_params = "{gpu:1, block:{w:32, h:32, overlap:0}, main:{search:{type:2, distance:2}}, refine:[{thsad:250}]}"
vectors = core.svp1.Analyse(sup["clip"], sup["data"], input_m8, analyse_params)

# SmoothFps: interpolate to target fps
smooth_params = "{{gpu:1, rate:{{num:{num}, den:1, abs:true}}, algo:23, scene:{{mode:0, limits:{{scene:6000, zero:150, luma:10}}}}}}".format(
    num=dst_fps
)
clip = core.svp2.SmoothFps(clip, sup["clip"], sup["data"], vectors["clip"], vectors["data"], smooth_params, src=video_in, fps=src_fps)

# Set correct output fps
clip = core.std.AssumeFPS(clip, fpsnum=dst_fps, fpsden=1)

clip.set_output()
