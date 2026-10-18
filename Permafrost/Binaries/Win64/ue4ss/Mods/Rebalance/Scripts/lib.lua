-- Shared helpers for every Overhaul module (2026-10-17). Loaded once by
-- main.lua as the global REBALANCE_LIB. Each module used to carry its own
-- copy of these.
--
-- The helpers never build a new function per call: the old pattern
-- try(function() return obj:IsValid() end) created a closure on every call,
-- thousands per second in the fast loops, and the garbage they left was
-- collected in small regular pauses. Here pcall runs fixed functions with
-- the object passed in, which allocates nothing.
local L = {}
local pcall, type = pcall, type

local function _isvalid(o) return o:IsValid() end
local function _fname(o) return o:GetFName():ToString() end
local function _full(o) return o:GetFullName() end
local function _addr(o) return o:GetAddress() end
local function _get(o, k) return o[k] end
local function _set(o, k, v) o[k] = v end
local function _call(o, m, ...) return o[m](o, ...) end
local function _find(p) return StaticFindObject(p) end

-- Runs fn and returns its first result, or nil if it raised. Builds a
-- closure at each call site, so keep it out of fast loops.
function L.try(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

function L.valid(o)
    if o == nil then return false end
    local ok, v = pcall(_isvalid, o)
    return ok and v == true
end

-- o[k], or nil if reading it raised.
function L.get(o, k)
    if o == nil then return nil end
    local ok, v = pcall(_get, o, k)
    if ok then return v end
    return nil
end

-- o[k] = v; true when it worked.
function L.set(o, k, v)
    if o == nil then return false end
    return (pcall(_set, o, k, v))
end

-- o:m(...), first result or nil if it raised.
function L.call(o, m, ...)
    if o == nil then return nil end
    local ok, v = pcall(_call, o, m, ...)
    if ok then return v end
    return nil
end

function L.fname(o)
    if o == nil then return "?" end
    local ok, v = pcall(_fname, o)
    return ok and v or "?"
end

-- Path -> class name, recorded whenever a path is made from an object, so
-- L.resolve can find the object again WITHOUT StaticFindObject (see below).
local path_class = {}
local function short_of(path)
    return path:match("[%.:]([^%.:]+)$") or path
end
local function remember(o, s)
    -- "Class /Path.To:Object" -> path + class name
    local cls, path = s:match("^(%S+)%s+(.+)$")
    if path and cls and not path_class[path] then path_class[path] = cls end
    return path or s
end

-- Full name without the class prefix (an object path), "?" if unknown.
function L.full(o)
    if o == nil then return "?" end
    local ok, s = pcall(_full, o)
    if not ok or type(s) ~= "string" then return "?" end
    return remember(o, s)
end

-- Same, "" if unknown.
function L.path_of(o)
    if o == nil then return "" end
    local ok, s = pcall(_full, o)
    if not ok or type(s) ~= "string" then return "" end
    return remember(o, s)
end

-- Lets a module name the class of a path it built by hand (assets).
function L.register(path, class_name)
    if type(path) == "string" and type(class_name) == "string" then path_class[path] = class_name end
end

-- Live instances of a class by short name, from FindAllOf (this UE4SS build
-- answers it from the engine's per-class hash: ~0.1 ms). Cached for 100 ms.
-- Map: short name -> list of objects (components often share a name).
local live_cache = {}        -- class -> { t, map name -> object }
local function _findall(c) return FindAllOf(c) end
function L.live(class_name)
    local now = os.clock()
    local c = live_cache[class_name]
    if c and now - c.t < 0.1 then return c.map end
    local map = {}
    local ok, list = pcall(_findall, class_name)
    if ok and type(list) == "table" then
        for _, o in ipairs(list) do
            local okn, n = pcall(_fname, o)
            if okn and n then
                local t = map[n]
                if t then t[#t + 1] = o else map[n] = { o } end
            end
        end
    end
    live_cache[class_name] = { t = now, map = map }
    return map
end

function L.address(o)
    if not L.valid(o) then return nil end
    local ok, a = pcall(_addr, o)
    if not ok or type(a) ~= "number" or a <= 0 then return nil end
    return a
end

-- The live object at a path, or nil. Keep paths, never objects, across frames.
-- UE4SS's Lua StaticFindObject walks EVERY object in the game, and a walk
-- that meets an object being built or destroyed (async loading, a dialogue
-- opening, quitting) crashed inside UE4SS (UObject::GetOutermost on a
-- garbage outer, 3 crashes on 2026-10-17). So a path whose class is known is
-- found through L.live(class) instead; only paths of unknown class (fixed
-- asset and /Script paths, normally looked up once at startup) still use
-- StaticFindObject.
function L.resolve(path)
    if type(path) ~= "string" or path == "" or path == "?" then return nil end
    local cls = path_class[path]
    if cls then
        local list = L.live(cls)[short_of(path)]
        if not list then return nil end
        for _, o in ipairs(list) do
            if L.valid(o) and L.path_of(o) == path then return o end
        end
        return nil
    end
    local ok, o = pcall(_find, path)
    if ok and L.valid(o) then return o end
    return nil
end

-- Game-thread scheduling. LoopAsync + ExecuteInGameThread raced in UE4SS and
-- crashed the game (2026-10-16); these run on the game thread directly.
function L.game_loop(ms, fn)
    if REBALANCE_LOOP then REBALANCE_LOOP(ms, fn) return end
    if type(LoopInGameThreadWithDelay) == "function" then
        LoopInGameThreadWithDelay(ms, function() fn() return false end)
    else
        LoopAsync(ms, function() ExecuteInGameThread(fn) return false end)
    end
end

function L.game_later(ms, fn)
    if type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(ms, fn)
    else
        ExecuteWithDelay(ms, function() ExecuteInGameThread(fn) end)
    end
end

return L
