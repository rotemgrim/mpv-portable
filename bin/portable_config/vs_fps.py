import os
from fractions import Fraction

STANDARD = [Fraction(24000, 1001), Fraction(24), Fraction(25), Fraction(30000, 1001), Fraction(30),
            Fraction(48), Fraction(50), Fraction(60000, 1001), Fraction(60)]

# Written by scripts/vs_mode.lua when the file has no container fps
MEASURED_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache", "measured_fps.txt")


def read_measured():
    try:
        with open(MEASURED_FILE) as f:
            return float(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def source_fps(container_fps):
    """mpv never sets video_in.fps, only the container_fps global, which can be
    missing (0) or a rounded float. Snap it to the exact standard rate."""
    fps = container_fps if container_fps and container_fps > 0 else read_measured()
    if fps <= 0:
        return Fraction(24000, 1001)
    best = min(STANDARD, key=lambda f: abs(float(f) - fps))
    if abs(float(best) - fps) / fps < 0.002:
        return best
    return Fraction(fps).limit_denominator(1001)


def assume_source_fps(core, clip, container_fps):
    fps = source_fps(container_fps)
    return core.std.AssumeFPS(clip, fpsnum=fps.numerator, fpsden=fps.denominator)


def display_rate(display_fps):
    """Snap mpv's display_fps (e.g. 119.88 or 143.998) to N or N*1000/1001."""
    if not display_fps or display_fps <= 0:
        return Fraction(60)
    candidates = [Fraction(round(display_fps)), Fraction(round(display_fps * 1.001) * 1000, 1001)]
    best = min(candidates, key=lambda f: abs(float(f) - display_fps))
    if abs(float(best) - display_fps) / display_fps < 0.001:
        return best
    return Fraction(display_fps).limit_denominator(1001)


def target_fps(setting, display_fps, max_fps):
    """'auto' gives the display rate, divided by the smallest whole number that
    brings it to max_fps or below, so every output frame lasts an equal number
    of refreshes. Anything else is taken as a fixed rate."""
    if str(setting).strip().lower() != "auto":
        return Fraction(str(setting))
    rate = display_rate(display_fps)
    divisor = 1
    while rate / divisor > max_fps:
        divisor += 1
    return rate / divisor
