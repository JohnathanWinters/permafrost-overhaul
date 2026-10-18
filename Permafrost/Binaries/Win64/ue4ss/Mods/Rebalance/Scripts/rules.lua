-- Rebalance rules: pure math, no game API. Used by main.lua in game and by
-- Core\tools\loot_ledger.py offline (through lupa), so the Loot Ledger
-- always shows exactly what the mod applies.
--
-- Game roll rules (ULootConfig::GetLoot, build 25985440):
--   fixed entry  -> amount = uniform whole number in [lo, hi]; <= 0 gives nothing
--   random list  -> one pick by weight, then that entry rolls [lo, hi] the same way
-- So a negative lo is how the mod adds a chance of "nothing": [-5, 2] gives
-- 1 or 2 on 2 of 8 rolls (25%) and nothing otherwise.
local M = {}

-- Setting keys per category: <key>Find scales the chance an item is there,
-- <key>Amount scales how many you get when it is. 1.0 = vanilla.
M.CATEGORIES = {
    { key = "carSmall",    title = "Cars, small",              pats = { "_Car_Small$" } },
    { key = "carMedium",   title = "Cars, medium",             pats = { "_Car_Medium$" } },
    { key = "carBig",      title = "Cars, big",                pats = { "_Car_Big$" } },
    { key = "militaryCar", title = "Military vehicles",        pats = { "_Car_Military" } },
    { key = "military",    title = "Military crates and ammo", pats = { "Military", "AmmoBox", "QualityCrate" } },
    { key = "trash",       title = "Trash and junk",           pats = { "Trash", "PlasticJunk", "PlasticPallet", "ClothPile", "ScrapPile" } },
    { key = "homes",       title = "Homes, offices, utilities", pats = { "Cabinet", "Fridge", "SuitCase", "Luggage", "WoodenBox",
                                                                         "Toolbox", "ATM", "ElectricityBox", "PumpingStation",
                                                                         "SolarPanel", "MedicalBox" } },
    { key = "bodies",      title = "Dead bodies and dog finds", pats = { "DeadBody", "DogLoot" } },
    { key = "enemies",     title = "Hostile humans",           pats = { "HostileNPC" } },
    { key = "animals",     title = "Animal carcasses",         pats = { "_Dead%u" } },
    { key = "resources",   title = "Rocks, ore, wood, scrap",  pats = { "Destructable", "Scavengable", "FrostCore" } },
}

-- Tables the mod never touches.
M.SKIP = { "Trading", "PlayerRespawnItems", "Template", "EquipmentSet", "StartingEquipment" }

function M.skipped(name)
    for _, s in ipairs(M.SKIP) do
        if name:find(s, 1, true) then return true end
    end
    return false
end

function M.category(name)
    for _, c in ipairs(M.CATEGORIES) do
        for _, p in ipairs(c.pats) do
            if name:find(p) then return c.key end
        end
    end
    return "resources"
end

-- Searchable containers (cars, fridges, cabinets, crates, bodies...) are
-- handled by the container profiles (containers.lua), so their loot tables
-- stay vanilla here. Carcasses, enemies and Frost Core are not containers.
function M.is_container_table(name)
    return name:find("DA_LC_Containers_", 1, true) ~= nil and not name:find("HostileNPC", 1, true)
        and not name:find("FrostCore", 1, true) and M.category(name) ~= "animals"
end

-- Food and drink items (alcohol included, medication not).
function M.is_food(item)
    return type(item) == "string" and item:find("^DA_Consumable_") ~= nil and item:find("Medication") == nil
end

local function round(x)
    return x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5)
end

-- P(amount > 0) and mean amount when > 0 for uniform whole numbers in [lo, hi].
function M.stats(lo, hi)
    if hi < lo then hi = lo end
    local first = math.max(lo, 1)
    if hi < first then return 0, 0 end
    local pos = hi - first + 1
    return pos / (hi - lo + 1), (first + hi) / 2
end

-- New [lo, hi] so the chance of getting anything is `find` times vanilla and
-- the amount when you do is `amount` times vanilla.
function M.range(lo, hi, find, amount)
    local p0, m0 = M.stats(lo, hi)
    if p0 == 0 or (find == 1 and amount == 1) then return lo, hi end
    local p = math.min(1, p0 * find)
    local m = math.max(1, m0 * amount)
    if p >= 0.995 then
        local L = math.max(1, round(math.max(lo, 1) * amount))
        local H = math.max(L, round(hi * amount))
        return L, H
    end
    if p <= 0 then return 0, 0 end
    local H = math.max(1, round(2 * m - 1))
    local L = math.min(0, round(H + 1 - H / p))
    return L, H
end

-- Random lists are shared between tables; each list follows the category
-- of most tables that use it (ties: alphabetical, so it is stable).
local function list_categories(configs)
    local votes = {}
    for name, c in pairs(configs) do
        if not M.skipped(name) and not M.is_container_table(name) then
            local cat = M.category(name)
            for _, l in ipairs(c.random or {}) do
                votes[l] = votes[l] or {}
                votes[l][cat] = (votes[l][cat] or 0) + 1
            end
        end
    end
    local out = {}
    for l, v in pairs(votes) do
        local best, bestn = nil, -1
        for cat, n in pairs(v) do
            if n > bestn or (n == bestn and cat < best) then best, bestn = cat, n end
        end
        out[l] = best
    end
    return out
end

local function setting(cfg, cat, kind)
    local v = tonumber(cfg[cat .. kind])
    if v == nil then return 1.0 end
    return math.max(0, v)
end

-- vanilla = { configs = { name = { static = { {item, lo, hi} }, random = { listname } } },
--             lists   = { name = { {item, w, lo, hi} } },
--             singles = { name = {item, lo, hi} } }
-- Returns a plan with the same shape plus mod values:
--   plan.configs[name].static[i] = { item, lo, hi, newItem, newLo, newHi }
--   plan.lists[name][i]          = { item, w, lo, hi, newLo, newHi }
--   plan.singles[name]           = { item, lo, hi, newLo, newHi }
function M.plan(vanilla, cfg)
    local plan = { configs = {}, lists = {}, singles = {}, listCategory = {} }
    if tonumber(cfg.enabled) == 0 then cfg = {} end
    local lc = list_categories(vanilla.configs)
    plan.listCategory = lc

    for name, c in pairs(vanilla.configs) do
        if not M.skipped(name) then
            local cat = M.category(name)
            local find, amount = setting(cfg, cat, "Find"), setting(cfg, cat, "Amount")
            if M.is_container_table(name) then find, amount = 1, 1 end
            local rows = {}
            -- Big game carcasses: raw meat by its own multiplier (a red deer
            -- carries 40-60 kg of meat; vanilla gives 1-2 pieces, user 2026-10-17).
            local big = cat == "animals" and (name:find("Bear") or name:find("Bison") or name:find("Boar")
                or name:find("Moose") or name:find("Muskox") or name:find("Deer") or name:find("Elk") or name:find("Doe"))
            for i, e in ipairs(c.static or {}) do
                local item, lo, hi = e.item, e.lo, e.hi
                local newItem = item
                local a = amount
                if cat == "animals" then
                    local it = tostring(item)
                    if big and it:find("Meat") then
                        a = tonumber(cfg.animalsMeatBigGame) or amount
                    elseif it:find("Pelt") or it:find("Hide") or it:find("Fur") or it:find("Fat") then
                        -- One hide per animal; fat as vanilla (the 1.5x rounded
                        -- a single pelt up to 2, user 2026-10-17).
                        a = 1.0
                    elseif name:find("Rabbit") or name:find("Hare") or name:find("Rat") or name:find("Fox") then
                        a = 1.0      -- small game stays vanilla
                    end
                end
                local f = find
                -- Food outside animals is scarce (user 2026-10-18: "nuke food").
                if cat ~= "animals" and M.is_food(item) then f = find * (tonumber(cfg.foodFind) or 1.0) end
                local nl, nh = M.range(lo, hi, f, a)
                rows[i] = { item = item, lo = lo, hi = hi, newItem = newItem, newLo = nl, newHi = nh }
            end
            plan.configs[name] = { category = cat, static = rows, random = c.random or {},
                                   container = M.is_container_table(name) }
        end
    end

    for name, entries in pairs(vanilla.lists) do
        local cat = lc[name]
        local rows = {}
        for i, e in ipairs(entries) do
            local nl, nh = e.lo, e.hi
            local food = cat ~= "animals" and M.is_food(e.item)
            if cat or food then
                local find = cat and setting(cfg, cat, "Find") or 1.0
                -- Hostile humans rarely carry food or drinks (medication excluded).
                if cat == "enemies" and M.is_food(e.item) then
                    find = find * (tonumber(cfg.enemyFoodFind) or 1.0)
                end
                -- Food outside animals is scarce everywhere, containers included.
                if food then find = find * (tonumber(cfg.foodFind) or 1.0) end
                nl, nh = M.range(e.lo, e.hi, find, cat and setting(cfg, cat, "Amount") or 1.0)
            end
            rows[i] = { item = e.item, w = e.w, lo = e.lo, hi = e.hi, newLo = nl, newHi = nh }
        end
        plan.lists[name] = { category = cat, entries = rows }
    end

    for name, e in pairs(vanilla.singles or {}) do
        local cat = M.category(name)
        local nl, nh = M.range(e.lo, e.hi, setting(cfg, cat, "Find"), setting(cfg, cat, "Amount"))
        plan.singles[name] = { category = cat, item = e.item, lo = e.lo, hi = e.hi, newLo = nl, newHi = nh }
    end
    return plan
end

-- Random encounters: every `interval` seconds a location rolls one encounter
-- from its weighted list. Human encounters per minute ~ humanShare / interval.
-- Returns a new interval and weights so human encounters happen `human` times
-- as often and animal/other encounters `other` times as often as vanilla.
-- entries = { {human = bool, w = weight} }
function M.encounters(entries, interval, human, other)
    local hw, ow = 0, 0
    for _, e in ipairs(entries) do
        if e.human then hw = hw + e.w else ow = ow + e.w end
    end
    local total = hw + ow
    if total <= 0 or interval <= 0 or human <= 0 and other <= 0 then return interval, nil end
    local s = hw / total
    local k = human * s + other * (1 - s)          -- overall encounter rate factor
    if k <= 0 then return interval, nil end
    local s2 = human * s / k                       -- new human share of the list
    local f = 1                                    -- factor on human weights
    if s > 0 and s < 1 then f = (s2 * (1 - s)) / (s * (1 - s2)) end
    local weights = {}
    for i, e in ipairs(entries) do weights[i] = e.human and e.w * f or e.w end
    return interval / k, weights
end

------------------------------------------------------------------ container profiles
local function matches(pats, cls)
    for _, p in ipairs(pats or {}) do
        if cls:find(p) then return true end
    end
    return false
end

function M.profile_for(profiles, cls)
    for _, p in ipairs(profiles or {}) do
        if matches(p.match, cls) then return p end
    end
    return nil
end

-- Mean amount of one pick from a list (an untouched container's pick always
-- gives at least 1).
function M.list_mean(entries)
    local tw, sum = 0, 0
    for _, e in ipairs(entries or {}) do
        local lo, hi = math.max(e.lo, 1), math.max(e.hi, 1)
        if hi < lo then hi = lo end
        tw = tw + e.w
        sum = sum + e.w * (lo + hi) / 2
    end
    return tw > 0 and sum / tw or 0
end

-- Expected items in one search of a container with this profile, given the
-- vanilla items-per-search of its loot table. Returns expected items and the
-- chance the search finds anything.
function M.profile_expected(p, vanilla_items, lists)
    local inside = p.replace and 0 or (p.keep or 1) * vanilla_items
    for _, k in ipairs(p.picks or {}) do
        local per = k.stackMin and (k.stackMin + (k.stackMax or k.stackMin)) / 2 or M.list_mean(lists[k.list])
        inside = inside + (k.chance or 1) * (k.min + k.max) / 2 * per
    end
    for _, x in ipairs(p.extras or {}) do
        inside = inside + (x.chance or 1) * (x.min + x.max) / 2
    end
    local u = p.untouched or 1
    return u * inside, inside > 0 and u or 0
end

-- Rolls the extra items for an untouched container. rand(a, b) = whole number
-- in [a, b]; rand() = float in [0, 1). Returns { {item, amount} }.
function M.profile_roll(p, lists, rand)
    local out = {}
    for _, k in ipairs(p.picks or {}) do
        local entries = lists[k.list]
        if entries and #entries > 0 and rand() < (k.chance or 1) then
            local tw = 0
            for _, e in ipairs(entries) do tw = tw + e.w end
            for _ = 1, rand(k.min, k.max) do
                local r, pick = rand() * tw, entries[#entries]
                for _, e in ipairs(entries) do
                    r = r - e.w
                    if r < 0 then pick = e break end
                end
                local lo, hi = math.max(pick.lo, 1), math.max(pick.hi, 1)
                if k.stackMin then lo, hi = k.stackMin, k.stackMax or k.stackMin end  -- profile stack size
                out[#out + 1] = { item = pick.item, amount = rand(lo, math.max(lo, hi)) }
            end
        end
    end
    for _, x in ipairs(p.extras or {}) do
        if rand() < (x.chance or 1) then out[#out + 1] = { item = x.item, amount = rand(x.min, x.max) } end
    end
    return out
end

return M
