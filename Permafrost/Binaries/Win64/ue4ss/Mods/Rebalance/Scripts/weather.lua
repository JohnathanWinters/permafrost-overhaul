-- Weather module of the Overhaul (2026-10-18). User: storms are too rare.
-- Each weather condition (UData_WeatherCondition: ClearSky, FogNight,
-- Fog_Day, DustStorm, AuroraBorealis, Snow, Blizzard) has Requirements with
-- a Probability and a Cooldown. Blizzard's chance is multiplied by
-- blizzardChanceMultiplier and its cooldown by blizzardCooldownMultiplier;
-- Snow (whose heavy phase is the snowstorm) has its own pair. Every
-- condition's vanilla values are logged once. Edited in memory each time a
-- condition asset loads; nothing on disk.
-- Settings: Weather section of config.lua. Log tag [PF Weather].
local TAG = "[PF Weather] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, fname = LIB.try, LIB.fname
local get = LIB.get
local ROOT = REBALANCE_ROOT or ""

local DEFAULTS = {
    { "blizzardChanceMultiplier",   1.75, "how much more likely blizzards are" },
    { "blizzardCooldownMultiplier", 0.7,  "how much shorter the wait between blizzards is" },
    { "snowChanceMultiplier",       3.0,  "how much more likely snowfall (and snowstorms) is" },
    { "snowCooldownMultiplier",     0.5,  "how much shorter the wait between snowfalls is" },
    { "blizzardShareOfSnow",        0.6,  "blizzards never end up more likely than this share of snowfall" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Weather.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Weather.lua", "t", {})
    local user = chunk and try(chunk)
    if type(user) == "table" then
        for _, d in ipairs(DEFAULTS) do
            local v = tonumber(user[d[1]])
            if v then cfg[d[1]] = math.max(0, math.min(20, v)) end
        end
    end
    return cfg
end
local CFG = load_config()

local RULES = {
    Blizzard = { "blizzardChanceMultiplier", "blizzardCooldownMultiplier" },
    Snow = { "snowChanceMultiplier", "snowCooldownMultiplier" },
}

-- A number field or a struct holding one (Cooldown may be a range).
local function read_num(st, f)
    local v = try(function() return st[f] end)
    if type(v) == "number" then return v, nil end
    for _, sub in ipairs({ "Value", "Min", "Max", "X", "LowerBound" }) do
        local x = v and try(function() return v[sub] end)
        if type(x) == "number" then return x, sub end
    end
    return nil, nil
end
local function write_num(st, f, sub, value)
    if sub then
        local v = try(function() return st[f] end)
        return v and try(function() v[sub] = value; return true end) == true
    end
    return try(function() st[f] = value; return true end) == true
end

local done = {}   -- asset address -> true
-- Snow must stay more common than blizzards (user 2026-10-18): once both
-- are known, a blizzard chance above blizzardShareOfSnow x snow chance is
-- lowered to it, but never below 1.2 x its vanilla chance.
local final = {}  -- name -> { path, sub, vanilla, now } (the asset path, never a kept struct)
local function keep_snow_ahead()
    local b, s = final.Blizzard, final.Snow
    if not (b and s and b.now and s.now) or b.checked then return end
    b.checked = true
    local cap = s.now * CFG.blizzardShareOfSnow
    if b.now > cap then
        local target = math.max(cap, (b.vanilla or 0) * 1.2)
        local cond = LIB.resolve(b.path)
        local req = cond and get(cond, "Requirements")
        if not req then return end
        write_num(req, "Probability", b.sub, target)
        log(string.format("Blizzard chance %.4f lowered to %.4f so snow (%.4f) stays more common", b.now, target, s.now))
    end
end
local function apply(cond)
    local a = LIB.address(cond)
    local name = fname(cond)
    if not a or done[a] or name:find("^Default__") then return end
    done[a] = true
    local req = get(cond, "Requirements")
    if not req then log(name .. ": no Requirements") return end
    local p, psub = read_num(req, "Probability")
    local c, csub = read_num(req, "Cooldown")
    local rule = RULES[name]
    local np, nc = p, c
    if rule and p then
        np = math.min(1.0, p * CFG[rule[1]])
        if p > 1 then np = p * CFG[rule[1]] end      -- a weight, not a 0..1 chance
        write_num(req, "Probability", psub, np)
    end
    if rule and c then
        nc = c * CFG[rule[2]]
        write_num(req, "Cooldown", csub, nc)
    end
    local np_now = read_num(req, "Probability")
    local nc_now = read_num(req, "Cooldown")
    log(string.format("%s: chance %s -> %s, cooldown %s -> %s", name, tostring(p), tostring(np_now), tostring(c),
        tostring(nc_now)))
    if rule then
        final[name] = { path = LIB.path_of(cond), sub = psub, vanilla = p, now = np_now }
        keep_snow_ahead()
    end
end

REBALANCE_ON_ASSET("Data_WeatherCondition", function(obj)
    local ok, err = pcall(apply, obj)
    if not ok then log("error: " .. tostring(err)) end
end)

log(string.format("loaded: blizzard chance x%.2f, cooldown x%.2f; snow chance x%.2f, cooldown x%.2f",
    CFG.blizzardChanceMultiplier, CFG.blizzardCooldownMultiplier, CFG.snowChanceMultiplier, CFG.snowCooldownMultiplier))
