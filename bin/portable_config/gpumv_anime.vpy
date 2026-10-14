# gpumv tuned for animation (Ctrl+9): gpumv.vpy with the gpumv_anime_* settings
import os

ANIME = True
_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gpumv.vpy")
exec(compile(open(_script).read(), _script, "exec"))
