-- SurvivalTweaks module of the Rebalance mod (was its own mod until 2026-10-17).
-- Settings: Rebalance\survivaltweaks\config.lua (read by the hosted DLL).
-- SurvivalTweaks: local PlayerController(0) -> actual pawn -> GAS ASC.
-- This is a fail-closed identity witness, NOT a gameplay mod.
-- A client with no validated LOCAL controller/ASC writes ASC=0.
local TAG = "[PF GAS Player0] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

-- Game-thread scheduling. LoopAsync + ExecuteInGameThread queues a new
-- callback from a worker thread on every tick; with several mods doing it,
-- UE4SS raced ("Ref was not function") and crashed the game on 2026-10-16.
-- This UE4SS build can loop directly on the game thread; the old pattern is
-- only a fallback.
local LIB = REBALANCE_LIB  -- shared helpers (Scripts\lib.lua)
local try, valid, address, game_loop, game_later = LIB.try, LIB.valid, LIB.address, LIB.game_loop, LIB.game_later

local function find_output_path()
    if REBALANCE_ROOT then return REBALANCE_ROOT .. "survivaltweaks\\dlls\\local-player-asc.ini" end
    -- UE4SS typically invokes the file with its absolute source filename.
    local path = try(function() return debug.getinfo(1, "S").source end)
    if type(path) == "string" then
        path = path:gsub("^@", ""):gsub("/", "\\")
        local base = path:match("^(.*\\)[Ss]cripts\\main%.lua$")
        if base then return base .. "dlls\\local-player-asc.ini" end
    end
    -- UE4SS 3.0.x supports IterateGameDirectories in Lua.
    local roots = try(function() return IterateGameDirectories() end)
    local win64 = roots and roots.Game and roots.Game.Binaries and roots.Game.Binaries.Win64
    local root = win64 and win64.__absolute_path
    if type(root) == "string" then
        return root .. "\\ue4ss\\Mods\\SurvivalTweaks\\dlls\\local-player-asc.ini"
    end
    return nil
end
local destination = find_output_path()
if not destination then
    log("FAIL CLOSED: unable to resolve mod-owned DLL directory")
    return
end

local helpers = try(function() return require("UEHelpers") end)
local function local_player_asc()
    if type(helpers) ~= "table" then return nil end
    -- UEHelpers.GetPlayerController chooses a local controller. In the
    -- supported single-local-player test this is PlayerController(0).
    local pc = try(function() return helpers.GetPlayerController() end)
    if not valid(pc) then return nil end
    if try(function() return pc:IsLocalPlayerController() end) ~= true then
        return nil
    end
    local pawn = try(function() return pc.Pawn end)
    if not valid(pawn) then return nil end
    if try(function() return pawn:IsLocallyControlled() end) ~= true then
        return nil
    end
    local pawnAddress = address(pawn)
    if not pawnAddress then return nil end
    local state = try(function() return pawn.PlayerState end)
    local function asc_from_actor(actor)
        if not valid(actor) then return nil end
        local reflected = try(function() return actor.AbilitySystemComponent end)
        if valid(reflected) then return reflected end
        local cdo = try(function()
            return StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        end)
        if valid(cdo) then
            local asComponent = try(function() return cdo:GetAbilitySystemComponent(actor) end)
            if valid(asComponent) then return asComponent end
        end
        return nil
    end
    local asc = asc_from_actor(pawn) or asc_from_actor(state)
    if not valid(asc) then
        -- Last-resort exact UI link already proven in the old PF probe.
        -- Never choose an arbitrary panel: require Character == local pawn.
        local panels = try(function() return FindAllOf("UW_CharStatusPanel_C") end)
        if type(panels) == "table" then
            for _, panel in ipairs(panels) do
                if valid(panel) and address(try(function() return panel.Character end)) == pawnAddress then
                    local candidate = try(function() return panel.AbilistySystemComp end)
                    if valid(candidate) then asc = candidate; break end
                end
            end
        end
    end
    return address(asc)
end

-- Like MoreBackpackSlots/CustomStackSize: the initial game-thread
-- callback runs during main-menu initialization. The native DLL does
-- nothing expensive during the intro and may resolve GAS from this
-- point forward, even while the player's ASC is not spawned yet.
local mainMenuGameThreadReady = false
local lastAddress = nil
local lastError = nil
local last_data = nil
local function publish()
    -- All UObject operations must run on the game thread.
    local addr = local_player_asc() or 0
    local data = string.format("[LocalPlayer]\nASC=%X\nMainMenuReady=%d\n",
        addr, mainMenuGameThreadReady and 1 or 0)
    if data == last_data then return end    -- unchanged: no disk write
    last_data = data
    local file, errorText = io.open(destination, "wb")
    if not file then
        if errorText ~= lastError then
            log("FAIL CLOSED: cannot write identity witness: " .. tostring(errorText))
            lastError = errorText
        end
        return
    end
    file:write(data)
    file:close()
    if addr ~= lastAddress then
        log(string.format("PlayerController(0) target ASC=0x%X (0 disables all native writes)", addr))
        lastAddress = addr
    end
end

log("identity witness ready; refresh every 1 second (game thread)")
-- Queue exactly like the other Permafrost mods which initialize their
-- settings in the main menu before a save is loaded.
local queued, queueError = pcall(function()
    game_later(0, function()
        mainMenuGameThreadReady = true
        log("MAIN MENU GAME THREAD READY: native GAS resolver may start now")
        publish()
    end)
end)
if not queued then
    log("MAIN MENU QUEUE FAILED: native resolver remains disabled: " ..
        tostring(queueError))
end
game_loop(1000, function()
    local ok, err = pcall(publish)
    if not ok then log("player identity refresh failed: " .. tostring(err)) end
end)
