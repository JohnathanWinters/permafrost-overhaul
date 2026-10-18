-- SpawnDistance module of the Rebalance mod (was its own mod until 2026-10-17).
-- Settings: Rebalance\config\SpawnDistance.lua
-- SpawnDistance: animals and hostile NPCs spawn farther from the player.
-- Pure reflection, three levers:
--  1. Spawn-placement EQS queries (/Game/Permafrost/Blueprints/AI/EQS/...):
--     generator radii (circle/donut/grid/cone) and Distance-test min/max are
--     scaled by spawnDistanceMultiplier.
--  2. PlayerDetection volumes on AAnimalSpawnPoint, AActorSpawnerBase and
--     AStaticEncounterBase: things spawn when you enter these, so a bigger
--     volume spawns them while you are still farther away.
--  3. URandomEncountersSubsystem.MaksimumDistance (encounter actors beyond it
--     are cleaned up) is scaled with the spawn distance, so far spawns are
--     not deleted on arrival.

local TAG = "[PF SpawnDistance] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

-- Game-thread scheduling (LoopAsync + ExecuteInGameThread crashed UE4SS).
local LIB = REBALANCE_LIB  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, path_of, resolve, address, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.path_of, LIB.resolve, LIB.address, LIB.game_loop

-- Objects are kept by path across delays and looked up again: an object
-- unloaded during the delay must never be written to.

------------------------------------------------------------------ config
local DEFAULTS = {
    { "spawnDistanceMultiplier",    2.0, "how far other spawn placement queries reach (1.0 = vanilla)" },
    { "randomEncounterMinMetres",   100, "random encounters (patrols etc.) spawn at least this far away" },
    { "randomEncounterMaxMetres",   200, "and at most this far away" },
    { "animalTriggerMultiplier",    2.0, "size of animal spawn-point trigger volumes (non-bear)" },
    { "bearTriggerMultiplier",      1.0, "size of bear spawn-point trigger volumes (vanilla 250 m)" },
    { "encounterTriggerMultiplier", 2.0, "size of NPC/encounter spawner trigger volumes" },
    { "spawnerSpreadMultiplier",    2.5, "how far apart a spawner's group stands (vanilla 1.0 = 10 m square, 1 m apart)" },
    { "spawnerIntervalSeconds",     1.0, "seconds between each NPC a spawner creates (vanilla 0.1); spreads the spawn hitch" },
    { "blockSpawnMetres",           100, "spawners do not spawn while you are this close to them (vanilla 0 = no limit)" },
}
local MIN_MULT, MAX_MULT = 0.25, 6.0

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
    if type(root) == "string" then return root .. "\\ue4ss\\Mods\\SpawnDistance\\" end
    return nil
end

local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local root = mod_root()
    if not root then return cfg end
    local path = root .. "config\\SpawnDistance.lua"
    local f = io.open(path, "r")
    if not f then
        f = io.open(path, "w")
        if f then
            f:write("-- SpawnDistance settings. 1.0 = vanilla. Range 0.25 to 6.0. Restart the game to apply.\n")
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
-- Address -> true once scaled; cleared when a new object takes the address.
local done = {}
local function claim(obj)
    local a = address(obj)
    if not a or done[a] then return false end
    done[a] = true
    return true
end
local function release(obj)
    local a = address(obj)
    if a then done[a] = nil end
end
local function is_template(obj)
    if fname(obj):find("^Default__") then return true end
    return try(function()
        return obj:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject)
    end) == true
end

local function load_object(path)
    local obj = try(function() return StaticFindObject(path) end)
    if valid(obj) then return obj end
    local loaded = try(function() return LoadAsset(path) end)
    if valid(loaded) then return loaded end
    obj = try(function() return StaticFindObject(path) end)
    return valid(obj) and obj or nil
end

------------------------------------------------------------------ 1. EQS queries
local EQS_DIR = "/Game/Permafrost/Blueprints/AI/EQS/"
-- Placement queries for spawning. Encounter formation (ActorPlacement),
-- sound-only, static (fixed place) and friendly background NPC queries are
-- left alone.
local SPAWN_QUERIES = {
    "SpawnLocation", "SpawnNearby", "SpawnNearbyEmpty3x3", "SpawnNearbySound",
    "SpawnNearbyPredetermined", "UnseenLocations",
    "RandomEncounterDefault", "RandomEncounter_Query_Nearest", "RandomEncounter_Query_Farthest",
}
-- FAIDataProviderFloatValue fields on generators that set reach.
local GEN_FIELDS = { "CircleRadius", "InnerRadius", "OuterRadius", "GridSize", "Range", "SearchRadius", "SpaceBetween" }

local function provider_value(obj, field)
    local p = try(function() return obj[field] end)
    if not p then return nil, nil end
    local v = try(function() return p.DefaultValue end)
    if type(v) ~= "number" then return nil, nil end
    local bound = valid(try(function() return p.DataBinding end))
    return v, bound, p
end

local function scale_provider(obj, field, mult, out)
    local v, bound, p = provider_value(obj, field)
    if not v then return end
    out[#out + 1] = string.format("%s=%.0f%s", field, v, bound and "(bound)" or "")
    if mult ~= 1.0 and v ~= 0 and not bound then
        try(function() p.DefaultValue = v * mult end)
    end
end

-- Sets an absolute value (cm); 0 = "unused" in a Distance test stays 0.
local function set_provider(obj, field, value, keep_zero, out)
    local v, bound, p = provider_value(obj, field)
    if not v then return end
    out[#out + 1] = string.format("%s=%.0f%s", field, v, bound and "(bound)" or "")
    if bound or (keep_zero and v == 0) then return end
    try(function() p.DefaultValue = value end)
end

-- Random encounter queries get exact distances instead of a multiplier.
local ENCOUNTER_QUERIES = {
    RandomEncounterDefault = true, RandomEncounter_Query_Nearest = true, RandomEncounter_Query_Farthest = true,
}

local missing_logged = {}
local function process_query(name)
    local q = load_object(EQS_DIR .. name .. "." .. name)
    if not q then
        if not missing_logged[name] then
            missing_logged[name] = true
            log("query not loaded yet: " .. name)
        end
        return false
    end
    if not claim(q) then return true end
    local m = CFG.spawnDistanceMultiplier
    local exact = ENCOUNTER_QUERIES[name]
    local lo, hi = CFG.randomEncounterMinMetres * 100, CFG.randomEncounterMaxMetres * 100
    if lo > hi then lo, hi = hi, lo end
    local options = 0
    try(function()
        q.Options:ForEach(function(_, elem)
            local opt = elem:get()
            options = options + 1
            local gen = try(function() return opt.Generator end)
            local parts = {}
            if valid(gen) then
                if exact then
                    set_provider(gen, "InnerRadius", lo, false, parts)
                    set_provider(gen, "OuterRadius", hi, false, parts)
                    set_provider(gen, "CircleRadius", hi, false, parts)
                else
                    for _, f in ipairs(GEN_FIELDS) do scale_provider(gen, f, m, parts) end
                end
            end
            local tests = {}
            try(function()
                opt.Tests:ForEach(function(_, telem)
                    local t = telem:get()
                    local cls = fname(try(function() return t:GetClass() end))
                    local tparts = {}
                    if cls:find("Distance") then
                        if exact then
                            set_provider(t, "FloatValueMin", lo, true, tparts)
                            set_provider(t, "FloatValueMax", hi, true, tparts)
                        else
                            scale_provider(t, "FloatValueMin", m, tparts)
                            scale_provider(t, "FloatValueMax", m, tparts)
                        end
                    end
                    tests[#tests + 1] = cls .. (#tparts > 0 and ("[" .. table.concat(tparts, " ") .. "]") or "")
                end)
            end)
        end)
    end)
    return true
end

------------------------------------------------------------------ 2. trigger volumes
local function scale_volume(comp, mult)
    if not valid(comp) or mult == 1.0 then return nil end
    local cls = fname(comp:GetClass())
    if cls:find("Sphere") then
        local r = try(function() return comp.SphereRadius end)
        if type(r) == "number" and r > 0 then
            try(function() comp:SetSphereRadius(r * mult, false) end)
            return string.format("sphere %.0f -> %.0f", r, r * mult)
        end
    elseif cls:find("Box") then
        local e = try(function() return comp.BoxExtent end)
        if e then
            local x, y, z = e.X, e.Y, e.Z
            try(function() comp:SetBoxExtent({ X = x * mult, Y = y * mult, Z = z }, false) end)
            return string.format("box %.0fx%.0f -> %.0fx%.0f", x, y, x * mult, y * mult)
        end
    elseif cls:find("Capsule") then
        local r = try(function() return comp.CapsuleRadius end)
        local h = try(function() return comp.CapsuleHalfHeight end)
        if type(r) == "number" and type(h) == "number" then
            try(function() comp:SetCapsuleSize(r * mult, math.max(h, r * mult), false) end)
            return string.format("capsule %.0f -> %.0f", r, r * mult)
        end
    end
    return nil
end

local volume_logged = {}
local function process_spawner(actor, kind, mult)
    if not valid(actor) or is_template(actor) or not claim(actor) then return end
    if kind == "AnimalSpawnPoint" and fname(actor):find("Bear") then
        mult = CFG.bearTriggerMultiplier
        kind = "BearSpawnPoint"
    end
    local comp = try(function() return actor.PlayerDetection end)
    local what = scale_volume(comp, mult)
    if what and not volume_logged[kind] then
        volume_logged[kind] = true
        log(string.format("%s %s: %s", kind, fname(actor), what))
    end
end

------------------------------------------------------------------ 3. encounter cleanup distance
local subsystem_done = false
local function process_subsystem()
    if subsystem_done then return end
    for _, sub in ipairs(FindAllOf("RandomEncountersSubsystem") or {}) do
        if not is_template(sub) and claim(sub) then
            local d = try(function() return sub.MaksimumDistance end)
            if type(d) == "number" and d > 0 then
                -- Must stay beyond the farthest spawn, or encounters vanish on arrival.
                local nd = math.max(d * math.max(1.0, CFG.spawnDistanceMultiplier), CFG.randomEncounterMaxMetres * 150)
                try(function() sub.MaksimumDistance = nd end)
                log(string.format("random encounter MaksimumDistance %.0f -> %.0f", d, nd))
                subsystem_done = true
            end
        end
    end
end

------------------------------------------------------------------ wiring
local SPAWNERS = {
    { "/Script/Permafrost.AnimalSpawnPoint", "AnimalSpawnPoint", "animalTriggerMultiplier" },
    { "/Script/Permafrost.ActorSpawnerBase", "ActorSpawnerBase", "encounterTriggerMultiplier" },
    { "/Script/Permafrost.StaticEncounterBase", "StaticEncounterBase", "encounterTriggerMultiplier" },
}

-- New-object callbacks only write down the path. They can run nested inside
-- one of our own scheduled callbacks (a game call we make spawns objects),
-- and scheduling more work from there corrupted UE4SS's queue (crashes in
-- UE4SS, render, Niagara and save code, 2026-10-17). A loop does the work.
local volume_pending = {}   -- { path, spawner entry, due }
for _, s in ipairs(SPAWNERS) do
    -- At BeginPlay on the game thread, never NotifyOnNewObject (see main.lua).
    local ok = REBALANCE_ON_ACTOR(s[1], function(obj)
        release(obj)
        if is_template(obj) then return end
        -- 1 s later, so the volume has its authored size.
        volume_pending[#volume_pending + 1] = { path_of(obj), s, os.clock() + 1.0 }
    end)
    log((ok and "watching " or "FAILED to watch ") .. s[1])
end

------------------------------------------------------------------ 4. (removed)
-- The spawn guard and the respawn cooldowns destroyed spawners, their NPCs
-- and spawned animals. Those actors are registered with the game's save
-- system, and the next autosave crashed serializing them (2026-10-17,
-- UGameInstance_SaveFileSystem::PerformWorldSave). Never destroy spawners
-- or what they spawned.

------------------------------------------------------------------ 5. spawner spread and pacing
-- Map AI spawners (native ASpawner_BaseType, BP_Spawner_*) place their group
-- inside a HalfSpawnerGridSize square with SpaceBetweenSpawnPoints spacing,
-- and create one NPC every SpawnInterval seconds. The Blueprint defaults
-- (CDOs) are changed before the world loads, so every spawner that keeps the
-- default uses the new values; live spawners are changed as they appear.
local SPAWNER_BPS = {
    "/Game/Permafrost/Blueprints/AI/AISpace/Spawners/BP_Spawner_PointsV2",
    "/Game/Permafrost/Blueprints/AI/AISpace/Spawners/BP_Spawner_Points",
    "/Game/Permafrost/Blueprints/AI/AISpace/Spawners/BP_Spawner_SinglePoint",
    "/Game/Permafrost/Blueprints/AI/AISpace/Spawners/BP_Spawner_Splines",
}
local spread_done = {}
local widened = {}
local live_logged = 0  -- "Field=value" results already produced
local spread_pending = {}  -- paths of new spawners
local function spread_spawner(sp, label)
    if not valid(sp) then return end
    local key = try(function() return sp:GetFullName() end) or tostring(sp)
    if spread_done[key] then return end
    spread_done[key] = true
    local parts = {}
    local iv = try(function() return sp.SpawnInterval end)
    if type(iv) == "number" and CFG.spawnerIntervalSeconds > 0 and iv < CFG.spawnerIntervalSeconds then
        try(function() sp.SpawnInterval = CFG.spawnerIntervalSeconds end)
        parts[#parts + 1] = string.format("interval %.2f->%.2f s", iv, CFG.spawnerIntervalSeconds)
    end
    if CFG.spawnerSpreadMultiplier ~= 1 then
        for _, f in ipairs({ "HalfSpawnerGridSize", "SpaceBetweenSpawnPoints" }) do
            local v = try(function() return sp[f] end)
            -- Instances that kept the default already carry the widened value.
            if type(v) == "number" and v > 0 and not widened[f .. "=" .. v] then
                widened[f .. "=" .. (v * CFG.spawnerSpreadMultiplier)] = true
                try(function() sp[f] = v * CFG.spawnerSpreadMultiplier end)
                parts[#parts + 1] = string.format("%s %.0f->%.0f", f, v, v * CFG.spawnerSpreadMultiplier)
            end
        end
    end
    if label and #parts > 0 then log(label .. ": " .. table.concat(parts, ", ")) end
end

local defaults_done = {}
local function spread_defaults()
    for _, path in ipairs(SPAWNER_BPS) do
        if defaults_done[path] then goto continue end
        local name = path:match("([^/]+)$")
        local cls = try(function() return StaticFindObject(path .. "." .. name .. "_C") end)
        if not valid(cls) then
            try(function() LoadAsset(path) end)
            cls = try(function() return StaticFindObject(path .. "." .. name .. "_C") end)
        end
        local cdo = valid(cls) and try(function() return cls:GetCDO() end)
        if valid(cdo) then
            defaults_done[path] = true
            spread_spawner(cdo, "spawner defaults " .. name)
        end
        ::continue::
    end
end
pcall(spread_defaults)
-- PointsV2 was not loadable at startup (2026-10-17); retry as the map loads.
local default_tries = 0
game_loop(10000, function()
    -- Gives up after 6 tries: each retry runs StaticFindObject (a full object
    -- walk) and LoadAsset.
    default_tries = default_tries + 1
    if default_tries > 6 then return end
    local left = 0
    for _, p in ipairs(SPAWNER_BPS) do if not defaults_done[p] then left = left + 1 end end
    if left > 0 then pcall(spread_defaults) end
end)
local block_candidates = {}   -- spawner paths for the blocker's calibration (section 6)
REBALANCE_ON_ACTOR("/Script/Permafrost.Spawner_BaseType", function(obj)
    local p = path_of(obj)
    spread_pending[#spread_pending + 1] = p
    if #block_candidates < 20 then block_candidates[#block_candidates + 1] = p end
end)

-- Every 100 ms: new spawners get their spread, new volumes their size.
game_loop(100, function()
    if #spread_pending > 0 then
        local list = spread_pending
        spread_pending = {}
        for _, path in ipairs(list) do
            local o = resolve(path)
            if o then
                live_logged = live_logged + 1
                pcall(spread_spawner, o, live_logged <= 5 and "live spawner" or nil)
            end
        end
    end
    if #volume_pending > 0 then
        local now, keep = os.clock(), {}
        local list = volume_pending
        volume_pending = {}
        for _, v in ipairs(list) do
            if now < v[3] then
                keep[#keep + 1] = v
            else
                local o = resolve(v[1])
                if o then pcall(process_spawner, o, v[2][2], CFG[v[2][3]]) end
            end
        end
        for _, v in ipairs(volume_pending) do keep[#keep + 1] = v end
        volume_pending = keep
    end
end)

local queries_left = {}
for _, q in ipairs(SPAWN_QUERIES) do queries_left[#queries_left + 1] = q end

-- Every 5 s: queries not yet loaded, the encounter subsystem, and any
-- spawner that existed before the watch started.
local first = true
game_loop(5000, function()
    local ok, err = pcall(function()
        local still = {}
        for _, q in ipairs(queries_left) do
            if not process_query(q) then still[#still + 1] = q end
        end
        queries_left = still
        process_subsystem()
        if first then
            first = false
            for _, s in ipairs(SPAWNERS) do
                for _, a in ipairs(FindAllOf(s[2]) or {}) do process_spawner(a, s[2], CFG[s[3]]) end
            end
        end
    end)
    if not ok then log("error: " .. tostring(err)) end
end)

------------------------------------------------------------------ 6. spawn blocker
-- dlls\main.dll hooks ASpawner_BaseType::CheckIfSpawnProcessIsValid, the
-- check every new spawner spawn goes through, and refuses it while the
-- player is within blockSpawnMetres of that spawner. NPCs restored from the
-- save take another path and are untouched. This feeds the DLL:
--   block=<cm>, player=<x>,<y>,<z>
--   cal=<spawner addr>,<its RootComponent addr>,<x>,<y>,<z>
-- The calibration sample lets the DLL find where actors keep their root
-- component and location, so no game offsets are hardcoded.
local BLOCK_FILE = (mod_root() or "") .. "dlls\\spawnblock.txt"
local block_helpers = nil
local cal_line = nil
local last_block_text = nil
local function calibration()
    if cal_line then return cal_line end
    for _, p in ipairs(block_candidates) do
        local sp = resolve(p)
        if valid(sp) then
            local root = try(function() return sp.RootComponent end)
            local a, r = address(sp), address(root)
            local loc = try(function() return sp:K2_GetActorLocation() end)
            if a and r and loc then
                cal_line = string.format("cal=%X,%X,%.17g,%.17g,%.17g", a, r, loc.X, loc.Y, loc.Z)
                return cal_line
            end
        end
    end
    return nil
end
local function write_block()
    local cm = math.floor((tonumber(CFG.blockSpawnMetres) or 0) * 100)
    local lines = { string.format("block=%d", cm) }
    block_helpers = block_helpers or try(function() return require("UEHelpers") end)
    local pc = block_helpers and try(function() return block_helpers.GetPlayerController() end)
    local pawn = valid(pc) and try(function() return pc.Pawn end)
    local loc = valid(pawn) and try(function() return pawn:K2_GetActorLocation() end)
    if loc then
        -- 50 cm steps: the file only changes when the player really moves.
        lines[#lines + 1] = string.format("player=%d,%d,%d",
            math.floor(loc.X / 50) * 50, math.floor(loc.Y / 50) * 50, math.floor(loc.Z / 50) * 50)
    end
    local cal = calibration()
    if cal then lines[#lines + 1] = cal end
    local text = table.concat(lines, "\n") .. "\nend\n"
    if text == last_block_text then return end
    last_block_text = text
    local f = io.open(BLOCK_FILE .. ".tmp", "wb")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(BLOCK_FILE)
    os.rename(BLOCK_FILE .. ".tmp", BLOCK_FILE)
end
game_loop(500, function()
    local ok, err = pcall(write_block)
    if not ok then log("spawn blocker error: " .. tostring(err)) end
end)
log(string.format("spawn blocker: spawners stay quiet within %d m of you (native side logs to dlls\\CraftFromStorage.log)",
    math.floor(tonumber(CFG.blockSpawnMetres) or 0)))

log("loaded")
