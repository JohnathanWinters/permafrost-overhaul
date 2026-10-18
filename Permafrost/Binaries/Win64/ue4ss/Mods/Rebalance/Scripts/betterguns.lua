-- BetterGuns module of the Rebalance mod (was its own mod until 2026-10-17).
-- Settings: Rebalance\config\BetterGuns.lua
-- BetterGuns: louder shots, more reverb, more recoil.
-- Audio: FMOD bus volumes (Weapon_Shot, Weapon_Shot_Suppressed, Gun_Reverb return).
-- Recoil: RecoilValues on each firearm's ItemConfig_RangeWeapon data asset
-- (the held gun copies it into RecoilXY/RecoilZ per shot), plus the
-- amplitude of the three shot camera shakes (VisualRecoilEffect).
local TAG = "[PF BetterGuns] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

-- Game-thread scheduling. LoopAsync + ExecuteInGameThread queues a new
-- callback from a worker thread on every tick; with several mods doing it,
-- UE4SS raced ("Ref was not function") and crashed the game on 2026-10-16.
-- This UE4SS build can loop directly on the game thread; the old pattern is
-- only a fallback.
local LIB = REBALANCE_LIB  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, game_loop, game_later = LIB.try, LIB.valid, LIB.fname, LIB.game_loop, LIB.game_later

------------------------------------------------------------------ config
local DEFAULTS = {
    { "shotVolume",           10.0, "gunshot loudness (1.0 = vanilla, 2.0 = +6 dB)" },
    { "duckAmount",           0.55, "other sounds drop to this share of their volume right after your shot (1 = no ducking)" },
    { "duckRecoverMs",        900,  "how long other sounds take to come back after a shot" },
    { "suppressedShotVolume", 2.0,  "suppressed gunshot loudness" },
    { "gunReverbVolume",      6.0,  "Gun_Reverb bus (reverb return for gunshots)" },
    { "worldReverbVolume",    2.0,  "Reverb, ForestReverb, Cave_Reverb, Bunker_Reverb buses (all sounds)" },
    { "headshotMultiplier",   2.0, "head damage multiplier for melee weapons (vanilla 1.0)" },
    { "headshotPistol",       8.0, "head damage multiplier for pistols and SMGs (vanilla 1.0)" },
    { "headshotRifle",        8.0, "head damage multiplier for rifles, shotguns and other guns (vanilla 1.0)" },
    { "headshotBow",          8.0, "head damage multiplier for bows (vanilla 1.0)" },
    { "recoilMultiplier",     2.0, "weapon kick (aim climb)" },
    { "cameraKickMultiplier", 2.5, "camera shake per shot" },
    { "echoVolume",           4.0,  "outdoor echo: tail plus echoRepeats delayed, lower repeats per shot (0 = off)" },
    { "echoRepeats",          0,    "outdoor echo: how many canyon repeats follow the tail (0 to 10)" },
    { "hallReverb",           1,    "1 = real reverb on your gunshots (FMOD SFX Reverb on the Weapon_Shot bus)" },
    { "hallDecayMs",          3900, "how long the hall rings out (concert hall 3900, hangar 10000)" },
    { "hallWetDb",            -9,   "reverb loudness outdoors, dB (-80 = none, 0 = as loud as the shot)" },
    { "hallWetIndoorDb",      -4,   "reverb loudness indoors, dB" },
    { "hallHighCutHz",        5650, "reverb brightness: highs above this fade (lower = darker hall)" },
    { "echoSpacingMs",        400,  "outdoor echo: delay of the first repeat; later ones spread out" },
    { "echoDecay",            0.72, "outdoor echo: each repeat's volume vs the one before" },
    { "echoPitchDrop",        0.03, "outdoor echo: each repeat this much lower (far walls sound duller)" },
    { "indoorEchoVolume",     20.0, "indoor echo: tail plus 3 quick room reflections per shot" },
    { "indoorReverbVolume",   7.0,  "world reverb buses while indoors (replaces worldReverbVolume)" },
    { "echoMinGapMs",         300,  "full auto: at most one echo per this many ms" },
    { "bassLayerVolume",      1.0,  "extra low copy of the shot under each of your shots (0 = off)" },
    { "bassLayerPitch",       0.55, "pitch of that copy (lower = deeper boom)" },
    { "shotPitch",            0.92, "pitch of the game's own shot sound (below 1 = less metallic)" },
    { "echoPitch",            0.92, "extra pitch factor on echo tails (below 1 = deeper)" },
}
local MIN_MULT, MAX_MULT = 0.0, 20.0

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
    if type(root) == "string" then return root .. "\\ue4ss\\Mods\\BetterGuns\\" end
    return nil
end

local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local root = mod_root()
    if not root then return cfg end
    local path = root .. "config\\BetterGuns.lua"
    local f = io.open(path, "r")
    if not f then
        f = io.open(path, "w")
        if f then
            f:write("-- BetterGuns settings. 1.0 = vanilla. Range 0.0 to 20.0. Restart the game to apply.\n")
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
        -- Volumes and multipliers are capped; millisecond values are not
        -- (echoMinGapMs 200 was silently cut to 20 until 2026-10-18).
        if v and (d[1]:find("Ms$") or d[1]:find("Hz$")) then cfg[d[1]] = math.max(0, v)
        elseif v and d[1]:find("Db$") then cfg[d[1]] = math.max(-80, math.min(20, v))
        elseif v then cfg[d[1]] = math.max(MIN_MULT, math.min(MAX_MULT, v)) end
    end
    return cfg
end

local CFG = load_config()
for _, d in ipairs(DEFAULTS) do log(d[1] .. " = " .. tostring(CFG[d[1]])) end

-- LoadAsset in UE4SS 3.0.x wants the full object path; the package path
-- is tried too. Retried a few times since assets may not be mountable yet.
local load_tries = {}
local function find_or_load(object_path, package_path)
    -- LIB.resolve uses FindAllOf for registered paths (buses), falling back to
    -- StaticFindObject only for unregistered ones (startup-only lookups).
    local obj = LIB.resolve(object_path)
    if valid(obj) then return obj end
    local n = load_tries[object_path] or 0
    if n < 5 then
        load_tries[object_path] = n + 1
        for _, p in ipairs({ object_path, package_path }) do
            if p then
                local loaded = try(function() return LoadAsset(p) end)
                if valid(loaded) then return loaded end
            end
        end
        obj = LIB.resolve(object_path)
        if valid(obj) then return obj end
    end
    return nil
end

------------------------------------------------------------------ audio
local BUSES = {
    { "/Game/FMOD/Buses/Master/SFX/Player/Weapon_Shot", "shotVolume" },
    { "/Game/FMOD/Buses/Master/SFX/Player/Weapon_Shot_Suppressed", "suppressedShotVolume" },
    { "/Game/FMOD/Buses/Gun_Reverb", "gunReverbVolume" },
    { "/Game/FMOD/Buses/Reverb", "worldReverbVolume" },
    { "/Game/FMOD/Buses/ForestReverb", "worldReverbVolume" },
    { "/Game/FMOD/Buses/Cave_Reverb", "worldReverbVolume" },
    { "/Game/FMOD/Buses/Bunker_Reverb", "worldReverbVolume" },
}
local bus_logged = {}
local indoor = false  -- set by the echo loop (ceiling + walls traced around the player)

local function bus_target(key)
    if key == "worldReverbVolume" and indoor then return CFG.indoorReverbVolume end
    return CFG[key]
end

-- FMOD keeps a bus volume once set, even after the game unloads the bus
-- asset (nothing holds it, so it is unloaded about once a minute). So a bus
-- is only (re)loaded when its target volume changes (indoor/outdoor);
-- reloading all 7 every pass was a blocking load hitch each minute
-- (2026-10-17).
local bus_applied = {}   -- package path -> volume last set
local function apply_audio()
    local statics = try(function()
        return StaticFindObject("/Script/FMODStudio.Default__FMODBlueprintStatics")
    end)
    if not valid(statics) then return end
    for _, b in ipairs(BUSES) do
        local pkg, key = b[1], b[2]
        if bus_applied[pkg] == bus_target(key) then goto continue end
        local short = pkg:match("([^/]+)$")
        local object_path = pkg .. "." .. short
        LIB.register(object_path, "FMODBus")
        local bus = find_or_load(object_path, pkg)
        if valid(bus) then
            local vol = bus_target(key)
            local ok = try(function() statics:BusSetVolume(bus, vol); return true end)
            if ok then bus_applied[pkg] = vol end
            if not bus_logged[pkg] then
                bus_logged[pkg] = true
                log(string.format("bus %s volume %.2f %s", short, vol, ok and "OK" or "FAILED"))
            end
        elseif not bus_logged[pkg .. "?"] and (load_tries[object_path] or 0) >= 5 then
            bus_logged[pkg .. "?"] = true
            log("bus NOT FOUND after 5 load attempts: " .. short)
        end
        ::continue::
    end
end

------------------------------------------------------------------ reflection walker
local NUMERIC = { FloatProperty = true, DoubleProperty = true }

-- Calls fn(prop, name, type) for every property of a UStruct/UClass,
-- including inherited ones.
local function each_property(ustruct, fn)
    local s, guard = ustruct, 0
    while valid(s) and guard < 32 do
        try(function()
            s:ForEachProperty(function(prop)
                fn(prop, fname(prop), try(function() return prop:GetClass():GetFName():ToString() end) or "?")
            end)
        end)
        s = try(function() return s:GetSuperStruct() end)
        guard = guard + 1
    end
end

-- Scales numeric fields inside `container` (UObject or struct value) whose
-- names pass `accept`. Recurses into nested structs. Returns count changed.
local function scale_fields(container, ustruct, accept, mult, depth)
    if mult == 1.0 or depth > 4 then return 0 end
    local n = 0
    each_property(ustruct, function(prop, name, ptype)
        if NUMERIC[ptype] then
            if accept(name) then
                local v = try(function() return container[name] end)
                if type(v) == "number" and v ~= 0 then
                    if try(function() container[name] = v * mult; return true end) then n = n + 1 end
                end
            end
        elseif ptype == "StructProperty" then
            local inner = try(function() return prop:GetStruct() end)
            local value = try(function() return container[name] end)
            if inner and value then n = n + scale_fields(value, inner, accept, mult, depth + 1) end
        end
    end)
    return n
end

------------------------------------------------------------------ recoil
local DA_NAMES = {
    "AR-53", "AUG", "Anetti_19", "BA-37", "BR-14", "Buria", "CKR-94", "DZ-1K", "FlareGun",
    "GB-11", "GRN-DZ", "IZG", "JPistol_MK2", "Kobra-2115", "Mrozny91", "PDW-9",
    "PU-12_Stratos", "Patriot_A7", "SAS-70_Zozulia", "SG9", "SMJ-45", "SUR_V4",
    "SW-54_Volkodav", "TR-22_Rudi", "Viater",
}
local function any_field() return true end

-- Reads every numeric field of RecoilValues as "name=value" (for the log
-- and as a fingerprint: an asset reloaded from disk reads vanilla again).
local function recoil_snapshot(da)
    local prop
    each_property(da:GetClass(), function(p, name)
        if name == "RecoilValues" then prop = p end
    end)
    local inner = prop and try(function() return prop:GetStruct() end)
    local value = try(function() return da.RecoilValues end)
    if not inner or not value then return nil, nil, nil end
    local parts = {}
    each_property(inner, function(_, name, ptype)
        if NUMERIC[ptype] then
            local v = try(function() return value[name] end)
            parts[#parts + 1] = string.format("%s=%.3f", name, tonumber(v) or 0)
        end
    end)
    return table.concat(parts, " "), value, inner
end

local scaled = {}  -- short name -> snapshot string after scaling
local recoil_logged = 0
-- Only weapon assets that are newly loaded (new address) are read: the
-- reflection snapshot of all 25 every 2 s cost ~40 ms each time, a visible
-- hitch (2026-10-17 profile). A reloaded asset has a new address and reads
-- vanilla again, so it is scaled again.
local recoil_addr = {}     -- DA short name -> address it was scaled at
local DA_SET = {}
for _, short in ipairs(DA_NAMES) do DA_SET["DA_Weapon_Firearms_" .. short] = short end
local function apply_recoil()
    if CFG.recoilMultiplier == 1.0 then return end
    for _, da in ipairs(try(function() return FindAllOf("ItemConfig_Weapon") end) or {}) do
        local short = DA_SET[fname(da)]
        local addr = short and try(function() return da:GetAddress() end)
        if addr and recoil_addr[short] ~= addr then
            recoil_addr[short] = addr
            local before, value, inner = recoil_snapshot(da)
            if before and before ~= scaled[short] then
                local n = scale_fields(value, inner, any_field, CFG.recoilMultiplier, 0)
                local after = recoil_snapshot(da)
                scaled[short] = after
                if recoil_logged < 6 then
                    recoil_logged = recoil_logged + 1
                    log(string.format("recoil %s: %d fields  %s  ->  %s", short, n, before, after or "?"))
                end
            end
        end
    end
end

------------------------------------------------------------------ headshots
-- Bullets, arrows and melee hits reach enemies through
-- UGameplayStatics::ApplyPointDamage (the NPC Blueprint listens with
-- ListenForDamage and subtracts from its `health`). Scaling the weapon items'
-- DamageModificators did nothing (2026-10-17), so the head bonus is applied
-- here: when the player's weapon hits a bone whose name contains "head", the
-- damage is multiplied by the setting for that weapon kind. Enemies hitting
-- the player are untouched (the causer must be held by the player).
local PISTOLS = { "IZG", "SG9", "Anetti", "DZ-1K", "DZ1K", "JPistol", "Patriot", "PDW", "SMJ", "FlareGun" }
local kind_cache = {}      -- causer class name -> kind
local function causer_kind(causer)
    local cls = try(function() return causer:GetClass() end)
    local cname = valid(cls) and fname(cls) or "?"
    if kind_cache[cname] then return kind_cache[cname] end
    local kind = nil
    local c, guard = cls, 0
    while valid(c) and guard < 12 do
        local n = fname(c)
        if n == "BP_MasterMeleeWeapon_C" then kind = "melee" break end
        if n == "BP_MasterFirearm_C" or n == "BP_MasterRange_C" then kind = "gun" break end
        if n == "BP_MasterEnemyWeapon_C" then kind = "enemy" break end
        c = try(function() return c:GetSuperStruct() end)
        guard = guard + 1
    end
    if kind == "gun" then
        kind = "rifle"
        if cname:find("Bow") then kind = "bow" end
        for _, p in ipairs(PISTOLS) do if cname:find(p, 1, true) then kind = "pistol" end end
    end
    kind = kind or "other"
    kind_cache[cname] = kind
    return kind
end
local function kind_mult(kind)
    if kind == "pistol" then return CFG.headshotPistol end
    if kind == "rifle" then return CFG.headshotRifle end
    if kind == "bow" then return CFG.headshotBow end
    if kind == "melee" then return CFG.headshotMultiplier end
    return 1.0
end

------------------------------------------------------------------ camera shake
local SHAKES = {
    "/Game/Permafrost/Blueprints/Utils/BP_RifleStrongShootShake",
    "/Game/Permafrost/Blueprints/Utils/BP_PistolShootShake",
    "/Game/Permafrost/Blueprints/Utils/BP_AutorifleShootShake",
}
local shakes_done = {}
local function is_amplitude(name)
    local n = name:lower()
    return n:find("amplitude", 1, true) ~= nil and n:find("multiplier", 1, true) == nil
end

local function apply_shakes()
    if CFG.cameraKickMultiplier == 1.0 then return end
    for _, pkg in ipairs(SHAKES) do
        if not shakes_done[pkg] then
            local short = pkg:match("([^/]+)$")
            local cdo = find_or_load(pkg .. ".Default__" .. short .. "_C", pkg)
            if valid(cdo) then
                shakes_done[pkg] = true
                local n = scale_fields(cdo, cdo:GetClass(), is_amplitude, CFG.cameraKickMultiplier, 0)
                local pattern = try(function() return cdo.RootShakePattern end)
                if valid(pattern) then
                    n = n + scale_fields(pattern, pattern:GetClass(), is_amplitude, CFG.cameraKickMultiplier, 0)
                end
                log(string.format("shake %s: %d amplitude fields scaled", short, n))
                if n == 0 then
                end
            end
        end
    end
end

------------------------------------------------------------------ loop
------------------------------------------------------------------ echo tails
-- Bus volume above 1.0 is capped by the game's mix (no audible change), so
-- the echo is added as sound instead: the game ships separate tail events
-- per weapon class. A shot is detected when the player's gun loses a round
-- (CurrentMagazine drops); the matching tail plays at the gun.
local TAIL_DIR = "/Game/FMOD/Events/Weapon/"
local TAILS = {  -- checked in order against the gun's GunfireSound event name
    { "suppressed", nil },
    { "flaregun", nil },
    { "shotgun", "sfx_weapon_shotgun_tail" },
    { "smg", "sfx_weapon_smg_tail" },
    { "pistol", "sfx_weapon_pistol_tail" },
    { "assault_rifle", "sfx_weapon_assault_rifle_tail" },
    { "rifle", "sfx_weapon_rifle_tail" },
}
local function tail_for(gun)
    local shot = fname(try(function() return gun.GunfireSound end)):lower()
    for _, t in ipairs(TAILS) do
        if shot:find(t[1], 1, true) then
            if not t[2] then return nil end
            -- Looked up per shot, never cached: a cached asset can be freed.
            -- No retry cap: the game unloads idle events, and a capped
            -- loader silently ended the echoes after a few minutes.
            local op = TAIL_DIR .. t[2] .. "." .. t[2]
            LIB.register(op, "FMODEvent")       -- found via FindAllOf, not StaticFindObject
            local ev = LIB.resolve(op)
            if not valid(ev) then ev = try(function() return LoadAsset(op) end) end
            return valid(ev) and ev or nil
        end
    end
    return nil
end

local last_echo = 0
local echo_logged = 0

local helpers_mod = nil
local function player_pawn()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local helpers = helpers_mod
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and try(function() return pc.Pawn end)
    return valid(pawn) and pawn or nil
end

-- The gun in your hands, read fresh every time (nothing is kept between
-- frames, so a dropped or destroyed gun can never be touched afterwards).
local equip_name = nil
local function held_gun(pawn)
    if not pawn then return nil end
    local equip
    if equip_name then
        equip = try(function() return pawn[equip_name] end)
    else
        for _, n in ipairs({ "Equipment Component", "EquipmentComponent" }) do
            equip = try(function() return pawn[n] end)
            if valid(equip) then equip_name = n break end
        end
    end
    if not valid(equip) then return nil end
    local gun = try(function() return equip.HeldItem.ItemActor end)
    if valid(gun) and type(try(function() return gun.CurrentMagazine end)) == "number" then return gun end
    return nil
end

-- Indoors = something solid within 8 m above the head AND within 20 m in at
-- least 6 of 8 horizontal directions (Visibility channel). Checked every 0.5 s.
local DIRS = {}
for i = 0, 7 do
    local a = i * math.pi / 4
    DIRS[#DIRS + 1] = { math.cos(a), math.sin(a) }
end
local NO_COLOR = { R = 0, G = 0, B = 0, A = 0 }
local function trace(ksl, pawn, sx, sy, sz, ex, ey, ez)
    return try(function()
        return ksl:LineTraceSingle(pawn, { X = sx, Y = sy, Z = sz }, { X = ex, Y = ey, Z = ez },
            0, false, {}, 0, {}, true, NO_COLOR, NO_COLOR, 0.0)
    end) == true
end

local function check_indoor()
    local pawn = player_pawn()
    local loc = pawn and try(function() return pawn:K2_GetActorLocation() end)
    local helpers = try(function() return require("UEHelpers") end)
    local ksl = helpers and try(function() return helpers.GetKismetSystemLibrary() end)
    if not loc or not valid(ksl) then return end
    local x, y, z = loc.X, loc.Y, loc.Z + 60
    local roof = trace(ksl, pawn, x, y, z, x, y, z + 800)
    local walls = 0
    if roof then
        for _, d in ipairs(DIRS) do
            if trace(ksl, pawn, x, y, z, x + d[1] * 2000, y + d[2] * 2000, z) then walls = walls + 1 end
        end
    end
    local now_indoor = roof and walls >= 6
    if now_indoor ~= indoor then
        indoor = now_indoor
        log(indoor and "indoors: strong room echo" or "outdoors: distant echo")
        apply_audio()  -- swap world reverb bus level right away
    end
end

-- Echo layers: { delay ms, volume factor, pitch }. Outdoor repeats are later,
-- quieter and lower (distant reflections); indoor ones are quick and bright.
-- Outdoor = canyon (user 2026-10-18: "sound more like shot in a canyon"):
-- the tail, then echoRepeats slap-backs off walls farther and farther away.
-- Delays grow faster than linear (spacing x i^1.25, +-8% jitter so they
-- roll rather than tick); 400 ms spacing, 6 repeats ends near 3.8 s.
local function canyon_layers()
    local layers = { { 0, 1.0, 1.0 } }
    local n = math.max(0, math.min(10, math.floor(CFG.echoRepeats or 0)))
    for i = 1, n do
        local d = CFG.echoSpacingMs * i ^ 1.25 * (0.92 + math.random() * 0.16)
        layers[#layers + 1] = { math.floor(d), CFG.echoDecay ^ i, math.max(0.6, 1 - CFG.echoPitchDrop * i) }
    end
    return layers
end
local INDOOR_LAYERS = { { 0, 1.0, 1.0 }, { 70, 0.7, 1.0 }, { 150, 0.5, 0.98 }, { 260, 0.35, 0.96 } }

local function play_layer(gun, ev, xf, volume, pitch)
    local statics = try(function() return StaticFindObject("/Script/FMODStudio.Default__FMODBlueprintStatics") end)
    if not valid(statics) then return false end
    local inst = try(function() return statics:PlayEventAtLocation(gun, ev, xf, true) end)
    if not inst then return false end
    try(function() statics:EventInstanceSetVolume(inst, volume) end)
    if pitch ~= 1.0 then try(function() statics:EventInstanceSetPitch(inst, pitch) end) end
    return true
end

local function play_echo(gun)
    local ev = tail_for(gun)
    if not ev then return end
    local loc = try(function() return gun:K2_GetActorLocation() end)
    if not loc then return end
    local xf = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    local layers = indoor and INDOOR_LAYERS or canyon_layers()
    local base = indoor and CFG.indoorEchoVolume or CFG.echoVolume
    local ok = false
    for _, l in ipairs(layers) do
        local pitch = l[3] * CFG.echoPitch
        if l[1] == 0 then
            ok = play_layer(gun, ev, xf, base * l[2], pitch)
        else
            -- Echo layers look the gun up again by path: it may be dropped or
            -- unloaded before the delay ends.
            local gun_path = LIB.path_of(gun)
            game_later(l[1], function()
                local g = LIB.resolve(gun_path)
                if valid(g) then play_layer(g, ev, xf, base * l[2], pitch) end
            end)
        end
    end
    if echo_logged < 3 then
        echo_logged = echo_logged + 1
        log(string.format("echo %s x%d (%s) on %s: %s", fname(ev), #layers, indoor and "indoor" or "outdoor",
            fname(gun:GetClass()), ok and "played" or "FAILED"))
    end
end

-- Bass: no EQ is reachable from mods, so low end is added by playing the
-- gun's own shot event again, pitched far down (mostly boom), under the
-- real shot. The real shot instances (ActiveGunshotInstances on the gun BP)
-- are also pitched slightly down to soften the metallic ring.
local bass_logged, pitch_logged = false, false
local function play_bass(gun)
    if CFG.bassLayerVolume <= 0 then return end
    local ev = try(function() return gun.GunfireSound end)
    local loc = try(function() return gun:K2_GetActorLocation() end)
    if not valid(ev) or not loc then return end
    local xf = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    local ok = play_layer(gun, ev, xf, CFG.bassLayerVolume, CFG.bassLayerPitch)
    if not bass_logged then
        bass_logged = true
        log(string.format("bass layer %s at pitch %.2f: %s", fname(ev), CFG.bassLayerPitch, ok and "played" or "FAILED"))
    end
end

local function pitch_shots(gun)
    if CFG.shotPitch == 1.0 then return end
    local statics = try(function() return StaticFindObject("/Script/FMODStudio.Default__FMODBlueprintStatics") end)
    local n = 0
    try(function()
        gun.ActiveGunshotInstances:ForEach(function(_, elem)
            local v = elem:get()
            -- FFMODEventInstance struct, or an FMODAudioComponent object
            if try(function() statics:EventInstanceSetPitch(v, CFG.shotPitch); return true end)
                or try(function() v:SetPitch(CFG.shotPitch); return true end) then
                n = n + 1
            end
        end)
    end)
    if not pitch_logged then
        pitch_logged = true
        log(string.format("shot pitch %.2f applied to %d active gunshot instances", CFG.shotPitch, n))
    end
end

-- A shot = the held gun's magazine count dropped since the last frame.
local last_gun, last_mag = nil, nil
-- The full lookup (player controller -> pawn -> equipment -> held item) is
-- too costly every frame (~0.3 ms, 2026-10-17 profile), so it runs 4 times a
-- second and each frame only finds the gun again by path.
local gun_path, next_gun_lookup = nil, 0
local function current_gun()
    local now = os.clock()
    if now >= next_gun_lookup then
        next_gun_lookup = now + 0.25
        local g = held_gun(player_pawn())
        gun_path = g and LIB.path_of(g) or nil
        if gun_path == "" then gun_path = nil end
        return g
    end
    if not gun_path then return nil end
    return LIB.resolve(gun_path)
end
------------------------------------------------------------------ ducking
-- User 2026-10-18: a bit of ducking. Right after each of your shots the
-- ambient, music and world-sound buses drop to duckAmount and come back
-- over duckRecoverMs. Guns, dialogue and UI are untouched.
local DUCK_BUSES = {
    "/Game/FMOD/Buses/Master/Ambient", "/Game/FMOD/Buses/Master/Music",
    "/Game/FMOD/Buses/Master/SFX/Env", "/Game/FMOD/Buses/Master/SFX/Random_Encounters",
}
local duck_at = nil        -- os.clock() of the last shot while ducking
local duck_level = 1       -- volume last sent
local function set_duck(vol)
    local statics = try(function() return StaticFindObject("/Script/FMODStudio.Default__FMODBlueprintStatics") end)
    if not valid(statics) then return end
    for _, pkg in ipairs(DUCK_BUSES) do
        local short = pkg:match("([^/]+)$")
        local object_path = pkg .. "." .. short
        LIB.register(object_path, "FMODBus")
        -- Loading is allowed only when restoring to full volume, so a bus
        -- never stays ducked; mid-duck steps use buses already loaded.
        local bus = (vol >= 1) and find_or_load(object_path, pkg) or LIB.resolve(object_path)
        if valid(bus) then try(function() statics:BusSetVolume(bus, vol) end) end
    end
    duck_level = vol
end
local function duck_tick()
    if not duck_at then return end
    local t = (os.clock() - duck_at) * 1000 / math.max(1, CFG.duckRecoverMs)
    local vol = t >= 1 and 1 or CFG.duckAmount + (1 - CFG.duckAmount) * t * t   -- eases back in
    if math.abs(vol - duck_level) > 0.03 or vol >= 1 then set_duck(vol) end
    if vol >= 1 then duck_at = nil end
end
game_loop(50, function() pcall(duck_tick) end)

local function on_shot(gun)
    if CFG.duckAmount < 1 then
        duck_at = os.clock()
        if duck_level > CFG.duckAmount + 0.01 then set_duck(CFG.duckAmount) end
    end
    pitch_shots(gun)
    play_bass(gun)
    local now = os.clock() * 1000
    if now - last_echo >= CFG.echoMinGapMs then
        last_echo = now
        play_echo(gun)
    end
end

-- Shots are caught when the player's gun spawns a projectile (BeginPlay on
-- the game thread), so nothing runs while you are not shooting. Polling the
-- magazine every frame cost ~1,900 calls per 15 s (2026-10-17). Shotgun
-- pellets within 40 ms count as one shot.
local last_projectile_shot = -100
REBALANCE_ON_ACTOR("/Script/Permafrost.Projectile", function(proj)
    if not gun_path then return end
    local owner = LIB.call(proj, "GetOwner")
    if not owner or LIB.path_of(owner) ~= gun_path then return end
    local now = os.clock()
    if now - last_projectile_shot < 0.04 then return end
    last_projectile_shot = now
    local gun = LIB.resolve(gun_path)
    if gun then
        local ok, err = pcall(on_shot, gun)
        if not ok then log("echo error: " .. tostring(err)) end
        last_mag = LIB.get(gun, "CurrentMagazine")
    end
end)

-- Fallback for guns whose shots spawn no projectile: the magazine count,
-- every 100 ms, only while projectile shots have not been seen lately.
local function echo_tick()
    local gun = current_gun()
    local addr = gun and LIB.address(gun)
    local mag = gun and LIB.get(gun, "CurrentMagazine")
    if os.clock() - last_projectile_shot > 3 and addr and addr == last_gun
        and type(mag) == "number" and type(last_mag) == "number" and mag < last_mag then
        on_shot(gun)
    end
    last_gun, last_mag = addr, mag
end

if CFG.echoVolume > 0 or CFG.indoorEchoVolume > 0 or CFG.bassLayerVolume > 0 then
    local next_indoor = 0
    game_loop(100, function()
        local ok, err = pcall(function()
            local now = os.clock()
            if now >= next_indoor then next_indoor = now + 0.5; check_indoor() end
            echo_tick()
        end)
        if not ok then log("echo error: " .. tostring(err)) end
    end)
end

-- Recoil every tick (2 s, cheap StaticFindObject lookups); the rest every 5th.
local ticks = 0
local function tick()
    if ticks % 5 == 0 then
        apply_audio()
        apply_shakes()
    end
    ticks = ticks + 1
    apply_recoil()
end

game_loop(2000, function()
    local ok, err = pcall(tick)
    if not ok then log("error: " .. tostring(err)) end
end)

------------------------------------------------------------------ headshot feed
-- The head bonus itself is applied natively (dlls\main.dll detours the GAS
-- damage helper that doubles head hits). This tells it the multiplier for
-- the weapon in your hands, and who the player is (hits on you are never
-- boosted). ApplyPointDamage is not on the damage path (2026-10-17).
local COMBAT_FILE = (mod_root() or "") .. "dlls\\combat.txt"
local last_combat = nil
local function held_item(pawn)
    if not pawn then return nil end
    local equip = equip_name and try(function() return pawn[equip_name] end)
    if not valid(equip) then
        for _, n in ipairs({ "Equipment Component", "EquipmentComponent" }) do
            equip = try(function() return pawn[n] end)
            if valid(equip) then equip_name = n break end
        end
    end
    if not valid(equip) then return nil end
    local item = try(function() return equip.HeldItem.ItemActor end)
    return valid(item) and item or nil
end
-- Hall reverb: main.dll adds an FMOD SFX Reverb DSP to the gunshot bus and
-- reads its settings from dlls\reverb.txt (indoor = louder reverb).
local REVERB_FILE = (mod_root() or "") .. "dlls\\reverb.txt"
local last_reverb = nil
local function write_reverb()
    local text = string.format("on=%d\ndecay=%.0f\nearly=20\nlate=29\nhighcut=%.0f\nmix=80\nwet=%.1f\ndry=0\nend\n",
        CFG.hallReverb == 1 and 1 or 0, CFG.hallDecayMs, CFG.hallHighCutHz,
        indoor and CFG.hallWetIndoorDb or CFG.hallWetDb)
    if text == last_reverb then return end
    last_reverb = text
    local f = io.open(REVERB_FILE .. ".tmp", "wb")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(REVERB_FILE)
    os.rename(REVERB_FILE .. ".tmp", REVERB_FILE)
end

local function write_combat()
    local pawn = player_pawn()
    local item = held_item(pawn)
    local mult = item and kind_mult(causer_kind(item)) or 1.0
    local pa = pawn and try(function() return pawn:GetAddress() end) or 0
    local text = string.format("head=%.3f\npawn=%X\nend\n", mult, pa)
    if text == last_combat then return end
    last_combat = text
    local f = io.open(COMBAT_FILE .. ".tmp", "wb")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(COMBAT_FILE)
    os.rename(COMBAT_FILE .. ".tmp", COMBAT_FILE)
end
game_loop(250, function()
    local ok, err = pcall(write_combat)
    if ok then ok, err = pcall(write_reverb) end
    if not ok then log("headshot feed error: " .. tostring(err)) end
end)
log(string.format("headshots: the game's x2 head bonus is multiplied by %.1f pistol, %.1f rifle, %.1f bow, %.1f melee",
    CFG.headshotPistol, CFG.headshotRifle, CFG.headshotBow, CFG.headshotMultiplier))

log("loaded")
