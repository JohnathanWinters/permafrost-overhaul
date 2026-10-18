-- EnemyDrops module of the Overhaul. Hostile humans drop what they carried:
-- the gun in their hands (worn, like the game's own drops) and 1 to 3 cloth
-- (they wear clothes). Needs the loot tables only to find item references
-- (shared lootdata library), not the Loot module.
-- Settings: Enemies section of config.lua. Log tag [PF EnemyDrops].
local TAG = "[PF EnemyDrops] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, full, resolve, game_loop, game_later = LIB.try, LIB.valid, LIB.fname, LIB.full, LIB.resolve, LIB.game_loop, LIB.game_later
local ROOT = REBALANCE_ROOT or ""
local DATA = REBALANCE_SHARED("lootdata")
local short, soft_path, each_elem, soft_ref, item_entry = DATA.short, DATA.soft_path, DATA.each_elem, DATA.soft_ref, DATA.item_entry
local item_soft = DATA.item_soft

------------------------------------------------------------------ config
local DEFAULTS = {
    { "enemyGunDrop",     1.0, 0.0, "chance an armed hostile human drops its gun (vanilla: only IZG, ~3%)" },
    { "enemyClothChance", 0.7, 0.0, "chance a hostile human drops cloth (they wear clothes)" },
    { "enemyClothMin",    1,   0,   "cloth dropped, lowest" },
    { "enemyClothMax",    3,   0,   "cloth dropped, highest" },
    { "enemyGunWearMin",  10,  10,  "dropped gun condition, lowest %" },
    { "enemyGunWearMax",  50,  50,  "dropped gun condition, highest %" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\EnemyDrops.lua", "r")  -- generated from config.lua by the loader
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "EnemyDrops.lua", "t", {})
    local user = chunk and try(chunk)
    if type(user) == "table" then
        for _, d in ipairs(DEFAULTS) do
            local v = tonumber(user[d[1]])
            if v then cfg[d[1]] = math.max(0, math.min(100, v)) end
        end
    end
    return cfg
end
local CFG = load_config()

------------------------------------------------------------------ drops
local function is_hostile_npc(cls)
    for _, h in ipairs({ "RifleMan", "MoonCult", "Combatant", "Militant", "Cultist", "Bandit", "Hostile" }) do
        if cls:find(h, 1, true) then return true end
    end
    return false
end
local gun_logged = 0
local function norm(s) return (s or ""):lower():gsub("[%-_ ]", "") end

-- Enemies hold enemy-only weapon actors (e.g. BP_EnemyCrudeBow_C) with no
-- known link to the pickup item (2026-10-17). Look for any field on the
-- weapon that points at a weapon item; failing that, match the class name
-- to a known weapon item (BP_EnemyCrudeBow -> DA_Weapon_Firearms_CrudeBow).
-- Every weapon item names the enemy-only actor class that uses it
-- (UItemConfig_Weapon.EnemyWeaponClass). Weapon items are loaded once at
-- startup (they are small) and mapped enemy class -> item name.
local enemy_weapon_item = nil
local function build_enemy_weapon_map()
    if enemy_weapon_item or next(item_soft) == nil then return end
    enemy_weapon_item = {}
    local n = 0
    for name, src in pairs(item_soft) do
        if name:find("^DA_Weapon") then
            local path = src.soft
            local cfg = path and (try(function() return StaticFindObject(path) end))
            if not valid(cfg) and path then cfg = try(function() return LoadAsset(path) end) end
            if valid(cfg) then
                local ec = try(function() return cfg.EnemyWeaponClass end)
                local ecn = ec and (valid(ec) and fname(ec) or short(soft_path(ec)))
                if ecn and ecn ~= "?" and ecn ~= "None" then
                    enemy_weapon_item[(ecn:gsub("_C$", ""))] = name
                    n = n + 1
                end
            end
        end
    end
    log(string.format("enemy weapons mapped to items: %d", n))
end

-- Built right after the loot tables are read at startup, not at the first
-- kill: loading the weapon items mid-fight would hitch.
DATA.on_scan(function(_, _, first) if first then build_enemy_weapon_map() end end)

local function item_from_weapon_actor(w)
    build_enemy_weapon_map()
    enemy_weapon_item = enemy_weapon_item or {}
    local wcls = (fname(try(function() return w:GetClass() end) or {}):gsub("_C$", ""))
    if enemy_weapon_item[wcls] then return enemy_weapon_item[wcls], nil end
    local cls = try(function() return w:GetClass() end)
    local found = nil
    local guard = 0
    while valid(cls) and not found and guard < 8 do
        try(function()
            cls:ForEachProperty(function(prop)
                if found then return end
                local name = try(function() return prop:GetFName():ToString() end)
                local v = name and try(function() return w[name] end)
                if v ~= nil and type(v) ~= "number" and type(v) ~= "boolean" and type(v) ~= "string" then
                    local n = valid(v) and fname(v) or short(soft_path(v))
                    if n and n:find("^DA_Weapon") then found = { n, v } end
                end
            end)
        end)
        cls = try(function() return cls:GetSuperStruct() end)
        guard = guard + 1
    end
    if found then return found[1], found[2] end
    local key = norm((fname(w):gsub("_C_%d+$", ""):gsub("_C$", ""):gsub("^BP_Enemy", ""):gsub("^BP_", "")))
    if key == "" then return nil, nil end
    local best = nil
    for name in pairs(item_soft) do
        if name:find("^DA_Weapon") then
            local tail = norm(name:gsub("^DA_Weapon_Firearms_", ""):gsub("^DA_Weapon_", ""))
            if tail == key then return name, nil end
            if not best and (tail:find(key, 1, true) or key:find(tail, 1, true)) then best = name end
        end
    end
    return best, nil
end

local function weapon_item(npc)
    -- Held weapon first, then the weapon pool's entries.
    local w = try(function() return npc.AIWeapon end)
    if valid(w) then
        local name, raw = item_from_weapon_actor(w)
        if gun_logged < 5 then log("gun drop: " .. fname(w) .. " -> " .. tostring(name)) end
        if name then return name, raw end
    end
    local found = nil
    each_elem(try(function() return npc.WeaponPool end), function(_, s)
        if found then return end
        local v = try(function() return s.ItemBase end)
        local name = v and (valid(v) and fname(v) or short(soft_path(v)))
        if gun_logged < 3 then log("gun drop: WeaponPool entry " .. tostring(name)) end
        if name and name ~= "?" then found = { name, v } end
    end)
    if found then return found[1], found[2] end
    return nil, nil
end

local hook_logged = 0
local function give_cloth(npc, inv)
    if math.random() >= (tonumber(CFG.enemyClothChance) or 0) then return end
    local lo, hi = math.floor(CFG.enemyClothMin or 0), math.floor(CFG.enemyClothMax or 0)
    if hi < 1 then return end
    local n = math.random(math.max(1, lo), math.max(1, lo, hi))
    local sp = soft_ref("DA_Resource_Cloth")
    local ok = sp and try(function() inv:AddItemAmount({ Item = sp, Amount = n }, false, false); return true end)
    if hook_logged <= 10 then log(string.format("enemy cloth: %s +%d (%s)", fname(npc), n, ok and "added" or "FAILED")) end
end

local dropped = {}
local inv_class = nil
local function npc_inventory(npc)
    local inv = try(function() return npc.AIInventory end)
    if valid(inv) then return inv end
    -- Since 2026-10-17: AIInventory reads empty on dead cultists; their loot
    -- sits on an InventoryComponent (seen in the F8 census).
    inv_class = inv_class or try(function() return StaticFindObject("/Script/Permafrost.InventoryComponent") end)
    inv = valid(inv_class) and try(function() return npc:GetComponentByClass(inv_class) end)
    return valid(inv) and inv or nil
end

local function give_gun(npc)
    local key = full(npc)
    if dropped[key] then return end
    dropped[key] = true
    local inv = npc_inventory(npc)
    hook_logged = hook_logged + 1
    if hook_logged <= 10 then
        log(string.format("enemy loot generated: %s, inventory %s", fname(npc), valid(inv) and fname(inv) or "MISSING"))
    end
    if not valid(inv) then return end
    local cls = try(function() return npc:GetClass():GetFName():ToString() end) or ""
    if is_hostile_npc(cls) then give_cloth(npc, inv) end
    if math.random() >= (tonumber(CFG.enemyGunDrop) or 0) then return end
    local name, raw = weapon_item(npc)
    gun_logged = gun_logged + 1
    if not name then
        if gun_logged <= 5 then log("gun drop: no weapon found on " .. fname(npc)) end
        return
    end
    local sp = raw or soft_ref(name)     -- the enemy's own reference first: no load
    local have = try(function() return inv:GetItemQuantity(sp) end)
    if tonumber(have) and have > 0 then return end
    local added = try(function() return inv:AddItemAmount({ Item = sp, Amount = 1 }, false, false) end)
    -- Worn condition, like the game's own gun drops.
    local slots = tonumber(try(function() return inv:GetNumOfSlots() end)) or 0
    local wear = math.random(math.floor(CFG.enemyGunWearMin), math.max(math.floor(CFG.enemyGunWearMin), math.floor(CFG.enemyGunWearMax)))
    for i = 0, slots - 1 do
        local item = try(function() return inv:GetItemInSlot(i) end)
        local e = item_entry(item)
        if e and e.item == name then
            try(function() item.Durability = wear end)
        end
    end
    if gun_logged <= 10 then
        log(string.format("gun drop: %s -> %s (added %s, condition %d%%)", fname(npc), name, tostring(added), wear))
    end
end

-- GenerateLoot is called natively and the hook never fired in game
-- (2026-10-17, several kills). So hostile humans are tracked from creation
-- and handled the moment bIsDead turns true.
local tracked = {}
REBALANCE_ON_ACTOR("/Script/Permafrost.BaseAICharacter", function(obj)
    local n = full(obj)
    if n:find("Default__") then return end
    tracked[#tracked + 1] = n
end)
local death_logged = 0
local function death_watch()
    local keep = {}
    for _, path in ipairs(tracked) do
        local npc = resolve(path)
        if npc then
            local cls = try(function() return npc:GetClass():GetFName():ToString() end) or ""
            if is_hostile_npc(cls) then
                local dead = try(function() return npc.bIsDead end)
                if dead == true then
                    if death_logged < 10 then
                        death_logged = death_logged + 1
                        log("enemy died: " .. fname(npc))
                    end
                    -- Short delay so the game's own corpse loot is in first.
                    game_later(400, function()
                        local body = resolve(path)
                        if not body then return end
                        local ok, err = pcall(give_gun, body)
                        if not ok then log("gun drop error: " .. tostring(err)) end
                    end)
                else
                    keep[#keep + 1] = path
                end
            end
        end
    end
    tracked = keep
end
game_loop(1000, function()
    local ok, err = pcall(death_watch)
    if not ok then log("death watch error: " .. tostring(err)) end
end)

DATA.start()

log(string.format("loaded: gun drop %.0f%%, cloth %.0f%%", CFG.enemyGunDrop * 100, CFG.enemyClothChance * 100))
