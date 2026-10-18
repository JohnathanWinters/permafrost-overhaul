-- BedTravel module of the Overhaul (2026-10-18). User: fast travel on the
-- map to home bases, anywhere you have a bed.
-- The game's fast travel points are actors with a UFastTravelComponent: it
-- holds the point's name asset (PDA_FastTravel), builds its own world-map
-- marker and handles the travel request, and ActivateFastTravelComponent
-- registers it with the fast travel manager. The game even ships a "Home"
-- name asset (PDA_FT_Home) and a buildable travel lamp
-- (BP_FastTravel_BuildPart). So every bed (BP_PermaBed) gets that component
-- with the Home name, added at runtime and activated; runtime components are
-- not saved, so this runs again each session. Experimental: every step is
-- logged (added, registered, unlocked) so the next fix can follow the log.
-- Settings: BedTravel section of config.lua. Log tag [PF BedTravel].
local TAG = "[PF BedTravel] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

local DEFAULTS = {
    { "sleepingBags", 0, "1 = sleeping bags count as beds too" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\BedTravel.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "BedTravel.lua", "t", {})
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

local HOME_PDA = "/Game/Permafrost/Blueprints/FastTravel/PDA/PDA_FT_Home.PDA_FT_Home"
local ft_class, home_pda = nil, nil
local done = {}            -- bed path -> true
local logged = 0
local function note(msg)
    if logged < 30 then logged = logged + 1 log(msg) end
end

local function bed_classes()
    local list = { "BP_PermaBed_C" }
    if CFG.sleepingBags == 1 then list[#list + 1] = "BP_SleepingBag_C" end
    return list
end

local function make_travel_point(bed)
    ft_class = ft_class or try(function() return StaticFindObject("/Script/Permafrost.FastTravelComponent") end)
    if not valid(ft_class) then note("FastTravelComponent class not found") return end
    if not valid(home_pda) then
        home_pda = try(function() return StaticFindObject(HOME_PDA) end)
        if not valid(home_pda) then home_pda = try(function() return LoadAsset(HOME_PDA) end) end
    end
    local comp = call(bed, "GetComponentByClass", ft_class)
    local existed = valid(comp)
    if not existed then
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        comp = call(bed, "AddComponentByClass", ft_class, false, xf, false)
    end
    if not valid(comp) then note("could not add a fast travel component to " .. fname(bed)) return end
    if valid(home_pda) and not valid(get(comp, "PDA_FastTravel")) then LIB.set(comp, "PDA_FastTravel", home_pda) end
    call(comp, "ActivateFastTravelComponent")
    note(string.format("%s: fast travel component %s, name asset %s, tags %s", fname(bed),
        existed and "already there" or "added", valid(get(comp, "PDA_FastTravel")) and fname(get(comp, "PDA_FastTravel")) or "none",
        tostring(try(function() return get(comp, "FTTags") and "set" end))))
end

local manager_logged = false
local function pass()
    local helpers = try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    if not (valid(pc) and valid(get(pc, "Pawn"))) then return end
    for _, cls in ipairs(bed_classes()) do
        for _, bed in ipairs(try(function() return FindAllOf(cls) end) or {}) do
            if valid(bed) and not fname(bed):find("^Default__") then
                local p = LIB.path_of(bed)
                if not done[p] then
                    done[p] = true
                    local ok, err = pcall(make_travel_point, bed)
                    if not ok then note("error on " .. fname(bed) .. ": " .. tostring(err)) end
                end
            end
        end
    end
    if not manager_logged then
        for _, m in ipairs(try(function() return FindAllOf("Manager_FastTravel") end) or {}) do
            if valid(m) and not fname(m):find("^Default__") then
                local n = 0
                try(function() m.FastTravelPoints:ForEach(function() n = n + 1 end) end)
                note(string.format("fast travel manager lists %d points", n))
                manager_logged = true
            end
        end
    end
end

local settle = os.clock() + 20
game_loop(10000, function()
    if os.clock() < settle then return end
    local ok, err = pcall(pass)
    if not ok then note("error: " .. tostring(err)) end
end)

log("loaded (experimental: beds become fast travel points named Home)")
