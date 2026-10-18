-- Loot module of the Overhaul. Edits the game's loot tables in memory (never
-- the install files) for trash piles, carcasses, enemies and resources:
-- chance x amount per category, big-game meat, and food made scarce
-- everywhere except animals. The math lives in rules.lua, shared with the
-- Loot Ledger page. Writes rebalance_applied.json (vanilla vs mod for every
-- entry it changed).
-- Settings: Loot and Enemies sections of config.lua. Log tag [PF Loot].
local TAG = "[PF Loot] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try = LIB.try
local ROOT = REBALANCE_ROOT or ""
local DATA = REBALANCE_SHARED("lootdata")
local rules = REBALANCE_SHARED("rules")
local short, soft_path, read_range, write_range = DATA.short, DATA.soft_path, DATA.read_range, DATA.write_range

------------------------------------------------------------------ config
-- { key, default, vanilla, description }
local DEFAULTS = {
    { "trashFind",          1.0,  1.0, "trash piles and plastic bags you break apart: chance" },
    { "trashAmount",        2.5,  1.0, "trash piles and plastic bags: amount" },
    { "enemiesFind",        1.0,  1.0, "hostile humans you kill: chance" },
    { "enemiesAmount",      1.0,  1.0, "hostile humans: amount" },
    { "animalsFind",        1.0,  1.0, "animal carcasses: chance" },
    { "animalsAmount",      1.5,  1.0, "animal carcasses: amount (pelts, meat, fat, bones)" },
    { "animalsMeatBigGame", 4.0,  1.0, "raw meat from big game carcasses (deer, moose, boar, bison, muskox, bear)" },
    { "resourcesFind",      1.0,  1.0, "rocks, ore, wood, scrap: chance" },
    { "resourcesAmount",    1.0,  1.0, "rocks, ore, wood, scrap: amount" },
    { "enemyFoodFind",      0.15, 1.0, "hostile humans: chance of food and drinks, on top of enemiesFind" },
    { "foodFind",           0.15, 1.0, "food and drinks everywhere except animals: chance" },
}

local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Loot.lua", "r")  -- generated from config.lua by the loader
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Loot.lua", "t", {})
    local user = chunk and try(chunk)
    if type(user) == "table" then
        for _, d in ipairs(DEFAULTS) do
            local v = tonumber(user[d[1]])
            if v then cfg[d[1]] = math.max(0, math.min(20, v)) end
        end
    end
    return cfg
end
local CFG = load_config()
for _, d in ipairs(DEFAULTS) do log(string.format("%s = %s (vanilla %s)", d[1], tostring(CFG[d[1]]), tostring(d[3]))) end

------------------------------------------------------------------ apply
local plan, plan_known = nil, 0
local report = { entries = {}, failed = 0, swapped = 0 }

local function apply_entry(kind, tname, i, s, e)
    if e.newLo == nil then return end
    local changed = e.newLo ~= e.lo or e.newHi ~= e.hi
    local ok = true
    if changed then
        local lo, hi = read_range(s)
        if lo ~= e.newLo or hi ~= e.newHi then ok = write_range(s, e.newLo, e.newHi) end
    end
    local item_ok = true
    if e.newItem and e.newItem ~= e.item then
        changed = true
        local src = DATA.soft_ref(e.newItem)
        local now = short(soft_path(try(function() return s.Item end)))
        if now ~= e.newItem then
            item_ok = src ~= nil and try(function() s.Item = src; return true end) == true
                and short(soft_path(try(function() return s.Item end))) == e.newItem
        end
    end
    if changed then
        local key = kind .. "|" .. tname .. "|" .. i
        if not report.entries[key] then
            report.entries[key] = { kind = kind, table = tname, index = i, item = e.item, newItem = e.newItem,
                                    w = e.w, lo = e.lo, hi = e.hi, newLo = e.newLo, newHi = e.newHi,
                                    ok = ok and item_ok }
            if not (ok and item_ok) then report.failed = report.failed + 1 end
            if e.newItem and e.newItem ~= e.item and item_ok then report.swapped = report.swapped + 1 end
        end
    end
end

local function apply_plan()
    local live = DATA.live
    for tname, refs in pairs(live.configs) do
        local p = plan.configs[tname]
        if p then for i, s in ipairs(refs) do if p.static[i] then apply_entry("fixed", tname, i, s, p.static[i]) end end end
    end
    for lname, refs in pairs(live.lists) do
        local p = plan.lists[lname]
        if p then for i, s in ipairs(refs) do if p.entries[i] then apply_entry("random", lname, i, s, p.entries[i]) end end end
    end
    for sname, s in pairs(live.singles) do
        local p = plan.singles[sname]
        if p then apply_entry("hit", sname, 1, s, p) end
    end
end

------------------------------------------------------------------ report file
local function json(v, ind)
    ind = ind or ""
    local t = type(v)
    if t == "table" then
        if #v > 0 or next(v) == nil then
            local parts = {}
            for _, x in ipairs(v) do parts[#parts + 1] = json(x, ind .. " ") end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = "\n" .. ind .. " " .. json(k) .. ":" .. json(v[k], ind .. " ") end
        return "{" .. table.concat(parts, ",") .. "\n" .. ind .. "}"
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    elseif t == "number" then
        return (v ~= v or v == math.huge or v == -math.huge) and "0" or tostring(v)
    elseif t == "boolean" then
        return tostring(v)
    end
    return "null"
end

local function write_report()
    local list = {}
    for _, e in pairs(report.entries) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        if a.table ~= b.table then return a.table < b.table end
        return a.index < b.index
    end)
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[#cfg + 1] = { key = d[1], value = CFG[d[1]], vanilla = d[3] } end
    local f = io.open(ROOT .. "rebalance_applied.json", "wb")
    if not f then return end
    f:write(json({ written = os.date("%Y-%m-%d %H:%M:%S"), settings = cfg, failed = report.failed,
                   swapped = report.swapped, entries = list }))
    f:close()
end

------------------------------------------------------------------ wiring
local passes, reported = 0, false
DATA.on_scan(function(n, _, first)
    local vanilla = DATA.vanilla
    -- Rebuild the plan whenever a table shows up for the first time.
    local known = 0
    for _ in pairs(vanilla.configs) do known = known + 1 end
    for _ in pairs(vanilla.lists) do known = known + 1 end
    for _ in pairs(vanilla.singles) do known = known + 1 end
    if not plan or known ~= plan_known then
        plan, plan_known = rules.plan(vanilla, CFG), known
        -- A new plan can change any table: re-read all loaded ones once.
        if not first then DATA.scan(true) end
    end
    apply_plan()
    passes = passes + 1
    if not reported and passes >= 2 then
        reported = true
        local count = 0
        for _ in pairs(report.entries) do count = count + 1 end
        log(string.format("loot tables: %d assets, %d entries changed, %d item swaps, %d failed writes -> rebalance_applied.json",
            n, count, report.swapped, report.failed))
        write_report()
    end
end)
DATA.start()

log("loaded")
