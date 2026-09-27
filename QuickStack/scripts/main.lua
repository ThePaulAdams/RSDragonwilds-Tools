local UEHelpers = require("UEHelpers")

local ModName = "QuickStack"

local Config = {
    -- Keybind to activate Quick Stack / Quick Pull
    Key = Key.G,
    Modifier = nil, -- Optional modifier key for base G press

    -- Modifier keys for instant Vacuum Ground Items & Stack
    VacuumModifierCtrl = ModifierKey.CONTROL,
    VacuumModifierShift = ModifierKey.SHIFT,

    -- Maximum distance (in Unreal Units) to search for chests. 2500 uu = 25 meters.
    SearchRadius = 2500.0,

    -- Maximum distance (in Unreal Units) to vacuum ground items. 7500 uu = 75 meters.
    VacuumRadius = 7500.0,

    -- Protect the player's quick-action hotbar slots from being deposited.
    ProtectHotbar = true,

    -- QuickStack (Deposit): If true, creates new stacks in a chest as long as the chest already has that item.
    -- If false, only tops-off existing non-full stacks in the chest.
    OverflowToEmptySlots = false,

    -- Hold duration (in seconds) to trigger Quick Pull or Ground Vacuum
    HoldDuration = 0.35,

    -- Print detailed information to the console log
    DebugLog = true
}

local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing QuickStack Mod with Quick Pull & Ground Item Vacuum...")
Log("  [Tap G]            : Quick-stack matching items into nearby chests.")
Log("  [Hold G on Item]   : Retrieve all matching items from nearby chests!")
Log("  [Hold G in World]  : Vacuum all nearby ground items and stack into chests!")
Log("  [Ctrl+G / Shift+G] : Instant vacuum all ground items and stack into chests!")
Log("==========================================")

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
local function ExecuteQuickStack(allowOverflow)
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

    local canOverflow = Config.OverflowToEmptySlots or (allowOverflow == true)

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

        if hasItems or canOverflow then
            for pIdx = hotbarCount + 1, playerSlotCount do
                local pSlotZero = pIdx - 1
                local pItem = nil
                pcall(function() pItem = playerInv.ItemSlots[pIdx] end)

                if IsValidItem(pItem) then
                    local pDataAddr = GetItemDataAddress(pItem)
                    local pCount = 0
                    pcall(function() pCount = pItem:GetStackSize() end)

                    if pDataAddr and pCount > 0 then
                        local itemName = GetItemName(pItem)

                        -- A: Fill existing non-full stacks
                        if chestItemDataMap[pDataAddr] then
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
                        end

                        -- B: Overflow to empty slots if enabled
                        if pCount > 0 and canOverflow and #chestEmptySlots > 0 then
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
        if not allowOverflow then
            Log("No matching items found in nearby chests to stack.")
        end
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
-- EXECUTE VACUUM & STACK (Bring all ground items to player & stack into chests)
-- =========================================================================
local function ExecuteVacuumAndStack()
    local PC = UEHelpers.GetPlayerController()
    if not IsValidWorldActor(PC) then
        Log("Vacuum failed: Local PlayerController not found or invalid.")
        return
    end

    local pawn = PC.Pawn
    if not IsValidWorldActor(pawn) then
        Log("Vacuum failed: Player character pawn not spawned.")
        return
    end

    local playerLoc = nil
    pcall(function() playerLoc = pawn:K2_GetActorLocation() end)
    if not playerLoc then
        Log("Vacuum failed: Unable to get player location.")
        return
    end

    local radius = Config.VacuumRadius or 7500.0
    local radiusSq = radius * radius

    -- Find all WorldItem actors in the world within radius
    local allItems = {}
    local okItems, foundItems = pcall(function() return FindAllOf("WorldItem") end)
    if okItems and foundItems then
        for _, actor in ipairs(foundItems) do
            if IsValidWorldActor(actor) then
                local loc = nil
                pcall(function() loc = actor:K2_GetActorLocation() end)
                if loc then
                    local dx = loc.X - playerLoc.X
                    local dy = loc.Y - playerLoc.Y
                    local dz = loc.Z - playerLoc.Z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= radiusSq then
                        table.insert(allItems, {
                            Actor = actor,
                            Distance = math.sqrt(distSq)
                        })
                    end
                end
            end
        end
    end

    if #allItems == 0 then
        Log(string.format("Vacuum: No ground items found within %.1f meters.", radius / 100.0))
        return
    end

    Log(string.format(">>> VACUUM: Found %d ground item(s) within %.1f meters! Teleporting to player and stacking into chests...",
        #allItems, radius / 100.0))

    -- Sort closest items first
    table.sort(allItems, function(a, b) return a.Distance < b.Distance end)

    local function PulsePull()
        local curPawn = PC.Pawn
        if not IsValidWorldActor(curPawn) then return end
        local curLoc = nil
        pcall(function() curLoc = curPawn:K2_GetActorLocation() end)
        if not curLoc then return end

        local targetLoc = {
            X = curLoc.X,
            Y = curLoc.Y,
            Z = curLoc.Z + 15.0
        }

        for _, entry in ipairs(allItems) do
            local actor = entry.Actor
            if IsValidWorldActor(actor) then
                -- 1. Teleport directly to player's feet
                pcall(function()
                    actor:K2_SetActorLocation(targetLoc, false, nil, false)
                end)

                -- 2. Activate magnetic attraction & grant
                pcall(function()
                    local mag = nil
                    if actor.GetMagneticComponent then
                        mag = actor:GetMagneticComponent()
                    end
                    if not mag and actor.MagneticComponentGrantItem then
                        mag = actor.MagneticComponentGrantItem
                    end
                    if mag and mag:IsValid() then
                        mag.bAllowAutoMagnetization = true
                        mag.bAutoMagnetizationEnabled = true
                        mag.bMagnetizeWithFullInventory = true
                        mag:BP_MagnetizeToPlayer(curPawn, true)
                    end
                end)

                -- 3. Trigger interaction pickup
                pcall(function()
                    local interact = actor.InteractionComponent
                    if interact and interact:IsValid() then
                        interact:K2_OnInteraction(curPawn)
                    end
                end)
            end
        end
    end

    -- Run initial pull
    PulsePull()

    -- Run multi-pulse sequence to deposit items into chests and pull subsequent batches
    local pulseCount = 0
    local maxPulses = 6

    LoopAsync(150, function()
        pulseCount = pulseCount + 1

        ExecuteInGameThread(function()
            -- Deposit items currently collected into nearby chests (with overflow to empty slots enabled)
            ExecuteQuickStack(true)

            -- Pulse pull again for any items remaining on the ground
            PulsePull()
        end)

        if pulseCount >= maxPulses then
            ExecuteInGameThread(function()
                ExecuteQuickStack(true)
                Log(">>> VACUUM COMPLETE: All ground items gathered and stacked into chests.")
            end)
            return true -- Stop loop
        end

        return false
    end)
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
        if not HoldState.TriggeredPull then
            HoldState.TriggeredPull = true
            if HoldState.Target then
                ExecuteQuickPull(HoldState.Target)
            else
                -- Held G in the open world! Trigger Ground Item Vacuum & Stack!
                ExecuteVacuumAndStack()
            end
        end
        return
    end

    -- Case 2: Fresh key press. Check if an item is currently hovered under the cursor
    local hoverTarget = GetCurrentHoverTarget()

    -- If an item IS hovered in inventory or chest:
    if hoverTarget then
        HoldState.IsActive = true
        HoldState.PressTime = now
        HoldState.Target = hoverTarget
        HoldState.TriggeredPull = false
        HoldState.RepeatCount = 0

        local pressTimestamp = now

        LoopAsync(40, function()
            local elapsed = os.clock() - pressTimestamp

            if elapsed < Config.HoldDuration then
                return false -- Keep checking until hold threshold is reached
            end

            -- Hold threshold reached!
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
                    -- Key was released before hold threshold! Treat as normal QuickStack tap
                    ExecuteInGameThread(function()
                        ExecuteQuickStack()
                    end)
                end
            end

            if elapsed >= 0.50 then
                HoldState.IsActive = false
                return true -- Stop LoopAsync
            end

            return false
        end)
        return
    end

    -- Case 3: No item hovered! Open world.
    -- Immediately execute normal QuickStack at 0ms latency!
    ExecuteQuickStack()

    -- And simultaneously start hold detection for Ground Vacuum if user continues holding G!
    HoldState.IsActive = true
    HoldState.PressTime = now
    HoldState.Target = nil
    HoldState.TriggeredPull = false
    HoldState.RepeatCount = 0

    local pressTimestamp = now

    LoopAsync(40, function()
        local elapsed = os.clock() - pressTimestamp

        if elapsed < Config.HoldDuration then
            return false
        end

        if HoldState.PressTime == pressTimestamp and not HoldState.TriggeredPull then
            local PC = UEHelpers.GetPlayerController()
            local keyStillDown = IsGKeyDown(PC)

            if keyStillDown or HoldState.RepeatCount >= 1 then
                -- Key was held in open world! Trigger Ground Item Vacuum & Stack!
                HoldState.TriggeredPull = true
                ExecuteInGameThread(function()
                    ExecuteVacuumAndStack()
                end)
            end
        end

        if elapsed >= 0.50 then
            HoldState.IsActive = false
            return true
        end

        return false
    end)
end

-- Keybind Registration: Normal G
local okBind, errBind = pcall(function()
    if Config.Modifier then
        RegisterKeyBind(Config.Key, { Config.Modifier }, function()
            ExecuteInGameThread(OnKeyG)
        end)
    else
        RegisterKeyBind(Config.Key, function()
            ExecuteInGameThread(OnKeyG)
        end)
    end
end)

if okBind then
    Log(string.format("Keybind registered: [%s] -> Quick Stack / Quick Pull / Ground Vacuum.", "G"))
else
    Log("ERROR registering keybind [G]: " .. tostring(errBind))
end

-- Keybind Registration: Ctrl + G (Instant Ground Item Vacuum & Chest Stack)
pcall(function()
    RegisterKeyBind(Config.Key, { Config.VacuumModifierCtrl }, function()
        ExecuteInGameThread(ExecuteVacuumAndStack)
    end)
    Log("Keybind registered: [Ctrl + G] -> Instant Ground Item Vacuum & Chest Stack.")
end)

-- Keybind Registration: Shift + G (Instant Ground Item Vacuum & Chest Stack)
pcall(function()
    RegisterKeyBind(Config.Key, { Config.VacuumModifierShift }, function()
        ExecuteInGameThread(ExecuteVacuumAndStack)
    end)
    Log("Keybind registered: [Shift + G] -> Instant Ground Item Vacuum & Chest Stack.")
end)

return {
    ExecuteQuickStack = ExecuteQuickStack,
    ExecuteQuickPull = ExecuteQuickPull,
    ExecuteVacuumAndStack = ExecuteVacuumAndStack,
    Config = Config
}
