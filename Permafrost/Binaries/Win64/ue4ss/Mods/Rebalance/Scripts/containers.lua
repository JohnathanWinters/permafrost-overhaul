-- Containers module of the Overhaul. Most searchable containers have
-- already been picked clean; the rare untouched one holds what the real
-- thing would (profiles: Containers list in config.lua). Food stays scarce
-- in untouched containers too (Loot.foodFind). Needs the loot tables only to
-- read item lists and references (shared lootdata library), not the Loot
-- module.
-- Settings: Containers list + Loot.containerProfiles / Loot.foodFind.
-- Log tag [PF Containers].
local TAG = "[PF Containers] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, full, resolve, game_loop, game_later = LIB.try, LIB.valid, LIB.full, LIB.resolve, LIB.game_loop, LIB.game_later
local ROOT = REBALANCE_ROOT or ""
local DATA = REBALANCE_SHARED("lootdata")
local rules = REBALANCE_SHARED("rules")
local soft_path, soft_ref, item_entry = DATA.soft_path, DATA.soft_ref, DATA.item_entry
local vanilla = DATA.vanilla

------------------------------------------------------------------ config
local function read_table(file)
    local f = io.open(ROOT .. "config\\" .. file, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, file, "t", {})
    local t = chunk and try(chunk)
    return type(t) == "table" and t or nil
end
local LOOT = read_table("Loot.lua") or {}
local CFG = {
    containerProfiles = tonumber(LOOT.containerProfiles) or 1,
    foodFind = tonumber(LOOT.foodFind) or 0.15,
}

------------------------------------------------------------------ containers
-- The game rolls a container's loot the moment it is first opened (verified
-- 2026-10-17: every unopened container reads empty). So containers near the
-- player are watched; when one is opened (bEverOpened flips, or items appear)
-- it is decided once: looted (cleared) or untouched (game roll x keep +
-- profile picks/extras). Containers already opened when first seen (earlier
-- sessions) and quest containers are left alone.
local PROFILES = {}
do
    local f = io.open(ROOT .. "config\\Containers.lua", "r")
    if f then
        local text = f:read("*a")
        f:close()
        local chunk = load(text, "containers.lua", "t", {})
        local t = chunk and try(chunk)
        if type(t) == "table" then PROFILES = t end
    end
    log(string.format("container profiles: %d", #PROFILES))
end

-- Through the component's own GetItemInSlot only: the raw Items_ array can
-- still hold items the game already freed after ClearInventory.
local function inv_items(inv)
    local items = {}
    local slots = tonumber(try(function() return inv:GetNumOfSlots() end)) or 0
    for i = 0, slots - 1 do
        local e = item_entry(try(function() return inv:GetItemInSlot(i) end))
        if e then items[#items + 1] = e end
    end
    return items
end

local function items_sig(items)
    local parts = {}
    for _, it in ipairs(items) do parts[#parts + 1] = it.item .. "=" .. it.amount end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ",") or "empty"
end

local missing_logged = {}
local function add_item(inv, item, amount)
    if amount <= 0 then return false end
    local sp = soft_ref(item, true)
    if not sp then
        if not missing_logged[item] then missing_logged[item] = true log("no item reference for " .. tostring(item)) end
        return false
    end
    return pcall(function() return inv:AddItemAmount({ Item = sp, Amount = amount }, false, false) end)
end

local cont_logged = 0
local stats_c = { looted = 0, untouched = 0, skipped = 0 }
local function rand(a, b)
    if a == nil then return math.random() end
    if b < a then b = a end
    return math.random(math.floor(a), math.floor(b))
end

-- A container that was still locked when first seen has never been looted
-- (user 2026-10-18): it is always untouched. Once opened it is decided and
-- never touched again, so it stays empty after you take the loot.
local padlock_class = nil
-- Locations of locked padlocks (plain numbers), rebuilt at most every 2 s:
-- a streamed-in area brings hundreds of containers at once.
local lock_cache, lock_cache_at = {}, -1
local function locked_padlocks()
    local now = os.clock()
    if now - lock_cache_at < 2 then return lock_cache end
    lock_cache_at = now
    lock_cache = {}
    for _, pl in ipairs(try(function() return FindAllOf("Padlock") end) or {}) do
        if valid(pl) and LIB.get(pl, "bLocked") == true then
            local o = LIB.call(pl, "GetOwner")
            local ol = valid(o) and LIB.call(o, "K2_GetActorLocation")
            if ol then lock_cache[#lock_cache + 1] = { ol.X, ol.Y, ol.Z } end
        end
    end
    return lock_cache
end

-- Its own padlock, or a locked padlock on another actor within 1.5 m (some
-- boxes keep the lock on a separate actor next to the container).
local function is_locked(a)
    padlock_class = padlock_class or try(function() return StaticFindObject("/Script/Permafrost.Padlock") end)
    local lock = valid(padlock_class) and try(function() return a:GetComponentByClass(padlock_class) end)
    if valid(lock) then return try(function() return lock.bLocked end) == true end
    local l = LIB.call(a, "K2_GetActorLocation")
    if not l then return false end
    local x, y, z = l.X, l.Y, l.Z
    for _, p in ipairs(locked_padlocks()) do
        if (p[1] - x) ^ 2 + (p[2] - y) ^ 2 + (p[3] - z) ^ 2 < 150 * 150 then return true end
    end
    return false
end

local function process_container(a, was_locked)
    local cls = try(function() return a:GetClass():GetFName():ToString() end) or "?"
    local profile = rules.profile_for(PROFILES, cls)
    if not profile then return end
    local inv = try(function() return a.Inventory end)
    if not valid(inv) then return end
    local before = inv_items(inv)
    local sig = items_sig(before)
    local untouched = was_locked or math.random() < (profile.untouched or 1)
    if not untouched then
        try(function() inv:ClearInventory() end)
        stats_c.looted = stats_c.looted + 1
    else
        stats_c.untouched = stats_c.untouched + 1
        local rolled = rules.profile_roll(profile, vanilla.lists, rand)
        -- No physical limit: grow the container so every rolled item fits.
        local slots = tonumber(try(function() return inv:GetNumOfSlots() end)) or 0
        local need = #before + #rolled + 2
        if slots < need then try(function() inv:SetNumOfSlots(need) end) end
        local keep = profile.keep or 1
        if profile.replace then
            -- The profile's list is the whole content: drop the game's roll.
            try(function() inv:ClearInventory() end)
        else
            for _, it in ipairs(before) do
                local extra = math.floor(it.amount * keep + 0.5) - it.amount
                if extra > 0 and not rules.is_food(it.item) then add_item(inv, it.item, extra) end
            end
        end
        local food_keep = tonumber(CFG.foodFind) or 1.0
        for _, r in ipairs(rolled) do
            -- Profile picks roll vanilla lists: food is thinned here too.
            if not (rules.is_food(r.item) and math.random() >= food_keep) then add_item(inv, r.item, r.amount) end
        end
    end
    local after = untouched and items_sig(inv_items(inv)) or "empty"
    if cont_logged < 25 then
        cont_logged = cont_logged + 1
        log(string.format("container %s (%s): %s; before [%s] after [%s]", cls, profile.name,
            was_locked and "UNTOUCHED (was locked)" or (untouched and "UNTOUCHED" or "looted"), sig, after))
    end
end

-- watch[full name] = { actor, loc, state } for unopened containers.
local watch, ignored, pending = {}, {}, {}
-- Searchable containers derive from the native AInteractionBase; new ones are
-- queued as they are created and sorted out on the next pass.
-- Only classes that have a container profile are queued (decided once per
-- class): queuing every interaction object of a streamed area (thousands)
-- and inspecting each cost ~1 s every 6 s (2026-10-17 profile).
REBALANCE_ON_ACTOR("/Script/Permafrost.InteractionBase", function(obj)
    local n = full(obj)
    if not n:find("Default__") then pending[#pending + 1] = n end
end, function(cls) return rules.profile_for(PROFILES, cls) ~= nil end)
local function consider(a, name)
    if watch[name] or ignored[name] then return end
    local cls = try(function() return a:GetClass():GetFName():ToString() end) or ""
    if not valid(try(function() return a.Inventory end)) or try(function() return a.bEverOpened end) == nil then
        ignored[name] = true          -- not a searchable container
        return
    end
    local opened = try(function() return a.bEverOpened end)
    local quest = try(function() return a.QuestStorageID end)
    local quest_path = quest and soft_path(quest)
    -- Locked means never looted, whatever the save says: a box the game
    -- re-locked (it does not save padlocks) is filled again (2026-10-18).
    local locked = is_locked(a)
    if locked then opened = false end
    if opened == true or (quest_path and quest_path ~= "" and quest_path ~= "None") or not rules.profile_for(PROFILES, cls) then
        ignored[name] = true
        stats_c.skipped = stats_c.skipped + 1
    else
        -- Plain numbers: a struct returned by a game call must not be kept
        -- past the call (suspected cause of a crash inside UE4SS, 2026-10-17).
        local v = LIB.call(a, "K2_GetActorLocation")
        watch[name] = { loc = v and { X = v.X, Y = v.Y, Z = v.Z } or nil, locked = locked }
    end
end
local first_scan = true
local function container_pass()
    if tonumber(CFG.containerProfiles) ~= 1 or #PROFILES == 0 then return end
    if not DATA.ready() then return end              -- loot tables not read yet
    if first_scan then
        -- Once, for containers that existed before the mod started watching.
        first_scan = false
        for _, a in ipairs(FindAllOf("BP_SearchableStorage_C") or {}) do consider(a, full(a)) end
    end
    -- At most ~4 ms per pass; the rest waits for the next one.
    local queue = pending
    pending = {}
    local t0 = os.clock()
    for i, name in ipairs(queue) do
        if os.clock() - t0 > 0.004 then
            for j = i, #queue do pending[#pending + 1] = queue[j] end
            break
        end
        local a = resolve(name)
        if a then consider(a, name) end
    end
end

-- Every 100 ms: containers within 10 m of the player; process the one that
-- was just opened as soon as its loot is in (or 0.3 s after it opened empty).
local helpers_mod = nil
local function player_loc()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local helpers = helpers_mod
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and try(function() return pc.Pawn end)
    return valid(pawn) and try(function() return pawn:K2_GetActorLocation() end) or nil
end

-- Containers within 50 m, rebuilt every 2 s; the 100 ms pass only checks
-- those (checking every watched container each pass grew with the list:
-- ~2 ms per pass after a while, 2026-10-17 profile).
local near, next_near = {}, 0
local function open_watch()
    if next(watch) == nil then return end
    local p = player_loc()
    if not p then return end
    local now = os.clock()
    if now >= next_near then
        next_near = now + 2
        near = {}
        for name, w in pairs(watch) do
            local l = w.loc
            if l and (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 < 5000 * 5000 then near[name] = w end
        end
    end
    for name, w in pairs(near) do
        if not watch[name] then near[name] = nil goto continue end
        local l = w.loc
        if l and (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 < 1000 * 1000 then
            local actor = resolve(name)
            if not actor then
                watch[name] = nil
            else
                local opened = try(function() return actor.bEverOpened end) == true
                local inv = opened and try(function() return actor.Inventory end)
                local occupied = inv and valid(inv) and tonumber(try(function() return inv:GetNumOfOccupiedSlots() end)) or 0
                local has = inv and valid(inv) and (occupied > 0 or #inv_items(inv) > 0)
                if opened then w.ticks = (w.ticks or 0) + 1 end
                -- Loot lands when the search finishes; give it up to 10 s.
                if has or (opened and w.ticks >= 100) then
                    watch[name] = nil
                    ignored[name] = true
                    local ok, err = pcall(process_container, actor, w.locked)
                    if not ok then log("container error: " .. tostring(err)) end
                end
            end
        end
        ::continue::
    end
end

local last_stats = ""
game_loop(30000, function()
    local n = 0
    for _ in pairs(watch) do n = n + 1 end
    local s = string.format("containers opened: %d looted, %d untouched; %d watched, %d skipped (opened before, quest or no profile)",
        stats_c.looted, stats_c.untouched, n, stats_c.skipped)
    if s ~= last_stats then last_stats = s log(s) end
end)

------------------------------------------------------------------ start
math.randomseed(os.time())
DATA.start()
game_later(4000, function()
    game_loop(6000, function()
        local ok, err = pcall(container_pass)
        if not ok then log("container pass error: " .. tostring(err)) end
    end)
end)
game_loop(100, function()
    local ok, err = pcall(open_watch)
    if not ok then log("open watch error: " .. tostring(err)) end
end)

log("loaded")
