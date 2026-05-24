-- VapourSynth MVTools parameter editor
-- Press Ctrl+M to open/close the menu
-- Navigate: Up/Down  |  Change: Left/Right  |  Apply & reload: Enter  |  Close: Esc

local utils = require("mp.utils")
local msg = require("mp.msg")

local active = false
local cursor = 1
local dirty = false

-- Config file path (next to mpv.conf)
local config_path = mp.find_config_file("vs_config.conf")
if not config_path then
    local mpv_conf = mp.find_config_file("mpv.conf")
    if mpv_conf then
        config_path = mpv_conf:gsub("mpv%.conf$", "vs_config.conf")
    end
end

-- Parameter definitions: key, display name, type, min, max, step, options_list
local params = {
    { key="dst_fps",     name="Target FPS",        type="int",   min=24,  max=240, step=10,  desc="Output framerate. Match your monitor refresh rate" },
    { key="pel",         name="Sub-pixel (pel)",    type="choice", choices={1, 2, 4}, labels={"1 (fast)","2 (quality)","4 (best)"},  desc="Sub-pixel accuracy. Higher = sharper motion, slower" },
    { key="sharp",       name="Sharp (super)",      type="int",   min=0,   max=2,   step=1,   desc="Sub-pixel sharpness. 0=soft 1=bilinear 2=wiener" },
    { key="blksize",     name="Block size",         type="choice", choices={4, 8, 16, 32, 64}, labels={"4","8","16","32 (fast)","64"},  desc="Smaller = finer detail, much slower" },
    { key="overlap",     name="Overlap",            type="choice", choices={0, 2, 4, 8, 16, 32}, labels={"0 (off)","2","4","8","16","32"},  desc="Reduces blocky edges. Best at half of block size" },
    { key="search",      name="Search algorithm",   type="choice", choices={0, 1, 2, 3, 4, 5}, labels={"0 onetime","1 nstep","2 hex","3 exhaustive","4 UMH","5 SATD hex"},  desc="Motion search method. Higher = more accurate, slower" },
    { key="searchparam", name="Search radius",      type="int",   min=1,   max=16,  step=1,   desc="Search distance. Higher = better for fast motion" },
    { key="truemotion",  name="True motion",        type="choice", choices={0, 1}, labels={"0 (off)","1 (on)"},  desc="Smooth consistent motion vs raw pixel matching" },
    { key="dct",         name="DCT mode",           type="choice", choices={0, 1, 2, 3, 4, 5}, labels={"0 SAD","1 DCT","2 SATD","3 DCT+SAD","4 DCT+SATD","5 SATD (fftw)"},  desc="Block comparison. SATD = more accurate, slower" },
    { key="use_flow",    name="Algorithm",          type="choice", choices={0, 1}, labels={"BlockFPS","FlowFPS"},  desc="BlockFPS=fast block warp. FlowFPS=smooth optical flow" },
    { key="mode",        name="BlockFPS mode",      type="choice", choices={0, 1, 2, 3}, labels={"0 overlap","1 shift","2 average","3 adaptive"},  desc="Block blend method. Adaptive usually looks best" },
    { key="blend",       name="Scene change blend", type="choice", choices={0, 1}, labels={"0 repeat","1 blend"},  desc="Repeat last frame or blend on scene change" },
    { key="thscd1",      name="SC threshold 1",     type="int",   min=50,  max=1000, step=50,  desc="Scene change sensitivity. Lower = more sensitive" },
    { key="thscd2",      name="SC threshold 2",     type="int",   min=20,  max=255,  step=10,  desc="Block change % for scene change. Lower = more sensitive" },
    { key="ml",          name="Bad block mask",     type="float", min=0,   max=400,  step=10,  desc="Mask bad motion. Lower = stricter, fewer artifacts" },
    { key="threads",     name="Threads (0=auto)",   type="int",   min=0,   max=32,   step=1,   desc="CPU threads. 0 = use all available cores" },
    { key="_sep_rife",    name="─── RIFE AI (GPU) ───", type="separator" },
    { key="rife_multi",   name="FPS multiplier",      type="choice", choices={2, 2.5, 3, 4}, labels={"2x","2.5x","3x","4x"},  desc="Multiply source FPS. 24fps x2 = 48fps, x2.5 = 60fps" },
    { key="rife_model",   name="Model version",       type="choice", choices={46, 410}, labels={"v4.6","v4.10"},  desc="v4.6 = fast & compatible. v4.10 = newer, better quality" },
    { key="rife_streams", name="GPU streams",         type="int",   min=1,   max=8,   step=1,   desc="Parallel GPU work. More = faster but more VRAM" },
    { key="rife_fp16",    name="Half precision",      type="choice", choices={0, 1}, labels={"off (accurate)","on (fast)"},  desc="FP16 uses less VRAM and is faster. Minimal quality loss" },
    { key="rife_ensemble", name="Ensemble mode",      type="choice", choices={0, 1}, labels={"off","on"},  desc="Better quality but 2x slower. Averages multiple predictions" },
}

-- Default values
local defaults = {
    dst_fps=60, pel=1, sharp=2, blksize=32, overlap=0,
    search=2, searchparam=2, truemotion=1, dct=0,
    mode=3, blend=1, thscd1=400, thscd2=130, ml=100.0,
    use_flow=0, threads=4,
    rife_multi=2, rife_model=46, rife_streams=2, rife_fp16=1, rife_ensemble=0
}

-- 4K preset: lightweight settings for high-res video
local preset_4k = {
    dst_fps=60, pel=1, sharp=2, blksize=64, overlap=0,
    search=1, searchparam=1, truemotion=1, dct=0,
    mode=3, blend=1, thscd1=400, thscd2=130, ml=100.0,
    use_flow=0, threads=0,
    rife_multi=2, rife_model=46, rife_streams=1, rife_fp16=1, rife_ensemble=0
}

-- Current values
local values = {}

local function read_config()
    local f = io.open(config_path, "r")
    if not f then return end
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1,1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
            if k and v then
                values[k] = tonumber(v) or v
            end
        end
    end
    f:close()
end

local function write_config()
    local f = io.open(config_path, "r")
    if not f then return end
    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()

    f = io.open(config_path, "w")
    if not f then return end
    for _, line in ipairs(lines) do
        local k = line:match("^([%w_]+)%s*=")
        if k and values[k] ~= nil then
            local v = values[k]
            if type(v) == "number" and v == math.floor(v) then
                f:write(k .. "=" .. string.format("%d", v) .. "\n")
            else
                f:write(k .. "=" .. tostring(v) .. "\n")
            end
        else
            f:write(line .. "\n")
        end
    end
    f:close()
end

local function get_choice_index(p)
    local v = values[p.key] or p.choices[1]
    for i, c in ipairs(p.choices) do
        if c == v then return i end
    end
    return 1
end

local function change_value(p, direction)
    if p.type == "separator" then return end
    if p.type == "choice" then
        local idx = get_choice_index(p) + direction
        if idx < 1 then idx = #p.choices end
        if idx > #p.choices then idx = 1 end
        values[p.key] = p.choices[idx]
    elseif p.type == "int" then
        local v = (values[p.key] or p.min) + direction * p.step
        if v < p.min then v = p.min end
        if v > p.max then v = p.max end
        values[p.key] = v
    elseif p.type == "float" then
        local v = (values[p.key] or p.min) + direction * p.step
        if v < p.min then v = p.min end
        if v > p.max then v = p.max end
        values[p.key] = v
    end
    dirty = true
end

local function format_value(p)
    local v = values[p.key]
    local is_default = (v == defaults[p.key])
    local suffix = is_default and "  (default)" or ""
    if p.type == "choice" then
        local idx = get_choice_index(p)
        return (p.labels[idx] or tostring(v)) .. suffix
    elseif p.type == "float" then
        return string.format("%.1f", v or 0) .. suffix
    else
        return tostring(v or "?") .. suffix
    end
end

local function render_menu()
    if not active then
        mp.set_osd_ass(0, 0, "")
        return
    end

    -- Use fixed PlayRes so ASS scales automatically with window size
    local play_w = 1600
    local play_h = 900

    local fs_h = 30
    local fs_n = 24
    local fs_d = 21
    local bord = 2.5

    local header_style = string.format("{\\fnConsolas\\fs%d\\bord%g\\b1\\c&H00CCFF&\\3c&H000000&}", fs_h, bord)
    local normal_style = string.format("{\\fnConsolas\\fs%d\\bord%g\\c&HFFFFFF&\\3c&H000000&}", fs_n, bord)
    local cursor_style = string.format("{\\fnConsolas\\fs%d\\bord%g\\c&H00CCFF&\\b1\\3c&H000000&}", fs_n, bord)
    local value_style  = string.format("{\\fnConsolas\\fs%d\\bord%g\\c&H66FF66&\\3c&H000000&}", fs_n, bord)
    local dirty_style  = string.format("{\\fnConsolas\\fs%d\\bord%g\\c&H6666FF&\\3c&H000000&}", fs_n, bord)
    local dim_style    = string.format("{\\fnConsolas\\fs%d\\bord%g\\c&H888888&\\3c&H000000&}", fs_d, bord)

    local lines = {}
    table.insert(lines, header_style .. "═══ VapourSynth MVTools Config ═══")
    table.insert(lines, dim_style .. "Up/Down: navigate  Left/Right: change  Enter: apply  Backspace: defaults  P: 4K preset  Esc: close")
    table.insert(lines, "")

    for i, p in ipairs(params) do
        if p.type == "separator" then
            table.insert(lines, header_style .. "  " .. p.name)
        else
            local style = (i == cursor) and cursor_style or normal_style
            local arrow = (i == cursor) and "► " or "  "
            local val = format_value(p)
            local vst = (i == cursor) and value_style or normal_style
            local dst = dim_style
            local name_padded = p.name .. string.rep(" ", 22 - #p.name)
            local val_padded = val .. string.rep(" ", 28 - #val)
            table.insert(lines, style .. arrow .. name_padded .. vst .. " ◄ " .. val_padded .. " ►  " .. dst .. (p.desc or ""))
        end
    end

    if dirty then
        table.insert(lines, "")
        table.insert(lines, dirty_style .. "  * Unsaved changes — press Enter to apply *")
    end

    local text = "{\\an7\\pos(25,20)}" .. table.concat(lines, "\\N")
    mp.set_osd_ass(play_w, play_h, text)
end

local function apply_and_reload()
    write_config()
    dirty = false

    -- Check if vapoursynth filter is active, reload it
    local vf = mp.get_property_native("vf")
    local found = false
    local found_filter = nil
    for i, f in ipairs(vf) do
        if f.name == "vapoursynth" then
            found = true
            -- Detect which script is active
            if f.params and f.params.file and f.params.file:find("rife") then
                found_filter = 'vapoursynth="~~/rife.vpy":buffered-frames=4:concurrent-frames=4'
            else
                found_filter = 'vapoursynth="~~/motion.vpy":buffered-frames=4:concurrent-frames=4'
            end
            break
        end
    end

    if found then
        -- Fully remove then re-add to force a clean reinit
        local vf_str = found_filter
        mp.command("no-osd vf clr \"\"")
        -- Small delay via timer to let the old filter fully tear down
        mp.add_timeout(0.3, function()
            mp.command("no-osd vf set " .. vf_str)
            mp.osd_message("Config applied & reloaded", 2)
        end)
    else
        mp.osd_message("Config saved (VapourSynth not active — use Ctrl+3)", 2)
    end

    render_menu()
end

local function on_key_up()
    if not active then return end
    cursor = cursor - 1
    if cursor < 1 then cursor = #params end
    if params[cursor].type == "separator" then
        cursor = cursor - 1
        if cursor < 1 then cursor = #params end
    end
    render_menu()
end

local function on_key_down()
    if not active then return end
    cursor = cursor + 1
    if cursor > #params then cursor = 1 end
    if params[cursor].type == "separator" then
        cursor = cursor + 1
        if cursor > #params then cursor = 1 end
    end
    render_menu()
end

local function on_key_left()
    if not active then return end
    change_value(params[cursor], -1)
    render_menu()
end

local function on_key_right()
    if not active then return end
    change_value(params[cursor], 1)
    render_menu()
end

local function on_key_enter()
    if not active then return end
    apply_and_reload()
end

local function on_key_reset()
    if not active then return end
    for k, v in pairs(defaults) do
        values[k] = v
    end
    dirty = true
    render_menu()
end

local function on_key_4k()
    if not active then return end
    for k, v in pairs(preset_4k) do
        values[k] = v
    end
    dirty = true
    render_menu()
end

local function on_key_esc()
    if not active then return end
    active = false
    mp.set_osd_ass(0, 0, "")
    unbind_keys()
end

function bind_keys()
    mp.add_forced_key_binding("UP",    "vs-menu-up",    on_key_up,    {repeatable=true})
    mp.add_forced_key_binding("DOWN",  "vs-menu-down",  on_key_down,  {repeatable=true})
    mp.add_forced_key_binding("LEFT",  "vs-menu-left",  on_key_left,  {repeatable=true})
    mp.add_forced_key_binding("RIGHT", "vs-menu-right", on_key_right, {repeatable=true})
    mp.add_forced_key_binding("ENTER", "vs-menu-enter", on_key_enter)
    mp.add_forced_key_binding("BS",    "vs-menu-reset", on_key_reset)
    mp.add_forced_key_binding("p",     "vs-menu-4k",    on_key_4k)
    mp.add_forced_key_binding("ESC",   "vs-menu-esc",   on_key_esc)
end

function unbind_keys()
    mp.remove_key_binding("vs-menu-up")
    mp.remove_key_binding("vs-menu-down")
    mp.remove_key_binding("vs-menu-left")
    mp.remove_key_binding("vs-menu-right")
    mp.remove_key_binding("vs-menu-enter")
    mp.remove_key_binding("vs-menu-reset")
    mp.remove_key_binding("vs-menu-4k")
    mp.remove_key_binding("vs-menu-esc")
end

local function toggle_menu()
    active = not active
    if active then
        read_config()
        dirty = false
        bind_keys()
        render_menu()
    else
        mp.set_osd_ass(0, 0, "")
        unbind_keys()
    end
end

mp.add_key_binding("Ctrl+m", "vs-menu-toggle", toggle_menu)
