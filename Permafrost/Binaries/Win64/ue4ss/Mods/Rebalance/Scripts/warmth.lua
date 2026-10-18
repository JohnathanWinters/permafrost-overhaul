-- Warmth module of the Overhaul (2026-10-18). User: clothing should not
-- just switch heat loss on or off; how fast you lose (or keep) body warmth
-- should follow the gap between your insulation and the cold, so being
-- naked at 50 degrees loses heat faster than being dressed at 50 degrees.
-- Step 1 (this version): logging only, nothing changes. Every 5 s for the
-- first 5 minutes of play: the player's UAttributeSet_TemperatureMetrics
-- values (Temperature, ThermalInsulation, FinalTemperature,
-- HeatSourceTemperature, BodyWarmth and its min/max, the gain/loss/base
-- factors) and how fast BodyWarmth actually changed since the last line.
-- Try it dressed and undressed, outside, indoors and by a fire.
-- Log tag [PF Warmth].
local TAG = "[PF Warmth] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get = LIB.get

local FIELDS = { "Temperature", "ThermalInsulation", "FinalTemperature", "HeatSourceTemperature", "BodyWarmth",
                 "MinBodyWarmth", "MaxBodyWarmth", "BodyWarmth_GainFactor", "BodyWarmth_LossFactor",
                 "BodyWarmth_BaseFactor" }

local function value(set, f)
    local d = get(set, f)
    if type(d) == "number" then return d end
    return d and tonumber(try(function() return d.CurrentValue end)) or nil
end

local helpers = nil
local lines, last_warmth, last_t = 0, nil, nil
local listed = false
local function pass()
    if lines >= 60 then return end
    helpers = helpers or try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    if not valid(pawn) then return end
    -- The player's set: its full path names the pawn or the player state
    -- (stats often live on the player state, 2026-10-18).
    local names = { fname(pawn) }
    local ps = get(pc, "PlayerState")
    if valid(ps) then names[#names + 1] = fname(ps) end
    local set, all = nil, {}
    for _, s in ipairs(try(function() return FindAllOf("AttributeSet_TemperatureMetrics") end) or {}) do
        if valid(s) and not fname(s):find("^Default__") then
            local p = LIB.path_of(s)
            all[#all + 1] = p
            for _, n in ipairs(names) do
                if p:find(n, 1, true) then set = s end
            end
            if set then break end
        end
    end
    if not set then
        if not listed then
            listed = true
            log("player's temperature set not found under " .. table.concat(names, " / ") .. "; sets: "
                .. (#all > 0 and table.concat(all, " ; ", 1, math.min(#all, 5)) or "none"))
        end
        return
    end
    local parts = {}
    for _, f in ipairs(FIELDS) do
        local v = value(set, f)
        if v then parts[#parts + 1] = string.format("%s=%.2f", f, v) end
    end
    local now = os.clock()
    local w = value(set, "BodyWarmth")
    local rate = ""
    if w and last_warmth and last_t and now > last_t then
        rate = string.format(" | warmth change %.3f/s", (w - last_warmth) / (now - last_t))
    end
    last_warmth, last_t = w, now
    lines = lines + 1
    log(table.concat(parts, ", ") .. rate)
end

game_loop(5000, function()
    local ok, err = pcall(pass)
    if not ok and lines < 60 then lines = lines + 1 log("error: " .. tostring(err)) end
end)

log("loaded (logging only for 5 minutes: try dressed, undressed, inside and by a fire)")
