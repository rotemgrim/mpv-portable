-- Opens the motion smoothing settings window (Ctrl+G, or the menu).
-- The window (smoothing-settings.ps1) talks to this mpv through its JSON IPC
-- pipe; each mpv gets its own pipe so the window controls the right player.

local utils = require "mp.utils"

local pipe = "mpv-portable-" .. utils.getpid()
mp.set_property("input-ipc-server", "\\\\.\\pipe\\" .. pipe)

local gui = mp.command_native({"expand-path", "~~/smoothing-settings.ps1"})

local function open()
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        detach = true,
        args = {"powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                "-File", gui, pipe},
    }, function() end)
end

mp.add_key_binding("Ctrl+g", "smoothing-settings", open)
mp.register_script_message("smoothing-settings", open)
