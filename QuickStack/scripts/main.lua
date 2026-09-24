local UEHelpers = require("UEHelpers")

local ModName = "QuickStack"

local Config = {
    -- Keybind to activate Quick Stack
    Key = Key.G,
    Modifier = nil, -- Optional modifier key, e.g. ModifierKey.CONTROL or nil for just G

    -- Maximum distance (in Unreal Units) to search for chests. 2500 uu = 25 meters.
    SearchRadius = 2500.0,

    -- Protect the player's quick-action hotbar slots from being deposited.
    ProtectHotbar = true,

    -- If true, will create new stacks in a chest as long as the chest already contains that item type.
    -- If false, will only top-off existing non-full stacks in the chest.
    OverflowToEmptySlots = false,

    -- Print detailed information to the console log
    DebugLog = true
}

local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing QuickStack Mod (Crash-Safe Build)...")
Log("Press 'G' near storage chests to quick-stack matching items!")
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

-- The Core Quick-Stack Execution
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

    local maxRadiusSq = Config.SearchRadius * Config.SearchRadius

    -- 1. Find all nearby chests safely
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

    if #nearbyChests == 0 then
        Log(string.format("No chests found within %.1f meters.", Config.SearchRadius / 100.0))
        return
    end

    -- Sort chests closest first
    table.sort(nearbyChests, function(a, b) return a.Distance < b.Distance end)

    if Config.DebugLog then
        Log(string.format("Found %d nearby chest(s). Starting quick stack...", #nearbyChests))
    end

    -- 2. Determine Player Backpack Slot Bounds
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

    -- 3. Process each chest
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
            -- Iterate player backpack slots (skipping hotbar)
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

    -- 4. Result Logging
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

-- Keybind Registration
local keyCallback = function()
    ExecuteInGameThread(function()
        ExecuteQuickStack()
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
    Log(string.format("Keybind registered successfully: [%s] -> Quick Stack to nearby chests.", "G"))
else
    Log("ERROR registering keybind: " .. tostring(errBind))
end

return {
    ExecuteQuickStack = ExecuteQuickStack,
    Config = Config
}
