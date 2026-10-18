-- BedTravel module of the Overhaul (2026-10-18). User: fast travel on the
-- map to home bases, anywhere you have a bed. (Dropped once for the
-- buildable travel lamp, brought back the same day: beds for home, the
-- lamp for caves and the like.) User wants:
--  * a key while looking at a bed opens fast travel there, with a prompt
--    line like the bed's own "Press F Rest";
--  * bed trips do not autosave;
--  * bed trips cost food like any trip (they do: the cost is taken in
--    main.dll's TravelTo detour, which every map trip goes through).
-- How:
--  * Beds become travel points: each BP_PermaBed gets a runtime
--    UFastTravelComponent with the game's Home name asset (PDA_FT_Home),
--    then ActivateFastTravelComponent registers it. Runtime components are
--    not saved, so this runs every session. First run (2026-10-18): the
--    component was added but the name asset did not stick and the manager
--    listed 0 points, so this version logs the component's and the
--    manager's properties to fix that.
--  * The key (travelKey, default T) while a bed is within 3 m in front of
--    you opens the fast travel map through the game's own
--    UI_ManagerComponent:CLIENT_OpenFastTravelMap (what the travel lamp
--    uses).
--  * Discovery for the next steps: every autosave is logged (and whether a
--    bed trip is under way), and the interaction prompt's widget layout is
--    logged once while you look at a bed.
-- Settings: BedTravel section of config.lua. Log tag [PF BedTravel].
local TAG = "[PF BedTravel] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

local DEFAULTS = {
    { "sleepingBags", 0, "1 = sleeping bags count as beds too" },
    { "travelKey", "T", "key that opens fast travel while you look at a bed" },
    { "reachMetres", 3, "how close the bed must be" },
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
            local v = user[d[1]]
            if type(d[2]) == "number" then v = tonumber(v) end
            if v ~= nil and type(v) == type(d[2]) then cfg[d[1]] = v end
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
    if logged < 40 then logged = logged + 1 log(msg) end
end

local function bed_classes()
    local list = { "BP_PermaBed_C" }
    if CFG.sleepingBags == 1 then list[#list + 1] = "BP_SleepingBag_C" end
    return list
end

-- Every property (with its value) and function of a class, 4 levels.
local function describe(label, obj)
    local props, funcs = {}, {}
    local c = call(obj, "GetClass")
    for _ = 1, 4 do
        if not valid(c) then break end
        local cn = fname(c) or "?"
        if cn == "ActorComponent" or cn == "Actor" or cn == "Object" then break end
        try(function()
            c:ForEachProperty(function(prop)
                local n = try(function() return prop:GetFName():ToString() end) or "?"
                local v = get(obj, n)
                local shown
                if type(v) == "number" or type(v) == "boolean" then shown = tostring(v)
                elseif v ~= nil and valid(v) then shown = fname(v)
                elseif v == nil then shown = "nil"
                else shown = try(function() return v:ToString() end) or "(other)" end
                props[#props + 1] = n .. "=" .. tostring(shown)
            end)
        end)
        try(function()
            c:ForEachFunction(function(fn)
                funcs[#funcs + 1] = try(function() return fn:GetFName():ToString() end) or "?"
            end)
        end)
        c = try(function() return c:GetSuperStruct() end)
    end
    log(label .. " properties: " .. table.concat(props, ", "))
    log(label .. " functions: " .. table.concat(funcs, ", "))
end

------------------------------------------------------------------ travel points
local comp_described = false
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
    -- The name asset: any object property of the component that takes a
    -- PDA (the first run's guess "PDA_FastTravel" did not stick).
    local set_on = nil
    if valid(home_pda) then
        local c = call(comp, "GetClass")
        for _ = 1, 3 do
            if not valid(c) or set_on then break end
            try(function()
                c:ForEachProperty(function(prop)
                    if set_on then return end
                    local n = try(function() return prop:GetFName():ToString() end) or ""
                    local l = n:lower()
                    if (l:find("pda") or l:find("data") or l:find("name")) and get(comp, n) == nil then
                        LIB.set(comp, n, home_pda)
                        if valid(get(comp, n)) then set_on = n end
                    end
                end)
            end)
            c = try(function() return c:GetSuperStruct() end)
        end
    end
    call(comp, "ActivateFastTravelComponent")
    note(string.format("%s: fast travel component %s, name asset set on %s", fname(bed),
        existed and "already there" or "added", tostring(set_on)))
    if not comp_described then
        comp_described = true
        describe("fast travel component", comp)
    end
end

local manager_described = false
local function points_pass()
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
    if not manager_described then
        for _, m in ipairs(try(function() return FindAllOf("Manager_FastTravel") end) or {}) do
            if valid(m) and not fname(m):find("^Default__") then
                manager_described = true
                describe("fast travel manager", m)
                break
            end
        end
    end
end

------------------------------------------------------------------ the bed you look at
local helpers = nil
local function player()
    helpers = helpers or try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    if not valid(pawn) then return nil end
    return pc, pawn
end

-- The nearest bed within reachMetres that is in front of your view.
local function bed_in_view(pc, pawn)
    local p = call(pawn, "K2_GetActorLocation")
    local r = call(pc, "GetControlRotation")
    if not (p and r) then return nil end
    local yaw, pitch = math.rad(r.Yaw or 0), math.rad(r.Pitch or 0)
    local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
    local reach = (tonumber(CFG.reachMetres) or 3) * 100
    local best, best_d = nil, nil
    for _, cls in ipairs(bed_classes()) do
        for _, bed in ipairs(try(function() return FindAllOf(cls) end) or {}) do
            if valid(bed) and not fname(bed):find("^Default__") then
                local b = call(bed, "K2_GetActorLocation")
                if b then
                    local dx, dy, dz = b.X - p.X, b.Y - p.Y, b.Z - p.Z
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d <= reach and d > 1 then
                        local dot = (dx * fx + dy * fy + dz * fz) / d
                        if dot > 0.5 and (not best_d or d < best_d) then best, best_d = bed, d end
                    end
                end
            end
        end
    end
    return best
end

------------------------------------------------------------------ open the map
-- CLIENT_OpenFastTravelMap(MarkerID: FName) needs the map marker of the
-- travel point you are at: with an empty name nothing opened (2026-10-18).
-- The beds are not registered points yet, so the marker the travel lamp
-- uses is learned: a hook logs every map opening and keeps its MarkerID
-- (dlls\bed_marker.txt, so it survives restarts). Beds then open the map
-- with that marker; the trip itself goes wherever you pick.
local MARKER_FILE = ROOT .. "dlls\\bed_marker.txt"
local known_marker = nil
do
    local f = io.open(MARKER_FILE, "r")
    if f then
        local t = f:read("*l")
        f:close()
        if t and t ~= "" and t ~= "None" then known_marker = t end
    end
end
local own_call = false
local open_hooked = try(function()
    RegisterHook("/Script/Permafrost.UI_ManagerComponent:CLIENT_OpenFastTravelMap", function(_, marker)
        local m = try(function() return marker:get():ToString() end) or "?"
        log(string.format("fast travel map opened by %s with marker '%s'", own_call and "a bed" or "the game", m))
        if not own_call and m ~= "" and m ~= "None" and m ~= "?" and m ~= known_marker then
            known_marker = m
            local f = io.open(MARKER_FILE, "w")
            if f then f:write(m .. "\n") f:close() end
            log("remembered travel marker '" .. m .. "' for beds")
        end
    end)
    return true
end)

local bed_trip_until = 0
local warned_no_marker = false
local fn_params = {}
-- Parameters of a UFunction as { name, property class } (logged once).
local function params_of(path)
    if fn_params[path] then return fn_params[path] end
    local list = {}
    local fn = try(function() return StaticFindObject(path) end)
    if valid(fn) then
        try(function()
            fn:ForEachProperty(function(prop)
                list[#list + 1] = { try(function() return prop:GetFName():ToString() end) or "?",
                                    try(function() return prop:GetClass():GetFName():ToString() end) or "?" }
            end)
        end)
    end
    local shown = {}
    for _, e in ipairs(list) do shown[#shown + 1] = e[1] .. ":" .. e[2] end
    log(path:match("[^.:]+$") .. " takes: " .. (#shown > 0 and table.concat(shown, ", ") or "nothing readable"))
    fn_params[path] = list
    return list
end

-- No lamp marker known: the bed's own travel component is asked to start
-- a trip (TravelRequest, what a travel point does when used), with the
-- player controller or pawn for object parameters.
local world_map_described = false
local function request_from_component(pc, pawn, bed)
    ft_class = ft_class or try(function() return StaticFindObject("/Script/Permafrost.FastTravelComponent") end)
    local comp = valid(ft_class) and call(bed, "GetComponentByClass", ft_class)
    if not valid(comp) then log("bed has no travel component (yet)") return end
    local args = {}
    for _, e in ipairs(params_of("/Script/Permafrost.FastTravelComponent:TravelRequest")) do
        if e[1] ~= "ReturnValue" then
            if e[2] == "ObjectProperty" then
                args[#args + 1] = e[1]:lower():find("controller") and pc or pawn
            elseif e[2] == "BoolProperty" then args[#args + 1] = true
            elseif e[2] == "NameProperty" then args[#args + 1] = FName("None")
            else args[#args + 1] = 0 end
        end
    end
    local ok, err = pcall(function() comp:TravelRequest(table.unpack(args)) end)
    log(string.format("asked %s's travel component for a trip (%d args): %s", fname(bed), #args, ok and "ok" or tostring(err)))
    if not world_map_described then
        world_map_described = true
        for _, m in ipairs(try(function() return FindAllOf("WorldMapManager") end) or {}) do
            if valid(m) and not fname(m):find("^Default__") then describe("world map manager", m) break end
        end
    end
end

local function open_map(pc, bed, pawn)
    if not known_marker then
        if not warned_no_marker then
            warned_no_marker = true
            log("no travel marker known yet (open fast travel once from a travel lamp); trying the bed's own component")
        end
        request_from_component(pc, pawn, bed)
        return
    end
    local uim_class = try(function() return StaticFindObject("/Script/Permafrost.UI_ManagerComponent") end)
    local uim = valid(uim_class) and call(pc, "GetComponentByClass", uim_class)
    if not valid(uim) then log("UI manager not found on the player controller") return end
    own_call = true
    local ok = try(function() uim:CLIENT_OpenFastTravelMap(FName(known_marker)) return true end)
    own_call = false
    bed_trip_until = os.clock() + 180
    log(string.format("fast travel map from %s (marker '%s'): %s", fname(bed), known_marker, ok and "called" or "call failed"))
end

------------------------------------------------------------------ prompt layout (discovery)
-- The "Press F Rest" lines are BP_InteractionHint rows in the HUD's
-- UW_HintsList (HintList, a VerticalBox), 2026-10-18 HUD dump. Logged once
-- while you look at a bed: the list's layout with its texts, and one row's
-- properties and functions, to add a "Press T Fast travel" row next.
local prompt_logged = false
local function log_prompt(bed)
    if prompt_logged then return end
    local list = nil
    for _, x in ipairs(try(function() return FindAllOf("UW_HintsList_C") end) or {}) do
        if valid(x) and not fname(x):find("^Default__") then list = x break end
    end
    if not valid(list) then return end
    local lines, row = {}, nil
    local function walk(x, depth, route)
        if depth > 14 or #lines > 120 then return end
        local cn = fname(call(x, "GetClass")) or "?"
        local t = ""
        if cn == "TextBlock" or cn:find("RichText") then
            t = " '" .. tostring(try(function() return x:GetText():ToString() end)) .. "'"
        end
        if cn == "BP_InteractionHint_C" and not row then row = x end
        lines[#lines + 1] = string.rep(" ", depth) .. route .. " " .. fname(x) .. ":" .. cn .. t
        local tree = get(x, "WidgetTree")
        local root = valid(tree) and get(tree, "RootWidget")
        if valid(root) then walk(root, depth + 1, route .. ".0") end
        local n = tonumber(call(x, "GetChildrenCount")) or 0
        for i = 0, n - 1 do
            local c = call(x, "GetChildAt", i)
            if valid(c) then walk(c, depth + 1, route .. "." .. (i + 1)) end
        end
    end
    walk(list, 0, "r")
    -- Only once the list shows the bed's lines (a row with text).
    local has_text = false
    for _, l in ipairs(lines) do if l:find("'[^']+'") and not l:find("''") then has_text = true break end end
    if not has_text then return end
    prompt_logged = true
    log("hint list while looking at " .. fname(bed) .. ":\n" .. table.concat(lines, "\n"))
    if row then describe("hint row", row) end
end

------------------------------------------------------------------ autosave (discovery)
local save_hooked = try(function()
    RegisterHook("/Script/Permafrost.PermaGameMode:AutoSaveFunction", function()
        log(string.format("autosave fired%s", os.clock() < bed_trip_until and " during a bed trip" or ""))
    end)
    return true
end)

------------------------------------------------------------------ loops
local key = Key[CFG.travelKey] or Key.T
RegisterKeyBind(key, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc, pawn = player()
            if not pc or get(pc, "bShowMouseCursor") == true then return end   -- not while a menu is open
            local bed = bed_in_view(pc, pawn)
            if bed then open_map(pc, bed, pawn) end
        end)
        if not ok then log("key error: " .. tostring(err)) end
    end)
end)

local settle = os.clock() + 20
local next_points = 0
game_loop(500, function()
    if os.clock() < settle then return end
    local ok, err = pcall(function()
        local pc, pawn = player()
        if not pc then return end
        if os.clock() >= next_points then
            next_points = os.clock() + 10
            points_pass()
        end
        if not prompt_logged then
            local bed = bed_in_view(pc, pawn)
            if bed then log_prompt(bed) end
        end
    end)
    if not ok then note("error: " .. tostring(err)) end
end)

log(string.format("loaded: look at a bed and press %s for fast travel (autosave log %s, map hook %s, marker %s)", CFG.travelKey,
    save_hooked and "on" or "off", open_hooked and "on" or "off", tostring(known_marker)))
