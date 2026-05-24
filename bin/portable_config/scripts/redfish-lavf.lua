-- Redfish/SMBLibrary workaround: route reads through FFmpeg's file: protocol.
-- mpv's native Win32 stream gets 0-byte reads from the B:\ Redfish share.
-- FFmpeg's avio file: protocol uses a simpler ReadFile pattern that works.

local mp = require 'mp'

mp.add_hook("on_load", 50, function()
    local url = mp.get_property("stream-open-filename", "")
    if url:match("^[Bb]:[/\\]") then
        mp.set_property("stream-open-filename", "lavf://file:" .. url)
        mp.msg.info("redfish-lavf: rerouting " .. url)
    end
end)