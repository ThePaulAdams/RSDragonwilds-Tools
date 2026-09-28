local UEHelpers = require("UEHelpers")

local ModName = "QuickStack"

local Config = {
    -- Keybind to activate Quick Stack / Ground Magnetism
    Key = Key.G,
    Modifier = nil, -- Optional modifier key, e.g. ModifierKey.CONTROL or nil for just G

    -- Maximum distance (in Unreal Units) to search for chests. 6000 uu = 60 meters.
    SearchRadius = 6000.0,

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

    -- Hold duration (in seconds) to trigger Ground Item Magnetism
    HoldDuration = 0.25,

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
Log("==========================================")

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
            name = item.ItemData:GetName()
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
    FOOD = "FOOD",           -- Raw/cooked food, meat, fish, bread, berries, drinks, potions
    WOOD = "WOOD",           -- Logs, planks, bark, timber, splinters, charcoal
    MINING = "MINING",       -- Ores, ingots/bars, stone, clay, gems, minerals
    FARMING = "FARMING",     -- Plants, flax, seeds, herbs, fibers, textiles, leather, cloth
    MAGIC = "MAGIC",         -- Runes, essence, shards, anima, scrolls
    EQUIPMENT = "EQUIPMENT", -- Weapons, armor, tools, accessories, capes
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
        pcall(function() className = itemData:GetClass():GetName():lower() end)
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

    -- 1. Check Class Type
    if className:find("food") or className:find("drink") or className:find("potion") or className:find("consumable") then
        return ItemCategories.FOOD
    end
    if className:find("wardstone") or className:find("whetstone") or className:find("trinket") then
        return ItemCategories.EQUIPMENT
    end

    -- 2. Check Asset Path
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
            return ItemCategories.EQUIPMENT
        end
    end

    -- 3. Check GameplayTag
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
            return ItemCategories.EQUIPMENT
        end
    end

    -- 4. Check Display Name Keywords
    if name ~= "" then
        -- Food keywords
        if name:find("meat") or name:find("fish") or name:find("bread") or name:find("stew") or
           name:find("soup") or name:find("berry") or name:find("berries") or name:find("dwellberry") or
           name:find("dwellberries") or name:find("apple") or name:find("pie") or name:find("cake") or
           name:find("ration") or name:find("cabbage") or name:find("potato") or name:find("onion") or
           name:find("mushroom") or name:find("cooked") or name:find("raw") or name:find("burnt") or
           name:find("drink") or name:find("potion") or name:find("brew") or name:find("ale") or
           name:find("beer") or name:find("wine") or name:find("water") or name:find("tea") or
           name:find("food") or name:find("egg") or name:find("cheese") then
            return ItemCategories.FOOD
        end

        -- Wood keywords
        if name:find("wood") or name:find("log") or name:find("logs") or name:find("plank") or
           name:find("planks") or name:find("bark") or name:find("branch") or name:find("timber") or
           name:find("splinter") or name:find("charcoal") or name:find("ash") then
            return ItemCategories.WOOD
        end

        -- Mining / Metal keywords
        if name:find("ore") or name:find("bar") or name:find("bars") or name:find("ingot") or
           name:find("stone") or name:find("rock") or name:find("clay") or name:find("sand") or
           name:find("copper") or name:find("tin") or name:find("bronze") or name:find("iron") or
           name:find("steel") or name:find("mithril") or name:find("adamant") or name:find("runite") or
           name:find("gold") or name:find("silver") or name:find("coal") or name:find("sapphire") or
           name:find("emerald") or name:find("ruby") or name:find("diamond") then
            return ItemCategories.MINING
        end

        -- Farming / Herbs / Textiles keywords
        if name:find("flax") or name:find("fiber") or name:find("fibre") or name:find("seed") or
           name:find("herb") or name:find("plant") or name:find("leaf") or name:find("leaves") or
           name:find("toadflax") or name:find("thread") or name:find("cloth") or name:find("linen") or
           name:find("leather") or name:find("wool") or name:find("feather") or name:find("pelt") or
           name:find("hide") or name:find("flower") or name:find("wheat") or name:find("cotton") then
            return ItemCategories.FARMING
        end

        -- Magic keywords
        if name:find("rune") or name:find("essence") or name:find("shard") or name:find("anima") or
           name:find("scroll") or name:find("tome") or name:find("talisman") or name:find("reagent") then
            return ItemCategories.MAGIC
        end

        -- Equipment & Armour keywords
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
           name:find("torso") or name:find("buckler") or name:find("quiver") then
            return ItemCategories.EQUIPMENT
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
            className = item.ItemData:GetClass():GetName():lower()
        elseif item.GetClass then
            className = item:GetClass():GetName():lower()
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
    local className = ""
    pcall(function() className = actor:GetClass():GetName():lower() end)
    local actorName = ""
    pcall(function() actorName = actor:GetName():lower() end)

    -- STRICT BLACKLIST: Never touch any crafting stations, processors, furnaces, or utility actors!
    local disallowedKeywords = {
        "furnace", "smelter", "kiln", "campfire", "fire", "range", "cook",
        "cauldron", "bench", "anvil", "wheel", "station", "crafting",
        "grinder", "sawmill", "loom", "stonecutter", "tanning", "brew",
        "pottery", "altar", "vent", "spawner", "pawn", "character", "npc",
        "enemy", "bedroll", "lodestone", "torch", "light"
    }
    for _, kw in ipairs(disallowedKeywords) do
        if className:find(kw) or actorName:find(kw) then
            return false
        end
    end

    -- Allowed storage keywords
    if className:find("chest") or className:find("crate") or className:find("storage")
       or className:find("rack") or className:find("stand") or className:find("mannequin")
       or className:find("wardrobe") or className:find("coffer") or className:find("trunk") then
        return true
    end

    if actorName:find("chest") or actorName:find("crate") or actorName:find("storage")
       or actorName:find("rack") or actorName:find("stand") or actorName:find("mannequin") then
        return true
    end

    return false
end

-- Helper: Find all chests within SearchRadius, sorted closest first
local function FindNearbyChests(playerLoc)
    local maxRadiusSq = Config.SearchRadius * Config.SearchRadius
    local nearbyChests = {}
    local seenAddresses = {}

    local function RegisterCandidate(chestActor, chestInv)
        if not chestActor or not chestInv or not chestInv:IsValid() then return end
        local addr = chestActor:GetAddress()
        if seenAddresses[addr] then return end

        if not IsChestActor(chestActor) then return end

        local loc = nil
        pcall(function() loc = chestActor:K2_GetActorLocation() end)
        if not loc then return end

        local dx = loc.X - playerLoc.X
        local dy = loc.Y - playerLoc.Y
        local dz = loc.Z - playerLoc.Z
        local distSq = dx * dx + dy * dy + dz * dz

        if distSq <= maxRadiusSq then
            seenAddresses[addr] = true
            local actorClass = ""
            pcall(function() actorClass = chestActor:GetClass():GetName():lower() end)
            local preferredCat = nil
            if actorClass:find("armour") or actorClass:find("armor") or actorClass:find("rack") or actorClass:find("mannequin") or actorClass:find("stand") then
                preferredCat = ItemCategories.EQUIPMENT
            elseif actorClass:find("lumber") or actorClass:find("wood") then
                preferredCat = ItemCategories.WOOD
            end

            table.insert(nearbyChests, {
                Actor = chestActor,
                Inventory = chestInv,
                Distance = math.sqrt(distSq),
                PreferredCategory = preferredCat,
                ActorName = actorClass
            })
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
local function IsGKeyDown(PC)
    if not PC or not PC:IsValid() then return false end
    local ok, res = pcall(function()
        return PC:IsInputKeyDown({ KeyName = FName("G") })
    end)
    return ok and res
end

-- =========================================================================
-- CHEST INVENTORY ANALYSIS & INTER-CHEST REORGANIZATION
-- =========================================================================
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
    state.DominantCategory = maxCat
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
-- IN-MEMORY CHEST UPGRADE & CATEGORY REORGANIZATION ENGINE
-- =========================================================================
local function ReorganizeNearbyChests(chestStates, PC, playerInv)
    if not chestStates or #chestStates < 1 then return 0 end

    Log(string.format(">>> Starting In-Memory Chest Consolidation & Upgrade across %d chest(s)...", #chestStates))

    -- 1. UPGRADE ALL CHESTS TO HIGHEST TIER (48 SLOTS)
    local largeMesh = nil
    for _, state in ipairs(chestStates) do
        if state.SlotCount >= 48 and state.Actor and state.Actor.Mesh then
            pcall(function() largeMesh = state.Actor.Mesh.StaticMesh end)
            if largeMesh then break end
        end
    end
    if not largeMesh then
        pcall(function()
            largeMesh = StaticFindObject("/Game/Art/Env/Base_Building/Furniture/Cosiness/Chest/SM_Storage_Chest_01v2.SM_Storage_Chest_01v2")
        end)
    end

    local upgradedCount = 0
    for _, state in ipairs(chestStates) do
        pcall(function()
            if state.Inventory and state.Inventory:IsValid() then
                if (state.Inventory.MaxSlotCount or 0) < 48 then
                    state.Inventory.MaxSlotCount = 48
                    state.SlotCount = 48
                    upgradedCount = upgradedCount + 1
                end
            end
            if largeMesh and state.Actor and state.Actor.Mesh and state.Actor.Mesh:IsValid() then
                state.Actor.Mesh:SetStaticMesh(largeMesh)
            end
        end)
    end
    if upgradedCount > 0 then
        Log(string.format("    Upgraded %d chest(s) to Highest Tier (48 Slots each)!", upgradedCount))
    end

    -- 2. PULL ALL ITEMS FROM CHESTS INTO IN-MEMORY POOL
    -- Merge identical items by ItemData + Durability so split stacks combine into full stacks!
    local memoryPool = {} -- [key] = { ItemData, Name, TotalCount, Durability, Category }
    local categoryTotals = {}
    for _, cat in pairs(ItemCategories) do categoryTotals[cat] = 0 end

    local totalItemsInPool = 0
    local totalStacksRead = 0

    for _, state in ipairs(chestStates) do
        local inv = state.Inventory
        local slotCount = 0
        pcall(function() slotCount = inv.ItemSlots:GetArrayNum() end)
        for cIdx = 1, slotCount do
            local cItem = nil
            pcall(function() cItem = inv.ItemSlots[cIdx] end)
            if IsValidItem(cItem) then
                local itemData = nil
                pcall(function() itemData = cItem.ItemData end)
                if itemData and itemData:IsValid() then
                    local count = 0
                    pcall(function() count = cItem:GetStackSize() end)
                    if count > 0 then
                        local durability = 1.0
                        pcall(function() durability = cItem:GetDurability() or 1.0 end)
                        local name = GetItemName(cItem)
                        local category = GetItemCategory(cItem)
                        local dataAddr = GetItemDataAddress(cItem)

                        local key = string.format("%s_%.2f", tostring(dataAddr), durability)
                        if memoryPool[key] then
                            memoryPool[key].TotalCount = memoryPool[key].TotalCount + count
                        else
                            memoryPool[key] = {
                                ItemData = itemData,
                                Name = name,
                                TotalCount = count,
                                Durability = durability,
                                Category = category,
                                Key = key
                            }
                        end

                        categoryTotals[category] = (categoryTotals[category] or 0) + count
                        totalItemsInPool = totalItemsInPool + count
                        totalStacksRead = totalStacksRead + 1
                    end
                end
            end
        end
    end

    if totalItemsInPool == 0 then
        Log("    Chests are currently empty. Nothing to reorganize.")
        return 0
    end

    Log(string.format("    Pulled %d total items (%d original stacks) into In-Memory Buffer.",
        totalItemsInPool, totalStacksRead))

    -- 3. CLEAR ALL CHESTS VIA NATIVE ClearInventory()
    for _, state in ipairs(chestStates) do
        pcall(function()
            state.Inventory:ClearInventory()
        end)
        state.EmptySlots = {}
        for s = 0, 47 do table.insert(state.EmptySlots, s) end
        state.Slots = {}
        state.TotalItemCount = 0
    end

    -- 4. ASSIGN DEDICATED CHESTS TO CATEGORIES
    local assignedChestsByCategory = {}
    for _, cat in pairs(ItemCategories) do assignedChestsByCategory[cat] = {} end
    local claimedAddrs = {}

    -- Priority A: Containers with explicit preferred category (Armour racks -> EQUIPMENT, Lumber -> WOOD)
    for _, state in ipairs(chestStates) do
        if state.PreferredCategory and not claimedAddrs[state.Address] then
            local cat = state.PreferredCategory
            claimedAddrs[state.Address] = cat
            state.AssignedCategory = cat
            table.insert(assignedChestsByCategory[cat], state)
        end
    end

    -- Priority B: Sort categories by total item count descending
    local sortedCats = {}
    for cat, total in pairs(categoryTotals) do
        if total > 0 then table.insert(sortedCats, { Category = cat, Total = total }) end
    end
    table.sort(sortedCats, function(a, b) return a.Total > b.Total end)

    -- Assign Primary Chest to each active category
    for _, cInfo in ipairs(sortedCats) do
        local cat = cInfo.Category
        if #assignedChestsByCategory[cat] == 0 then
            for _, state in ipairs(chestStates) do
                if not claimedAddrs[state.Address] then
                    claimedAddrs[state.Address] = cat
                    state.AssignedCategory = cat
                    table.insert(assignedChestsByCategory[cat], state)
                    break
                end
            end
        end
    end

    -- If a category has more than 48 items, assign additional secondary chest(s)
    for _, cInfo in ipairs(sortedCats) do
        local cat = cInfo.Category
        local neededChests = math.ceil(cInfo.Total / 48)
        while #assignedChestsByCategory[cat] < neededChests do
            local found = false
            for _, state in ipairs(chestStates) do
                if not claimedAddrs[state.Address] then
                    claimedAddrs[state.Address] = cat
                    state.AssignedCategory = cat
                    table.insert(assignedChestsByCategory[cat], state)
                    found = true
                    break
                end
            end
            if not found then break end
        end
    end

    -- Any remaining chests are overflow
    local overflowChests = {}
    for _, state in ipairs(chestStates) do
        if not claimedAddrs[state.Address] then
            table.insert(overflowChests, state)
        end
    end

    -- 5. SORT MEMORY ITEMS: GROUP BY CATEGORY, ALPHABETICAL BY NAME
    local categoryItemLists = {}
    for _, cat in pairs(ItemCategories) do categoryItemLists[cat] = {} end
    for _, entry in pairs(memoryPool) do
        local cat = entry.Category or ItemCategories.MISC
        if not categoryItemLists[cat] then categoryItemLists[cat] = {} end
        table.insert(categoryItemLists[cat], entry)
    end

    for _, cat in pairs(ItemCategories) do
        table.sort(categoryItemLists[cat], function(a, b) return a.Name < b.Name end)
    end

    -- 6. REDISTRIBUTE ITEMS FROM MEMORY BUFFER INTO MATCHING DEDICATED CHESTS
    local totalRestored = 0

    for _, cat in pairs(ItemCategories) do
        local items = categoryItemLists[cat]
        local chests = assignedChestsByCategory[cat] or {}
        local chestIdx = 1

        for _, entry in ipairs(items) do
            local remaining = entry.TotalCount
            local maxStack = 1
            pcall(function()
                if entry.ItemData.GetMaxStackSize then
                    maxStack = entry.ItemData:GetMaxStackSize()
                elseif entry.ItemData.MaxStackSize then
                    maxStack = entry.ItemData.MaxStackSize
                end
            end)
            if not maxStack or maxStack <= 0 then maxStack = 100 end

            while remaining > 0 do
                local targetChest = chests[chestIdx]
                if not targetChest and #overflowChests > 0 then
                    targetChest = table.remove(overflowChests, 1)
                    table.insert(chests, targetChest)
                end

                local toAdd = math.min(remaining, maxStack)

                if not targetChest then
                    -- All base chests completely full! Safe fallback: deposit into player backpack
                    if playerInv and playerInv:IsValid() then
                        local addedP = false
                        pcall(function()
                            addedP = playerInv:AddItemByData(entry.ItemData, toAdd, entry.Durability, {})
                        end)
                        if addedP then
                            totalRestored = totalRestored + toAdd
                            remaining = remaining - toAdd
                            Log(string.format("    Chests full: Stored %dx '%s' into player inventory.", toAdd, entry.Name))
                        else
                            Log(string.format("    CRITICAL: No room anywhere for %dx '%s'!", remaining, entry.Name))
                            break
                        end
                    else
                        Log(string.format("    CRITICAL: No room anywhere for %dx '%s'!", remaining, entry.Name))
                        break
                    end
                else
                    local addedOk = false
                    pcall(function()
                        addedOk = targetChest.Inventory:AddItemByData(entry.ItemData, toAdd, entry.Durability, {})
                    end)

                    if addedOk then
                        remaining = remaining - toAdd
                        totalRestored = totalRestored + toAdd
                        targetChest.TotalItemCount = (targetChest.TotalItemCount or 0) + 1
                    else
                        -- Target chest full, advance to next chest for this category
                        chestIdx = chestIdx + 1
                    end
                end
            end
        end
    end

    Log(string.format(">>> Memory-Buffered Reorganization COMPLETE: %d item(s) restored into perfectly sorted 48-slot chests.", totalRestored))
    return totalRestored
end

-- =========================================================================
-- EXECUTE QUICK STACK (Deposit matching & categorized items to chests)
-- =========================================================================
local function ExecuteQuickStack()
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
    if Config.OrganizeNearbyChests and #chestStates >= 1 then
        local reorganizedCount = ReorganizeNearbyChests(chestStates, PC, playerInv)
        if reorganizedCount > 0 and Config.DebugLog then
            Log(string.format("Organized %d misplaced item(s) between chests into matching categories.", reorganizedCount))
        end
        -- Re-analyze to have fresh slot tracking after reorganization
        chestStates = {}
        for _, chestEntry in ipairs(nearbyChests) do
            table.insert(chestStates, AnalyzeChest(chestEntry))
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
-- EXECUTE QUICK PULL (Retrieve matching items from chests into player inventory)
-- =========================================================================
local function ExecuteQuickPull(target)
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
            name = actor:GetClass():GetName():gsub("^BP_Spawner_", ""):gsub("^BP_", ""):gsub("_C$", "")
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
local function MagnetizeWorldItems(pawn, playerLoc, radius)
    local radiusSq = radius * radius
    local pWorld = nil
    pcall(function() pWorld = pawn:GetWorld() end)

    local okItems, foundItems = pcall(function() return FindAllOf("WorldItem") end)
    if not okItems or not foundItems then return 0 end

    local magnetizedCount = 0
    local magnetizedNames = {}

    for _, actor in ipairs(foundItems) do
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
                                        mag.bMagnetizeWithFullInventory = true
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
    PressTime = 0,
    LastMagnetPulse = 0
}

local function OnKeyG()
    local now = os.clock()
    local timeSinceLast = now - HoldState.PressTime

    -- If this is an OS typematic repeat (fired rapidly after holding G for > 0.25s):
    if timeSinceLast < 0.6 and HoldState.PressTime > 0 then
        -- Key is being HELD!
        if (now - HoldState.LastMagnetPulse) >= 0.20 then
            HoldState.LastMagnetPulse = now
            ExecuteGroundMagnetism()
        end
        return
    end

    -- Fresh key press!
    HoldState.PressTime = now
    HoldState.LastMagnetPulse = 0

    Log(">>> Key [G] pressed!")

    -- 1. Check if nearby chests exist to quick-stack & sort
    local foundChests = ExecuteQuickStack()

    -- 2. If NO chests found nearby (outside base), execute Ground Gathering & Magnetism immediately!
    if not foundChests then
        Log(">>> Outside base (no chests nearby): Harvesting & magnetizing ground resources...")
        ExecuteGroundMagnetism()
    else
        -- If at base, schedule Ground Magnetism if the user holds G past 250ms
        local pressTimestamp = now
        LoopAsync(250, function()
            if HoldState.PressTime ~= pressTimestamp then return true end
            ExecuteInGameThread(function()
                if HoldState.PressTime == pressTimestamp then
                    ExecuteGroundMagnetism()
                end
            end)
            return true -- one-shot timer
        end)
    end
end

-- Keybind Registration: Normal G (Tap = Quick Stack, Hold on Item = Quick Pull)
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
    Log(string.format("Keybind registered: [%s] -> Tap = Quick Stack, Hold = Ground Magnetism.", "G"))
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


return {
    ExecuteQuickStack = ExecuteQuickStack,
    ExecuteQuickPull = ExecuteQuickPull,
    ExecuteGroundMagnetism = ExecuteGroundMagnetism,
    ExecutePackRelocationCrate = ExecutePackRelocationCrate,
    ExecuteUnpackRelocationCrate = ExecuteUnpackRelocationCrate,
    RelocationCrate = RelocationCrate,
    Config = Config
}
