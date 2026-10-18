-- HarderHunting module of the Rebalance mod (was its own mod until 2026-10-17).
-- Settings: Rebalance\config\HarderHunting.lua
-- HarderHunting: animals see and hear farther, run faster, take more hits.
-- Pure reflection: scales properties on each animal, its AI controller's
-- sense configs, its UAnimalConfig data asset, and animal spawn points.
-- Movement speed is scaled live on CharacterMovement.MaxWalkSpeed.
-- Every object is scaled exactly once per construction (see `done`).
local TAG = "[PF HarderHunting] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

-- Game-thread scheduling. LoopAsync + ExecuteInGameThread queues a new
-- callback from a worker thread on every tick; with several mods doing it,
-- UE4SS raced ("Ref was not function") and crashed the game on 2026-10-16.
-- This UE4SS build can loop directly on the game thread; the old pattern is
-- only a fallback.
local LIB = REBALANCE_LIB
local get, set, call = LIB.get, LIB.set, LIB.call  -- allocation-free, for the fast loops  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, path_of, resolve, address, game_loop, game_later = LIB.try, LIB.valid, LIB.fname, LIB.path_of, LIB.resolve, LIB.address, LIB.game_loop, LIB.game_later
-- Objects are kept by path and looked up when needed: holding a Lua
-- reference to an object the game later frees crashed the game (2026-10-17).
local function name_of(obj)
    return try(function() return obj:GetFullName() end) or "?"
end

------------------------------------------------------------------ config
local DEFAULTS = {
    { "sightRangeMultiplier",       3.0,  "how far animals can see you" },
    { "peripheralVisionMultiplier", 1.25, "how wide animals can see (cap 180 deg)" },
    { "hearingRangeMultiplier",     4.0,  "how far animals can hear you" },
    { "animalSpeedMultiplier",      1.25, "all movement states, fleeing included" },
    { "injuredSpeedMultiplier",     1.0,  "speed cap once wounded" },
    { "animalHealthMultiplier",     1.0,  "animal max health" },
    { "lootMultiplier",             1.0,  "meat/hide amounts (min 1)" },
    { "bigGameMeatMultiplier",      4.0,  "meat, fat and bones from deer, elk, boar and bears (vanilla 1.0); pelts unchanged" },
    { "spawnCountMultiplier",       1.0,  "animals per spawn point (below 1 = scarcer)" },
    { "smartFlee",                  1,    "1 = prey always flee away from you (herbivores only)" },
    { "fleeDistanceMetres",         60,   "how far away from you fleeing prey aim for" },
    { "fleeCheckMetres",            90,   "prey within this range of you are steered" },
    { "fearSeconds",                180,  "after fleeing, prey avoid you this long (0 = off)" },
    { "fearMetres",                 150,  "and will not walk back within this distance of you" },
}
local MIN_MULT, MAX_MULT = 0.1, 5.0

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
    if type(root) == "string" then return root .. "\\ue4ss\\Mods\\HarderHunting\\" end
    return nil
end

local function write_default_config(path)
    local f = io.open(path, "w")
    if not f then return end
    f:write("-- HarderHunting settings. 1.0 = vanilla. Range 0.1 to 5.0. Restart the game to apply.\n")
    f:write("return {\n")
    for _, d in ipairs(DEFAULTS) do
        f:write(string.format("    %s = %s, -- %s\n", d[1], tostring(d[2]), d[3]))
    end
    f:write("}\n")
    f:close()
end

local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local root = mod_root()
    if not root then
        log("mod folder not found, using defaults")
        return cfg
    end
    local path = root .. "config\\HarderHunting.lua"
    local f = io.open(path, "r")
    if not f then
        write_default_config(path)
        log("created " .. path)
        return cfg
    end
    local text = f:read("*a")
    f:close()
    -- Empty environment: the file can only return a table of numbers.
    local chunk = load(text, "config.lua", "t", {})
    local user = chunk and try(chunk)
    if type(user) ~= "table" then
        log("config.lua unreadable, using defaults")
        return cfg
    end
    for _, d in ipairs(DEFAULTS) do
        local v = tonumber(user[d[1]])
        if v then
            if d[1]:find("Multiplier$") then v = math.max(MIN_MULT, math.min(MAX_MULT, v)) end
            cfg[d[1]] = v
        end
    end
    return cfg
end

local CFG = load_config()
for _, d in ipairs(DEFAULTS) do log(d[1] .. " = " .. tostring(CFG[d[1]])) end

------------------------------------------------------------------ helpers
-- Objects already scaled. Cleared when a watcher sees a new object there.
local done = {}
-- Keyed by address AND full name: a new object at a reused address is
-- normally named differently, so it is not mistaken for the old one even
-- before a watcher releases it.
local function done_key(obj)
    local a = address(obj)
    if not a then return nil end
    return tostring(a) .. " " .. (try(function() return obj:GetFullName() end) or "")
end
local function claim(obj)
    local k = done_key(obj)
    if not k or done[k] then return false end
    done[k] = true
    return true
end
local function release(obj)
    local k = done_key(obj)
    if k then done[k] = nil end
end

local function is_template(obj)
    local n = try(function() return obj:GetFName():ToString() end) or ""
    if n:find("^Default__") then return true end
    local flags = try(function()
        return obj:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject)
    end)
    return flags == true
end

local function scale_float(obj, prop, mult, cap)
    if mult == 1.0 then return false end
    local v = try(function() return obj[prop] end)
    if type(v) ~= "number" then return false end
    local nv = v * mult
    if cap then nv = math.min(nv, cap) end
    return try(function() obj[prop] = nv; return true end) == true
end

local function scale_int(obj, prop, mult, minimum)
    if mult == 1.0 then return false end
    local v = try(function() return obj[prop] end)
    if type(v) ~= "number" then return false end
    local nv = math.max(minimum, math.floor(v * mult + 0.5))
    return try(function() obj[prop] = nv; return true end) == true
end

local function later(ms, fn)
    game_later(ms, function()
        local ok, err = pcall(fn)
        if not ok then log("error: " .. tostring(err)) end
    end)
end

------------------------------------------------------------------ senses
local function scale_sense(sense)
    if not valid(sense) or not claim(sense) then return end
    local cls = try(function() return sense:GetClass():GetFName():ToString() end) or ""
    if cls:find("Sight") then
        scale_float(sense, "SightRadius", CFG.sightRangeMultiplier)
        scale_float(sense, "LoseSightRadius", CFG.sightRangeMultiplier)
        scale_float(sense, "PeripheralVisionAngleDegrees", CFG.peripheralVisionMultiplier, 180.0)
    elseif cls:find("Hearing") then
        scale_float(sense, "HearingRange", CFG.hearingRangeMultiplier)
        scale_float(sense, "LoSHearingRange", CFG.hearingRangeMultiplier)
    end
end

local function scale_controller(ctrl)
    if not valid(ctrl) then return false end
    local comp = try(function() return ctrl.AIPerception end)
    if not valid(comp) then comp = try(function() return ctrl.PerceptionComponent end) end

    -- Direct config pointers on the Permafrost controllers, then the
    -- perception component's own list. claim() dedups shared objects.
    for _, p in ipairs({ "_SightConfig", "_HearingConfig", "SenseConfigSight" }) do
        scale_sense(try(function() return ctrl[p] end))
    end
    if valid(comp) then
        try(function()
            comp.SensesConfig:ForEach(function(_, elem) scale_sense(elem:get()) end)
        end)
        -- Re-digest ranges into the perception system.
        try(function() comp:RequestStimuliListenerUpdate() end)
    end
    return true
end

------------------------------------------------------------------ config asset
-- A big animal's meat: a red deer gives 40-60 kg of meat in reality, but one
-- piece of raw meat in game (user, 2026-10-17). Meat, fat and bones of big
-- game are multiplied; pelts stay as they are.
local BIG_GAME = { "deer", "elk", "moose", "boar", "bear", "bison", "stag" }
local function loot_item_name(e)
    for _, f in ipairs({ "Item", "ItemConfig", "ItemBase", "ItemToSpawn", "ItemClass" }) do
        local v = try(function() return e[f] end)
        if v ~= nil then
            local id = try(function() return v:GetObjectID() end)
            local p = id and (try(function() return id:GetAssetPathName():ToString() end) or try(function() return id:ToString() end))
            if type(p) == "string" and p ~= "" then return p:match("([^%./]+)$") or p end
            if valid(v) then return fname(v) end
        end
    end
    return "?"
end
local loot_logged = 0
local function scale_animal_config(cfg)
    if not valid(cfg) or not claim(cfg) then return end
    scale_float(cfg, "MaxHealth", CFG.animalHealthMultiplier)
    local cname = fname(cfg):lower()
    local big = false
    for _, k in ipairs(BIG_GAME) do if cname:find(k, 1, true) then big = true end end
    local parts = {}
    try(function()
        cfg.Loot:ForEach(function(_, elem)
            local e = elem:get()
            local item = loot_item_name(e)
            local before = try(function() return e.ItemAmount end)
            local mult = CFG.lootMultiplier
            local l = item:lower()
            if big and (l:find("meat") or l:find("fat") or l:find("bone")) then mult = mult * CFG.bigGameMeatMultiplier end
            if mult ~= 1.0 then scale_int(e, "ItemAmount", mult, 1) end
            parts[#parts + 1] = string.format("%s %s->%s", item, tostring(before), tostring(try(function() return e.ItemAmount end)))
        end)
    end)
    if loot_logged < 12 then
        loot_logged = loot_logged + 1
        log(string.format("loot %s%s: %s", fname(cfg), big and " (big game)" or "", table.concat(parts, ", ")))
    end
end

------------------------------------------------------------------ animals
local stats = { animals = 0, noController = 0 }

-- Speed: UE4SS 3.0.1 cannot write TMaps (StateSpeedMap), so the speed the
-- game puts into CharacterMovement.MaxWalkSpeed for each state is scaled
-- instead. last_set[address] = value we wrote; any other value means the
-- game changed state, so it is scaled again.
local tracked, last_set = {}, {}
local flee_list = {}  -- every scaled animal; smart_flee filters to prey near the player
local speed_logged = false
local function scale_speeds()
    local keep = {}
    for _, path in ipairs(tracked) do
        local animal = resolve(path)
        if animal then
            keep[#keep + 1] = path
            local a = address(animal)
            local cmc = get(animal, "CharacterMovement")
            local cur = cmc and get(cmc, "MaxWalkSpeed")
            if a and type(cur) == "number" and cur > 0 then
                local prev = last_set[a]
                if not prev or math.abs(cur - prev) > 0.01 then
                    local nv = cur * CFG.animalSpeedMultiplier
                    if set(cmc, "MaxWalkSpeed", nv) then
                        last_set[a] = nv
                        if not speed_logged then
                            speed_logged = true
                            log(string.format("speed %s: %.0f -> %.0f", name_of(animal), cur, nv))
                        end
                    end
                end
            end
        end
    end
    tracked = keep
end

local retry_pending = {}  -- { path, attempt, due }: animals not possessed yet
local function scale_animal(animal, attempt)
    if not valid(animal) then return end
    local ctrl = try(function() return animal.AIController end)
    if not valid(ctrl) then ctrl = try(function() return animal.Controller end) end
    if not valid(ctrl) then
        -- Not possessed yet: retry a few times, then give up on senses only.
        if attempt < 5 then
            retry_pending[#retry_pending + 1] = { path_of(animal), attempt + 1, os.clock() + 1.0 }
            return
        end
        stats.noController = stats.noController + 1
    end
    if not claim(animal) then return end

    scale_animal_config(try(function() return animal.AnimalConfig end))
    scale_float(animal, "Injured_MaxSpeed", CFG.injuredSpeedMultiplier)
    if CFG.animalSpeedMultiplier ~= 1.0 then
        last_set[address(animal) or 0] = nil  -- new animal at a reused address
        table.insert(tracked, path_of(animal))
    end
    if valid(ctrl) then scale_controller(ctrl) end
    table.insert(flee_list, path_of(animal))

    stats.animals = stats.animals + 1
    if stats.animals <= 3 or stats.animals % 25 == 0 then
        log(string.format("scaled animal #%d %s", stats.animals, name_of(animal)))
    end
end

------------------------------------------------------------------ smart flee
-- Prey picked escape points without regard to where the player is (the
-- escape AI heads for the animal's hiding place), so they sometimes ran back
-- past the player. For herbivores near the player:
--  * the hiding place is kept 60 m straight away from the player, so every
--    escape choice lies away from them;
--  * an animal running TOWARD the player while not attacking (no
--    CombatTarget) is ordered to the away point directly.
-- Predators (non-herbivore controllers) are never touched.
local flee_corrected = {}  -- address -> os.clock() of last direct order
local spooked = {}         -- address -> os.clock() when the animal last fled from the player
local flee_logged = 0

local function vec(v) return v and v.X, v and v.Y, v and v.Z end

local function player_pawn()
    local helpers = try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and try(function() return pc.Pawn end)
    return valid(pawn) and pawn or nil
end

local prey_by_class = {}   -- controller class name -> prey?
local function is_prey(animal)
    local ctrl = get(animal, "Controller")
    if not valid(ctrl) then return false, nil end
    local cn = fname(call(ctrl, "GetClass"))
    local p = prey_by_class[cn]
    if p == nil then p = cn:find("Herbivore") ~= nil prey_by_class[cn] = p end
    return p, ctrl
end

-- Fear memory: once prey has fled, its patrol AI would walk it home to the
-- spawn area, often right back to the player. For fearSeconds afterwards it
-- is kept fearMetres away: any movement toward the player inside that range
-- gets an order to a point away from the player.
local function order_away(animal, ctrl, target, now, why, d, gap)
    local a = address(animal)
    if not a or now - (flee_corrected[a] or 0) < gap then return end
    flee_corrected[a] = now
    local ok = try(function()
        ctrl:MoveToLocation(target, 150.0, false, true, true, false, nil, true)
        return true
    end)
    if flee_logged < 8 then
        flee_logged = flee_logged + 1
        log(string.format("flee fix (%s): %s at %.0f m, state %s -> sent away %s", why, fname(animal:GetClass()),
            d / 100, tostring(try(function() return animal.CurrentState end)), ok and "OK" or "FAILED"))
    end
end

-- Steering the behavior tree itself: a one-off MoveToLocation is replaced
-- within seconds when the tree re-runs its own move, so while an animal is
-- afraid its destinations are rewritten every tick instead:
--  * PatrolTargetLocation and every PatrolTargetLocations entry (saved first,
--    restored when the fear ends), so "go home / patrol" leads away;
--  * blackboard vector keys whose names look like destinations.
local saved_patrol = {}   -- address -> { animal, current = {x,y,z}, list = {{x,y,z},...} }
local bb_cache = {}       -- blackboard asset address -> { vector key names }
local bb_logged = false
local DEST_WORDS = { "patrol", "hid", "escape", "run", "flee", "home", "spawn", "wander", "location", "point" }

local function xyz(v) return { v.X, v.Y, v.Z } end

local function blackboard_keys(ctrl)
    local bb = try(function() return ctrl.Blackboard end)
    if not valid(bb) then return nil, nil end
    local asset = try(function() return bb.BlackboardAsset end)
    local aa = address(asset)
    if not aa then return bb, nil end
    if not bb_cache[aa] then
        local keys, all = {}, {}
        local function collect(data, depth)
            if not valid(data) or depth > 4 then return end
            try(function()
                data.Keys:ForEach(function(_, e)
                    local entry = e:get()
                    local name = try(function() return entry.EntryName:ToString() end) or "?"
                    local kt = fname(try(function() return entry.KeyType:GetClass() end))
                    all[#all + 1] = name .. ":" .. kt:gsub("BlackboardKeyType_", "")
                    if kt:find("Vector") then
                        local low = name:lower()
                        for _, w in ipairs(DEST_WORDS) do
                            if low:find(w, 1, true) then keys[#keys + 1] = name; break end
                        end
                    end
                end)
            end)
            collect(try(function() return data.Parent end), depth + 1)
        end
        collect(asset, 0)
        bb_cache[aa] = keys
        if not bb_logged then
            bb_logged = true
            log(string.format("blackboard %s keys: %s | steering: %s", fname(asset), table.concat(all, ", "),
                #keys > 0 and table.concat(keys, ", ") or "none"))
        end
    end
    return bb, bb_cache[aa]
end

local function steer_ai(animal, ctrl, target, a)
    -- Patrol destinations (save originals once).
    if not saved_patrol[a] then
        local rec = { path = path_of(animal), list = {} }
        local cur = try(function() return animal.PatrolTargetLocation end)
        if cur then rec.current = xyz(cur) end
        try(function()
            animal.PatrolTargetLocations:ForEach(function(_, e) rec.list[#rec.list + 1] = xyz(e:get()) end)
        end)
        saved_patrol[a] = rec
    end
    try(function() animal.PatrolTargetLocation = target end)
    try(function()
        animal.PatrolTargetLocations:ForEach(function(i, e)
            local ang = i * 2.4  -- spread the points around the away target
            local p = { X = target.X + math.cos(ang) * 800, Y = target.Y + math.sin(ang) * 800, Z = target.Z }
            if not try(function() e:set(p); return true end) then
                local v = e:get(); v.X = p.X; v.Y = p.Y; v.Z = p.Z
            end
        end)
    end)
    -- Blackboard destinations.
    local bb, keys = blackboard_keys(ctrl)
    if bb and keys then
        for _, k in ipairs(keys) do
            try(function() bb:SetValueAsVector(FName(k), target) end)
        end
    end
end

-- When the fear ends the animal is RE-HOMED where it stands, not sent back:
-- restoring the original patrol points walked deer back to their spawn and
-- toward the player (user, 2026-10-17). Patrol points and home/spawn-like
-- blackboard keys now sit around the spot it fled to, so each scare pushes
-- it further away.
local rehomed = 0
local function restore_patrol(a)
    local rec = saved_patrol[a]
    saved_patrol[a] = nil
    local animal = rec and resolve(rec.path)
    if not animal then return end
    local here = try(function() return animal:K2_GetActorLocation() end)
    if not here then return end
    local home = { X = here.X, Y = here.Y, Z = here.Z }
    try(function() animal.PatrolTargetLocation = home end)
    try(function()
        animal.PatrolTargetLocations:ForEach(function(i, e)
            local ang = i * 2.4
            local p = { X = here.X + math.cos(ang) * 1500, Y = here.Y + math.sin(ang) * 1500, Z = here.Z }
            if not try(function() e:set(p); return true end) then
                local v = e:get(); v.X = p.X; v.Y = p.Y; v.Z = p.Z
            end
        end)
    end)
    local ctrl = try(function() return animal.Controller end)
    local bb, keys = valid(ctrl) and blackboard_keys(ctrl)
    if bb and keys then
        for _, k in ipairs(keys) do
            try(function() bb:SetValueAsVector(FName(k), home) end)
        end
    end
    try(function() animal:SetDefaultHidingPlace(home) end)
    if rehomed < 5 then
        rehomed = rehomed + 1
        log(string.format("re-homed %s at %.0f,%.0f (fear over, stays where it fled)", fname(animal), here.X, here.Y))
    end
end

local steered = {}         -- address -> os.clock() of the last patrol rewrite
local function smart_flee()
    if CFG.smartFlee ~= 1 then return end
    local pawn = player_pawn()
    local px, py = vec(pawn and call(pawn, "K2_GetActorLocation"))
    if not px then return end
    local check = CFG.fleeCheckMetres * 100
    local fear = CFG.fearMetres * 100
    local reach2 = math.max(check, fear) ^ 2
    local now = os.clock()
    local keep = {}
    for _, path in ipairs(flee_list) do
        local animal = resolve(path)
        if animal then
            keep[#keep + 1] = path
            local ax, ay, az = vec(call(animal, "K2_GetActorLocation"))
            if ax then
                local dx, dy = ax - px, ay - py
                local d2 = dx * dx + dy * dy
                if d2 < reach2 and d2 > 1 then
                    local prey, ctrl = is_prey(animal)
                    if prey then
                        local a = address(animal)
                        local d = math.sqrt(d2)
                        local ux, uy = dx / d, dy / d  -- unit vector player -> animal
                        local far = CFG.fleeDistanceMetres * 100
                        local target = { X = ax + ux * far, Y = ay + uy * far, Z = az }
                        local vx, vy = vec(call(animal, "GetVelocity"))
                        local speed = vx and math.sqrt(vx * vx + vy * vy) or 0
                        local toward = speed > 1 and -(vx * ux + vy * uy) / speed or 0  -- 1 = straight at the player
                        local attacking = valid(get(animal, "CombatTarget"))
                        local afraid = a and spooked[a] and now - spooked[a] < CFG.fearSeconds

                        if d < check then
                            call(animal, "SetDefaultHidingPlace", target)
                            if speed > 300 and not attacking and a then spooked[a] = now end
                            if speed > 300 and not attacking and toward > 0.5 then
                                order_away(animal, ctrl, target, now, "running at you", d, 1.5)
                            end
                        end
                        if afraid and not attacking then
                            call(animal, "SetDefaultHidingPlace", target)
                            -- Patrol points + blackboard rewrite: at most every 2 s per
                            -- animal (every 250 ms caused ~100 ms spikes, 2026-10-17).
                            if not steered[a] or now - steered[a] >= 2 then
                                steered[a] = now
                                steer_ai(animal, ctrl, target, a)
                            end
                            if d < fear and speed > 50 and toward > 0.3 then
                                order_away(animal, ctrl, target, now, "returning", d, 3.0)
                            end
                        end
                    end
                end
            end
        end
    end
    flee_list = keep
    -- Fear over (or animal gone): give it its home patrol back.
    for a, _ in pairs(saved_patrol) do
        if not spooked[a] or now - spooked[a] >= CFG.fearSeconds then restore_patrol(a) end
    end
end

local function scale_spawn_point(sp)
    if not valid(sp) or not claim(sp) then return end
    local m = CFG.spawnCountMultiplier
    scale_int(sp, "MinNumOfSpawnedAnimals", m, 0)
    scale_int(sp, "MaxNumOfSpawnedAnimals", m, 1)
end

------------------------------------------------------------------ wiring
-- New-object callbacks only write down the path. They can run nested inside
-- one of our own scheduled callbacks (a game call we make spawns objects),
-- and scheduling more work from there corrupted UE4SS's queue (crashes in
-- UE4SS, render, Niagara and save code, 2026-10-17). A loop does the work.
-- Paths only, never the object: it can be unloaded before the delay ends.
local new_pending = {}   -- { path, handler, due }
local function run_pending()
    if #new_pending == 0 then return end
    local now, keep = os.clock(), {}
    local list = new_pending
    new_pending = {}
    for _, v in ipairs(list) do
        if now < v[3] then
            keep[#keep + 1] = v
        else
            local o = resolve(v[1])
            if o then
                local ok, err = pcall(v[2], o, 0)
                if not ok then log("error: " .. tostring(err)) end
            end
        end
    end
    for _, v in ipairs(new_pending) do keep[#keep + 1] = v end
    new_pending = keep
end

-- Game thread only, never NotifyOnNewObject (see main.lua): actors at
-- BeginPlay, data objects by a FindAllOf poll.
local function watch(class_path, delay, handler)
    local ok = REBALANCE_ON_ACTOR(class_path, function(obj)
        release(obj)
        if is_template(obj) then return end
        new_pending[#new_pending + 1] = { path_of(obj), handler, os.clock() + delay / 1000 }
    end)
    log((ok and "watching " or "FAILED to watch ") .. class_path)
end
local function watch_release(class_name)
    REBALANCE_ON_ASSET(class_name, release)
end

-- Release-only watches: new sense configs / data assets at a reused address.
watch_release("AISenseConfig")
watch_release("AnimalConfig")
-- Delay lets possession finish before we read properties.
watch("/Script/Permafrost.PermaAnimalBase", 1500, scale_animal)
watch("/Script/Permafrost.AnimalSpawnPoint", 500, scale_spawn_point)

-- 250 ms: catch each state change (calm -> alert -> flee) soon after it happens.
game_loop(250, function()
    run_pending()
    if #retry_pending > 0 then
        local now, list = os.clock(), retry_pending
        retry_pending = {}
        for _, v in ipairs(list) do
            if now < v[3] then
                retry_pending[#retry_pending + 1] = v
            else
                local a = resolve(v[1])
                if a then pcall(scale_animal, a, v[2]) end
            end
        end
    end
    local ok, err = pcall(scale_speeds)
    if not ok then log("speed error: " .. tostring(err)) end
    ok, err = pcall(smart_flee)
    if not ok then log("flee error: " .. tostring(err)) end
end)

-- Hot reload / late load: pick up anything already in the world.
later(100, function()
    for _, a in ipairs(FindAllOf("PermaAnimalBase") or {}) do
        if not is_template(a) then scale_animal(a, 0) end
    end
    for _, s in ipairs(FindAllOf("AnimalSpawnPoint") or {}) do
        if not is_template(s) then scale_spawn_point(s) end
    end
end)

log("loaded")
