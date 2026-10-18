-- Flashlight module of the Overhaul (2026-10-18). User: the flashlight only
-- lights the ground right in front of you and casts no shadow.
--  * Shadows: every spotlight on the player (the flashlight is a Blueprint
--    component; native APermaCharacter only holds the Far/Wide mode assets)
--    gets SetCastShadows(true).
--  * Aim: the light's relative pitch is raised by pitchUpDegrees, once per
--    component, so the beam lands farther ahead.
--  * Range: the light's AttenuationRadius x rangeMultiplier. Switching
--    between the Far and Wide modes (DA_FlashlightMode_*) writes the mode's
--    own radius back, so a radius we did not set is scaled again (2 s poll).
-- Settings: Flashlight section of config.lua. Log tag [PF Flashlight].
local TAG = "[PF Flashlight] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

------------------------------------------------------------------ config
local DEFAULTS = {
    { "enabled",         1,   "1 = on" },
    { "castShadows",     1,   "1 = the flashlight casts shadows" },
    { "pitchUpDegrees",  6,   "aim the beam this many degrees higher" },
    { "rangeMultiplier", 3.0, "how far the light reaches" },
    { "offsetDownCm",    25,  "move the light below your eyes; a light at the eye hides its own shadows" },
    { "offsetRightCm",   20,  "move the light to the right (held in the right hand / chest strap)" },
    { "debugLog",        1,   "1 = log what was found" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Flashlight.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Flashlight.lua", "t", {})
    local user = chunk and try(chunk)
    if type(user) == "table" then
        for _, d in ipairs(DEFAULTS) do
            local v = tonumber(user[d[1]])
            if v then cfg[d[1]] = v end
        end
    end
    return cfg
end
local CFG = load_config()
if CFG.enabled ~= 1 then
    log("off")
    return
end

------------------------------------------------------------------ player spotlights
local helpers_mod = nil
local function player_pawn()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local pc = helpers_mod and try(function() return helpers_mod.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    return valid(pawn) and pawn or nil
end

local lights_done = {}        -- component address -> true
local found_logged = 0
local function fix_light(comp)
    local addr = LIB.address(comp)
    if not addr or lights_done[addr] then return end
    lights_done[addr] = true
    if CFG.castShadows == 1 then call(comp, "SetCastShadows", true) end
    local rot = get(comp, "RelativeRotation")
    local p, y, r = rot and tonumber(rot.Pitch), rot and tonumber(rot.Yaw), rot and tonumber(rot.Roll)
    if p and CFG.pitchUpDegrees ~= 0 then
        call(comp, "K2_SetRelativeRotation", { Pitch = p + CFG.pitchUpDegrees, Yaw = y, Roll = r }, false, {}, false)
    end
    -- Shadows were on but unseen (user 2026-10-18): a light at the camera
    -- throws every shadow straight behind what it lights. Offset it like a
    -- handheld or chest light (relative X forward, Y right, Z up).
    local loc = get(comp, "RelativeLocation")
    local lx, ly, lz = loc and tonumber(loc.X), loc and tonumber(loc.Y), loc and tonumber(loc.Z)
    if lx and (CFG.offsetDownCm ~= 0 or CFG.offsetRightCm ~= 0) then
        call(comp, "K2_SetRelativeLocation", { X = lx, Y = ly + CFG.offsetRightCm, Z = lz - CFG.offsetDownCm }, false, {}, false)
    end
    if CFG.debugLog == 1 and found_logged < 10 then
        found_logged = found_logged + 1
        local now = get(comp, "RelativeRotation")
        log(string.format("player light %s (owner %s): shadows %s, pitch %.1f -> %.1f, range %.0f m",
            fname(comp), fname(call(comp, "GetOwner")), tostring(get(comp, "CastShadows")),
            p or 0, now and tonumber(now.Pitch) or 0, (tonumber(get(comp, "AttenuationRadius")) or 0) / 100))
    end
end

local function belongs_to(comp, pawn_addr)
    local owner = call(comp, "GetOwner")
    if not valid(owner) then return false end
    if LIB.address(owner) == pawn_addr then return true end
    local parent = call(owner, "GetAttachParentActor")
    return valid(parent) and LIB.address(parent) == pawn_addr
end

-- Radius we last set per component; anything else came from the game.
local range_set = {}
local range_logged = 0
local function fix_range(comp, addr)
    if CFG.rangeMultiplier == 1.0 then return end
    local rad = tonumber(get(comp, "AttenuationRadius"))
    if not rad or (range_set[addr] and math.abs(rad - range_set[addr]) < 1) then return end
    local nr = rad * CFG.rangeMultiplier
    call(comp, "SetAttenuationRadius", nr)
    range_set[addr] = tonumber(get(comp, "AttenuationRadius")) or nr
    if CFG.debugLog == 1 and range_logged < 10 then
        range_logged = range_logged + 1
        log(string.format("%s range %.0f -> %.0f m", fname(comp), rad / 100, range_set[addr] / 100))
    end
end

local function pass()
    local pawn = player_pawn()
    local pawn_addr = pawn and LIB.address(pawn)
    if not pawn_addr then return end
    for _, comp in ipairs(try(function() return FindAllOf("SpotLightComponent") end) or {}) do
        if valid(comp) and not fname(comp):find("^Default__") then
            local addr = LIB.address(comp)
            if addr and belongs_to(comp, pawn_addr) then
                fix_light(comp)
                fix_range(comp, addr)
            end
        end
    end
end

game_loop(2000, function()
    local ok, err = pcall(pass)
    if not ok and found_logged < 10 then found_logged = found_logged + 1 log("error: " .. tostring(err)) end
end)

log(string.format("loaded: shadows %s, aim +%.0f deg, range x%.1f", CFG.castShadows == 1 and "on" or "off",
    CFG.pitchUpDegrees, CFG.rangeMultiplier))
