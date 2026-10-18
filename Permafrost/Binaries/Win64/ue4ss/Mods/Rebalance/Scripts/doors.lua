-- Doors module of the Overhaul (2026-10-18). User: doors and window
-- shutters saved closed came back open (one shutter half open, the other
-- closed), needing extra presses. The plan: remember every built door and
-- shutter's state by its position (built parts get new names each load) and
-- put it back after loading through the game's own open/close function.
-- Step 1 (this version): discovery only, nothing changes. Once in the
-- world, for the first door and the first shutter found (BP_PermaMasterDoor,
-- BP_MasterWindowShutter and their children), every property with its
-- value and every function name is logged.
-- Log tag [PF Doors].
local TAG = "[PF Doors] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call

local KINDS = {
    { "door", "/Game/Permafrost/Blueprints/BuildingParts/Core/BP_PermaMasterDoor.BP_PermaMasterDoor_C" },
    { "shutter", "/Game/Permafrost/Blueprints/BuildingParts/Core/BP_MasterWindowShutter.BP_MasterWindowShutter_C" },
}
local done = {}

local function describe(kind, actor, cls)
    local props, funcs = {}, {}
    local c = cls
    for _ = 1, 3 do
        if not valid(c) then break end
        try(function()
            c:ForEachProperty(function(prop)
                local n = try(function() return prop:GetFName():ToString() end) or "?"
                local v = get(actor, n)
                local shown
                if type(v) == "number" or type(v) == "boolean" then shown = tostring(v)
                elseif v ~= nil and valid(v) then shown = fname(v)
                else shown = "(other)" end
                props[#props + 1] = n .. "=" .. shown
            end)
        end)
        try(function()
            c:ForEachFunction(function(fn)
                funcs[#funcs + 1] = try(function() return fn:GetFName():ToString() end) or "?"
            end)
        end)
        c = try(function() return c:GetSuperStruct() end)
    end
    log(string.format("%s %s properties: %s", kind, fname(actor), table.concat(props, ", ")))
    log(string.format("%s %s functions: %s", kind, fname(actor), table.concat(funcs, ", ")))
end

local settle = os.clock() + 20
game_loop(5000, function()
    if os.clock() < settle then return end
    local ok, err = pcall(function()
        for _, k in ipairs(KINDS) do
            if not done[k[1]] then
                do
                    -- Any live actor of that class or a child class.
                    local short = k[2]:match("%.([%w_]+)$")
                    local list = try(function() return FindAllOf(short) end) or {}
                    for _, a in ipairs(list) do
                        if valid(a) and not fname(a):find("^Default__") then
                            done[k[1]] = true
                            describe(k[1], a, call(a, "GetClass"))
                            break
                        end
                    end
                end
            end
        end
    end)
    if not ok then log("error: " .. tostring(err)) end
end)

log("loaded (discovery only: logs door and shutter properties)")
