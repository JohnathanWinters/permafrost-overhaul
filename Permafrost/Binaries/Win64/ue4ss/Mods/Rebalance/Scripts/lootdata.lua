-- Shared library (not a feature, cannot be turned off): reads the game's
-- loot tables for the modules that need them (loot, containers,
-- enemydrops). Loaded once through REBALANCE_SHARED("lootdata"); whichever
-- module asks first starts the scan, so no module depends on another being
-- on. Changes nothing by itself.
--  * vanilla: every table's vanilla entries, captured once.
--  * live: struct refs of the tables loaded right now, rebuilt on every
--    pass and only valid inside it (see on_scan).
--  * soft_ref(item): a soft pointer to an item, read from a loaded table.
local TAG = "[PF LootData] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, full, game_loop, game_later = LIB.try, LIB.valid, LIB.fname, LIB.full, LIB.game_loop, LIB.game_later
local ROOT = REBALANCE_ROOT or ""

local M = {}

function M.short(path)
    if type(path) ~= "string" then return "?" end
    return path:match("%.([^%.]+)$") or path:match("([^/]+)$") or path
end
local short = M.short

function M.soft_path(v)
    if v == nil then return nil end
    local id = try(function() return v:GetObjectID() end)
    local p = id and (try(function() return id:GetAssetPathName():ToString() end) or try(function() return id:ToString() end))
    if type(p) == "string" and p ~= "" then return p end
    local o = try(function() return v:GetWeakPtr():Get() end)
    if valid(o) then return full(o) end
    return nil
end
local soft_path = M.soft_path

function M.each_elem(arr, fn)
    try(function()
        arr:ForEach(function(i, e)
            local s = try(function() return e:get() end)
            fn(i, s ~= nil and s or e)
        end)
    end)
end
local each_elem = M.each_elem

function M.read_range(s)
    local r = try(function() return s.AmountRange end)
    local lo = r and try(function() return r.LowerBound.Value end)
    local hi = r and try(function() return r.UpperBound.Value end)
    return tonumber(lo), tonumber(hi)
end
local read_range = M.read_range

function M.write_range(s, lo, hi)
    try(function()
        local r = s.AmountRange
        r.LowerBound.Value = lo
        r.UpperBound.Value = hi
    end)
    local a, b = read_range(s)
    return a == lo and b == hi
end

-- An inventory item as { item = short name, amount }.
function M.item_entry(it)
    if not valid(it) then return nil end
    local cfgobj = try(function() return it.Config end)
    local amount = tonumber(try(function() return it.Amount end)) or 0
    local name = valid(cfgobj) and fname(cfgobj) or (cfgobj ~= nil and short(soft_path(cfgobj))) or nil
    if name and name ~= "?" and amount > 0 then return { item = name, amount = amount } end
    return nil
end

------------------------------------------------------------------ tables
local function read_asset_list()
    local list = {}
    local f = io.open(ROOT .. "Scripts\\asset_list.txt", "r")
    if not f then log("asset_list.txt missing") return list end
    for raw in f:lines() do
        local line = raw:gsub("%s+$", "")
        if line ~= "" then list[#list + 1] = line end
    end
    f:close()
    return list
end

local function load_asset(path)
    local obj = try(function() return StaticFindObject(path) end)
    if valid(obj) then return obj end
    obj = try(function() return LoadAsset(path) end)
    if valid(obj) then return obj end
    return try(function() return StaticFindObject(path) end)
end

-- Struct refs per table, rebuilt from the live asset on EVERY pass and used
-- only within that pass. Keeping them across passes wrote loot amounts into
-- tables the game had unloaded, i.e. into freed memory, which later crashed
-- Blueprint code (2026-10-17).
M.live = { configs = {}, lists = {}, singles = {} }
M.vanilla = { configs = {}, lists = {}, singles = {} }  -- captured once, never overwritten
-- Item short name -> where a loot table references it: { path, field, pos }.
-- The soft pointer itself is read again from the live table each time it
-- is needed (soft_ref), never kept: it points into the table's memory.
M.item_soft = {}
local item_soft = M.item_soft

local function capture_soft(s, path, field, pos)
    local it = try(function() return s.Item end)
    local sp = soft_path(it)
    local name = short(sp)
    if name ~= "?" then
        local e = item_soft[name]
        if not e then
            e = { soft = sp, sources = {} }
            item_soft[name] = e
        end
        if #e.sources < 4 then
            local dup = false
            for _, src in ipairs(e.sources) do if src.path == path then dup = true end end
            if not dup then e.sources[#e.sources + 1] = { path = path, field = field, pos = pos } end
        end
    end
    return name
end

local function soft_from(src, obj, name)
    local st = nil
    if src.field == "Loot" then
        st = try(function() return obj.Loot end)
    else
        local k = 0
        each_elem(try(function() return obj[src.field] end), function(_, e)
            k = k + 1
            if k == src.pos then st = e end
        end)
    end
    local it = st and try(function() return st.Item end)
    if it == nil or short(soft_path(it)) ~= name then return nil end
    return it
end

-- A soft pointer to the item, read now from a loaded loot table; use it
-- right away. Loads a table (a small hitch) only when none is loaded.
function M.soft_ref(name)
    local e = name and item_soft[name]
    if not e then return nil end
    for _, src in ipairs(e.sources) do
        local obj = nil
        local s = src.path:match("%.([^%.]+)$")
        for _, c in ipairs({ "LootConfig", "LootConfig_RandomList", "SingleResourceLootConfig" }) do
            local l = s and LIB.live(c)[s]
            if l and l[1] then obj = l[1] break end
        end
        if valid(obj) then
            local it = soft_from(src, obj, name)
            if it then return it end
        end
    end
    local src = e.sources[1]
    local obj = src and try(function() return LoadAsset(src.path) end)
    return valid(obj) and soft_from(src, obj, name) or nil
end

local asset_list = nil
local live_addr = {}
local first_load = true
-- full = read every loaded table; otherwise only tables that are new or were
-- reloaded (new address). Only the first pass force-loads tables.
function M.scan(full_pass)
    local n, changed = 0, 0
    asset_list = asset_list or read_asset_list()
    local loading = first_load
    first_load = false
    local live = { configs = {}, lists = {}, singles = {} }
    M.live = live
    local vanilla = M.vanilla
    local loaded = nil
    if not loading then
        loaded = {}
        for _, cls in ipairs({ "LootConfig", "LootConfig_RandomList", "SingleResourceLootConfig" }) do
            for _, o in ipairs(try(function() return FindAllOf(cls) end) or {}) do
                local nm = try(function() return o:GetFName():ToString() end)
                if nm and not nm:find("^Default__") then loaded[nm] = o end
            end
        end
    end
    for _, path in ipairs(asset_list) do
        local name = short(path)
        local obj
        if loading then obj = load_asset(path) else obj = loaded[name] end
        local addr = valid(obj) and try(function() return obj:GetAddress() end)
        if not (valid(obj) and addr) then
            live_addr[name] = nil
        else
            n = n + 1
            local is_new = live_addr[name] ~= addr
            if is_new then changed = changed + 1 end
            live_addr[name] = addr
            local cls = (full_pass or is_new) and (try(function() return obj:GetClass():GetFName():ToString() end) or "?") or ""
            if cls == "LootConfig" then
                local static, refs, random = {}, {}, {}
                local fresh = not vanilla.configs[name]
                each_elem(obj.StaticLoot, function(_, st)
                    if fresh then
                        local lo, hi = read_range(st)
                        static[#static + 1] = { item = capture_soft(st, path, "StaticLoot", #refs + 1), lo = lo or 0, hi = hi or 0 }
                    end
                    refs[#refs + 1] = st
                end)
                if fresh then
                    each_elem(obj.RandomLoot, function(_, l)
                        if valid(l) then random[#random + 1] = fname(l) end
                    end)
                    vanilla.configs[name] = { static = static, random = random }
                end
                live.configs[name] = refs
            elseif cls == "LootConfig_RandomList" then
                local entries, refs = {}, {}
                local fresh = not vanilla.lists[name]
                each_elem(obj.RandomItemsList, function(_, st)
                    if fresh then
                        local lo, hi = read_range(st)
                        entries[#entries + 1] = { item = capture_soft(st, path, "RandomItemsList", #refs + 1),
                                                  w = tonumber(try(function() return st.SpawnWeight end)) or 0,
                                                  lo = lo or 0, hi = hi or 0 }
                    end
                    refs[#refs + 1] = st
                end)
                if fresh then vanilla.lists[name] = entries end
                live.lists[name] = refs
            elseif cls == "SingleResourceLootConfig" then
                local st = try(function() return obj.Loot end)
                if st then
                    if not vanilla.singles[name] then
                        local lo, hi = read_range(st)
                        vanilla.singles[name] = { item = capture_soft(st, path, "Loot", 1), lo = lo or 0, hi = hi or 0 }
                    end
                    live.singles[name] = st
                end
            end
        end
    end
    return n, changed
end

function M.ready() return next(item_soft) ~= nil end

------------------------------------------------------------------ passes
-- Listeners: fn(n, changed, first) right after a scan, while M.live is valid.
local listeners = {}
function M.on_scan(fn) listeners[#listeners + 1] = fn end

local passes = 0
local function pass()
    local first = passes < 2
    local n, changed = M.scan(first)
    passes = passes + 1
    if n == 0 or (changed == 0 and not first) then return end
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, n, changed, first)
        if not ok then log("listener error: " .. tostring(err)) end
    end
end

-- Started by the first module that needs it. Loot tables can be unloaded
-- and reloaded from disk (reverting to vanilla), so passes repeat; a table
-- the game loads again is picked up within ~0.35 s.
local started = false
function M.start()
    if started then return end
    started = true
    local reload_at = false
    for _, cls in ipairs({ "LootConfig", "LootConfig_RandomList", "SingleResourceLootConfig" }) do
        REBALANCE_ON_ASSET(cls, function()
            if passes > 0 and not reload_at then reload_at = os.clock() + 0.25 end
        end)
    end
    game_later(3000, function() pcall(pass) end)
    game_loop(20000, function()
        local ok, err = pcall(pass)
        if not ok then log("pass error: " .. tostring(err)) end
    end)
    game_loop(100, function()
        if reload_at and os.clock() >= reload_at then
            reload_at = false
            pcall(pass)
        end
    end)
end

return M
