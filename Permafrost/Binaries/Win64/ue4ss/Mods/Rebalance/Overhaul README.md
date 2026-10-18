# Permafrost Overhaul

One mod that makes Permafrost a harder, more believable survival game. Loot is scarce but real when you find it. Food is rare. Enemies spawn farther away, fight without flinching and drop what they carried. Hunting takes patience.

Every feature is its own file in `Scripts`, and each one can be turned off on its own.

## Install

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1 for Permafrost.
2. Download the latest zip from [Releases](https://github.com/JohnathanWinters/permafrost-overhaul/releases) and copy its `Rebalance` folder into `Permafrost\Binaries\Win64\ue4ss\Mods\`.
3. Start the game.

## Settings

Edit `config.lua` in the `Rebalance` folder, save it, then restart the game. Each line shows our value, the vanilla value and what it does. "vanilla -" means the game has no such setting.

`Modules` at the top turns each feature on (1) or off (0). The rest of the file holds one section per feature. The files in `config\` are rebuilt from `config.lua` at every start, so editing them does nothing.

## Features

### loot
- Food and drinks are rare everywhere except on animals: 15% of the vanilla chance.
- Trash bags and piles always drop plastic: 3 to 5 instead of 1 to 2.
- Animal carcasses give 1.5x the pelts, fat and bones. Big game gives 4x the meat (a deer gives 4 to 8).
- Hostiles rarely carry food or drinks.

### containers
Most containers have already been picked clean. The rare untouched one holds what the real thing would:

| Container | Untouched | Typical haul |
|---|---|---|
| Fridges | 6% | drinks and several kinds of food |
| Medical boxes | 6% | bandages, painkillers, medkits |
| Cars | 8% | plastic, wire, metal, fabric, sometimes oil, fuel, a car medkit |
| Electricity boxes | 8% | components, wire, electrical junk |
| Toolboxes | 10% | metal junk, components, wire, batteries |
| Cabinets and lockers | 12% | household items |
| Military vehicles | 12% | military supplies and ammo |
| Suitcases | 15% | clothes, snacks, cash |
| Ammo boxes | 15% | about 70 rounds |
| Trash bins | 20% | junk |
| Dead bodies | 20% | a few items |
| Safes | 25% | cash, tripled |

Only containers you have not opened yet change. A container that is still locked has never been looted, so it always holds its full haul. Edit the `Containers` list to change chances and hauls.

### locks
- A box you unlock stays unlocked after a reload. (The game itself locks it again.)

### enemydrops
- Armed hostiles drop the gun they carried, worn to 10 to 50%.
- Hostiles drop 1 to 3 cloth 70% of the time.

### encounters
- Random encounters with hostiles happen about a third as often. Animal encounters are unchanged.
- Scripted spots, like cultist camps, take 3x longer to come back.

### spawndistance
- Spawns appear 2x farther away; random encounters 100 to 200 m away.
- Groups stand 2.5x farther apart and appear one at a time.
- Enemy spawners stay quiet while you are within 100 m of them.

### patrols
- When no hostile is within 300 m, a small patrol (1 to 3 people) comes through.
- At most one every 10 minutes. A patrol 400 m away disappears.

### humanai
- Hostiles do not flinch when shot, so they keep fighting.
- They reposition less often and shoot back more.

### harderhunting
- Animals see 3x and hear 4x farther, and move 1.25x faster.
- 40% fewer animals, balanced by the richer carcasses.
- Prey runs away from you and avoids you for 3 minutes.

### betterguns
- Gunshots are 8x louder, deeper and less metallic.
- A concert-hall reverb on your shots, stronger indoors.
- 2x recoil and 2.5x camera kick.
- Headshots hit harder: 4x pistols, 8x rifles, shotguns and bows, 2x melee.

### flashlight
- Casts shadows, aims a little higher and reaches 3x farther.

### togglemovement
- Tap to sprint and tap to crouch. Sprint stops when you let go of the movement keys and resumes after a weapon swap.

### eternaltorches
- Placed torches never run out of fuel.

### craftfromstorage
- Crafting, repairs and building use items from storage within 15 m.

### survivaltweaks
- You take 1.5x damage. Hunger drains at 0.2x. Body warmth drops 2x faster.

### toolbelt
- A knife in your hotbar counts as held: skin animals and open electrical boxes without taking it out.
- Any knife opens what needs one. Each tier it is short costs extra durability.

### recipes
- The Makeshift Heater needs 1 chemicals on top of cloth and plastic, and repairs with chemicals.

### food
- Food and drinks no longer heal, and their tooltips no longer say so. Medical items still heal.

### hud
- Health and the stat bars show only when one drops below 25%.
- The hotbar shows for 2 seconds after you press a hotbar key.
- The quest box fades 5 seconds after it changes. The compass stays.

### f8log
- Press F8 to save every lootable around you to `loot_census.txt` with a timestamp. Changes nothing in game.

## Building main.dll

`src\main.cpp` builds the native part (`dlls\main.dll`) with `src\build.bat` (Visual Studio 2022 Build Tools). It holds everything Lua cannot reach: crafting from storage, the spawn blocker, headshot damage, the toolbelt check, survival rates, the gunshot reverb and the crash report. Each part is driven by its Lua module, so turning a module off turns its native part off too. Everything is source; there are no closed binaries.
