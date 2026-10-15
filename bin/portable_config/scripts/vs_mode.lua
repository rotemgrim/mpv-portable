-- Applies a VapourSynth interpolation filter: script-message vs-mode <name>
-- Re-applies the active one after its settings changed: script-message vs-reload
-- The .vpy scripts take the source rate from mpv's container_fps, which some
-- files (many streams) don't have. For those, the rate mpv measured before any
-- filter changed it is handed over in a file that vs_fps.py reads.

local utils = require "mp.utils"

local filters = {
    motion = 'vapoursynth="~~/motion.vpy":buffered-frames=8',
    rife   = 'vapoursynth="~~/rife.vpy":buffered-frames=4:concurrent-frames=4',
    svp    = 'vapoursynth="~~/svp.vpy":buffered-frames=8:concurrent-frames=8',
    gpumv  = 'vapoursynth="~~/gpumv.vpy":buffered-frames=8',
    gpumv_anime = 'vapoursynth="~~/gpumv_anime.vpy":buffered-frames=8',
}
-- Script file name -> mode, for finding the active one
local by_script = {motion = "motion", rife = "rife", svp = "svp", gpumv = "gpumv", gpumv_anime = "gpumv_anime"}

-- What each mode needs, so a missing part gets a clear message instead of a
-- filter that silently fails. The installer leaves out RIFE and SVP.
local plugins = mp.command_native({"expand-path", "~~/../Lib/site-packages/vapoursynth/plugins/"})
local nvidia = os.getenv("SystemRoot") .. "\\System32\\nvcuda.dll"
local needs = {
    rife = {{plugins .. "models/rife", "RIFE is not included in this install"}},
    svp = {{plugins .. "svpflow1_vs.dll", "SVPflow is not included in this install"}},
    gpumv = {{nvidia, "gpumv needs an NVIDIA graphics card"}, {plugins .. "gpumv.dll", "gpumv is missing"}},
}
needs.gpumv_anime = needs.gpumv

local function missing(name)
    for _, need in ipairs(needs[name] or {}) do
        if not utils.file_info(need[1]) then return need[2] end
    end
end

local fps_file = mp.command_native({"expand-path", "~~/cache/measured_fps.txt"})
local measured

local function write_fps(fps)
    local f = io.open(fps_file, "w")
    if f then
        f:write(fps and string.format("%.6f", fps) or "")
        f:close()
    end
end

local function apply(name)
    local vf = filters[name]
    if not vf then return end
    local why = missing(name)
    if why then
        -- The key binding already turned mpv's own interpolation off
        mp.command('no-osd vf clr ""')
        mp.osd_message(why .. ", smoothing is off", 5)
        return
    end
    -- Only trust the estimate while no filter is altering the frame rate
    if not measured and #mp.get_property_native("vf", {}) == 0 then
        measured = mp.get_property_number("estimated-vf-fps")
    end
    write_fps(measured)
    mp.command("no-osd vf set " .. vf)
end

mp.register_event("start-file", function()
    measured = nil
    write_fps(nil)
end)

mp.register_script_message("vs-mode", apply)

mp.register_script_message("vs-reload", function()
    for _, f in ipairs(mp.get_property_native("vf", {})) do
        if f.name == "vapoursynth" then
            local file = f.params and f.params.file or ""
            local name = by_script[file:match("([%w_]+)%.vpy")]
            if name then
                -- Remove, then re-add, so the script starts over with the new settings
                mp.command('no-osd vf clr ""')
                mp.add_timeout(0.3, function() apply(name) end)
            end
            return
        end
    end
end)
