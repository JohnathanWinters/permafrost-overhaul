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

local stats = { parts = 0, mats = 0, skipped = 0 }
local verified = false
local function snow_part(actor)
    for _, c in ipairs(part_meshes(actor)) do
        local n = tonumber(call(c, "GetNumMaterials")) or 0
        for i = 0, n - 1 do
            local mat = call(c, "GetMaterial", i)
            if valid(mat) then
                local cn = fname(call(mat, "GetClass")) or ""
                if cn == "MaterialInstanceDynamic" then
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
            log(string.format("snow on %d built parts (%d materials set, %d shared materials left alone)",
                stats.parts, stats.mats, stats.skipped))
        end
    end)
    if not ok then log("error: " .. tostring(err)) end
end)

log(string.format("loaded: snow coverage %.2f on built parts", CFG.coverage))
