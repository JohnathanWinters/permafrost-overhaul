-- BuildSnow module of the Overhaul (2026-10-18). User: the character slowly
-- gets snow on it; player-built structures should too.
-- What discovery found: every built part (foundations, walls, floors,
-- doorways) draws with its own dynamic material MID_MI_WoodenConstruction,
-- whose master is MM_Opaque_VT, the same master the game's snowy rocks and
-- wood use. That master has a snow layer driven by "Coverage (Snow)",
-- "Falloff Offset (Snow)" and "Mask Cutoff (Snow)" (the snowy wood uses
-- 0.90 / 0.20 / 0.05). Built parts just leave coverage at 0.
-- This module sets those three on each built part's dynamic materials, so
-- snow lies on the upward faces like on the world's buildings. Parts are
-- found as they load (and by a scan every 30 s); each part is done once.
-- Only dynamic materials are touched (they belong to that one part), never
-- shared material assets.
-- Settings: BuildSnow section of config.lua. Log tag [PF BuildSnow].
local TAG = "[PF BuildSnow] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

local DEFAULTS = {
    { "coverage", 0.9, "snow coverage on built parts (0 = none, vanilla)" },
    { "falloffOffset", 0.2, "how far the snow reaches down the sides" },
    { "maskCutoff", 0.05, "snow mask cutoff" },
    { "shelterMetres", 30, "a part with anything above it within this distance (a roof) gets no snow (0 = no check)" },
    { "swapMaterial", 1, "1 = rebuild each part's material on the game's snowy wood material (needed for snow to show)" },
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
CFG.swapMaterial = CFG.swapMaterial ~= 0

local PARAMS = {
    { "Coverage (Snow)", CFG.coverage },
    { "Falloff Offset (Snow)", CFG.falloffOffset },
    { "Mask Cutoff (Snow)", CFG.maskCutoff },
}

------------------------------------------------------------------ parts
-- K2_GetComponentsByClass gives 0 mesh components on built parts, so the
-- part's own class properties are walked (3 levels) for mesh components,
-- plus the root component.
local function part_meshes(actor)
    local out, seen = {}, {}
    local function add(c)
        if not valid(c) then return end
        local a = LIB.address(c)
        if a and seen[a] then return end
        local cn = fname(call(c, "GetClass")) or ""
        if cn:find("MeshComponent") then
            if a then seen[a] = true end
            out[#out + 1] = c
        end
    end
    add(get(actor, "RootComponent"))
    local cls = call(actor, "GetClass")
    for _ = 1, 3 do
        if not valid(cls) then break end
        try(function()
            cls:ForEachProperty(function(prop)
                local n = try(function() return prop:GetFName():ToString() end)
                if n then
                    local v = get(actor, n)
                    if type(v) == "userdata" then try(function() add(v) end) end
                end
            end)
        end)
        cls = try(function() return cls:GetSuperStruct() end)
    end
    return out
end

------------------------------------------------------------------ snow material
-- Setting the coverage alone showed no snow (2026-10-18): the build-part
-- material (MMI_BuildPart_VT) most likely has the snow layer switched off
-- by a static switch, which cannot change at runtime. MI_FV_Wood (the
-- game's snowy wood, same master MM_Opaque_VT) has it on. So each part's
-- material is replaced by a new dynamic material on MI_FV_Wood with the
-- part's own textures, colours and numbers copied over (same master, so
-- the parameter names match): the part keeps its look and gets snow.
local SNOW_PARENT = "MI_FV_Wood"
local snow_parent_path, parent_looked = nil, false
local function find_snow_parent()
    if snow_parent_path then
        local m = LIB.resolve(snow_parent_path)
        if m then return m end
    end
    if parent_looked then return nil end
    parent_looked = true
    for _, m in ipairs(try(function() return FindAllOf("MaterialInstanceConstant") end) or {}) do
        if valid(m) and fname(m) == SNOW_PARENT then
            snow_parent_path = LIB.path_of(m)
            log("snow material found: " .. tostring(snow_parent_path))
            return m
        end
    end
    log("snow material " .. SNOW_PARENT .. " not loaded: falling back to coverage only")
    return nil
end

-- Parameters set on a material and its parents (closest wins).
local function collect(mat)
    local out = { scalar = {}, vector = {}, texture = {}, order = {} }
    local m = mat
    for _ = 1, 6 do
        for _, kind in ipairs({ { "scalar", "ScalarParameterValues" }, { "vector", "VectorParameterValues" },
                                { "texture", "TextureParameterValues" } }) do
            try(function()
                m[kind[2]]:ForEach(function(_, e)
                    local s = e:get()
                    local n = try(function() return s.ParameterInfo.Name:ToString() end)
                    if n and out[kind[1]][n] == nil then
                        local v = try(function() return s.ParameterValue end)
                        if v ~= nil then
                            if kind[1] == "vector" then
                                v = { R = v.R, G = v.G, B = v.B, A = v.A }
                            end
                            out[kind[1]][n] = v
                            out.order[#out.order + 1] = { kind[1], n }
                        end
                    end
                end)
            end)
        end
        local p = get(m, "Parent")
        if not valid(p) then break end
        m = p
    end
    return out
end

-- Logs a material's static switches (UE5 keeps them in StaticParametersRuntime).
local function switches(mat)
    local out, m = {}, mat
    for _ = 1, 6 do
        for _, field in ipairs({ "StaticParametersRuntime", "StaticParameters" }) do
            try(function()
                m[field].StaticSwitchParameters:ForEach(function(_, e)
                    local s = e:get()
                    local n = try(function() return s.ParameterInfo.Name:ToString() end) or "?"
                    out[#out + 1] = string.format("%s:%s=%s", fname(m), n, tostring(try(function() return s.Value end)))
                end)
            end)
        end
        local p = get(m, "Parent")
        if not valid(p) then break end
        m = p
    end
    return #out > 0 and table.concat(out, ", ") or "none readable"
end

local stats = { parts = 0, mats = 0, swapped = 0, skipped = 0, sheltered = 0 }
local verified, described = false, false
local function snow_material(c, i, old, parent)
    if not CFG.swapMaterial or not parent then return old end
    local src = collect(old)
    local new = call(c, "CreateDynamicMaterialInstance", i, parent, FName("None"))
    if not valid(new) then return old end
    for _, o in ipairs(src.order) do
        local kind, n = o[1], o[2]
        local v = src[kind][n]
        if kind == "scalar" then call(new, "SetScalarParameterValue", FName(n), v)
        elseif kind == "vector" then call(new, "SetVectorParameterValue", FName(n), v)
        elseif kind == "texture" and valid(v) then call(new, "SetTextureParameterValue", FName(n), v) end
    end
    stats.swapped = stats.swapped + 1
    if not described then
        described = true
        local tex = {}
        for n, v in pairs(src.texture) do tex[#tex + 1] = n .. "=" .. (valid(v) and fname(v) or "?") end
        log("part material switches: " .. switches(old))
        log("snow material switches: " .. switches(parent))
        log("copied textures: " .. table.concat(tex, ", "))
    end
    return new
end

-- Only parts open to the sky get snow (user 2026-10-18: snow showed on the
-- repair bench inside the building). A trace goes straight up from just
-- above the part's top, at its centre; anything within shelterMetres
-- (a roof, a ceiling, another storey) means sheltered.
local helpers_cache = nil
local trace_warned, shelter_logged = false, 0
local function sheltered(actor)
    local limit = (tonumber(CFG.shelterMetres) or 0) * 100
    if limit <= 0 then return false end
    helpers_cache = helpers_cache or try(function() return require("UEHelpers") end)
    local ksl = helpers_cache and try(function() return helpers_cache.GetKismetSystemLibrary() end)
    if not ksl then return false end
    local origin, extent = {}, {}
    try(function() actor:GetActorBounds(true, origin, extent, false) end)
    local x, y = tonumber(origin.X), tonumber(origin.Y)
    local top = tonumber(origin.Z) and tonumber(extent.Z) and (origin.Z + extent.Z)
    if not (x and y and top) then
        local p = call(actor, "K2_GetActorLocation")
        if not p then return false end
        x, y, top = p.X, p.Y, p.Z + 50
    end
    local hit = {}
    local blocked = try(function()
        return ksl:LineTraceSingle(actor, { X = x, Y = y, Z = top + 15 }, { X = x, Y = y, Z = top + 15 + limit },
            0, false, {}, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
    end)
    if blocked == nil and not trace_warned then
        trace_warned = true
        log("roof check: the trace failed, parts are treated as open to the sky")
    end
    if blocked == true and shelter_logged < 3 then
        shelter_logged = shelter_logged + 1
        local o = hit.HitObjectHandle and try(function() return hit.HitObjectHandle.Actor:Get() end)
        log(string.format("roof check: %s is under %s", fname(actor), o and valid(o) and fname(o) or "something"))
    end
    return blocked == true
end

local function snow_part(actor)
    if sheltered(actor) then
        stats.sheltered = stats.sheltered + 1
        stats.parts = stats.parts + 1
        return
    end
    local parent = CFG.swapMaterial and find_snow_parent() or nil
    for _, c in ipairs(part_meshes(actor)) do
        local cname = fname(c) or ""
        local n = tonumber(call(c, "GetNumMaterials")) or 0
        for i = 0, n - 1 do
            local mat = call(c, "GetMaterial", i)
            if valid(mat) and not cname:find("^Arrow") then
                local cn = fname(call(mat, "GetClass")) or ""
                if cn == "MaterialInstanceDynamic" then
                    mat = snow_material(c, i, mat, parent)
                    for _, p in ipairs(PARAMS) do
                        call(mat, "SetScalarParameterValue", FName(p[1]), p[2])
                    end
                    stats.mats = stats.mats + 1
                    if not verified then
                        verified = true
                        local back = call(mat, "K2_GetScalarParameterValue", FName(PARAMS[1][1]))
                        log(string.format("first part %s (%s): coverage set to %.2f, reads back %s", fname(actor), fname(mat),
                            PARAMS[1][2], tostring(back)))
                    end
                else
                    stats.skipped = stats.skipped + 1
                end
            end
        end
    end
    stats.parts = stats.parts + 1
end

------------------------------------------------------------------ loop
local queue, done = {}, {}
REBALANCE_ON_ACTOR("/Script/Permafrost.BuildPartBase", function(obj)
    if #queue < 2000 then queue[#queue + 1] = LIB.path_of(obj) end
end)

local world_at, rescan_at, reported = nil, 0, -1
game_loop(1000, function()
    if CFG.coverage <= 0 then return end
    local ok, err = pcall(function()
        local helpers = try(function() return require("UEHelpers") end)
        local pc = helpers and try(function() return helpers.GetPlayerController() end)
        if not (valid(pc) and valid(get(pc, "Pawn"))) then return end
        world_at = world_at or (os.clock() + 15)
        if os.clock() < world_at then return end
        if os.clock() >= rescan_at then
            rescan_at = os.clock() + 30
            for _, a in ipairs(try(function() return FindAllOf("BuildPartBase") end) or {}) do
                local pth = valid(a) and not fname(a):find("^Default__") and LIB.path_of(a)
                if pth and not done[pth] and #queue < 2000 then queue[#queue + 1] = pth end
            end
        end
        local list = queue
        queue = {}
        local handled = 0
        for _, p in ipairs(list) do
            if p and not done[p] then
                if handled >= 40 then queue[#queue + 1] = p     -- 40 parts per second at most
                else
                    local a = LIB.resolve(p)
                    if a then
                        done[p] = true
                        handled = handled + 1
                        snow_part(a)
                    end
                end
            end
        end
        if #queue == 0 and stats.parts ~= reported then
            reported = stats.parts
            log(string.format("snow on %d of %d built parts (%d under a roof skipped; %d materials set, %d rebuilt on the snow material, %d shared left alone)",
                stats.parts - stats.sheltered, stats.parts, stats.sheltered, stats.mats, stats.swapped, stats.skipped))
        end
    end)
    if not ok then log("error: " .. tostring(err)) end
end)

log(string.format("loaded: snow coverage %.2f on built parts", CFG.coverage))
