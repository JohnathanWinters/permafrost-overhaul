-- BuildSnow module of the Overhaul (2026-10-18). User: the character slowly
-- gets snow on it; player-built structures should too.
-- Step 1 (this version): discovery only, nothing in the game changes.
--  * The character's snow manager (BPC_CharacterSnowManager): its numbers
--    and names, to learn how the character's snow is driven.
--  * Player-built parts (ABuildPartBase): for each distinct material on
--    their meshes, the scalar parameters it overrides and its parent chain,
--    so we know whether building materials can take a snow amount.
-- Everything goes to UE4SS.log with the tag [PF BuildSnow].
-- Settings: BuildSnow section of config.lua.
local TAG = "[PF BuildSnow] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

local DEFAULTS = {
    { "maxMaterials", 40, "how many distinct building materials to log" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\BuildSnow.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "BuildSnow.lua", "t", {})
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

------------------------------------------------------------------ character snow manager
local manager_done = false
local function log_manager()
    if manager_done then return end
    local helpers = try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    if not valid(pawn) then return end
    local cls = try(function() return StaticFindObject("/Game/Permafrost/Blueprints/Components/BPC_CharacterSnowManager.BPC_CharacterSnowManager_C") end)
    if not valid(cls) then cls = try(function() return LoadAsset("/Game/Permafrost/Blueprints/Components/BPC_CharacterSnowManager.BPC_CharacterSnowManager_C") end) end
    local comp = valid(cls) and call(pawn, "GetComponentByClass", cls)
    manager_done = true
    if not valid(comp) then log("character snow manager: not found on the player") return end
    local parts = {}
    try(function()
        cls:ForEachProperty(function(prop)
            local n = try(function() return prop:GetFName():ToString() end) or "?"
            local v = get(comp, n)
            local shown
            if type(v) == "number" or type(v) == "boolean" then shown = tostring(v)
            elseif v ~= nil and valid(v) then shown = fname(v)
            else
                local t = try(function() return v:ToString() end)
                shown = t or "(struct)"
            end
            parts[#parts + 1] = n .. "=" .. shown
        end)
    end)
    log("character snow manager: " .. table.concat(parts, ", "))
end

------------------------------------------------------------------ building materials
local seen_mats, mat_count = {}, 0
local queue = {}
REBALANCE_ON_ACTOR("/Script/Permafrost.BuildPartBase", function(obj)
    if #queue < 400 then queue[#queue + 1] = LIB.path_of(obj) end
end)

local mesh_class = nil
local function parent_chain(mat)
    local names, m = {}, mat
    for _ = 1, 6 do
        names[#names + 1] = fname(m)
        local p = get(m, "Parent")
        if not valid(p) then break end
        m = p
    end
    return table.concat(names, " < ")
end
local function scalar_params(mat)
    local out, snow = {}, false
    local m = mat
    for _ = 1, 6 do
        try(function()
            m.ScalarParameterValues:ForEach(function(_, e)
                local s = e:get()
                local n = try(function() return s.ParameterInfo.Name:ToString() end) or "?"
                local v = tonumber(try(function() return s.ParameterValue end)) or 0
                out[#out + 1] = string.format("%s=%.2f", n, v)
                if n:lower():find("snow") then snow = true end
            end)
        end)
        local p = get(m, "Parent")
        if not valid(p) then break end
        m = p
    end
    return out, snow
end
local diag, unresolved = 0, 0
local function log_part(actor)
    mesh_class = mesh_class or try(function() return StaticFindObject("/Script/Engine.MeshComponent") end)
    local comps = valid(mesh_class) and call(actor, "K2_GetComponentsByClass", mesh_class)
    if diag < 5 then
        diag = diag + 1
        local n = 0
        if comps then try(function() comps:ForEach(function() n = n + 1 end) end) end
        log(string.format("part %s: mesh class %s, %s mesh components", fname(actor), tostring(valid(mesh_class)),
            comps and tostring(n) or "no list"))
    end
    if not comps then return end
    try(function()
        comps:ForEach(function(_, e)
            local c = e:get()
            local n = tonumber(call(c, "GetNumMaterials")) or 0
            for i = 0, n - 1 do
                if mat_count >= CFG.maxMaterials then return end
                local mat = call(c, "GetMaterial", i)
                local mn = valid(mat) and fname(mat)
                if mn and not seen_mats[mn] then
                    seen_mats[mn] = true
                    mat_count = mat_count + 1
                    local params, snow = scalar_params(mat)
                    log(string.format("material %d on %s: %s | scalars: %s%s", mat_count, fname(actor), parent_chain(mat),
                        #params > 0 and table.concat(params, ", ") or "none", snow and "  <- HAS SNOW" or ""))
                end
            end
        end)
    end)
end

-- Built parts showed 0 mesh components (2026-10-18): building meshes are
-- probably instanced, drawn by a grid/manager actor. Once in the world,
-- every instanced mesh component whose owner's class mentions building is
-- listed with its materials (and their scalar parameters).
local ism_done = false
local function log_instanced()
    if ism_done then return end
    ism_done = true
    local owners, n = {}, 0
    for _, c in ipairs(try(function() return FindAllOf("InstancedStaticMeshComponent") end) or {}) do
        if valid(c) and not fname(c):find("^Default__") then
            local o = call(c, "GetOwner")
            local oc = valid(o) and fname(call(o, "GetClass")) or "?"
            local l = oc:lower()
            if l:find("build") or l:find("grid") or l:find("part") then
                n = n + 1
                owners[oc] = (owners[oc] or 0) + 1
                local m = tonumber(call(c, "GetNumMaterials")) or 0
                for i = 0, m - 1 do
                    if mat_count >= CFG.maxMaterials then break end
                    local mat = call(c, "GetMaterial", i)
                    local mn = valid(mat) and fname(mat)
                    if mn and not seen_mats[mn] then
                        seen_mats[mn] = true
                        mat_count = mat_count + 1
                        local params, snow = scalar_params(mat)
                        log(string.format("instanced material %d (%s on %s): %s | scalars: %s%s", mat_count, fname(c), oc,
                            parent_chain(mat), #params > 0 and table.concat(params, ", ") or "none", snow and "  <- HAS SNOW" or ""))
                    end
                end
            end
        end
    end
    local parts = {}
    for k, v in pairs(owners) do parts[#parts + 1] = k .. " x" .. v end
    log(string.format("instanced building meshes: %d components (%s)", n, #parts > 0 and table.concat(parts, ", ") or "none"))
end

local settle = os.clock() + 15
local scanned = false
local world_at, rescan_at, logged_zero = nil, 0, false
local queued_once = {}
game_loop(1000, function()
    if os.clock() < settle then return end
    local ok, err = pcall(function()
        log_manager()
        -- Parts loaded from the save BeginPlay before this module watches:
        -- list the existing ones once (the first run logged none).
        -- Only once in the world (the first scan ran in the main menu and
        -- found 0), then again every 60 s for parts loaded since.
        local helpers = try(function() return require("UEHelpers") end)
        local pc = helpers and try(function() return helpers.GetPlayerController() end)
        if not (valid(pc) and valid(get(pc, "Pawn"))) then return end
        world_at = world_at or (os.clock() + 15)
        if os.clock() >= world_at and os.clock() >= rescan_at then
            rescan_at = os.clock() + 60
            scanned = true
            local n = 0
            for _, a in ipairs(try(function() return FindAllOf("BuildPartBase") end) or {}) do
                local pth = valid(a) and not fname(a):find("^Default__") and LIB.path_of(a)
                if pth and not queued_once[pth] and #queue < 400 then
                    queued_once[pth] = true
                    queue[#queue + 1] = pth
                    n = n + 1
                end
            end
            if n > 0 or not logged_zero then
                logged_zero = true
                log(string.format("built parts found: %d new", n))
            end
        end
        if scanned then pcall(log_instanced) end
        if mat_count >= CFG.maxMaterials then queue = {} return end
        local list = queue
        queue = {}
        for i, p in ipairs(list) do
            if i > 20 then queue[#queue + 1] = p     -- 20 parts per second at most
            else
                local a = LIB.resolve(p)
                if a then log_part(a)
                elseif unresolved < 3 then
                    unresolved = unresolved + 1
                    log("could not look up built part " .. p)
                end
            end
        end
    end)
    if not ok then log("error: " .. tostring(err)) end
end)

log("loaded (discovery only: logs the character snow manager and building materials)")
