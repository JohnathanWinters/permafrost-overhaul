-- Overhaul (folder name Rebalance): one mod for a harder, more believable
-- survival game. This loader:
--   1. reads config.lua, the only settings file (one section per category),
--   2. writes each module's small internal settings file from its sections
--      (config\<Module>.lua; the DLL writes survivaltweaks\config.lua
--      itself, because it reads it before any Lua runs),
--   3. runs each module switched on in the Modules section, each in its own
--      chunk so modules cannot clash.
local TAG = "[PF Rebalance] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

local function root()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("/", "\\")
    local base = src:match("^(.*\\)[Ss]cripts\\main%.lua$")
    if base then return base end
    local ok, dirs = pcall(IterateGameDirectories)
    local win64 = ok and dirs and dirs.Game and dirs.Game.Binaries and dirs.Game.Binaries.Win64
    if win64 and win64.__absolute_path then return win64.__absolute_path .. "\\ue4ss\\Mods\\Rebalance\\" end
    return ""
end
REBALANCE_ROOT = root()

-- Shared helpers for all modules (must load before any module).
do
    local ok, lib = pcall(dofile, REBALANCE_ROOT .. "Scripts\\lib.lua")
    if ok and type(lib) == "table" then
        REBALANCE_LIB = lib
    else
        log("lib.lua FAILED to load: " .. tostring(lib))
    end
end

-- Shared libraries (Scripts\<name>.lua that return a table, e.g. lootdata,
-- rules): loaded once, on first use, by whichever module asks. Modules never
-- load each other, so any module can be turned off on its own.
local shared = {}
function REBALANCE_SHARED(name)
    if shared[name] == nil then
        local ok, m = pcall(dofile, REBALANCE_ROOT .. "Scripts\\" .. name .. ".lua")
        if not ok then error("shared library " .. name .. " failed: " .. tostring(m)) end
        shared[name] = m
    end
    return shared[name]
end

-- Generational garbage collection (Lua 5.4): many short-lived objects are
-- freed in small steady steps instead of the incremental collector's larger
-- sweeps, which showed up as small regular pauses.
pcall(collectgarbage, "generational")

------------------------------------------------------------------ player controller
-- UEHelpers.GetPlayerController runs FindAllOf("PlayerController") on every
-- call, and the modules call it 20+ times a second. Replaced (for every
-- module, since require caches the table) by a version that searches at
-- most every 2 s and otherwise looks the controller up by its path. Never
-- holds the object itself across frames.
do
    local ok, H = pcall(require, "UEHelpers")
    if ok and type(H) == "table" and type(H.GetPlayerController) == "function" then
        local slow = H.GetPlayerController
        local pc_path, next_search = nil, 0
        H.GetPlayerController = function()
            local L = REBALANCE_LIB
            if pc_path and L then
                -- FindAllOf-based lookup, never StaticFindObject (full object walk).
                local pc = L.resolve(pc_path)
                if pc then return pc end
                pc_path = nil
            end
            local now = os.clock()
            if now < next_search then return CreateInvalidObject() end
            next_search = now + 2
            local pc = slow()
            if pc and pc:IsValid() and L then
                pc_path = L.path_of(pc)
                if pc_path == "" then pc_path = nil end
            end
            return pc
        end
    end
end

------------------------------------------------------------------ diagnostics
-- One switch, Modules.diagnostics in config.lua (1 = on, 0 = off):
--   * profiler: times every game-thread callback the modules register
--     (loops, delayed calls, hooks, the BeginPlay watcher). Logs callbacks
--     over 8 ms and the top costs every 15 s to UE4SS.log.
--   * flight recorder: once a second one line goes to dlls\flight.txt (the
--     last 2 minutes are kept, rewritten each second): what ran that second,
--     the slowest callback, Lua memory, and recent mod events
--     (REBALANCE_EVENT). After a crash it shows the final 2 minutes.
--   * dlls\main.dll writes dlls\crash_report.txt the moment a crash happens
--     (it reads the same switch).
-- Off = no wrapping at all, zero cost. os.clock has 1 ms steps; summed over
-- many calls the totals are still fair estimates.
local DIAG = true
do
    local f = io.open(REBALANCE_ROOT .. "config.lua", "r")
    if f then
        local text = f:read("*a")
        f:close()
        local v = text:match("\n%s*diagnostics%s*=%s*(%d)")
        if v == "0" then DIAG = false end
    end
end
REBALANCE_DIAG = DIAG

local prof = { stats = {}, sec = {}, slow_logged = 0 }
local clock = os.clock
local function prof_key(fn)
    local info = debug.getinfo(fn, "S")
    local src = info and info.short_src or "?"
    return (src:match("([^\\/]+)%.lua") or src) .. ":" .. tostring(info and info.linedefined or 0)
end
local function bump(t, key, ms)
    local s = t[key]
    if not s then s = { n = 0, total = 0, max = 0 } t[key] = s end
    s.n = s.n + 1
    s.total = s.total + ms
    if ms > s.max then s.max = ms end
end
local function prof_record(key, ms)
    bump(prof.stats, key, ms)
    bump(prof.sec, key, ms)
    if ms >= 8 and prof.slow_logged < 40 then
        prof.slow_logged = prof.slow_logged + 1
        log(string.format("PROFILE slow callback %s: %.0f ms", key, ms))
    end
end
local function prof_wrap(fn, key)
    if not DIAG or type(fn) ~= "function" then return fn end
    key = key or prof_key(fn)
    return function(...)
        local t0 = clock()
        local ok, a, b, c = pcall(fn, ...)
        prof_record(key, (clock() - t0) * 1000)
        if not ok then error(a, 0) end
        return a, b, c
    end
end
REBALANCE_PROF_WRAP = prof_wrap

-- Notable mod events for the flight recorder (cheap: kept in memory, written
-- with the next second's line).
local events = {}
function REBALANCE_EVENT(text)
    if not DIAG then return end
    if #events < 20 then events[#events + 1] = tostring(text) end
end

local raw_loop, raw_later = LoopInGameThreadWithDelay, ExecuteInGameThreadWithDelay
prof.raw_loop, prof.raw_later = raw_loop, raw_later
-- Module loop helpers call this so each loop is timed under its own source
-- line (not the helper's).
function REBALANCE_LOOP(ms, fn)
    local timed = prof_wrap(fn)
    raw_loop(ms, function() timed() return false end)
end

local function prof_report()
    local rows, sum = {}, 0
    for k, s in pairs(prof.stats) do rows[#rows + 1] = { k, s } sum = sum + s.total end
    prof.stats = {}
    if sum < 5 then return end
    table.sort(rows, function(a, b) return a[2].total > b[2].total end)
    local parts = {}
    for i = 1, math.min(6, #rows) do
        local k, s = rows[i][1], rows[i][2]
        parts[#parts + 1] = string.format("%s %.0f ms/%d calls (max %.0f)", k, s.total, s.n, s.max)
    end
    log(string.format("PROFILE last 15 s: %.0f ms total; %s", sum, table.concat(parts, "; ")))
end

local FLIGHT_FILE = REBALANCE_ROOT .. "dlls\\flight.txt"
local flight = {}            -- ring of the last 120 lines
local function flight_tick()
    local rows, sum, calls, worst, worst_key = {}, 0, 0, 0, "-"
    for k, s in pairs(prof.sec) do
        rows[#rows + 1] = { k, s }
        sum = sum + s.total
        calls = calls + s.n
        if s.max > worst then worst, worst_key = s.max, k end
    end
    prof.sec = {}
    table.sort(rows, function(a, b) return a[2].total > b[2].total end)
    local top = {}
    for i = 1, math.min(3, #rows) do
        top[#top + 1] = string.format("%s %.0fms/%d", rows[i][1], rows[i][2].total, rows[i][2].n)
    end
    local line = string.format("%s lua %.0f ms in %d calls, worst %s %.0f ms; mem %.0f KB; top %s%s",
        os.date("%H:%M:%S"), sum, calls, worst_key, worst, collectgarbage("count"),
        #top > 0 and table.concat(top, ", ") or "-",
        #events > 0 and (" | events: " .. table.concat(events, "; ")) or "")
    events = {}
    flight[#flight + 1] = line
    if #flight > 120 then table.remove(flight, 1) end
    local f = io.open(FLIGHT_FILE, "wb")
    if f then
        f:write(table.concat(flight, "\n"), "\n")
        f:close()
    end
end

if DIAG then
    local raw_frames, raw_hook = LoopInGameThreadAfterFrames, RegisterHook
    if type(raw_loop) == "function" then
        LoopInGameThreadWithDelay = function(ms, fn, ...) return raw_loop(ms, prof_wrap(fn), ...) end
        raw_loop(15000, function() pcall(prof_report) return false end)
        raw_loop(1000, function() pcall(flight_tick) return false end)
    end
    if type(raw_later) == "function" then
        ExecuteInGameThreadWithDelay = function(ms, fn, ...) return raw_later(ms, prof_wrap(fn), ...) end
    end
    if type(raw_frames) == "function" then
        LoopInGameThreadAfterFrames = function(n, fn, ...) return raw_frames(n, prof_wrap(fn), ...) end
    end
    if type(raw_hook) == "function" then
        RegisterHook = function(path, pre, post, ...)
            local short = tostring(path):match("([^:%.]+)$") or "?"
            return raw_hook(path, prof_wrap(pre, "hook " .. short), post and prof_wrap(post, "hook post " .. short), ...)
        end
    end
    -- Every module message also becomes a flight recorder event (this mod's
    -- own Lua state only; other UE4SS mods are not affected).
    local raw_print = print
    print = function(...)
        raw_print(...)
        local msg = tostring((...) or ""):gsub("%s+$", "")
        REBALANCE_EVENT(msg:gsub("^%[PF ", "["))
    end
    log("diagnostics on: profiler + flight recorder (dlls\\flight.txt); set Modules.diagnostics = 0 to turn off")
else
    log("diagnostics off")
end

------------------------------------------------------------------ object watchers
-- Never use NotifyOnNewObject. It runs its Lua callback on whatever thread
-- creates the object, and World Partition streaming creates actors and assets
-- on the async loading thread. Lua then ran on two threads at once and
-- corrupted memory: random crashes in render, Niagara, physics, save and UE4SS
-- code, all a few seconds after a save loaded (2026-10-17). Both watchers
-- below only ever run on the game thread.
--
-- REBALANCE_ON_ACTOR(class_path, fn [, name_filter])
--   fn(actor) at the end of each matching actor's BeginPlay. name_filter(class
--   name) can narrow it further; the match is worked out once per class.
-- REBALANCE_ON_ASSET(class_name, fn [, ms])
--   fn(obj) for each object of that class that appears, found by a FindAllOf
--   poll (default every 6 s). An object that vanished and came back counts
--   as new.
local function wtry(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end
local function wvalid(o)
    return o ~= nil and wtry(function() return o:IsValid() end) == true
end

local actor_watchers = {}   -- { cls = UClass, fn, filter }
local class_cache = {}      -- class address -> { name, list of fns }
local begin_play_hooked = false
local function actor_handlers(actor)
    local cls = wtry(function() return actor:GetClass() end)
    if not wvalid(cls) then return nil end
    local addr = wtry(function() return cls:GetAddress() end)
    local name = wtry(function() return cls:GetFName():ToString() end) or ""
    local c = addr and class_cache[addr]
    if c and c.name == name then return c.fns end
    local fns = {}
    for _, w in ipairs(actor_watchers) do
        if wtry(function() return actor:IsA(w.cls) end) == true
            and (not w.filter or wtry(function() return w.filter(name) end)) then
            fns[#fns + 1] = w.fn
        end
    end
    if addr then class_cache[addr] = { name = name, fns = fns } end
    return fns
end
local function on_begin_play(ctx)
    local actor = ctx
    local got = wtry(function() return ctx:get() end)
    if got ~= nil then actor = got end
    if not wvalid(actor) then return end
    local fns = actor_handlers(actor)
    if not fns then return end
    for _, fn in ipairs(fns) do pcall(fn, actor) end
end
function REBALANCE_ON_ACTOR(class_path, fn, filter)
    local cls = wtry(function() return StaticFindObject(class_path) end)
    if not wvalid(cls) then
        log("watch FAILED (class not found): " .. class_path)
        return false
    end
    actor_watchers[#actor_watchers + 1] = { cls = cls, fn = fn, filter = filter }
    class_cache = {}
    if not begin_play_hooked then
        if type(RegisterBeginPlayPostHook) ~= "function" then
            log("watch FAILED: this UE4SS has no RegisterBeginPlayPostHook")
            return false
        end
        local ok, err = pcall(RegisterBeginPlayPostHook, prof_wrap(on_begin_play, "BeginPlay watcher"))
        if not ok then
            log("watch FAILED: RegisterBeginPlayPostHook: " .. tostring(err))
            return false
        end
        begin_play_hooked = true
    end
    return true
end

-- All asset watches share ONE loop that polls one class per tick (750 ms),
-- round robin, so no two FindAllOf ever land on the same frame and each
-- class is still checked every few seconds (eight classes: every 6 s).
local asset_polls = {}       -- { timed poll function }
local asset_next = 1
local asset_loop_started = false
local function asset_tick()
    local n = #asset_polls
    if n == 0 then return false end
    if asset_next > n then asset_next = 1 end
    pcall(asset_polls[asset_next])
    asset_next = asset_next + 1
    return false
end
function REBALANCE_ON_ASSET(class_name, fn)
    local seen = {}            -- address -> object name
    local L = REBALANCE_LIB
    local function poll()
        local now = {}
        for _, o in ipairs(wtry(function() return FindAllOf(class_name) end) or {}) do
            local addr = L and L.address(o) or wtry(function() return o:GetAddress() end)
            local name = L and L.fname(o) or ""
            if addr and not name:find("^Default__") then
                now[addr] = name
                if seen[addr] ~= name then pcall(fn, o) end
            end
        end
        seen = now
    end
    asset_polls[#asset_polls + 1] = prof_wrap(poll, "asset poll " .. class_name)
    if not asset_loop_started then
        local every = prof.raw_loop or LoopInGameThreadWithDelay
        if type(every) ~= "function" then
            log("asset watch FAILED (no game-thread scheduler): " .. class_name)
            return false
        end
        asset_loop_started = true
        every(750, asset_tick)
    end
    return true
end

local ORDER = { "loot", "containers", "locks", "enemydrops", "encounters", "spawndistance", "patrols", "humanai",
                "harderhunting", "betterguns", "flashlight", "togglemovement", "eternaltorches", "craftfromstorage",
                "survivaltweaks", "toolbelt", "accuracy", "recipes", "food", "hud", "buildsnow", "warmth", "weather", "travelcost", "bedtravel", "doors", "f8log" }

-- Internal file per module, built from these config.lua sections (later
-- sections win on a shared key).
local SPLIT = {
    { file = "config\\Loot.lua",           sections = { "Loot", "Enemies" } },
    { file = "config\\EnemyDrops.lua",     sections = { "Enemies" } },
    { file = "config\\Encounters.lua",     sections = { "Encounters" } },
    { file = "config\\SpawnDistance.lua",  sections = { "Spawns", "Encounters" } },
    { file = "config\\HarderHunting.lua",  sections = { "Hunting" } },
    { file = "config\\BetterGuns.lua",     sections = { "Guns" } },
    { file = "config\\ToggleMovement.lua", sections = { "Movement" } },
    { file = "config\\EternalTorches.lua", sections = { "Torches" } },
    { file = "config\\CraftFromStorage.lua", sections = { "Crafting" } },
    { file = "config\\Toolbelt.lua",       sections = { "Toolbelt" } },
    { file = "config\\HumanAI.lua",        sections = { "HumanAI" } },
    { file = "config\\Patrols.lua",        sections = { "Patrols" } },
    { file = "config\\Flashlight.lua",     sections = { "Flashlight" } },
    { file = "config\\Recipes.lua",        sections = { "Recipes" } },
    { file = "config\\Food.lua",           sections = { "Food" } },
    { file = "config\\HUD.lua",            sections = { "HUD" } },
    { file = "config\\Survival.lua",       sections = { "Survival" } },
    { file = "config\\Accuracy.lua",       sections = { "Accuracy" } },
    { file = "config\\Weather.lua",        sections = { "Weather" } },
    { file = "config\\TravelCost.lua",     sections = { "TravelCost" } },
    { file = "config\\BuildSnow.lua",      sections = { "BuildSnow" } },
    { file = "config\\BedTravel.lua",      sections = { "BedTravel" } },
    { file = "config\\Containers.lua",       list = "Containers" },
}

local function read_config()
    local f = io.open(REBALANCE_ROOT .. "config.lua", "r")
    if not f then return nil, "config.lua missing" end
    local text = f:read("*a")
    f:close()
    local chunk, err = load(text, "config.lua", "t", {})
    if not chunk then return nil, err end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= "table" then return nil, tostring(t) end
    return t
end

-- Plain Lua literal for numbers, strings and nested tables.
local function literal(v, ind)
    ind = ind or ""
    if type(v) == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.6g", v)
    elseif type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "table" then
        local parts = {}
        if #v > 0 then
            for _, x in ipairs(v) do parts[#parts + 1] = ind .. "    " .. literal(x, ind .. "    ") end
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                parts[#parts + 1] = ind .. "    " .. tostring(k) .. " = " .. literal(v[k], ind .. "    ")
            end
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. ind .. "}"
    end
    return "nil"
end

local function write_internal(cfg)
    for _, s in ipairs(SPLIT) do
        local value
        if s.list then
            value = cfg[s.list]
        else
            value = {}
            for _, name in ipairs(s.sections) do
                for k, v in pairs(cfg[name] or {}) do value[k] = v end
            end
        end
        if type(value) == "table" then
            local f = io.open(REBALANCE_ROOT .. s.file, "w")
            if f then
                f:write("-- GENERATED from config.lua at every game start. Edit config.lua, not this file.\n")
                f:write("return " .. literal(value, "") .. "\n")
                f:close()
            end
        end
    end
end

local cfg, err = read_config()
local enabled = {}
for _, m in ipairs(ORDER) do enabled[m] = 1 end
if cfg then
    local ok, werr = pcall(write_internal, cfg)
    if not ok then log("could not write module settings: " .. tostring(werr)) end
    for k, v in pairs(cfg.Modules or {}) do enabled[k] = tonumber(v) end
    log("settings read from config.lua")
else
    log("config.lua unreadable (" .. tostring(err) .. "); modules use their last settings")
end

for _, m in ipairs(ORDER) do
    if enabled[m] == 1 then
        local ok, merr = pcall(dofile, REBALANCE_ROOT .. "Scripts\\" .. m .. ".lua")
        log((ok and "module loaded: " or "module FAILED: ") .. m .. (ok and "" or (" " .. tostring(merr))))
    else
        log("module off: " .. m)
    end
end
