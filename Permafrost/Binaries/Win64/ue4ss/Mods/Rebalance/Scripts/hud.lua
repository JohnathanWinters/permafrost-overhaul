-- HUD module of the Overhaul (2026-10-18). User: every HUD element is always
-- on. Wanted:
--  * health area: only while one of its bars is below lowStatPercent;
--  * hotbar: only for hotbarShowSeconds after a hotbar key is pressed;
--  * quest box on the left: fades out questShowSeconds after it changes;
--  * selected weapon box: hidden while your hands are empty, shown for
--    weaponShowSeconds after you switch to an item;
--  * compass: untouched.
-- Fades are SetRenderOpacity steps (fadeSeconds, quick but smooth).
--
-- The game's HUD is the UW_HUD widget; the always-on part is Canvas_BaseHUD
-- (menus live in Canvas_Toggleable and are never touched). PARTS names the
-- widgets of each group, from the HUD tree dumped on 2026-10-18
-- (dlls\hud_tree.txt, still written once per session). Each part is
-- remembered as its route of child indexes from Canvas_BaseHUD and looked up
-- fresh through that route when needed: cheap, and no widget reference is
-- kept across frames. (The first version found widgets by listing every
-- widget of their class, up to 20 times a second: 0.6 s of work per 15 s and
-- 30 ms stutters.)
-- Settings: HUD section of config.lua. Log tag [PF HUD].
local TAG = "[PF HUD] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

------------------------------------------------------------------ config
local DEFAULTS = {
    { "enabled",           1,    "1 = on" },
    { "lowStatPercent",    25,   "health area shows while any of its bars is below this %" },
    { "hotbarShowSeconds", 2,    "hotbar shows this long after a hotbar key" },
    { "questShowSeconds",  5,    "quest box shows this long after it changes" },
    { "weaponShowSeconds", 2,    "selected weapon box shows this long after you switch items" },
    { "fadeSeconds",       0.25, "fade in/out time" },
    { "debugLog",          1,    "1 = log the HUD parts found and dump the tree" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\HUD.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "HUD.lua", "t", {})
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

-- Widget name -> group. Exact names; the quick-slot hints are matched by
-- prefix because the game numbers some of them.
local PARTS = {
    VerticalBox_StatusPanel = "health",
    UW_HeldItemIndicator = "weapon",
    InvalidationBox_Quests = "quest",
}
local PREFIXES = { { "PreviousQuickSlot", "hotbar" }, { "NextQuickSlot", "hotbar" }, { "QuickSlots", "hotbar" } }
-- Widgets the game adds to the HUD after it is built (the stat panel and
-- the hotbar slots were missing from the scan, 2026-10-18): found by their
-- own Blueprint class on each pass (a handful of objects, cheap), keeping
-- only those inside the HUD and not inside a menu (their object path names
-- every owning widget).
local CLASS_PARTS = { health = { "UW_CharStatusPanel_C", "BP_Widget_StatStatus_C" }, hotbar = { "UW_QuickSlot_C" } }
local MENU_WORDS = { "Menu", "Ledger", "Inventory", "Trading", "Crafting", "Container", "Storage" }
-- Never walked into: the compass and its markers, the crosshairs.
local NO_WALK = { UW_HUDCompass = true, CrosshairSwitcher = true, Markers_CanvasPanel = true }

------------------------------------------------------------------ widget tree
-- Children of a widget: panel slots first, then a nested UserWidget's root
-- (route step 0 = that root, n >= 1 = GetChildAt(n - 1)).
local function child(w, step)
    if step == 0 then
        local tree = get(w, "WidgetTree")
        local root = valid(tree) and get(tree, "RootWidget")
        return valid(root) and root or nil
    end
    local c = call(w, "GetChildAt", step - 1)
    return valid(c) and c or nil
end

local function each_child(w, fn)
    local n = tonumber(call(w, "GetChildrenCount")) or 0
    for i = 1, n do
        local c = child(w, i)
        if c then fn(c, i) end
    end
    local r = child(w, 0)
    if r then fn(r, 0) end
end

local function cls_name(w) return fname(call(w, "GetClass")) or "?" end

local function group_of(name)
    if PARTS[name] then return PARTS[name] end
    for _, p in ipairs(PREFIXES) do
        if name:sub(1, #p[1]) == p[1] then return p[2] end
    end
    return nil
end

local function find_hud()
    for _, h in ipairs(try(function() return FindAllOf("UW_HUD_C") end) or {}) do
        if valid(h) and not fname(h):find("^Default__") and call(h, "IsInViewport") == true then return h end
    end
    return nil
end

-- Canvas_BaseHUD under the HUD: UW_HUD -> root (Canvas_Root) -> ... found
-- by name within a few levels.
local function find_base(hud)
    local found = nil
    local function rec(w, depth, route)
        if found or depth > 4 then return end
        if fname(w) == "Canvas_BaseHUD" then found = route return end
        each_child(w, function(c, i)
            local r = { table.unpack(route) }
            r[#r + 1] = i
            rec(c, depth + 1, r)
        end)
    end
    rec(hud, 0, {})
    return found
end

local function follow(w, route)
    for _, step in ipairs(route) do
        if not w then return nil end
        w = child(w, step)
    end
    return w
end

-- routes[group] = { { route, name }, ... } relative to the HUD widget.
local routes = { health = {}, hotbar = {}, quest = {}, weapon = {} }
local bars = {}           -- routes of ProgressBars inside the health parts
local quest_texts = {}    -- routes of TextBlocks inside the quest parts
local hud_addr = nil
local dumped = false

local function scan(hud)
    local base = find_base(hud)
    if not base then return false end
    routes = { health = {}, hotbar = {}, quest = {}, weapon = {} }
    bars, quest_texts = {}, {}
    local dump = (CFG.debugLog == 1 and not dumped) and {} or nil
    local function inner(w, depth, route, out, kind)
        if depth > 10 or #out > 40 then return end
        if cls_name(w):find(kind) then out[#out + 1] = route end
        each_child(w, function(c, i)
            local r = { table.unpack(route) }
            r[#r + 1] = i
            inner(c, depth + 1, r, out, kind)
        end)
    end
    local function rec(w, depth, route)
        if depth > 12 then return end
        local name = fname(w)
        local g = group_of(name)
        if dump and #dump < 400 then
            dump[#dump + 1] = string.rep("  ", depth) .. name .. " (" .. cls_name(w) .. ")" .. (g and ("  <- " .. g) or "")
        end
        if g then
            local list = routes[g]
            list[#list + 1] = { route = route, name = name }
            if g == "health" then inner(w, 0, route, bars, "ProgressBar") end
            if g == "quest" then inner(w, 0, route, quest_texts, "TextBlock") end
            return
        end
        if NO_WALK[name] then return end
        each_child(w, function(c, i)
            local r = { table.unpack(route) }
            r[#r + 1] = i
            rec(c, depth + 1, r)
        end)
    end
    rec(follow(hud, base), 0, base)
    if dump then
        dumped = true
        local f = io.open(ROOT .. "dlls\\hud_tree.txt", "w")
        if f then f:write(table.concat(dump, "\n") .. "\n") f:close() end
    end
    for k, list in pairs(routes) do
        local names = {}
        for _, e in ipairs(list) do names[#names + 1] = e.name end
        log(string.format("%s: %s", k, #names > 0 and table.concat(names, ", ") or "not found"))
    end
    log(string.format("health bars: %d, quest texts: %d", #bars, #quest_texts))
    return true
end

-- Inside the always-on HUD? Climbs the real parents (GetParent; at a nested
-- widget's root, its WidgetTree's owner) until Canvas_BaseHUD (yes) or the
-- menu canvas / a menu widget (no). Widgets added at runtime are owned by
-- the player controller, so their object path says nothing about the HUD.
local function in_hud(w)
    for _ = 1, 40 do
        local name = fname(w)
        if name == "Canvas_BaseHUD" then return true end
        if name == "Canvas_Toggleable" then return false end
        for _, word in ipairs(MENU_WORDS) do
            if name:find(word, 1, true) then return false end
        end
        local p = call(w, "GetParent")
        if not valid(p) then
            local outer = call(w, "GetOuter")
            if valid(outer) and fname(outer) == "WidgetTree" then p = call(outer, "GetOuter") end
        end
        if not valid(p) then return false end
        w = p
    end
    return false
end

-- class_widgets[key] = this pass's widgets of CLASS_PARTS[key] (never kept
-- past the pass).
local function class_widgets(key)
    local out = {}
    for _, cls in ipairs(CLASS_PARTS[key] or {}) do
        for _, w in ipairs(try(function() return FindAllOf(cls) end) or {}) do
            if valid(w) and not fname(w):find("^Default__") and in_hud(w) then out[#out + 1] = w end
        end
    end
    return out
end

local class_logged = {}
local function note_class(key, list)
    if CFG.debugLog == 1 and #list > 0 and not class_logged[key] then
        class_logged[key] = true
        log(string.format("%s: %d widget(s) in the HUD (%s)", key, #list, table.concat(CLASS_PARTS[key], ", ")))
    end
end

-- Lowest ProgressBar fill under a widget (small trees: the stat panel).
local function lowest_in(w, depth, best)
    if depth > 8 then return best end
    if cls_name(w):find("ProgressBar") then
        local pct = tonumber(get(w, "Percent"))
        if pct then best = math.min(best or 1, pct) end
    end
    each_child(w, function(c) best = lowest_in(c, depth + 1, best) end)
    return best
end

-- One-time census (debugLog 1), 15 s after the HUD appears: every
-- UserWidget whose parent chain reaches Canvas_BaseHUD, by class, with the
-- chain of its first instance. Written to dlls\hud_census.txt so the
-- health and hotbar classes can be pinned down.
local census_at, census_done = nil, false
local function chain_of(w)
    local names = {}
    for _ = 1, 40 do
        names[#names + 1] = fname(w)
        local p = call(w, "GetParent")
        if not valid(p) then
            local outer = call(w, "GetOuter")
            if valid(outer) and fname(outer) == "WidgetTree" then p = call(outer, "GetOuter") end
        end
        if not valid(p) then break end
        w = p
    end
    return table.concat(names, " < ")
end
local function census()
    local by_class, first = {}, {}
    for _, w in ipairs(try(function() return FindAllOf("UserWidget") end) or {}) do
        if valid(w) and not fname(w):find("^Default__") and in_hud(w) then
            local c = cls_name(w)
            by_class[c] = (by_class[c] or 0) + 1
            first[c] = first[c] or chain_of(w)
        end
    end
    local lines = {}
    for c, n in pairs(by_class) do lines[#lines + 1] = string.format("%-40s x%-3d %s", c, n, first[c]) end
    table.sort(lines)
    local f = io.open(ROOT .. "dlls\\hud_census.txt", "w")
    if f then f:write(table.concat(lines, "\n") .. "\n") f:close() end
    log(string.format("HUD census: %d widget types on the HUD -> dlls\\hud_census.txt", #lines))
end

------------------------------------------------------------------ rules
local HOTBAR_KEYS = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Zero" }
local hotbar_structs = nil
local hotbar_until, quest_until, weapon_until = 0, 0, 0
local quest_sig = nil
local held_addr = false   -- address of the item in your hands (nil = empty; false = not read yet)

local helpers_mod = nil
local function player_pc()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local pc = helpers_mod and try(function() return helpers_mod.GetPlayerController() end)
    return valid(pc) and pc or nil
end

-- The item actor in the player's hands, or nil (same path BetterGuns uses).
local equip_name = nil
local function held_item(pc)
    local pawn = pc and get(pc, "Pawn")
    if not valid(pawn) then return nil end
    local equip = equip_name and get(pawn, equip_name)
    if not valid(equip) then
        for _, n in ipairs({ "Equipment Component", "EquipmentComponent" }) do
            equip = get(pawn, n)
            if valid(equip) then equip_name = n break end
        end
    end
    if not valid(equip) then return nil end
    local item = try(function() return equip.HeldItem.ItemActor end)
    return valid(item) and item or nil
end

local targets = { health = 1, hotbar = 1, quest = 1, weapon = 1 }
local opacity = { health = 1, hotbar = 1, quest = 1, weapon = 1 }
local ticks = 0
local function decide(hud)
    local now = os.clock()
    ticks = ticks + 1
    -- Health area (every 0.5 s): shown while a bar is low. No bars found:
    -- it stays shown (it may hold the game's own warning icons).
    if ticks % 5 == 0 then
        local low = nil
        for _, r in ipairs(bars) do
            local b = follow(hud, r)
            local pct = b and tonumber(get(b, "Percent"))
            if pct then low = math.min(low or 1, pct) end
        end
        local panels = class_widgets("health")
        note_class("health", panels)
        for _, w in ipairs(panels) do low = lowest_in(w, 0, low) end
        targets.health = (low == nil or low * 100 < CFG.lowStatPercent) and 1 or 0
    end
    local pc = player_pc()
    -- Hotbar: any number key.
    if pc then
        if not hotbar_structs then
            hotbar_structs = {}
            for _, k in ipairs(HOTBAR_KEYS) do hotbar_structs[#hotbar_structs + 1] = { KeyName = FName(k) } end
        end
        for _, k in ipairs(hotbar_structs) do
            if call(pc, "IsInputKeyDown", k) == true then hotbar_until = now + CFG.hotbarShowSeconds break end
        end
        targets.hotbar = now < hotbar_until and 1 or 0
    end
    -- Weapon box (every 0.2 s): a new item in your hands -> shown for
    -- weaponShowSeconds; hands empty -> hidden.
    if ticks % 2 == 0 and #routes.weapon > 0 then
        local item = held_item(pc)
        local addr = item and LIB.address(item) or nil
        if addr ~= held_addr then
            if addr and held_addr ~= false then weapon_until = now + CFG.weaponShowSeconds end
            held_addr = addr
        end
        targets.weapon = (addr and now < weapon_until) and 1 or 0
    end
    -- Quest box (every 0.5 s): its text changed -> shown for questShowSeconds.
    if ticks % 5 == 0 and #routes.quest > 0 then
        local all = {}
        for _, r in ipairs(quest_texts) do
            local w = follow(hud, r)
            local t = w and try(function() return w:GetText():ToString() end)
            if t and t ~= "" then all[#all + 1] = t end
        end
        local sig = table.concat(all, "|")
        if sig ~= quest_sig then
            if quest_sig ~= nil then quest_until = now + CFG.questShowSeconds end
            quest_sig = sig
        end
        targets.quest = now < quest_until and 1 or 0
    end
end

local STEP_MS = 50
local function fading()
    for key, target in pairs(targets) do
        if opacity[key] ~= target then return true end
    end
    return false
end

local function fade(hud)
    local step = CFG.fadeSeconds > 0 and (STEP_MS / 1000) / CFG.fadeSeconds or 1
    for key, target in pairs(targets) do
        local o = opacity[key]
        if o ~= target then
            if o < target then o = math.min(target, o + step) else o = math.max(target, o - step) end
            -- Smoothstep so the start and end of each fade are soft.
            local shown = o * o * (3 - 2 * o)
            opacity[key] = o
            for _, e in ipairs(routes[key]) do
                local w = follow(hud, e.route)
                if w then call(w, "SetRenderOpacity", shown) end
            end
            local extra = class_widgets(key)
            note_class(key, extra)
            for _, w in ipairs(extra) do call(w, "SetRenderOpacity", shown) end
        end
    end
end

------------------------------------------------------------------ menus (hover info prep)
-- Which top-level screens open (inventory etc.), for the planned hover item
-- info. FindAllOf("UserWidget") is heavy: every 10 s, first 5 minutes only.
local seen_widgets, menu_runs, menu_at = {}, 0, 0
local function log_menus(now)
    if CFG.debugLog ~= 1 or menu_runs >= 30 or now < menu_at then return end
    menu_at = now + 10
    menu_runs = menu_runs + 1
    for _, w in ipairs(try(function() return FindAllOf("UserWidget") end) or {}) do
        if valid(w) and call(w, "IsInViewport") == true then
            local c = cls_name(w)
            if not seen_widgets[c] then
                seen_widgets[c] = true
                log("screen widget: " .. c)
            end
        end
    end
end

------------------------------------------------------------------ loop
-- Rules every 100 ms; fade steps every 50 ms only while something fades.
local scan_at, errors, odd = 0, 0, false
game_loop(STEP_MS, function()
    local ok, err = pcall(function()
        odd = not odd
        local busy = fading()
        if odd and not busy then return end
        local now = os.clock()
        local hud = find_hud()
        if not hud then hud_addr = nil return end
        local a = LIB.address(hud)
        if a ~= hud_addr or now >= scan_at then
            if a ~= hud_addr then
                if not scan(hud) then return end
                hud_addr = a
                -- A new HUD starts fully shown.
                for k in pairs(opacity) do opacity[k] = 1 end
            end
            scan_at = now + 3
            log_menus(now)
        end
        if CFG.debugLog == 1 and not census_done then
            census_at = census_at or (now + 15)
            if now >= census_at then census_done = true pcall(census) end
        end
        if not odd then decide(hud) end
        fade(hud)
    end)
    if not ok and errors < 10 then errors = errors + 1 log("error: " .. tostring(err)) end
end)

log(string.format("loaded: health area below %d%%, hotbar %d s after a key, weapon box %d s after a switch, quest %d s after a change",
    CFG.lowStatPercent, CFG.hotbarShowSeconds, CFG.weaponShowSeconds, CFG.questShowSeconds))
