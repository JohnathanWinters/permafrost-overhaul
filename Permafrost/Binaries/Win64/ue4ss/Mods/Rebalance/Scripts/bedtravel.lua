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
--  * Each bed gets a runtime UFastTravelComponent, activated (runtime
--    components are not saved, so this runs every session).
--  * The key (travelKey, default T) while a bed is within reach in front of
--    you asks that component for a trip (TravelRequest): the game opens the
--    fast travel map for the bed (worked 2026-10-18).
--  * While the interaction prompt's title names a bed, a "Press T  Fast
--    travel" line is added to its hint list.
--  * Every autosave is logged (and whether a bed trip is under way).
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
-- The bed's own travel component is asked for a trip (TravelRequest with
-- the player controller): the game then opens the fast travel map for
-- that bed, and the trip costs food like any other (worked 2026-10-18).
-- (Opening the map with an empty or remembered marker did nothing: the
-- marker is the bed's runtime name, new every session.)
local bed_trip_until = 0
local function open_map(pc, bed)
    ft_class = ft_class or try(function() return StaticFindObject("/Script/Permafrost.FastTravelComponent") end)
    local comp = valid(ft_class) and call(bed, "GetComponentByClass", ft_class)
    if not valid(comp) then
        pcall(make_travel_point, bed)
        comp = valid(ft_class) and call(bed, "GetComponentByClass", ft_class)
    end
    if not valid(comp) then log("bed has no travel component: " .. fname(bed)) return end
    local ok, err = pcall(function() comp:TravelRequest(pc) end)
    bed_trip_until = os.clock() + 180
    log(string.format("fast travel from %s: %s", fname(bed), ok and "map opened" or tostring(err)))
end

------------------------------------------------------------------ prompt line
-- The "Press F Rest" lines are rows in the HUD's UW_HintsList (HintList,
-- a VerticalBox; the title "Bed | name" is its InteractionName text). While
-- that title names a bed, a "Press T  Fast travel" text line is added to
-- the list, in the font of the title; otherwise it is collapsed. The game
-- may rebuild the list, so the line is put back when it goes missing.
local TEXT_CLASS = nil
local list_path, line_path = nil, nil
local function find_named(w, name, depth)
    if depth > 12 or not valid(w) then return nil end
    if fname(w) == name then return w end
    local tree = get(w, "WidgetTree")
    local root = valid(tree) and get(tree, "RootWidget")
    if valid(root) then
        local r = find_named(root, name, depth + 1)
        if r then return r end
    end
    local n = tonumber(call(w, "GetChildrenCount")) or 0
    for i = 0, n - 1 do
        local r = find_named(call(w, "GetChildAt", i), name, depth + 1)
        if r then return r end
    end
    return nil
end
local function hints_widget()
    local w = list_path and LIB.resolve(list_path)
    if w then return w end
    for _, x in ipairs(try(function() return FindAllOf("UW_HintsList_C") end) or {}) do
        if valid(x) and not fname(x):find("^Default__") and call(x, "IsVisible") ~= false
            and find_named(x, "HintList", 0) then
            list_path = LIB.path_of(x)
            return x
        end
    end
    return nil
end
local line_logged = false
local function update_line()
    local hints = hints_widget()
    if not hints then return end
    local title = find_named(hints, "InteractionName", 0)
    local box = find_named(hints, "HintList", 0)
    if not (valid(title) and valid(box)) then return end
    local t = (try(function() return title:GetText():ToString() end) or ""):lower()
    local at_bed = t:find("bed", 1, true) ~= nil or (CFG.sleepingBags == 1 and t:find("sleeping", 1, true) ~= nil)
    local line = line_path and LIB.resolve(line_path)
    if not at_bed then
        if line then call(line, "SetVisibility", 1) end      -- Collapsed
        return
    end
    if not line then
        TEXT_CLASS = TEXT_CLASS or try(function() return StaticFindObject("/Script/UMG.TextBlock") end)
        local tree = get(hints, "WidgetTree")
        line = valid(TEXT_CLASS) and valid(tree) and try(function() return StaticConstructObject(TEXT_CLASS, tree) end)
        if not valid(line) then return end
        try(function() line:SetFont(title.Font) end)
        try(function() line:SetColorAndOpacity(title.ColorAndOpacity) end)
        try(function() line:SetShadowOffset(title.ShadowOffset) end)
        try(function() line:SetShadowColorAndOpacity(title.ShadowColorAndOpacity) end)
        call(line, "SetText", FText(string.format("Press %s  Fast travel", CFG.travelKey)))
        line_path = LIB.path_of(line)
    end
    if call(line, "GetParent") == nil or not valid(call(line, "GetParent")) then
        call(box, "AddChildToVerticalBox", line)
        if not line_logged then
            line_logged = true
            log("prompt line added under " .. fname(box))
        end
    end
    call(line, "SetVisibility", 3)                            -- HitTestInvisible
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
            if bed then open_map(pc, bed) end
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
    end)
    if not ok then note("error: " .. tostring(err)) end
end)

game_loop(200, function()
    if os.clock() < settle then return end
    local ok, err = pcall(update_line)
    if not ok then note("prompt error: " .. tostring(err)) end
end)

log(string.format("loaded: look at a bed and press %s for fast travel (autosave log %s)", CFG.travelKey,
    save_hooked and "on" or "off"))
