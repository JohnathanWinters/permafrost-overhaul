-- Recipes module of the Overhaul (2026-10-18). Makeshift Heater
-- (DA_CraftingRecipe_ChemicalHeater): Cost gets heaterChemicals x Chemicals
-- on top of cloth + plastic; its repair cost (DA_Clothing_ChemicalHeater.
-- DurabilityConfig.RepairCost, a map item -> amount) becomes Chemicals only.
-- The Chemicals reference is copied from DA_CraftingRecipe_Chemicals.Result.
-- Data assets are edited in memory; nothing on disk.
-- Settings: Recipes section of config.lua. Log tag [PF Recipes].
local TAG = "[PF Recipes] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid = LIB.try, LIB.valid
local get = LIB.get
local ROOT = REBALANCE_ROOT or ""
------------------------------------------------------------------ config
local DEFAULTS = {
    { "heaterChemicals",       1, "chemicals needed to craft the Makeshift Heater (0 = vanilla recipe)" },
    { "heaterRepairChemicals", 1, "chemicals to repair it; replaces its vanilla repair cost (0 = vanilla)" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Recipes.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Recipes.lua", "t", {})
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

local ITEMS = "/Game/Permafrost/Blueprints/Items/DataAsset_Items/"
local HEATER_RECIPE = ITEMS .. "CraftingRecipes/Clothing/Heaters/DA_CraftingRecipe_ChemicalHeater.DA_CraftingRecipe_ChemicalHeater"
local CHEM_RECIPE = ITEMS .. "CraftingRecipes/Resources/DA_CraftingRecipe_Chemicals.DA_CraftingRecipe_Chemicals"
local HEATER_ITEM = ITEMS .. "Clothing/AdditionalAccessories/DA_Clothing_ChemicalHeater.DA_Clothing_ChemicalHeater"

local function find_or_load(path)
    local o = try(function() return StaticFindObject(path) end)
    if not valid(o) then o = try(function() return LoadAsset(path) end) end
    return valid(o) and o or nil
end

local function arr_len(arr)
    local n = 0
    try(function() arr:ForEach(function() n = n + 1 end) end)
    return n
end

------------------------------------------------------------------ 1. heater
-- The Chemicals item reference, as the soft pointer the Chemicals recipe produces.
local function chemicals_ref()
    local r = find_or_load(CHEM_RECIPE)
    local res = r and get(r, "Result")
    if not res then return nil end
    -- Result is one FItemAmount or an array of them.
    local item = get(res, "Item")
    if item ~= nil then return item end
    local first = nil
    try(function() res:ForEach(function(_, e) if not first then first = e:get().Item end end) end)
    return first
end

local function item_name(soft)
    local p = soft and (try(function() return soft:GetObjectID():GetAssetPathName():ToString() end)
        or try(function() return soft:ToString() end))
    return type(p) == "string" and p or "?"
end

local heater_done, repair_done = false, false
local function fix_heater_recipe(chem)
    if heater_done or CFG.heaterChemicals <= 0 then return end
    local r = find_or_load(HEATER_RECIPE)
    local cost = r and get(r, "Cost")
    if not cost then return end
    heater_done = true
    local entries, has = {}, false
    try(function()
        cost:ForEach(function(_, e)
            local s = e:get()
            local name = item_name(s.Item)
            if name:find("Chemicals") then has = true end
            entries[#entries + 1] = { Item = s.Item, Amount = s.Amount }
        end)
    end)
    if has then log("heater recipe already has chemicals") return end
    local before = #entries
    -- Append in place; if the array cannot grow from Lua, assign it whole.
    local ok = try(function() cost[before + 1] = { Item = chem, Amount = CFG.heaterChemicals }; return true end)
    if not ok or arr_len(cost) ~= before + 1 then
        entries[#entries + 1] = { Item = chem, Amount = CFG.heaterChemicals }
        try(function() r.Cost = entries end)
    end
    local now = arr_len(get(r, "Cost"))
    log(string.format("Makeshift Heater recipe: %d -> %d ingredients%s", before, now,
        now == before + 1 and string.format(" (+%d chemicals)", CFG.heaterChemicals) or " (FAILED to add chemicals)"))
end

local function fix_heater_repair(chem)
    if repair_done or CFG.heaterRepairChemicals <= 0 then return end
    local it = find_or_load(HEATER_ITEM)
    local dc = it and get(it, "DurabilityConfig")
    local map = dc and get(dc, "RepairCost")
    if not map then return end
    repair_done = true
    -- Vanilla already repairs it with chemicals (log 2026-10-18): leave it.
    -- Otherwise add chemicals first and drop the other entries only once the
    -- add is confirmed (an earlier version emptied the map, then the add
    -- failed and repairs became free).
    local old, has_chem = {}, false
    try(function()
        map:ForEach(function(k)
            local n = item_name(k:get())
            old[#old + 1] = n:match("[%.]([^%.]+)$") or n
            if n:find("Chemicals") then has_chem = true end
        end)
    end)
    if has_chem then
        log("Makeshift Heater already repairs with chemicals (vanilla): unchanged")
        return
    end
    local added = try(function() map:Add(chem, CFG.heaterRepairChemicals); return true end)
    local now_has = false
    try(function() map:ForEach(function(k) if item_name(k:get()):find("Chemicals") then now_has = true end end) end)
    if not (added and now_has) then
        log("Makeshift Heater repair: could not add chemicals from Lua; vanilla repair cost kept ("
            .. table.concat(old, ", ") .. ")")
        return
    end
    -- Chemicals are in: remove everything else.
    local others = {}
    try(function() map:ForEach(function(k) if not item_name(k:get()):find("Chemicals") then others[#others + 1] = k:get() end end) end)
    for _, k in ipairs(others) do try(function() map:Remove(k) end) end
    log("Makeshift Heater repair: [" .. table.concat(old, ", ") .. "] -> chemicals only")
end


------------------------------------------------------------------ wiring
-- The recipe and item assets may load late; retry every 5 s until done.
local tries = 0
LIB.game_loop(5000, function()
    if (heater_done or CFG.heaterChemicals <= 0) and (repair_done or CFG.heaterRepairChemicals <= 0) then return end
    tries = tries + 1
    local chem = chemicals_ref()
    if chem == nil then
        if tries == 12 then log("Chemicals item reference not found (DA_CraftingRecipe_Chemicals.Result)") end
        return
    end
    local ok, err = pcall(fix_heater_recipe, chem)
    if not ok then log("heater recipe error: " .. tostring(err)) heater_done = true end
    ok, err = pcall(fix_heater_repair, chem)
    if not ok then log("heater repair error: " .. tostring(err)) repair_done = true end
end)

log(string.format("loaded: Makeshift Heater +%d chemicals, repair %d chemicals", CFG.heaterChemicals, CFG.heaterRepairChemicals))
