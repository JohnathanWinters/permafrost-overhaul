-- Food module of the Overhaul (2026-10-18). Food and drinks do not heal:
-- every DA_Consumable_* outside Medication loses the Health entries of
-- AttributeRestorationMap (key FGameplayAttribute, AttributeName "Health")
-- and AttributeRestorationAmount (key ESurvivorStat). Entries are removed,
-- not zeroed, so the tooltip (built from these maps) stops listing healing;
-- if Remove is unsupported they are zeroed. Medical items keep healing.
-- Food scarcity is the Loot module (Loot.foodFind).
-- Settings: Food section of config.lua. Log tag [PF Food].
local TAG = "[PF Food] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname = LIB.try, LIB.valid, LIB.fname
local get = LIB.get
local ROOT = REBALANCE_ROOT or ""
------------------------------------------------------------------ config
local DEFAULTS = {
    { "foodHeals", 0, "1 = food and drinks heal as vanilla, 0 = they do not heal" },
    { "debugLog",  1, "1 = log what was changed" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Food.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Food.lua", "t", {})
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
if CFG.foodHeals == 1 then
    log("off: food heals as vanilla")
    return
end

------------------------------------------------------------------ 2. food healing
local function is_health(name)
    return type(name) == "string" and name:lower():find("health") ~= nil
end

local food_done = {}           -- asset address -> true
local food_count, food_logged = 0, 0
local stat_enum = nil
local function enum_name(v)
    stat_enum = stat_enum or try(function() return StaticFindObject("/Script/Permafrost.ESurvivorStat") end)
    if not valid(stat_enum) then return nil end
    return try(function() return stat_enum:GetNameByValue(v):ToString() end)
end

local function strip_map(map, key_name)
    local hits = {}
    try(function()
        map:ForEach(function(k, v)
            local key = k:get()
            local n = key_name(key)
            if is_health(n) then hits[#hits + 1] = { key = key, v = v, name = n } end
        end)
    end)
    local removed, zeroed = 0, 0
    for _, h in ipairs(hits) do
        if try(function() map:Remove(h.key); return true end) then
            removed = removed + 1
        elseif try(function() h.v:set(0); return true end) then
            zeroed = zeroed + 1
        end
    end
    return removed, zeroed, hits
end

local function fix_food(obj)
    if CFG.foodHeals == 1 then return end
    local path = LIB.path_of(obj)
    if not path:find("/Consumables/") or path:find("/Medication/") then return end
    local a = LIB.address(obj)
    if not a or food_done[a] then return end
    food_done[a] = true
    local r1, z1, h1 = 0, 0, {}
    local m1 = get(obj, "AttributeRestorationMap")
    if m1 then
        r1, z1, h1 = strip_map(m1, function(key)
            return try(function() return key.AttributeName:ToString() end)
        end)
    end
    local r2, z2, h2 = 0, 0, {}
    local m2 = get(obj, "AttributeRestorationAmount")
    if m2 then
        r2, z2, h2 = strip_map(m2, function(key) return enum_name(key) or tostring(key) end)
    end
    if #h1 + #h2 > 0 then food_count = food_count + 1 end
    if CFG.debugLog == 1 and food_logged < 8 and #h1 + #h2 > 0 then
        food_logged = food_logged + 1
        local names = {}
        for _, h in ipairs(h1) do names[#names + 1] = h.name end
        for _, h in ipairs(h2) do names[#names + 1] = h.name end
        log(string.format("%s: healing removed (%s; %d removed, %d zeroed)", fname(obj), table.concat(names, ", "),
            r1 + r2, z1 + z2))
    end
end


------------------------------------------------------------------ wiring
REBALANCE_ON_ASSET("ItemConfig_Consumable", function(obj)
    local ok, err = pcall(fix_food, obj)
    if not ok and food_logged < 8 then food_logged = food_logged + 1 log("food error: " .. tostring(err)) end
end)
LIB.game_loop(60000, function()
    if food_count > 0 and food_logged >= 0 then
        log(string.format("food without healing so far: %d items", food_count))
        food_logged = -100
    end
end)

log("loaded: food and drinks do not heal")
