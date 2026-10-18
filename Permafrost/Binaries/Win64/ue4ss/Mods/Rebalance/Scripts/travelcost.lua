-- TravelCost module of the Overhaul (2026-10-18). User: fast travel should
-- cost food, 1 item for now, from the hotbar before the rest of the
-- inventory, and from the highest hotbar slot down (slot 8 before 7).
-- Every trip (map or travel lamp) ends in the player controller's
-- Server_HandleFastTravelRequest(destination name); the map's confirm calls
-- its own steps natively, so a hook there never fired (2026-10-18). A
-- pre-hook on the request takes 1 food item (any DA_Consumable_* outside
-- Medication: food and drinks) from the player's equipment inventory:
-- quick slots from the highest down, then the remaining slots in order,
-- then any other inventory on the player. Nothing is taken unless the full
-- cost is there. With no food the destination name is blanked, so the game
-- finds no destination and the trip does not happen, and the game's own
-- text notification is shown if a fitting one exists.
-- Settings: TravelCost section of config.lua. Log tag [PF TravelCost].
local TAG = "[PF TravelCost] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname = LIB.try, LIB.valid, LIB.fname
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

local DEFAULTS = {
    { "foodPerTrip", 1, "food items one fast travel costs (0 = free, vanilla)" },
    { "hotbarSlots", 8, "number of hotbar slots (they are taken from first, highest slot first)" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\TravelCost.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "TravelCost.lua", "t", {})
    local user = chunk and try(chunk)
    if type(user) == "table" then
        for _, d in ipairs(DEFAULTS) do
            local v = tonumber(user[d[1]])
            if v then cfg[d[1]] = math.max(0, math.floor(v)) end
        end
    end
    return cfg
end
local CFG = load_config()

------------------------------------------------------------------ inventories
local function player_parts()
    local helpers = try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    if not valid(pawn) then return nil end
    return pc, pawn
end

-- Equipment component first (its first 8 slots are the quick slots), then
-- any other inventory component on the pawn.
local inv_class = nil
local function inventories(pawn)
    local list, seen = {}, {}
    for _, n in ipairs({ "Equipment Component", "EquipmentComponent" }) do
        local e = get(pawn, n)
        if valid(e) then list[1] = e seen[LIB.address(e) or 0] = true break end
    end
    inv_class = inv_class or try(function() return StaticFindObject("/Script/Permafrost.InventoryComponent") end)
    local comps = valid(inv_class) and call(pawn, "K2_GetComponentsByClass", inv_class)
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

local function item_name(item)
    local cfg = get(item, "Config")
    if valid(cfg) then return fname(cfg) end
    local p = cfg and try(function() return cfg:GetObjectID():GetAssetPathName():ToString() end)
    return p and (p:match("([%w_]+)$") or p) or ""
end
local function is_food(name)
    return name:find("^DA_Consumable_") ~= nil and name:find("Medication") == nil
end

-- Food stacks in the order they are used: hotbar from the highest slot
-- down, then the rest of the equipment inventory, then other inventories.
-- Each entry: { inv, slot, item, name, amount }.
local function food_stacks(pawn)
    local out = {}
    for k, inv in ipairs(inventories(pawn)) do
        local n = tonumber(call(inv, "GetNumOfSlots")) or 0
        local order = {}
        if k == 1 then
            local hb = math.min(n, CFG.hotbarSlots)
            for i = hb - 1, 0, -1 do order[#order + 1] = i end
            for i = hb, n - 1 do order[#order + 1] = i end
        else
            for i = 0, n - 1 do order[#order + 1] = i end
        end
        for _, i in ipairs(order) do
            local it = call(inv, "GetItemInSlot", i)
            if valid(it) then
                local name = item_name(it)
                if is_food(name) then
                    out[#out + 1] = { inv = inv, slot = i, item = it, name = name,
                                      amount = tonumber(call(inv, "GetItemAmountInSlot", i)) or tonumber(get(it, "Amount")) or 1 }
                end
            end
        end
    end
    return out
end

-- Takes one from that stack: the game's RemoveItemAmount first; if the count
-- did not drop, a single item is removed by slot.
local function take_one(f)
    call(f.inv, "RemoveItemAmount", { Item = get(f.item, "Config"), Amount = 1 }, false, true)
    local after = tonumber(call(f.inv, "GetItemAmountInSlot", f.slot)) or 0
    local still = call(f.inv, "GetItemInSlot", f.slot)
    if valid(still) and item_name(still) == f.name and after >= f.amount then
        if f.amount <= 1 then
            call(f.inv, "RemoveItem", f.slot, false)
        else
            LIB.set(still, "Amount", f.amount - 1)
        end
    end
end

------------------------------------------------------------------ notification
local notice_value = false   -- ETextNotificationID value to show, nil = none found
local function notify(pc)
    if notice_value == false then
        notice_value = nil
        local e = try(function() return StaticFindObject("/Script/Permafrost.ETextNotificationID") end)
        local names = {}
        if valid(e) then
            try(function()
                e:ForEachName(function(name, value)
                    local n = (type(name) == "string" and name) or try(function() return name:ToString() end) or ""
                    names[#names + 1] = n
                    local l = n:lower()
                    if not notice_value and (l:find("notenough") or l:find("missing") or l:find("requir") or l:find("cannot")) then
                        notice_value = tonumber(value)
                    end
                end)
            end)
        end
        log("text notifications: " .. table.concat(names, ", ") .. " -> using " .. tostring(notice_value))
    end
    if not notice_value then return end
    local uim_class = try(function() return StaticFindObject("/Script/Permafrost.UI_ManagerComponent") end)
    local uim = valid(uim_class) and call(pc, "GetComponentByClass", uim_class)
    if valid(uim) then call(uim, "CLIENT_ShowBasicTextNotification", notice_value) end
end

------------------------------------------------------------------ native link
-- The trip itself runs natively (UFastTravelAccessPoint::TravelTo, called by
-- the map's confirm), so main.dll detours it: this module tells it how much
-- food you carry (dlls\travel.txt, every 0.5 s); main.dll refuses a trip
-- you cannot pay for and counts the ones it let through
-- (dlls\travel_paid.txt). Each new paid trip takes the food here; each
-- refused one shows the game's notice. (Lua hooks on the confirm and on the
-- travel request never fired, 2026-10-18.)
local TRAVEL_FILE = ROOT .. "dlls\\travel.txt"
local PAID_FILE = ROOT .. "dlls\\travel_paid.txt"
local last_feed = nil
local seen_paid, seen_refused = nil, nil

local function write_feed(food)
    local text = string.format("food=%d\ncost=%d\nend\n", food, CFG.foodPerTrip)
    if text == last_feed then return end
    last_feed = text
    local f = io.open(TRAVEL_FILE .. ".tmp", "wb")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(TRAVEL_FILE)
    os.rename(TRAVEL_FILE .. ".tmp", TRAVEL_FILE)
end

local function read_paid()
    local f = io.open(PAID_FILE, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    if not text:find("\nend\n", 1, true) then return nil end
    return tonumber(text:match("paid=(%d+)")), tonumber(text:match("refused=(%d+)"))
end

local function pay(pawn)
    local stacks = food_stacks(pawn)
    local left = CFG.foodPerTrip
    for _, f in ipairs(stacks) do
        while left > 0 and f.amount > 0 do
            take_one(f)
            f.amount = f.amount - 1
            left = left - 1
            log(string.format("fast travel paid with 1 %s (slot %d)", f.name, f.slot + 1))
        end
        if left == 0 then break end
    end
    if left > 0 then log("fast travel: could only take part of the cost") end
end

local feed_tick = 0
local function pass()
    if CFG.foodPerTrip <= 0 then write_feed(0) return end
    local pc, pawn = player_parts()
    if not pc then return end
    feed_tick = feed_tick + 1
    if feed_tick % 2 == 1 then
        local have = 0
        for _, f in ipairs(food_stacks(pawn)) do have = have + f.amount end
        write_feed(have)
    end
    local paid, refused = read_paid()
    if paid then
        if seen_paid and paid > seen_paid then
            for _ = 1, paid - seen_paid do pay(pawn) end
            last_feed = nil              -- food changed: send the new count
        end
        seen_paid = paid
    end
    if refused then
        if seen_refused and refused > seen_refused then
            log("fast travel cancelled: not enough food on you")
            notify(pc)
        end
        seen_refused = refused
    end
end

LIB.game_loop(250, function()
    local ok, err = pcall(pass)
    if not ok then log("error: " .. tostring(err)) end
end)
log(string.format("loaded: fast travel costs %d food (hotbar from the highest slot first)", CFG.foodPerTrip))
