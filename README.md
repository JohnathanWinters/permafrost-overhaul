# Permafrost Overhaul

A tougher, more immersive take on **Permafrost**. Loot is scarce, food is harder to find, hunting is more dangerous, and enemies behave more aggressively. The HUD is quieter, survival is harsher, and the world feels less predictable.

**Modular by design.** Every feature can be enabled or disabled independently.

## Installation

1. Install [UE4SS v3.0.1](https://github.com/UE4SS-RE/RE-UE4SS) for Permafrost.
2. Download the latest [release](https://github.com/JohnathanWinters/permafrost-overhaul/releases).
3. Copy the `Rebalance` folder into `Permafrost\Binaries\Win64\ue4ss\Mods\`.
4. Launch the game.

## Configuration

Edit `config.lua` inside the `Rebalance` folder, then restart the game.

- **Modules:** Set each feature to `1` to enable it or `0` to disable it.
- **Values:** Each setting shows the mod value, vanilla value, and a description.
- **`vanilla -`:** The setting does not exist in the original game.
- **Config files:** Files in `config\` are regenerated from `config.lua` at startup. Edit `config.lua`, not those generated files.

## Features

### Survival & Weather

| Module | Changes |
|---|---|
| `eternaltorches` | Placed torches never run out of fuel. |
| `food` | Food and drinks no longer restore health. Tooltips are updated; medicine still heals. |
| `weather` | Snowfall is 3× more likely, blizzards 1.75× more likely. Snowfall remains the more common event. |
| `survivaltweaks` | Take 1.5× damage. Hunger drains at 0.2× the vanilla rate. Body warmth drains at 0.12×, but cold drains warmth faster the further it exceeds your clothing's protection. |
| `buildsnow` | Snow accumulates on player-built structures exposed to the sky. Fixes vanilla snow appearing on stoves and torches under roofs. |
| `recipes` | Makeshift Heater requires cloth, plastic, and 1 chemical to craft, and 1 chemical to repair. |

### Loot & Resources

| Module | Changes |
|---|---|
| `loot` | Food and drinks have a 15% drop chance, except from animals. Trash always yields 3–5 plastic. Carcasses yield 1.5× pelts, fat, and bones; big game yields 4× meat. |
| `containers` | Most containers have already been looted. See the container table below for untouched chances and typical contents. Only unopened containers are affected. Locked containers are always full. |
| `enemydrops` | Armed hostiles drop their weapon at 10–50% condition. There is a 70% chance to drop 1–3 cloth. |
| `craftfromstorage` | Craft, build, and repair using items stored within 15 m. |
| `toolbelt` | Automatically draw a hotbar knife to skin animals or open electrical boxes. Any knife tier works, regardless of durability. |
| `recipes` | Adjusts the Makeshift Heater's crafting and repair costs. |

### Combat & Enemies

| Module | Changes |
|---|---|
| `encounters` | Hostile encounters occur one-third as often. Scripted encounter locations take 3× longer to reset. |
| `humanai` | Hostiles never flinch, reposition less often, and return fire more aggressively. |
| `patrols` | When no hostile is within 300 m, a patrol of 1–3 enemies may arrive, at most once every 10 minutes. Patrols disappear beyond 400 m. |
| `spawndistance` | Enemies spawn 2× farther away, with encounters 100–200 m away. Groups spread out and arrive individually. Enemy spawners remain inactive within 100 m. Animals never spawn within 100 m; any that do are moved farther away. |
| `harderhunting` | Animals see 3× and hear 4× farther, and move 1.25× faster. Animal populations are reduced by 40%. Prey flees and avoids you for 3 minutes. |
| `betterguns` | Gunshots are louder, with strong indoor reverb that is more pronounced inside buildings. Other sounds duck after gunfire. Recoil is 2× and camera kick is 2.5×. Headshots deal 8× damage with guns and bows, and 2× with melee. |
| `accuracy` | Movement, jumping, and rapid fire increase weapon spread. Aiming and crouching reduce it. The Accuracy skill further reduces spread, and crosshair lines widen to reflect current accuracy. |

### Exploration & Movement

| Module | Changes |
|---|---|
| `locks` | Unlocked containers remain unlocked after reloading. |
| `flashlight` | Sharper shadows, higher aiming angle, and 3× range. |
| `togglemovement` | Sprint and crouch toggle on tap. Sprint stops when movement keys are released and resumes after a weapon swap. |
| `travelcost` | Fast travel consumes 1 food or drink, taking items from the hotbar first (highest slot first), then inventory. Travel is blocked if neither is available. |
| `bedtravel` | Look at your bed and press `X` to fast travel. The key is configurable. The travel lamp remains usable. |
| `hud` | Health indicators appear only when a stat falls below 25%. The hotbar appears for 2 seconds after a hotbar key press; the weapon panel appears for 2 seconds after switching weapons and stays hidden with empty hands. The quest panel appears for 6 seconds after a change or when closing a menu. The compass remains visible. |

## Container Loot Chances

Most containers have been picked clean. The chance of finding an untouched container, along with its typical contents, depends on the type.

| Container | Untouched chance | Typical contents |
|---|---:|---|
| Fridges | 6% | Drinks, food |
| Medical boxes | 6% | Bandages, painkillers, medkits |
| Cars | 8% | Plastic, wire, metal, fabric, sometimes fuel |
| Electrical boxes | 8% | Components, wire |
| Toolboxes | 10% | Metal, components, wire, batteries |
| Cabinets and lockers | 12% | Household items |
| Military vehicles | 12% | Military supplies, ammunition |
| Suitcases | 15% | Clothes, snacks, cash |
| Ammo boxes | 15% | About 70 rounds |
| Trash bins | 20% | Junk |
| Dead bodies | 20% | A few items |
| Safes | 25% | Cash, with 3× the usual amount |

Only unopened containers are affected. Locked containers are always full.

## Development & Work in Progress

| Module | Status |
|---|---|
| `f8log` | Press `F8` to save nearby lootable objects to `loot_census.txt`. Logging only; does not change the game. |
| `warmth` | Clothing warmth that scales with the cold. Logging only for now. |
| `doors` | Tracks door and shutter states across saves. Logging only for now. |

## Building `main.dll`

The native module is built from `src\main.cpp` using `src\build.bat` and Visual Studio 2022 Build Tools. It handles features that Lua cannot access, including crafting from storage, spawn blockers, headshot damage, toolbelt checks, survival rates, fast-travel costs, gunshot reverb, and crash reporting.

Each native feature follows its corresponding Lua module toggle.

**All source code is included. No closed-source binaries.**