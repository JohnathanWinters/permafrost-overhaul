-- CraftFromStorage module of the Rebalance mod (was its own mod until 2026-10-17).
-- Settings: Rebalance\config\CraftFromStorage.lua
-- CraftFromStorage, Lua side. Finds everything by reflection and hands it to
-- dlls\main.dll through dlls\state.txt (rewritten every 0.5 s):
--   enabled=1
--   equip=<player EquipmentComponent>
--   chest=<UInventoryComponent of a storage chest in range>   (repeated)
--   building=1/0   build mode or construction active (held 3 s after)
--   fn_qty / fn_list / fn_remove / fn_check=<UInventoryComponent UFunctions>
--   craft=<UFunction>  crafting/repair component functions (repeated)
--   ui=<UFunction>     crafting widget functions (repeated)
--   end
local TAG = "[PF CraftFromStorage] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

-- Game-thread scheduling. LoopAsync + ExecuteInGameThread queues a new
-- callback from a worker thread on every tick; with several mods doing it,
-- UE4SS raced ("Ref was not function") and crashed the game on 2026-10-16.
-- This UE4SS build can loop directly on the game thread; the old pattern is
-- only a fallback.
local LIB = REBALANCE_LIB  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, path_of, resolve, address, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.path_of, LIB.resolve, LIB.address, LIB.game_loop

------------------------------------------------------------------ config
local DEFAULTS = {
    { "enabled",      1,  "1 = crafting and repairs also use nearby storage, 0 = off" },
    { "radiusMetres", 15, "how far storage can be from you (1 to 100)" },
}

local function mod_root()
    if REBALANCE_ROOT then return REBALANCE_ROOT end
    local src = try(function() return debug.getinfo(1, "S").source end)
    if type(src) == "string" then
        src = src:gsub("^@", ""):gsub("/", "\\")
        local base = src:match("^(.*\\)[Ss]cripts\\main%.lua$")
        if base then return base end
    end
    local dirs = try(function() return IterateGameDirectories() end)
    local win64 = dirs and dirs.Game and dirs.Game.Binaries and dirs.Game.Binaries.Win64
    local root = win64 and win64.__absolute_path
    if type(root) == "string" then return root .. "\\ue4ss\\Mods\\CraftFromStorage\\" end
    return nil
end

local ROOT = mod_root()
if not ROOT then
    log("FAIL: mod folder not found; mod inactive")
    return
end

local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local path = ROOT .. "config\\CraftFromStorage.lua"
    local f = io.open(path, "r")
    if not f then
        f = io.open(path, "w")
        if f then
            f:write("-- CraftFromStorage settings. Restart the game to apply.\n")
            f:write("return {\n")
            for _, d in ipairs(DEFAULTS) do
                f:write(string.format("    %s = %s, -- %s\n", d[1], tostring(d[2]), d[3]))
            end
            f:write("}\n")
            f:close()
            log("created " .. path)
        end
        return cfg
    end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "config.lua", "t", {})  -- empty env: data only
    local user = chunk and try(chunk)
    if type(user) ~= "table" then
        log("config.lua unreadable, using defaults")
        return cfg
    end
    for _, d in ipairs(DEFAULTS) do
        local v = tonumber(user[d[1]])
        if v then cfg[d[1]] = v end
    end
    cfg.radiusMetres = math.max(1, math.min(100, cfg.radiusMetres))
    return cfg
end

local CFG = load_config()
log(string.format("enabled = %s, radiusMetres = %s", tostring(CFG.enabled), tostring(CFG.radiusMetres)))

local STATE = ROOT .. "dlls\\state.txt"
local STATE_TMP = ROOT .. "dlls\\state.tmp"

------------------------------------------------------------------ UFunctions
local CRAFT_CLASSES = {
    "/Script/Permafrost.CraftingComponent_Base",
    "/Script/Permafrost.CraftingComponent_Workbench",
    "/Script/Permafrost.RepairStationComponent",
    "/Script/Permafrost.PlayerBuildingComponent",
}
local UI_CLASSES = {
    "/Script/Permafrost.Widget_CraftingBase",
    "/Script/Permafrost.Widget_CraftingModular",
    "/Script/Permafrost.Widget_CraftingSimple",
    "/Script/Permafrost.Widget_CraftingSingleObjectPosition",
    "/Script/Permafrost.Widget_CraftingTooltip",
    "/Script/Permafrost.Widget_SingleCraftingPosition",
    "/Script/Permafrost.Widget_UniformSingleObjectPosition",
    -- Repair menu (user 2026-10-18: repairs needed the material on you).
    "/Script/Permafrost.RepairStationWidget",
    "/Script/Permafrost.ServiceWidgetBase",
}
-- Single UFunctions that run a repair: the repair button calls
-- UUI_ManagerComponent::SERVER_RepairItem(Inventory, Slot), which runs
-- URepairStationComponent::AUTHORITY_RepairItem -> CheckForItem /
-- RemoveItemAmount on the player's inventory (the hooked slots). Only this
-- one is wrapped: wrapping the whole UI manager would show storage items in
-- ordinary inventory views.
local CRAFT_FUNCTIONS = {
    "/Script/Permafrost.UI_ManagerComponent:SERVER_RepairItem",
}
local INV = "/Script/Permafrost.InventoryComponent:"

local static_lines = nil  -- built once; the UFunctions live for the whole session

local function class_functions(path, kind, out)
    local cls = try(function() return StaticFindObject(path) end)
    if not valid(cls) then
        log("class not found: " .. path)
        return 0
    end
    local n = 0
    try(function()
        cls:ForEachFunction(function(fn)
            local a = address(fn)
            if a then
                out[#out + 1] = string.format("%s=%X", kind, a)
                n = n + 1
            end
        end)
    end)
    return n
end

local function build_static()
    local lines = {}
    for _, key in ipairs({ { "fn_qty", "GetItemQuantity" }, { "fn_list", "GetItemsList" }, { "fn_remove", "RemoveItemAmount" }, { "fn_check", "CheckForItem" } }) do
        local fn = try(function() return StaticFindObject(INV .. key[2]) end)
        local a = address(fn)
        if not a then
            log("FAIL: UFunction not found: " .. INV .. key[2])
            return nil
        end
        lines[#lines + 1] = string.format("%s=%X", key[1], a)
    end
    local craft, ui = 0, 0
    for _, p in ipairs(CRAFT_CLASSES) do craft = craft + class_functions(p, "craft", lines) end
    for _, p in ipairs(CRAFT_FUNCTIONS) do
        local a = address(try(function() return StaticFindObject(p) end))
        if a then
            lines[#lines + 1] = string.format("craft=%X", a)
            craft = craft + 1
        else
            log("repair function not found: " .. p)
        end
    end
    for _, p in ipairs(UI_CLASSES) do ui = ui + class_functions(p, "ui", lines) end
    if craft == 0 then
        log("FAIL: no crafting UFunctions found")
        return nil
    end
    log(string.format("found %d crafting and %d crafting-widget UFunctions", craft, ui))
    return lines
end

------------------------------------------------------------------ player + chests
local equip_class, inv_class, build_class = nil, nil, nil
local building_until = 0  -- os.clock() time the building flag stays on until
local last_build_key = nil

-- True when an enum value is anything but its "None" entry. Uses the UEnum's
-- names when UE4SS exposes them, else assumes None = 0.
local enum_none = {}
local function is_active_enum(path, value)
    if type(value) ~= "number" then return false end
    if enum_none[path] == nil then
        enum_none[path] = 0
        local e = try(function() return StaticFindObject(path) end)
        if valid(e) then
            try(function()
                e:ForEachName(function(name, v)
                    local n = type(name) == "string" and name or try(function() return name:ToString() end) or ""
                    if n:match("None$") then enum_none[path] = v end
                end)
            end)
        end
    end
    return value ~= enum_none[path]
end

-- Building is active in build mode, while placing a preview, or during a
-- construction/repair action. Costs are paid from Blueprint after the native
-- call returns, so the flag is held 3 s after activity ends.
-- Kept by path and looked up each time (never hold a UObject across frames).
local build_path = nil
local last_build_search = 0
local build_missing_logged = false
local next_build_search = 0

-- The building component may sit on the pawn or on the player controller.
local function find_build_comp(pawn)
    if build_path then
        local o = resolve(build_path)
        if valid(o) then return o end
        build_path = nil
    end
    local build_comp = nil
    local now = os.clock()
    if now < next_build_search then return nil end
    next_build_search = now + 5  -- searching walks objects; at most every 5 s
    build_class = build_class or try(function() return StaticFindObject("/Script/Permafrost.PlayerBuildingComponent") end)
    if not valid(build_class) or not pawn then return nil end
    local pc = try(function() return pawn.Controller end)
    for _, owner in ipairs({ pawn, pc }) do
        if valid(owner) then
            local c = try(function() return owner:GetComponentByClass(build_class) end)
            if valid(c) then build_comp = c; break end
        end
    end
    if not valid(build_comp) and os.time() - last_build_search >= 10 then
        last_build_search = os.time()
        -- Last resort: any instance whose owner is the pawn or controller.
        local pawn_a, pc_a = address(pawn), address(pc)
        for _, c in ipairs(FindAllOf("PlayerBuildingComponent") or {}) do
            if not fname(c):find("^Default__") then
                local o = address(try(function() return c:GetOwner() end))
                if o and (o == pawn_a or o == pc_a) then build_comp = c; break end
            end
        end
    end
    if valid(build_comp) then
        local s_full = try(function() return build_comp:GetFullName() end) or ""
        build_path = path_of(build_comp)
        log("building component: " .. (s_full ~= "" and s_full or "?"))
    elseif not build_missing_logged then
        build_missing_logged = true
        log("building component NOT found on pawn or controller")
    end
    return valid(build_comp) and build_comp or nil
end

local function building_active(pawn)
    local comp = find_build_comp(pawn)
    if not comp then return false end
    local mode = try(function() return comp.BuildMode end)
    local state = try(function() return comp.CurrentState end)
    local preview = valid(try(function() return comp.PreviewBuildPart end))
    local mode_on = is_active_enum("/Script/Permafrost.EBuildMode", mode)
    local state_on = is_active_enum("/Script/Permafrost.EBuildState", state)
    local key = string.format("%s/%s/%s", tostring(mode), tostring(state), tostring(preview))
    if key ~= last_build_key then
        last_build_key = key
        log(string.format("building state: mode=%s (%s) state=%s (%s) preview=%s", tostring(mode),
            mode_on and "active" or "idle", tostring(state), state_on and "active" or "idle", tostring(preview)))
    end
    local now = os.clock()
    if mode_on or state_on or preview then building_until = now + 3 end
    return now < building_until
end
local storage_actors = {}
local last_actor_scan = 0
local ticks = 0
local last_count = -1
local last_inv2 = false

local function player_pawn()
    local helpers = try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    if not valid(pc) then return nil end
    local pawn = try(function() return pc.Pawn end)
    if valid(pawn) then return pawn end
    return nil
end

local function location(actor)
    local v = try(function() return actor:K2_GetActorLocation() end)
    if not v then return nil end
    return v.X, v.Y, v.Z
end

local last_state = nil
-- Objects are kept by path and looked up when needed: holding a Lua
-- reference to an object the game later frees crashed the game (2026-10-17).
local function write_state(lines)
    local text = table.concat(lines, "\n")
    if text == last_state then return end   -- the DLL only re-reads when the file changes
    last_state = text
    local f = io.open(STATE_TMP, "wb")  -- binary: LF line endings
    if not f then return end
    f:write(text)
    f:write("\nend\n")
    f:close()
    os.remove(STATE)
    os.rename(STATE_TMP, STATE)
end

local function update()
    ticks = ticks + 1
    if not static_lines then
        if ticks % 10 ~= 1 then return end  -- retry every 5 s until the classes exist
        static_lines = build_static()
        if not static_lines then return end
    end
    equip_class = equip_class or try(function() return StaticFindObject("/Script/Permafrost.EquipmentComponent") end)
    inv_class = inv_class or try(function() return StaticFindObject("/Script/Permafrost.InventoryComponent") end)

    local lines = { "enabled=" .. ((CFG.enabled == 1) and "1" or "0") }
    local pawn = player_pawn()
    lines[#lines + 1] = "building=" .. (building_active(pawn) and "1" or "0")
    local equip = pawn and valid(equip_class) and try(function() return pawn:GetComponentByClass(equip_class) end)
    local equip_addr = address(equip)
    local chests = 0
    if equip_addr then
        lines[#lines + 1] = string.format("equip=%X", equip_addr)
        -- Building checks costs on its own PlayerInventory reference.
        local bc = find_build_comp(pawn)
        local inv2 = bc and try(function() return bc.PlayerInventory end)
        local inv2_addr = address(inv2)
        if inv2_addr and inv2_addr ~= equip_addr then
            lines[#lines + 1] = string.format("inv2=%X", inv2_addr)
        end
        if inv2_addr ~= last_inv2 then
            last_inv2 = inv2_addr
            log(string.format("building inventory: %s (%s)", fname(inv2) ~= "?" and fname(inv2) or "none",
                inv2_addr == equip_addr and "same as equipment" or "separate object"))
        end
        -- Storage list (path + position, they do not move) every 10 s; distance
        -- every tick; the actor is looked up only when it is in range.
        local now = os.time()
        if now - last_actor_scan >= 10 then
            last_actor_scan = now
            storage_actors = {}
            for _, actor in ipairs(FindAllOf("BP_MasterStorageBuildPart_C") or {}) do
                local n = path_of(actor)
                if not n:find("Default__") then
                    local x, y, z = location(actor)
                    if x then storage_actors[#storage_actors + 1] = { path = n, x = x, y = y, z = z } end
                end
            end
        end
        local px, py, pz = location(pawn)
        local r2 = (CFG.radiusMetres * 100) ^ 2
        if px then
            for _, st in ipairs(storage_actors) do
                if (st.x - px) ^ 2 + (st.y - py) ^ 2 + (st.z - pz) ^ 2 <= r2 then
                    local actor = resolve(st.path)
                    if actor then
                        local inv = valid(inv_class) and try(function() return actor:GetComponentByClass(inv_class) end)
                        local a = address(inv)
                        if a and a ~= equip_addr then
                            lines[#lines + 1] = string.format("chest=%X", a)
                            chests = chests + 1
                        end
                    end
                end
            end
        end
    end
    for _, l in ipairs(static_lines) do lines[#lines + 1] = l end
    write_state(lines)
    if chests ~= last_count then
        last_count = chests
        log(string.format("%d storage inventories within %d m", chests, CFG.radiusMetres))
    end
end

game_loop(500, function()
    local ok, err = pcall(update)
    if not ok then log("error: " .. tostring(err)) end
end)

log("loaded")
