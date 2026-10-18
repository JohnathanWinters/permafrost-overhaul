-- f8log (part of Rebalance, formerly the LootDump mod): loot research. Changes nothing.
-- 1. 20 s after the world loads (or on the first F8): loads every LootConfigs asset (list in
--    asset_list.txt) plus loaded AnimalConfig / NPCConfig / WorldLocation
--    assets and writes every field to loot_assets.txt.
-- 2. Census: every lootable actor in the streamed-in world (inventory
--    components + actors holding a loot config), with its loot config,
--    spawn method and location, appended to loot_census.txt.
--    Runs once after the asset dump and on every F8 press (timestamped, kept
--    across launches: press F8 whenever loot looks off and quote the time). Walking
--    or driving to a new area and pressing F8 adds that area.
local TAG = "[PF Rebalance F8] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

local LIB = REBALANCE_LIB  -- shared helpers (Scripts\lib.lua)
local try, valid, fname, full, game_later = LIB.try, LIB.valid, LIB.fname, LIB.full, LIB.game_later
local function class_name(x)
    return try(function() return x:GetClass():GetFName():ToString() end) or "?"
end

local function mod_root()
    local src = try(function() return debug.getinfo(1, "S").source end)
    if type(src) == "string" then
        src = src:gsub("^@", ""):gsub("/", "\\")
        local base = src:match("^(.*\\)[Ss]cripts\\[%w_]+%.lua$")
        if base then return base end
    end
    local dirs = try(function() return IterateGameDirectories() end)
    local win64 = dirs and dirs.Game and dirs.Game.Binaries and dirs.Game.Binaries.Win64
    local root = win64 and win64.__absolute_path
    if type(root) == "string" then return root .. "\\ue4ss\\Mods\\Rebalance\\" end
    return nil
end
local ROOT = mod_root() or ""

------------------------------------------------------------------ reflection
local NUMBER = {
    FloatProperty = true, DoubleProperty = true, IntProperty = true, Int64Property = true,
    Int16Property = true, Int8Property = true, UInt32Property = true, UInt16Property = true,
    UInt64Property = true, ByteProperty = true, EnumProperty = true, BoolProperty = true,
}
local OBJECT = {
    ObjectProperty = true, ClassProperty = true, WeakObjectProperty = true,
    SoftObjectProperty = true, SoftClassProperty = true, LazyObjectProperty = true,
    InterfaceProperty = true,
}

local function ptype_of(prop)
    return try(function() return prop:GetClass():GetFName():ToString() end) or "?"
end

local function each_property(ustruct, fn)
    local s, guard = ustruct, 0
    while valid(s) and guard < 32 do
        try(function()
            s:ForEachProperty(function(prop) fn(prop, fname(prop), ptype_of(prop)) end)
        end)
        s = try(function() return s:GetSuperStruct() end)
        guard = guard + 1
    end
end

local function soft_path(v)
    -- UE4SS 3.0.x: TSoftObjectPtr:GetObjectID() -> FSoftObjectPath:GetAssetPathName().
    if type(v) == "string" then return v end
    local id = try(function() return v:GetObjectID() end)
    if id then
        local p = try(function() return id:GetAssetPathName():ToString() end)
            or try(function() return id:ToString() end)
        if type(p) == "string" and p ~= "" then return p end
    end
    local o = try(function() return v:GetWeakPtr():Get() end)
    if valid(o) then return full(o) end
    local s = try(function() return v:ToString() end)
    if type(s) == "string" and s ~= "" then return s end
    return tostring(v)
end
local function short(path)
    if type(path) ~= "string" then return "?" end
    return path:match("%.([^%.]+)$") or path:match("([^/]+)$") or path
end

local ser
local function ser_struct(value, ustruct, depth)
    if depth > 6 then return "{...}" end
    local parts = {}
    each_property(ustruct, function(prop, name, ptype)
        local v = try(function() return value[name] end)
        parts[#parts + 1] = name .. "=" .. ser(prop, ptype, v, depth + 1)
    end)
    return "{" .. table.concat(parts, ", ") .. "}"
end

ser = function(prop, ptype, v, depth)
    if v == nil then return "nil" end
    if NUMBER[ptype] then
        if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
        return tostring(try(function() return v:get() end) or v)
    end
    if ptype == "NameProperty" or ptype == "StrProperty" or ptype == "TextProperty" then
        return '"' .. (try(function() return v:ToString() end) or tostring(v)) .. '"'
    end
    if ptype == "SoftObjectProperty" or ptype == "SoftClassProperty" then
        return "soft:" .. soft_path(v)
    end
    if OBJECT[ptype] then
        if valid(v) then return full(v) end
        return "None"
    end
    if ptype == "StructProperty" then
        local inner = try(function() return prop:GetStruct() end)
        if not inner then return "{?}" end
        return ser_struct(v, inner, depth)
    end
    if ptype == "ArrayProperty" or ptype == "SetProperty" then
        local inner = try(function() return prop:GetInner() end)
            or try(function() return prop:GetElementProp() end)
        local itype = inner and ptype_of(inner) or "?"
        local parts = {}
        local ok = try(function()
            v:ForEach(function(a, b)
                local elem = b
                if elem == nil then elem = a end
                local e = try(function() return elem:get() end)
                if e == nil then e = elem end
                parts[#parts + 1] = ser(inner, itype, e, depth + 1)
            end)
            return true
        end)
        if not ok and #parts == 0 then
            local n = try(function() return v:GetArrayNum() end)
            return "[unreadable " .. ptype .. (n and (" n=" .. n) or "") .. "]"
        end
        return "[" .. table.concat(parts, "; ") .. "]"
    end
    if ptype == "MapProperty" then
        local kp = try(function() return prop:GetKeyProp() end)
        local vp = try(function() return prop:GetValueProp() end)
        local kt, vt = kp and ptype_of(kp) or "?", vp and ptype_of(vp) or "?"
        local parts = {}
        local ok = try(function()
            v:ForEach(function(k, val)
                local kk = try(function() return k:get() end) or k
                local vv = try(function() return val:get() end) or val
                parts[#parts + 1] = ser(kp, kt, kk, depth + 1) .. " => " .. ser(vp, vt, vv, depth + 1)
            end)
            return true
        end)
        if not ok and #parts == 0 then return "[unreadable map]" end
        return "<" .. table.concat(parts, "; ") .. ">"
    end
    return "?" .. ptype
end

-- Fields declared by the game (skips UObject/UDataAsset/Actor base noise).
local SKIP_OWNERS = { Object = true, DataAsset = true, PrimaryDataAsset = true, ActorComponent = true }
local function dump_object(obj, out)
    out[#out + 1] = "== " .. class_name(obj) .. " " .. full(obj)
    local s, guard = try(function() return obj:GetClass() end), 0
    while valid(s) and guard < 32 and not SKIP_OWNERS[fname(s)] do
        local owner = fname(s)
        try(function()
            s:ForEachProperty(function(prop)
                local name, ptype = fname(prop), ptype_of(prop)
                local v = try(function() return obj[name] end)
                out[#out + 1] = string.format("  %s.%s : %s = %s", owner, name, ptype, ser(prop, ptype, v, 0))
            end)
        end)
        s = try(function() return s:GetSuperStruct() end)
        guard = guard + 1
    end
end

local function write_file(name, lines, mode)
    local f = io.open(ROOT .. name, mode or "wb")
    if not f then log("cannot write " .. ROOT .. name) return end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end

------------------------------------------------------------------ asset dump
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
    obj = try(function() return LoadAsset(path:match("^(.-)%.") or path) end)
    if valid(obj) then return obj end
    return try(function() return StaticFindObject(path) end)
end

local function dump_assets()
    local out, ok, missing = {}, 0, {}
    for _, path in ipairs(read_asset_list()) do
        local obj = load_asset(path)
        if valid(obj) then
            ok = ok + 1
            local good = pcall(dump_object, obj, out)
            if not good then out[#out + 1] = "  (dump error)" end
        else
            missing[#missing + 1] = path
        end
    end
    -- Configs that live elsewhere in the content tree; whatever is loaded now.
    local extra = 0
    for _, cls in ipairs({ "AnimalConfig", "NPCConfig_Base", "Data_WorldLocationInstance",
                           "SingleResourceLootConfig", "LootConfig", "LootConfig_RandomList",
                           "LootFilterConfig", "PermaGeneralSettings" }) do
        for _, o in ipairs(FindAllOf(cls) or {}) do
            local n = full(o)
            if not n:find("Default__") and not n:find("/LootConfigs/") then
                extra = extra + 1
                pcall(dump_object, o, out)
            end
        end
    end
    for _, m in ipairs(missing) do out[#out + 1] = "!! not loaded " .. m end
    write_file("loot_assets.txt", out)
    log(string.format("assets: %d dumped from list, %d missing, %d extra -> loot_assets.txt", ok, #missing, extra))
end

local function player_pawn()
    local helpers = try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and try(function() return pc.Pawn end)
    return valid(pawn) and pawn or nil
end


------------------------------------------------------------------ on-screen notice
-- Small text box in the top-left corner plus the game's hint sound, so an
-- F8 press is visibly confirmed. Shipping builds strip
-- PrintString, so this borrows a tiny game widget and swaps its root for a
-- Border + TextBlock before it is first shown.
local HOST_WIDGETS = {
    "/Game/Permafrost/UI/Utils/UW_RecipePopupIcon.UW_RecipePopupIcon_C",
    "/Game/Permafrost/UI/Popups/UW_DefaultHUDPopUp.UW_DefaultHUDPopUp_C",
}
local NOTICE_SOUND = "/Game/FMOD/Events/UI/sfx_ui_notification_hint_appear.sfx_ui_notification_hint_appear"
local notice = { widget = nil, text = nil, failed = false, hide_token = 0 }

local function player_controller()
    local helpers = try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    return valid(pc) and pc or nil
end

local function construct(class_path, outer, name)
    local cls = try(function() return StaticFindObject(class_path) end)
    if not valid(cls) then return nil end
    local o = try(function() return StaticConstructObject(cls, outer, FName(name)) end)
    return valid(o) and o or nil
end

local function build_notice()
    local pc = player_controller()
    local lib = try(function() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end)
    if not pc or not valid(lib) then return false end
    local widget
    for _, path in ipairs(HOST_WIDGETS) do
        local cls = load_asset(path)
        widget = valid(cls) and try(function() return lib:Create(pc, cls, pc) end)
        if valid(widget) then break end
        widget = nil
    end
    if not widget then log("notice: no host widget class could be created") return false end
    local tree = try(function() return widget.WidgetTree end)
    if not valid(tree) then log("notice: host widget has no WidgetTree") return false end
    local border = construct("/Script/UMG.Border", tree, "LootDumpNoticeBorder")
    local text = construct("/Script/UMG.TextBlock", tree, "LootDumpNoticeText")
    if not border or not text then log("notice: could not construct Border/TextBlock") return false end
    try(function() border:SetContent(text) end)
    try(function() border:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.6 }) end)
    try(function() border:SetPadding({ Left = 8, Top = 3, Right = 8, Bottom = 3 }) end)
    try(function()
        local font = text.Font
        font.Size = 11
        text:SetFont(font)
    end)
    try(function() text:SetColorAndOpacity({ SpecifiedColor = { R = 1.0, G = 0.85, B = 0.35, A = 1.0 }, ColorUseRule = 0 }) end)
    tree.RootWidget = border
    try(function() widget:AddToViewport(10000) end)
    try(function() widget:SetAlignmentInViewport({ X = 0.0, Y = 0.0 }) end)
    try(function() widget:SetPositionInViewport({ X = 24.0, Y = 24.0 }, true) end)
    try(function() widget:SetDesiredSizeInViewport({ X = 360.0, Y = 26.0 }) end)
    try(function() widget:SetVisibility(1) end)  -- Collapsed until the first message
    notice.widget, notice.text = widget, text
    log("notice: on-screen box ready")
    return true
end

local sound_event = nil
local function play_notice_sound()
    local pc = player_controller()
    local statics = try(function() return StaticFindObject("/Script/FMODStudio.Default__FMODBlueprintStatics") end)
    if not pc or not valid(statics) then return end
    sound_event = load_asset(NOTICE_SOUND)  -- looked up each press, never trusted from last time
    if valid(sound_event) then try(function() statics:PlayEvent2D(pc, sound_event, true) end) end
end

-- Shows `msg` for `seconds` (default 5). sound = true plays the hint sound.
local function notify(msg, seconds, sound)
    log(msg)
    if sound then play_notice_sound() end
    if notice.failed then return end
    if not valid(notice.widget) or not valid(notice.text) then
        local ok, built = pcall(build_notice)
        if not ok or not built then
            notice.failed = true
            log("notice: on-screen box unavailable (" .. tostring(ok and "build failed" or built) .. "), sound only")
            return
        end
    end
    try(function() notice.text:SetText(FText(msg)) end)
    try(function() notice.widget:SetVisibility(3) end)  -- HitTestInvisible: shown, never blocks the mouse
    notice.hide_token = notice.hide_token + 1
    local token = notice.hide_token
    game_later(math.floor((seconds or 5) * 1000), function()
        if token == notice.hide_token and valid(notice.widget) then
            try(function() notice.widget:SetVisibility(1) end)
        end
    end)
end

------------------------------------------------------------------ census
local seen = {}           -- full name -> true (across F8 presses)
local loot_props = {}     -- actor class -> list of property names holding loot configs

local function looks_like_loot(path)
    return type(path) == "string" and (path:find("LootConfig") or path:find("DA_LC_")
        or path:find("RandomList")) ~= nil
end

local function loc_str(actor)
    local v = try(function() return actor:K2_GetActorLocation() end)
    if not v then return "?" end
    return string.format("%.0f,%.0f,%.0f", v.X or 0, v.Y or 0, v.Z or 0)
end

local function scan_class_loot_props(actor)
    local cls = class_name(actor)
    if loot_props[cls] then return loot_props[cls] end
    local names = {}
    each_property(try(function() return actor:GetClass() end), function(prop, name, ptype)
        if ptype == "ObjectProperty" or ptype == "SoftObjectProperty" then
            local v = try(function() return actor[name] end)
            local path = ptype == "SoftObjectProperty" and (v and soft_path(v)) or (valid(v) and full(v))
            if looks_like_loot(path) or (valid(v) and class_name(v):find("Loot")) then
                names[#names + 1] = name
            end
        end
    end)
    loot_props[cls] = names
    return names
end

local function describe(actor)
    local parts = {}
    for _, p in ipairs(scan_class_loot_props(actor)) do
        local v = try(function() return actor[p] end)
        local shown = valid(v) and full(v) or (v and soft_path(v)) or "None"
        parts[#parts + 1] = p .. "=" .. short(shown)
    end
    return #parts > 0 and table.concat(parts, ",") or "-"
end

local NEAR_CM = 2500  -- objects this close are always logged, even if seen before

local function near(actor, pv)
    if not pv then return false end
    local v = try(function() return actor:K2_GetActorLocation() end)
    if not v then return false end
    local dx, dy, dz = v.X - pv.X, v.Y - pv.Y, v.Z - pv.Z
    return dx * dx + dy * dy + dz * dz < NEAR_CM * NEAR_CM
end

local function census()
    local pawn = player_pawn()
    local pv = pawn and try(function() return pawn:K2_GetActorLocation() end)
    local here = pawn and loc_str(pawn) or "?"
    local stamp = os.date("%Y-%m-%d %H:%M:%S")
    local out, added = { "## F8 " .. stamp .. " player at " .. here }, 0
    local logged = {}  -- this press only: an actor with an inventory is not logged twice

    -- Containers, corpses, NPCs: anything with an InventoryComponent.
    for _, comp in ipairs(FindAllOf("InventoryComponent") or {}) do
        local n = full(comp)
        local owner = not n:find("Default__") and try(function() return comp:GetOwner() end)
        if valid(owner) and (not seen[n] or near(owner, pv)) then
            seen[n] = true
            do
                seen[full(owner)] = true
                logged[full(owner)] = true
                local init = try(function() return comp.InitialItems end)
                local method = try(function() return comp.StartingItemsSpawnMethod end)
                local items = try(function() return comp.Items_:GetArrayNum() end)
                out[#out + 1] = string.format((near(owner, pv) and "%s|INV*|" or "%s|INV|") .. "%s|%s|loot=%s|comp=%s|comploot=%s|init=%s|method=%s|items=%s|loc=%s",
                    stamp, class_name(owner), fname(owner), describe(owner), class_name(comp), describe(comp),
                    valid(init) and short(full(init)) or "None", tostring(method), tostring(items),
                    loc_str(owner))
                added = added + 1
            end
        end
    end

    -- Trash piles, ore, scrap, wood, bushes: scavenge/destroy actors.
    for _, base in ipairs({ "Scavengeable", "InteractionBase", "DestructibleActor", "GeometryCollectionActor" }) do
        for _, a in ipairs(FindAllOf(base) or {}) do
            local n = full(a)
            if not n:find("Default__") and not logged[n] and (not seen[n] or near(a, pv)) then
                seen[n] = true
                local scav = try(function() return a.bScavenged end)
                out[#out + 1] = string.format((near(a, pv) and "%s|ACT*|" or "%s|ACT|") .. "%s|%s|loot=%s|scavenged=%s|loc=%s",
                    stamp, class_name(a), fname(a), describe(a), tostring(scav), loc_str(a))
                added = added + 1
            end
        end
    end

    write_file("loot_census.txt", out, "ab")
    local nearby = 0
    for _, line in ipairs(out) do
        if line:find("|INV%*|") or line:find("|ACT%*|") then nearby = nearby + 1 end
    end
    log(string.format("census: %d lootables near %s -> loot_census.txt", added, here))
    notify(string.format("F8 saved: %d objects, %d near you (%s)", added, nearby, os.date("%H:%M:%S")), 4, true)
end

------------------------------------------------------------------ start
local started = false
local dumped = false
local function start(delay)
    if started then return end
    started = true
    game_later(delay or 20000, function()
        if dumped then return end
        dumped = true
        local ok, err = pcall(dump_assets)
        if not ok then log("asset dump error: " .. tostring(err)) end
        ok, err = pcall(census)
        if not ok then log("census error: " .. tostring(err)) end
    end)
end

-- Start once a player character exists (world loaded, not the main menu).
local function poll()
    if started then return end
    if player_pawn() then start() return end
    game_later(5000, poll)
end
-- No automatic run: the full dump + census hitches the game, so it only
-- runs on the first F8 press (start(1) in the key bind).

RegisterKeyBind(Key.F8, function()
    if not started then start(1) end
    game_later(1, function()
        local ok, err = pcall(census)
        if not ok then log("census error: " .. tostring(err)) end
    end)
end)

-- Fresh files per game launch.
-- Census files are kept across launches (one session header each) so a
-- find from hours or days ago can still be looked up by its timestamp.
local session = "# ===== game session started " .. os.date("%Y-%m-%d %H:%M:%S")
write_file("loot_census.txt", { session }, "ab")
log("loaded; F8 = timestamped census of the area (first press also dumps the loot tables)")
