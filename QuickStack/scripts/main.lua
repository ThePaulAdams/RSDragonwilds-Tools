local UEHelpers = require("UEHelpers")

local ModName = "QuickStack"

local Config = {
    -- Keybind to activate Quick Stack / Quick Pull
    Key = Key.G,
    Modifier = nil, -- Optional modifier key, e.g. ModifierKey.CONTROL or nil for just G

    -- Maximum distance (in Unreal Units) to search for chests. 2500 uu = 25 meters.
    SearchRadius = 2500.0,

    -- Maximum distance (in Unreal Units) to pack up ground items into Relocation Crate. 15000 uu = 150 meters.
    RelocationPackRadius = 15000.0,

    -- Protect the player's quick-action hotbar slots from being deposited.
    ProtectHotbar = true,

    -- QuickStack (Deposit): If true, creates new stacks in a chest as long as the chest already has that item.
    -- If false, only tops-off existing non-full stacks in the chest.
    OverflowToEmptySlots = false,

    -- Hold duration (in seconds) to trigger Quick Pull (retrieval from chests)
    HoldDuration = 0.35,

    -- Print detailed information to the console log
    DebugLog = true
}

local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing QuickStack Mod with Relocation Crate...")
Log("  [Tap G]    : Quick-stack matching items into nearby chests.")
Log("  [Hold G]   : Hover over any item (in inventory or chest) to pull all matching items from nearby chests!")
Log("  [Ctrl + G] : PACK BASE -> Store all ground items within 150m into your virtual Relocation Crate!")
Log("  [Shift + G]: UNPACK BASE -> Deposit all Relocation Crate items into nearby chests at your new base!")
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
        local world = actor:GetWorld()
        if not world or not world:IsValid() then return false end
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

-- Helper: Find all chests within SearchRadius, sorted closest first
local function FindNearbyChests(playerLoc)
    local maxRadiusSq = Config.SearchRadius * Config.SearchRadius
    local nearbyChests = {}
    local seenAddresses = {}

    local function RegisterCandidate(chestActor, chestInv)
        if not IsValidWorldActor(chestActor) or not chestInv or not chestInv:IsValid() then return end
        local addr = chestActor:GetAddress()
        if seenAddresses[addr] then return end

        local loc = nil
        pcall(function() loc = chestActor:K2_GetActorLocation() end)
        if not loc then return end

        local dx = loc.X - playerLoc.X
        local dy = loc.Y - playerLoc.Y
        local dz = loc.Z - playerLoc.Z
        local distSq = dx * dx + dy * dy + dz * dz

        if distSq <= maxRadiusSq then
            seenAddresses[addr] = true
            table.insert(nearbyChests, {
                Actor = chestActor,
                Inventory = chestInv,
                Distance = math.sqrt(distSq)
            })
        end
    end

    -- Scan method A: Find all BP_BaseBuilding_Chest_C actors
    local okChests, chestActors = pcall(function()
        return FindAllOf("BP_BaseBuilding_Chest_C")
    end)
    if okChests and chestActors then
        for _, actor in ipairs(chestActors) do
            if IsValidWorldActor(actor) then
                local inv = actor.BP_Components_WorldItemInventory
                if inv and inv:IsValid() then
                    RegisterCandidate(actor, inv)
                end
            end
        end
    end

    -- Scan method B: Find any remaining world inventory components
    local okComps, allComps = pcall(function()
        return FindAllOf("BP_Components_WorldItemInventory_C")
    end)
    if okComps and allComps then
        for _, comp in ipairs(allComps) do
            if IsValidWorldInventory(comp) then
                local owner = nil
                pcall(function() owner = comp:GetOwner() end)
                if owner and IsValidWorldActor(owner) then
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
-- EXECUTE QUICK STACK (Deposit matching items from player inventory to chests)
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
        Log(string.format("No chests found within %.1f meters.", Config.SearchRadius / 100.0))
        return
    end

    if Config.DebugLog then
        Log(string.format("Found %d nearby chest(s). Starting quick stack...", #nearbyChests))
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
        return
    end

    local totalItemsMoved = 0
    local depositedItemsSummary = {}
    local affectedChests = {}

    for _, entry in ipairs(nearbyChests) do
        local chestInv = entry.Inventory
        local chestActor = entry.Actor

        local chestItemDataMap = {}
        local chestTargetSlots = {}
        local chestEmptySlots = {}

        local chestSlotCount = 0
        pcall(function() chestSlotCount = chestInv.ItemSlots:GetArrayNum() end)

        for cIdx = 1, chestSlotCount do
            local cSlotZero = cIdx - 1
            local cItem = nil
            pcall(function() cItem = chestInv.ItemSlots[cIdx] end)

            if IsValidItem(cItem) then
                local dataAddr = GetItemDataAddress(cItem)
                if dataAddr then
                    chestItemDataMap[dataAddr] = true

                    local freeSpace = 0
                    pcall(function() freeSpace = cItem:GetStackFreeSpace() end)
                    if freeSpace > 0 then
                        if not chestTargetSlots[dataAddr] then
                            chestTargetSlots[dataAddr] = {}
                        end
                        table.insert(chestTargetSlots[dataAddr], {
                            SlotZero = cSlotZero,
                            FreeSpace = freeSpace,
                            Item = cItem
                        })
                    end
                end
            else
                table.insert(chestEmptySlots, cSlotZero)
            end
        end

        local hasItems = false
        for _ in pairs(chestItemDataMap) do
            hasItems = true
            break
        end

        if hasItems then
            for pIdx = hotbarCount + 1, playerSlotCount do
                local pSlotZero = pIdx - 1
                local pItem = nil
                pcall(function() pItem = playerInv.ItemSlots[pIdx] end)

                if IsValidItem(pItem) then
                    local pDataAddr = GetItemDataAddress(pItem)
                    local pCount = 0
                    pcall(function() pCount = pItem:GetStackSize() end)

                    if pDataAddr and chestItemDataMap[pDataAddr] and pCount > 0 then
                        local itemName = GetItemName(pItem)

                        -- A: Fill existing non-full stacks
                        local targets = chestTargetSlots[pDataAddr]
                        if targets then
                            for _, target in ipairs(targets) do
                                if pCount <= 0 then break end
                                if target.FreeSpace > 0 then
                                    local moveAmount = math.min(pCount, target.FreeSpace)
                                    local movedOk = false
                                    pcall(function()
                                        movedOk = playerInv:MoveItem(pSlotZero, chestInv, target.SlotZero, PC, moveAmount)
                                    end)

                                    if movedOk then
                                        pCount = pCount - moveAmount
                                        target.FreeSpace = target.FreeSpace - moveAmount
                                        totalItemsMoved = totalItemsMoved + moveAmount
                                        depositedItemsSummary[itemName] = (depositedItemsSummary[itemName] or 0) + moveAmount
                                        affectedChests[chestActor:GetAddress()] = true

                                        if Config.DebugLog then
                                            Log(string.format("Stacked %dx '%s' into chest slot %d.", moveAmount, itemName, target.SlotZero))
                                        end
                                    end
                                end
                            end
                        end

                        -- B: Overflow to empty slots if enabled
                        if pCount > 0 and Config.OverflowToEmptySlots and #chestEmptySlots > 0 then
                            local emptySlotZero = table.remove(chestEmptySlots, 1)
                            local moveAmount = pCount
                            local movedOk = false
                            pcall(function()
                                movedOk = playerInv:MoveItem(pSlotZero, chestInv, emptySlotZero, PC, moveAmount)
                            end)

                            if movedOk then
                                totalItemsMoved = totalItemsMoved + moveAmount
                                depositedItemsSummary[itemName] = (depositedItemsSummary[itemName] or 0) + moveAmount
                                affectedChests[chestActor:GetAddress()] = true
                                pCount = 0

                                if Config.DebugLog then
                                    Log(string.format("Overflowed %dx '%s' into empty chest slot %d.", moveAmount, itemName, emptySlotZero))
                                end
                            end
                        end
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

    local pawnLevel = nil
    pcall(function() pawnLevel = pawn:GetLevel() end)

    local okItems, foundItems = pcall(function() return FindAllOf("WorldItem") end)
    if not okItems or not foundItems then
        Log("Relocation Pack: No WorldItem actors found.")
        return
    end

    local candidateActors = {}
    for _, actor in ipairs(foundItems) do
        if IsValidWorldActor(actor) then
            local sameLevel = true
            if pawnLevel then
                pcall(function()
                    local aLevel = actor:GetLevel()
                    if aLevel and aLevel:IsValid() and pawnLevel:IsValid() then
                        sameLevel = (aLevel:GetAddress() == pawnLevel:GetAddress())
                    end
                end)
            end

            if sameLevel then
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

    local totalItemsDeposited = 0
    local remainingCrate = {}
    local chestsUsed = {}
    local depositedSummary = {}

    for _, entry in ipairs(RelocationCrate) do
        local itemData = ResolveItemData(entry)
        local countRemaining = entry.Count
        local itemName = entry.Name or "Item"

        if itemData and countRemaining > 0 then
            -- 1. Deposit into nearby chests using native AddItemByData
            for _, chest in ipairs(nearbyChests) do
                if countRemaining <= 0 then break end
                local chestInv = chest.Inventory
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
                            chestsUsed[chest.Actor:GetAddress()] = true
                            depositedSummary[itemName] = (depositedSummary[itemName] or 0) + toAdd

                            if Config.DebugLog then
                                Log(string.format("Unpacked %dx '%s' into chest.", toAdd, itemName))
                            end
                        end
                    end
                end
            end

            -- 2. If chests are full, deposit into player backpack slots
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

            -- 3. If there is still leftover, keep it in the Crate for the next unpack!
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
    IsActive = false,
    PressTime = 0,
    Target = nil,
    TriggeredPull = false,
    RepeatCount = 0
}

local function OnKeyG()
    local now = os.clock()

    -- Case 1: Key is currently being held and OS typematic repeat is firing
    if HoldState.IsActive and (now - HoldState.PressTime < 1.0) then
        HoldState.RepeatCount = HoldState.RepeatCount + 1
        if not HoldState.TriggeredPull and HoldState.Target then
            HoldState.TriggeredPull = true
            ExecuteQuickPull(HoldState.Target)
        end
        return
    end

    -- Case 2: Fresh key press. Check if an item is currently hovered under the cursor
    local hoverTarget = GetCurrentHoverTarget()

    -- If no item is hovered, execute normal QuickStack immediately with ZERO delay
    if not hoverTarget then
        HoldState.IsActive = false
        HoldState.Target = nil
        ExecuteQuickStack()
        return
    end

    -- An item IS hovered! Start hold detection
    HoldState.IsActive = true
    HoldState.PressTime = now
    HoldState.Target = hoverTarget
    HoldState.TriggeredPull = false
    HoldState.RepeatCount = 0

    local pressTimestamp = now

    -- Run asynchronous hold checker
    LoopAsync(40, function()
        local elapsed = os.clock() - pressTimestamp

        if elapsed < Config.HoldDuration then
            return false -- Keep checking until hold threshold is reached
        end

        -- Hold threshold reached! Check if this hold state is still current
        if HoldState.PressTime == pressTimestamp and not HoldState.TriggeredPull then
            local PC = UEHelpers.GetPlayerController()
            local keyStillDown = IsGKeyDown(PC)

            if keyStillDown or HoldState.RepeatCount >= 1 then
                -- Key was held! Execute Quick Pull
                HoldState.TriggeredPull = true
                ExecuteInGameThread(function()
                    ExecuteQuickPull(HoldState.Target)
                end)
            else
                -- Key was released before hold threshold! Treat as a normal QuickStack tap
                ExecuteInGameThread(function()
                    ExecuteQuickStack()
                end)
            end
        end

        -- Reset hold state after 500ms and stop the loop
        if elapsed >= 0.50 then
            HoldState.IsActive = false
            return true -- Stop LoopAsync
        end

        return false
    end)
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
    Log(string.format("Keybind registered: [%s] -> Quick Stack / Quick Pull.", "G"))
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
    ExecutePackRelocationCrate = ExecutePackRelocationCrate,
    ExecuteUnpackRelocationCrate = ExecuteUnpackRelocationCrate,
    RelocationCrate = RelocationCrate,
    Config = Config
}
