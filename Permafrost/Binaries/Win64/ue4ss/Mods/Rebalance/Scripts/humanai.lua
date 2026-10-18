-- HumanAI module of the Overhaul (2026-10-17). User: hostile humans get
-- stun-locked by flinching when shot, and keep trying to flank instead of
-- returning fire.
--
-- 1. Flinch: hit reactions are montages (started by the GC_HitReactAnim
--    cue). Hostile humans near the player are watched every 100 ms; the
--    first flinch plays, another within flinchCooldownSeconds is stopped, so
--    the enemy keeps fighting. Animals are left alone.
-- 2. Flanking: the native behavior tree task UBTT_KeepDistance re-runs a
--    positioning query every TimeSpacingBetweenEQS seconds and moves the
--    enemy there. That interval is multiplied by repositionIntervalMultiplier
--    on every loaded KeepDistance node, so they reposition less and shoot
--    more. The task nodes live in behavior tree assets; new ones are caught
--    by the asset watch.
-- Settings: HumanAI section of config.lua. Log tag [PF HumanAI].
local TAG = "[PF HumanAI] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, set, call = LIB.get, LIB.set, LIB.call
local ROOT = REBALANCE_ROOT or ""

------------------------------------------------------------------ config
local DEFAULTS = {
    { "enabled",                      1,   "1 = on" },
    { "flinch",                       0,   "0 = hostile humans never flinch when hit, 1 = flinch with the cooldown below (vanilla 1)" },
    { "flinchCooldownSeconds",        4.0, "after a flinch, hits within this many seconds do not flinch again (vanilla 0)" },
    { "repositionIntervalMultiplier", 4.0, "how much longer enemies wait before repositioning (vanilla 1.0)" },
    { "debugLog",                     1,   "1 = log what was found and changed" },
}
local function load_config()
    local cfg = {}
    for _, d in ipairs(DEFAULTS) do cfg[d[1]] = d[2] end
    local f = io.open(ROOT .. "config\\HumanAI.lua", "r")
    if not f then return cfg end
    local text = f:read("*a")
    f:close()
    local chunk = load(text, "HumanAI.lua", "t", {})
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

------------------------------------------------------------------ 1. flinch cooldown
-- UE4SS could not hook the hit-react cue (GC_HitReactAnim has only the
-- Blueprint event K2_HandleGameplayCue, and its hook failed, 2026-10-17), so
-- this watches instead: every 100 ms, hostile humans within 60 m that are
-- playing a hit-reaction montage. The first flinch plays; another one within
-- flinchCooldownSeconds of it is stopped at once. Montage names seen are
-- logged (first 15) so the name filter can be checked.
local ANIMAL = try(function() return StaticFindObject("/Script/Permafrost.PermaAnimalBase") end)
local REACT_WORDS = { "hit", "react", "flinch", "stagger", "pain", "damage" }
local last_flinch = {}       -- character address -> os.clock() of the last allowed flinch
local current = {}           -- character address -> montage address being played
local seen_montages, seen_count = {}, 0
local stopped_logged = 0

local function is_react(name)
    local l = name:lower()
    for _, w in ipairs(REACT_WORDS) do if l:find(w, 1, true) then return true end end
    return false
end

local helpers = nil
local function flinch_pass()
    if CFG.flinch ~= 0 and CFG.flinchCooldownSeconds <= 0 then return end
    helpers = helpers or try(function() return require("UEHelpers") end)
    local pc = helpers and try(function() return helpers.GetPlayerController() end)
    local pawn = valid(pc) and get(pc, "Pawn")
    local p = pawn and call(pawn, "K2_GetActorLocation")
    if not p then return end
    local px, py, pz = p.X, p.Y, p.Z
    local now = os.clock()
    for _, npc in ipairs(try(function() return FindAllOf("BaseAICharacter") end) or {}) do
        if valid(npc) and not (valid(ANIMAL) and call(npc, "IsA", ANIMAL) == true) then
            local l = call(npc, "K2_GetActorLocation")
            if l and (l.X - px) ^ 2 + (l.Y - py) ^ 2 + (l.Z - pz) ^ 2 < 6000 * 6000 then
                local mesh = get(npc, "Mesh")
                local anim = mesh and call(mesh, "GetAnimInstance")
                local m = anim and call(anim, "GetCurrentActiveMontage")
                local a = LIB.address(npc)
                if a then
                    if valid(m) then
                        local ma = LIB.address(m)
                        local mn = fname(m)
                        if CFG.debugLog == 1 and not seen_montages[mn] and seen_count < 15 then
                            seen_montages[mn] = true
                            seen_count = seen_count + 1
                            log("montage seen on " .. fname(npc) .. ": " .. mn .. (is_react(mn) and " (hit reaction)" or ""))
                        end
                        if ma ~= current[a] then
                            current[a] = ma
                            if is_react(mn) then
                                local prev = last_flinch[a]
                                if CFG.flinch == 0 or (prev and now - prev < CFG.flinchCooldownSeconds) then
                                    call(npc, "StopAnimMontage", m)
                                    if CFG.debugLog == 1 and stopped_logged < 10 then
                                        stopped_logged = stopped_logged + 1
                                        log(string.format("flinch skipped on %s (%s, %.1f s after the last one)", fname(npc), mn, now - prev))
                                    end
                                else
                                    last_flinch[a] = now
                                end
                            end
                        end
                    else
                        current[a] = nil
                    end
                end
            end
        end
    end
end
-- Block before it plays: the watcher above stops a flinch only after it
-- started (up to 100 ms, still visible; user 2026-10-18). Montages started
-- from Blueprint (the hit-react cue) pass through these UFunctions; a play
-- rate of 0 makes Montage_Play refuse the montage. Native starts still fall
-- to the watcher.
local hook_blocked = 0
local AI_CHAR = try(function() return StaticFindObject("/Script/Permafrost.BaseAICharacter") end)
local function block_react(owner, montage, rate)
    local m = montage and try(function() return montage:get() end)
    if not valid(m) or not is_react(fname(m)) then return end
    if not valid(owner) or (valid(ANIMAL) and call(owner, "IsA", ANIMAL) == true) then return end
    -- NPCs only: the player's own hit reactions stay.
    if not (valid(AI_CHAR) and call(owner, "IsA", AI_CHAR) == true) then return end
    local a = LIB.address(owner)
    local now = os.clock()
    if CFG.flinch ~= 0 then
        local prev = a and last_flinch[a]
        if not (prev and now - prev < CFG.flinchCooldownSeconds) then
            if a then last_flinch[a] = now end
            return
        end
    end
    try(function() rate:set(0.0) end)
    if CFG.debugLog == 1 and hook_blocked < 10 then
        hook_blocked = hook_blocked + 1
        log(string.format("flinch blocked before it played: %s on %s", fname(m), fname(owner)))
    end
end
for _, h in ipairs({
    { "/Script/Engine.Character:PlayAnimMontage", function(self, montage, rate)
        block_react(self:get(), montage, rate) end },
    { "/Script/Engine.AnimInstance:Montage_Play", function(self, montage, rate)
        local inst = self:get()
        block_react(valid(inst) and call(inst, "GetOwningActor") or nil, montage, rate) end },
}) do
    local ok = try(function() RegisterHook(h[1], h[2]); return true end)
    log((ok and "hooked " or "FAILED to hook ") .. h[1])
end

game_loop(100, function()
    local ok, err = pcall(flinch_pass)
    if not ok and stopped_logged < 10 then stopped_logged = stopped_logged + 1 log("flinch error: " .. tostring(err)) end
end)

------------------------------------------------------------------ 2. reposition interval
local done_nodes = {}         -- node address -> true
local node_logged = 0
local function scale_keep_distance(node)
    local a = LIB.address(node)
    if not a or done_nodes[a] then return end
    done_nodes[a] = true
    local name = fname(node)
    if name:find("^Default__") then return end
    local v = tonumber(get(node, "TimeSpacingBetweenEQS"))
    if not v then return end
    local nv = v * CFG.repositionIntervalMultiplier
    if CFG.repositionIntervalMultiplier ~= 1.0 then set(node, "TimeSpacingBetweenEQS", nv) end
    if CFG.debugLog == 1 and node_logged < 15 then
        node_logged = node_logged + 1
        local query = get(node, "QueryForKeepingDistance")
        log(string.format("KeepDistance %s (query %s): reposition every %.1f s -> %.1f s", LIB.path_of(node),
            valid(query) and fname(query) or "?", v, nv))
    end
end
REBALANCE_ON_ASSET("BTT_KeepDistance", scale_keep_distance)

-- Forget flinch times of enemies that are gone (addresses get reused).
game_loop(30000, function()
    local now = os.clock()
    for a, t in pairs(last_flinch) do
        if now - t > 60 then last_flinch[a] = nil end
    end
end)

log(string.format("loaded: flinch %s, reposition interval x%.1f",
    CFG.flinch == 0 and "off" or string.format("cooldown %.1f s", CFG.flinchCooldownSeconds), CFG.repositionIntervalMultiplier))
