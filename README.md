# Permafrost Overhaul

One mod that makes Permafrost a harder, more believable survival game. Scarce but real loot, rare food, tougher hunting and enemies, and a quieter HUD.

Each feature is its own file in `Scripts` and can be turned off on its own.

## Install

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1 for Permafrost.
2. Download the latest zip from [Releases](https://github.com/JohnathanWinters/permafrost-overhaul/releases) and copy its `Rebalance` folder into `Permafrost\Binaries\Win64\ue4ss\Mods\`.
3. Start the game.

## Settings

Edit `config.lua` in the `Rebalance` folder and restart the game. Each line shows our value, the vanilla value and what it does ("vanilla -" = no such game setting).

`Modules` at the top turns each feature on (1) or off (0). Below it is one section per feature. Files in `config\` are rebuilt from `config.lua` at every start; do not edit them.

## Features

Simplest first.

### eternaltorches
- Placed torches never run out of fuel.

### food
- Food and drinks no longer heal (tooltips too). Medicine still does.

### recipes
- Makeshift Heater: cloth, plastic and 1 chemicals to craft; 1 chemicals to repair.

### weather
- Snowfall 3x as likely, blizzards 1.75x. Snowfall stays more common.

### survivaltweaks
- 1.5x damage taken, 0.2x hunger, 2x body warmth loss.

### locks
- Unlocked boxes stay unlocked after a reload.

### flashlight
- Sharp shadows, aims higher, reaches 3x farther.

### togglemovement
- Tap to sprint or crouch. Sprint stops when you let go of the movement keys and resumes after a weapon swap.

### travelcost
- Fast travel costs 1 food or drink: hotbar first (highest slot first), then inventory. None on you, no trip.

### bedtravel
- Look at your bed and press X to fast travel. The key is set in config. The travel lamp still works.

### hud
- Health area shows only when a stat is below 25%.
- Hotbar shows 2 s after a hotbar key.
- Weapon box shows 2 s after a switch, hidden with empty hands.
- Quest box shows 6 s after a change or after closing a menu.
- Compass stays.

### encounters
- Hostile encounters a third as often. Scripted spots take 3x longer to return.

### loot
- Food and drinks are rare (15%) except on animals.
- Trash always drops 3 to 5 plastic.
- Carcasses give 1.5x pelts, fat and bones; big game 4x meat.

### enemydrops
- Armed hostiles drop their gun (10 to 50% condition). 70% drop 1 to 3 cloth.

### harderhunting
- Animals see 3x and hear 4x farther, move 1.25x faster.
- 40% fewer animals. Prey flees and avoids you for 3 minutes.

### humanai
- Hostiles never flinch, reposition less and shoot back more.

### patrols
- No hostile within 300 m: a patrol of 1 to 3 comes through, at most every 10 minutes. Gone at 400 m.

### spawndistance
- Spawns 2x farther; encounters 100 to 200 m away. Groups spread out and arrive one at a time.
- Enemy spawners stay quiet within 100 m. Animals never spawn within 100 m; any that do are moved out.

### craftfromstorage
- Craft, build and repair with items from storage within 15 m.

### toolbelt
- A knife in your hotbar is drawn automatically to skin animals and open electrical boxes.
- Any knife tier works. Durability does not matter.

### accuracy
- Moving, jumping and rapid fire widen your spread. Aiming and crouching tighten it.
- Your Accuracy skill shrinks it.
- The crosshair lines open up with it.

### buildsnow
- Snow settles on your built structures where open to the sky.
- Fixes vanilla snow on stoves and torches under a roof.

### betterguns
- Louder gunshots with a big-hall reverb (stronger indoors). Other sounds duck after your shots.
- 2x recoil, 2.5x camera kick.
- Headshots: 8x for guns and bows, 2x melee.

### containers
Most containers are already picked clean. The rare untouched one holds what the real thing would:

| Container | Untouched | Typical haul |
|---|---|---|
| Fridges | 6% | drinks, food |
| Medical boxes | 6% | bandages, painkillers, medkits |
| Cars | 8% | plastic, wire, metal, fabric, sometimes fuel |
| Electricity boxes | 8% | components, wire |
| Toolboxes | 10% | metal, components, wire, batteries |
| Cabinets and lockers | 12% | household items |
| Military vehicles | 12% | military supplies, ammo |
| Suitcases | 15% | clothes, snacks, cash |
| Ammo boxes | 15% | about 70 rounds |
| Trash bins | 20% | junk |
| Dead bodies | 20% | a few items |
| Safes | 25% | cash, tripled |

Only unopened containers change. Locked ones were never looted, so they are always full.

### Tools and work in progress
- **f8log**: F8 saves every lootable around you to `loot_census.txt`. Changes nothing.
- **warmth**: clothing warmth that scales with the cold. Logging only for now.
- **doors**: doors and shutters keep their state across saves. Logging only for now.

## Building main.dll

`src\main.cpp` builds `dlls\main.dll` with `src\build.bat` (Visual Studio 2022 Build Tools). It holds what Lua cannot reach: crafting from storage, the spawn and animal spawn blockers, headshot damage, the toolbelt check, survival rates, the fast travel cost, the gunshot reverb and the crash report. Each part follows its Lua module's switch. Everything is source; no closed binaries.
