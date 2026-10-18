-- Patrols module of the Overhaul (2026-10-18). User: make the world feel
-- more alive. When no hostile human is within emptyRadiusMetres of the
-- player, a small patrol squad is sent in; it vanishes once it is
-- despawnMetres away; a cooldown keeps squads from chaining.
--
-- Everything runs through the game's own random encounter system, so the
-- squad is placed, registered and later removed by vanilla code (raw
-- destroys of spawned NPCs crashed the autosave on 2026-10-17):
--  * Spawn: URandomEncountersSubsystem::Server_TryToInvokeEncounter picks a
--    weighted entry from the current location's RandomEncounterConstraints.
--    For that one call every entry of every location points at the chosen
--    patrol config (RandomEncounters_*Patrol*), then the entries are put
--    back. Gates kept from vanilla: encounters enabled, location allows
--    random encounters, active encounter actors below AllowedSpawnedActor.
--  * Despawn: ClearInvalidAndDistanceActors destroys encounter actors
--    farther than MaksimumDistance from every player (exe 0x55CD290). It is
--    set to despawnMetres and called once our squad is past it. This also
--    applies to the game's own random encounters.
-- Settings: Patrols section of config.lua. Log tag [PF Patrols].
local TAG = "[PF Patrols] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, set, call = LIB.get, LIB.set, LIB.call
local ROOT = REBALANCE_ROOT or ""

------------------------------------------------------------------ config
local DEFAULTS = {
    { "enabled",            1,   "1 = on" },
    { "emptyRadiusMetres",  300, "a squad comes only when no hostile human is this close" },
    { "despawnMetres",      400, "a squad this far away disappears" },
    { "cooldownMinutes",    10,  "minimum time between squads" },
    { "firstDelayMinutes",  3,   "no squad in the first minutes after loading" },
    { "includeResistance",  0,   "1 = Resistance patrols can come too" },
    { "debugLog",           1,   "1 = log checks and squads" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Patrols.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Patrols.lua", "t", {})
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

local HUMANOID = "/Game/Permafrost/Blueprints/RandomEncounters/Data/Humanoid/"
local PATROLS = {
    "RandomEncounters_MoonCultPatrol1Firearm_Day", "RandomEncounters_MoonCultPatrol1Firearm_Night",
    "RandomEncounters_MoonCultPatrol1Bow_Day", "RandomEncounters_MoonCultPatrol1Bow_Night",
    "RandomEncounters_MoonCultPatrol2Bow_Day",
    "RandomEncounters_MoonCultPatrol3Firearm", "RandomEncounters_MoonCultPatrol3Firearm_Night",
    "RandomEncounters_CombatantPatrol",
}
if CFG.includeResistance == 1 then PATROLS[#PATROLS + 1] = "RandomEncounters_ResistancePatrol" end

local HOSTILE = { "RifleMan", "MoonCult", "Combatant", "Militant", "Cultist", "Bandit", "Hostile" }
local function is_hostile(cls)
    for _, h in ipairs(HOSTILE) do
        if cls:find(h, 1, true) then return true end
    end
    return false
end

local debug_left = 60
local function dbg(msg)
    if CFG.debugLog == 1 and debug_left > 0 then
        debug_left = debug_left - 1
        log(msg)
    end
end

------------------------------------------------------------------ helpers
local helpers_mod = nil
-- Player position as plain numbers (never keep a returned struct).
local function player_xyz()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local pc = helpers_mod and try(function() return helpers_mod.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    local p = valid(pawn) and call(pawn, "K2_GetActorLocation")
    if not p then return nil end
    return p.X, p.Y, p.Z
end

local function dist2(o, px, py, pz)
    local l = call(o, "K2_GetActorLocation")
    if not l then return nil end
    return (l.X - px) ^ 2 + (l.Y - py) ^ 2 + (l.Z - pz) ^ 2
end

local sub_path = nil
local function subsystem()
    local sub = sub_path and LIB.resolve(sub_path)
    if sub then return sub end
    for _, s in ipairs(try(function() return FindAllOf("RandomEncountersSubsystem") end) or {}) do
        if valid(s) and not fname(s):find("^Default__") then
            sub_path = LIB.path_of(s)
            return s
        end
    end
    return nil
end

local function active_actors(sub)
    local list = {}
    try(function()
        sub.ListOfActiveEncountersActors:ForEach(function(_, e)
            local a = try(function() return e:get() end)
            if valid(a) then list[#list + 1] = a end
        end)
    end)
    return list
end

local ANIMAL = try(function() return StaticFindObject("/Script/Permafrost.PermaAnimalBase") end)
-- Nearest living hostile human, in metres (nil = none loaded).
local function nearest_hostile(px, py, pz)
    local best = nil
    for _, npc in ipairs(try(function() return FindAllOf("BaseAICharacter") end) or {}) do
        if valid(npc) and not (valid(ANIMAL) and call(npc, "IsA", ANIMAL) == true) and get(npc, "bIsDead") ~= true then
            local cls = fname(call(npc, "GetClass"))
            if is_hostile(cls) then
                local d = dist2(npc, px, py, pz)
                if d and (not best or d < best) then best = d end
            end
        end
    end
    return best and math.sqrt(best) / 100 or nil
end

------------------------------------------------------------------ squad state
local squad = {}              -- paths of our squad's actors
local squad_pending = nil     -- { t, before = { address = true } } while the placement query runs
local next_allowed = os.clock() + CFG.firstDelayMinutes * 60

local function load_patrol(name)
    local path = HUMANOID .. name .. "." .. name
    local cfg = try(function() return StaticFindObject(path) end)
    if not valid(cfg) then cfg = try(function() return LoadAsset(path) end) end
    return valid(cfg) and cfg or nil
end

-- Every entry of every location points at cfg (weight 1); returns the undo list.
local function redirect_all(cfg)
    local undo = {}
    for _, loc in ipairs(try(function() return FindAllOf("Data_WorldLocationInstance") end) or {}) do
        if valid(loc) and not fname(loc):find("^Default__") then
            local c = get(loc, "RandomEncounterConstraints")
            local arr = c and get(c, "WeightedRandomEncounters")
            if arr then
                try(function()
                    arr:ForEach(function(_, e)
                        local s = e:get()
                        undo[#undo + 1] = { s = s, enc = s.Encounter, w = s.SpawnWeight }
                        s.Encounter = cfg
                        s.SpawnWeight = 1
                    end)
                end)
            end
        end
    end
    return undo
end

local function restore(undo)
    for _, u in ipairs(undo) do
        try(function()
            u.s.Encounter = u.enc
            u.s.SpawnWeight = u.w
        end)
    end
end

local function try_spawn(sub)
    if get(sub, "EncountersEnabled") == false then dbg("skip: encounters disabled") return false end
    local before = {}
    for _, a in ipairs(active_actors(sub)) do before[LIB.address(a) or 0] = true end
    -- Shuffled; a patrol the game refuses (wrong time of day, location rules) is skipped.
    local order = {}
    for i, n in ipairs(PATROLS) do order[i] = n end
    for i = #order, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end
    for k = 1, math.min(3, #order) do
        local name = order[k]
        local cfg = load_patrol(name)
        if cfg then
            local want = LIB.address(cfg)
            local undo = redirect_all(cfg)
            if #undo == 0 then dbg("skip: no location has encounter entries") return false end
            set(sub, "CurrentEncounter", nil)
            local ok, err = pcall(function() sub:Server_TryToInvokeEncounter() end)
            restore(undo)
            local got = get(sub, "CurrentEncounter")
            if not ok then
                log("invoke error: " .. tostring(err))
                return false
            end
            if valid(got) and LIB.address(got) == want then
                log(string.format("squad sent: %s (%d encounter entries redirected for the call)", name, #undo))
                squad_pending = { t = os.clock(), before = before, name = name }
                return true
            end
            dbg("game refused " .. name .. (valid(got) and (" (picked " .. fname(got) .. ")") or ""))
        else
            dbg("patrol config not found: " .. name)
        end
    end
    return false
end

-- Placement is an async query: collect the squad's actors once they appear.
local function collect_squad(sub, px, py, pz)
    if not squad_pending then return end
    local found = {}
    for _, a in ipairs(active_actors(sub)) do
        local addr = LIB.address(a)
        if addr and not squad_pending.before[addr] then found[#found + 1] = a end
    end
    if #found > 0 then
        squad = {}
        local names = {}
        for _, a in ipairs(found) do
            squad[#squad + 1] = LIB.path_of(a)
            local d = dist2(a, px, py, pz)
            names[#names + 1] = string.format("%s %.0f m", fname(call(a, "GetClass")), d and math.sqrt(d) / 100 or -1)
        end
        log("squad spawned: " .. table.concat(names, ", "))
        squad_pending = nil
    elseif os.clock() - squad_pending.t > 30 then
        log("squad never appeared (placement found no spot?): " .. squad_pending.name)
        squad_pending = nil
        next_allowed = os.clock() + 60   -- try again soon instead of a full cooldown
    end
end

------------------------------------------------------------------ main loop
local CHECK_MS = 5000
local dist_logged = false
local function pass()
    local px, py, pz = player_xyz()
    if not px then return end
    local sub = subsystem()
    if not sub then return end

    local want = CFG.despawnMetres * 100
    local md = tonumber(get(sub, "MaksimumDistance"))
    if md and math.abs(md - want) > 1 then
        set(sub, "MaksimumDistance", want)
        if not dist_logged then
            dist_logged = true
            log(string.format("encounter despawn distance %.0f m -> %.0f m", md / 100, CFG.despawnMetres))
        end
    end

    collect_squad(sub, px, py, pz)

    -- Squad members still around? Past the despawn distance: let the game clear them.
    local alive, far = {}, false
    for _, path in ipairs(squad) do
        local a = LIB.resolve(path)
        if a and get(a, "bIsDead") ~= true then
            alive[#alive + 1] = path
            local d = dist2(a, px, py, pz)
            if d and d > want * want then far = true end
        end
    end
    squad = alive
    if far then
        try(function() sub:ClearInvalidAndDistanceActors() end)
        dbg("squad past " .. CFG.despawnMetres .. " m: cleared by the game")
    end

    if squad_pending or #squad > 0 or os.clock() < next_allowed then return end
    local near = nearest_hostile(px, py, pz)
    if near and near < CFG.emptyRadiusMetres then return end
    dbg(near and string.format("nearest hostile %.0f m: sending a squad", near) or "no hostile loaded: sending a squad")
    if try_spawn(sub) then
        next_allowed = os.clock() + CFG.cooldownMinutes * 60
    else
        next_allowed = os.clock() + 60
    end
end

game_loop(CHECK_MS, function()
    local ok, err = pcall(pass)
    if not ok then dbg("error: " .. tostring(err)) end
end)

log(string.format("loaded: squad when no hostile within %d m, gone at %d m, every %d+ min",
    CFG.emptyRadiusMetres, CFG.despawnMetres, CFG.cooldownMinutes))
