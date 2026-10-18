-- Encounters module of the Overhaul. Random encounters with hostile humans
-- happen less often (other encounters as vanilla), and scripted encounter
-- spots (cultist camps, loot camps) take longer to come back.
-- Settings: Encounters section of config.lua. Log tag [PF Encounters].
local TAG = "[PF Encounters] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, full, resolve, game_loop, game_later = LIB.try, LIB.valid, LIB.fname, LIB.full, LIB.resolve, LIB.game_loop, LIB.game_later
local ROOT = REBALANCE_ROOT or ""
local rules = REBALANCE_SHARED("rules")
local DATA = REBALANCE_SHARED("lootdata")   -- only its small helpers; no loot scan
local short, soft_path, each_elem = DATA.short, DATA.soft_path, DATA.each_elem

------------------------------------------------------------------ config
local DEFAULTS = {
    { "enemyEncounterRate",   0.35, 1.0, "random encounters with hostile humans: how often" },
    { "otherEncounterRate",   1.0,  1.0, "random encounters with animals, moonrock events, bodies: how often" },
    { "staticEncounterReuse", 3.0,  1.0, "scripted encounter spots: time before they can happen again" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Encounters.lua", "r")  -- generated from config.lua by the loader
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Encounters.lua", "t", {})
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

------------------------------------------------------------------ random encounters
-- Each map location (Data_WorldLocationInstance) carries RandomEncounterConstraints:
-- RandomEncountersFrequency (seconds between rolls) and WeightedRandomEncounters.
-- The subsystem copies the current location's set into CurrentConstraints.
local enc_vanilla = {}   -- location name -> { interval, weights = {...} }
local enc_done = {}      -- location name -> applied signature
local enc_logged = 0

local function encounter_entries(c)
    local entries, refs = {}, {}
    each_elem(try(function() return c.WeightedRandomEncounters end), function(_, s)
        local e = try(function() return s.Encounter end)
        local path = e and (valid(e) and full(e) or soft_path(e)) or ""
        entries[#entries + 1] = { human = path:find("/Humanoid/") ~= nil, w = tonumber(try(function() return s.SpawnWeight end)) or 0,
                                  name = short(path) }
        refs[#refs + 1] = s
    end)
    return entries, refs
end

local function signature(interval, entries)
    local parts = { string.format("%.3f", interval or 0) }
    for _, e in ipairs(entries) do parts[#parts + 1] = string.format("%.4f", e.w) end
    return table.concat(parts, ",")
end

-- Applies the rates to one constraints struct whose vanilla values are `van`.
local function apply_constraints(c, van, label)
    local _, refs = encounter_entries(c)
    local interval, weights = rules.encounters(van.entries, van.interval,
        tonumber(CFG.enemyEncounterRate) or 1, tonumber(CFG.otherEncounterRate) or 1)
    try(function() c.RandomEncountersFrequency = interval end)
    if weights then
        for i, s in ipairs(refs) do
            if weights[i] then try(function() s.SpawnWeight = weights[i] end) end
        end
    end
    local now_interval = tonumber(try(function() return c.RandomEncountersFrequency end)) or 0
    local now_entries = encounter_entries(c)
    if enc_logged < 12 then
        enc_logged = enc_logged + 1
        local humans = 0
        for _, e in ipairs(van.entries) do if e.human then humans = humans + 1 end end
        log(string.format("encounters %s: every %.0fs -> %.0fs, %d of %d entries human", label, van.interval, now_interval,
            humans, #van.entries))
    end
    return signature(now_interval, now_entries)
end

-- Region data assets and the encounter subsystem: found once, then kept by
-- path; regions loaded later are added as they are created.
local region_paths, subsystem_path = nil, nil
REBALANCE_ON_ASSET("Data_WorldLocationInstance", function(obj)
    local n = full(obj)
    if region_paths and not n:find("Default__") then region_paths[n] = true end
end)
local function encounter_pass()
    if CFG.enemyEncounterRate == 1 and CFG.otherEncounterRate == 1 then return end
    if not region_paths then
        region_paths = {}
        for _, loc in ipairs(FindAllOf("Data_WorldLocationInstance") or {}) do
            local n = full(loc)
            if not n:find("Default__") then region_paths[n] = true end
        end
    end
    for path in pairs(region_paths) do
        local loc = resolve(path)
        local name = loc and fname(loc) or "?"
        if not loc then
            region_paths[path] = nil
        else
            local c = try(function() return loc.RandomEncounterConstraints end)
            if c then
                local entries = encounter_entries(c)
                local interval = tonumber(try(function() return c.RandomEncountersFrequency end)) or 0
                local sig = signature(interval, entries)
                if not enc_vanilla[name] then enc_vanilla[name] = { interval = interval, entries = entries } end
                if enc_done[name] ~= sig and #entries > 0 then
                    enc_done[name] = apply_constraints(c, enc_vanilla[name], name)
                end
            end
        end
    end
    -- The location currently active was copied before the edit if the save
    -- loaded first; match it to its location by vanilla signature and fix it.
    local sub = resolve(subsystem_path)
    if not sub then
        sub = (FindAllOf("RandomEncountersSubsystem") or {})[1]
        subsystem_path = sub and full(sub) or nil
    end
    if sub then
        local c = try(function() return sub.CurrentConstraints end)
        if c then
            local entries = encounter_entries(c)
            local interval = tonumber(try(function() return c.RandomEncountersFrequency end)) or 0
            local sig = signature(interval, entries)
            for name, van in pairs(enc_vanilla) do
                if signature(van.interval, van.entries) == sig and enc_done[name] ~= sig and #entries > 0 then
                    apply_constraints(c, van, "current (" .. name .. ")")
                    break
                end
            end
        end
    end
end

------------------------------------------------------------------ scripted encounters
-- Static encounter spots (cultist camps, patrols, loot camps) wait ReuseTime
-- seconds before they can trigger again; staticEncounterReuse stretches it.
local reuse_logged = 0
local reuse_pending = {}  -- { path, due }
REBALANCE_ON_ACTOR("/Script/Permafrost.StaticEncounterBase", function(obj)
    local n = full(obj)
    if n:find("Default__") or (tonumber(CFG.staticEncounterReuse) or 1) == 1 then return end
    reuse_pending[#reuse_pending + 1] = { n, os.clock() + 1.0 }
end)
local function reuse_pass()
    if #reuse_pending == 0 then return end
    local now, list = os.clock(), reuse_pending
    reuse_pending = {}
    for _, v in ipairs(list) do
        if now < v[2] then
            reuse_pending[#reuse_pending + 1] = v
        else
            local sp = resolve(v[1])
            local t = sp and tonumber(try(function() return sp.ReuseTime end))
            if t then
                try(function() sp.ReuseTime = t * CFG.staticEncounterReuse end)
                if reuse_logged < 5 then
                    reuse_logged = reuse_logged + 1
                    log(string.format("scripted encounter %s: reuse %.0f -> %.0f s", fname(sp), t, t * CFG.staticEncounterReuse))
                end
            end
        end
    end
end

------------------------------------------------------------------ start
game_later(7000, function()
    game_loop(20000, function()
        local ok, err = pcall(encounter_pass)
        if not ok then log("encounter pass error: " .. tostring(err)) end
    end)
end)
game_loop(100, function() pcall(reuse_pass) end)

log(string.format("loaded: hostile encounters x%.2f, others x%.2f, scripted spots reuse x%.1f",
    CFG.enemyEncounterRate, CFG.otherEncounterRate, CFG.staticEncounterReuse))
