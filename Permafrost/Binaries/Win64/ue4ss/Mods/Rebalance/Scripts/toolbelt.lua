-- Toolbelt module of the Rebalance mod (2026-10-17).
-- 1. A tool anywhere in your hotbar counts as held: with a knife in the
--    hotbar you can hold F to skin animals and open electrical boxes.
-- 2. Any knife can open what needs a knife (electrical boxes, knife locks),
--    whatever its tier. Each tier the knife is short costs extra durability,
--    charged once the target actually opens. A knife without enough
--    durability left for the job is refused, like in vanilla.
-- How: the game asks UInteractionFunctionLibrary::IsHeldToolCompatible(Actor,
-- HeldToolType, HeldToolTier) with the HELD item's tool. A pre-hook asks the
-- target what it needs (IToolRequirementInterface) and passes the best
-- matching knife's type and tier instead (raised to the requirement when the
-- shiv rule applies). Settings: Toolbelt section of config.lua.
local TAG = "[PF Toolbelt] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, path_of, resolve, game_loop, game_later = LIB.try, LIB.valid, LIB.fname, LIB.path_of, LIB.resolve, LIB.game_loop, LIB.game_later

local ROOT = REBALANCE_ROOT or ""

------------------------------------------------------------------ config
-- { key, default, vanilla, description }
local DEFAULTS = {
    { "enabled",         1, 0, "1 = tools in the hotbar count as held for interactions" },
    { "knife",           1, 0, "knife: skinning, electrical boxes" },
    { "crowbar",         0, 0, "crowbar: pried-open containers and doors" },
    { "axe",             0, 0, "axe" },
    { "pickaxe",         0, 0, "pickaxe" },
    { "key",             0, 0, "keys: locked doors and containers" },
    { "anyKnifeTier",    1, 0, "1 = any knife opens what needs a knife; a lower tier costs durability" },
    { "knifeBaseCost",   2, 0, "durability % an under-tier knife uses per opening" },
    { "knifeCostPerTier", 8, 0, "extra durability % per tier step the knife is below the requirement" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Toolbelt.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Toolbelt.lua", "t", {})
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
if CFG.enabled ~= 1 then
    log("off")
    return
end

------------------------------------------------------------------ enums
local TOOL = {}
local function read_enum(path, fn)
    local e = try(function() return StaticFindObject(path) end)
    if not valid(e) then return false end
    try(function()
        e:ForEachName(function(name, value)
            local n = (type(name) == "string" and name) or try(function() return name:ToString() end) or ""
            fn(n:match("ETT_(%w+)$") or n, tonumber(value))
        end)
    end)
    return true
end
local allowed = {}
local function build_allowed()
    allowed = {}
    for _, t in ipairs({ "knife", "crowbar", "axe", "pickaxe", "key" }) do
        if CFG[t] == 1 and TOOL[t] then allowed[TOOL[t]] = t end
    end
end

------------------------------------------------------------------ the player's tools
local helpers = nil
local equip_name = nil
local function player_equipment()
    helpers = helpers or try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and try(function() return pc.Pawn end)
    if not valid(pawn) then return nil end
    if equip_name then
        local c = try(function() return pawn[equip_name] end)
        if valid(c) then return c end
    end
    for _, n in ipairs({ "Equipment Component", "EquipmentComponent", "Equipment" }) do
        local c = try(function() return pawn[n] end)
        if valid(c) then equip_name = n return c end
    end
    return nil
end

local function item_tool(item)
    local cfgobj = try(function() return item.Config end)
    if cfgobj and not valid(cfgobj) then cfgobj = try(function() return cfgobj:GetWeakPtr():Get() end) end
    if not valid(cfgobj) then return nil end
    return tonumber(try(function() return cfgobj.ToolType end)),
           tonumber(try(function() return cfgobj.ToolTier end)) or 0,
           fname(cfgobj)
end

-- Every tool of this type in hand or hotbar: { tier, durability, slot, name }.
-- Read through GetItemInSlot only (never the raw item array).
-- Every inventory on the player: the equipment component plus every
-- InventoryComponent on the pawn (the hotbar is one of them). Only the
-- equipment slots were scanned before, so a knife in the hotbar was not
-- found unless it was in hand (2026-10-17).
local inv_class = nil
local function player_inventories()
    local equip = player_equipment()
    if not equip then return {} end
    local list, seen = { equip }, {}
    seen[LIB.address(equip) or 0] = true
    inv_class = inv_class or try(function() return StaticFindObject("/Script/Permafrost.InventoryComponent") end)
    local pawn = LIB.call(equip, "GetOwner")
    local comps = valid(inv_class) and pawn and LIB.call(pawn, "K2_GetComponentsByClass", inv_class)
    if comps then
        try(function()
            comps:ForEach(function(_, e)
                local c = e:get()
                local a = LIB.address(c)
                if a and not seen[a] then seen[a] = true list[#list + 1] = c end
            end)
        end)
    end
    return list
end

local last_found = nil
local function tools_of(tool)
    local out = {}
    for _, inv in ipairs(player_inventories()) do
        local slots = tonumber(LIB.call(inv, "GetNumOfSlots")) or 0
        for i = 0, slots - 1 do
            local item = LIB.call(inv, "GetItemInSlot", i)
            if valid(item) then
                local t, tier, name = item_tool(item)
                if t == tool then
                    out[#out + 1] = { tier = tier, slot = i, name = name, inv = LIB.path_of(inv),
                                      dur = tonumber(LIB.get(item, "Durability")) or 100 }
                end
            end
        end
    end
    local sig = tostring(tool) .. ":" .. #out
    if sig ~= last_found then
        last_found = sig
        local names = {}
        for _, t in ipairs(out) do names[#names + 1] = t.name .. " (" .. (t.inv:match("[%.:]([^%.:]+)$") or "?") .. ")" end
        log(string.format("tool %s: %d found in your inventories%s", tostring(tool), #out,
            #names > 0 and (": " .. table.concat(names, ", ")) or ""))
    end
    return out
end

------------------------------------------------------------------ durability charge
-- pending[target path] = { slot, name, cost, opened0, until }
local pending = {}
local logged = 0
local padlock_class = nil
local padlock_of            -- defined below
local function target_opened(actor)
    if try(function() return actor.bEverOpened end) == true then return true end
    -- Locked things (electrical boxes) open when their padlock wears to 0.
    local lock = padlock_of(actor)
    if not lock then return false end
    local left = tonumber(try(function() return lock:GetPercentLockDurability() end))
    return left ~= nil and left <= 0
end

local function charge(p)
    local inv = p.inv and LIB.resolve(p.inv)
    local item = inv and LIB.call(inv, "GetItemInSlot", p.slot)
    if not valid(item) then return end
    local _, _, name = item_tool(item)
    if name ~= p.name then return end
    local d = tonumber(try(function() return item.Durability end))
    if not d then return end
    local nd = math.max(0, d - p.cost)
    try(function() item.Durability = nd end)
    if logged < 20 then
        logged = logged + 1
        log(string.format("%s used: durability %.0f%% -> %.0f%% (cost %.0f%%)", name, d, nd, p.cost))
    end
end

game_loop(250, function()
    local now = os.clock()
    for path, p in pairs(pending) do
        local actor = resolve(path)
        if not actor or now > p.expires then
            pending[path] = nil
        elseif target_opened(actor) and not p.opened0 then
            pending[path] = nil
            pcall(charge, p)
        end
    end
end)

------------------------------------------------------------------ hook
-- What a target needs: the interface call on the actor first, then the
-- padlock component's own properties (found by name once: the property
-- holding "Tool" + "Type", and the one holding "Tier").
local lock_props = nil
padlock_of = function(actor)
    padlock_class = padlock_class or try(function() return StaticFindObject("/Script/Permafrost.Padlock") end)
    local lock = valid(padlock_class) and try(function() return actor:GetComponentByClass(padlock_class) end)
    return valid(lock) and lock or nil
end
local function requirement(actor, lock)
    local need = tonumber(try(function() return actor:GetRequiredToolType() end))
    local tier = tonumber(try(function() return actor:GetRequiredToolTier() end))
    if need then return need, tier or 0, "interface" end
    lock = lock or padlock_of(actor)
    if not lock then return nil, nil, "none" end
    if not lock_props then
        lock_props = {}
        local names = {}
        try(function()
            padlock_class:ForEachProperty(function(prop)
                local n = try(function() return prop:GetFName():ToString() end) or ""
                names[#names + 1] = n
                local l = n:lower()
                if l:find("tool") and l:find("type") and not lock_props.type then lock_props.type = n end
                if l:find("tier") and not lock_props.tier then lock_props.tier = n end
            end)
        end)
        log("padlock properties: " .. table.concat(names, ", ") .. " -> type " .. tostring(lock_props.type)
            .. ", tier " .. tostring(lock_props.tier))
    end
    need = lock_props.type and tonumber(try(function() return lock[lock_props.type] end))
    tier = lock_props.tier and tonumber(try(function() return lock[lock_props.tier] end))
    return need, tier or 0, "padlock"
end

local diag = 0
local function decide(actor, type_p, tier_p, lock, label)
    if next(allowed) == nil then return end
    if not valid(actor) then return end
    local need, need_tier, how = requirement(actor, lock)
    local tools = need and allowed[need] and tools_of(need) or {}
    if diag < 12 then
        diag = diag + 1
        log(string.format("%s on %s: needs tool %s tier %s (%s); hand passes %s/%s; %d matching tools in hotbar",
            label or "check", fname(actor), tostring(need), tostring(need_tier), how,
            tostring(try(function() return type_p:get() end)), tostring(try(function() return tier_p:get() end)), #tools))
    end
    if not need or not allowed[need] then return end
    if #tools == 0 then return end

    -- Best tool that meets the tier outright (highest tier).
    local best_ok = nil
    for _, t in ipairs(tools) do
        if t.tier >= need_tier and (not best_ok or t.tier > best_ok.tier) then best_ok = t end
    end
    if best_ok then
        try(function() type_p:set(need) end)
        try(function() tier_p:set(best_ok.tier) end)
        return
    end

    -- Shiv rule: a lower-tier knife may still do it, at a durability cost.
    if CFG.anyKnifeTier ~= 1 or allowed[need] ~= "knife" then return end
    local best = nil
    for _, t in ipairs(tools) do
        local cost = CFG.knifeBaseCost + CFG.knifeCostPerTier * math.max(0, need_tier - t.tier)
        if t.dur >= cost and (not best or cost < best.cost) then best = { t = t, cost = cost } end
    end
    if not best then
        local path = path_of(actor)
        if logged < 20 and not pending[path] then
            logged = logged + 1
            log(string.format("%s needs a better knife: no knife has enough durability", fname(actor)))
        end
        return                                  -- vanilla refusal
    end
    try(function() type_p:set(need) end)
    try(function() tier_p:set(need_tier) end)
    local path = path_of(actor)
    if not pending[path] then
        pending[path] = { slot = best.t.slot, inv = best.t.inv, name = best.t.name, cost = best.cost,
                          opened0 = target_opened(actor), expires = os.clock() + 60 }
        if logged < 20 then
            logged = logged + 1
            log(string.format("%s: %s (tier %d, needs %d) allowed, will cost %.0f%% durability",
                fname(actor), best.t.name, best.t.tier, need_tier, best.cost))
        end
    end
end

local function on_check(actor_p, type_p, tier_p)
    decide(try(function() return actor_p:get() end), type_p, tier_p)
end

-- The prompt asks IsHeldToolCompatible, but holding F then calls
-- UPadlock::TryToUnlock(ToolType, ToolTier, Damage) on the lock component,
-- which checks type and tier again (2026-10-17: prompt said unlock, nothing
-- happened with a low-tier knife). Same decision, on the lock's owner.
local function on_unlock(padlock_p, type_p, tier_p)
    local padlock = try(function() return padlock_p:get() end)
    if not valid(padlock) then return end
    decide(try(function() return padlock:GetOwner() end), type_p, tier_p, padlock, "unlock")
end

local function start()
    local ok_tool = read_enum("/Script/Permafrost.EToolType", function(n, v) TOOL[n:lower()] = v end)
    if not ok_tool or not TOOL.knife then return false end
    build_allowed()
    local ok = try(function()
        RegisterHook("/Script/Permafrost.InteractionFunctionLibrary:IsHeldToolCompatible", function(ctx, actor_p, type_p, tier_p)
            local ok2, err = pcall(on_check, actor_p, type_p, tier_p)
            if not ok2 and logged < 20 then logged = logged + 1 log("error: " .. tostring(err)) end
        end)
        return true
    end)
    local ok_lock = try(function()
        RegisterHook("/Script/Permafrost.Padlock:TryToUnlock", function(ctx, type_p, tier_p)
            local ok2, err = pcall(on_unlock, ctx, type_p, tier_p)
            if not ok2 and logged < 20 then logged = logged + 1 log("unlock error: " .. tostring(err)) end
        end)
        return true
    end)
    if not ok_lock then log("FAILED to hook Padlock:TryToUnlock (locks still need the right tier in hand)") end
    local names = {}
    for _, n in pairs(allowed) do names[#names + 1] = n end
    log((ok and "on: hotbar counts as held for " or "FAILED to hook IsHeldToolCompatible for ") .. table.concat(names, ", ")
        .. (CFG.anyKnifeTier == 1 and "; any knife tier opens knife locks" or ""))
    return true
end

-- The enums live in the game module, normally loaded before mods; retry once
-- the engine is up in case they are not.
if not start() then
    local tries = 0
    local function retry()
        tries = tries + 1
        if start() or tries > 30 then return end
        game_later(2000, retry)
    end
    game_later(2000, retry)
end

------------------------------------------------------------------ native feed
-- dlls\main.dll detours the native IsHeldToolCompatible (the HUD and the
-- interaction start call it natively, so "invalid tool" showed for skinning
-- and electrical boxes with the knife only in the hotbar, 2026-10-17). It
-- needs the knife's EToolType value and whether one is in the hotbar.
local TOOL_FILE = ROOT .. "dlls\\toolbelt.txt"
local last_tool_text = nil
game_loop(500, function()
    local ok, err = pcall(function()
        if not TOOL.knife or CFG.knife ~= 1 then return end
        local has = #tools_of(TOOL.knife) > 0
        local text = string.format("knife=%d\nhas=%d\nend\n", TOOL.knife, has and 1 or 0)
        if text == last_tool_text then return end
        last_tool_text = text
        local f = io.open(TOOL_FILE .. ".tmp", "wb")
        if not f then return end
        f:write(text)
        f:close()
        os.remove(TOOL_FILE)
        os.rename(TOOL_FILE .. ".tmp", TOOL_FILE)
    end)
    if not ok then log("native feed error: " .. tostring(err)) end
end)
