-- HUD module of the Overhaul (2026-10-18). User: every HUD element is always
-- on. Wanted:
--  * health area (health + the other stat bars next to it): only while one
--    of them is below lowStatPercent;
--  * hotbar: only for hotbarShowSeconds after a hotbar key is pressed;
--  * quest box on the left: fades out questShowSeconds after it changes;
--  * compass: untouched.
-- Fades are SetRenderOpacity steps (fadeSeconds, quick but smooth).
-- The game's HUD is the UW_HUD widget. Its parts are found by widget name
-- (HEALTH_NAMES etc. below) on each new HUD; every part found and the whole
-- tree (dlls\hud_tree.txt) are logged, so the patterns can be corrected.
-- Also logs which widgets open with menus (inventory etc.), for the planned
-- hover item info.
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

-- Name patterns (lowercase, plain find) for each group. First match wins per
-- widget; its children are then not searched.
local GROUPS = {
    { key = "health", words = { "statstatus", "stats", "healthbar", "health", "survivalstat", "vitals" } },
    { key = "hotbar", words = { "hotbar", "quickslot", "quickbar", "toolbelt", "beltslot" } },
    { key = "quest",  words = { "questtracker", "quest", "objective", "journaltrack", "tracker" } },
}
local SKIP_WORDS = { "compass" }

------------------------------------------------------------------ widget tree
local function children(w)
    local out = {}
    local n = tonumber(call(w, "GetChildrenCount"))
    if n and n > 0 then
        for i = 0, n - 1 do
            local c = call(w, "GetChildAt", i)
            if valid(c) then out[#out + 1] = c end
        end
    end
    -- A nested UserWidget keeps its content in its own tree.
    local tree = get(w, "WidgetTree")
    local root = valid(tree) and get(tree, "RootWidget")
    if valid(root) then out[#out + 1] = root end
    return out
end

local function cls_name(w)
    return fname(call(w, "GetClass")) or "?"
end

local function group_of(w)
    local text = (fname(w) .. " " .. cls_name(w)):lower()
    for _, s in ipairs(SKIP_WORDS) do if text:find(s, 1, true) then return "skip" end end
    for _, g in ipairs(GROUPS) do
        for _, word in ipairs(g.words) do
            if text:find(word, 1, true) then return g.key end
        end
    end
    return nil
end

-- parts[key] = { paths of widgets }
local parts = { health = {}, hotbar = {}, quest = {} }
local hud_addr = nil
local dump_lines = nil

local function holds_skip(w, depth)
    if depth > 0 and group_of(w) == "skip" then return true end
    if depth > 12 then return false end
    for _, c in ipairs(children(w)) do
        if holds_skip(c, depth + 1) then return true end
    end
    return false
end

local function walk(w, depth)
    if depth > 14 then return end
    local g = group_of(w)
    if dump_lines and #dump_lines < 600 then
        dump_lines[#dump_lines + 1] = string.rep("  ", depth) .. fname(w) .. " (" .. cls_name(w) .. ")" .. (g and ("  <- " .. g) or "")
    end
    -- A match that holds the compass is too big a box: look inside instead.
    if g and g ~= "skip" and holds_skip(w, 0) then g = nil end
    if g and g ~= "skip" then
        local list = parts[g]
        list[#list + 1] = LIB.path_of(w)
        if not dump_lines then return end   -- keep walking only while dumping
    end
    for _, c in ipairs(children(w)) do walk(c, depth + 1) end
end

local dumped = false
local function scan_hud()
    local huds = try(function() return FindAllOf("UW_HUD_C") end) or {}
    for _, h in ipairs(huds) do
        if valid(h) and not fname(h):find("^Default__") and call(h, "IsInViewport") == true then
            local a = LIB.address(h)
            if a == hud_addr then return true end
            hud_addr = a
            parts = { health = {}, hotbar = {}, quest = {} }
            dump_lines = (CFG.debugLog == 1 and not dumped) and {} or nil
            walk(h, 0)
            if dump_lines then
                dumped = true
                local f = io.open(ROOT .. "dlls\\hud_tree.txt", "w")
                if f then f:write(table.concat(dump_lines, "\n") .. "\n") f:close() end
                log("HUD tree written to dlls\\hud_tree.txt (" .. #dump_lines .. " widgets)")
                dump_lines = nil
            end
            for k, list in pairs(parts) do
                local names = {}
                for _, p in ipairs(list) do names[#names + 1] = p:match("[%.:]([^%.:]+)$") or p end
                log(string.format("%s: %d part(s) %s", k, #list, table.concat(names, ", ")))
            end
            return true
        end
    end
    return false
end

------------------------------------------------------------------ visibility rules
local function each_part(key, fn)
    for _, p in ipairs(parts[key]) do
        local w = LIB.resolve(p)
        if w then fn(w) end
    end
end

-- Lowest ProgressBar fill (0..1) under the health parts.
local function lowest_bar(w, depth, best)
    if depth > 8 then return best end
    local pct = tonumber(get(w, "Percent"))
    if pct and cls_name(w):find("ProgressBar") then best = math.min(best, pct) end
    for _, c in ipairs(children(w)) do best = lowest_bar(c, depth + 1, best) end
    return best
end

local HOTBAR_KEYS = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Zero" }
local hotbar_structs = nil
local hotbar_until, quest_until = 0, 0
local quest_sig = nil

local function texts(w, depth, out)
    if depth > 8 or #out > 20 then return out end
    if cls_name(w):find("TextBlock") then
        local t = try(function() return w:GetText():ToString() end)
        if t and t ~= "" then out[#out + 1] = t end
    end
    for _, c in ipairs(children(w)) do texts(c, depth + 1, out) end
    return out
end

local helpers_mod = nil
local function player_pc()
    helpers_mod = helpers_mod or try(function() return require("UEHelpers") end)
    local pc = helpers_mod and try(function() return helpers_mod.GetPlayerController() end)
    return valid(pc) and pc or nil
end

local targets = { health = 1, hotbar = 1, quest = 1 }
local opacity = { health = 1, hotbar = 1, quest = 1 }
local ticks = 0
local function decide()
    local now = os.clock()
    ticks = ticks + 1
    -- Health area: lowest bar every 0.5 s.
    if ticks % 10 == 0 and #parts.health > 0 then
        local low = 1
        each_part("health", function(w) low = lowest_bar(w, 0, low) end)
        targets.health = (low * 100 < CFG.lowStatPercent) and 1 or 0
    end
    -- Hotbar: any number key.
    local pc = player_pc()
    if pc and #parts.hotbar > 0 then
        if not hotbar_structs then
            hotbar_structs = {}
            for _, k in ipairs(HOTBAR_KEYS) do hotbar_structs[#hotbar_structs + 1] = { KeyName = FName(k) } end
        end
        for _, k in ipairs(hotbar_structs) do
            if call(pc, "IsInputKeyDown", k) == true then hotbar_until = now + CFG.hotbarShowSeconds break end
        end
        targets.hotbar = now < hotbar_until and 1 or 0
    end
    -- Quest box: its text changed -> show for questShowSeconds.
    if ticks % 10 == 0 and #parts.quest > 0 then
        local all = {}
        each_part("quest", function(w) texts(w, 0, all) end)
        local sig = table.concat(all, "|")
        if sig ~= quest_sig then
            if quest_sig ~= nil then quest_until = now + CFG.questShowSeconds end
            quest_sig = sig
        end
        targets.quest = now < quest_until and 1 or 0
    end
end

local STEP_MS = 50
local function fade()
    local step = CFG.fadeSeconds > 0 and (STEP_MS / 1000) / CFG.fadeSeconds or 1
    for key, target in pairs(targets) do
        local o = opacity[key]
        if o ~= target then
            if o < target then o = math.min(target, o + step) else o = math.max(target, o - step) end
            -- Smoothstep so the start and end of each fade are soft.
            local shown = o * o * (3 - 2 * o)
            opacity[key] = o
            each_part(key, function(w) call(w, "SetRenderOpacity", shown) end)
        end
    end
end

------------------------------------------------------------------ menus (hover info prep)
local seen_widgets, seen_logged = {}, 0
local function log_menus()
    if CFG.debugLog ~= 1 or seen_logged >= 60 then return end
    for _, w in ipairs(try(function() return FindAllOf("UserWidget") end) or {}) do
        if valid(w) and call(w, "IsInViewport") == true then
            local c = cls_name(w)
            if not seen_widgets[c] then
                seen_widgets[c] = true
                seen_logged = seen_logged + 1
                log("screen widget: " .. c)
            end
        end
    end
end

------------------------------------------------------------------ loop
local scan_at = 0
game_loop(STEP_MS, function()
    local ok, err = pcall(function()
        local now = os.clock()
        if now >= scan_at then
            scan_at = now + 3
            if not scan_hud() then return end
            log_menus()
        end
        if not hud_addr then return end
        decide()
        fade()
    end)
    if not ok and seen_logged < 60 then seen_logged = seen_logged + 1 log("error: " .. tostring(err)) end
end)

log(string.format("loaded: health area below %d%%, hotbar %d s after a key, quest %d s after a change",
    CFG.lowStatPercent, CFG.hotbarShowSeconds, CFG.questShowSeconds))
