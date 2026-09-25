local UEHelpers = require("UEHelpers")

local ModName = "TelekineticWoodcraft"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing Telekinetic Woodcraft Mod...")
Log("Single log drag + Mass Log Magnet for easy Splinter harvesting.")
Log("Controls:")
Log("  [E] or [V]   - Telekinetically Grab / Place targeted log")
Log("  [Z]          - [Log Magnet] Mass-gather all nearby logs into a stack")
Log("  [F6]         - Cycle Splinter Spell AoE Radius (1x -> 2.5x -> 5x)")
Log("==========================================")

-- State
local HeldLog = nil
local IsHolding = false
local GrabStartTime = 0
local UpdatePending = false

-- Configuration
local Config = {
    MaxGrabRange = 800.0,        -- 8 meters
    HoldDistance = 280.0,        -- 2.8 meters in front of camera
    MassGatherRadius = 15000.0,  -- 150 meters (sweeps wide clearings and hills)
    SplinterTiers = {
        { Name = "1.0x (Vanilla Radius)", Multiplier = 1.0 },
        { Name = "2.5x (Adept Radius)",   Multiplier = 2.5 },
        { Name = "5.0x (Archmage Giant)", Multiplier = 5.0 },
    },
    CurrentSplinterTierIndex = 1,
}
local VanillaSplinterRadius = nil

-- Safe UObject Validator
local function IsValidUObject(obj)
    if not obj then return false end
    local ok, res = pcall(function()
        if type(obj) ~= "userdata" then return false end
        if not obj.IsValid or not obj:IsValid() then return false end
        if not obj.GetAddress or obj:GetAddress() == 0 then return false end
        return true
    end)
    return ok and res
end

-- Get Player Controller, Pawn, Camera Manager
local function GetPlayerContext()
    local PC = UEHelpers.GetPlayerController()
    if not IsValidUObject(PC) then return nil end
    local pawn = PC.Pawn
    if not IsValidUObject(pawn) then return nil end
    local camMgr = PC.PlayerCameraManager
    if not IsValidUObject(camMgr) then return nil end
    return {
        PC = PC,
        Pawn = pawn,
        CamMgr = camMgr
    }
end

-- Target Blueprint and Native Classes for all tree species in the game
local TargetLogClasses = {
    -- Ash Tree (User primary target)
    "BP_SplittableLog_Ash_C",
    "BP_Log_Ash_C",
    "BP_FelledTree_Ash_C",

    -- Oak Tree
    "BP_SplittableLog_Oak_C",
    "BP_Log_Oak_C",
    "BP_FelledTree_Oak_C",

    -- Willow Tree
    "BP_SplittableLog_Willow_C",
    "BP_Log_Willow_C",
    "BP_FelledTree_Willow_C",

    -- Maple Tree
    "BP_SplittableLog_Maple_C",
    "BP_Log_Maple_C",
    "BP_FelledTree_Maple_C",

    -- Yew Tree
    "BP_SplittableLog_Yew_C",
    "BP_Log_Yew_C",
    "BP_FelledTree_Yew_C",

    -- Magic Tree
    "BP_SplittableLog_Magic_C",
    "BP_Log_Magic_C",
    "BP_FelledTree_Magic_C",

    -- Elder, Redwood, Teak, Mahogany
    "BP_SplittableLog_Elder_C",
    "BP_Log_Elder_C",
    "BP_FelledTree_Elder_C",
    "BP_SplittableLog_Redwood_C",
    "BP_Log_Redwood_C",
    "BP_FelledTree_Redwood_C",
    "BP_SplittableLog_Teak_C",
    "BP_Log_Teak_C",
    "BP_FelledTree_Teak_C",
    "BP_SplittableLog_Mahogany_C",
    "BP_Log_Mahogany_C",
    "BP_FelledTree_Mahogany_C",

    -- Base Blueprint Classes
    "BP_SplittableLog_Base_C",
    "BP_Log_Base_C",
    "BP_FelledTree_Base_C",

    -- Native C++ Classes
    "SplittableTreeLog",
    "TreeLog",
    "FelledTree",
}

-- Check if an actor is a fallen tree log, splittable log, or felled tree trunk
local function IsLogActor(actor)
    if not IsValidUObject(actor) then return false end

    -- Check for CDO (Class Default Objects)
    local objName = ""
    pcall(function() objName = tostring(actor:GetName() or "") end)
    if string.find(objName, "^Default__") then
        return false
    end

    -- Verify actor has a RootComponent or valid world position
    local hasRoot = false
    pcall(function()
        if actor.RootComponent and IsValidUObject(actor.RootComponent) then
            hasRoot = true
        end
    end)
    if not hasRoot then
        return false
    end

    local fullName = ""
    local className = ""
    pcall(function() fullName = tostring(actor:GetFullName() or "") end)
    pcall(function()
        local classObj = actor:GetClass()
        if classObj and classObj.GetName then
            className = tostring(classObj:GetName() or "")
        end
    end)

    -- Explicitly ignore standing / live trees!
    if string.find(fullName, "FellableTree") or string.find(objName, "FellableTree") or string.find(className, "FellableTree") then
        return false
    end
    -- Explicitly ignore standing foliage scenery trees
    if string.find(className, "^BP_.*Tree_") or string.find(className, "TreeEmitter") or string.find(className, "LoggingAxe") then
        return false
    end
    -- Explicitly ignore transmutation filter strategies
    if string.find(className, "TTFS") or string.find(className, "TTDS") or string.find(className, "Transmutation") then
        return false
    end

    -- Match all fallen tree trunks, cut logs, and splittable timber
    local logPatterns = {
        "SplittableLog", "SplittableTreeLog", "TreeLog", "FelledTree",
        "BP_Log_", "Log_Base", "Tree_Log"
    }

    for _, pat in ipairs(logPatterns) do
        if string.find(fullName, pat) or string.find(objName, pat) or string.find(className, pat) then
            return true
        end
    end

    return false
end

-- Find all active fallen logs and splittable trunks in the world
local function GetAllWorldLogs()
    local logs = {}
    local seen = {}

    local function addActor(actor)
        if IsValidUObject(actor) and IsLogActor(actor) then
            local addr = actor:GetAddress()
            if not seen[addr] then
                local isPending = false
                pcall(function()
                    if actor.bDestroyActorIsPending then
                        isPending = actor.bDestroyActorIsPending
                    end
                end)
                if not isPending then
                    seen[addr] = true
                    table.insert(logs, actor)
                end
            end
        end
    end

    for _, clsName in ipairs(TargetLogClasses) do
        local ok, list = pcall(function() return FindAllOf(clsName) end)
        if ok and list then
            for _, a in ipairs(list) do
                addActor(a)
            end
        end
    end

    return logs
end

-- Targeted Log Finder (via interaction detector or camera conical trace)
local function GetTargetedLog(ctx, maxDist)
    maxDist = maxDist or Config.MaxGrabRange

    -- 1. Try game's native InteractableDetector
    local detectorOk, detector = pcall(function()
        if ctx.Pawn.GetInteractableDetector then
            return ctx.Pawn:GetInteractableDetector()
        end
        return nil
    end)
    if detectorOk and IsValidUObject(detector) then
        local curActor = detector.CurrentWorldActor
        if IsValidUObject(curActor) and IsLogActor(curActor) then
            return curActor
        end
    end

    -- 2. Conical camera raycast
    local camLoc = ctx.CamMgr:GetCameraLocation()
    local camRot = ctx.CamMgr:GetCameraRotation()
    if not camLoc or not camRot then return nil end

    local pitchRad = math.rad(camRot.Pitch)
    local yawRad = math.rad(camRot.Yaw)
    local cosPitch = math.cos(pitchRad)
    local fwdX = cosPitch * math.cos(yawRad)
    local fwdY = cosPitch * math.sin(yawRad)
    local fwdZ = math.sin(pitchRad)

    local bestLog = nil
    local bestScore = -999999

    local allLogs = GetAllWorldLogs()
    for _, log in ipairs(allLogs) do
        local loc = nil
        pcall(function()
            if log.GetMidPointWorldLocation then
                loc = log:GetMidPointWorldLocation()
            end
            if not loc then
                loc = log:K2_GetActorLocation()
            end
        end)

        if loc then
            local dx = loc.X - camLoc.X
            local dy = loc.Y - camLoc.Y
            local dz = loc.Z - camLoc.Z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

            if dist > 30 and dist <= maxDist then
                local dirX = dx / dist
                local dirY = dy / dist
                local dirZ = dz / dist

                local dot = fwdX * dirX + fwdY * dirY + fwdZ * dirZ
                if dot > 0.70 then
                    local score = dot * 2.0 - (dist / maxDist)
                    if score > bestScore then
                        bestScore = score
                        bestLog = log
                    end
                end
            end
        end
    end

    return bestLog
end

-- Carry loop handle managed strictly during active grab
local CarryLoopHandle = nil

-- Update Held Log Position each frame
local function UpdateHeldLogPosition(ctx)
    if not IsHolding or not IsValidUObject(HeldLog) then
        IsHolding = false
        HeldLog = nil
        return
    end

    local camLoc = ctx.CamMgr:GetCameraLocation()
    local camRot = ctx.CamMgr:GetCameraRotation()
    local pawnLoc = ctx.Pawn:K2_GetActorLocation()
    if not camLoc or not camRot or not pawnLoc then return end

    local pitchRad = math.rad(camRot.Pitch)
    local yawRad = math.rad(camRot.Yaw)
    local cosPitch = math.cos(pitchRad)
    local fwdX = cosPitch * math.cos(yawRad)
    local fwdY = cosPitch * math.sin(yawRad)
    local fwdZ = math.sin(pitchRad)

    local targetX = camLoc.X + fwdX * Config.HoldDistance
    local targetY = camLoc.Y + fwdY * Config.HoldDistance
    local targetZ = camLoc.Z + fwdZ * Config.HoldDistance

    -- Ground clamp so log doesn't clip below floor
    if targetZ < pawnLoc.Z - 30.0 then
        targetZ = pawnLoc.Z - 30.0
    end

    pcall(function()
        HeldLog:K2_SetActorLocation({ X = targetX, Y = targetY, Z = targetZ }, false, {}, true)
        HeldLog:K2_SetActorRotation({ Pitch = 0.0, Yaw = camRot.Yaw, Roll = 90.0 }, true)
    end)
end

-- Telekinetically Grab a Log
local function GrabLog(ctx, logActor)
    if not IsValidUObject(logActor) then return false end

    HeldLog = logActor
    IsHolding = true
    GrabStartTime = os.clock()

    local mesh = nil
    pcall(function()
        mesh = logActor.RootStaticMeshComponent or logActor.RootComponent
    end)

    if IsValidUObject(mesh) then
        pcall(function()
            mesh:SetSimulatePhysics(false)
            mesh:SetEnableGravity(false)
            mesh:SetCollisionResponseToChannel(1, 0) -- Ignore pawn collision
            mesh:SetPhysicsLinearVelocity({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
            mesh:SetPhysicsAngularVelocityInDegrees({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
        end)
    end

    pcall(function()
        logActor:SetActorEnableCollision(false)
    end)



    -- Start per-frame smooth positioning loop on the game thread
    if CarryLoopHandle then
        pcall(function() CancelDelayedAction(CarryLoopHandle) end)
        CarryLoopHandle = nil
    end

    pcall(function()
        CarryLoopHandle = LoopInGameThreadWithDelay(16, function()
            if not IsHolding or not IsValidUObject(HeldLog) then
                if CarryLoopHandle then
                    CancelDelayedAction(CarryLoopHandle)
                    CarryLoopHandle = nil
                end
                IsHolding = false
                HeldLog = nil
                return
            end

            local curCtx = GetPlayerContext()
            if curCtx and IsHolding then
                pcall(function() UpdateHeldLogPosition(curCtx) end)
            else
                IsHolding = false
                HeldLog = nil
                if CarryLoopHandle then
                    CancelDelayedAction(CarryLoopHandle)
                    CarryLoopHandle = nil
                end
            end
        end)
    end)

    Log(string.format(">>> ✨ Telekinetically grabbed log! Move anywhere, then press [E] or [V] to place it."))
    return true
end

-- Place / Drop Held Log
local function DropHeldLog(ctx)
    if CarryLoopHandle then
        pcall(function() CancelDelayedAction(CarryLoopHandle) end)
        CarryLoopHandle = nil
    end

    if not IsHolding or not IsValidUObject(HeldLog) then
        HeldLog = nil
        IsHolding = false
        return
    end

    local logActor = HeldLog
    HeldLog = nil
    IsHolding = false

    local mesh = nil
    pcall(function()
        mesh = logActor.RootStaticMeshComponent or logActor.RootComponent
    end)

    pcall(function()
        logActor:SetActorEnableCollision(true)
    end)

    if IsValidUObject(mesh) then
        pcall(function()
            mesh:SetCollisionResponseToChannel(1, 2) -- Block pawn
            mesh:SetPhysicsLinearVelocity({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
            mesh:SetPhysicsAngularVelocityInDegrees({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
            mesh:SetEnableGravity(true)
            mesh:SetSimulatePhysics(true)
            mesh:WakeRigidBody(FName("None"))
        end)
    end

    Log(">>> 📦 Log placed gently on the ground.")
end

-- Toggle Grab / Drop Action
local function HandleGrabDrop(isKeyE)
    ExecuteInGameThread(function()
        local ctx = GetPlayerContext()
        if not ctx then return end

        if IsHolding then
            DropHeldLog(ctx)
            return
        end

        local targeted = GetTargetedLog(ctx, Config.MaxGrabRange)
        if targeted then
            GrabLog(ctx, targeted)
        else
            if not isKeyE then
                Log(">>> No fallen log in crosshair range (aim at a log and press V or E).")
            end
        end
    end)
end

-- Helper: Get Player Ground Location (bottom of character capsule)
local function GetPlayerGroundLocation(ctx)
    local pawnLoc = ctx.Pawn:K2_GetActorLocation()
    local halfHeight = 88.0
    pcall(function()
        if ctx.Pawn.CapsuleComponent and ctx.Pawn.CapsuleComponent.CapsuleHalfHeight then
            halfHeight = ctx.Pawn.CapsuleComponent.CapsuleHalfHeight
        end
    end)
    return {
        X = pawnLoc.X,
        Y = pawnLoc.Y,
        Z = pawnLoc.Z - halfHeight
    }
end

-- Pyramid Woodpile Layout:
-- Compact, realistic stack placed right in front of the player (under crosshair)
local function GetPileOffset(index)
    local slots = {
        -- Layer 1: Ground Base (3 logs side-by-side, safe +50cm ground clearance)
        { lat = 0.0,    depth = 0.0,   z = 50.0 },
        { lat = -45.0,  depth = 5.0,   z = 50.0 },
        { lat = 45.0,   depth = 5.0,   z = 50.0 },
        -- Layer 2: Middle Tier (2 logs resting in valleys)
        { lat = -22.5,  depth = 0.0,   z = 90.0 },
        { lat = 22.5,   depth = 0.0,   z = 90.0 },
        -- Layer 3: Top Crown (1 log on apex)
        { lat = 0.0,    depth = 0.0,   z = 130.0 },
        -- Expanded Base (if 7-12 logs)
        { lat = -90.0,  depth = 8.0,   z = 50.0 },
        { lat = 90.0,   depth = 8.0,   z = 50.0 },
        { lat = -67.5,  depth = 4.0,   z = 90.0 },
        { lat = 67.5,   depth = 4.0,   z = 90.0 },
        { lat = -45.0,  depth = 0.0,   z = 130.0 },
        { lat = 45.0,   depth = 0.0,   z = 130.0 },
        -- Extra High Crown (if >12 logs)
        { lat = 0.0,    depth = 0.0,   z = 170.0 },
        { lat = -22.5,  depth = 0.0,   z = 170.0 },
        { lat = 22.5,   depth = 0.0,   z = 170.0 },
    }

    if index <= #slots then
        return slots[index]
    end

    local extra = index - #slots
    local side = (extra % 2 == 1) and 1 or -1
    local col = math.ceil(extra / 2)
    return {
        lat = side * (90.0 + col * 40.0),
        depth = 0.0,
        z = 50.0
    }
end

-- Mass Telekinetic Gathering ("Log Magnet" - Z)
local function MassGatherLogs()
    ExecuteInGameThread(function()
        local ctx = GetPlayerContext()
        if not ctx then return end

        local groundLoc = GetPlayerGroundLocation(ctx)
        local camRot = ctx.CamMgr:GetCameraRotation()
        if not camRot then return end

        local yawRad = math.rad(camRot.Yaw)
        -- Forward and Right unit vectors in world horizontal plane
        local fwdX = math.cos(yawRad)
        local fwdY = math.sin(yawRad)
        local rightX = -math.sin(yawRad)
        local rightY = math.cos(yawRad)

        local baseCenterDist = 260.0 -- 2.6m directly in front of player
        local allLogs = GetAllWorldLogs()
        local gatheredCount = 0
        local ashCount = 0
        local oakCount = 0
        local otherCount = 0

        for _, log in ipairs(allLogs) do
            if not HeldLog or log:GetAddress() ~= HeldLog:GetAddress() then
                local loc = nil
                pcall(function() loc = log:K2_GetActorLocation() end)
                if loc then
                    local dx = loc.X - groundLoc.X
                    local dy = loc.Y - groundLoc.Y
                    local dz = loc.Z - groundLoc.Z
                    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

                    if dist <= Config.MassGatherRadius then
                        gatheredCount = gatheredCount + 1

                        local actorName = ""
                        pcall(function() actorName = tostring(log:GetName() or "") end)
                        if string.find(actorName, "Ash") then
                            ashCount = ashCount + 1
                        elseif string.find(actorName, "Oak") then
                            oakCount = oakCount + 1
                        else
                            otherCount = otherCount + 1
                        end

                        -- Layout in a compact, realistic pyramid pile
                        local slot = GetPileOffset(gatheredCount)
                        local destX = groundLoc.X + fwdX * (baseCenterDist + slot.depth) + rightX * slot.lat
                        local destY = groundLoc.Y + fwdY * (baseCenterDist + slot.depth) + rightY * slot.lat
                        local destZ = groundLoc.Z + slot.z

                        local mesh = nil
                        pcall(function()
                            mesh = log.RootStaticMeshComponent or log.RootComponent
                        end)

                        -- 1. Freeze physics and zero all momentum before moving
                        if IsValidUObject(mesh) then
                            pcall(function()
                                mesh:SetSimulatePhysics(false)
                                mesh:SetEnableGravity(false)
                                mesh:SetPhysicsLinearVelocity({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
                                mesh:SetPhysicsAngularVelocityInDegrees({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
                            end)
                        end

                        -- 2. Teleport without imparting displacement velocity (bTeleport = true)
                        pcall(function()
                            log:K2_SetActorLocation({ X = destX, Y = destY, Z = destZ }, false, {}, true)
                            log:K2_SetActorRotation({ Pitch = 0.0, Yaw = camRot.Yaw, Roll = 90.0 }, true)
                        end)

                        -- 3. Ensure fully visible and solid (undo any fade/hide from earlier)
                        pcall(function()
                            log:SetActorHiddenInGame(false)
                            if IsValidUObject(mesh) then
                                mesh:SetHiddenInGame(false, true)
                                mesh:SetVisibility(true, true)
                            end
                        end)

                        -- 4. Re-zero velocity, enable gravity & physics, wake body to drop and settle naturally
                        if IsValidUObject(mesh) then
                            pcall(function()
                                mesh:SetEnableGravity(true)
                                mesh:SetSimulatePhysics(true)
                                mesh:SetPhysicsLinearVelocity({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
                                mesh:SetPhysicsAngularVelocityInDegrees({ X = 0.0, Y = 0.0, Z = 0.0 }, false, FName("None"))
                                mesh:WakeRigidBody(FName("None"))
                            end)
                        end

                        Log(string.format("  -> Pulled: '%s' into pile at (%.0f, %.0f, %.0f)", actorName, destX, destY, destZ))
                    end
                end
            end
        end

        if gatheredCount > 0 then
            Log(string.format(">>> [Log Magnet] Stacked %d log(s) into a tight woodpile 2.6m in front of you! (Ash: %d, Oak: %d, Other: %d) Ready for Splinter!", gatheredCount, ashCount, oakCount, otherCount))
        else
            if #allLogs > 0 then
                local closestDist = 999999
                for _, l in ipairs(allLogs) do
                    local lLoc = nil
                    pcall(function() lLoc = l:K2_GetActorLocation() end)
                    if lLoc then
                        local d = math.sqrt((lLoc.X - groundLoc.X)^2 + (lLoc.Y - groundLoc.Y)^2 + (lLoc.Z - groundLoc.Z)^2)
                        if d < closestDist then closestDist = d end
                    end
                end
                Log(string.format(">>> [Log Magnet] Found %d fallen log(s) on map, but closest is %.1fm away (gather radius is %.0fm). Walk closer!", #allLogs, closestDist / 100.0, Config.MassGatherRadius / 100.0))
            else
                Log(">>> [Log Magnet] No fallen logs or felled tree trunks found anywhere on the map. Chop down a tree first!")
            end
        end
    end)
end

-- Cycle Splinter Spell Radius (F6)
local function CycleSplinterRadius()
    Config.CurrentSplinterTierIndex = Config.CurrentSplinterTierIndex + 1
    if Config.CurrentSplinterTierIndex > #Config.SplinterTiers then
        Config.CurrentSplinterTierIndex = 1
    end

    local tier = Config.SplinterTiers[Config.CurrentSplinterTierIndex]

    ExecuteInGameThread(function()
        local sphere = StaticFindObject("/Game/Gameplay/UtilityMagic/PerkSpells/Splinter/USD_Splinter.USD_Splinter:SpellModule_Shape_0.DominionShape_Sphere_0")
        if IsValidUObject(sphere) then
            if not VanillaSplinterRadius then
                VanillaSplinterRadius = sphere.Radius or 400.0
            end
            local newRadius = VanillaSplinterRadius * tier.Multiplier
            sphere.Radius = newRadius
            Log(string.format(">>> [F6] Splinter Spell Radius set to: %s (Radius = %.1f)", tier.Name, newRadius))
        else
            Log("[F6] Splinter Spell data not loaded yet (unlock or equip Splinter first).")
        end
    end)
end


-- Register Keybinds
pcall(function()
    RegisterKeyBind(Key.E, function()
        HandleGrabDrop(true)
    end)
    Log("Keybind registered: [E: Grab / Place Targeted Log]")
end)

pcall(function()
    RegisterKeyBind(Key.V, function()
        HandleGrabDrop(false)
    end)
    Log("Keybind registered: [V: Dedicated Grab / Place Toggle]")
end)

pcall(function()
    RegisterKeyBind(Key.Z, function()
        MassGatherLogs()
    end)
    Log("Keybind registered: [Z: Log Magnet Mass Gather]")
end)

pcall(function()
    RegisterKeyBind(Key.F6, function()
        CycleSplinterRadius()
    end)
    Log("Keybind registered: [F6: Cycle Splinter Spell Radius]")
end)

Log("Telekinetic Woodcraft Mod initialized successfully.")
