-- EternalTorches module of the Rebalance mod (was its own mod until 2026-10-17).
-- Settings: Rebalance\config\EternalTorches.lua
-- EternalTorches: placed torches never run out of fuel.
-- Torches (BP_WallTorch, BP_StandingTorch, BP_StandingWoodenTorch, ...) burn
-- fuel through a UFueledStationComponent. Two levers:
--  1. FuelBurnSpeedMultiplier = 0 on torch fuel stations.
--  2. Safety net: every 2 s, any burning slot (FuelData[].RemainingTime > 0)
--     that has dropped below half of SingleItemBurnTime is set back to a full
--     item, so fuel is never used up even if the multiplier is ignored.
-- A torch still needs fuel once to be lit; it just never consumes it.
local TAG = "[PF EternalTorches] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

-- Game-thread scheduling (LoopAsync + ExecuteInGameThread crashed UE4SS).
local LIB = REBALANCE_LIB  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, path_of, resolve, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.path_of, LIB.resolve, LIB.game_loop


------------------------------------------------------------------ config
local DEFAULTS = {
    { "enabled",         1, "1 = torches never use up fuel" },
    { "includeBraziers", 0, "1 = braziers too" },
    { "includeAllFires", 0, "1 = every fuel station (campfires, stoves, furnaces...)" },
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
    if type(root) == "string" then return root .. "\\ue4ss\\Mods\\EternalTorches\\" end
    return nil
end

local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local root = mod_root()
    if not root then return cfg end
    local path = root .. "config\\EternalTorches.lua"
    local f = io.open(path, "r")
    if not f then
        f = io.open(path, "w")
        if f then
            f:write("-- EternalTorches settings. Restart the game to apply.\n")
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
if CFG.enabled ~= 1 then
    log("disabled")
    return
end

------------------------------------------------------------------ torches
local function wanted(owner_class)
    if CFG.includeAllFires == 1 then return true end
    local n = owner_class:lower()
    if n:find("torch", 1, true) then return true end
    if CFG.includeBraziers == 1 and n:find("brazier", 1, true) then return true end
    return false
end

-- Objects are kept by path and looked up when needed: holding a Lua
-- reference to an object the game later frees crashed the game (2026-10-17).

local stations = {}      -- path -> true (torch fuel stations already set to burn 0)
local pending = {}       -- new fuel stations, checked on the next pass
local logged_values = 0
local refills = 0
local function consider(comp, n)
    if stations[n] then return end
    local owner = try(function() return comp:GetOwner() end)
    local cls = valid(owner) and fname(owner:GetClass()) or ""
    if cls == "" or not wanted(cls) then return end
    stations[n] = true
    local old = try(function() return comp.FuelBurnSpeedMultiplier end)
    try(function() comp.FuelBurnSpeedMultiplier = 0.0 end)
    if logged_values < 3 then
        logged_values = logged_values + 1
        log(string.format("%s: FuelBurnSpeedMultiplier %s -> 0", cls, tostring(old)))
    end
end

-- New torch actors, at BeginPlay on the game thread (never NotifyOnNewObject,
-- see main.lua). The class filter runs once per actor class.
local FUEL_CLASS = try(function() return StaticFindObject("/Script/Permafrost.FueledStationComponent") end)
REBALANCE_ON_ACTOR("/Script/Engine.Actor", function(actor)
    if not valid(FUEL_CLASS) then return end
    local comp = try(function() return actor:GetComponentByClass(FUEL_CLASS) end)
    if valid(comp) then pending[#pending + 1] = path_of(comp) end
end, wanted)

local first_scan = true
local function scan()
    if first_scan then
        -- Once, for stations that existed before the mod started watching.
        first_scan = false
        for _, comp in ipairs(FindAllOf("FueledStationComponent") or {}) do
            local n = path_of(comp)
            if not n:find("Default__") then consider(comp, n) end
        end
    end
    local queue = pending
    pending = {}
    for _, n in ipairs(queue) do
        local comp = resolve(n)
        if comp then consider(comp, n) end
    end
end

local function top_up()
    for n in pairs(stations) do
        local comp = resolve(n)
        if not comp then
            stations[n] = nil
        else
            try(function()
                comp.FuelData:ForEach(function(_, elem)
                    local slot = elem:get()
                    local remaining = try(function() return slot.RemainingTime end)
                    local single = try(function() return slot.SingleItemBurnTime end)
                    if type(remaining) == "number" and type(single) == "number" and single > 0
                        and remaining > 0 and remaining < single * 0.5 then
                        slot.RemainingTime = single
                        refills = refills + 1
                        if refills <= 3 then
                            log(string.format("refilled a burning slot: %.0f -> %.0f s", remaining, single))
                        end
                    end
                end)
            end)
        end
    end
end

local ticks = 0
game_loop(2000, function()
    local ok, err = pcall(function()
        scan()                              -- cheap: only newly created stations
        ticks = ticks + 1
        top_up()
    end)
    if not ok then log("error: " .. tostring(err)) end
end)

log("loaded")
