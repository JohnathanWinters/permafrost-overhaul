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
    { "questShowSeconds",  6,    "quest box shows this long after it changes" },
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
local PREFIXES = { { "PreviousQuickSlot", "hotbar" }, { "NextQuickSlot", "hotbar" }, { "QuickSlots", "hotbar" },
                   { "UW_LedgerMenu", "menu" } }

-- Never walked into: the compass and its markers, the crosshairs.
local NO_WALK = { UW_HUDCompass = true, CrosshairSwitcher = true, Markers_CanvasPanel = true,
                  Canvas_WorldIndicators = true, Canvas_WorldMapMarkers = true }
-- The health bar (bottom left) and toolbelt (bottom right) are not in
-- Canvas_BaseHUD (user 2026-10-18), so the whole HUD is walked, matching
-- these words in a widget's name or class (lowercase). Menus and radial
-- menus are never entered.
local WORDS = {
    { "health", { "statuspanel", "charstatus", "statstatus", "healthbar", "vitals", "playerstats" } },
    { "hotbar", { "toolbelt", "quickslot", "hotbar", "quickbar", "beltslot" } },
}

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

local function group_of(name, cls)
    if PARTS[name] then return PARTS[name] end
    for _, p in ipairs(PREFIXES) do
        if name:sub(1, #p[1]) == p[1] then return p[2] end
    end
    local text = (name .. " " .. (cls or "")):lower()
    for _, g in ipairs(WORDS) do
        for _, w in ipairs(g[2]) do
            if text:find(w, 1, true) then return g[1] end
        end
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
local routes = { health = {}, hotbar = {}, quest = {}, weapon = {}, menu = {} }
local bars = {}           -- routes of ProgressBars inside the health parts
local quest_texts = {}    -- routes of TextBlocks inside the quest parts
local hud_addr = nil
local dumped = false

local ledger_parts   -- defined in scan
local function scan(hud)
    if not find_base(hud) then return false end   -- HUD not built yet
    routes = { health = {}, hotbar = {}, quest = {}, weapon = {}, menu = {} }
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
    -- The bottom-left stat diamonds and the bottom-right toolbelt are part of
    -- the inventory screen (UW_LedgerMenu), which stays on screen with only
    -- those two showing during play (the very first HUD version matched
    -- them there and both hid, user 2026-10-18). Only these names are taken
    -- from inside the menu.
    local LEDGER = { SizeBox_Stats = "health", QuickSlots = "hotbar" }
    function ledger_parts(menu, base)
        local function find(w, depth, route)
            if depth > 16 then return end
            local n = fname(w)
            local g = LEDGER[n]
            if g then
                routes[g][#routes[g] + 1] = { route = route, name = n }
                return
            end
            each_child(w, function(c, i)
                local r = { table.unpack(route) }
                r[#r + 1] = i
                find(c, depth + 1, r)
            end)
        end
        find(menu, 0, base)
    end
    local function rec(w, depth, route)
        if depth > 12 then return end
        local name = fname(w)
        local cls = cls_name(w)
        local g = group_of(name, cls)
        if dump and #dump < 500 then
            dump[#dump + 1] = string.rep("  ", depth) .. name .. " (" .. cls .. ")" .. (g and ("  <- " .. g) or "")
        end
        if g then
            local list = routes[g]
            list[#list + 1] = { route = route, name = name }
            if g == "health" then inner(w, 0, route, bars, "ProgressBar") end
            if g == "quest" then inner(w, 0, route, quest_texts, "TextBlock") end
            if g == "menu" then ledger_parts(w, route) end
            return
        end
        if NO_WALK[name] or cls:find("Menu", 1, true) or cls:find("Radial", 1, true) then return end
        each_child(w, function(c, i)
            local r = { table.unpack(route) }
            r[#r + 1] = i
            rec(c, depth + 1, r)
        end)
    end
    rec(hud, 0, {})
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


-- Lowest fill under a widget: ProgressBars, and "284/300"-style texts.
-- Also returns the widget holding that lowest value (for the log).
local function lowest_stat(w, depth, best, src)
    if depth > 8 then return best, src end
    local c = cls_name(w)
    if c:find("ProgressBar") then
        local pct = tonumber(get(w, "Percent"))
        if pct and pct < (best or 2) then best, src = pct, fname(w) end
    elseif c:find("TextBlock") then
        local t = try(function() return w:GetText():ToString() end)
        local a, b = t and t:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
        a, b = tonumber(a), tonumber(b)
        if a and b and b > 0 and a / b < (best or 2) then best, src = a / b, fname(w) .. " '" .. t .. "'" end
    end
    each_child(w, function(ch) best, src = lowest_stat(ch, depth + 1, best, src) end)
    return best, src
end

-- A menu is open when the game shows the mouse cursor. (The ledger menu
-- widget reports itself visible even when closed, which kept the whole HUD
-- shown, 2026-10-18.)
-- The player's own stats, read from the game's attribute sets (the stat
-- diamonds have no bars or "x/y" texts to read: 0 found and the health area
-- stayed shown, 2026-10-18). Each stat against its maximum; the lowest wins.
local STATS = {
    { "AttributeSet_HealthMetrics", "Health", "MaxHealth" },
    { "AttributeSet_StaminaMetrics", "Hunger", "MaxHunger" },
    { "AttributeSet_StaminaMetrics", "Energy", "MaxEnergy" },
    { "AttributeSet_StaminaMetrics", "Stamina", "MaxStamina" },
    { "AttributeSet_TemperatureMetrics", "BodyWarmth", "MaxBodyWarmth" },
}
local set_paths = {}         -- class -> path of the player's set
local function attr(set, f)
    local d = get(set, f)
    if type(d) == "number" then return d end
    return d and tonumber(try(function() return d.CurrentValue end)) or nil
end
local function player_set(pc, cls)
    local p = set_paths[cls]
    local s = p and LIB.resolve(p)
    if s then return s end
    local pawn = get(pc, "Pawn")
    local names = { valid(pawn) and fname(pawn) or nil }
    local ps = get(pc, "PlayerState")
    if valid(ps) then names[#names + 1] = fname(ps) end
    for _, o in ipairs(try(function() return FindAllOf(cls) end) or {}) do
        if valid(o) and not fname(o):find("^Default__") then
            local op = LIB.path_of(o)
            for _, n in ipairs(names) do
                if n and op and op:find(n, 1, true) then set_paths[cls] = op return o end
            end
        end
    end
    return nil
end
local function lowest_attribute(pc)
    local best, src = nil, nil
    for _, st in ipairs(STATS) do
        local set = player_set(pc, st[1])
        local v, m = set and attr(set, st[2]), set and attr(set, st[3])
        if v and m and m > 0 and v / m < (best or 2) then best, src = v / m, st[2] end
    end
    return best, src
end

local function menu_open(pc)
    return pc ~= nil and get(pc, "bShowMouseCursor") == true
end

------------------------------------------------------------------ rules
local HOTBAR_KEYS = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Zero" }
local hotbar_structs = nil
local hotbar_until, quest_until, weapon_until = 0, 0, 0
local quest_sig = nil
local was_menu = false   -- a menu was open on the last check
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
local health_logged = nil
local function decide(hud)
    local now = os.clock()
    ticks = ticks + 1
    -- Health area (every 0.5 s): shown while a bar is low. No bars found:
    -- it stays shown (it may hold the game's own warning icons).
    if ticks % 5 == 0 then
        local low, src = nil, nil
        for _, r in ipairs(bars) do
            local b = follow(hud, r)
            local pct = b and tonumber(get(b, "Percent"))
            if pct and pct < (low or 2) then low, src = pct, fname(b) end
        end
        for _, e in ipairs(routes.health) do
            local w = follow(hud, e.route)
            if w then low, src = lowest_stat(w, 0, low, src) end
        end
        local pcx = player_pc()
        if pcx then
            local a, asrc = lowest_attribute(pcx)
            if a and a < (low or 2) then low, src = a, asrc end
        end
        local want = (low == nil or low * 100 < CFG.lowStatPercent) and 1 or 0
        -- Logged on each change: which stat keeps the health area shown
        -- (user 2026-10-18: it stopped hiding; 0 bars were found).
        if want ~= targets.health or health_logged == nil then
            health_logged = true
            log(want == 1 and string.format("health area shown: lowest %s from %s", low and string.format("%.0f%%", low * 100) or "nothing readable", tostring(src))
                or string.format("health area hidden: lowest %.0f%% (%s)", (low or 1) * 100, tostring(src)))
        end
        targets.health = want
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
    -- Inventory open: everything shown (the toolbelt slots appear there too).
    if menu_open(pc) then
        for k in pairs(targets) do targets[k] = 1 end
        was_menu = true
        return
    end
    -- Menu just closed: the quest box gets its full time again (it hid at
    -- once when its time ran out while the inventory was open, 2026-10-18).
    if was_menu then
        was_menu = false
        quest_until = now + CFG.questShowSeconds
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
        end
    end
end

------------------------------------------------------------------ loop
-- Rules every 100 ms; fade steps every 50 ms only while something fades.
local scan_at, errors, odd = 0, 0, false
local seen_addr, settle_until = nil, 0
game_loop(STEP_MS, function()
    local ok, err = pcall(function()
        odd = not odd
        local busy = fading()
        if odd and not busy then return end
        local now = os.clock()
        local hud = find_hud()
        if not hud then hud_addr = nil return end
        local a = LIB.address(hud)
        if a ~= seen_addr then seen_addr, settle_until = a, now + 10 end
        if now < settle_until then return end
        if a ~= hud_addr or now >= scan_at then
            if a ~= hud_addr then
                if not scan(hud) then return end
                hud_addr = a
                -- A new HUD starts fully shown.
                for k in pairs(opacity) do opacity[k] = 1 end
            end
            scan_at = now + 3
        end
        if not odd then decide(hud) end
        fade(hud)
    end)
    if not ok and errors < 10 then errors = errors + 1 log("error: " .. tostring(err)) end
end)

log(string.format("loaded: health area below %d%%, hotbar %d s after a key, weapon box %d s after a switch, quest %d s after a change",
    CFG.lowStatPercent, CFG.hotbarShowSeconds, CFG.weaponShowSeconds, CFG.questShowSeconds))
