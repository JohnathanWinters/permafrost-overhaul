-- Overhaul settings: the only file to edit. Restart the game after saving.
-- Each line: our value, then the vanilla value and what it does.
-- 'vanilla -' means the game has no such setting (the feature is ours).
-- The Loot Ledger page shows what these numbers do to every loot table.
return {

    -- MODULES: Each feature is one file in Scripts. 1 = on, 0 = off. Every one works on its own.
    Modules = {
        loot                       = 1     , -- Scripts/loot.lua             loot tables: trash, carcasses, bodies, resources; food scarcity
        containers                 = 1     , -- Scripts/containers.lua       containers mostly looted, rare untouched ones well stocked
        locks                      = 1     , -- Scripts/locks.lua            unlocked boxes stay unlocked after a reload
        enemydrops                 = 1     , -- Scripts/enemydrops.lua       enemies drop the gun they carried and cloth
        encounters                 = 1     , -- Scripts/encounters.lua       fewer hostile random encounters, slower scripted camps
        spawndistance              = 1     , -- Scripts/spawndistance.lua    spawns farther away, no spawns within 100 m
        patrols                    = 1     , -- Scripts/patrols.lua          patrol squads when no enemy is near
        humanai                    = 1     , -- Scripts/humanai.lua          enemies do not flinch, reposition less
        harderhunting              = 1     , -- Scripts/harderhunting.lua    sharper animal senses, speed and fleeing
        betterguns                 = 1     , -- Scripts/betterguns.lua       gun sound, hall reverb, recoil, headshots
        flashlight                 = 1     , -- Scripts/flashlight.lua       flashlight shadows, aim and range
        togglemovement             = 1     , -- Scripts/togglemovement.lua   tap to sprint and crouch
        eternaltorches             = 1     , -- Scripts/eternaltorches.lua   placed torches never run out
        craftfromstorage           = 1     , -- Scripts/craftfromstorage.lua craft, repair and build from nearby storage
        survivaltweaks             = 1     , -- Scripts/survivaltweaks.lua   hunger, stamina, warmth and damage rates
        toolbelt                   = 1     , -- Scripts/toolbelt.lua         knife in the hotbar counts as held
        accuracy                   = 1     , -- Scripts/accuracy.lua         moving, jumping and rapid fire spread your shots; aiming and crouching tighten them; the crosshair shows it
        recipes                    = 1     , -- Scripts/recipes.lua          Makeshift Heater needs and repairs with chemicals
        food                       = 1     , -- Scripts/food.lua             food and drinks do not heal
        hud                        = 1     , -- Scripts/hud.lua              HUD parts fade out until needed
        buildsnow                  = 1     , -- Scripts/buildsnow.lua        snow on player-built structures (now: discovery only, logs, changes nothing)
        warmth                     = 1     , -- Scripts/warmth.lua           heat loss that follows your clothing vs the cold (now: logging only, changes nothing)
        weather                    = 1     , -- Scripts/weather.lua          storms and snowfall come more often
        travelcost                 = 1     , -- Scripts/travelcost.lua       fast travel costs food (hotbar first)
        doors                      = 1     , -- Scripts/doors.lua            doors and shutters keep their state across saves (now: discovery only)
        f8log                      = 1     , -- Scripts/f8log.lua            F8 loot logger (research tool, changes nothing)
        diagnostics                = 1     , -- (main.lua, main.dll)         profiler, flight recorder and crash report in dlls; 0 = off
    },

    -- LOOT: Loot you break or harvest. Find = chance an item is there, Amount = how many. 1.0 = vanilla.
    Loot = {
        containerProfiles          = 1     , -- vanilla 0     1 = containers use the Containers section below (mostly looted, rare full ones)
        trashFind                  = 1.0   , -- vanilla 1.0   trash bags and piles you break: chance
        trashAmount                = 2.5   , -- vanilla 1.0   trash bags and piles: amount (plastic bags give 3 to 5)
        animalsFind                = 1.0   , -- vanilla 1.0   animal carcasses: chance
        animalsAmount              = 1.5   , -- vanilla 1.0   animal carcasses: pelts, meat, fat, bones
        animalsMeatBigGame         = 4.0   , -- vanilla 1.0   raw meat from deer, moose, boar, bison, muskox and bear carcasses (replaces animalsAmount for meat)
        resourcesFind              = 1.0   , -- vanilla 1.0   rocks, ore, wood, scrap: chance
        resourcesAmount            = 1.0   , -- vanilla 1.0   rocks, ore, wood, scrap: amount
        foodFind                   = 0.15  , -- vanilla 1.0   food and drinks everywhere except animals: chance (containers, bodies, piles)
    },

    -- ENEMIES: What hostile humans carry and drop.
    Enemies = {
        enemiesFind                = 1.0   , -- vanilla 1.0   chance each loot item is on the body
        enemiesAmount              = 1.0   , -- vanilla 1.0   amount of each loot item
        enemyFoodFind              = 0.15  , -- vanilla 1.0   food and drinks on the body (they rarely carry food)
        enemyGunDrop               = 1.0   , -- vanilla 0.0   chance the body has the gun it carried (vanilla: only IZG, about 3%)
        enemyGunWearMin            = 10    , -- vanilla 10    dropped gun condition, lowest %
        enemyGunWearMax            = 50    , -- vanilla 50    dropped gun condition, highest %
        enemyClothChance           = 0.7   , -- vanilla 0.0   chance the body has cloth (they wear clothes)
        enemyClothMin              = 1     , -- vanilla 0     cloth, lowest
        enemyClothMax              = 3     , -- vanilla 0     cloth, highest
    },

    -- ENCOUNTERS: Random and scripted encounters.
    Encounters = {
        enemyEncounterRate         = 0.35  , -- vanilla 1.0   random encounters with hostile humans: how often
        otherEncounterRate         = 1.0   , -- vanilla 1.0   random encounters with animals, moonrock, bodies: how often
        staticEncounterReuse       = 3.0   , -- vanilla 1.0   scripted spots (cultist camps): wait before they can happen again
        randomEncounterMinMetres   = 100   , -- vanilla 50    random encounters spawn at least this far away
        randomEncounterMaxMetres   = 200   , -- vanilla 100   and at most this far away
    },

    -- SPAWNS: Where and how often things spawn.
    Spawns = {
        spawnDistanceMultiplier    = 2.0   , -- vanilla 1.0   how far other spawn placements reach
        animalTriggerMultiplier    = 1.2   , -- vanilla 1.0   animal spawn point range (1.2 = 300 m): animals appear and are cleared at this distance
        bearTriggerMultiplier      = 1.0   , -- vanilla 1.0   bear spawn points (vanilla 250 m)
        encounterTriggerMultiplier = 2.0   , -- vanilla 1.0   NPC and encounter spawners trigger from farther away
        spawnerSpreadMultiplier    = 2.5   , -- vanilla 1.0   how far apart an enemy group stands (vanilla 10 m square, 1 m apart)
        spawnerIntervalSeconds     = 1.0   , -- vanilla 0.1   seconds between each enemy a spawner creates (spreads the hitch)
        blockSpawnMetres           = 100   , -- vanilla 0     enemy spawners do not spawn while you are this close to them
        animalBlockMetres            = 100   , -- vanilla 0     animal spawn points do not spawn while you are this close; they spawn once you are farther
    },

    -- HUNTING: Animal senses and behavior. 1.0 = vanilla.
    Hunting = {
        sightRangeMultiplier       = 3.0   , -- vanilla 1.0   how far animals see you
        peripheralVisionMultiplier = 1.25  , -- vanilla 1.0   how wide animals see (max 180 degrees)
        hearingRangeMultiplier     = 4.0   , -- vanilla 1.0   how far animals hear you
        animalSpeedMultiplier      = 1.25  , -- vanilla 1.0   movement speed, fleeing included
        injuredSpeedMultiplier     = 1.0   , -- vanilla 1.0   speed cap once wounded
        animalHealthMultiplier     = 1.0   , -- vanilla 1.0   animal health
        lootMultiplier             = 1.0   , -- vanilla 1.0   meat and hide (use Loot animalsAmount instead)
        bigGameMeatMultiplier      = 1.0   , -- vanilla 1.0   (no effect: carcass loot comes from the Loot section, see animalsMeatBigGame)
        spawnCountMultiplier       = 0.6   , -- vanilla 1.0   animals per spawn point
        smartFlee                  = 1     , -- vanilla 0     1 = prey always runs away from you
        fleeDistanceMetres         = 60    , -- vanilla -     how far away fleeing prey aims for
        fleeCheckMetres            = 90    , -- vanilla -     prey this close are steered
        fearSeconds                = 180   , -- vanilla 0     after fleeing, prey avoid you this long
        fearMetres                 = 150   , -- vanilla -     and stay at least this far from you
    },

    -- GUNS: Gun sound and handling. 1.0 = vanilla.
    Guns = {
        shotVolume                 = 10.0  , -- vanilla 1.0   gunshot loudness (2.0 = +6 dB)
        duckAmount                 = 0.55  , -- vanilla 1.0   other sounds drop to this share of their volume right after your shot (1 = no ducking)
        duckRecoverMs              = 900   , -- vanilla -     how long other sounds take to come back after a shot
        suppressedShotVolume       = 2.0   , -- vanilla 1.0   suppressed gunshot loudness
        gunReverbVolume            = 6.0   , -- vanilla 1.0   gunshot reverb
        worldReverbVolume          = 2.0   , -- vanilla 1.0   reverb on all sounds outdoors
        indoorReverbVolume         = 7.0   , -- vanilla 1.0   reverb on all sounds indoors
        echoVolume                 = 4.0   , -- vanilla 0     outdoor echo after each shot
        echoRepeats                = 0     , -- vanilla 0     canyon echo: repeats after each shot outdoors (0 to 10)
        echoSpacingMs              = 400   , -- vanilla -     canyon echo: delay of the first repeat, later ones spread out (6 x 400 = about 3.8 s)
        echoDecay                  = 0.72  , -- vanilla -     canyon echo: each repeat's volume vs the one before
        echoPitchDrop              = 0.03  , -- vanilla -     canyon echo: each repeat this much deeper
        indoorEchoVolume           = 20.0  , -- vanilla 0     indoor room echo after each shot
        echoMinGapMs               = 300   , -- vanilla -     full auto: at most one echo per this many ms
        hallReverb                 = 1     , -- vanilla 0     1 = real hall reverb on your gunshots
        hallDecayMs                = 3900  , -- vanilla -     how long the hall rings out (concert hall 3900, hangar 10000)
        hallWetDb                  = -9    , -- vanilla -     reverb loudness outdoors in dB (-80 = none, 0 = as loud as the shot)
        hallWetIndoorDb            = -4    , -- vanilla -     reverb loudness indoors in dB
        hallHighCutHz              = 5650  , -- vanilla -     reverb brightness: lower = darker, warmer hall
        bassLayerVolume            = 2.0   , -- vanilla 0     deep layer under each shot
        bassLayerPitch             = 0.45  , -- vanilla -     pitch of that layer (lower = deeper)
        shotPitch                  = 0.88  , -- vanilla 1.0   pitch of the shot (below 1 = less metallic)
        echoPitch                  = 0.92  , -- vanilla 1.0   pitch of echoes
        headshotMultiplier         = 2.0   , -- vanilla 1.0   head damage for melee weapons
        headshotPistol             = 8.0   , -- vanilla 1.0   head damage for pistols and SMGs
        headshotRifle              = 8.0   , -- vanilla 1.0   head damage for rifles, shotguns and other guns
        headshotBow                = 8.0   , -- vanilla 1.0   head damage for bows
        recoilMultiplier           = 2.0   , -- vanilla 1.0   weapon kick
        cameraKickMultiplier       = 2.5   , -- vanilla 1.0   camera shake per shot
    },

    -- HUMAN AI: Hostile humans in a fight.
    HumanAI = {
        flinch                       = 0     , -- vanilla 1     0 = hostile humans never flinch when hit, 1 = flinch with the cooldown below
        flinchCooldownSeconds        = 4.0   , -- vanilla 0     after an enemy flinches, more hits within this many seconds do not flinch it again
        repositionIntervalMultiplier = 4.0   , -- vanilla 1.0   how much longer enemies wait before repositioning (less flanking, more shooting back)
        debugLog                     = 1     , -- vanilla -     1 = log what was found and changed
    },

    -- PATROLS: When no hostile human is near, the game sends a small patrol squad your way. Vanilla: none.
    Patrols = {
        emptyRadiusMetres            = 300   , -- vanilla -     a squad comes only when no hostile human is this close
        despawnMetres                = 400   , -- vanilla 150   a squad this far away disappears (also the game's own random encounters)
        cooldownMinutes              = 10    , -- vanilla -     minimum time between squads
        firstDelayMinutes            = 3     , -- vanilla -     no squad in the first minutes after loading
        includeResistance            = 0     , -- vanilla -     1 = Resistance patrols can come too
        debugLog                     = 1     , -- vanilla -     1 = log checks and squads
    },

    -- FLASHLIGHT: Your flashlight. Vanilla: no shadows, aimed at the ground close in front.
    Flashlight = {
        castShadows                  = 1     , -- vanilla 0     1 = the flashlight casts shadows
        pitchUpDegrees               = 6     , -- vanilla 0     aim the beam this many degrees higher
        rangeMultiplier              = 3.0   , -- vanilla 1.0   how far the light reaches (vanilla about 6 m)
        sourceRadiusCm               = 3     , -- vanilla 25    size of the light source: smaller = sharper shadows
        shadowSharpen                = 0.5   , -- vanilla 0     extra shadow edge sharpening, 0 to 1
        shadowResolution             = 2.0   , -- vanilla 1.0   shadow detail
        offsetDownCm                 = 25    , -- vanilla 0     light sits this far below your eyes, so its shadows show
        offsetRightCm                = 20    , -- vanilla 0     and this far to the right
        debugLog                     = 1     , -- vanilla -     1 = log what was found
    },

    -- ACCURACY: Extra spread on your shots on top of each gun's own. Degrees. The crosshair grows and shrinks with it.
    Accuracy = {
        moveSpreadDeg                = 2.0   , -- vanilla 0     extra spread at a full sprint (walking adds part of it)
        airSpreadDeg                 = 3.0   , -- vanilla 0     extra spread while jumping or falling
        shotSpreadDeg                = 0.6   , -- vanilla 0     extra spread added by each shot
        shotRecoveryDegPerSec        = 3.0   , -- vanilla -     how fast the per-shot spread recovers
        maxSpreadDeg                 = 5.0   , -- vanilla -     largest extra spread
        aimMultiplier                = 0.35  , -- vanilla -     extra spread while aiming down sights (0.35 = 35%)
        crouchMultiplier             = 0.7   , -- vanilla -     extra spread while crouched
        sprintSpeed                  = 600   , -- vanilla -     speed in cm/s that counts as a full sprint
        useAccuracySkill             = 1     , -- vanilla -     1 = your Accuracy skill shrinks the extra spread by the same per-level benefit the game uses
        minSkillMultiplier           = 0.3   , -- vanilla -     a maxed skill never shrinks the extra spread below this share
        reticle                      = 1     , -- vanilla 0     1 = the crosshair lines open up and close with the spread
        reticlePixelsPerDeg          = 10    , -- vanilla -     how far the crosshair lines move apart per degree of extra spread (pixels)
        reticleGap                   = 6     , -- vanilla -     gap between the crosshair lines when steady (pixels)
        reticleLength                = 10    , -- vanilla -     length of each crosshair line (pixels)
        reticleThickness             = 2     , -- vanilla -     thickness of each crosshair line (pixels)
        debugLog                     = 1     , -- vanilla -     1 = log the first shots
    },

    -- WEATHER: How often storms come. 1.0 = vanilla.
    Weather = {
        blizzardChanceMultiplier     = 1.75  , -- vanilla 1.0   how much more likely blizzards are
        blizzardCooldownMultiplier   = 0.7   , -- vanilla 1.0   how much shorter the wait between blizzards is
        snowChanceMultiplier         = 3.0   , -- vanilla 1.0   how much more likely snowfall (and snowstorms) is
        snowCooldownMultiplier       = 0.5   , -- vanilla 1.0   how much shorter the wait between snowfalls is
        blizzardShareOfSnow          = 0.6   , -- vanilla -     blizzards never end up more likely than this share of snowfall
    },

    -- BUILD SNOW: Snow on player-built structures, like on the game's own buildings.
    BuildSnow = {
        coverage                     = 0.9   , -- vanilla 0     snow coverage on built parts (0 = off)
        falloffOffset                = 0.2   , -- vanilla -     how far the snow reaches down the sides
        maskCutoff                   = 0.05  , -- vanilla -     snow mask cutoff
        shelterMetres                = 30    , -- vanilla -     a part with a roof (anything) above it within this distance gets no snow
        swapMaterial                 = 1     , -- vanilla 0     1 = rebuild part materials on the game's snowy wood material (needed for snow to show)
    },

    -- TRAVEL COST: What fast travel costs. Food comes from the hotbar first (highest slot first), then the inventory.
    TravelCost = {
        foodPerTrip                  = 1     , -- vanilla 0     food items one fast travel costs (food and drinks, not medicine)
        hotbarSlots                  = 8     , -- vanilla -     number of hotbar slots
    },

    -- RECIPES: Crafting and repair costs.
    Recipes = {
        heaterChemicals              = 1     , -- vanilla 0     chemicals to craft the Makeshift Heater (plus cloth and plastic)
        heaterRepairChemicals        = 1     , -- vanilla -     chemicals to repair it (replaces its vanilla repair cost; 0 = vanilla)
    },

    -- FOOD: What eating does.
    Food = {
        foodHeals                    = 0     , -- vanilla 1     1 = food and drinks heal, 0 = they do not (tooltip too)
        debugLog                     = 1     , -- vanilla -     1 = log what was changed
    },

    -- HUD: Hide HUD parts until they matter. The compass always stays.
    HUD = {
        lowStatPercent               = 25    , -- vanilla -     health area shows while any of its bars is below this %
        hotbarShowSeconds            = 2     , -- vanilla -     hotbar shows this long after a hotbar key
        questShowSeconds             = 12    , -- vanilla -     quest box shows this long after it changes
        weaponShowSeconds            = 2     , -- vanilla -     selected weapon box shows this long after you switch items (hidden with empty hands)
        fadeSeconds                  = 0.25  , -- vanilla -     fade time
        debugLog                     = 1     , -- vanilla -     1 = log the HUD parts found (dlls\hud_tree.txt)
    },

    -- SURVIVAL: How fast you lose your own stats. Gains and healing stay vanilla. 1.0 = vanilla, 0.5 = half, 2.0 = double.
    Survival = {
        staminaDrainMultiplier     = 1.2   , -- vanilla 1.0   stamina use
        hungerDrainMultiplier      = 0.2   , -- vanilla 1.0   hunger
        energyDrainMultiplier      = 1.0   , -- vanilla 1.0   energy (tiredness)
        healthDamageMultiplier     = 1.5   , -- vanilla 1.0   damage you take
        bodyWarmthLossMultiplier   = 2.0   , -- vanilla 1.0   body warmth loss in the cold
    },

    -- MOVEMENT: Sprint and crouch.
    Movement = {
        toggleSprint               = 1     , -- vanilla 0     1 = tap to sprint
        toggleCrouch               = 1     , -- vanilla 0     1 = tap to crouch
        sprintStopDelayMs          = 100   , -- vanilla -     sprint stops this long after you let go of WASD (ms)
        debugLog                   = 1     , -- vanilla 0     1 = log sprint and crouch events (tuning)
    },

    -- TORCHES: Fuel.
    Torches = {
        enabled                    = 1     , -- vanilla 0     1 = placed torches never use fuel
        includeBraziers            = 0     , -- vanilla 0     1 = braziers too
        includeAllFires            = 0     , -- vanilla 0     1 = every fire: campfires, stoves, furnaces
    },

    -- CRAFTING: Crafting and building from storage.
    Crafting = {
        enabled                    = 1     , -- vanilla 0     1 = crafting, repairs and building use nearby storage
        radiusMetres               = 15    , -- vanilla -     how far the storage can be
    },

    -- TOOLBELT: Tools in the hotbar count as held. Vanilla: the tool must be in your hand.
    Toolbelt = {
        enabled                    = 1     , -- vanilla 0     1 = on
        knife                      = 1     , -- vanilla 0     knife: skinning, electrical boxes
        crowbar                    = 0     , -- vanilla 0     crowbar
        axe                        = 0     , -- vanilla 0     axe
        pickaxe                    = 0     , -- vanilla 0     pickaxe
        key                        = 0     , -- vanilla 0     keys
        anyKnifeTier               = 1     , -- vanilla 0     1 = any knife opens what needs a knife; a lower tier costs durability
        knifeBaseCost              = 0     , -- vanilla -     durability % an under-tier knife uses per opening
        knifeCostPerTier           = 0     , -- vanilla -     extra durability % per tier step the knife is short (refined counts as a step)
        hotbarUnlockSeconds        = 1     , -- vanilla -     hold the interact key this long to open a knife lock with a knife in your hotbar (knife durability not used)
    },

    -- CONTAINERS: most are already looted (empty); the odd untouched one is full.
    -- Vanilla: every container is always stocked (untouched 1.0, keep 1, no picks or extras).
    --   untouched : chance it was never looted        keep : multiplier on the game's own roll
    --   replace   : true = drop the game's own roll, the profile's list is the whole content
    --   picks     : picks from a game item list (min-max picks, stackMin-stackMax of each, chance)
    --   extras    : specific items (min-max, chance)  match : container class patterns, first match wins
    Containers = {

        -- Animal carcasses you skin are searchable too; they stay vanilla here
        -- (their yield is set by animalsAmount in config.lua).
        { name = "Animal carcasses (unchanged)", untouched = 1.0, keep = 1,
          match = { "Carcass", "DogLoot" } },

        -- An untouched fridge: a shelf of drinks and several kinds of food.
        { name = "Fridges", untouched = 0.06, keep = 2,
          match = { "Fridge" },
          picks = { { list = "DA_RandomList_Preset_Remnants_Fridge", min = 5, max = 9, stackMin = 1, stackMax = 4, chance = 1.0 } } },

        -- A wall first-aid cabinet: a few kinds of supplies, several of each.
        { name = "Medical boxes", untouched = 0.06, keep = 2,
          match = { "MedicalBox" },
          picks = { { list = "DA_RandomList_Preset_Remnants_Medication", min = 3, max = 5, stackMin = 1, stackMax = 3, chance = 1.0 } } },

        -- A breaker / junction box nobody stripped: boards, wire, junk.
        { name = "Electricity boxes", untouched = 0.08, keep = 2,
          match = { "ElectricityBox" },
          extras = { { item = "DA_Resource_Components", min = 3, max = 8, chance = 1.0 },
                     { item = "DA_Resource_ElectricalJunk", min = 3, max = 6, chance = 1.0 },
                     { item = "DA_Resource_Wire", min = 4, max = 10, chance = 0.9 },
                     { item = "DA_Resource_Batteries", min = 1, max = 3, chance = 0.3 } } },

        -- A military truck or jeep left intact: supplies, rations, some ammo.
        { name = "Military vehicles", untouched = 0.12, keep = 2,
          match = { "Military_Car" },
          picks = { { list = "DA_RandomList_Preset_Military_All", min = 2, max = 4, stackMin = 1, stackMax = 2, chance = 1.0 },
                    { list = "DA_RandomList_Preset_Military_Ammo", min = 1, max = 2, chance = 0.6 } } },

        -- A car nobody searched: plastic trim and junk, pulled wiring, some scrap,
        -- a first-aid kit. Fuel and oil are usually long gone.
        -- replace = true: this list is the whole content (the game's own oil and
        -- metal roll is dropped).
        { name = "Cars", untouched = 0.08, replace = true,
          match = { "^BP_S_Car_" },
          picks = { { list = "DA_RandomList_Consumables_PocketFood", min = 1, max = 3, stackMin = 1, stackMax = 2, chance = 0.4 } },
          extras = { { item = "DA_Resource_PlasticJunk", min = 3, max = 8, chance = 0.95 },
                     { item = "DA_Resource_Wire", min = 3, max = 8, chance = 0.85 },
                     { item = "DA_Resource_MetalJunk", min = 2, max = 5, chance = 0.85 },
                     { item = "DA_Resource_FabricJunk", min = 1, max = 4, chance = 0.6 },
                     { item = "DA_Resource_Oil", min = 1, max = 1, chance = 0.15 },
                     { item = "DA_Resource_LowGradeFuel", min = 1, max = 2, chance = 0.15 },
                     { item = "DA_Consumable_Medication_Bandage", min = 1, max = 3, chance = 0.25 },
                     { item = "DA_Consumable_Medication_Car_Medkit", min = 1, max = 1, chance = 0.15 } } },

        -- A full ammo can: one or a few calibers, game amounts are already boxes of rounds.
        { name = "Ammo boxes", untouched = 0.15, keep = 2,
          match = { "AmmoBox" },
          picks = { { list = "DA_RandomList_Preset_Military_Ammo", min = 1, max = 3, chance = 1.0 } } },

        { name = "Military crates and army bags", untouched = 0.15, keep = 2,
          match = { "MilitaryCrate", "ArmyBag" },
          picks = { { list = "DA_RandomList_Preset_Military_All", min = 3, max = 5, stackMin = 1, stackMax = 2, chance = 1.0 } } },

        { name = "Quality and insulated crates", untouched = 0.20, keep = 2,
          match = { "QualityCrate", "InsulatedCrate" },
          picks = { { list = "DA_RandomList_Preset_Remnants_QualityCrate", min = 3, max = 4, stackMin = 1, stackMax = 3, chance = 1.0 } } },

        -- A bin nobody dug through: a bag or two of plastic, metal and fabric junk.
        { name = "Trash cans, bins, dumpsters", untouched = 0.20, keep = 2,
          match = { "TrashCan", "SearchableBin", "TrashContainer" },
          picks = { { list = "DA_RandomList_Preset_Remnants_Trash", min = 2, max = 4, stackMin = 1, stackMax = 3, chance = 1.0 } } },

        -- Kitchen cabinets, office drawers, lockers.
        { name = "Cabinets and lockers", untouched = 0.12, keep = 2,
          match = { "Cabinet", "Locker" },
          picks = { { list = "DA_RandomList_Preset_Remnants_Cabinet", min = 3, max = 6, stackMin = 1, stackMax = 2, chance = 1.0 } } },

        -- Storage crates: wood, rope, cloth, hides.
        { name = "Wooden boxes and crates", untouched = 0.15, keep = 2,
          match = { "WoodenBox", "WoodenCrate" },
          picks = { { list = "DA_RandomList_Preset_Remnants_WoodenBox", min = 2, max = 4, stackMin = 1, stackMax = 4, chance = 1.0 } } },

        -- A toolbox left behind: hardware, parts, wire.
        { name = "Toolboxes", untouched = 0.10, keep = 2,
          match = { "Toolbox" },
          extras = { { item = "DA_Resource_MetalJunk", min = 3, max = 6, chance = 0.9 },
                     { item = "DA_Resource_Components", min = 2, max = 5, chance = 0.8 },
                     { item = "DA_Resource_Wire", min = 2, max = 4, chance = 0.6 },
                     { item = "DA_Resource_Batteries", min = 1, max = 3, chance = 0.4 } } },

        -- A packed suitcase: clothes, snacks, some cash.
        { name = "Suitcases and luggage", untouched = 0.15, keep = 2,
          match = { "Suitcase", "Luggage" },
          picks = { { list = "DA_RandomList_Preset_Remnants_Luggage", min = 4, max = 8, stackMin = 1, stackMax = 2, chance = 1.0 } } },

        { name = "Safes", untouched = 0.25, keep = 3,
          match = { "Safe" },
          extras = { { item = "DA_Resource_Bucks", min = 50, max = 200, chance = 1.0 } } },

        -- Pockets and a bag.
        { name = "Dead bodies", untouched = 0.20, keep = 1.5,
          match = { "^BP_S_0%d_", "DeadOnTheGround", "SittingOnChair", "RestingOnWall", "Hanged", "HangingOnFence", "FallenFromHeight" },
          picks = { { list = "DA_RandomList_Preset_Remnants_All", min = 1, max = 3, stackMin = 1, stackMax = 2, chance = 1.0 } } },

        { name = "Other searchable containers", untouched = 0.15, keep = 2,
          match = { "" } },
    },
}
