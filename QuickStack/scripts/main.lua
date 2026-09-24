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

    -- Play chest rattle audio on successful quick deposit
    PlaySound = true,

    -- Show visual on-screen notification toast
    ShowNotification = true,

    -- Print detailed information to the console log
    DebugLog = true
}

local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing QuickStack Mod...")
Log("Press 'G' near your storage chests to quick-stack matching items!")
Log("==========================================")

-- Helper: Safe validation of an actor or component
local function IsValidObject(obj)
    if not obj then return false end
    local ok, valid = pcall(function()
        return obj:IsValid() and obj:GetAddress() ~= 0
    end)
    return ok and valid
end

-- Helper: Get user-friendly name of an Item
local function GetItemName(item)
    if not IsValidObject(item) then return "Unknown Item" end
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
    if not IsValidObject(item) then return nil end
    local addr = nil
    pcall(function()
        if item.ItemData and item.ItemData:IsValid() then
            addr = item.ItemData:GetAddress()
        end
    end)
    return addr
end

-- On-screen Toast Notification System using Slate / UMG
local ActiveToastWidget = nil
local ToastHideTick = 0

local function ShowToastMessage(PC, title, message, isSuccess)
    if not Config.ShowNotification then return end
    if not IsValidObject(PC) then return end

    pcall(function()
        -- Attempt to find or create a notification text block if Slate is supported
        -- As a safe fallback across all UE versions, log to console and print on screen via ClientMessage
        if PC.ClientMessage then
            PC:ClientMessage(string.format("[%s] %s", title, message), "Event", 4.0)
        end
    end)
end

-- Play Sound Effect helper
local function PlayQuickDepositSound(PC)
    if not Config.PlaySound or not IsValidObject(PC) then return end
    pcall(function()
        local soundObj = StaticFindObject("/Game/Audio/DataAssets/MSS_Suso_QuickDeposit_ChestRattle.MSS_Suso_QuickDeposit_ChestRattle")
        if not soundObj or not soundObj:IsValid() then
            soundObj = StaticFindObject("/Game/Audio/WwiseAudio/Events/Spells/MSS_Suso_QuickDeposit_ChestRattle.MSS_Suso_QuickDeposit_ChestRattle")
        end
        if soundObj and soundObj:IsValid() then
            local GameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if GameplayStatics and GameplayStatics.PlaySound2D then
                GameplayStatics:PlaySound2D(PC, soundObj, 1.0, 1.0)
            end
        end
    end)
end

-- The Core Quick-Stack Algorithm
local function ExecuteQuickStack()
    local PC = UEHelpers.GetPlayerController()
    if not IsValidObject(PC) then
        Log("QuickStack failed: Local PlayerController not found.")
        return
    end

    local pawn = PC.Pawn
    if not IsValidObject(pawn) then
        Log("QuickStack failed: Player pawn not spawned.")
        return
    end

    local playerLoc = nil
    local okLoc = pcall(function() playerLoc = pawn:K2_GetActorLocation() end)
    if not okLoc or not playerLoc then
        Log("QuickStack failed: Unable to get player location.")
        return
    end

    local playerInv = PC.BP_Components_Inventory
    if not IsValidObject(playerInv) then
        Log("QuickStack failed: Player inventory component (BP_Components_Inventory) not found.")
        return
    end

    local maxRadiusSq = Config.SearchRadius * Config.SearchRadius

    -- 1. Scan for all world chest inventories
    local allChestComps = nil
    local okChests = pcall(function()
        return FindAllOf("BP_Components_WorldItemInventory_C")
    end)
    if not okChests or not allChestComps or #allChestComps == 0 then
        Log("No storage containers found in current world partition.")
        ShowToastMessage(PC, "Quick Stack", "No chests found nearby.", false)
        return
    end

    -- 2. Filter nearby valid chests
    local nearbyChests = {}
    for _, comp in ipairs(allChestComps) do
        if IsValidObject(comp) then
            local chestOwner = nil
            pcall(function() chestOwner = comp:GetOwner() end)
            if IsValidObject(chestOwner) then
                local chestLoc = nil
                local okCLoc = pcall(function() chestLoc = chestOwner:K2_GetActorLocation() end)
                if okCLoc and chestLoc then
                    local dx = chestLoc.X - playerLoc.X
                    local dy = chestLoc.Y - playerLoc.Y
                    local dz = chestLoc.Z - playerLoc.Z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= maxRadiusSq then
                        table.insert(nearbyChests, {
                            Inventory = comp,
                            Actor = chestOwner,
                            Distance = math.sqrt(distSq)
                        })
                    end
                end
            end
        end
    end

    if #nearbyChests == 0 then
        if Config.DebugLog then
            Log(string.format("Scanned %d containers, but none are within %.1f meters.", #allChestComps, Config.SearchRadius / 100.0))
        end
        ShowToastMessage(PC, "Quick Stack", "No chests within range (" .. tostring(math.floor(Config.SearchRadius / 100)) .. "m).", false)
        return
    end

    -- Sort chests closest first
    table.sort(nearbyChests, function(a, b) return a.Distance < b.Distance end)

    if Config.DebugLog then
        Log(string.format("Found %d storage container(s) within %.1f meters. Starting stack check...", #nearbyChests, Config.SearchRadius / 100.0))
    end

    -- 3. Determine Player Backpack Slot Bounds
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

    -- Counters for user summary
    local totalItemsMoved = 0
    local depositedItemsSummary = {} -- itemName -> count
    local affectedChests = {}

    -- 4. Process each chest in range
    for _, chestEntry in ipairs(nearbyChests) do
        local chestInv = chestEntry.Inventory
        local chestActor = chestEntry.Actor

        -- Catalog the chest's current inventory contents
        local chestItemDataMap = {} -- itemDataAddress -> true
        local chestTargetSlots = {} -- itemDataAddress -> list of { slotZero, freeSpace, item }
        local chestEmptySlots = {}  -- list of slotZero

        local chestSlotCount = 0
        pcall(function() chestSlotCount = chestInv.ItemSlots:GetArrayNum() end)

        for cIdx = 1, chestSlotCount do
            local cSlotZero = cIdx - 1
            local cItem = nil
            pcall(function() cItem = chestInv.ItemSlots[cIdx] end)

            if IsValidObject(cItem) then
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

        -- Check if chest has anything that can receive items
        local hasMatchingTypes = false
        for _ in pairs(chestItemDataMap) do
            hasMatchingTypes = true
            break
        end

        if hasMatchingTypes then
            -- Iterate player backpack slots (skipping hotbar slots)
            for pIdx = hotbarCount + 1, playerSlotCount do
                local pSlotZero = pIdx - 1
                local pItem = nil
                pcall(function() pItem = playerInv.ItemSlots[pIdx] end)

                if IsValidObject(pItem) then
                    local pDataAddr = GetItemDataAddress(pItem)
                    local pCount = 0
                    pcall(function() pCount = pItem:GetStackSize() end)

                    -- Only consider stowing if this chest ALREADY has this item type
                    if pDataAddr and chestItemDataMap[pDataAddr] and pCount > 0 then
                        local itemName = GetItemName(pItem)

                        -- A: Try depositing into existing non-full stacks
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

                        -- B: If player still has items, overflow is enabled, and chest has empty slots
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

    -- 5. User Feedback & Results
    if totalItemsMoved > 0 then
        PlayQuickDepositSound(PC)

        -- Build concise summary of deposited items
        local chestCount = 0
        for _ in pairs(affectedChests) do chestCount = chestCount + 1 end

        local itemBreakdownList = {}
        for name, count in pairs(depositedItemsSummary) do
            table.insert(itemBreakdownList, string.format("%dx %s", count, name))
        end
        local breakdownStr = table.concat(itemBreakdownList, ", ")

        local summaryMsg = string.format("Deposited %d item%s into %d chest%s: %s",
            totalItemsMoved,
            totalItemsMoved == 1 and "" or "s",
            chestCount,
            chestCount == 1 and "" or "s",
            breakdownStr)

        Log("SUCCESS: " .. summaryMsg)
        ShowToastMessage(PC, "Quick Stack", summaryMsg, true)
    else
        Log("No matching items found in nearby chests to stack.")
        ShowToastMessage(PC, "Quick Stack", "No matching items found in nearby chests.", false)
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
