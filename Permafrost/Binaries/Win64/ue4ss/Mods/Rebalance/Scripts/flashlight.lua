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
-- Shadow settings, enforced every pass: the light still threw no shadow
-- with CastShadows on (user screenshot 2026-10-18), so the other switches
-- are forced too and every shadow-related value is logged once.
local SHADOW_PROPS = { "CastShadows", "CastDynamicShadows", "CastStaticShadows", "CastRaytracedShadow", "bCastVolumetricShadow",
                       "bAffectDynamicIndirectLighting", "ShadowResolutionScale", "ShadowBias", "ShadowSlopeBias",
                       "ContactShadowLength", "Mobility", "bUseRayTracedDistanceFieldShadows", "MaxDrawDistance",
                       "bCastShadowsFromCinematicObjectsOnly", "bAffectsWorld", "SourceRadius", "SoftSourceRadius" }
local shadow_logged = false
local function enforce_shadows(comp)
    if CFG.castShadows ~= 1 then return end
    if not shadow_logged and CFG.debugLog == 1 then
        shadow_logged = true
        local parts = {}
        for _, k in ipairs(SHADOW_PROPS) do parts[#parts + 1] = k .. "=" .. tostring(get(comp, k)) end
        log("light shadow settings (before): " .. table.concat(parts, ", "))
    end
    local changed = false
    for _, k in ipairs({ "CastDynamicShadows", "CastStaticShadows" }) do  -- plural in UE 5.4
        if get(comp, k) == false then LIB.set(comp, k, true) changed = true end
    end
    if get(comp, "bCastShadowsFromCinematicObjectsOnly") == true then
        LIB.set(comp, "bCastShadowsFromCinematicObjectsOnly", false) changed = true
    end
    local res = tonumber(get(comp, "ShadowResolutionScale"))
    if res and res < 1 then LIB.set(comp, "ShadowResolutionScale", 1.0) changed = true end
    if get(comp, "CastShadows") ~= true or changed then
        -- Toggling through the setter re-creates the light's render state.
        call(comp, "SetCastShadows", false)
        call(comp, "SetCastShadows", true)
        if CFG.debugLog == 1 and found_logged < 10 then
            found_logged = found_logged + 1
            log("shadows switched back on for " .. fname(comp))
        end
    end
end

local function fix_light(comp)
    enforce_shadows(comp)
    local addr = LIB.address(comp)
    if not addr or lights_done[addr] then return end
    lights_done[addr] = true
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
-- The game applies a flashlight mode's Settings (DA_FlashlightMode_Far /
-- _Wide) each time the light turns on, so rescaling only the light showed
-- the vanilla beam for up to 2 s first (user 2026-10-18). The modes' radius
-- is scaled once instead; vanilla -> scaled radius is kept per mode, so a
-- light still at a vanilla radius (lit before the edit) is moved to the
-- scaled one without ever scaling twice.
local mode_radius = {}      -- vanilla radius -> scaled radius
local scaled_values = {}    -- scaled radius -> true
-- Every pass: the mode assets found by class (cheap), any at a radius we
-- did not set is scaled (they may be reloaded from disk at vanilla).
local function scale_modes()
    if CFG.rangeMultiplier == 1.0 then return end
    for _, a in ipairs(try(function() return FindAllOf("Data_FlashlightMode") end) or {}) do
        if valid(a) and not fname(a):find("^Default__") then
            local st = get(a, "Settings")
            local r = st and tonumber(get(st, "AttenuationRadius"))
            local ours = false
            for v in pairs(scaled_values) do if r and math.abs(v - r) < 1 then ours = true end end
            if r and not ours then
                local nr = r * CFG.rangeMultiplier
                LIB.set(st, "AttenuationRadius", nr)
                local now = tonumber(get(st, "AttenuationRadius"))
                if now and math.abs(now - nr) < 1 then
                    mode_radius[r] = nr
                    scaled_values[nr] = true
                    log(string.format("%s range %.0f -> %.0f m", fname(a), r / 100, nr / 100))
                end
            end
        end
    end
end

local function fix_range(comp, addr)
    if CFG.rangeMultiplier == 1.0 then return end
    local rad = tonumber(get(comp, "AttenuationRadius"))
    if next(mode_radius) ~= nil then
        -- Modes are scaled: only move a light still at a vanilla mode radius.
        for v, sc in pairs(mode_radius) do
            if rad and math.abs(rad - v) < 1 then call(comp, "SetAttenuationRadius", sc) end
        end
        return
    end
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
    scale_modes()
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
