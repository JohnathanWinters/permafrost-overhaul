-- Locks module of the Overhaul (2026-10-18). User: once a box or electrical
-- box is unlocked it should stay unlocked. The game does not save padlock
-- state: an electrical box unlocked in one session was locked again (10/10)
-- after a reload, while its emptied contents were saved.
-- Every padlock seen unlocked is remembered by its owner's object path
-- (world actors keep the same path between loads) in
-- dlls\unlocked_padlocks.txt. When a remembered one shows up locked again,
-- it is unlocked through the game's own UPadlock::TryToUnlock (required
-- tool, top tier, all of its durability), so the box reacts as to a normal
-- unlock. Checked every 2 s.
-- Settings: none (Modules.locks turns it off). Log tag [PF Locks].
local TAG = "[PF Locks] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local LIB = REBALANCE_LIB
local try, valid, fname, game_loop = LIB.try, LIB.valid, LIB.fname, LIB.game_loop
local get, call = LIB.get, LIB.call
local ROOT = REBALANCE_ROOT or ""

local FILE = ROOT .. "dlls\\unlocked_padlocks.txt"
local unlocked = {}       -- owner path -> true
local count = 0
do
    local f = io.open(FILE, "r")
    if f then
        for line in f:lines() do
            local p = line:gsub("%s+$", "")
            if p ~= "" and not unlocked[p] then unlocked[p] = true count = count + 1 end
        end
        f:close()
    end
end

local function remember(path)
    if unlocked[path] then return end
    unlocked[path] = true
    count = count + 1
    local f = io.open(FILE, "a")
    if f then f:write(path .. "\n") f:close() end
end

local logged = 0
local function pass()
    for _, lock in ipairs(try(function() return FindAllOf("Padlock") end) or {}) do
        if valid(lock) and not fname(lock):find("^Default__") then
            local owner = call(lock, "GetOwner")
            local path = valid(owner) and LIB.path_of(owner) or ""
            if path ~= "" then
                local locked = get(lock, "bLocked")
                if locked == false then
                    remember(path)
                elseif locked == true and unlocked[path] then
                    local tool = tonumber(get(lock, "RequiredTool")) or 0
                    local dur = tonumber(get(lock, "LockDurability")) or 0
                    call(lock, "TryToUnlock", tool, 255, dur + 1000)
                    if logged < 10 then
                        logged = logged + 1
                        log(string.format("kept unlocked: %s (%s)", fname(owner),
                            get(lock, "bLocked") == false and "done" or "still locked"))
                    end
                end
            end
        end
    end
end

game_loop(2000, function()
    local ok, err = pcall(pass)
    if not ok and logged < 10 then logged = logged + 1 log("error: " .. tostring(err)) end
end)

log(string.format("loaded: %d padlocks remembered as unlocked", count))
