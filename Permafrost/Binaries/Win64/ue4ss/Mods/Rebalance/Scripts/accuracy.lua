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
-- guns are untouched. The crosshair lines (CrosshairSwitcher in the HUD)
-- move apart with the cone so it opens up and tightens.
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
    { "useAccuracySkill",  1,    "1 = your Accuracy skill shrinks the extra spread by its per-level benefit" },
    { "minSkillMultiplier", 0.3, "a maxed skill never shrinks the extra spread below this share" },
    { "reticle",           1,    "1 = the crosshair grows and shrinks with the spread" },
    { "reticlePixelsPerDeg", 10, "how far the crosshair lines move apart per degree of extra spread (pixels)" },
    { "reticleGap",        6,    "gap between the crosshair lines when steady (pixels)" },
    { "reticleLength",     10,   "length of each crosshair line (pixels)" },
    { "reticleThickness",  2,    "thickness of each crosshair line (pixels)" },
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

------------------------------------------------------------------ skill
-- The game's Accuracy skill (DA_Skill_Accuracy): UniformValuePerLevel is
-- its benefit per level; the player's level is in the pawn's
-- CharacterSkillsComponent.SkillsRuntimeData (user 2026-10-18: the extra
-- spread should follow the skill). Read every 5 s.
local skill_mult, skill_logged = 1, false
local skills_class = nil
local function read_skill(pawn)
    if CFG.useAccuracySkill ~= 1 then skill_mult = 1 return end
    skills_class = skills_class or try(function() return StaticFindObject("/Script/Permafrost.CharacterSkillsComponent") end)
    local comp = valid(skills_class) and call(pawn, "GetComponentByClass", skills_class)
    local data = valid(comp) and get(comp, "SkillsRuntimeData")
    if not data then return end
    local level, per = nil, nil
    try(function()
        data:ForEach(function(_, e)
            local d = e:get()
            local name = try(function() return d.SkillName:ToString() end) or ""
            local skill = try(function() return d.AssociatedSkill end)
            local sname = valid(skill) and fname(skill) or ""
            if name:find("Accuracy") or sname:find("Accuracy") then
                level = tonumber(try(function() return d.Level end))
                if valid(skill) then per = tonumber(get(skill, "UniformValuePerLevel")) end
            end
        end)
    end)
    if not per then
        for _, s in ipairs(try(function() return FindAllOf("Skill_BaseClass") end) or {}) do
            if valid(s) and fname(s) == "DA_Skill_Accuracy" then per = tonumber(get(s, "UniformValuePerLevel")) end
        end
    end
    if not level or not per then return end
    -- Benefit per level in percent (DA_Skill_Accuracy stores 1.0 = 1 % per
    -- level; reading it as a share pinned level 11 at the floor, 2026-10-18).
    local share = per / 100
    skill_mult = math.max(CFG.minSkillMultiplier, 1 - level * share)
    if CFG.debugLog == 1 and not skill_logged then
        skill_logged = true
        log(string.format("Accuracy skill level %d, %.3f per level -> extra spread x%.2f", level, per, skill_mult))
    end
end

local gun_path = nil
local skill_at = 0
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
    if now >= skill_at then skill_at = now + 5 pcall(read_skill, pawn) end
    e = e * skill_mult
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

-- The crosshair opens up with the spread. The game's crosshair is ONE
-- image with the four ticks drawn in (dlls\crosshair.txt, 2026-10-18), and
-- scaling it made the ticks longer and thicker. So for the gun and precise
-- gun crosshairs that image is hidden and four plain lines are added to the
-- same canvas, in its colour; their gap is reticleGap + extra spread x
-- reticlePixelsPerDeg. Hit and target markers are untouched; bow and melee
-- crosshairs stay vanilla.
local OWN_RETICLE = { UW_CrosshairGun = true, UW_CrosshairPreciseGun = true }
local IMAGE_CLASS = nil
local hud_addr, route, settle_until = nil, nil, 0
local reticles = nil       -- { { lines = { route, dx, dy } } }
local shown_gap = -1

-- Children route helpers: index i >= 1 is GetChildAt(i - 1), 0 is a nested
-- widget's root.
local function add_lines(cw, cw_route)
    local tree = get(cw, "WidgetTree")
    local root = valid(tree) and get(tree, "RootWidget")              -- Border_0
    if not valid(root) then return nil end
    -- Border_0 > RetainerBox_1 > CanvasPanel_0
    local retainer = call(root, "GetChildAt", 0)
    local canvas = valid(retainer) and call(retainer, "GetChildAt", 0)
    if not valid(canvas) then return nil end
    local canvas_route = { table.unpack(cw_route) }
    for _, st in ipairs({ 0, 1, 1 }) do canvas_route[#canvas_route + 1] = st end
    -- The game's crosshair image: hide it, copy its colour.
    local orig_i, color = nil, { R = 1, G = 0.72, B = 0.1, A = 1 }
    local n = tonumber(call(canvas, "GetChildrenCount")) or 0
    for i = 0, n - 1 do
        local c = call(canvas, "GetChildAt", i)
        if valid(c) and fname(c) == "Crosshair" then
            orig_i = i
            local col = get(c, "ColorAndOpacity")
            local r, g, bl = col and tonumber(col.R), col and tonumber(col.G), col and tonumber(col.B)
            if r and not (r > 0.95 and g > 0.95 and bl > 0.95) then color = { R = r, G = g, B = bl, A = 1 } end
            call(c, "SetRenderOpacity", 0)
        end
    end
    if not orig_i then return nil end
    IMAGE_CLASS = IMAGE_CLASS or try(function() return StaticFindObject("/Script/UMG.Image") end)
    if not valid(IMAGE_CLASS) then return nil end
    local lines = {}
    for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
        local img = try(function() return StaticConstructObject(IMAGE_CLASS, tree) end)
        local slot = valid(img) and call(canvas, "AddChildToCanvas", img)
        if valid(slot) then
            call(img, "SetColorAndOpacity", color)
            call(slot, "SetAnchors", { Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
            call(slot, "SetAlignment", { X = 0.5, Y = 0.5 })
            local w, h = CFG.reticleThickness, CFG.reticleLength
            if d[2] == 0 then w, h = CFG.reticleLength, CFG.reticleThickness end
            call(slot, "SetSize", { X = w, Y = h })
            local idx = (tonumber(call(canvas, "GetChildrenCount")) or 1) - 1
            local r = { table.unpack(canvas_route) }
            r[#r + 1] = idx + 1
            lines[#lines + 1] = { route = r, dx = d[1], dy = d[2] }
        end
    end
    return lines
end

local function setup(hud)
    local switcher = follow(hud, route)
    if not switcher then return {} end
    local out = {}
    local n = tonumber(call(switcher, "GetChildrenCount")) or 0
    for i = 0, n - 1 do
        local cw = call(switcher, "GetChildAt", i)
        local cls = valid(cw) and (fname(call(cw, "GetClass")) or ""):gsub("_C$", "")
        if cls and OWN_RETICLE[cls] then
            local r = { table.unpack(route) }
            r[#r + 1] = i + 1
            local lines = add_lines(cw, r)
            if lines then out[#out + 1] = { lines = lines } end
        end
    end
    log(string.format("crosshair: own lines on %d gun crosshairs", #out))
    return out
end

local function reticle(now)
    if CFG.reticle ~= 1 then return end
    local hud = find_hud()
    if not hud then hud_addr = nil return end
    local a = LIB.address(hud)
    if a ~= hud_addr then hud_addr, route, reticles, settle_until, shown_gap = a, nil, nil, now + 10, -1 end
    if now < settle_until then return end
    if route == nil then
        route = find_route(hud, 0, {}, "CrosshairSwitcher") or false
        if not route then log("crosshair NOT found (CrosshairSwitcher)") end
    end
    if not route then return end
    if not reticles then
        local sw = follow(hud, route)
        if sw then call(sw, "SetRenderScale", { X = 1, Y = 1 }) end   -- undo the old scaling
        reticles = setup(hud)
    end
    local gap = CFG.reticleGap + extra * CFG.reticlePixelsPerDeg
    if math.abs(gap - shown_gap) < 0.5 then return end
    local off = gap + CFG.reticleLength / 2
    for _, rt in ipairs(reticles) do
        for _, l in ipairs(rt.lines) do
            local img = follow(hud, l.route)
            local slot = img and get(img, "Slot")
            if valid(slot) then call(slot, "SetPosition", { X = l.dx * off, Y = l.dy * off }) end
        end
    end
    shown_gap = gap
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
