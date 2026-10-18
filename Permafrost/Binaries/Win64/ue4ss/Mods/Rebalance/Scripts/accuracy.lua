-- Accuracy module of the Overhaul (2026-10-18). User: aiming and movement
-- should matter, and the reticle should show it. The game's own spread is a
-- fixed number per gun (ItemConfig_RangeWeapon.SpreadModificator); nothing
-- in its code changes it with movement or aiming.
-- This adds a cone of extra spread to the player's own shots:
--  * grows with movement speed (sprinting most), being in the air, and each
--    shot fired in quick succession (recovers over time);
--  * shrinks while aiming down sights and while crouched.
-- Applied to the bullet itself: when the player's gun spawns a projectile,
-- its flight direction is turned by a random angle inside the cone. Enemy
-- guns are untouched. The crosshair (CrosshairSwitcher in the HUD) is scaled
-- with the cone so it opens up and tightens.
-- Settings: Accuracy section of config.lua. Log tag [PF Accuracy].
local TAG = "[PF Accuracy] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, set, call = LIB.get, LIB.set, LIB.call
local ROOT = REBALANCE_ROOT or ""

------------------------------------------------------------------ config
local DEFAULTS = {
    { "moveSpreadDeg",     2.0,  "extra spread at full sprint, degrees (walking: part of it)" },
    { "airSpreadDeg",      3.0,  "extra spread while jumping or falling" },
    { "shotSpreadDeg",     0.6,  "extra spread added by each shot" },
    { "shotRecoveryDegPerSec", 3.0, "how fast the per-shot spread recovers" },
    { "maxSpreadDeg",      5.0,  "largest extra spread" },
    { "aimMultiplier",     0.35, "extra spread while aiming down sights (0.35 = 35%)" },
    { "crouchMultiplier",  0.7,  "extra spread while crouched" },
    { "sprintSpeed",       600,  "speed (cm/s) that counts as a full sprint" },
    { "reticle",           1,    "1 = the crosshair grows and shrinks with the spread" },
    { "reticleScalePerDeg", 0.45, "crosshair growth per degree of extra spread" },
    { "debugLog",          1,    "1 = log the first shots" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Accuracy.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Accuracy.lua", "t", {})
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

------------------------------------------------------------------ player state
local helpers_mod = nil
local function player()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local pc = helpers_mod and try(function() return helpers_mod.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    return valid(pawn) and pawn or nil
end

local equip_name = nil
local function held_gun(pawn)
    local equip = equip_name and get(pawn, equip_name)
    if not valid(equip) then
        for _, n in ipairs({ "Equipment Component", "EquipmentComponent" }) do
            equip = get(pawn, n)
            if valid(equip) then equip_name = n break end
        end
    end
    if not valid(equip) then return nil end
    local gun = try(function() return equip.HeldItem.ItemActor end)
    if valid(gun) and type(get(gun, "CurrentMagazine")) == "number" then return gun end
    return nil
end

-- ALS enums: RotationMode 2 = Aiming, Stance 1 = Crouching, MovementState 2 = InAir.
local ROT_AIMING, STANCE_CROUCH, STATE_AIR = 2, 1, 2

local gun_path = nil
local bloom = 0            -- per-shot spread, degrees
local extra = 0            -- current extra spread, degrees
local last_t = os.clock()

local function update()
    local now = os.clock()
    local dt = math.min(0.5, now - last_t)
    last_t = now
    bloom = math.max(0, bloom - CFG.shotRecoveryDegPerSec * dt)
    local pawn = player()
    if not pawn then gun_path = nil extra = 0 return end
    local gun = held_gun(pawn)
    gun_path = gun and LIB.path_of(gun) or nil
    local v = call(pawn, "GetVelocity")
    local speed = v and math.sqrt(v.X * v.X + v.Y * v.Y) or 0
    local move = math.min(1, speed / math.max(1, CFG.sprintSpeed))
    local e = CFG.moveSpreadDeg * move + bloom
    if tonumber(get(pawn, "MovementState")) == STATE_AIR then e = e + CFG.airSpreadDeg end
    if tonumber(get(pawn, "RotationMode")) == ROT_AIMING then e = e * CFG.aimMultiplier end
    if tonumber(get(pawn, "Stance")) == STANCE_CROUCH then e = e * CFG.crouchMultiplier end
    extra = math.min(CFG.maxSpreadDeg, e)
end

------------------------------------------------------------------ bullets
-- Turns direction d (unit) by a random angle up to `deg` inside a cone.
local function cone(dx, dy, dz, deg)
    local theta = math.rad(deg) * math.sqrt(math.random())   -- even over the disc
    local phi = math.random() * 2 * math.pi
    -- two unit vectors perpendicular to d
    local ux, uy, uz
    if math.abs(dz) < 0.9 then ux, uy, uz = -dy, dx, 0 else ux, uy, uz = 0, -dz, dy end
    local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    local wx, wy, wz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux
    local t = math.tan(theta)
    local ox, oy = math.cos(phi) * t, math.sin(phi) * t
    local nx = dx + ux * ox + wx * oy
    local ny = dy + uy * ox + wy * oy
    local nz = dz + uz * ox + wz * oy
    local l = math.sqrt(nx * nx + ny * ny + nz * nz)
    return nx / l, ny / l, nz / l
end

local shot_logged = 0
local last_shot = -100
REBALANCE_ON_ACTOR("/Script/Permafrost.Projectile", function(proj)
    if not gun_path then return end
    local owner = call(proj, "GetOwner")
    if not valid(owner) or LIB.path_of(owner) ~= gun_path then return end
    local now = os.clock()
    local deg = extra
    -- One bloom step per shot (shotgun pellets within 40 ms are one shot).
    if now - last_shot > 0.04 then bloom = math.min(CFG.maxSpreadDeg, bloom + CFG.shotSpreadDeg) end
    last_shot = now
    if deg < 0.01 then return end
    local pm = get(proj, "ProjectileMovement")
    local v = valid(pm) and get(pm, "Velocity")
    if not v then return end
    local vx, vy, vz = tonumber(v.X) or 0, tonumber(v.Y) or 0, tonumber(v.Z) or 0
    local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    if speed < 1 then return end
    local nx, ny, nz = cone(vx / speed, vy / speed, vz / speed, deg)
    set(pm, "Velocity", { X = nx * speed, Y = ny * speed, Z = nz * speed })
    if CFG.debugLog == 1 and shot_logged < 8 then
        shot_logged = shot_logged + 1
        log(string.format("shot: extra spread %.2f deg (bloom %.2f)", deg, bloom))
    end
end)

------------------------------------------------------------------ reticle
-- CrosshairSwitcher inside UW_HUD, found by name through children only and
-- remembered as a route of child indexes (no widget kept across frames).
local function child(w, step)
    if step == 0 then
        local tree = get(w, "WidgetTree")
        local root = valid(tree) and get(tree, "RootWidget")
        return valid(root) and root or nil
    end
    local c = call(w, "GetChildAt", step - 1)
    return valid(c) and c or nil
end
local function find_route(w, depth, route, name)
    if depth > 8 then return nil end
    if fname(w) == name then return route end
    local n = tonumber(call(w, "GetChildrenCount")) or 0
    for i = 0, n do
        local c = (i == 0) and child(w, 0) or child(w, i)
        if c then
            local r = { table.unpack(route) }
            r[#r + 1] = i
            local found = find_route(c, depth + 1, r, name)
            if found then return found end
        end
    end
    return nil
end
local function follow(w, route)
    for _, step in ipairs(route) do
        if not w then return nil end
        w = child(w, step)
    end
    return w
end
local function find_hud()
    for _, h in ipairs(try(function() return FindAllOf("UW_HUD_C") end) or {}) do
        if valid(h) and not fname(h):find("^Default__") and call(h, "IsInViewport") == true then return h end
    end
    return nil
end

local hud_addr, route, settle_until, shown_scale = nil, nil, 0, 1
local function reticle(now)
    if CFG.reticle ~= 1 then return end
    local hud = find_hud()
    if not hud then hud_addr = nil return end
    local a = LIB.address(hud)
    if a ~= hud_addr then hud_addr, route, settle_until = a, nil, now + 10 end
    if now < settle_until then return end
    if not route then
        route = find_route(hud, 0, {}, "CrosshairSwitcher") or false
        log(route and "crosshair found" or "crosshair NOT found (CrosshairSwitcher)")
    end
    if not route then return end
    local s = 1 + extra * CFG.reticleScalePerDeg
    if math.abs(s - shown_scale) < 0.02 then return end
    local w = follow(hud, route)
    if w then
        call(w, "SetRenderScale", { X = s, Y = s })
        shown_scale = s
    end
end

game_loop(50, function()
    local ok, err = pcall(function()
        update()
        reticle(os.clock())
    end)
    if not ok and shot_logged < 8 then shot_logged = shot_logged + 1 log("error: " .. tostring(err)) end
end)

log(string.format("loaded: sprint +%.1f deg, air +%.1f, per shot +%.1f, aim x%.2f, crouch x%.2f",
    CFG.moveSpreadDeg, CFG.airSpreadDeg, CFG.shotSpreadDeg, CFG.aimMultiplier, CFG.crouchMultiplier))
