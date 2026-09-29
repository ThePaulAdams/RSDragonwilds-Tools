local UEHelpers = require("UEHelpers")

local ModName = "QuickStack"

local Config = {
    -- Keybind to activate Quick Stack / Ground Magnetism
    Key = Key.G,
    Modifier = nil, -- Optional modifier key, e.g. ModifierKey.CONTROL or nil for just G

    -- Maximum distance (in Unreal Units) to search for chests. 10000 uu = 100 meters.
    SearchRadius = 10000.0,

    -- Maximum distance (in Unreal Units) to magnetize ground items into inventory. 4000 uu = 40 meters.
    GroundMagnetRadius = 4000.0,

    -- Maximum distance (in Unreal Units) to pack up ground items into Relocation Crate. 15000 uu = 150 meters.
    RelocationPackRadius = 15000.0,

    -- Protect the player's quick-action hotbar slots from being deposited.
    ProtectHotbar = true,

    -- Protect combat ammunition (arrows, bolts, quivers) from being deposited into chests
    ProtectAmmo = true,

    -- Protect magic runes and essence from being deposited into chests
    ProtectRunes = true,

    -- QuickStack (Deposit): If true, sorts similar items into dedicated chests by category (e.g. all food together)
    SortSimilarIntoChests = true,

    -- Automatically reorganize misplaced items between nearby chests so chests stay tidy
    OrganizeNearbyChests = true,

    -- If true, allows items to spill over into other chests if their category chest is completely full.
    -- Set to false so dedicated category chests (Food, Wood, Mining) never get contaminated!
    OverflowWhenCategoryFull = false,

    -- Items whose category has no chest at all go into the MISC chest (or any chest with room)
    -- instead of staying in the backpack. Build a chest for that category to separate them later.
    HomelessItemsToMisc = true,

    -- Experimental: raise small chests to 48 slots and swap in the large chest mesh while sorting.
    -- Off by default because it crashed the game.
    UpgradeChestsTo48Slots = false,

    -- At base, tapping G also picks up loose items on the ground (within GroundMagnetRadius) and stores them in chests
    StoreGroundItemsAtBase = true,

    -- Hold duration (in seconds) to trigger Ground Item Magnetism
    HoldDuration = 0.25,

    -- Alt+G at an open crafting station: stacks of each accepted ingredient to pull from chests
    StationFetchStacksPerItem = 1,
    -- If a station accepts more item types than this, treat it as unfiltered and use name hints
    StationFetchMaxItemTypes = 12,
    -- Furnaces/smelters: only fetch item types already in the station's ingredient or
    -- fuel slots (put one iron ore in -> Alt+G fetches iron). Set false to fetch everything it accepts.
    StationFetchLoadedOnly = true,
    -- Alt+G at a station opens a clickable list of what it can use (items in nearby
    -- chests, with counts); click one to fetch a stack. False = fetch straight away.
    StationFetchPicker = true,
    -- Alt+G with no station open shows the Nearby Storage dialog: every nearby chest
    -- as one list with category tabs; click an item to take stacks of it.
    StorageDialog = true,
    StorageStacksPerClick = 1,
    -- With StationFetchLoadedOnly, an empty station fetches everything it accepts (true) or nothing (false).
    StationFetchAllWhenEmpty = false,

    -- Floating category labels above chests (Shift+F12 toggles)
    ChestLabels = true,
    ChestLabelRadius = 3000.0,  -- 30 meters
    ChestLabelHeight = 110.0,   -- above the chest pivot
    ChestLabelSize = 28.0,

    -- Move items a crafting station drops on the ground into the matching category chest
    AutoStoreStationOutput = true,
    StationOutputRadius = 3000.0, -- only items that appear within 30 m of you

    -- Print detailed information to the console log
    DebugLog = true
}

local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing QuickStack Mod with Smart Category Sorting & Wild Gathering...")
Log("  * Version: 2.1 (60m Base Scan, Small Chest Support, 48-Slot Upgrade, In-Memory Categorization)")
Log("  [Tap G]    : At Base: Auto-stack & sort into matching chests / In Wild: Instant harvest & pull wild plants (onions, dwellberries, flax) & ground loot!")
Log("  [Hold G]   : Continuous 40m vacuum -> Rapidly harvest and magnetize all wild resources & ground items as you run!")
Log("  [Ctrl + G] : PACK BASE -> Store all ground items within 150m into your virtual Relocation Crate!")
Log("  [Shift + G]: UNPACK BASE -> Deposit all Relocation Crate items organized into nearby chests!")
Log("  [Alt + G]  : STATION FETCH -> At an open crafting station, pull its ingredients from nearby chests (or pull the hovered item)")
Log("  [Shift + F12] : Toggle floating category labels above nearby chests")
Log("==========================================")

-- Helper: Safely get the name of any UObject, UClass, or UActorComponent without TrivialObject crashes
local function GetSafeName(obj)
    if not obj then return "" end
    local name = ""
    pcall(function()
        if obj.IsValid and not obj:IsValid() then return end
        if obj.GetFName then
            name = obj:GetFName():ToString()
        elseif obj.GetFullName then
            name = obj:GetFullName()
        end
    end)
    return name or ""
end

-- Helper: Safely get class name of any UObject without TrivialObject crashes
local function GetSafeClassName(obj)
    if not obj then return "" end
    local clsName = ""
    pcall(function()
        if obj.IsValid and not obj:IsValid() then return end
        local cls = obj:GetClass()
        if cls and cls:IsValid() then
            if cls.GetFName then
                clsName = cls:GetFName():ToString()
            elseif cls.GetFullName then
                clsName = cls:GetFullName()
            end
        end
    end)
    return clsName or ""
end

-- Persistent Virtual Storage for Base Relocation (cross-zone persistent, infinite capacity)
local RelocationCrate = {}

-- Helper: Check if an actor is a real world actor (filters out CDOs and archetypes)
local function IsValidWorldActor(actor)
    if not actor then return false end
    local ok, valid = pcall(function()
        if not actor:IsValid() or actor:GetAddress() == 0 then return false end
        if actor:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject) then
            return false
        end
        return true
    end)
    return ok and valid
end

-- Helper: Check if an inventory component is valid and attached to a real world actor
local function IsValidWorldInventory(comp)
    if not comp then return false end
    local ok, valid = pcall(function()
        if not comp:IsValid() or comp:GetAddress() == 0 then return false end
        if comp:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject) then
            return false
        end
        local owner = comp:GetOwner()
        if not owner or not IsValidWorldActor(owner) then return false end
        return true
    end)
    return ok and valid
end

-- Helper: Safe validation of an Item object
local function IsValidItem(item)
    if not item then return false end
    local ok, valid = pcall(function()
        if not item:IsValid() or item:GetAddress() == 0 then return false end
        if item:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject) then
            return false
        end
        return true
    end)
    return ok and valid
end

-- Helper: Get user-friendly name of an Item
local function GetItemName(item)
    if not IsValidItem(item) then return "Unknown Item" end
    local name = nil
    pcall(function()
        local textObj = item:GetPlayerFacingName()
        if textObj and textObj.ToString then
            name = textObj:ToString()
        end
    end)
    if name and name ~= "" then return name end

    pcall(function()
        if item.ItemData and item.ItemData:IsValid() then
            name = GetSafeName(item.ItemData)
        end
    end)
    return name or "Item"
end

-- Helper: Get unique identifier address for an Item's Data Asset
local function GetItemDataAddress(item)
    if not IsValidItem(item) then return nil end
    local addr = nil
    pcall(function()
        if item.ItemData and item.ItemData:IsValid() then
            addr = item.ItemData:GetAddress()
        end
    end)
    return addr
end

-- Helper: Resolve ItemData object safely (with fallback to StaticFindObject by path)
local function ResolveItemData(entry)
    if not entry then return nil end
    if entry.ItemData and entry.ItemData:IsValid() and entry.ItemData:GetAddress() ~= 0 then
        return entry.ItemData
    end
    if entry.AssetPath and entry.AssetPath ~= "" then
        local obj = nil
        pcall(function() obj = StaticFindObject(entry.AssetPath) end)
        if obj and obj:IsValid() then
            return obj
        end
    end
    return nil
end

-- =========================================================================
-- ITEM CATEGORIZATION SYSTEM
-- =========================================================================
local ItemCategories = {
    FOOD = "FOOD",           -- Raw/cooked food, meat, fish, bread, berries, meals, rations, drinks, potions
    RECIPES = "RECIPES",     -- Recipes, plans, blueprints, schematics, books, tomes, scrolls, primers, diagrams
    WOOD = "WOOD",           -- Logs, planks, bark, timber, splinters, charcoal
    MINING = "MINING",       -- Ores, ingots/bars, stone, clay, gems, minerals
    FARMING = "FARMING",     -- Seeds, saplings, plants, flax, herbs, fibers, textiles, leather, cloth
    MAGIC = "MAGIC",         -- Runes, essence, shards, anima
    ARMOUR = "ARMOUR",       -- Wearable armour pieces (helms, bodies, legs, boots, gloves, capes) -> armour stands
    EQUIPMENT = "EQUIPMENT", -- Weapons, shields, tools, jewellery, trinkets
    MISC = "MISC"            -- Quest items, currency, general items
}

local function GetItemCategory(itemOrData)
    if not itemOrData then return ItemCategories.MISC end

    local itemData = nil
    local assetPath = nil
    local itemName = nil

    if type(itemOrData) == "table" and itemOrData.AssetPath then
        assetPath = itemOrData.AssetPath
        itemData = itemOrData.ItemData
        itemName = itemOrData.Name
    else
        pcall(function()
            if itemOrData.ItemData and itemOrData.ItemData:IsValid() then
                itemData = itemOrData.ItemData
            elseif itemOrData:IsValid() then
                itemData = itemOrData
            end
        end)
    end

    local path = ""
    local className = ""
    local tagName = ""

    if itemData and itemData:IsValid() then
        pcall(function() path = itemData:GetPathName():lower() end)
        className = GetSafeClassName(itemData):lower()
        pcall(function()
            if itemData.Category and itemData.Category.TagName then
                tagName = itemData.Category.TagName:ToString():lower()
            end
        end)
    elseif assetPath and assetPath ~= "" then
        path = assetPath:lower()
    end

    local name = ""
    if itemName and itemName ~= "" then
        name = itemName:lower()
    else
        pcall(function()
            name = GetItemName(itemOrData):lower()
        end)
    end

    -- =========================================================================
    -- PRIORITY 1: RECIPES, PLANS, BLUEPRINTS, SCHEMATICS & KNOWLEDGE
    -- =========================================================================
    -- Must be evaluated first so food recipes ("Recipe: Cooked Meat", "Bread Recipe",
    -- "Fish Stew Recipe") and crafting plans ("Plan: Cooking Station", "Plan: Woodcrafting")
    -- are 100% categorized as RECIPES and NEVER pollute Food, Wood, or Equipment chests!
    -- Whole-word match, so "plan" does not match "plank"/"plant" and "tome" does not match "tomato"
    local function HasWord(str, w)
        return str:find("%f[%a]" .. w .. "s?%f[%A]") ~= nil
    end
    local isRecipe = false
    if className:find("recipe") or HasWord(className, "plan") or className:find("blueprint") or
       className:find("schematic") or HasWord(className, "diagram") or HasWord(className, "formula") or
       HasWord(className, "book") or HasWord(className, "tome") or HasWord(className, "lore") or
       className:find("readable") or HasWord(className, "scroll") or HasWord(className, "primer") or
       HasWord(className, "paper") or HasWord(className, "journal") then
        isRecipe = true
    end
    if path:find("/recipe") or HasWord(path, "plan") or path:find("/blueprint") or
       path:find("/schematic") or path:find("item_recipe") or HasWord(path, "plan") or
       HasWord(path, "book") or HasWord(path, "lore") or path:find("/readable") or
       HasWord(path, "scroll") or HasWord(path, "document") or HasWord(path, "book") or
       HasWord(path, "lore") then
        isRecipe = true
    end
    if tagName:find("recipe") or HasWord(tagName, "plan") or tagName:find("blueprint") or
       tagName:find("schematic") or HasWord(tagName, "book") or HasWord(tagName, "tome") or
       HasWord(tagName, "lore") or tagName:find("readable") or HasWord(tagName, "scroll") then
        isRecipe = true
    end
    if name:find("recipe") or HasWord(name, "plan") or name:find("blueprint") or
       name:find("schematic") or HasWord(name, "diagram") or HasWord(name, "formula") or
       HasWord(name, "pattern") or HasWord(name, "book") or HasWord(name, "tome") or
       HasWord(name, "primer") or HasWord(name, "manual") or name:find("treatise") or
       HasWord(name, "scroll") or HasWord(name, "notes") or HasWord(name, "journal") or
       name:find("almanac") or HasWord(name, "guide") or name:find("pamphlet") or
       name:find("folio") or HasWord(name, "document") or name:find("manuscript") or
       name:find("avernic") or name:find("codex") or name:find("grimoire") or
       name:find("chronicle") or name:find("history of") or name:find("tales of") or
       name:find("scripture") or name:find("parchment") or name:find("papyrus") or
       HasWord(name, "letter") or name:find("missive") or HasWord(name, "charter") or
       HasWord(name, "decree") or HasWord(name, "contract") or HasWord(name, "deed") then
        isRecipe = true
    end
    -- Plan assets are named like DA_Consumable_Plan_Decoration_Food_Bowl_Onions; the display name
    -- may not say "plan", and "consumable"/"food" would otherwise send them to the food chest
    if path:find("da_consumable_plan") or path:find("da_consumable_recipe") then
        isRecipe = true
    end
    if isRecipe then
        return ItemCategories.RECIPES
    end

    -- =========================================================================
    -- PRIORITY 2: AGRICULTURAL SEEDS, SAPLINGS, BULBS & SPORES -> FARMING
    -- =========================================================================
    -- Must be evaluated before food keywords so "Watermelon Seeds", "Cabbage Seeds",
    -- "Onion Seeds", "Potato Seeds", etc. are categorized as FARMING, NEVER as Food!
    if name:find("seed") or name:find("seeds") or name:find("sapling") or
       name:find("saplings") or name:find("spore") or name:find("spores") or
       name:find("bulb") or name:find("bulbs") or HasWord(name, "pip") or path:find("/seed") or path:find("item_seed") or
       className:find("seed") or tagName:find("seed") then
        return ItemCategories.FARMING
    end

    -- Wearable armour is split out of EQUIPMENT so it can go onto armour stands
    local function EquipmentOrArmour()
        if path:find("/armour/") or path:find("/armor/") or tagName:find("armour") or tagName:find("armor") then
            return ItemCategories.ARMOUR
        end
        local armourKeywords = {
            "helm", "helmet", "coif", "hood", "cowl", "armour", "armor", "boots", "gloves", "legs",
            "cuirass", "greaves", "gauntlet", "bracer", "vambrace", "robe", "tunic", "chainmail",
            "platebody", "plateleg", "chestplate", "hauberk", "sabaton", "pauldron", "gorget",
            "visor", "chaps", "torso", "cape", "cloak", "body", "trousers", "skirt", "leggings", "mail"
        }
        for _, kw in ipairs(armourKeywords) do
            if name:find(kw) then return ItemCategories.ARMOUR end
        end
        return ItemCategories.EQUIPMENT
    end

    -- 3. Check Class Type
    if className:find("food") or className:find("drink") or className:find("potion") or className:find("consumable") then
        return ItemCategories.FOOD
    end
    if className:find("wardstone") or className:find("whetstone") or className:find("trinket") then
        return ItemCategories.EQUIPMENT
    end

    -- 4. Check Asset Path
    if path ~= "" then
        if path:find("/food/") or path:find("/consumable/") or path:find("/drink/") or path:find("/potion/") or path:find("item_food") then
            return ItemCategories.FOOD
        end
        if path:find("/wood/") or path:find("item_resources_wood") or path:find("item_fuel_resources_wood") then
            return ItemCategories.WOOD
        end
        if path:find("/mineral/") or path:find("/metal/") or path:find("/gem/") or path:find("item_resources_stone") or path:find("item_resources_iron") or path:find("item_resources_bronze") then
            return ItemCategories.MINING
        end
        if path:find("/plant/") or path:find("/herb/") or path:find("/textiles/") or path:find("/animal/") or path:find("item_resources_flax") or path:find("item_herb_") then
            return ItemCategories.FARMING
        end
        if path:find("/magic/") or path:find("item_rune_") or path:find("item_resources_vaultshard") or path:find("item_resources_wildanima") then
            return ItemCategories.MAGIC
        end
        if path:find("/equipment/") or path:find("/armour/") or path:find("/armor/") or path:find("/weapon/") then
            return EquipmentOrArmour()
        end
    end

    -- 5. Check GameplayTag
    if tagName ~= "" then
        if tagName:find("food") or tagName:find("cooking") or tagName:find("consumable") then
            return ItemCategories.FOOD
        end
        if tagName:find("wood") then
            return ItemCategories.WOOD
        end
        if tagName:find("mining") or tagName:find("mineral") or tagName:find("metal") or tagName:find("gem") or tagName:find("smithing") then
            return ItemCategories.MINING
        end
        if tagName:find("plant") or tagName:find("herb") or tagName:find("farming") or tagName:find("textile") then
            return ItemCategories.FARMING
        end
        if tagName:find("magic") or tagName:find("runecrafting") or tagName:find("rune") then
            return ItemCategories.MAGIC
        end
        if tagName:find("equipment") or tagName:find("weapon") or tagName:find("armour") or tagName:find("armor") or tagName:find("tool") then
            return EquipmentOrArmour()
        end
    end

    -- 6. Check Display Name Keywords
    if name ~= "" then
        -- A. Equipment & Armour keywords
        if name:find("sword") or name:find("axe") or name:find("pickaxe") or name:find("shield") or
           name:find("bow") or name:find("helmet") or name:find("helm") or name:find("coif") or
           name:find("armour") or name:find("armor") or name:find("boots") or name:find("gloves") or
           name:find("legs") or name:find("cuirass") or name:find("ring") or name:find("amulet") or
           name:find("necklace") or name:find("cape") or name:find("staff") or name:find("wand") or
           name:find("dagger") or name:find("spear") or name:find("hammer") or name:find("knife") or
           name:find("greaves") or name:find("gauntlet") or name:find("bracer") or name:find("vambrace") or
           name:find("robe") or name:find("tunic") or name:find("chainmail") or name:find("plate") or
           name:find("platebody") or name:find("plateleg") or name:find("mail") or name:find("hood") or
           name:find("hauberk") or name:find("sabaton") or name:find("pauldron") or name:find("gorget") or
           name:find("visor") or name:find("chap") or name:find("cowl") or name:find("chestplate") or
           name:find("torso") or name:find("buckler") or name:find("quiver") or name:find("hatchet") or
           name:find("mace") or name:find("leggings") or name:find("scythe") or name:find("halberd") or name:find("crossbow") then
            return EquipmentOrArmour()
        end

        -- B. Strict Food & Drink keywords (only genuine edible food & potions).
        -- Whole words only, so "Pale Logs", "Leggings", "Spike" or "Plume" never count as food.
        if HasWord(name, "meat") or HasWord(name, "fish") or HasWord(name, "bread") or HasWord(name, "stew") or
           HasWord(name, "soup") or HasWord(name, "berry") or HasWord(name, "berries") or HasWord(name, "dwellberry") or
           HasWord(name, "dwellberries") or HasWord(name, "apple") or HasWord(name, "pie") or HasWord(name, "cake") or
           HasWord(name, "ration") or HasWord(name, "cabbage") or HasWord(name, "potato") or HasWord(name, "potatoes") or HasWord(name, "tomatoes") or HasWord(name, "onion") or
           HasWord(name, "carrot") or HasWord(name, "tomato") or HasWord(name, "corn") or HasWord(name, "watermelon") or
           HasWord(name, "melon") or HasWord(name, "grape") or HasWord(name, "grapes") or HasWord(name, "banana") or
           HasWord(name, "pear") or HasWord(name, "plum") or HasWord(name, "pumpkin") or
           HasWord(name, "mushroom") or HasWord(name, "cooked") or HasWord(name, "raw") or HasWord(name, "burnt") or
           HasWord(name, "drink") or HasWord(name, "potion") or HasWord(name, "brew") or HasWord(name, "ale") or
           HasWord(name, "beer") or HasWord(name, "wine") or HasWord(name, "cider") or HasWord(name, "tea") or
           HasWord(name, "coffee") or HasWord(name, "milk") or HasWord(name, "cheese") or HasWord(name, "egg") or
           HasWord(name, "food") or HasWord(name, "feast") or HasWord(name, "meal") or HasWord(name, "roast") or
           HasWord(name, "steak") or HasWord(name, "ribs") or HasWord(name, "skewer") or HasWord(name, "jerky") or
           HasWord(name, "trout") or HasWord(name, "salmon") or HasWord(name, "tuna") or HasWord(name, "lobster") or
           HasWord(name, "bass") or HasWord(name, "swordfish") or HasWord(name, "shark") or HasWord(name, "shrimp") or
           HasWord(name, "anchovy") or HasWord(name, "herring") or HasWord(name, "pike") or HasWord(name, "cod") or
           HasWord(name, "chicken") or HasWord(name, "beef") or HasWord(name, "pork") or HasWord(name, "mutton") or
           HasWord(name, "venison") or HasWord(name, "bacon") or HasWord(name, "dough") or HasWord(name, "pastry") or
           HasWord(name, "toast") or HasWord(name, "omelette") or HasWord(name, "broth") or HasWord(name, "tart") or
           HasWord(name, "pudding") or HasWord(name, "snack") then
            return ItemCategories.FOOD
        end
        -- Only treat water as food if it's explicitly drinkable/liquid container, not water rune/essence
        if (name:find("water bowl") or name:find("water jug") or name:find("water flask") or
            name:find("water skin") or name:find("water bottle") or name:find("clean water") or
            name:find("fresh water") or name:find("dirty water") or name:find("bucket of water") or
            name:find("jug of water") or name:find("bowl of water")) then
            return ItemCategories.FOOD
        end

        -- C. Wood keywords
        if name:find("wood") or name:find("log") or name:find("logs") or name:find("plank") or
           name:find("planks") or name:find("bark") or name:find("branch") or name:find("timber") or
           name:find("splinter") or name:find("charcoal") or name:find("ash") then
            return ItemCategories.WOOD
        end

        -- D. Mining / Metal / Gem keywords
        if name:find("ore") or name:find("bar") or name:find("bars") or name:find("ingot") or
           name:find("stone") or name:find("rock") or name:find("clay") or name:find("sand") or
           name:find("copper") or name:find("tin") or name:find("bronze") or name:find("iron") or
           name:find("steel") or name:find("mithril") or name:find("adamant") or name:find("runite") or
           name:find("gold") or name:find("silver") or name:find("coal") or name:find("sapphire") or
           name:find("emerald") or name:find("ruby") or name:find("diamond") or name:find("mineral") or
           name:find("nugget") or name:find("gravel") or name:find("flint") or name:find("slab") then
            return ItemCategories.MINING
        end

        -- E. Farming / Herbs / Textiles keywords
        if name:find("flax") or name:find("fiber") or name:find("fibre") or
           name:find("herb") or name:find("plant") or name:find("leaf") or name:find("leaves") or
           name:find("toadflax") or name:find("thread") or name:find("cloth") or name:find("linen") or
           name:find("leather") or name:find("wool") or name:find("feather") or name:find("pelt") or
           name:find("hide") or name:find("flower") or name:find("wheat") or name:find("cotton") or
           name:find("guam") or name:find("marrentill") or name:find("tarromin") or
           name:find("harralander") or name:find("ranarr") or name:find("irit") or
           name:find("avantoe") or name:find("kwuarm") or name:find("cadantine") or
           name:find("lantadyme") or name:find("dwarf weed") or name:find("torstol") then
            return ItemCategories.FARMING
        end

        -- F. Magic keywords
        if name:find("rune") or name:find("essence") or name:find("shard") or name:find("anima") or
           name:find("talisman") or name:find("reagent") or name:find("catalyst") or
           name:find("enchanted") or name:find("crystal") then
            return ItemCategories.MAGIC
        end
    end

    return ItemCategories.MISC
end

-- Check if an item in the player's inventory should be protected from being deposited
local function IsItemProtectedFromDeposit(item)
    if not IsValidItem(item) then return false end

    local name = GetItemName(item):lower()
    local path = ""
    local className = ""

    pcall(function()
        if item.ItemData and item.ItemData:IsValid() then
            path = item.ItemData:GetPathName():lower()
            className = GetSafeClassName(item.ItemData):lower()
        elseif item.GetClass then
            className = GetSafeClassName(item):lower()
        end
    end)

    -- 1. Protect Arrows, Bolts, Quivers, Ammo
    if Config.ProtectAmmo then
        if name:find("arrow") or name:find("bolt") or name:find("quiver") or name:find("ammo") or
           path:find("/ammo/") or path:find("item_ammo_") or path:find("arrow") or path:find("bolt") or
           className:find("ammo") or className:find("arrow") or className:find("bolt") then
            return true
        end
    end

    -- 2. Protect Runes, Rune Pouches, Essence
    if Config.ProtectRunes then
        if name:find("rune") or name:find("essence") or
           path:find("/rune/") or path:find("item_rune_") or path:find("/essence/") or
           className:find("rune") or className:find("essence") then
            return true
        end
    end

    return false
end

-- Hover Detection: Find the item currently under the player's cursor
local function GetHoveredItem()
    -- 1. Check all InventorySlotBase widgets (Main inventory slots & Chest slots)
    local okSlots, allSlots = pcall(function() return FindAllOf("InventorySlotBase") end)
    if okSlots and allSlots then
        for _, slot in ipairs(allSlots) do
            local ok, isHovered = pcall(function()
                if not slot:IsValid() or not slot:IsVisible() then return false end
                if slot.bIsMousedOver then return true end
                return slot:IsHovered()
            end)
            if ok and isHovered then
                local item = nil
                pcall(function() item = slot.ContainedItem end)
                if IsValidItem(item) then
                    return item
                end
            end
        end
    end

    -- 2. Check QuickAccessBarSlotBase (Hotbar slots)
    local okQA, qaSlots = pcall(function() return FindAllOf("QuickAccessBarSlotBase") end)
    if okQA and qaSlots then
        for _, slot in ipairs(qaSlots) do
            local ok, isHovered = pcall(function()
                return slot:IsValid() and slot:IsVisible() and slot:IsHovered()
            end)
            if ok and isHovered then
                local subSlot = nil
                pcall(function() subSlot = slot.InventorySlot end)
                if subSlot and subSlot:IsValid() then
                    local item = nil
                    pcall(function() item = subSlot.ContainedItem end)
                    if IsValidItem(item) then
                        return item
                    end
                end
            end
        end
    end

    return nil
end

-- Hover Fallback: Check if an item tooltip is currently visible on screen
local function GetHoveredTooltipItemName()
    local ok, tooltips = pcall(function() return FindAllOf("InventoryTooltip") end)
    if ok and tooltips then
        for _, tt in ipairs(tooltips) do
            local okVis, vis = pcall(function()
                return tt:IsValid() and tt:IsVisible() and tt:IsInViewport()
            end)
            if okVis and vis then
                local nameStr = nil
                pcall(function()
                    if tt.TooltipTitleTextBlock and tt.TooltipTitleTextBlock:IsValid() then
                        local txt = tt.TooltipTitleTextBlock:GetText()
                        if txt and txt.ToString then
                            nameStr = txt:ToString()
                        end
                    end
                end)
                if nameStr and nameStr ~= "" then
                    return nameStr
                end
            end
        end
    end
    return nil
end

-- Get current hover target (either an item reference or an item name)
local function GetCurrentHoverTarget()
    local item = GetHoveredItem()
    if item then
        return {
            Item = item,
            DataAddr = GetItemDataAddress(item),
            Name = GetItemName(item)
        }
    end

    local fallbackName = GetHoveredTooltipItemName()
    if fallbackName and fallbackName ~= "" then
        return {
            Item = nil,
            DataAddr = nil,
            Name = fallbackName
        }
    end

    return nil
end

-- Helper: Check if an actor is a legitimate chest or storage container
local function IsChestActor(actor)
    if not actor then return false end
    local className = GetSafeClassName(actor):lower()
    local actorName = GetSafeName(actor):lower()

    -- STRICT BLACKLIST: Never touch any crafting stations, processors, furnaces, or utility actors!
    local disallowedKeywords = {
        "furnace", "smelter", "kiln", "campfire", "fire", "range", "cook",
        "cauldron", "bench", "anvil", "wheel", "station", "crafting",
        "grinder", "sawmill", "loom", "stonecutter", "tanning", "brew",
        "pottery", "altar", "vent", "spawner", "pawn", "character", "npc",
        "enemy", "bedroll", "lodestone", "torch", "light",
        -- World loot and buried treasure chests are not part of the base
        "loot", "buried", "_world"
    }
    for _, kw in ipairs(disallowedKeywords) do
        if className:find(kw) or actorName:find(kw) then
            return false
        end
    end

    -- Allowed storage keywords
    if className:find("chest") or className:find("crate") or className:find("storage")
       or className:find("rack") or className:find("stand") or className:find("mannequin")
       or className:find("wardrobe") or className:find("coffer") or className:find("trunk")
       or className:find("shelf") or className:find("book") or className:find("desk") then
        return true
    end

    if actorName:find("chest") or actorName:find("crate") or actorName:find("storage")
       or actorName:find("rack") or actorName:find("stand") or actorName:find("mannequin")
       or actorName:find("shelf") or actorName:find("book") or actorName:find("desk") then
        return true
    end

    return false
end

-- Helper: Find all chests within SearchRadius, sorted closest first
local function FindNearbyChests(playerLoc)
    local maxRadiusSq = Config.SearchRadius * Config.SearchRadius
    local nearbyChests = {}
    local seenAddresses = {}

    local function RegisterCandidate(chestActor, chestInv, forceInclude)
        if not chestActor or not chestInv or not chestInv:IsValid() then return end
        local addr = chestActor:GetAddress()
        if seenAddresses[addr] then return end

        if not IsChestActor(chestActor) then return end

        local loc = nil
        pcall(function() loc = chestActor:K2_GetActorLocation() end)

        local distSq = 0
        local dist = 0
        if loc and playerLoc then
            local dx = loc.X - playerLoc.X
            local dy = loc.Y - playerLoc.Y
            local dz = loc.Z - playerLoc.Z
            distSq = dx * dx + dy * dy + dz * dz
            dist = math.sqrt(distSq)
        end

        if forceInclude or (loc and distSq <= maxRadiusSq) then
            seenAddresses[addr] = true
            local actorClass = GetSafeClassName(chestActor):lower()
            local preferredCat = nil
            if actorClass:find("weapon") then
                preferredCat = ItemCategories.EQUIPMENT
            elseif actorClass:find("armour") or actorClass:find("armor") or actorClass:find("rack") or actorClass:find("mannequin") or actorClass:find("stand") then
                preferredCat = ItemCategories.ARMOUR
            elseif actorClass:find("lumber") or actorClass:find("wood") then
                preferredCat = ItemCategories.WOOD
            elseif actorClass:find("book") or actorClass:find("scroll") or actorClass:find("library") or actorClass:find("desk") then
                preferredCat = ItemCategories.RECIPES
            end

            table.insert(nearbyChests, {
                Actor = chestActor,
                Inventory = chestInv,
                Distance = dist,
                PreferredCategory = preferredCat,
                ActorName = actorClass
            })
        end
    end

    -- Scan Method 0: Currently Open Chest via WorldActorInventoryUIAPI
    local okUI, uis = pcall(function() return FindAllOf("WorldActorInventoryUIAPI") end)
    if okUI and uis then
        for _, ui in ipairs(uis) do
            if ui and ui:IsValid() then
                local comp = nil
                pcall(function() comp = ui:GetInventoryComponent() end)
                if comp and comp:IsValid() then
                    local owner = nil
                    pcall(function() owner = comp:GetOwner() end)
                    if owner and IsValidWorldActor(owner) and IsChestActor(owner) then
                        RegisterCandidate(owner, comp, true)
                    end
                end
            end
        end
    end

    -- Scan Method A: Explicit Base Building Storage Actor Classes
    local chestClassesToScan = {
        "BP_BaseBuilding_Chest_C",
        "BP_BaseBuilding_Chest_Small_C",
        "BP_BaseBuilding_Crate_C",
        "BP_BaseBuilding_LumberStorage_C",
    }
    for _, clsName in ipairs(chestClassesToScan) do
        local okActors, actors = pcall(function() return FindAllOf(clsName) end)
        if okActors and actors then
            for _, actor in ipairs(actors) do
                if IsValidWorldActor(actor) and IsChestActor(actor) then
                    local inv = nil
                    pcall(function() inv = actor.BP_Components_WorldItemInventory end)
                    if not inv or not inv:IsValid() then
                        pcall(function() inv = actor.Inventory end)
                    end
                    if not inv or not inv:IsValid() then
                        pcall(function()
                            local invCls = StaticFindObject("/Script/Dominion.InventoryComponent")
                            if invCls and invCls:IsValid() then
                                inv = actor:GetComponentByClass(invCls)
                            end
                        end)
                    end
                    if inv and inv:IsValid() then
                        RegisterCandidate(actor, inv)
                    end
                end
            end
        end
    end

    -- Scan Method B: World Item Inventories
    local okComps, allComps = pcall(function()
        return FindAllOf("BP_Components_WorldItemInventory_C")
    end)
    if okComps and allComps then
        for _, comp in ipairs(allComps) do
            if comp and comp:IsValid() then
                local owner = nil
                pcall(function() owner = comp:GetOwner() end)
                if owner and IsValidWorldActor(owner) and IsChestActor(owner) then
                    RegisterCandidate(owner, comp)
                end
            end
        end
    end

    -- Scan Method C: Any InventoryComponent with a validated storage owner
    local okInvComps, invComps = pcall(function()
        return FindAllOf("InventoryComponent")
    end)
    if okInvComps and invComps then
        local PC = UEHelpers.GetPlayerController()
        local pawn = PC and PC.Pawn
        for _, comp in ipairs(invComps) do
            if comp and comp:IsValid() then
                local owner = nil
                pcall(function() owner = comp:GetOwner() end)
                if owner and owner ~= pawn and owner ~= PC and IsChestActor(owner) then
                    RegisterCandidate(owner, comp)
                end
            end
        end
    end

    -- Sort chests closest first
    table.sort(nearbyChests, function(a, b) return a.Distance < b.Distance end)
    return nearbyChests
end

-- Helper: Check if key is currently pressed down via PlayerController
-- Returns nil (unknown) if the key state cannot be read, so callers can fall back to key-repeat timing
local function IsGKeyDown(PC)
    if not PC then return nil end
    local ok, res = pcall(function()
        if not PC:IsValid() then error("invalid PC") end
        return PC:IsInputKeyDown({ KeyName = FName("G") })
    end)
    if not ok or type(res) ~= "boolean" then return nil end
    return res
end

-- Persistent mapping of Chest Address -> Assigned Category (e.g. dedicated FOOD chest, RECIPES chest)
local PersistentAssignedCategories = {}

local function AnalyzeChest(chestEntry)
    local chestInv = chestEntry.Inventory
    local chestActor = chestEntry.Actor
    local addr = tostring(chestActor:GetAddress())

    local state = {
        Entry = chestEntry,
        Actor = chestActor,
        Inventory = chestInv,
        Address = addr,
        Slots = {},           -- [slotZero] = slotInfo
        EmptySlots = {},      -- list of slotZero numbers
        CategoryCounts = {},  -- [category] = count of items
        TargetSlotsByData = {}, -- [dataAddr] = list of slotInfo with free space
        TotalItemCount = 0,
        DominantCategory = nil,
        PreferredCategory = chestEntry.PreferredCategory,
        ActorName = chestEntry.ActorName
    }

    for _, cat in pairs(ItemCategories) do
        state.CategoryCounts[cat] = 0
    end

    local slotCount = 0
    pcall(function() slotCount = chestInv.ItemSlots:GetArrayNum() end)
    state.SlotCount = slotCount

    for cIdx = 1, slotCount do
        local cSlotZero = cIdx - 1
        local cItem = nil
        pcall(function() cItem = chestInv.ItemSlots[cIdx] end)

        if IsValidItem(cItem) then
            local dataAddr = GetItemDataAddress(cItem)
            local count = 0
            pcall(function() count = cItem:GetStackSize() end)
            local freeSpace = 0
            pcall(function() freeSpace = cItem:GetStackFreeSpace() end)
            local name = GetItemName(cItem)
            local category = GetItemCategory(cItem)

            state.CategoryCounts[category] = (state.CategoryCounts[category] or 0) + 1
            state.TotalItemCount = state.TotalItemCount + 1
            state.NamesByCategory = state.NamesByCategory or {}
            state.NamesByCategory[category] = state.NamesByCategory[category] or {}
            table.insert(state.NamesByCategory[category], name)

            local slotInfo = {
                SlotZero = cSlotZero,
                Item = cItem,
                DataAddr = dataAddr,
                Name = name,
                Category = category,
                Count = count,
                FreeSpace = freeSpace
            }
            state.Slots[cSlotZero] = slotInfo

            if dataAddr and freeSpace > 0 then
                if not state.TargetSlotsByData[dataAddr] then
                    state.TargetSlotsByData[dataAddr] = {}
                end
                table.insert(state.TargetSlotsByData[dataAddr], slotInfo)
            end
        else
            table.insert(state.EmptySlots, cSlotZero)
        end
    end

    local maxCat = nil
    local maxCount = 0
    for cat, cnt in pairs(state.CategoryCounts) do
        if cnt > maxCount then
            maxCount = cnt
            maxCat = cat
        end
    end
    local persisted = PersistentAssignedCategories[addr]
    if persisted and (state.CategoryCounts[persisted] or 0) == 0 and maxCount > 0 then
        PersistentAssignedCategories[addr] = nil
        persisted = nil
    end
    state.DominantCategory = persisted or state.PreferredCategory or maxCat
    return state
end

-- Robust item transfer between chests with 3 fallback mechanisms:
-- Helper: Get Player's InventoryController
local function GetInventoryController(PC)
    local invCtrl = nil
    pcall(function()
        if PC and PC:IsValid() then
            invCtrl = PC.InventoryController
            if (not invCtrl or not invCtrl:IsValid()) and PC.GetInventoryController then
                invCtrl = PC:GetInventoryController()
            end
        end
    end)
    return invCtrl
end

-- Robust item transfer between chests with 3 fallback mechanisms:
-- 1) PC.InventoryController:MoveItemBetweenInventories
-- 2) Direct srcChest.Inventory:MoveItem
-- 3) Bounce through an empty player backpack slot (guaranteed engine authority)
local function MoveItemBetweenChests(srcChest, srcSlotZero, destChest, destSlotZero, amount, PC, playerInv)
    if not srcChest or not destChest or srcSlotZero == nil or amount <= 0 then
        return false
    end
    local movedOk = false
    local errLog = {}

    -- Method 1: Try PC.InventoryController (engine native UI controller)
    local invCtrl = GetInventoryController(PC)
    if invCtrl and invCtrl:IsValid() then
        local ok, res = pcall(function()
            if destSlotZero ~= nil then
                return invCtrl:MoveItemBetweenInventories(srcChest.Inventory, srcSlotZero, destChest.Inventory, destSlotZero)
            else
                return invCtrl:MoveItemBetweenInventoriesAnySlot(srcChest.Inventory, srcSlotZero, destChest.Inventory)
            end
        end)
        if ok and res then
            return true
        else
            table.insert(errLog, "invCtrl:" .. tostring(res))
        end
    end

    -- Method 2: Try direct chest-to-chest MoveItem
    if srcChest.Inventory and srcChest.Inventory:IsValid() and destChest.Inventory and destChest.Inventory:IsValid() then
        local ok, res = pcall(function()
            return srcChest.Inventory:MoveItem(srcSlotZero, destChest.Inventory, destSlotZero or 0, PC, amount)
        end)
        if ok and res then
            return true
        else
            table.insert(errLog, "srcMoveItem:" .. tostring(res))
        end
    end

    -- Method 3: Direct Native UObject Transfer via AddItemToSlot / AddItem + RemoveItem
    if srcChest.Inventory and srcChest.Inventory:IsValid() and destChest.Inventory and destChest.Inventory:IsValid() then
        local srcItem = nil
        pcall(function() srcItem = srcChest.Inventory.ItemSlots[srcSlotZero + 1] end)
        if not IsValidItem(srcItem) and srcChest.Slots and srcChest.Slots[srcSlotZero] then
            srcItem = srcChest.Slots[srcSlotZero].Item
        end

        if IsValidItem(srcItem) then
            local added = false

            -- 3A: Direct AddItemByDataToSlot with correct C++ signature:
            -- (ItemData, SlotIndex, Count, DurabilityPercentage, GameplayTags)
            local itemData = nil
            pcall(function() itemData = srcItem.ItemData end)
            if itemData and itemData:IsValid() then
                local durability = 1.0
                pcall(function() durability = srcItem:GetDurability() or 1.0 end)

                if destSlotZero ~= nil then
                    local okDataSlot, resDataSlot = pcall(function()
                        return destChest.Inventory:AddItemByDataToSlot(itemData, destSlotZero, amount, durability, {})
                    end)
                    if okDataSlot and resDataSlot then
                        added = true
                    else
                        -- Retry with nil if empty table was rejected
                        pcall(function()
                            if destChest.Inventory:AddItemByDataToSlot(itemData, destSlotZero, amount, durability, nil) then
                                added = true
                            end
                        end)
                        if not added then
                            table.insert(errLog, "addItemByDataToSlot:" .. tostring(resDataSlot))
                        end
                    end
                end

                -- 3B: Direct AddItemByData into any free slot
                if not added then
                    local okDataAdd, resDataAdd = pcall(function()
                        return destChest.Inventory:AddItemByData(itemData, amount, durability, {})
                    end)
                    if okDataAdd and resDataAdd then
                        added = true
                    else
                        pcall(function()
                            if destChest.Inventory:AddItemByData(itemData, amount, durability, nil) then
                                added = true
                            end
                        end)
                        if not added then
                            table.insert(errLog, "addItemByData:" .. tostring(resDataAdd))
                        end
                    end
                end
            end

            -- 3C: Fallback via direct UObject AddItemToSlot / AddItem
            if not added and destSlotZero ~= nil then
                local okSlot, resSlot = pcall(function()
                    return destChest.Inventory:AddItemToSlot(srcItem, destSlotZero)
                end)
                if okSlot and resSlot then
                    added = true
                else
                    table.insert(errLog, "addItemToSlot:" .. tostring(resSlot))
                end
            end
            if not added then
                local okAdd, resAdd = pcall(function()
                    return destChest.Inventory:AddItem(srcItem)
                end)
                if okAdd and resAdd then
                    added = true
                else
                    table.insert(errLog, "addItem:" .. tostring(resAdd))
                end
            end

            if added then
                local removed = false
                local curStack = 0
                pcall(function() curStack = srcItem:GetStackSize() end)

                -- If entire stack moved, try RemoveItem
                if amount >= curStack and curStack > 0 then
                    pcall(function()
                        removed = srcChest.Inventory:RemoveItem(srcItem)
                    end)
                end
                if not removed and itemData and itemData:IsValid() then
                    pcall(function()
                        removed = srcChest.Inventory:RemoveItemByData(itemData, amount)
                    end)
                end
                if not removed then
                    pcall(function()
                        removed = srcChest.Inventory:RemoveFromSlot(srcSlotZero, amount, PC)
                    end)
                end
                if not removed and not (amount >= curStack) then
                    pcall(function()
                        removed = srcChest.Inventory:RemoveItem(srcItem)
                    end)
                end

                if removed then
                    return true
                else
                    table.insert(errLog, "directRemoveFailed")
                    -- Rollback added item if removal failed to prevent duplication
                    if destSlotZero ~= nil then
                        pcall(function()
                            destChest.Inventory:RemoveFromSlot(destSlotZero, amount, PC)
                        end)
                    end
                    if itemData and itemData:IsValid() then
                        pcall(function()
                            destChest.Inventory:RemoveItemByData(itemData, amount)
                        end)
                    end
                end
            end
        end
    end

    -- Method 4: Bounce through player backpack slot (with temporary unblocker if backpack is full)
    if playerInv and playerInv:IsValid() then
        local emptyPlayerSlot = nil
        local hotbarCount = 0
        pcall(function() hotbarCount = playerInv.NumberOfQuickActionSlots or 8 end)
        local pSlotCount = 0
        pcall(function() pSlotCount = playerInv.ItemSlots:GetArrayNum() end)

        for pIdx = hotbarCount + 1, pSlotCount do
            local pSlotZero = pIdx - 1
            local pItem = nil
            pcall(function() pItem = playerInv.ItemSlots[pIdx] end)
            if not IsValidItem(pItem) then
                emptyPlayerSlot = pSlotZero
                break
            end
        end

        local borrowedSlot = nil
        -- If player backpack is 100% full, temporarily stash 1 non-combat backpack item into destSlotZero
        if emptyPlayerSlot == nil and destSlotZero ~= nil then
            for pIdx = hotbarCount + 1, pSlotCount do
                local pSlotZero = pIdx - 1
                local pItem = nil
                pcall(function() pItem = playerInv.ItemSlots[pIdx] end)
                if IsValidItem(pItem) and not IsItemProtectedFromDeposit(pItem) then
                    local pCount = 1
                    pcall(function() pCount = pItem:GetStackSize() end)
                    local stashed = false
                    pcall(function()
                        stashed = playerInv:MoveItem(pSlotZero, destChest.Inventory, destSlotZero, PC, pCount)
                    end)
                    if stashed then
                        borrowedSlot = { PlayerSlot = pSlotZero, Count = pCount }
                        emptyPlayerSlot = pSlotZero
                        break
                    end
                end
            end
        end

        if emptyPlayerSlot ~= nil then
            local toPlayerOk = false
            pcall(function()
                toPlayerOk = srcChest.Inventory:MoveItem(srcSlotZero, playerInv, emptyPlayerSlot, PC, amount)
            end)
            if toPlayerOk then
                pcall(function()
                    movedOk = playerInv:MoveItem(emptyPlayerSlot, destChest.Inventory, destSlotZero or 0, PC, amount)
                end)
                if not movedOk then
                    pcall(function()
                        playerInv:MoveItem(emptyPlayerSlot, srcChest.Inventory, srcSlotZero, PC, amount)
                    end)
                end
            end

            -- If we borrowed a slot by stashing an item into destChest, restore the player's original item!
            if borrowedSlot then
                pcall(function()
                    playerInv:MoveItem(emptyPlayerSlot, destChest.Inventory, destSlotZero, PC, borrowedSlot.Count)
                end)
            end

            if movedOk then
                return true
            end
        end
    end

    if Config.DebugLog then
        Log(string.format(">>> MoveItemBetweenChests FAILED: amount=%d, srcSlot=%s, destSlot=%s, errors=[%s]",
            amount, tostring(srcSlotZero), tostring(destSlotZero), table.concat(errLog, ", ")))
    end

    return false
end

-- =========================================================================
-- CHEST CATEGORY SORTING (moves whole stacks; never clears, creates or drops items)
-- =========================================================================
-- Helper: Read one slot of an inventory (slotZero is 0-based)
local function ReadSlot(inv, slotZero)
    local item = nil
    pcall(function() item = inv.ItemSlots[slotZero + 1] end)
    if not IsValidItem(item) then return nil, 0 end
    local count = 0
    pcall(function() count = item:GetStackSize() end)
    return item, count or 0
end

-- Helper: Only real chests/crates get the 48-slot upgrade and chest mesh (never armour stands, racks or lumber storage)
local function IsUpgradeableChest(state)
    local n = (state.ActorName or ""):lower()
    if n:find("rack") or n:find("stand") or n:find("mannequin") or n:find("lumber") or n:find("armour") or n:find("armor") then
        return false
    end
    return n:find("chest") ~= nil or n:find("crate") ~= nil
end

-- Helper: Find a free player backpack slot (hotbar excluded) to carry items between chests
local function FindFreeBackpackSlot(playerInv)
    local hotbarCount = 8
    pcall(function() hotbarCount = playerInv.NumberOfQuickActionSlots or 8 end)
    local slotCount = 0
    pcall(function() slotCount = playerInv.ItemSlots:GetArrayNum() end)
    for pIdx = hotbarCount + 1, slotCount do
        if not ReadSlot(playerInv, pIdx - 1) then return pIdx - 1 end
    end
    return nil
end

local function CountFreeBackpackSlots(playerInv)
    local hotbarCount = 8
    pcall(function() hotbarCount = playerInv.NumberOfQuickActionSlots or 8 end)
    local slotCount = 0
    pcall(function() slotCount = playerInv.ItemSlots:GetArrayNum() end)
    local free = 0
    for pIdx = hotbarCount + 1, slotCount do
        if not ReadSlot(playerInv, pIdx - 1) then free = free + 1 end
    end
    return free
end

-- Move one whole stack from a chest slot into an EMPTY slot of another chest.
-- Uses only the same MoveItem calls as normal deposit (chest -> backpack -> chest) and targets
-- known-empty slots, so nothing is created, deleted or dropped. Every step is checked by reading
-- the slots back. If the second hop fails, the stack goes back where it came from, and if even that
-- fails it stays in your backpack.
local function CarryStack(src, srcSlot, dest, destSlot, carrySlot, PC, playerInv)
    local srcItem, srcCount = ReadSlot(src.Inventory, srcSlot)
    if not srcItem or srcCount <= 0 then return false end
    local destItem = ReadSlot(dest.Inventory, destSlot)
    local dataAddr = GetItemDataAddress(srcItem)
    local moveCount = srcCount
    if destItem then
        if GetItemDataAddress(destItem) ~= dataAddr then return false end
        local freeSpace = 0
        pcall(function() freeSpace = destItem:GetStackFreeSpace() end)
        if freeSpace <= 0 then return false end
        moveCount = math.min(srcCount, freeSpace)
    end

    -- Direct chest-to-chest transfer attempt first:
    local okDirect = false
    pcall(function()
        okDirect = src.Inventory:MoveItem(srcSlot, dest.Inventory, destSlot, PC, moveCount)
    end)
    local _, remainingSrc = ReadSlot(src.Inventory, srcSlot)
    if okDirect and (not remainingSrc or remainingSrc < srcCount) then
        return true
    end

    if not carrySlot or ReadSlot(playerInv, carrySlot) then return false end

    -- Hop 1: chest -> backpack carry slot
    pcall(function() src.Inventory:MoveItem(srcSlot, playerInv, carrySlot, PC, moveCount) end)
    local carried, carriedCount = ReadSlot(playerInv, carrySlot)
    if not carried or GetItemDataAddress(carried) ~= dataAddr then
        return false -- nothing moved
    end

    -- Hop 2: backpack carry slot -> destination chest's slot
    pcall(function() playerInv:MoveItem(carrySlot, dest.Inventory, destSlot, PC, carriedCount) end)
    if not ReadSlot(playerInv, carrySlot) then
        return true
    end

    -- Hop 2 failed: put it back where it came from
    local _, leftCount = ReadSlot(playerInv, carrySlot)
    pcall(function() playerInv:MoveItem(carrySlot, src.Inventory, srcSlot, PC, leftCount) end)
    if ReadSlot(playerInv, carrySlot) then
        Log(string.format("    Could not return '%s' to its chest; it is safe in your backpack.", GetItemName(carried)))
    end
    return false
end

local function ReorganizeNearbyChests(chestStates, PC, playerInv)
    if not chestStates or #chestStates < 1 then return 0 end
    if not playerInv or not playerInv:IsValid() then return 0 end

    Log(string.format(">>> Sorting %d nearby container(s) by category...", #chestStates))

    -- 1. UPGRADE REAL CHESTS TO HIGHEST TIER (48 SLOTS)
    -- Off by default: rewriting slot counts and swapping meshes in memory crashed the game (UE4SS null read)
    if Config.UpgradeChestsTo48Slots then
        local largeMesh = nil
        for _, state in ipairs(chestStates) do
            if IsUpgradeableChest(state) and state.SlotCount >= 48 and state.Actor and state.Actor.Mesh then
                pcall(function() largeMesh = state.Actor.Mesh.StaticMesh end)
                if largeMesh and largeMesh:IsValid() then break end
                largeMesh = nil
            end
        end
        if not largeMesh then
            pcall(function()
                largeMesh = StaticFindObject("/Game/Art/Env/Base_Building/Furniture/Cosiness/Chest/SM_Storage_Chest_01v2.SM_Storage_Chest_01v2")
            end)
            if largeMesh and not largeMesh:IsValid() then largeMesh = nil end
        end
        for _, state in ipairs(chestStates) do
            if IsUpgradeableChest(state) then
                pcall(function()
                    if state.Inventory and state.Inventory:IsValid() and (state.Inventory.MaxSlotCount or 0) < 48 then
                        state.Inventory.MaxSlotCount = 48
                    end
                    if largeMesh and state.Actor and state.Actor.Mesh and state.Actor.Mesh:IsValid() then
                        state.Actor.Mesh:SetStaticMesh(largeMesh)
                    end
                end)
            end
        end
    end

    -- 2. COUNT STACKS PER CATEGORY (read only; nothing is moved yet)
    local categoryStacks = {}
    for _, state in ipairs(chestStates) do
        for cat, cnt in pairs(state.CategoryCounts or {}) do
            categoryStacks[cat] = (categoryStacks[cat] or 0) + cnt
        end
    end

    -- 3. ASSIGN DEDICATED CONTAINERS TO CATEGORIES
    local assignedChestsByCategory = {}
    for _, cat in pairs(ItemCategories) do assignedChestsByCategory[cat] = {} end
    local function Claim(state, cat)
        state.AssignedCategory = cat
        table.insert(assignedChestsByCategory[cat], state)
        if state.Address then
            PersistentAssignedCategories[state.Address] = cat
        end
    end

    -- Priority A: Containers built for one category (armour stands -> ARMOUR, weapon racks -> EQUIPMENT, lumber -> WOOD, bookshelves -> RECIPES)
    for _, state in ipairs(chestStates) do
        if state.PreferredCategory then Claim(state, state.PreferredCategory) end
    end

    -- Priority A2: Containers with established persistent assignments from prior passes
    for _, state in ipairs(chestStates) do
        local persisted = state.Address and PersistentAssignedCategories[state.Address]
        if persisted and not state.AssignedCategory and #assignedChestsByCategory[persisted] == 0 then
            Claim(state, persisted)
        end
    end

    -- Priority B: Sticky. A chest keeps the category it already holds most of,
    -- so the food chest stays the food chest every time G is pressed.
    local pairsByCount = {}
    for idx, state in ipairs(chestStates) do
        if not state.AssignedCategory then
            for cat, cnt in pairs(state.CategoryCounts or {}) do
                if cnt > 0 then
                    table.insert(pairsByCount, { State = state, Category = cat, Count = cnt, Index = idx })
                end
            end
        end
    end
    table.sort(pairsByCount, function(a, b)
        if a.Count ~= b.Count then return a.Count > b.Count end
        if a.Index ~= b.Index then return a.Index < b.Index end
        return a.Category < b.Category
    end)
    for _, p in ipairs(pairsByCount) do
        if not p.State.AssignedCategory and #assignedChestsByCategory[p.Category] == 0 then
            Claim(p.State, p.Category)
        end
    end

    -- Priority C: Categories still without a home get the nearest empty-handed chest, largest first
    local sortedCats = {}
    for cat, stacks in pairs(categoryStacks) do
        if stacks > 0 then table.insert(sortedCats, { Category = cat, Stacks = stacks }) end
    end
    table.sort(sortedCats, function(a, b)
        if a.Stacks ~= b.Stacks then return a.Stacks > b.Stacks end
        return a.Category < b.Category
    end)
    local function NextFreeContainer()
        for _, state in ipairs(chestStates) do
            if not state.AssignedCategory and not state.PreferredCategory then return state end
        end
        return nil
    end
    for _, cInfo in ipairs(sortedCats) do
        if #assignedChestsByCategory[cInfo.Category] == 0 then
            local free = NextFreeContainer()
            if free then Claim(free, cInfo.Category) end
        end
    end
    -- Categories that need more room than their chests have get extra chests
    for _, cInfo in ipairs(sortedCats) do
        local cat = cInfo.Category
        local capacity = 0
        for _, st in ipairs(assignedChestsByCategory[cat]) do capacity = capacity + math.max(st.SlotCount or 0, 1) end
        while capacity < cInfo.Stacks do
            local free = NextFreeContainer()
            if not free then break end
            Claim(free, cat)
            capacity = capacity + math.max(free.SlotCount or 0, 1)
        end
    end

    local homeless = {}
    for _, cInfo in ipairs(sortedCats) do
        if #assignedChestsByCategory[cInfo.Category] == 0 then table.insert(homeless, cInfo.Category) end
    end
    if #homeless > 0 then
        Log(string.format("    Not enough chests for one per category. Build %d more to separate: %s (those stay where they are for now).",
            #homeless, table.concat(homeless, ", ")))
    end
    if Config.DebugLog then
        for idx, state in ipairs(chestStates) do
            Log(string.format("    Container #%d (%.1fm, %s) -> %s", idx, (state.Entry and state.Entry.Distance or 0) / 100.0,
                tostring(state.ActorName), tostring(state.AssignedCategory or "spare")))
        end
    end

    -- 4. CARRY MISPLACED STACKS INTO THEIR CATEGORY'S CHESTS
    -- Only items whose category has a home are moved; anything else stays exactly where it is.
    local carrySlot = FindFreeBackpackSlot(playerInv)
    if not carrySlot then
        Log("    Sorting skipped: free up one backpack slot so QuickStack can carry items between chests.")
        return 0
    end

    local function FreeSlotIn(state, item)
        local slotCount = 0
        pcall(function() slotCount = state.Inventory.ItemSlots:GetArrayNum() end)
        -- First: look for an existing partial stack of the same item to merge into!
        if item then
            local dataAddr = GetItemDataAddress(item)
            if dataAddr then
                for s = 0, slotCount - 1 do
                    local destItem = ReadSlot(state.Inventory, s)
                    if destItem and GetItemDataAddress(destItem) == dataAddr then
                        local freeSpace = 0
                        pcall(function() freeSpace = destItem:GetStackFreeSpace() end)
                        if freeSpace > 0 then
                            return s
                        end
                    end
                end
            end
        end
        -- Second: look for an empty slot
        for s = 0, slotCount - 1 do
            if not ReadSlot(state.Inventory, s) then return s end
        end
        return nil
    end

    local movedStacks = 0
    local stuckStacks = 0
    for _, src in ipairs(chestStates) do
        local slotCount = 0
        pcall(function() slotCount = src.Inventory.ItemSlots:GetArrayNum() end)
        for s = 0, slotCount - 1 do
            local item = ReadSlot(src.Inventory, s)
            if item then
                local cat = GetItemCategory(item)
                local targets = assignedChestsByCategory[cat] or {}
                if #targets > 0 and src.AssignedCategory ~= cat then
                    local moved = false
                    for _, dest in ipairs(targets) do
                        local destSlot = FreeSlotIn(dest, item)
                        if destSlot then
                            moved = CarryStack(src, s, dest, destSlot, carrySlot, PC, playerInv)
                            if moved then break end
                        end
                        -- The carry slot may be occupied if a hop failed; find another
                        if ReadSlot(playerInv, carrySlot) then
                            carrySlot = FindFreeBackpackSlot(playerInv)
                            if not carrySlot then break end
                        end
                    end
                    if moved then
                        movedStacks = movedStacks + 1
                        if Config.DebugLog then
                            Log(string.format("    Moved '%s' [%s] out of the %s chest.", GetItemName(item), cat,
                                tostring(src.AssignedCategory or "spare")))
                        end
                    else
                        stuckStacks = stuckStacks + 1
                    end
                    if not carrySlot then break end
                end
            end
        end
        if not carrySlot then
            Log("    Sorting stopped early: no free backpack slot left to carry items.")
            break
        end
    end

    Log(string.format(">>> Chest sort COMPLETE: moved %d stack(s) into their category chests.%s", movedStacks,
        stuckStacks > 0 and string.format(" %d stack(s) stayed put (target chests full or the move was refused).", stuckStacks) or ""))
    return movedStacks
end

-- =========================================================================
-- EXECUTE QUICK STACK (Deposit matching & categorized items to chests)
-- =========================================================================
local function ExecuteQuickStack(depositOnly)
    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) then
        Log("QuickStack failed: Local PlayerController not found or invalid.")
        return
    end

    local pawn = PC.Pawn
    if not IsValidWorldActor(pawn) then
        Log("QuickStack failed: Player character pawn not spawned.")
        return
    end

    local playerLoc = nil
    pcall(function() playerLoc = pawn:K2_GetActorLocation() end)
    if not playerLoc then
        Log("QuickStack failed: Unable to get player location.")
        return
    end

    local playerInv = PC.BP_Components_Inventory
    if not playerInv or not playerInv:IsValid() then
        Log("QuickStack failed: Player inventory component (BP_Components_Inventory) not found.")
        return
    end

    local nearbyChests = FindNearbyChests(playerLoc)
    if #nearbyChests == 0 then
        Log(string.format("QuickStack: No chests found within %.1f meters.", Config.SearchRadius / 100.0))
        return false
    end

    if Config.DebugLog then
        Log(string.format("Found %d nearby chest(s). Starting quick stack...", #nearbyChests))
    end

    -- 1. Analyze nearby chests
    local chestStates = {}
    for _, chestEntry in ipairs(nearbyChests) do
        table.insert(chestStates, AnalyzeChest(chestEntry))
    end

    -- 2. Organize misplaced items between chests by category & Upgrade to 48 slots
    if Config.OrganizeNearbyChests and not depositOnly and #chestStates >= 1 then
        local reorganizedCount = ReorganizeNearbyChests(chestStates, PC, playerInv)
        if reorganizedCount > 0 and Config.DebugLog then
            Log(string.format("Organized %d misplaced item(s) between chests into matching categories.", reorganizedCount))
        end
        -- Re-analyze to have fresh slot tracking after reorganization
        chestStates = {}
        for _, chestEntry in ipairs(nearbyChests) do
            table.insert(chestStates, AnalyzeChest(chestEntry))
        end
        -- Report any chest still holding items from another category, so mix-ups are visible in the log
        if Config.DebugLog then
            for _, st in ipairs(chestStates) do
                local home = st.DominantCategory
                if home then
                    for cat, names in pairs(st.NamesByCategory or {}) do
                        if cat ~= home then
                            Log(string.format("    Mixed: %s chest still holds %d %s item(s): %s", home, #names, cat,
                                table.concat(names, ", ", 1, math.min(#names, 8))))
                        end
                    end
                end
            end
        end
    end

    local hotbarCount = 0
    if Config.ProtectHotbar then
        pcall(function() hotbarCount = playerInv.NumberOfQuickActionSlots end)
        if not hotbarCount or hotbarCount < 0 then hotbarCount = 8 end
    end

    local playerSlotCount = 0
    pcall(function() playerSlotCount = playerInv.ItemSlots:GetArrayNum() end)
    if playerSlotCount <= 0 then
        Log("Player inventory has 0 slots.")
        return true
    end

    local totalItemsMoved = 0
    local depositedItemsSummary = {}
    local affectedChests = {}

    -- 3. Deposit items from player inventory into matching chests
    for pIdx = hotbarCount + 1, playerSlotCount do
        local pSlotZero = pIdx - 1
        local pItem = nil
        pcall(function() pItem = playerInv.ItemSlots[pIdx] end)

        if IsValidItem(pItem) then
            -- Protect combat ammunition (arrows, bolts) and magic runes from being deposited
            if IsItemProtectedFromDeposit(pItem) then
                if Config.DebugLog then
                    Log(string.format("Protected combat item: Kept '%s' in inventory.", GetItemName(pItem)))
                end
            else
                local pDataAddr = GetItemDataAddress(pItem)
                local pCount = 0
                pcall(function() pCount = pItem:GetStackSize() end)

                if pDataAddr and pCount > 0 then
                    local itemName = GetItemName(pItem)
                    local itemCat = GetItemCategory(pItem)

                    -- Find all chests dedicated to this category
                    local matchingChests = {}
                    for _, chest in ipairs(chestStates) do
                        if chest.DominantCategory == itemCat then
                            table.insert(matchingChests, chest)
                        end
                    end
                    table.sort(matchingChests, function(a, b)
                        return (a.CategoryCounts[itemCat] or 0) > (b.CategoryCounts[itemCat] or 0)
                    end)

                    -- Pass 1: Top off existing non-full stacks IN MATCHING CATEGORY CHESTS ONLY
                    for _, chest in ipairs(matchingChests) do
                        if pCount <= 0 then break end
                        local targets = chest.TargetSlotsByData[pDataAddr]
                        if targets then
                            for _, target in ipairs(targets) do
                                if pCount <= 0 then break end
                                if target.FreeSpace > 0 then
                                    local moveAmount = math.min(pCount, target.FreeSpace)
                                    local movedOk = false
                                    pcall(function()
                                        movedOk = playerInv:MoveItem(pSlotZero, chest.Inventory, target.SlotZero, PC, moveAmount)
                                    end)

                                    if movedOk then
                                        pCount = pCount - moveAmount
                                        target.FreeSpace = target.FreeSpace - moveAmount
                                        totalItemsMoved = totalItemsMoved + moveAmount
                                        depositedItemsSummary[itemName] = (depositedItemsSummary[itemName] or 0) + moveAmount
                                        affectedChests[chest.Address] = true

                                        if Config.DebugLog then
                                            Log(string.format("Stacked %dx '%s' into dedicated [%s] chest slot %d.", moveAmount, itemName, itemCat, target.SlotZero))
                                        end
                                    end
                                end
                            end
                        end
                    end

                    -- Pass 2: If item still has count > 0, deposit into empty slots of dedicated Category Chests
                    if pCount > 0 and Config.SortSimilarIntoChests then
                        for _, chest in ipairs(matchingChests) do
                            if pCount <= 0 then break end
                            while pCount > 0 and #chest.EmptySlots > 0 do
                                local emptySlotZero = table.remove(chest.EmptySlots, 1)
                                local moveAmount = pCount
                                local movedOk = false
                                pcall(function()
                                    movedOk = playerInv:MoveItem(pSlotZero, chest.Inventory, emptySlotZero, PC, moveAmount)
                                end)

                                if movedOk then
                                    totalItemsMoved = totalItemsMoved + moveAmount
                                    depositedItemsSummary[itemName] = (depositedItemsSummary[itemName] or 0) + moveAmount
                                    affectedChests[chest.Address] = true
                                    pCount = 0

                                    chest.CategoryCounts[itemCat] = (chest.CategoryCounts[itemCat] or 0) + 1
                                    chest.TotalItemCount = chest.TotalItemCount + 1

                                    if Config.DebugLog then
                                        Log(string.format("Sorted %dx '%s' into dedicated [%s] chest slot %d.", moveAmount, itemName, itemCat, emptySlotZero))
                                    end
                                else
                                    table.insert(chest.EmptySlots, 1, emptySlotZero)
                                    break
                                end
                            end
                        end
                    end

                    -- Pass 3: If no chest has this category yet, claim an empty chest for this category!
                    if pCount > 0 and Config.SortSimilarIntoChests and #matchingChests == 0 then
                        for _, chest in ipairs(chestStates) do
                            if pCount <= 0 then break end
                            if chest.TotalItemCount == 0 and #chest.EmptySlots > 0 then
                                local emptySlotZero = table.remove(chest.EmptySlots, 1)
                                local moveAmount = pCount
                                local movedOk = false
                                pcall(function()
                                    movedOk = playerInv:MoveItem(pSlotZero, chest.Inventory, emptySlotZero, PC, moveAmount)
                                end)

                                if movedOk then
                                    totalItemsMoved = totalItemsMoved + moveAmount
                                    depositedItemsSummary[itemName] = (depositedItemsSummary[itemName] or 0) + moveAmount
                                    affectedChests[chest.Address] = true
                                    pCount = 0

                                    chest.TotalItemCount = 1
                                    chest.DominantCategory = itemCat
                                    chest.CategoryCounts[itemCat] = 1
                                    PersistentAssignedCategories[chest.Address] = itemCat
                                    table.insert(matchingChests, chest)

                                    if Config.DebugLog then
                                        Log(string.format("Assigned new [%s] chest! Placed %dx '%s' into slot %d.", itemCat, moveAmount, itemName, emptySlotZero))
                                    end
                                else
                                    table.insert(chest.EmptySlots, 1, emptySlotZero)
                                end
                            end
                        end
                    end

                    -- Pass 3b: Category has no chest at all -> Only MISC chest or unassigned/empty chest!
                    -- Dedicated category chests (FOOD, WOOD, MINING, FARMING, RECIPES, EQUIPMENT, MAGIC, ARMOUR) are NEVER contaminated!
                    if pCount > 0 and Config.HomelessItemsToMisc and #matchingChests == 0 then
                        local fallbacks = {}
                        for _, chest in ipairs(chestStates) do
                            if chest.DominantCategory == ItemCategories.MISC then table.insert(fallbacks, chest) end
                        end
                        for _, chest in ipairs(chestStates) do
                            if (chest.DominantCategory == nil or chest.TotalItemCount == 0) and not chest.PreferredCategory then
                                table.insert(fallbacks, chest)
                            end
                        end
                        for _, chest in ipairs(fallbacks) do
                            if pCount <= 0 then break end
                            while pCount > 0 and #chest.EmptySlots > 0 do
                                local emptySlotZero = table.remove(chest.EmptySlots, 1)
                                local moveAmount = pCount
                                local movedOk = false
                                pcall(function()
                                    movedOk = playerInv:MoveItem(pSlotZero, chest.Inventory, emptySlotZero, PC, moveAmount)
                                end)

                                if movedOk then
                                    totalItemsMoved = totalItemsMoved + moveAmount
                                    depositedItemsSummary[itemName] = (depositedItemsSummary[itemName] or 0) + moveAmount
                                    affectedChests[chest.Address] = true
                                    pCount = 0

                                    if Config.DebugLog then
                                        Log(string.format("No [%s] chest yet: stored %dx '%s' in [%s] chest slot %d.", itemCat, moveAmount, itemName,
                                            tostring(chest.DominantCategory or "empty"), emptySlotZero))
                                    end
                                else
                                    table.insert(chest.EmptySlots, 1, emptySlotZero)
                                    break
                                end
                            end
                        end
                    end

                    -- Pass 4: Fallback overflow into any chest with an empty slot (only if explicitly enabled in Config)
                    if pCount > 0 and Config.OverflowWhenCategoryFull then
                        for _, chest in ipairs(chestStates) do
                            if pCount <= 0 then break end
                            while pCount > 0 and #chest.EmptySlots > 0 do
                                local emptySlotZero = table.remove(chest.EmptySlots, 1)
                                local moveAmount = pCount
                                local movedOk = false
                                pcall(function()
                                    movedOk = playerInv:MoveItem(pSlotZero, chest.Inventory, emptySlotZero, PC, moveAmount)
                                end)

                                if movedOk then
                                    totalItemsMoved = totalItemsMoved + moveAmount
                                    depositedItemsSummary[itemName] = (depositedItemsSummary[itemName] or 0) + moveAmount
                                    affectedChests[chest.Address] = true
                                    pCount = 0

                                    if Config.DebugLog then
                                        Log(string.format("Overflowed %dx '%s' into chest slot %d.", moveAmount, itemName, emptySlotZero))
                                    end
                                else
                                    table.insert(chest.EmptySlots, 1, emptySlotZero)
                                    break
                                end
                            end
                        end
                    end

                    if pCount > 0 and not Config.OverflowWhenCategoryFull and Config.DebugLog then
                        Log(string.format("[%s] chest(s) full! Kept %dx '%s' in inventory.", itemCat, pCount, itemName))
                    end
                end
            end
        end
    end

    if totalItemsMoved > 0 then
        local chestCount = 0
        for _ in pairs(affectedChests) do chestCount = chestCount + 1 end

        local breakdown = {}
        for name, count in pairs(depositedItemsSummary) do
            table.insert(breakdown, string.format("%dx %s", count, name))
        end

        Log(string.format(">>> SUCCESS: Quick-stacked %d item(s) into %d chest(s): %s",
            totalItemsMoved, chestCount, table.concat(breakdown, ", ")))
    else
        Log("No matching items found in nearby chests to stack.")
    end
    return true
end

-- =========================================================================
-- SHARED: store a stack into the best category chest nearby
-- =========================================================================
local function StoreIntoCategoryChest(itemData, count, durability, itemName, category, nearbyChests)
    local stored = 0
    local ranked = {}
    for _, ch in ipairs(nearbyChests) do
        local st = AnalyzeChest(ch)
        local score = (st.DominantCategory == category and 100 or 0) + (st.CategoryCounts[category] or 0)
        if st.TotalItemCount == 0 then score = 50 end
        -- Never overflow into another category's chest.
        if st.DominantCategory == category or st.TotalItemCount == 0 or Config.OverflowWhenCategoryFull then
            table.insert(ranked, { Chest = ch, Score = score })
        end
    end
    table.sort(ranked, function(a, b) return a.Score > b.Score end)
    for _, cand in ipairs(ranked) do
        if stored >= count then break end
        local inv = cand.Chest.Inventory
        local space = 0
        pcall(function() space = inv:GetSpaceAvailableForItemByData(itemData) end)
        if space > 0 then
            local toAdd = math.min(count - stored, space)
            local ok = false
            pcall(function() ok = inv:AddItemByData(itemData, toAdd, durability or 1.0, {}) end)
            if ok then stored = stored + toAdd end
        end
    end
    if stored > 0 and Config.DebugLog then
        Log(string.format("Stored %dx '%s' into [%s] chest.", stored, itemName, category))
    end
    return stored
end

local function PlayerContext()
    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) or not IsValidWorldActor(PC.Pawn) then return nil end
    local loc = nil
    pcall(function() loc = PC.Pawn:K2_GetActorLocation() end)
    if not loc then return nil end
    return PC, PC.Pawn, loc
end

local function DistSq(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

-- =========================================================================
-- FETCH INGREDIENTS FOR THE OPEN CRAFTING STATION (Alt + G)
-- =========================================================================
-- Open a furnace/anvil/range etc. and press Alt+G: every item the station's
-- inventory will accept is pulled from nearby chests into your backpack
-- (one stack of each by default). Hovering an item instead pulls that item.
local StationIngredientHints = {
    -- Used only when the station accepts "anything" (no item filter found).
    { Keys = { "furnace", "smelter" }, Items = { "ore", "coal" } },
    { Keys = { "anvil", "smith" }, Items = { "bar" } },
    { Keys = { "range", "cook", "campfire", "fire" }, Items = { "raw" } },
    { Keys = { "sawmill", "carpent", "bench" }, Items = { "log", "plank" } },
    { Keys = { "loom", "spinning", "wheel" }, Items = { "flax", "wool", "thread", "fibre", "fiber" } },
    { Keys = { "tanning", "tanner" }, Items = { "hide", "pelt", "leather" } },
    { Keys = { "kiln", "pottery" }, Items = { "clay" } },
    { Keys = { "brew", "cauldron", "alch", "herb" }, Items = { "herb", "vial", "potion" } },
}

-- Station classes (from the object dump): processing stations (furnace, smelter,
-- tanner, spinning wheel...) carry a ProcessingStationComponent whose open menu is
-- a ProcessingStationUIAPI; crafting benches carry a CraftingStationComponent whose
-- open menu is the CraftingUIAPI (CurrentStation / CurrentCraftRecipe).
local StationOpenRadius = 800.0   -- an open station menu belongs to a station this close
local StationFallbackRadius = 600.0

local function DataSet(arr)
    local set, n = {}, 0
    pcall(function()
        local count = arr:GetArrayNum()
        for i = 1, count do
            local d = arr[i]
            if d and d:IsValid() then set[d:GetAddress()] = true; n = n + 1 end
        end
    end)
    return set, n
end

local function RecipeIngredientSet(recipe)
    local set, n = {}, 0
    pcall(function()
        local arr = recipe.ItemsConsumed
        local count = arr:GetArrayNum()
        for i = 1, count do
            local d = arr[i].ItemData
            if d and d:IsValid() then set[d:GetAddress()] = true; n = n + 1 end
        end
    end)
    return set, n
end

local function ComponentNear(comp, playerLoc, radius)
    local owner, dsq = nil, math.huge
    pcall(function()
        owner = comp:GetOwner()
        local loc = owner:K2_GetActorLocation()
        local dx, dy, dz = loc.X - playerLoc.X, loc.Y - playerLoc.Y, loc.Z - playerLoc.Z
        dsq = dx * dx + dy * dy + dz * dz
    end)
    if owner and IsValidWorldActor(owner) and dsq <= radius * radius then return owner, dsq end
    return nil
end

-- Item types currently sitting in an inventory component, as { [dataAddr] = name }.
local function InventoryDataSet(inv)
    local set, n = {}, 0
    pcall(function()
        local count = inv.ItemSlots:GetArrayNum()
        for i = 1, count do
            local item = inv.ItemSlots[i]
            local addr = GetItemDataAddress(item)
            if addr and not set[addr] then set[addr] = GetItemName(item); n = n + 1 end
        end
    end)
    return set, n
end

local function ProcessingStation(comp, owner)
    local resources, n = DataSet(comp.AcceptedResources)
    local fuels, nf = DataSet(comp.AcceptedFuelsIncludingRecipeOverrides)
    local accepted = {}
    for addr in pairs(resources) do accepted[addr] = true end
    for addr in pairs(fuels) do accepted[addr] = true end
    n = n + nf
    local inv, fuel = nil, nil
    pcall(function() inv = comp.Resources end)
    pcall(function() fuel = comp.Fuel end)
    -- What the player already put in the ingredient and fuel slots: that is the
    -- selection Station Fetch tops up.
    local loaded, loadedCount = {}, 0
    for _, source in ipairs({ inv, fuel }) do
        if source and source:IsValid() then
            local set, c = InventoryDataSet(source)
            for addr, name in pairs(set) do
                if not loaded[addr] then loaded[addr] = name; loadedCount = loadedCount + 1 end
            end
        end
    end
    return { Actor = owner, Inventory = inv, ClassName = GetSafeClassName(owner),
             Accepted = n > 0 and accepted or nil, Processing = true,
             Resources = resources, Fuels = fuels,
             Loaded = loadedCount > 0 and loaded or nil }
end

local function FindOpenStation(PC, playerLoc)
    -- 1. An open processing-station menu.
    for _, ui in ipairs(FindAllOf("ProcessingStationUIAPI") or {}) do
        local comp = nil
        pcall(function() comp = ui.ProcessingStationComponent end)
        if comp and comp:IsValid() then
            local owner = ComponentNear(comp, playerLoc, StationOpenRadius)
            if owner then return ProcessingStation(comp, owner), "processing menu" end
        end
    end
    -- 2. An open crafting-bench menu: fetch the selected recipe's ingredients.
    for _, ui in ipairs(FindAllOf("CraftingUIAPI") or {}) do
        local comp, recipe = nil, nil
        pcall(function() comp = ui.CurrentStation end)
        pcall(function() recipe = ui.CurrentCraftRecipe end)
        if comp and comp:IsValid() then
            local owner = ComponentNear(comp, playerLoc, StationOpenRadius)
            if owner then
                local accepted, n = nil, 0
                if recipe and recipe:IsValid() then accepted, n = RecipeIngredientSet(recipe) end
                return { Actor = owner, Inventory = nil, ClassName = GetSafeClassName(owner),
                         Accepted = n > 0 and accepted or nil, Crafting = true }, "crafting menu"
            end
        end
    end
    -- 3. Fallback: the nearest processing station within reach (only without the
    -- picker/dialog: with them, no open station menu means the Nearby Storage dialog).
    if Config.StationFetchPicker then return nil end
    local best, bestD = nil, math.huge
    for _, comp in ipairs(FindAllOf("ProcessingStationComponent") or {}) do
        local owner, dsq = ComponentNear(comp, playerLoc, StationFallbackRadius)
        if owner and dsq < bestD then best, bestD = { Comp = comp, Owner = owner }, dsq end
    end
    if best then return ProcessingStation(best.Comp, best.Owner), "nearest station" end
    return nil
end

local function MaxStackOf(itemData)
    local maxStack = 0
    pcall(function()
        if itemData.GetMaxStackSize then maxStack = itemData:GetMaxStackSize()
        elseif itemData.MaxStackSize then maxStack = itemData.MaxStackSize end
    end)
    if not maxStack or maxStack <= 0 then maxStack = 20 end
    return maxStack
end

local ExecuteQuickPull -- defined below (forward-declared by the station fetch)

-- =========================================================================
-- STATION FETCH PICKER (clickable list of what the open station can use)
-- =========================================================================
-- Alt+G at an open station shows one game-style button per item type in nearby
-- chests that the station accepts (ingredients and fuel), with the count.
-- Clicking one pulls a stack of it into the backpack. Alt+G again, or closing
-- the station menu, hides the list. Same widget + click hook as ModMenu.
local PICKER_BUTTON = "/Game/UI/Common/WBP_DomAllCapsButton.WBP_DomAllCapsButton_C"
local Picker = { Buttons = {}, Rows = {}, Entries = {}, Page = 1, Visible = false,
                 Station = nil, Close = nil, More = nil }

local function PickerValid(w)
    if not w then return false end
    local ok, res = pcall(function() return w:IsValid() and w:GetAddress() ~= 0 end)
    return ok and res
end

local function PickerSame(a, b)
    return PickerValid(a) and PickerValid(b) and a:GetAddress() == b:GetAddress()
end

-- Buttons left behind by a previous load of this script (Ctrl+R hot reload).
do
    local recorded = nil
    if ModRef then pcall(function() recorded = ModRef:GetSharedVariable("QuickStack.PickerWidgets") end) end
    if type(recorded) == "string" and recorded ~= "" then
        ExecuteInGameThread(function()
            local names = {}
            for n in recorded:gmatch("[^\n]+") do names[n] = true end
            for _, w in ipairs(FindAllOf("WBP_DomAllCapsButton_C") or {}) do
                if PickerValid(w) and names[w:GetFullName()] then pcall(function() w:RemoveFromParent() end) end
            end
        end)
    end
end

-- Every picker widget that exists (a nil entry would stop ipairs early).
local function PickerWidgets()
    local list = {}
    if Picker.Close then list[#list + 1] = Picker.Close end
    if Picker.More then list[#list + 1] = Picker.More end
    for _, w in pairs(Picker.Buttons) do list[#list + 1] = w end
    return list
end

local function PickerRemember()
    if not ModRef then return end
    local names = {}
    for _, w in pairs(PickerWidgets()) do
        if PickerValid(w) then names[#names + 1] = w:GetFullName() end
    end
    pcall(function() ModRef:SetSharedVariable("QuickStack.PickerWidgets", table.concat(names, "\n")) end)
end

local function PickerText(str)
    return StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(str)
end

local function PickerCreateButton(pc)
    local cls = StaticFindObject(PICKER_BUTTON)
    if not PickerValid(cls) and LoadAsset then
        pcall(function() LoadAsset(PICKER_BUTTON) end)
        cls = StaticFindObject(PICKER_BUTTON)
    end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not PickerValid(cls) or not PickerValid(lib) then return nil end
    local w = lib:Create(pc, cls, pc)
    if not PickerValid(w) then return nil end
    pcall(function() w:SetIsFocusable(false) end)
    w:AddToViewport(10060)
    w:SetVisibility(1)
    return w
end

local function PickerPlace(w, x, y, width, height)
    w:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
    w:SetAnchorsInViewport({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    w:SetPositionInViewport({ X = x, Y = y }, false)
    w:SetDesiredSizeInViewport({ X = width, Y = height })
end

local function HidePicker()
    Picker.Visible = false
    for _, w in pairs(PickerWidgets()) do
        if PickerValid(w) then pcall(function() w:SetVisibility(1) end) end
    end
end

-- Item types in nearby chests that the station takes, with total counts.
local function PickerBuildEntries(station, playerLoc)
    local entries, byAddr = {}, {}
    if not station.Accepted then return entries end
    for _, entry in ipairs(FindNearbyChests(playerLoc)) do
        local n = 0
        pcall(function() n = entry.Inventory.ItemSlots:GetArrayNum() end)
        for i = 1, n do
            local item = nil
            pcall(function() item = entry.Inventory.ItemSlots[i] end)
            if IsValidItem(item) then
                local addr = GetItemDataAddress(item)
                if addr and station.Accepted[addr] then
                    local count = 0
                    pcall(function() count = item:GetStackSize() end)
                    local e = byAddr[addr]
                    if not e then
                        e = { DataAddr = addr, ItemData = item.ItemData, Name = GetItemName(item), Count = 0,
                              Fuel = station.Fuels and station.Fuels[addr] and not station.Resources[addr],
                              Loaded = station.Loaded and station.Loaded[addr] and true or false }
                        byAddr[addr] = e
                        entries[#entries + 1] = e
                    end
                    e.Count = e.Count + (count or 0)
                end
            end
        end
    end
    -- What is already in the station first, then ingredients before fuel, then by name.
    table.sort(entries, function(a, b)
        if a.Loaded ~= b.Loaded then return a.Loaded end
        if (a.Fuel and 1 or 0) ~= (b.Fuel and 1 or 0) then return not a.Fuel end
        return a.Name < b.Name
    end)
    return entries
end

local function PickerRender(pc)
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local size, dpi = layout:GetViewportSize(pc), layout:GetViewportScale(pc)
    local width, height = size.X / dpi, size.Y / dpi
    local rowH, colW = 58, 380
    local x, y = width - colW - 40, 120
    local perPage = math.max(3, math.min(12, math.floor((height - y - 2 * rowH - 40) / rowH)))
    local pages = math.max(1, math.ceil(#Picker.Entries / perPage))
    if Picker.Page > pages then Picker.Page = 1 end

    if not PickerValid(Picker.Close) then Picker.Close = PickerCreateButton(pc) end
    if not PickerValid(Picker.Close) then
        Log("Station Fetch: could not create the picker buttons.")
        return
    end
    local title = #Picker.Entries == 0
        and (Picker.Station.Crafting and not Picker.Station.Accepted and "SELECT A RECIPE FIRST  /  CLOSE"
             or "NOTHING IN NEARBY CHESTS  /  CLOSE")
        or "FETCH FROM CHESTS  /  CLOSE"
    Picker.Close:SetLabelText(PickerText(title))
    PickerPlace(Picker.Close, x, y, colW, rowH - 6)
    Picker.Close:SetVisibility(0)

    Picker.Rows = {}
    local first = (Picker.Page - 1) * perPage
    for i = 1, perPage do
        local e = Picker.Entries[first + i]
        local b = Picker.Buttons[i]
        if e then
            if not PickerValid(b) then
                b = PickerCreateButton(pc)
                Picker.Buttons[i] = b
            end
            if PickerValid(b) then
                local label = string.format("%s%s  x%d", e.Name, e.Fuel and " (fuel)" or "", e.Count)
                b:SetLabelText(PickerText(label))
                PickerPlace(b, x, y + i * rowH, colW, rowH - 6)
                b:SetVisibility(0)
                Picker.Rows[i] = e
            end
        elseif PickerValid(b) then
            b:SetVisibility(1)
        end
    end
    for i = perPage + 1, #Picker.Buttons do
        if PickerValid(Picker.Buttons[i]) then Picker.Buttons[i]:SetVisibility(1) end
    end

    if pages > 1 then
        if not PickerValid(Picker.More) then Picker.More = PickerCreateButton(pc) end
        if PickerValid(Picker.More) then
            Picker.More:SetLabelText(PickerText(string.format("MORE  (%d / %d)", Picker.Page, pages)))
            PickerPlace(Picker.More, x, y + (perPage + 1) * rowH, colW, rowH - 6)
            Picker.More:SetVisibility(0)
        end
    elseif PickerValid(Picker.More) then
        Picker.More:SetVisibility(1)
    end
    PickerRemember()
    Picker.Visible = true
end

local function OpenPicker(PC, station, playerLoc)
    Picker.Station = station
    Picker.Entries = PickerBuildEntries(station, playerLoc)
    Picker.Page = 1
    PickerRender(PC)
    Log(string.format("Station Fetch picker: %d item type(s) for '%s'.", #Picker.Entries, station.ClassName))
end

local function PickerClicked(index)
    local e = Picker.Rows[index]
    local PC, pawn, playerLoc = PlayerContext()
    if not e or not PC then return end
    ExecuteQuickPull({ Item = nil, DataAddr = e.DataAddr, Name = e.Name },
        MaxStackOf(e.ItemData) * Config.StationFetchStacksPerItem)
    -- Refresh the counts left in the chests.
    Picker.Entries = PickerBuildEntries(Picker.Station, playerLoc)
    PickerRender(PC)
end

-- Hide the list once the station menu closes (the mouse cursor goes away).
local function PickerWatch()
    if not Picker.Visible then return end
    local PC = UEHelpers.GetPlayerController()
    local cursor = false
    pcall(function() cursor = PC.bShowMouseCursor end)
    if not cursor then HidePicker() end
end

pcall(function()
    RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(context)
        if not Picker.Visible then return end
        local ok, button = pcall(function() return context:get() end)
        if not ok then return end
        if PickerSame(button, Picker.Close) then
            ExecuteInGameThread(function() pcall(HidePicker) end)
        elseif PickerSame(button, Picker.More) then
            ExecuteInGameThread(function()
                Picker.Page = Picker.Page + 1
                pcall(PickerRender, UEHelpers.GetPlayerController())
            end)
        else
            for i, b in ipairs(Picker.Buttons) do
                if PickerSame(button, b) then
                    ExecuteInGameThread(function()
                        local okClick, err = pcall(PickerClicked, i)
                        if not okClick then Log("Station Fetch picker error: " .. tostring(err)) end
                    end)
                    break
                end
            end
        end
    end)
end)

-- =========================================================================
-- NEARBY STORAGE DIALOG (every nearby chest as one list; Alt+G away from stations)
-- =========================================================================
-- A full-screen page built from the game's own Settings frame, tab buttons and
-- menu buttons (the same parts as the Toolkit dashboard): category tabs, a grid
-- of every item type across nearby chests with totals, paging, DEPOSIT ALL and
-- CLOSE. Clicking an item pulls a stack of it into the backpack.
local STORAGE_PAGE = "/Game/UI/Settings/WBP_SettingsWidget.WBP_SettingsWidget_C"
local STORAGE_ROW = "/Game/UI/Common/WBP_MainMenuTabButton.WBP_MainMenuTabButton_C"
local STORAGE_BACK = "/Game/UI/Common/WBP_DomMainMenuBottomNavButton.WBP_DomMainMenuBottomNavButton_C"
local STORAGE_VISIBLE, STORAGE_COLLAPSED = 0, 1
local StorageTabs = {
    { "ALL", nil }, { "FOOD", "FOOD" }, { "WOOD", "WOOD" }, { "MINING", "MINING" },
    { "FARMING", "FARMING" }, { "MAGIC", "MAGIC" }, { "ARMOUR", "ARMOUR" },
    { "EQUIPMENT", "EQUIPMENT" }, { "RECIPES", "RECIPES" }, { "MISC", "MISC" },
}
local Storage = {
    Visible = false, OwnCursor = false, Page = nil, Info = nil, Tabs = {}, Rows = {}, Hits = {},
    Prev = nil, Next = nil, Deposit = nil, Close = nil,
    Entries = {}, Shown = {}, Tab = 1, PageIndex = 1, ChestCount = 0,
}

local function StorageWidgets()
    local list = {}
    for _, w in ipairs({ "Page", "Info", "Prev", "Next", "Deposit", "Close" }) do
        if Storage[w] then list[#list + 1] = Storage[w] end
    end
    for _, group in ipairs({ Storage.Tabs, Storage.Rows, Storage.Hits }) do
        for _, w in pairs(group) do list[#list + 1] = w end
    end
    return list
end

-- Widgets left behind by a previous load of this script (Ctrl+R hot reload).
do
    local recorded = nil
    if ModRef then pcall(function() recorded = ModRef:GetSharedVariable("QuickStack.StorageWidgets") end) end
    if type(recorded) == "string" and recorded ~= "" then
        ExecuteInGameThread(function()
            local names = {}
            for n in recorded:gmatch("[^\n]+") do names[n] = true end
            for _, cls in ipairs({ "WBP_SettingsWidget_C", "WBP_MainMenuTabButton_C",
                                   "WBP_DomAllCapsButton_C", "WBP_DomMainMenuBottomNavButton_C" }) do
                for _, w in ipairs(FindAllOf(cls) or {}) do
                    if PickerValid(w) and names[w:GetFullName()] then pcall(function() w:RemoveFromParent() end) end
                end
            end
        end)
    end
end

local function StorageRemember()
    if not ModRef then return end
    local names = {}
    for _, w in pairs(StorageWidgets()) do
        if PickerValid(w) then names[#names + 1] = w:GetFullName() end
    end
    pcall(function() ModRef:SetSharedVariable("QuickStack.StorageWidgets", table.concat(names, "\n")) end)
end

local function StorageCreate(pc, path, z)
    local cls = StaticFindObject(path)
    if not PickerValid(cls) and LoadAsset then
        pcall(function() LoadAsset(path) end)
        cls = StaticFindObject(path)
    end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not PickerValid(cls) or not PickerValid(lib) then error("game UI asset unavailable: " .. path) end
    local w = lib:Create(pc, cls, pc)
    if not PickerValid(w) then error("game UI construction failed: " .. path) end
    pcall(function() w:SetIsFocusable(false) end)
    w:SetVisibility(STORAGE_COLLAPSED)
    w:AddToViewport(z)
    return w
end

-- Text on a tab-button row (its native LabelText) or on a menu button.
local function StorageLabel(w, text)
    if not PickerValid(w) then return end
    local ok = pcall(function() w.LabelText:SetText(PickerText(text)) end)
    if not ok then pcall(function() w:SetLabelText(PickerText(text)) end) end
end

local function StorageBuild(pc)
    Storage.Page = StorageCreate(pc, STORAGE_PAGE, 10070)
    -- Our own Settings instance: collapse its categories and content so none of
    -- its handlers can change game settings; keep the frame and title styling.
    for _, name in ipairs({
        "Button_Video", "Button_Legal", "Button_Gameplay", "Button_Controls",
        "Button_Audio", "Button_Accessibility", "AudioSubWidget", "AccessibilitySubWidget",
        "GameplaySubWidget", "DeveloperSubWidget", "ControlsSubWidget", "VideoSubWidget",
        "LegalSubWidget", "WBP_SettingTooltipContainer", "SubCategoryScroller",
        "SubCategoryButtonGroup", "SubTabLeftInputActionWidget", "SubTabRightInputActionWidget",
    }) do
        pcall(function()
            local child = Storage.Page[name]
            if PickerValid(child) then child:SetVisibility(STORAGE_COLLAPSED) end
        end)
    end
    pcall(function()
        Storage.Page.WBP_MainMenu_ScreenTitle.HeaderTextBlock:SetText(PickerText("NEARBY STORAGE"))
    end)
    Storage.Info = StorageCreate(pc, STORAGE_ROW, 10071)
    for i, tab in ipairs(StorageTabs) do
        Storage.Tabs[i] = StorageCreate(pc, PICKER_BUTTON, 10072)
        StorageLabel(Storage.Tabs[i], tab[1])
    end
    Storage.Prev = StorageCreate(pc, PICKER_BUTTON, 10072)
    Storage.Next = StorageCreate(pc, PICKER_BUTTON, 10072)
    Storage.Deposit = StorageCreate(pc, PICKER_BUTTON, 10072)
    Storage.Close = StorageCreate(pc, STORAGE_BACK, 10072)
    StorageLabel(Storage.Prev, "< PREV")
    StorageLabel(Storage.Next, "NEXT >")
    StorageLabel(Storage.Deposit, "DEPOSIT ALL (G)")
    StorageLabel(Storage.Close, "CLOSE")
    StorageRemember()
end

-- Every item type across nearby chests: { DataAddr, ItemData, Name, Count, Chests, Category }.
local function StorageCollect(playerLoc)
    local entries, byAddr = {}, {}
    local chests = FindNearbyChests(playerLoc)
    for _, entry in ipairs(chests) do
        local seenHere = {}
        local n = 0
        pcall(function() n = entry.Inventory.ItemSlots:GetArrayNum() end)
        for i = 1, n do
            local item = nil
            pcall(function() item = entry.Inventory.ItemSlots[i] end)
            if IsValidItem(item) then
                local addr = GetItemDataAddress(item)
                if addr then
                    local e = byAddr[addr]
                    if not e then
                        e = { DataAddr = addr, ItemData = item.ItemData, Name = GetItemName(item),
                              Count = 0, Chests = 0, Category = GetItemCategory(item) }
                        byAddr[addr] = e
                        entries[#entries + 1] = e
                    end
                    local count = 0
                    pcall(function() count = item:GetStackSize() end)
                    e.Count = e.Count + (count or 0)
                    if not seenHere[addr] then seenHere[addr] = true; e.Chests = e.Chests + 1 end
                end
            end
        end
    end
    table.sort(entries, function(a, b) return a.Name < b.Name end)
    return entries, #chests
end

local function StoragePlace(w, x, y, width, height)
    if not PickerValid(w) then return end
    PickerPlace(w, x, y, width, height)
    w:SetVisibility(STORAGE_VISIBLE)
end

local function StorageRender(pc)
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local size, dpi = layout:GetViewportSize(pc), layout:GetViewportScale(pc)
    local width, height = size.X / dpi, size.Y / dpi
    local x0 = math.max(90, width * 0.05)
    local innerW = width - 2 * x0

    -- Filtered list for the selected tab.
    local category = StorageTabs[Storage.Tab][2]
    local list = {}
    for _, e in ipairs(Storage.Entries) do
        if not category or e.Category == category then list[#list + 1] = e end
    end

    -- Summary line.
    local totalItems = 0
    for _, e in ipairs(Storage.Entries) do totalItems = totalItems + e.Count end
    StorageLabel(Storage.Info, string.format("%d CHESTS NEARBY  |  %d ITEM TYPES  |  %d ITEMS  |  CLICK AN ITEM TO TAKE A STACK",
        Storage.ChestCount, #Storage.Entries, totalItems))
    StoragePlace(Storage.Info, x0, 168, innerW, 46)

    -- Category tabs (the selected one reads [LIKE THIS]).
    local tabW = (innerW - (#StorageTabs - 1) * 8) / #StorageTabs
    for i, tab in ipairs(StorageTabs) do
        StorageLabel(Storage.Tabs[i], i == Storage.Tab and ("[" .. tab[1] .. "]") or tab[1])
        StoragePlace(Storage.Tabs[i], x0 + (i - 1) * (tabW + 8), 224, tabW, 50)
    end

    -- Item grid.
    local cols, rowH, gap = 3, 60, 14
    local colW = (innerW - (cols - 1) * gap) / cols
    local gridTop = 292
    local rows = math.max(3, math.min(10, math.floor((height - gridTop - 150) / rowH)))
    local perPage = rows * cols
    local pages = math.max(1, math.ceil(#list / perPage))
    if Storage.PageIndex > pages then Storage.PageIndex = pages end
    local first = (Storage.PageIndex - 1) * perPage
    Storage.Shown = {}
    for slot = 1, perPage do
        local e = list[first + slot]
        if e then
            if not PickerValid(Storage.Rows[slot]) then
                Storage.Rows[slot] = StorageCreate(pc, STORAGE_ROW, 10071)
                -- An invisible menu button on top of each row takes the click (as in the Toolkit dashboard).
                Storage.Hits[slot] = StorageCreate(pc, PICKER_BUTTON, 10073)
                StorageLabel(Storage.Hits[slot], "")
                pcall(function() Storage.Hits[slot]:SetRenderOpacity(0.0) end)
                StorageRemember()
            end
            local col = (slot - 1) % cols
            local row = math.floor((slot - 1) / cols)
            local x, y = x0 + col * (colW + gap), gridTop + row * rowH
            local label = string.format("%s   x%d", e.Name, e.Count)
            if e.Chests > 1 then label = label .. string.format("   (%d chests)", e.Chests) end
            StorageLabel(Storage.Rows[slot], label)
            StoragePlace(Storage.Rows[slot], x, y, colW, rowH - 8)
            StoragePlace(Storage.Hits[slot], x, y, colW, rowH - 8)
            Storage.Shown[slot] = e
        else
            if PickerValid(Storage.Rows[slot]) then Storage.Rows[slot]:SetVisibility(STORAGE_COLLAPSED) end
            if PickerValid(Storage.Hits[slot]) then Storage.Hits[slot]:SetVisibility(STORAGE_COLLAPSED) end
        end
    end
    for slot = perPage + 1, #Storage.Rows do
        if PickerValid(Storage.Rows[slot]) then Storage.Rows[slot]:SetVisibility(STORAGE_COLLAPSED) end
        if PickerValid(Storage.Hits[slot]) then Storage.Hits[slot]:SetVisibility(STORAGE_COLLAPSED) end
    end
    if #list == 0 then
        StorageLabel(Storage.Info, Storage.ChestCount == 0 and "NO CHESTS NEARBY"
            or "NOTHING IN THIS CATEGORY  |  PICK ANOTHER TAB")
    end

    -- Bottom bar.
    local by = height - 112
    StoragePlace(Storage.Close, x0, by, 240, 56)
    StorageLabel(Storage.Prev, pages > 1 and string.format("< PREV   %d / %d", Storage.PageIndex, pages) or "< PREV")
    StoragePlace(Storage.Prev, x0 + 260, by, 240, 56)
    StoragePlace(Storage.Next, x0 + 520, by, 200, 56)
    StoragePlace(Storage.Deposit, width - x0 - 340, by, 340, 56)
    StoragePlace(Storage.Page, 0, 0, width, height)
    Storage.Visible = true
end

local function StorageSetCursor(pc, on)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    pcall(function() pc.bShowMouseCursor = on end)
    if on then
        pcall(function() lib:SetInputMode_UIOnlyEx(pc, Storage.Page, 0, false) end)
    else
        pcall(function() lib:SetInputMode_GameOnly(pc, false) end)
    end
end

local function CloseStorage()
    if not Storage.Visible then return end
    Storage.Visible = false
    for _, w in pairs(StorageWidgets()) do
        if PickerValid(w) then pcall(function() w:SetVisibility(STORAGE_COLLAPSED) end) end
    end
    if Storage.OwnCursor then
        Storage.OwnCursor = false
        local pc = UEHelpers.GetPlayerController()
        if PickerValid(pc) then StorageSetCursor(pc, false) end
    end
end

local function StorageRefresh()
    local PC, pawn, playerLoc = PlayerContext()
    if not PC then return end
    Storage.Entries, Storage.ChestCount = StorageCollect(playerLoc)
    StorageRender(PC)
end

local function OpenStorage(PC, playerLoc)
    if not PickerValid(Storage.Page) then StorageBuild(PC) end
    Storage.Tab, Storage.PageIndex = 1, 1
    Storage.Entries, Storage.ChestCount = StorageCollect(playerLoc)
    StorageRender(PC)
    -- Opened from normal play: show the cursor and send input to the dialog.
    local cursor = false
    pcall(function() cursor = PC.bShowMouseCursor end)
    if not cursor then
        Storage.OwnCursor = true
        StorageSetCursor(PC, true)
    end
    Log(string.format("Nearby Storage: %d item type(s) across %d chest(s).", #Storage.Entries, Storage.ChestCount))
end

-- Close with the menu it was opened over (the cursor goes away), or on Escape.
local function StorageWatch()
    if not Storage.Visible or Storage.OwnCursor then return end
    local PC = UEHelpers.GetPlayerController()
    local cursor = false
    pcall(function() cursor = PC.bShowMouseCursor end)
    if not cursor then CloseStorage() end
end

pcall(function()
    RegisterKeyBind(Key.ESCAPE, function()
        ExecuteInGameThread(function() if Storage.Visible then pcall(CloseStorage) end end)
    end)
end)

local function StorageGuard(fn)
    local ok, err = pcall(fn)
    if not ok then
        Log("Nearby Storage error: " .. tostring(err))
        pcall(CloseStorage)
    end
end

pcall(function()
    RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(context)
        if not Storage.Visible then return end
        local ok, button = pcall(function() return context:get() end)
        if not ok then return end
        if PickerSame(button, Storage.Close) then
            ExecuteInGameThread(function() StorageGuard(CloseStorage) end)
        elseif PickerSame(button, Storage.Prev) then
            ExecuteInGameThread(function() StorageGuard(function()
                Storage.PageIndex = math.max(1, Storage.PageIndex - 1)
                StorageRender(UEHelpers.GetPlayerController())
            end) end)
        elseif PickerSame(button, Storage.Next) then
            ExecuteInGameThread(function() StorageGuard(function()
                Storage.PageIndex = Storage.PageIndex + 1
                StorageRender(UEHelpers.GetPlayerController())
            end) end)
        elseif PickerSame(button, Storage.Deposit) then
            ExecuteInGameThread(function() StorageGuard(function()
                local found = ExecuteQuickStack(true)
                if found then ExecuteQuickStack() end
                StorageRefresh()
            end) end)
        else
            for i, tab in ipairs(Storage.Tabs) do
                if PickerSame(button, tab) then
                    ExecuteInGameThread(function() StorageGuard(function()
                        Storage.Tab, Storage.PageIndex = i, 1
                        StorageRender(UEHelpers.GetPlayerController())
                    end) end)
                    return
                end
            end
            for slot, hit in pairs(Storage.Hits) do
                if PickerSame(button, hit) then
                    ExecuteInGameThread(function() StorageGuard(function()
                        local e = Storage.Shown[slot]
                        if not e then return end
                        ExecuteQuickPull({ Item = nil, DataAddr = e.DataAddr, Name = e.Name },
                            MaxStackOf(e.ItemData) * Config.StorageStacksPerClick)
                        StorageRefresh()
                    end) end)
                    return
                end
            end
        end
    end)
end)

local function ExecuteStationFetch()
    local PC, pawn, playerLoc = PlayerContext()
    if not PC then return end

    -- Alt+G while Nearby Storage is open closes it.
    if Storage.Visible then
        CloseStorage()
        return
    end

    -- Alt+G while the picker is open closes it.
    if Picker.Visible then
        HidePicker()
        return
    end

    -- Hovering an item always wins: pull every matching stack.
    local hover = GetCurrentHoverTarget()
    if hover then
        ExecuteQuickPull(hover)
        return
    end

    local station, how = FindOpenStation(PC, playerLoc)
    if not station and Config.StorageDialog then
        OpenStorage(PC, playerLoc)
        return
    end
    if not station then
        Log("[DISCOVERY] Station Fetch: no open station menu and no processing station within 6m.")
        Log("Station Fetch: open a crafting station (or hover an item) and press [Alt + G].")
        return
    end
    local acceptedCount = 0
    for _ in pairs(station.Accepted or {}) do acceptedCount = acceptedCount + 1 end
    Log(string.format("[DISCOVERY] Station Fetch: found '%s' via %s, %d accepted item type(s) listed.",
        station.ClassName, how, acceptedCount))

    -- Show the clickable list so the player picks exactly what to fetch.
    if Config.StationFetchPicker and (station.Processing or station.Crafting) then
        OpenPicker(PC, station, playerLoc)
        return
    end

    -- Crafting benches: only the selected recipe's ingredients, never a guess.
    if station.Crafting and not station.Accepted then
        Log(string.format("Station Fetch: select a recipe at '%s' first, then press [Alt + G] to fetch its ingredients.",
            station.ClassName))
        return
    end

    -- Every processing station (smelter, loom, spinning wheel, tanner, sawmill, kiln,
    -- grindstone, stonecutter, campfire, grill, cauldron, fermentation barrel...):
    -- only top up what is already in it, so the player chooses
    -- (one iron ore in = fetch iron; a log in the fuel slot = fetch logs).
    if station.Processing and Config.StationFetchLoadedOnly then
        if station.Loaded then
            station.Accepted = station.Loaded
        elseif not Config.StationFetchAllWhenEmpty then
            Log(string.format("Station Fetch: '%s' is empty. Put one of what you want (ore, fuel...) into it, then press [Alt + G] to fetch more of it. Or hover an item and press [Alt + G].",
                station.ClassName))
            return
        end
    end

    local nearbyChests = FindNearbyChests(playerLoc)
    if #nearbyChests == 0 then
        Log("Station Fetch: no chests nearby.")
        return
    end

    -- Collect one entry per item type found in chests.
    local types, order = {}, {}
    for _, entry in ipairs(nearbyChests) do
        local n = 0
        pcall(function() n = entry.Inventory.ItemSlots:GetArrayNum() end)
        for i = 1, n do
            local item = nil
            pcall(function() item = entry.Inventory.ItemSlots[i] end)
            if IsValidItem(item) then
                local addr = GetItemDataAddress(item)
                if addr and not types[addr] then
                    types[addr] = { DataAddr = addr, ItemData = item.ItemData, Name = GetItemName(item) }
                    order[#order + 1] = types[addr]
                end
            end
        end
    end

    -- Which of those does the station take? Prefer the station's own list
    -- (AcceptedResources, or the selected recipe's ingredients).
    local accepted = {}
    if station.Accepted then
        for _, t in ipairs(order) do
            if station.Accepted[t.DataAddr] then accepted[#accepted + 1] = t end
        end
    elseif station.Inventory then
        for _, t in ipairs(order) do
            local space = 0
            pcall(function() space = station.Inventory:GetSpaceAvailableForItemByData(t.ItemData) end)
            if space and space > 0 then accepted[#accepted + 1] = t end
        end
    end

    -- A station that accepts nearly everything has no filter we can read: use name hints instead.
    if not station.Accepted and (#accepted == 0 or #accepted > Config.StationFetchMaxItemTypes) then
        local cls = station.ClassName:lower()
        local wanted = nil
        for _, hint in ipairs(StationIngredientHints) do
            for _, k in ipairs(hint.Keys) do
                if cls:find(k, 1, true) then wanted = hint.Items; break end
            end
            if wanted then break end
        end
        if not wanted then
            Log(string.format("Station Fetch: can't tell what '%s' accepts (it took %d item types). Hover the ingredient and press [Alt + G] instead.",
                station.ClassName, #accepted))
            return
        end
        accepted = {}
        for _, t in ipairs(order) do
            local nm = t.Name:lower()
            for _, w in ipairs(wanted) do
                if nm:find(w, 1, true) then accepted[#accepted + 1] = t; break end
            end
        end
    end

    if #accepted == 0 then
        Log(string.format("Station Fetch: nothing in nearby chests that '%s' uses.", station.ClassName))
        return
    end

    local names = {}
    for _, t in ipairs(accepted) do
        ExecuteQuickPull({ Item = nil, DataAddr = t.DataAddr, Name = t.Name },
            MaxStackOf(t.ItemData) * Config.StationFetchStacksPerItem)
        names[#names + 1] = t.Name
    end
    Log(string.format(">>> Station Fetch for '%s': pulled %s", station.ClassName, table.concat(names, ", ")))
end

-- =========================================================================
-- CHEST LABELS (floating category name above each nearby chest)
-- =========================================================================
local ChestLabels = {}          -- [actorAddress] = { Actor, Comp, Text }
local ChestLabelsEnabled = Config.ChestLabels
local TextRenderClass = nil
local CategoryLabelText = {
    FOOD = "Food", WOOD = "Wood", MINING = "Mining", FARMING = "Farming",
    MAGIC = "Magic", EQUIPMENT = "Equipment", MISC = "Misc",
}

local function MakeText(str)
    local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    return lib:Conv_StringToText(str)
end

local function RemoveChestLabel(addr)
    local label = ChestLabels[addr]
    if label and label.Comp and label.Comp:IsValid() then
        pcall(function() label.Comp:K2_DestroyComponent(label.Comp) end)
    end
    ChestLabels[addr] = nil
end

local function RemoveAllChestLabels()
    for addr in pairs(ChestLabels) do RemoveChestLabel(addr) end
end

-- Labels left behind by a previous load of this script (Ctrl+R hot reload).
local function PurgeOrphanChestLabels()
    local ok, comps = pcall(function() return FindAllOf("TextRenderComponent") end)
    if not ok or not comps then return end
    for _, comp in ipairs(comps) do
        pcall(function()
            local owner = comp:GetOwner()
            if owner and owner:IsValid() and IsChestActor(owner) then
                comp:K2_DestroyComponent(comp)
            end
        end)
    end
end

local function EnsureChestLabel(actor, text)
    local addr = actor:GetAddress()
    local label = ChestLabels[addr]
    if label and label.Comp and label.Comp:IsValid() then
        if label.Text ~= text then
            pcall(function() label.Comp:K2_SetText(MakeText(text)) end)
            label.Text = text
        end
        return
    end
    if not TextRenderClass or not TextRenderClass:IsValid() then
        TextRenderClass = StaticFindObject("/Script/Engine.TextRenderComponent")
    end
    if not TextRenderClass or not TextRenderClass:IsValid() then return end
    local comp = nil
    pcall(function()
        comp = actor:AddComponentByClass(TextRenderClass, false, {
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Translation = { X = 0, Y = 0, Z = Config.ChestLabelHeight },
            Scale3D = { X = 1, Y = 1, Z = 1 }
        }, false)
    end)
    if not comp or not comp:IsValid() then return end
    pcall(function()
        comp:SetHorizontalAlignment(1) -- EHTA_Center
        comp:SetVerticalAlignment(1)   -- EVRTA_TextCenter
        comp:SetWorldSize(Config.ChestLabelSize)
        comp:SetTextRenderColor({ R = 255, G = 215, B = 0, A = 255 })
        comp:SetCollisionEnabled(0)
        comp:K2_SetText(MakeText(text))
    end)
    ChestLabels[addr] = { Actor = actor, Comp = comp, Text = text }
end

local function RefreshChestLabels()
    if not ChestLabelsEnabled then return end
    local PC, pawn, playerLoc = PlayerContext()
    if not PC then return end
    local maxSq = Config.ChestLabelRadius * Config.ChestLabelRadius
    local seen = {}
    for _, entry in ipairs(FindNearbyChests(playerLoc)) do
        if entry.Distance * entry.Distance <= maxSq then
            local st = AnalyzeChest(entry)
            local text = st.TotalItemCount == 0 and "Empty"
                or (CategoryLabelText[st.DominantCategory] or st.DominantCategory or "Misc")
            local addr = entry.Actor:GetAddress()
            seen[addr] = true
            EnsureChestLabel(entry.Actor, text)
        end
    end
    for addr, label in pairs(ChestLabels) do
        if not seen[addr] or not label.Actor or not label.Actor:IsValid() then RemoveChestLabel(addr) end
    end
end

-- Turn each label to face the camera so it reads from any side.
local function FaceChestLabels()
    if not ChestLabelsEnabled or next(ChestLabels) == nil then return end
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return end
    local cam = nil
    pcall(function() cam = PC.PlayerCameraManager:GetCameraLocation() end)
    if not cam then return end
    for _, label in pairs(ChestLabels) do
        pcall(function()
            local loc = label.Comp:K2_GetComponentLocation()
            local yaw = math.deg(math.atan(cam.Y - loc.Y, cam.X - loc.X))
            label.Comp:K2_SetWorldRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false, {}, true)
        end)
    end
end

local function ToggleChestLabels()
    ChestLabelsEnabled = not ChestLabelsEnabled
    if ChestLabelsEnabled then
        RefreshChestLabels()
    else
        RemoveAllChestLabels()
    end
    Log("Chest labels: " .. (ChestLabelsEnabled and "ON" or "OFF"))
end

-- =========================================================================
-- STATION OUTPUT AUTO-STORE
-- =========================================================================
-- When a crafting station finishes and drops its product on the ground, move
-- that item straight into the matching category chest.
local SeenWorldItems = {}         -- [address] = true for items that existed before
local SeenWorldItemsPrimed = false
local LoggedOwnerClasses = {}

local StationKeywords = {
    "furnace", "smelter", "kiln", "campfire", "range", "cook", "cauldron", "bench",
    "anvil", "wheel", "station", "crafting", "grinder", "sawmill", "loom",
    "stonecutter", "tanning", "brew", "pottery", "altar", "workshop", "forge",
}
local function IsStationActor(actor)
    if not actor or not IsValidWorldActor(actor) then return false end
    local cls = GetSafeClassName(actor):lower()
    for _, kw in ipairs(StationKeywords) do
        if cls:find(kw, 1, true) then return true end
    end
    return false
end

local function StationThatMade(item)
    -- Processing stations (furnace, smelter...) drop their product as this class
    -- (ProcessingStationComponent.SpawnItemClass in the object dump).
    local cls = GetSafeClassName(item)
    if cls:find("ProcessingStation", 1, true) then return item, cls end
    for _, getter in ipairs({
        function() return item:GetOwner() end,
        function() return item.Owner end,
        function() return item:GetInstigator() end,
    }) do
        local ok, owner = pcall(getter)
        if ok and owner and IsStationActor(owner) then return owner, GetSafeClassName(owner) end
    end
    return nil
end

-- Room for itemData across the chests StoreIntoCategoryChest would use.
local function CategoryChestSpace(itemData, category, nearbyChests)
    local space = 0
    for _, ch in ipairs(nearbyChests) do
        local st = AnalyzeChest(ch)
        if st.DominantCategory == category or st.TotalItemCount == 0 or Config.OverflowWhenCategoryFull then
            local s = 0
            pcall(function() s = ch.Inventory:GetSpaceAvailableForItemByData(itemData) end)
            space = space + (s or 0)
        end
    end
    return space
end

local function AutoStoreStationOutput()
    if not Config.AutoStoreStationOutput then return end
    local PC, pawn, playerLoc = PlayerContext()
    if not PC then return end
    local okItems, items = pcall(function() return FindAllOf("WorldItem") end)
    if not okItems or not items then return end

    local fresh = {}
    local maxSq = Config.StationOutputRadius * Config.StationOutputRadius
    local current = {}
    for _, actor in ipairs(items) do
        if IsValidWorldActor(actor) then
            local addr = actor:GetAddress()
            current[addr] = true
            if SeenWorldItemsPrimed and not SeenWorldItems[addr] then
                local loc = nil
                pcall(function() loc = actor:K2_GetActorLocation() end)
                if loc and DistSq(loc, playerLoc) <= maxSq then fresh[#fresh + 1] = actor end
            end
        end
    end
    SeenWorldItems = current
    if not SeenWorldItemsPrimed then
        SeenWorldItemsPrimed = true
        return
    end
    if #fresh == 0 then return end

    local nearbyChests = nil
    for _, actor in ipairs(fresh) do
        local station, stationCls = StationThatMade(actor)
        if not station and Config.DebugLog then
            local itemCls = GetSafeClassName(actor)
            if not LoggedOwnerClasses[itemCls] then
                LoggedOwnerClasses[itemCls] = true
                Log("[DISCOVERY] New ground item near you (not station output): " .. itemCls)
            end
        end
        if station then
            nearbyChests = nearbyChests or FindNearbyChests(playerLoc)
            local itemData, count = nil, 0
            pcall(function() itemData = actor.ItemData end)
            pcall(function() count = actor:GetStackSize() end)
            if itemData and itemData:IsValid() and count and count > 0 and #nearbyChests > 0 then
                local name = GetItemName(actor)
                local category = GetItemCategory(actor)
                -- Only move whole stacks: a ground item's stack size can't be reduced,
                -- so a partial store would duplicate the rest.
                if CategoryChestSpace(itemData, category, nearbyChests) >= count then
                    local stored = StoreIntoCategoryChest(itemData, count, 1.0, name, category, nearbyChests)
                    if stored >= count then
                        pcall(function() actor:K2_DestroyActor() end)
                        Log(string.format(">>> Auto-stored %dx '%s' from %s.", stored, name, stationCls))
                    elseif stored > 0 then
                        Log(string.format("Auto-store: only %d of %dx '%s' fit; left the stack on the ground.", stored, count, name))
                    end
                elseif Config.DebugLog then
                    Log(string.format("Auto-store: no room for %dx '%s' in [%s] chests; left it on the ground.", count, name, category))
                end
            end
        end
    end
end

-- Background loop: labels every 10 s (each refresh scans every chest), label facing every 0.2 s, station output every 1 s.
do
    local tick, busy = 0, false
    LoopAsync(200, function()
        tick = tick + 1
        if busy then return false end
        busy = true
        ExecuteInGameThread(function()
            if tick % 50 == 1 then pcall(RefreshChestLabels) end
            if tick % 5 == 0 then pcall(AutoStoreStationOutput) end
            pcall(FaceChestLabels)
            pcall(PickerWatch)
            pcall(StorageWatch)
            busy = false
        end)
        return false
    end)
end
ExecuteInGameThread(function() pcall(PurgeOrphanChestLabels) end)

-- =========================================================================
-- EXECUTE QUICK PULL (Retrieve matching items from chests into player inventory)
-- =========================================================================
ExecuteQuickPull = function(target, maxCount)
    if not target then
        Log("QuickPull failed: No target item specified.")
        return
    end

    local targetDataAddr = target.DataAddr
    local targetName = target.Name or "Item"

    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) then
        Log("QuickPull failed: Local PlayerController not found or invalid.")
        return
    end

    local pawn = PC.Pawn
    if not IsValidWorldActor(pawn) then
        Log("QuickPull failed: Player character pawn not spawned.")
        return
    end

    local playerLoc = nil
    pcall(function() playerLoc = pawn:K2_GetActorLocation() end)
    if not playerLoc then
        Log("QuickPull failed: Unable to get player location.")
        return
    end

    local playerInv = PC.BP_Components_Inventory
    if not playerInv or not playerInv:IsValid() then
        Log("QuickPull failed: Player inventory component not found.")
        return
    end

    local nearbyChests = FindNearbyChests(playerLoc)
    if #nearbyChests == 0 then
        Log(string.format("QuickPull: No chests found within %.1f meters.", Config.SearchRadius / 100.0))
        return
    end

    -- 1. Gather all matching candidate items across all nearby chests
    local chestItemsToPull = {}

    for _, entry in ipairs(nearbyChests) do
        local chestInv = entry.Inventory
        local chestActor = entry.Actor

        local chestSlotCount = 0
        pcall(function() chestSlotCount = chestInv.ItemSlots:GetArrayNum() end)

        for cIdx = 1, chestSlotCount do
            local cSlotZero = cIdx - 1
            local cItem = nil
            pcall(function() cItem = chestInv.ItemSlots[cIdx] end)

            if IsValidItem(cItem) then
                local isMatch = false
                if targetDataAddr then
                    local cDataAddr = GetItemDataAddress(cItem)
                    if cDataAddr and cDataAddr == targetDataAddr then
                        isMatch = true
                    end
                end

                if not isMatch and targetName then
                    local cName = GetItemName(cItem)
                    if cName and cName:lower() == targetName:lower() then
                        isMatch = true
                    end
                end

                if isMatch then
                    local count = 0
                    pcall(function() count = cItem:GetStackSize() end)
                    if count > 0 then
                        table.insert(chestItemsToPull, {
                            ChestInv = chestInv,
                            ChestActor = chestActor,
                            SlotZero = cSlotZero,
                            Count = count,
                            Item = cItem
                        })
                    end
                end
            end
        end
    end

    if #chestItemsToPull == 0 then
        Log(string.format("QuickPull: No matching '%s' found in %d nearby chest(s).", targetName, #nearbyChests))
        return
    end

    if Config.DebugLog then
        Log(string.format("QuickPull: Found %d matching stack(s) of '%s' across nearby chests.", #chestItemsToPull, targetName))
    end

    -- 2. Inspect player inventory slots for fill targets and empty slots
    local hotbarCount = 0
    if Config.ProtectHotbar then
        pcall(function() hotbarCount = playerInv.NumberOfQuickActionSlots end)
        if not hotbarCount or hotbarCount < 0 then hotbarCount = 8 end
    end

    local playerSlotCount = 0
    pcall(function() playerSlotCount = playerInv.ItemSlots:GetArrayNum() end)
    if playerSlotCount <= 0 then
        Log("QuickPull failed: Player inventory has 0 slots.")
        return
    end

    -- Phase A: Top off existing partial player stacks first
    local playerTargetSlots = {}
    for pIdx = 1, playerSlotCount do
        local pSlotZero = pIdx - 1
        local pItem = nil
        pcall(function() pItem = playerInv.ItemSlots[pIdx] end)

        if IsValidItem(pItem) then
            local isMatch = false
            if targetDataAddr then
                local pDataAddr = GetItemDataAddress(pItem)
                if pDataAddr and pDataAddr == targetDataAddr then
                    isMatch = true
                end
            end
            if not isMatch and targetName then
                local pName = GetItemName(pItem)
                if pName and pName:lower() == targetName:lower() then
                    isMatch = true
                end
            end

            if isMatch then
                local freeSpace = 0
                pcall(function() freeSpace = pItem:GetStackFreeSpace() end)
                if freeSpace > 0 then
                    table.insert(playerTargetSlots, {
                        SlotZero = pSlotZero,
                        FreeSpace = freeSpace
                    })
                end
            end
        end
    end

    -- Phase B: Find empty player backpack slots (hotbar protected by default)
    local playerEmptySlots = {}
    for pIdx = hotbarCount + 1, playerSlotCount do
        local pSlotZero = pIdx - 1
        local pItem = nil
        pcall(function() pItem = playerInv.ItemSlots[pIdx] end)
        if not IsValidItem(pItem) then
            table.insert(playerEmptySlots, pSlotZero)
        end
    end

    -- If hotbar is not protected, allow empty hotbar slots to be filled too
    if not Config.ProtectHotbar then
        for pIdx = 1, hotbarCount do
            local pSlotZero = pIdx - 1
            local pItem = nil
            pcall(function() pItem = playerInv.ItemSlots[pIdx] end)
            if not IsValidItem(pItem) then
                table.insert(playerEmptySlots, pSlotZero)
            end
        end
    end

    -- 3. Execute transfers from chests to player inventory
    local totalPulled = 0
    local affectedChests = {}

    for _, cEntry in ipairs(chestItemsToPull) do
        local chestInv = cEntry.ChestInv
        local chestActor = cEntry.ChestActor
        local cSlotZero = cEntry.SlotZero
        local cCount = cEntry.Count
        if maxCount then
            -- Station Fetch asks for a limited amount rather than every stack.
            local left = maxCount - totalPulled
            if left <= 0 then break end
            cCount = math.min(cCount, left)
        end

        -- Top-off existing partial player stacks
        while cCount > 0 and #playerTargetSlots > 0 do
            local targetSlot = playerTargetSlots[1]
            if targetSlot.FreeSpace > 0 then
                local moveAmount = math.min(cCount, targetSlot.FreeSpace)
                local movedOk = false
                pcall(function()
                    movedOk = chestInv:MoveItem(cSlotZero, playerInv, targetSlot.SlotZero, PC, moveAmount)
                end)

                if movedOk then
                    cCount = cCount - moveAmount
                    targetSlot.FreeSpace = targetSlot.FreeSpace - moveAmount
                    totalPulled = totalPulled + moveAmount
                    affectedChests[chestActor:GetAddress()] = true

                    if Config.DebugLog then
                        Log(string.format("QuickPull: Pulled %dx '%s' into existing player slot %d.", moveAmount, targetName, targetSlot.SlotZero))
                    end

                    if targetSlot.FreeSpace <= 0 then
                        table.remove(playerTargetSlots, 1)
                    end
                else
                    table.remove(playerTargetSlots, 1)
                    break
                end
            else
                table.remove(playerTargetSlots, 1)
            end
        end

        -- Move into empty player backpack slots
        while cCount > 0 and #playerEmptySlots > 0 do
            local emptySlotZero = table.remove(playerEmptySlots, 1)
            local moveAmount = cCount
            local movedOk = false
            pcall(function()
                movedOk = chestInv:MoveItem(cSlotZero, playerInv, emptySlotZero, PC, moveAmount)
            end)

            if movedOk then
                totalPulled = totalPulled + moveAmount
                affectedChests[chestActor:GetAddress()] = true

                if Config.DebugLog then
                    Log(string.format("QuickPull: Pulled %dx '%s' into empty player slot %d.", moveAmount, targetName, emptySlotZero))
                end

                -- Check if this newly moved item has remaining stack space
                local newPItem = nil
                pcall(function() newPItem = playerInv.ItemSlots[emptySlotZero + 1] end)
                local remainingFree = 0
                if IsValidItem(newPItem) then
                    pcall(function() remainingFree = newPItem:GetStackFreeSpace() end)
                end

                cCount = 0

                if remainingFree > 0 then
                    table.insert(playerTargetSlots, 1, {
                        SlotZero = emptySlotZero,
                        FreeSpace = remainingFree
                    })
                end
            else
                break
            end
        end

        -- Check if player inventory is completely full
        if #playerTargetSlots == 0 and #playerEmptySlots == 0 then
            if Config.DebugLog then
                Log("QuickPull: Player inventory is full.")
            end
            break
        end
    end

    -- 4. Result Logging
    if totalPulled > 0 then
        local chestCount = 0
        for _ in pairs(affectedChests) do chestCount = chestCount + 1 end

        Log(string.format(">>> SUCCESS: Retrieved %d '%s' from %d chest(s).", totalPulled, targetName, chestCount))
    else
        Log(string.format("QuickPull: Could not retrieve '%s' (inventory may be full or transfer blocked).", targetName))
    end
end

-- =========================================================================
-- WIDE LOCAL GROUND ITEM MAGNETISM & WILD RESOURCE HARVESTING (G)
-- =========================================================================

-- List of harvestable/gatherable resource classes (native C++ & specific Blueprints)
local HarvestableResourceClasses = {
    -- Native C++ classes (automatically matches derived blueprints in UE4SS)
    "BaseInteractableResource",
    "GatherableResource",
    "HarvestableResource",
    "SalvageableResource",
    -- Explicit Blueprints to guarantee 100% coverage
    "BP_Spawner_Onion_C",
    "BP_Spawner_Flax_C",
    "BP_Spawner_Cabbage_C",
    "BP_Spawner_Pumpkin_C",
    "BP_Spawner_Pumpkin_02_C",
    "BP_Spawner_Pumpkin_03_C",
    "BP_Spawner_Mushroom_C",
    "BP_Spawner_BittercapMushroom_C",
    "BP_Spawner_Marrentil_C",
    "BP_Spawner_Harralander_C",
    "BP_Spawner_AshBranch_01_C",
    "BP_Spawner_AshBranch_02_C",
    "BP_Spawner_AshBranch_03_C",
    "BP_Spawner_Stone_C",
    "BP_Spawner_Swamp_Tar_C",
    "BP_Spawner_AnimaInfusedBark_C",
    "BP_DwellberryBush_C",
    "BP_RedberryBush_C",
    "BP_CadavaBush_C"
}

-- Helper to get a human-readable name for a harvestable resource actor
local function GetResourceActorName(actor)
    local name = nil
    pcall(function()
        if actor.GetDisplayName then
            local dn = actor:GetDisplayName()
            if dn then name = dn:ToString() end
        end
    end)
    if not name or name == "" then
        pcall(function()
            if actor.DisplayNameOverride then
                name = actor.DisplayNameOverride:ToString()
            end
        end)
    end
    if not name or name == "" then
        pcall(function()
            if actor.ItemData and actor.ItemData:IsValid() and actor.ItemData.ItemName then
                name = actor.ItemData.ItemName:ToString()
            end
        end)
    end
    if not name or name == "" then
        pcall(function()
            name = GetSafeClassName(actor):gsub("^BP_Spawner_", ""):gsub("^BP_", ""):gsub("_C$", "")
        end)
    end
    return name or "Resource"
end

-- Phase 1: Harvest nearby wild resources (onions, dwellberries, flax, pumpkins, branches, stones, herbs)
local function HarvestNearbyResources(pawn, playerLoc, radius)
    local radiusSq = radius * radius
    local seen = {}
    local harvestedCount = 0
    local harvestedSummary = {}

    local pWorld = nil
    pcall(function() pWorld = pawn:GetWorld() end)

    for _, className in ipairs(HarvestableResourceClasses) do
        local ok, actors = pcall(function() return FindAllOf(className) end)
        if ok and actors then
            for _, actor in ipairs(actors) do
                if IsValidWorldActor(actor) then
                    local addr = actor:GetAddress()
                    if not seen[addr] then
                        seen[addr] = true

                        local sameWorld = true
                        if pWorld then
                            pcall(function()
                                local aWorld = actor:GetWorld()
                                if aWorld and aWorld:IsValid() and pWorld:IsValid() then
                                    sameWorld = (aWorld:GetAddress() == pWorld:GetAddress())
                                end
                            end)
                        end

                        if sameWorld then
                            local loc = nil
                            pcall(function() loc = actor:K2_GetActorLocation() end)
                            if loc then
                                local dx = loc.X - playerLoc.X
                                local dy = loc.Y - playerLoc.Y
                                local dz = loc.Z - playerLoc.Z
                                local distSq = dx * dx + dy * dy + dz * dz

                                if distSq <= radiusSq then
                                    -- Check if resource is available (not depleted/already harvested)
                                    local isAvail = true
                                    pcall(function()
                                        if actor.IsResourceAvailable then
                                            isAvail = actor:IsResourceAvailable()
                                        end
                                    end)

                                    if isAvail then
                                        local didHarvest = false

                                        -- Method 1: Plant's InteractionComponent
                                        pcall(function()
                                            local comp = actor.InteractionComponent
                                            if comp and comp:IsValid() then
                                                local canInteract = true
                                                if comp.K2_IsInteractable then
                                                    canInteract = comp:K2_IsInteractable(pawn)
                                                end
                                                if canInteract then
                                                    comp:K2_OnInteraction(pawn)
                                                    didHarvest = true
                                                end
                                            end
                                        end)

                                        -- Method 2 & 3: Actor-level OnInteraction / DropItems / HandleInteraction
                                        pcall(function()
                                            local stillAvail = true
                                            if actor.IsResourceAvailable then
                                                stillAvail = actor:IsResourceAvailable()
                                            else
                                                stillAvail = not didHarvest
                                            end

                                            if stillAvail then
                                                if actor.OnInteraction then
                                                    actor:OnInteraction(pawn)
                                                    didHarvest = true
                                                elseif actor.DropItems then
                                                    local dropped = actor:DropItems(pawn)
                                                    if dropped then didHarvest = true end
                                                elseif actor.HandleInteraction then
                                                    actor:HandleInteraction(pawn)
                                                    didHarvest = true
                                                end
                                            end
                                        end)

                                        -- Method 3: Mark resource unavailable if harvested
                                        pcall(function()
                                            if didHarvest and actor.ForceResourceUnavailable and actor.IsResourceAvailable and actor:IsResourceAvailable() then
                                                actor:ForceResourceUnavailable(pawn)
                                            end
                                        end)

                                        if didHarvest then
                                            harvestedCount = harvestedCount + 1
                                            local rName = GetResourceActorName(actor)
                                            harvestedSummary[rName] = (harvestedSummary[rName] or 0) + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if harvestedCount > 0 and Config.DebugLog then
        local details = {}
        for name, count in pairs(harvestedSummary) do
            table.insert(details, string.format("%dx %s", count, name))
        end
        Log(string.format(">>> [Wild Harvest] Harvested %d resource(s): %s",
            harvestedCount, table.concat(details, ", ")))
    end

    return harvestedCount
end

-- Phase 2: Magnetize all loose WorldItem actors on the ground into the player's inventory
-- allowFullInventory = false leaves items alone when the backpack has no room (no flinging items at the player)
local function MagnetizeWorldItems(pawn, playerLoc, radius, allowFullInventory, maxCount)
    if allowFullInventory == nil then allowFullInventory = true end
    local radiusSq = radius * radius
    local pWorld = nil
    pcall(function() pWorld = pawn:GetWorld() end)

    local okItems, foundItems = pcall(function() return FindAllOf("WorldItem") end)
    if not okItems or not foundItems then return 0 end

    local magnetizedCount = 0
    local magnetizedNames = {}

    for _, actor in ipairs(foundItems) do
        if maxCount and magnetizedCount >= maxCount then break end
        if IsValidWorldActor(actor) then
            local sameWorld = true
            if pWorld then
                pcall(function()
                    local aWorld = actor:GetWorld()
                    if aWorld and aWorld:IsValid() and pWorld:IsValid() then
                        sameWorld = (aWorld:GetAddress() == pWorld:GetAddress())
                    end
                end)
            end

            if sameWorld then
                local loc = nil
                pcall(function() loc = actor:K2_GetActorLocation() end)
                if loc then
                    local dx = loc.X - playerLoc.X
                    local dy = loc.Y - playerLoc.Y
                    local dz = loc.Z - playerLoc.Z
                    local distSq = dx * dx + dy * dy + dz * dz

                    if distSq <= radiusSq then
                        local dist = math.sqrt(distSq)

                        -- Skip if currently manipulated by telekinesis
                        local isManipulated = false
                        pcall(function()
                            if actor.IsBeingManipulated and actor:IsBeingManipulated() then
                                isManipulated = true
                            end
                        end)

                        if not isManipulated then
                            local mag = nil
                            pcall(function()
                                if actor.GetMagneticComponent then
                                    mag = actor:GetMagneticComponent()
                                end
                                if not mag or not mag:IsValid() then
                                    mag = actor.MagneticComponentGrantItem
                                end
                            end)

                            local magnetizedOk = false
                            if mag and mag:IsValid() then
                                local alreadyGranted = false
                                pcall(function() alreadyGranted = mag.bHasBeenGranted end)

                                if not alreadyGranted then
                                    pcall(function()
                                        mag.bAllowAutoMagnetization = true
                                        mag.bAutoMagnetizationEnabled = true
                                        mag.bMagnetizeWithFullInventory = allowFullInventory
                                        mag.MinTimeBeforeMoving = 0.0
                                        mag.ContactRange = 250.0
                                        mag.LerpSpeed = 30.0
                                        mag:BP_MagnetizeToPlayer(pawn, true)
                                        magnetizedOk = true
                                    end)
                                end
                            end

                            -- Close-range interaction fallback
                            if dist < 250.0 then
                                pcall(function()
                                    if actor.HandleInteraction then
                                        actor:HandleInteraction(pawn)
                                    elseif actor.InteractionComponent and actor.InteractionComponent:IsValid() then
                                        actor.InteractionComponent:K2_OnInteraction(pawn)
                                    end
                                end)
                            end

                            if magnetizedOk then
                                magnetizedCount = magnetizedCount + 1
                                local name = GetItemName(actor)
                                magnetizedNames[name] = (magnetizedNames[name] or 0) + 1
                            end
                        end
                    end
                end
            end
        end
    end

    if magnetizedCount > 0 and Config.DebugLog then
        local details = {}
        for name, count in pairs(magnetizedNames) do
            table.insert(details, string.format("%dx %s", count, name))
        end
        Log(string.format(">>> [Ground Magnet] Magnetized %d item(s) towards player! (%s)",
            magnetizedCount, table.concat(details, ", ")))
    end

    return magnetizedCount
end

local function ExecuteGroundMagnetism()
    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) or not IsValidWorldActor(PC.Pawn) then
        return
    end

    local pawn = PC.Pawn
    local playerLoc = nil
    pcall(function() playerLoc = pawn:K2_GetActorLocation() end)
    if not playerLoc then return end

    local radius = Config.GroundMagnetRadius or 4000.0 -- 40 meters

    -- 1. Harvest wild plants, herbs, bushes (onions, dwellberries, flax, etc.)
    HarvestNearbyResources(pawn, playerLoc, radius)

    -- 2. Magnetize existing ground items and items that dropped immediately
    MagnetizeWorldItems(pawn, playerLoc, radius)

    -- 3. Follow-up micro-pulse after 150ms to sweep up any items that took a frame to drop
    LoopAsync(150, function()
        ExecuteInGameThread(function()
            local PC2 = UEHelpers.GetPlayerController()
            if PC2 and PC2:IsValid() and PC2.Pawn and PC2.Pawn:IsValid() then
                local loc2 = nil
                pcall(function() loc2 = PC2.Pawn:K2_GetActorLocation() end)
                if loc2 then
                    MagnetizeWorldItems(PC2.Pawn, loc2, radius)
                end
            end
        end)
        return true -- one-shot timer
    end)
end

-- =========================================================================
-- BASE RELOCATION: PACK UP GROUND ITEMS (Ctrl + G)
-- =========================================================================
local function ExecutePackRelocationCrate()
    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) or not IsValidWorldActor(PC.Pawn) then
        Log("Relocation Pack failed: PlayerController or Character Pawn not ready.")
        return
    end

    local pawn = PC.Pawn
    local playerLoc = nil
    pcall(function() playerLoc = pawn:K2_GetActorLocation() end)
    if not playerLoc then
        Log("Relocation Pack failed: Could not get player location.")
        return
    end

    local radius = Config.RelocationPackRadius or 15000.0 -- 150 meters
    local radiusSq = radius * radius

    local pawnWorld = nil
    pcall(function() pawnWorld = pawn:GetWorld() end)

    local okItems, foundItems = pcall(function() return FindAllOf("WorldItem") end)
    if not okItems or not foundItems then
        Log("Relocation Pack: No WorldItem actors found.")
        return
    end

    local candidateActors = {}
    for _, actor in ipairs(foundItems) do
        if IsValidWorldActor(actor) then
            local sameWorld = true
            if pawnWorld then
                pcall(function()
                    local aWorld = actor:GetWorld()
                    if aWorld and aWorld:IsValid() and pawnWorld:IsValid() then
                        sameWorld = (aWorld:GetAddress() == pawnWorld:GetAddress())
                    end
                end)
            end

            if sameWorld then
                local loc = nil
                pcall(function() loc = actor:K2_GetActorLocation() end)
                if loc then
                    local dx = loc.X - playerLoc.X
                    local dy = loc.Y - playerLoc.Y
                    local dz = loc.Z - playerLoc.Z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= radiusSq then
                        table.insert(candidateActors, actor)
                    end
                end
            end
        end
    end

    if #candidateActors == 0 then
        Log(string.format("Relocation Pack: No ground items found within %.1f meters.", radius / 100.0))
        return
    end

    Log(string.format(">>> PACKING BASE: Found %d ground item stack(s) within %.1f meters! Storing into Relocation Crate...",
        #candidateActors, radius / 100.0))

    local packedStacks = 0
    local totalItemsCount = 0
    local summaryByName = {}

    for _, actor in ipairs(candidateActors) do
        if IsValidWorldActor(actor) then
            local itemData = nil
            pcall(function() itemData = actor.ItemData end)

            if itemData and itemData:IsValid() and itemData:GetAddress() ~= 0 then
                local count = 1
                pcall(function() count = actor:GetStackSize() end)
                if not count or count <= 0 then count = 1 end

                local name = GetItemName(actor)
                local path = nil
                pcall(function() path = itemData:GetPathName() end)

                -- Insert into Relocation Crate
                table.insert(RelocationCrate, {
                    ItemData = itemData,
                    AssetPath = path,
                    Count = count,
                    Name = name
                })

                packedStacks = packedStacks + 1
                totalItemsCount = totalItemsCount + count
                summaryByName[name] = (summaryByName[name] or 0) + count

                -- Safely remove the world item actor from the ground
                pcall(function()
                    actor:K2_DestroyActor()
                end)
            end
        end
    end

    -- Consolidate duplicate entries in the crate to save space
    local consolidated = {}
    for _, entry in ipairs(RelocationCrate) do
        local key = entry.AssetPath or (entry.ItemData and tostring(entry.ItemData:GetAddress())) or entry.Name
        if not consolidated[key] then
            consolidated[key] = {
                ItemData = entry.ItemData,
                AssetPath = entry.AssetPath,
                Count = 0,
                Name = entry.Name
            }
        end
        consolidated[key].Count = consolidated[key].Count + entry.Count
    end

    RelocationCrate = {}
    for _, item in pairs(consolidated) do
        table.insert(RelocationCrate, item)
    end

    -- Format summary for the player
    local breakdown = {}
    for name, cnt in pairs(summaryByName) do
        table.insert(breakdown, string.format("%dx %s", cnt, name))
    end

    Log(string.format(">>> SUCCESS: Packed %d stack(s) (%d total items) into Relocation Crate!", packedStacks, totalItemsCount))
    Log(string.format(">>> Packed contents: %s", table.concat(breakdown, ", ")))
    Log(">>> NEXT STEP: Travel across the map to your new base, place down chests, and press [Shift + G] to unpack everything into your chests!")
end

-- =========================================================================
-- BASE RELOCATION: UNPACK CRATE INTO CHESTS (Shift + G)
-- =========================================================================
local function ExecuteUnpackRelocationCrate()
    if #RelocationCrate == 0 then
        Log("Relocation Crate is empty! Go to your dismantled base and press [Ctrl + G] first to pack up ground items.")
        return
    end

    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) or not IsValidWorldActor(PC.Pawn) then
        Log("Relocation Unpack failed: PlayerController or Character Pawn not ready.")
        return
    end

    local pawn = PC.Pawn
    local playerLoc = nil
    pcall(function() playerLoc = pawn:K2_GetActorLocation() end)
    if not playerLoc then
        Log("Relocation Unpack failed: Could not get player location.")
        return
    end

    local nearbyChests = FindNearbyChests(playerLoc)
    local playerInv = PC.BP_Components_Inventory

    if #nearbyChests == 0 and (not playerInv or not playerInv:IsValid()) then
        Log("Relocation Unpack failed: No chests found nearby (within 25m). Place down chests and stand near them before unpacking!")
        return
    end

    Log(string.format(">>> UNPACKING RELOCATION CRATE: Depositing items into %d nearby chest(s)...", #nearbyChests))

    -- Sort crate items by Category so similar items are unpacked consecutively into matching chests
    table.sort(RelocationCrate, function(a, b)
        local catA = GetItemCategory(a)
        local catB = GetItemCategory(b)
        if catA ~= catB then
            return catA < catB
        end
        return (a.Name or "") < (b.Name or "")
    end)

    local totalItemsDeposited = 0
    local remainingCrate = {}
    local chestsUsed = {}
    local depositedSummary = {}

    for _, entry in ipairs(RelocationCrate) do
        local itemData = ResolveItemData(entry)
        local countRemaining = entry.Count
        local itemName = entry.Name or "Item"
        local itemCat = GetItemCategory(entry)

        if itemData and countRemaining > 0 then
            -- 1. Sort nearby chests for this category (matching dominant chests first, then empty, then others)
            local sortedChests = {}
            for _, ch in ipairs(nearbyChests) do
                local chState = AnalyzeChest(ch)
                local score = (chState.DominantCategory == itemCat and 100 or 0) + (chState.CategoryCounts[itemCat] or 0)
                if chState.TotalItemCount == 0 then score = 50 end
                table.insert(sortedChests, { Chest = ch, Score = score })
            end
            table.sort(sortedChests, function(a, b) return a.Score > b.Score end)

            -- 2. Deposit into nearby chests using native AddItemByData
            for _, cand in ipairs(sortedChests) do
                if countRemaining <= 0 then break end
                local chestInv = cand.Chest.Inventory
                if chestInv and chestInv:IsValid() then
                    local availableSpace = 0
                    pcall(function()
                        availableSpace = chestInv:GetSpaceAvailableForItemByData(itemData)
                    end)

                    if availableSpace > 0 then
                        local toAdd = math.min(countRemaining, availableSpace)
                        local addedOk = false
                        pcall(function()
                            addedOk = chestInv:AddItemByData(itemData, toAdd, 1.0, {})
                        end)

                        if addedOk then
                            countRemaining = countRemaining - toAdd
                            totalItemsDeposited = totalItemsDeposited + toAdd
                            chestsUsed[cand.Chest.Actor:GetAddress()] = true
                            depositedSummary[itemName] = (depositedSummary[itemName] or 0) + toAdd

                            if Config.DebugLog then
                                Log(string.format("Unpacked %dx '%s' into [%s] chest.", toAdd, itemName, itemCat))
                            end
                        end
                    end
                end
            end

            -- 3. If chests are full, deposit into player backpack slots
            if countRemaining > 0 and playerInv and playerInv:IsValid() then
                local pAvailable = 0
                pcall(function()
                    pAvailable = playerInv:GetSpaceAvailableForItemByData(itemData)
                end)

                if pAvailable > 0 then
                    local toAdd = math.min(countRemaining, pAvailable)
                    local addedOk = false
                    pcall(function()
                        addedOk = playerInv:AddItemByData(itemData, toAdd, 1.0, {})
                    end)

                    if addedOk then
                        countRemaining = countRemaining - toAdd
                        totalItemsDeposited = totalItemsDeposited + toAdd
                        depositedSummary[itemName] = (depositedSummary[itemName] or 0) + toAdd

                        if Config.DebugLog then
                            Log(string.format("Chests full: Placed %dx '%s' into player inventory.", toAdd, itemName))
                        end
                    end
                end
            end

            -- 4. If there is still leftover, keep it in the Crate for the next unpack!
            if countRemaining > 0 then
                entry.Count = countRemaining
                table.insert(remainingCrate, entry)
            end
        end
    end

    RelocationCrate = remainingCrate

    local chestCount = 0
    for _ in pairs(chestsUsed) do chestCount = chestCount + 1 end

    local breakdown = {}
    for name, cnt in pairs(depositedSummary) do
        table.insert(breakdown, string.format("%dx %s", cnt, name))
    end

    if #RelocationCrate == 0 then
        Log(string.format(">>> SUCCESS: Fully unpacked %d item(s) into %d chest(s)! Relocation Crate is now empty.",
            totalItemsDeposited, chestCount))
        if #breakdown > 0 then
            Log(string.format(">>> Unpacked: %s", table.concat(breakdown, ", ")))
        end
    else
        local remainingTotal = 0
        for _, rem in ipairs(RelocationCrate) do remainingTotal = remainingTotal + rem.Count end

        Log(string.format(">>> PARTIAL UNPACK: Unpacked %d item(s) into %d chest(s).", totalItemsDeposited, chestCount))
        Log(string.format(">>> ATTENTION: %d item(s) across %d stack(s) remain in the crate because all chests are full! Place down more chests and press [Shift + G] again to finish unpacking.",
            remainingTotal, #RelocationCrate))
    end
end

-- =========================================================================
-- KEYBIND & TAP / HOLD STATE MACHINE
-- =========================================================================
local HoldState = {
    Active = false,  -- True from key-down until G is released (key-repeat events are ignored meanwhile)
    Resolved = true, -- Whether a hovered-item press has been handled as a tap or a hold yet
    PressId = 0,
    LastKeyEvent = 0 -- Time of the latest G key event, including ignored key-repeats
}

-- At base: pull loose ground items into the backpack, then store them in the category chests
local function StoreGroundItems()
    if not Config.StoreGroundItemsAtBase then return end
    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) or not IsValidWorldActor(PC.Pawn) then return end
    local playerInv = PC.BP_Components_Inventory
    if not playerInv or not playerInv:IsValid() then return end
    -- Only pull as many items as the backpack can hold, or they bounce off and stay on the ground
    local freeSlots = CountFreeBackpackSlots(playerInv)
    if freeSlots <= 0 then
        Log("    Ground items left alone: your backpack has no free slot to pick them up.")
        return
    end
    local loc = nil
    pcall(function() loc = PC.Pawn:K2_GetActorLocation() end)
    if not loc then return end

    local pulled = MagnetizeWorldItems(PC.Pawn, loc, Config.GroundMagnetRadius, false, freeSlots)
    if pulled > 0 then
        Log(string.format(">>> Picking up %d ground item(s) to store them (%d free backpack slot(s))...", pulled, freeSlots))
        -- Give the pickups time to land in the backpack, then deposit them into chests
        LoopAsync(1500, function()
            ExecuteInGameThread(function() ExecuteQuickStack(true) end)
            return true -- one-shot timer
        end)
    end
end

-- A normal tap: empty the backpack into chests, sort chests and store ground items at base,
-- or harvest and vacuum in the wild
local function RunTapAction()
    -- Deposit first so the backpack has free slots for sorting and ground pickup
    local foundChests = ExecuteQuickStack(true)
    if foundChests then
        ExecuteQuickStack()
        StoreGroundItems()
    else
        Log(">>> Outside base (no chests nearby): Harvesting & magnetizing ground resources...")
        ExecuteGroundMagnetism()
    end
end

local function OnKeyG()
    HoldState.LastKeyEvent = os.clock()

    -- Ignore OS key-repeat events while G is still held from the last press
    if HoldState.Active then return end

    HoldState.PressId = HoldState.PressId + 1
    local pressId = HoldState.PressId
    local pressTime = os.clock()
    HoldState.Active = true
    HoldState.Resolved = false

    Log(">>> Key [G] pressed!")

    -- Hovering an item in the inventory or a chest: wait to see whether this is a hold (Quick Pull)
    -- or a tap (normal sort). Nothing is moved until that is known.
    local hover = nil
    pcall(function() hover = GetCurrentHoverTarget() end)

    if not hover then
        HoldState.Resolved = true
        RunTapAction()
    end

    -- Poll the real key state every 100ms. Holds are detected by polling, never by timing alone,
    -- so a quick tap never harvests or vacuums at base.
    local lastPulse = 0
    LoopAsync(100, function()
        if HoldState.PressId ~= pressId or not HoldState.Active then return true end
        ExecuteInGameThread(function()
            if HoldState.PressId ~= pressId or not HoldState.Active then return end
            local now = os.clock()
            local elapsed = now - pressTime
            local held = IsGKeyDown(UEHelpers.GetPlayerController())
            if held == nil then
                -- Key state unreadable: G counts as held only while OS key-repeat events keep arriving
                if HoldState.LastKeyEvent > pressTime then
                    held = (now - HoldState.LastKeyEvent) < 0.3
                elseif elapsed < 0.6 then
                    return -- no repeat yet; undecided until the OS repeat delay has passed
                else
                    held = false
                end
            end

            -- Safety cap in case the key state can never be read as released
            if elapsed > 30.0 then held = false end

            if not held then
                HoldState.Active = false
                if not HoldState.Resolved then
                    HoldState.Resolved = true
                    RunTapAction()
                end
                return
            end

            if elapsed < Config.HoldDuration then return end

            if hover then
                if not HoldState.Resolved then
                    HoldState.Resolved = true
                    Log(string.format(">>> [Hold G] Quick Pull: '%s'", tostring(hover.Name)))
                    ExecuteQuickPull(hover)
                end
            elseif (now - lastPulse) >= 0.20 then
                lastPulse = now
                ExecuteGroundMagnetism()
            end
        end)
        return HoldState.PressId ~= pressId or not HoldState.Active
    end)
end

-- Keybind Registration: Normal G (Tap = Quick Stack, Hold over an item = Quick Pull, Hold elsewhere = Ground Magnetism)
local keyCallback = function()
    ExecuteInGameThread(function()
        OnKeyG()
    end)
end

local okBind, errBind = pcall(function()
    if Config.Modifier then
        RegisterKeyBind(Config.Key, { Config.Modifier }, keyCallback)
    else
        RegisterKeyBind(Config.Key, keyCallback)
    end
end)

if okBind then
    Log(string.format("Keybind registered: [%s] -> Tap = Quick Stack, Hold over item = Quick Pull, Hold = Ground Magnetism.", "G"))
else
    Log("ERROR registering keybind [G]: " .. tostring(errBind))
end

-- Keybind Registration: Ctrl + G -> Pack up ground items into Relocation Crate
pcall(function()
    RegisterKeyBind(Config.Key, { ModifierKey.CONTROL }, function()
        ExecuteInGameThread(ExecutePackRelocationCrate)
    end)
    Log("Keybind registered: [Ctrl + G] -> Pack Base into Relocation Crate.")
end)

-- Keybind Registration: Shift + G -> Unpack Relocation Crate into nearby chests
pcall(function()
    RegisterKeyBind(Config.Key, { ModifierKey.SHIFT }, function()
        ExecuteInGameThread(ExecuteUnpackRelocationCrate)
    end)
    Log("Keybind registered: [Shift + G] -> Unpack Relocation Crate into nearby chests.")
end)

-- Keybind Registration: Alt + G -> Fetch ingredients for the open crafting station (or pull the hovered item)
pcall(function()
    RegisterKeyBind(Config.Key, { ModifierKey.ALT }, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(ExecuteStationFetch)
            if not ok then Log("Station Fetch error: " .. tostring(err)) end
        end)
    end)
    Log("Keybind registered: [Alt + G] -> Fetch ingredients for the open station / pull hovered item from chests.")
end)

-- Keybind Registration: Shift + F12 -> Toggle floating chest category labels
pcall(function()
    RegisterKeyBind(Key.F12, { ModifierKey.SHIFT }, function()
        ExecuteInGameThread(function() pcall(ToggleChestLabels) end)
    end)
    Log("Keybind registered: [Shift + F12] -> Toggle chest category labels.")
end)


return {
    ExecuteQuickStack = ExecuteQuickStack,
    ExecuteQuickPull = ExecuteQuickPull,
    ExecuteGroundMagnetism = ExecuteGroundMagnetism,
    ExecutePackRelocationCrate = ExecutePackRelocationCrate,
    ExecuteUnpackRelocationCrate = ExecuteUnpackRelocationCrate,
    ExecuteStationFetch = ExecuteStationFetch,
    RelocationCrate = RelocationCrate,
    Config = Config
}
