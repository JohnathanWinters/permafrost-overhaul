-- SurvivalTweaks module of the Overhaul. How fast your own stats drop:
-- stamina, hunger, energy, health damage and body warmth. Only your losses
-- change; gains, healing and other characters stay vanilla.
-- The scaling itself is native (main.cpp, "survival rates"): this module
-- tells it, once a second, which ability system component is yours, one
-- live object of each attribute set (Stamina, Health, Temperature; their
-- vtables get hooked) and the multipliers, through dlls\survival.txt.
-- Settings: Survival section of config.lua. Log tag [PF Survival].
local TAG = "[PF Survival] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, address, game_loop = LIB.try, LIB.valid, LIB.address, LIB.game_loop
local ROOT = REBALANCE_ROOT or ""

------------------------------------------------------------------ config
local DEFAULTS = {
    { "staminaDrainMultiplier",   1.2, "stamina drain" },
    { "hungerDrainMultiplier",    0.2, "hunger drain" },
    { "energyDrainMultiplier",    1.0, "energy drain" },
    { "healthDamageMultiplier",   1.5, "damage you take" },
    { "bodyWarmthLossMultiplier", 0.12, "body warmth loss" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\Survival.lua", "r")  -- generated from config.lua by the loader
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "Survival.lua", "t", {})
    local user = chunk and try(chunk)
    if type(user) == "table" then
        for _, d in ipairs(DEFAULTS) do
            local v = tonumber(user[d[1]])
            if v then cfg[d[1]] = math.max(0, math.min(10, v)) end
        end
    end
    return cfg
end
local CFG = load_config()

------------------------------------------------------------------ player
local helpers = try(function() return require("UEHelpers") end)
local asc_lib = nil
local function player_asc()
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    if not valid(pc) or try(function() return pc:IsLocalPlayerController() end) ~= true then return nil end
    local pawn = try(function() return pc.Pawn end)
    if not valid(pawn) then return nil end
    local asc = try(function() return pawn.AbilitySystemComponent end)
    if valid(asc) then return asc end
    asc_lib = asc_lib or try(function()
        return StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    end)
    asc = valid(asc_lib) and try(function() return asc_lib:GetAbilitySystemComponent(pawn) end)
    return valid(asc) and asc or nil
end

-- Any live object of the class: only its vtable is used.
local function one_of(class_name)
    for _, o in ipairs(try(function() return FindAllOf(class_name) end) or {}) do
        if valid(o) and not LIB.fname(o):find("^Default__") then return address(o) end
    end
    return nil
end

------------------------------------------------------------------ feed
local OUT = ROOT .. "dlls\\survival.txt"
local last, sets = nil, nil
local function publish()
    local asc = player_asc()
    -- The attribute sets only need finding once (their vtables never change).
    if not sets then
        local s, h, t = one_of("AttributeSet_StaminaMetrics"), one_of("AttributeSet_HealthMetrics"),
            one_of("AttributeSet_TemperatureMetrics")
        if s and h and t then sets = { s, h, t } end
    end
    local text = string.format(
        "asc=%X\nstamina_set=%X\nhealth_set=%X\ntemperature_set=%X\nstamina=%.3f\nhunger=%.3f\nenergy=%.3f\nhealth=%.3f\nwarmth=%.3f\nend\n",
        asc and address(asc) or 0, sets and sets[1] or 0, sets and sets[2] or 0, sets and sets[3] or 0,
        CFG.staminaDrainMultiplier, CFG.hungerDrainMultiplier, CFG.energyDrainMultiplier,
        CFG.healthDamageMultiplier, CFG.bodyWarmthLossMultiplier)
    if text == last then return end
    last = text
    local f = io.open(OUT .. ".tmp", "wb")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(OUT)
    os.rename(OUT .. ".tmp", OUT)
end

game_loop(1000, function()
    local ok, err = pcall(publish)
    if not ok then log("error: " .. tostring(err)) end
end)

log(string.format("loaded: stamina x%.2f, hunger x%.2f, energy x%.2f, damage x%.2f, warmth loss x%.2f",
    CFG.staminaDrainMultiplier, CFG.hungerDrainMultiplier, CFG.energyDrainMultiplier,
    CFG.healthDamageMultiplier, CFG.bodyWarmthLossMultiplier))
