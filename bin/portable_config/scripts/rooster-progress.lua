-- rooster-progress.lua
-- Sends playback progress to the RoosterX server every N seconds.
-- Auto-loaded by mpv when placed in portable_config/scripts/.
--
-- Optional: launch mpv with --script-opts=rooster-id=<mediaId> to tag the session.

local mp = require 'mp'
local utils = require 'mp.utils'

local ENDPOINT = "http://localhost:8080/api/progress"
local INTERVAL = 10  -- seconds

local function log(msg)
    mp.msg.info("[rooster-progress] " .. msg)
end

local function send_progress(reason)
    local percent  = mp.get_property_number("percent-pos")
    local time_pos = mp.get_property_number("time-pos")
    local duration = mp.get_property_number("duration")
    local path     = mp.get_property("path")
    local title    = mp.get_property("media-title")
    local pause    = mp.get_property_bool("pause")
    local eof      = mp.get_property_bool("eof-reached")
    local rooster_id = mp.get_opt("rooster-id") or ""

    if not path then return end

    local payload = {
        rooster_id = rooster_id,
        path       = path,
        title      = title or "",
        percent    = percent or 0,
        time_pos   = time_pos or 0,
        duration   = duration or 0,
        paused     = pause and true or false,
        eof        = eof and true or false,
        reason     = reason or "tick",
    }

    local body = utils.format_json(payload)
    if not body then return end

    log(string.format("ping reason=%s percent=%.1f path=%s", payload.reason, payload.percent, path))

    mp.command_native_async({
        name           = "subprocess",
        playback_only  = false,
        capture_stdout = false,
        capture_stderr = false,
        detach         = true,
        args           = {
            "curl", "-s", "-m", "3",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", body,
            ENDPOINT,
        },
    }, function() end)
end

local timer = mp.add_periodic_timer(INTERVAL, function() send_progress("tick") end)
timer:kill()

mp.observe_property("pause", "bool", function(_, paused)
    if paused then
        timer:kill()
        send_progress("pause")
    else
        timer:resume()
    end
end)

mp.register_event("file-loaded", function()
    send_progress("start")
    timer:resume()
end)

mp.register_event("end-file", function()
    send_progress("end")
    timer:kill()
end)
