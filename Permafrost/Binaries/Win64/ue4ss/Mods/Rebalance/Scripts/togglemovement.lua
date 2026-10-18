-- ToggleMovement module of the Rebalance mod (was its own mod until 2026-10-17).
-- Settings: Rebalance\config\ToggleMovement.lua
-- ToggleMovement: tap to crouch / tap to sprint instead of holding.
-- Works on the game's own calls, so whatever key is bound still applies:
--  Sprint: ALS SprintAction(bool) gets true on press, false on release.
--          The pre-hook rewrites that bool to the toggle state.
--  Crouch: the game calls ALS StanceAction (itself a crouch/stand toggle)
--          on press AND release, which is what makes crouch hold-only.
--          At hook time the bound key is down for a press and up for a
--          release. On release, MovementAction is set non-zero for the
--          duration of the call, so StanceAction exits early (its first
--          check), then restored. Presses still toggle as vanilla.
local TAG = "[PF ToggleMovement] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

-- Game-thread scheduling. LoopAsync + ExecuteInGameThread queues a new
-- callback from a worker thread on every tick; with several mods doing it,
-- UE4SS raced ("Ref was not function") and crashed the game on 2026-10-16.
-- This UE4SS build can loop directly on the game thread; the old pattern is
-- only a fallback.
local LIB = REBALANCE_LIB
local get, call = LIB.get, LIB.call  -- allocation-free, for the poll  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop

------------------------------------------------------------------ config
local DEFAULTS = {
    { "toggleCrouch",        1,   "1 = tap to crouch, 0 = vanilla hold" },
    { "toggleSprint",        1,   "1 = tap to sprint, 0 = vanilla hold" },
    { "sprintStopDelayMs",   100, "sprint turns off this long after you let go of WASD (ms)" },
    { "debugLog",            1,   "1 = log hook calls (first 30) for tuning" },
}

local function mod_root()
    if REBALANCE_ROOT then return REBALANCE_ROOT end
    local src = try(function() return debug.getinfo(1, "S").source end)
    if type(src) == "string" then
        src = src:gsub("^@", ""):gsub("/", "\\")
        local base = src:match("^(.*\\)[Ss]cripts\\main%.lua$")
        if base then return base end
    end
    local dirs = try(function() return IterateGameDirectories() end)
    local win64 = dirs and dirs.Game and dirs.Game.Binaries and dirs.Game.Binaries.Win64
    local root = win64 and win64.__absolute_path
    if type(root) == "string" then return root .. "\\ue4ss\\Mods\\ToggleMovement\\" end
    return nil
end

local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local root = mod_root()
    if not root then return cfg end
    local path = root .. "config\\ToggleMovement.lua"
    local f = io.open(path, "r")
    if not f then
        f = io.open(path, "w")
        if f then
            f:write("-- ToggleMovement settings. Restart the game to apply.\n")
            f:write("return {\n")
            for _, d in ipairs(DEFAULTS) do
                f:write(string.format("    %s = %s, -- %s\n", d[1], tostring(d[2]), d[3]))
            end
            f:write("}\n")
            f:close()
            log("created " .. path)
        end
        return cfg
    end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "config.lua", "t", {})  -- empty env: data only
    local user = chunk and try(chunk)
    if type(user) ~= "table" then
        log("config.lua unreadable, using defaults")
        return cfg
    end
    for _, d in ipairs(DEFAULTS) do
        local v = tonumber(user[d[1]])
        if v then cfg[d[1]] = v end
    end
    return cfg
end

local CFG = load_config()
for _, d in ipairs(DEFAULTS) do log(d[1] .. " = " .. tostring(CFG[d[1]])) end

-- Two budgets: raw hook calls (noisy) and state changes the poll makes.
local debug_left, hook_left = 150, 60
local function dbg(msg)
    if CFG.debugLog == 1 and debug_left > 0 then
        debug_left = debug_left - 1
        log(msg)
    end
end
local function dbg_hook(msg)
    if CFG.debugLog == 1 and hook_left > 0 then
        hook_left = hook_left - 1
        log(msg)
    end
end

------------------------------------------------------------------ key lookup
-- Keys bound to each action, read from the loaded input mapping contexts.
-- IA_Move collects the keys of every move action (name has "Move", not
-- "Look"), used to tell whether the player is still walking.
local keys = { IA_Stance = {}, IA_Sprint = {}, IA_Move = {} }
local keys_found = false

local function refresh_keys()
    local found = { IA_Stance = {}, IA_Sprint = {}, IA_Move = {} }
    for _, imc in ipairs(FindAllOf("InputMappingContext") or {}) do
        if not fname(imc):find("^Default__") then
            try(function()
                imc.Mappings:ForEach(function(_, elem)
                    local m = elem:get()
                    local action = fname(m.Action)
                    if action:find("Move") and not action:find("Look") then action = "IA_Move" end
                    if found[action] then
                        local k = try(function() return m.Key.KeyName:ToString() end)
                        if k and k ~= "None" then found[action][k] = true end
                    end
                end)
            end)
        end
    end
    local any = next(found.IA_Stance) ~= nil or next(found.IA_Sprint) ~= nil
    if any then
        local changed = false
        for action, set in pairs(found) do
            local a, b = {}, {}
            for k in pairs(set) do a[#a + 1] = k end
            for k in pairs(keys[action]) do b[#b + 1] = k end
            table.sort(a); table.sort(b)
            if table.concat(a, ",") ~= table.concat(b, ",") then changed = true end
        end
        keys = found
        if changed or not keys_found then
            for action, set in pairs(keys) do
                local list = {}
                for k in pairs(set) do list[#list + 1] = k end
                log(action .. " keys: " .. (#list > 0 and table.concat(list, ", ") or "none"))
            end
        end
        keys_found = true
    end
end

local function local_pc(char)
    local pc = try(function() return char.Controller end)
    if valid(pc) and try(function() return pc:IsLocalPlayerController() end) == true then return pc end
    return nil
end

local function key_down(pc, action)
    for k in pairs(keys[action]) do
        local down = try(function() return pc:IsInputKeyDown({ KeyName = FName(k) }) end)
        if down then return true end
    end
    return false
end

------------------------------------------------------------------ crouch
local MOVEMENT_ACTION_BLOCK = 4  -- EALSMovementAction::GettingUp; any non-zero works
local blocked = nil              -- { char, saved MovementAction } during a release call

local function stance_pre(char)
    if CFG.toggleCrouch ~= 1 or not valid(char) then return end
    local pc = local_pc(char)
    if not pc or next(keys.IA_Stance) == nil then return end  -- unknown keys: stay vanilla
    local down = key_down(pc, "IA_Stance")
    dbg_hook(string.format("StanceAction key=%s", tostring(down)))
    if down then return end
    local saved = try(function() return char.MovementAction end)
    if saved ~= 0 then return end  -- already busy (roll, mantle): the game ignores it anyway
    if try(function() char.MovementAction = MOVEMENT_ACTION_BLOCK; return true end) then
        blocked = { char = char, saved = saved }
    end
end

local function stance_post()
    if not blocked then return end
    local b = blocked
    blocked = nil
    try(function() b.char.MovementAction = b.saved end)
end

------------------------------------------------------------------ sprint
local sprint = { on = false, stopped_ms = 0 }
local wants_sprint, is_sprinting  -- defined with the poll below

local function on_sprint_pre(char, value)
    if CFG.toggleSprint ~= 1 then return end
    local raw = try(function() return value:get() end)
    if raw == nil then return end
    if not local_pc(char) then return end
    if sprint.self_call then return end      -- our own enforcement call: pass through
    if raw then
        -- A tap flips the toggle. The game sometimes ignores one start/stop
        -- request (user had to double-tap or hold, 2026-10-17), so for 0.6 s
        -- the poll keeps re-sending the chosen state until the character
        -- matches it.
        -- Flip from what the character really does: when the game had
        -- already ended the sprint (weapon swap, stamina) a tap used to
        -- "turn off" a sprint that was not running (2026-10-18).
        -- The real gait, not DesiredGait: the game kept asking for a sprint it
        -- was not running (tired, aiming), so a tap "turned off" a sprint you
        -- could not see and the next tap was needed (log 2026-10-18 18:58).
        sprint.on = not (sprint.on and is_sprinting(char))
        sprint.force_until = os.clock() + 0.6
        sprint.lost_ms = 0
    end
    sprint.stopped_ms = 0
    try(function() value:set(sprint.on) end)
    dbg_hook(string.format("SprintAction raw=%s -> %s (gait %s, desired %s)", tostring(raw), tostring(sprint.on),
        tostring(get(char, "Gait")), tostring(get(char, "DesiredGait"))))
end

------------------------------------------------------------------ hooks
local function hook(path, pre, post)
    local ok = try(function()
        RegisterHook(path, pre or function() end, post)
        return true
    end)
    log((ok and "hooked " or "FAILED to hook ") .. path)
    return ok
end

hook("/Script/ALSV4_CPP.ALSBaseCharacter:SprintAction", function(self, bValue)
    on_sprint_pre(self:get(), bValue)
end)
hook("/Script/ALSV4_CPP.ALSBaseCharacter:StanceAction", function(self)
    stance_pre(self:get())
end, function()
    stance_post()
end)

------------------------------------------------------------------ poll
-- 50 ms: stops toggled sprint once WASD is released, and is the safety
-- net that restores MovementAction if a post-hook ever failed to run.
local POLL_MS = 100  -- 50 ms cost twice as much and felt the same (2026-10-17)
local ticks = 0

local helpers_mod = nil
local function player_char()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local helpers = helpers_mod
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    if not valid(pc) then return nil, nil end
    local char = try(function() return pc.Pawn end)
    if not valid(char) then return nil, nil end
    return char, pc
end

-- Movement keys first: bHasMovementInput and then the input acceleration
-- both read "not moving" while the player walked, so toggled sprint switched
-- itself off right after each tap (log 2026-10-18). Digital move keys are
-- checked with IsInputKeyDown; stick axes (Gamepad_LeftX/Y) as analog values.
local FALLBACK_MOVE = { "W", "A", "S", "D" }
local move_structs, move_src = {}, nil
local function move_keys()
    local src = next(keys.IA_Move) and keys.IA_Move or nil
    if src ~= move_src or #move_structs == 0 then
        move_src, move_structs = src, {}
        local list = {}
        if src then for k in pairs(src) do list[#list + 1] = k end else list = FALLBACK_MOVE end
        -- The move actions also map Shift, Ctrl and the gamepad triggers
        -- (log 2026-10-18); holding those is not walking.
        local skip = {}
        for k in pairs(keys.IA_Sprint) do skip[k] = true end
        for k in pairs(keys.IA_Stance) do skip[k] = true end
        local kept = {}
        for _, k in ipairs(list) do
            if not (skip[k] or k:find("^Gamepad_Left") or k:find("Trigger") or k:find("Shift") or k:find("Control")
                    or k:find("Alt") or k:find("Thumbstick") or k:find("Mouse")) then
                kept[#kept + 1] = k
            end
        end
        if #kept == 0 then kept = FALLBACK_MOVE end
        if CFG.debugLog == 1 then log("movement keys used for auto stop: " .. table.concat(kept, ", ")) end
        for _, k in ipairs(kept) do
            move_structs[#move_structs + 1] = { analog = false, key = { KeyName = FName(k) } }
        end
        for _, k in ipairs({ "Gamepad_LeftX", "Gamepad_LeftY" }) do
            move_structs[#move_structs + 1] = { analog = true, key = { KeyName = FName(k) } }
        end
    end
    return move_structs
end

local function has_move_input(char, pc)
    if pc then
        for _, m in ipairs(move_keys()) do
            if m.analog then
                local v = tonumber(call(pc, "GetInputAnalogKeyState", m.key))
                if v and math.abs(v) > 0.2 then return true end
            elseif call(pc, "IsInputKeyDown", m.key) == true then
                return true
            end
        end
        return false
    end
    local a = call(get(char, "CharacterMovement"), "GetCurrentAcceleration")
    if a ~= nil and type(a.X) == "number" then
        return math.abs(a.X) > 1 or math.abs(a.Y) > 1
    end
    return get(char, "bHasMovementInput") == true
end

-- ALS gait the character is actually asking for (EALSGait: 0 walk, 1 run,
-- 2 sprint). The toggle flag alone drifted from it when the game ended a
-- sprint by itself (stamina, crouch, interactions), which left sprint stuck
-- on after releasing WASD (user report 2026-10-17).
local GAIT_SPRINT = 2
function wants_sprint(char)
    local g = tonumber(get(char, "DesiredGait"))
    if g == nil then return sprint.on end
    return g == GAIT_SPRINT
end
-- The gait the character is really in (what you see on screen).
function is_sprinting(char)
    local g = tonumber(get(char, "Gait"))
    if g == nil then return wants_sprint(char) end
    return g == GAIT_SPRINT
end

local resync_ms = 0
local function poll()
    ticks = ticks + 1
    if ticks % (keys_found and 2400 or 200) == 1 then refresh_keys() end  -- 10 s until found, then 2 min
    stance_post()
    local char, pc = player_char()
    if not char then return end
    if CFG.toggleSprint ~= 1 then return end

    local sprinting = wants_sprint(char)
    local moving = has_move_input(char, pc)
    -- (Not while a tap is being enforced: tapping sprint just before moving
    -- should not be cancelled as "not moving".)
    if not moving and (sprint.on or sprinting) and (sprint.force_until or 0) <= os.clock() then
        sprint.stopped_ms = sprint.stopped_ms + POLL_MS
        if sprint.stopped_ms >= CFG.sprintStopDelayMs then
            sprint.on = false
            sprint.stopped_ms = 0
            if sprinting and not key_down(pc, "IA_Sprint") then
                try(function() char:SprintAction(false) end)
            end
            dbg("sprint off (movement keys released)")
        end
        return
    end
    sprint.stopped_ms = 0
    -- For 0.6 s after a tap, re-send the chosen state until the character
    -- matches it (the game sometimes ignored a single start/stop request).
    if (sprint.force_until or 0) > os.clock() then
        if sprint.on ~= sprinting and (moving or not sprint.on) then
            sprint.self_call = true
            call(char, "SprintAction", sprint.on)
            sprint.self_call = false
            dbg("sprint " .. (sprint.on and "on" or "off") .. " enforced after tap")
        end
        resync_ms = 0
        return
    end
    -- Toggle is off but the character still sprints (an off-tap the game
    -- ignored past the 0.6 s window; user 2026-10-18 "doesnt even come off"):
    -- keep sending the stop.
    if not sprint.on and sprinting and not key_down(pc, "IA_Sprint") then
        sprint.self_call = true
        call(char, "SprintAction", false)
        sprint.self_call = false
        dbg("sprint off re-sent: character still sprinting")
        resync_ms = 0
        return
    end
    -- The game stopped the sprint on its own (weapon swap, reload, stamina):
    -- keep asking for it while you keep moving, for up to 3 s, so sprint
    -- resumes after a swap (user 2026-10-18). Still refused after that
    -- (stamina out): drop the toggle, so the next tap starts sprinting.
    if sprint.on and not sprinting then
        resync_ms = resync_ms + POLL_MS
        if resync_ms >= 3000 then
            sprint.on = false
            resync_ms = 0
            dbg("sprint toggle dropped: game kept the sprint off for 3 s")
        elseif moving then
            sprint.self_call = true
            call(char, "SprintAction", true)
            sprint.self_call = false
            if resync_ms == POLL_MS then dbg("sprint resumed after the game ended it") end
        end
    else
        resync_ms = 0
    end
end

game_loop(POLL_MS, function()
    local ok, err = pcall(poll)
    if not ok then log("error: " .. tostring(err)) end
end)

log("loaded")
