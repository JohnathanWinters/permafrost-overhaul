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
-- User 2026-10-18: the Makeshift Heater should take plastic, cloth AND
-- chemicals (it showed two ingredients). Every ingredient is logged by name
-- and amount; any of the three that is missing is added (chemicals:
-- heaterChemicals, plastic/cloth: 2).
local NEEDED = { { "Cloth", "DA_Resource_Cloth", 2 }, { "Plastic", "DA_Resource_Plastic", 2 },
                 { "Chemicals", "DA_Resource_Chemicals", nil } }
local function short_item(name)
    return (name:match("([%w_]+)%.[%w_]+$") or name:match("([%w_]+)$") or name)
end
local function cost_list(cost)
    local out = {}
    try(function()
        cost:ForEach(function(_, e)
            local st = e:get()
            out[#out + 1] = { Item = st.Item, Amount = tonumber(st.Amount) or 0, name = short_item(item_name(st.Item)) }
        end)
    end)
    return out
end
local function describe(list)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = e.name .. " x" .. e.Amount end
    return table.concat(parts, ", ")
end

local function fix_heater_recipe(chem)
    if heater_done or CFG.heaterChemicals <= 0 then return end
    local r = find_or_load(HEATER_RECIPE)
    local cost = r and get(r, "Cost")
    if not cost then return end
    local list = cost_list(cost)
    local refs = { DA_Resource_Chemicals = chem }
    local DATA = REBALANCE_SHARED("lootdata")
    DATA.start()
    for _, n in ipairs(NEEDED) do
        if not refs[n[2]] then refs[n[2]] = DATA.soft_ref(n[2]) end
    end
    local missing = {}
    for _, n in ipairs(NEEDED) do
        local found = false
        for _, e in ipairs(list) do if e.name:find(n[1], 1, true) then found = true end end
        if not found then missing[#missing + 1] = n end
    end
    if #missing == 0 then
        heater_done = true
        log("Makeshift Heater recipe already needs: " .. describe(list))
        return
    end
    -- Wait for the item references (loot tables load a few seconds in).
    for _, n in ipairs(missing) do
        if refs[n[2]] == nil then return end
    end
    heater_done = true
    local before = describe(list)
    local entries = {}
    for _, e in ipairs(list) do entries[#entries + 1] = { Item = e.Item, Amount = e.Amount } end
    for _, n in ipairs(missing) do
        entries[#entries + 1] = { Item = refs[n[2]], Amount = n[3] or CFG.heaterChemicals }
    end
    -- Append in place; if the array cannot grow from Lua, assign it whole.
    local n0 = #list
    for k = n0 + 1, #entries do
        try(function() cost[k] = entries[k] end)
    end
    if arr_len(cost) ~= #entries then try(function() r.Cost = entries end) end
    local after = cost_list(get(r, "Cost"))
    log(string.format("Makeshift Heater recipe: [%s] -> [%s]%s", before, describe(after),
        #after == #entries and "" or " (FAILED: the ingredient list could not be grown from Lua)"))
end

-- Repair (user 2026-10-18): 1 chemicals, nothing else. The repair cost is a
-- map item -> amount struct; the chemicals entry's amount is set (every
-- numeric field of the struct is logged once so the right one is known)
-- and every other entry removed. Nothing is removed unless chemicals stays.
local function fix_heater_repair(chem)
    if repair_done or CFG.heaterRepairChemicals <= 0 then return end
    local it = find_or_load(HEATER_ITEM)
    local dc = it and get(it, "DurabilityConfig")
    local map = dc and get(dc, "RepairCost")
    if not map then return end
    repair_done = true
    local entries = {}
    try(function()
        map:ForEach(function(k, v)
            entries[#entries + 1] = { key = k:get(), val = v, name = short_item(item_name(k:get())) }
        end)
    end)
    local function fields(val)
        local st = try(function() return val:get() end) or val
        local parts = {}
        for _, f in ipairs({ "Amount", "Value", "Count", "Quantity", "Min", "Max", "LowerBound", "UpperBound" }) do
            local x = try(function() return st[f] end)
            if type(x) == "number" then parts[#parts + 1] = f .. "=" .. x end
        end
        if type(st) == "number" then parts[#parts + 1] = "=" .. st end
        return table.concat(parts, " "), st
    end
    local before = {}
    for _, e in ipairs(entries) do before[#before + 1] = e.name .. " (" .. fields(e.val) .. ")" end
    log("Makeshift Heater repair cost (vanilla): " .. table.concat(before, ", "))
    local chem_entry = nil
    for _, e in ipairs(entries) do if e.name:find("Chemicals", 1, true) then chem_entry = e end end
    if not chem_entry then
        log("Makeshift Heater repair: no chemicals entry to keep; vanilla repair cost kept")
        return
    end
    -- Set its amount.
    local _, st = fields(chem_entry.val)
    local set_ok = false
    if type(st) == "number" then
        set_ok = try(function() chem_entry.val:set(CFG.heaterRepairChemicals); return true end) == true
    else
        for _, f in ipairs({ "Amount", "Value", "Count", "Quantity" }) do
            if type(try(function() return st[f] end)) == "number" then
                set_ok = try(function() st[f] = CFG.heaterRepairChemicals; return true end) == true
                if set_ok then break end
            end
        end
    end
    for _, e in ipairs(entries) do
        if e ~= chem_entry then try(function() map:Remove(e.key) end) end
    end
    local after = {}
    try(function()
        map:ForEach(function(k, v) after[#after + 1] = short_item(item_name(k:get())) .. " (" .. fields(v) .. ")" end)
    end)
    log("Makeshift Heater repair cost now: " .. table.concat(after, ", ") .. (set_ok and "" or " (amount could not be set)"))
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
