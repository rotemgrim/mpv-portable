-- Applies a VapourSynth interpolation filter: script-message vs-mode <name>
-- Re-applies the active one after its settings changed: script-message vs-reload
-- The .vpy scripts take the source rate from mpv's container_fps, which some
-- files (many streams) don't have. For those, the rate mpv measured before any
-- filter changed it is handed over in a file that vs_fps.py reads.

local filters = {
    motion = 'vapoursynth="~~/motion.vpy":buffered-frames=8',
    rife   = 'vapoursynth="~~/rife.vpy":buffered-frames=4:concurrent-frames=4',
    svp    = 'vapoursynth="~~/svp.vpy":buffered-frames=8:concurrent-frames=8',
    gpumv  = 'vapoursynth="~~/gpumv.vpy":buffered-frames=8',
    gpumv_anime = 'vapoursynth="~~/gpumv_anime.vpy":buffered-frames=8',
}
-- Script file name -> mode, for finding the active one
local by_script = {motion = "motion", rife = "rife", svp = "svp", gpumv = "gpumv", gpumv_anime = "gpumv_anime"}

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
