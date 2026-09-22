local UEHelpers = require("UEHelpers")

local ModName = "OSRSMinimap"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing OSRS Minimap (Engine Projected Math)...")
Log("==========================================")

-- State
local MinimapWidget = nil
local CurrentPlayerController = nil
local IsMinimapVisible = true
local CurrentZoom = 8.0
local MinimapSide = 280.0
local Margin = 25.0
local RotateWithPlayer = true
local CurrentPawn = nil
local UpdatePending = false
local UpdateTick = 0
local NextInitTick = 0
local NextSearchTick = 0
local LastMainMapOpen = nil
local LastUpdateError = nil
local MinimapClass = nil

-- Cached Singletons & Widgets (Never scan GUObjectArray inside ticks!)
local CachedGameInstance = nil
local CachedAreaMapView = nil
local CachedOfficialTopNav = nil
local CachedOfficialMap = nil

-- Dirty Checking for 0% CPU usage when stationary
local LastU = nil
local LastV = nil
local LastYaw = nil
local LastZoom = nil
local LastRotateState = nil

local Key = Key

-- 1. Locate the Official TopNav and Official Map (Cached, zero-scan during tick)
local function GetOfficialTopNav()
    if CachedOfficialTopNav and CachedOfficialTopNav:IsValid() then
        return CachedOfficialTopNav
    end
    -- Throttle searches: never search more than once every 5 seconds (100 ticks)
    if UpdateTick < NextSearchTick then
        return nil
    end
    NextSearchTick = UpdateTick + 100

    -- 1. Try finding via GameInstance MainMenuWidget
    if not CachedGameInstance or not CachedGameInstance:IsValid() then
        CachedGameInstance = FindFirstOf("BP_DominionGameInstance_C")
    end
    if CachedGameInstance and CachedGameInstance:IsValid() then
        local mm = CachedGameInstance.MainMenuWidget
        if mm and mm:IsValid() then
            local allInMM = FindAllOf("WBP_TopNav_Map_C")
            if allInMM then
                for _, tn in ipairs(allInMM) do
                    if tn:IsValid() and string.find(tn:GetFullName(), "MainMenuWidget") then
                        CachedOfficialTopNav = tn
                        Log(string.format("[TOPNAV] Found TopNav in MainMenuWidget: %s", tn:GetFullName()))
                        return CachedOfficialTopNav
                    end
                end
            end
        end
    end

    -- 2. Try finding live instance in Transient
    local allTopNav = FindAllOf("WBP_TopNav_Map_C")
    if allTopNav then
        for _, tn in ipairs(allTopNav) do
            if tn:IsValid() and string.find(tn:GetFullName(), "Transient") then
                CachedOfficialTopNav = tn
                Log(string.format("[TOPNAV] Found live Transient TopNav: %s", tn:GetFullName()))
                return CachedOfficialTopNav
            end
        end
    end

    return nil
end

local function GetOfficialMap()
    if CachedOfficialMap and CachedOfficialMap:IsValid() then
        return CachedOfficialMap
    end
    local topNav = GetOfficialTopNav()
    if topNav and topNav:IsValid() and topNav.Map and topNav.Map:IsValid() then
        CachedOfficialMap = topNav.Map
        return CachedOfficialMap
    end
    -- Fallback: check all WBP_DominionMinimap_C owned by GameInstance
    local allM = FindAllOf("WBP_DominionMinimap_C")
    if allM then
        for _, m in ipairs(allM) do
            if m:IsValid() and string.find(m:GetFullName(), "BP_DominionGameInstance") then
                if not MinimapWidget or m:GetAddress() ~= MinimapWidget:GetAddress() then
                    CachedOfficialMap = m
                    if topNav and topNav:IsValid() and (not topNav.Map or not topNav.Map:IsValid()) then
                        topNav.Map = m
                    end
                    return CachedOfficialMap
                end
            end
        end
    end
    return nil
end

local function GetViewportSize()
    local PC = UEHelpers.GetPlayerController()
    if PC and PC:IsValid() and PC.GetViewportSize then
        local SizeX, SizeY = 0, 0
        local ok, X, Y = pcall(function() return PC:GetViewportSize(SizeX, SizeY) end)
        if ok and X and Y and Y > 0 then
            return X, Y
        end
    end
    return 1920.0, 1080.0
end

local function EnsureOfficialMapRestored()
    local official = GetOfficialMap()
    if not official or not official:IsValid() then
        return
    end
    
    local topNav = GetOfficialTopNav()
    if topNav and topNav:IsValid() then
        topNav.Map = official
        local root = topNav.WidgetTree and topNav.WidgetTree.RootWidget
        if root and root:IsValid() and root.GetChildrenCount then
            local alreadyChild = false
            for i = 0, root:GetChildrenCount() - 1 do
                if root:GetChildAt(i):GetAddress() == official:GetAddress() then
                    alreadyChild = true
                    break
                end
            end
            if not alreadyChild then
                root:AddChild(official)
                Log("[RESTORE] Official map safely re-anchored into Main Map Panel.")
            end
        end
    end
    
    -- Sizing: Enforce 1:1 Square Aspect Ratio matching the Fog of War and World Bounds
    local vpX, vpY = GetViewportSize()
    local mapSide = vpY -- Square dimension matching screen height (e.g. 1080)
    local slot = official.Slot
    if slot and slot:IsValid() then
        pcall(function()
            if slot.SetAnchors then
                slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.0 }, Maximum = { X = 0.5, Y = 1.0 } })
            end
            if slot.SetAlignment then
                slot:SetAlignment({ X = 0.5, Y = 0.0 })
            end
            if slot.SetOffsets then
                slot:SetOffsets({ Left = 0.0, Top = 0.0, Right = mapSide, Bottom = 0.0 })
            end
            Log(string.format("[RESTORE] Official map slot anchored to 1:1 square (%.1f x %.1f) centered at X=0.5 (vp=%.1f x %.1f).", mapSide, mapSide, vpX, vpY))
        end)
    end
    
    -- Enforce 1:1 Aspect Ratio on Official Map widget
    pcall(function()
        if official.InitialMapSize and official.InitialMapSize.Y > 0 then
            official.InitialMapSize = { X = official.InitialMapSize.Y, Y = official.InitialMapSize.Y }
        end
        if official.SetDesiredAspectRatio then
            official:SetDesiredAspectRatio(1.0)
        end
        if official.EnforceAspectRatio then
            official:EnforceAspectRatio()
        end
    end)
    
    official:SetVisibility(0)
    
    -- Ensure official map has its backgrounds
    local tracker = FindFirstOf("MapTrackerComponent")
    if tracker and tracker:IsValid() and tracker.MapBackgrounds and official.Canvas_Backgrounds then
        if official.Canvas_Backgrounds:GetChildrenCount() == 0 then
            for i = 1, tracker.MapBackgrounds:GetArrayNum() do
                local bg = tracker.MapBackgrounds[i]
                if bg and bg:IsValid() and official.AddMapBackground then
                    pcall(function() official:AddMapBackground(bg) end)
                end
            end
            Log("[RESTORE] Populated backgrounds on Official map.")
        end
    end
end

-- 2. Locate the AreaMapView for Exact GPS Coordinates
local function GetAreaMapView()
    if CachedAreaMapView and CachedAreaMapView:IsValid() then
        return CachedAreaMapView
    end
    local tracker = FindFirstOf("MapTrackerComponent")
    if tracker and tracker:IsValid() and tracker.MapBackgrounds then
        local bg = tracker.MapBackgrounds[1]
        if bg and bg:IsValid() and bg.AreaMapView and bg.AreaMapView:IsValid() then
            CachedAreaMapView = bg.AreaMapView
            Log(string.format("Found AreaMapView for GPS: %s", CachedAreaMapView:GetFullName()))
            return CachedAreaMapView
        end
    end
    return nil
end

-- 3. Cleanup ONLY orphaned mod widgets (Never touch the Official Map!)
local function CleanupModOrphans(keepWidget)
    local official = GetOfficialMap()
    local all = FindAllOf("WBP_DominionMinimap_C")
    if all then
        local count = 0
        for _, w in ipairs(all) do
            if w:IsValid() then
                local isOfficial = (official and w:GetAddress() == official:GetAddress())
                if not isOfficial and string.find(w:GetFullName(), "BP_PlayerController") then
                    if not keepWidget or w:GetAddress() ~= keepWidget:GetAddress() then
                        pcall(function()
                            w:RemoveFromParent()
                            w:SetVisibility(2)
                        end)
                        count = count + 1
                    end
                end
            end
        end
        if count > 0 then
            Log(string.format("[CLEANUP] Removed %d orphaned mod minimaps.", count))
        end
    end
end

-- 4. Get Minimap Widget Blueprint Class
local function GetMinimapClass()
    if MinimapClass and MinimapClass:IsValid() then
        return MinimapClass
    end
    local ClassPath = "/Game/UI/HUD/ModifiedMinimapPlugin/WBP_DominionMinimap.WBP_DominionMinimap_C"
    MinimapClass = StaticFindObject(ClassPath)
    return MinimapClass
end

-- 5. Transform Screen Layout
local function ApplyMinimapTransform()
    if not MinimapWidget or not MinimapWidget:IsValid() then return end
    pcall(function()
        if MinimapWidget.SetRenderScale then
            MinimapWidget:SetRenderScale({ X = 1.0, Y = 1.0 })
        end
        if MinimapWidget.SetRenderTranslation then
            MinimapWidget:SetRenderTranslation({ X = 0.0, Y = 0.0 })
        end

        local rBox = MinimapWidget.RetainerBox_Minimap
        if rBox and rBox:IsValid() and rBox.Slot then
            local slot = rBox.Slot
            if slot.SetAnchors then
                slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
            end
            if slot.SetAlignment then
                slot:SetAlignment({ X = 1.0, Y = 0.0 })
            end
            if slot.SetOffsets then
                slot:SetOffsets({ Left = -Margin, Top = Margin, Right = MinimapSide, Bottom = MinimapSide })
            end
        end
    end)
end

-- 6. Setup Standalone Minimap Widget (Exact Copy of Main Map Architecture)
local function SetupMinimapWidget(Widget, PC)
    if not Widget or not Widget:IsValid() then return false end

    Widget:AddToViewport(100)
    Widget:SetVisibility(IsMinimapVisible and 0 or 2)

    -- Disable RetainerBox Render Target offscreen caching:
    -- Bypassing offscreen texture render targets eliminates GPU/CPU stalls and uses hardware GPU scissor clipping!
    pcall(function()
        local rBox = Widget.RetainerBox_Minimap
        if rBox and rBox:IsValid() then
            if rBox.SetRetainRendering then
                rBox:SetRetainRendering(false)
            end
        end
    end)

    -- Enforce 1:1 Aspect Ratio on Widget
    pcall(function()
        Widget.InitialMapSize = { X = MinimapSide, Y = MinimapSide }
        if Widget.SetDesiredAspectRatio then
            Widget:SetDesiredAspectRatio(1.0)
        end
        if Widget.EnforceAspectRatio then
            Widget:EnforceAspectRatio()
        end
    end)

    ApplyMinimapTransform()

    -- Configure Square shape
    Widget.bIsCircular = false
    if Widget.ReinitShape then pcall(function() Widget:ReinitShape() end) end

    -- Hide Clouds / Fog Overlays on HUD Minimap
    if Widget.Overlay_Fogs and Widget.Overlay_Fogs:IsValid() then
        Widget.Overlay_Fogs:SetVisibility(2)
    end
    if Widget.ShowFog then pcall(function() Widget:ShowFog(false) end) end

    -- Populate independent background layers from MapTrackerComponent
    local tracker = FindFirstOf("MapTrackerComponent")
    if tracker and tracker:IsValid() and tracker.MapBackgrounds then
        local numBgs = tracker.MapBackgrounds:GetArrayNum()
        for i = 1, numBgs do
            local bg = tracker.MapBackgrounds[i]
            if bg and bg:IsValid() and Widget.AddMapBackground then
                pcall(function() Widget:AddMapBackground(bg) end)
            end
        end
        Log(string.format("Populated %d background map layers into Minimap.", numBgs))
    end

    -- Populate map icons
    if tracker and tracker:IsValid() and tracker.MapIcons then
        local numIcons = tracker.MapIcons:GetArrayNum()
        for i = 1, numIcons do
            local icon = tracker.MapIcons[i]
            if icon and icon:IsValid() and Widget.AddMapIcon then
                pcall(function() Widget:AddMapIcon(icon) end)
            end
        end
        Log(string.format("Populated %d icons into Minimap.", numIcons))
    end

    -- Configure widget layers
    if Widget.WidgetTree and Widget.WidgetTree.RootWidget then
        Widget.WidgetTree.RootWidget:SetVisibility(0)
    end
    if Widget.Switcher_MapActive then
        Widget.Switcher_MapActive:SetVisibility(0)
        pcall(function() Widget.Switcher_MapActive:SetActiveWidgetIndex(1) end)
    end

    -- Configure Widget_Camera (The Player Icon)
    pcall(function()
        local cam = Widget.Widget_Camera
        if cam and cam:IsValid() then
            cam:SetVisibility(0)
            if cam.Slot and cam.Slot:IsValid() then
                -- Center the slot in Overlay_Layers (HAlign_Center=2, VAlign_Center=2)
                if cam.Slot.SetHorizontalAlignment then cam.Slot:SetHorizontalAlignment(2) end
                if cam.Slot.SetVerticalAlignment then cam.Slot:SetVerticalAlignment(2) end
            end
            if cam.SetRenderTransformPivot then
                cam:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
            end
            if cam.SetRenderTranslation then
                cam:SetRenderTranslation({ X = 0.0, Y = 0.0 })
            end
            if cam.SetRenderAngle then
                cam:SetRenderAngle(0.0)
            end
        end
    end)

    -- Filter layers: Overworld visible, underground hidden by default
    local cb = Widget.Canvas_Backgrounds
    if cb and cb:IsValid() then
        for i = 0, cb:GetChildrenCount() - 1 do
            local child = cb:GetChildAt(i)
            if child and child:IsValid() then
                child:SetVisibility(i == 0 and 0 or 2)
            end
        end
    end

    CleanupModOrphans(Widget)
    Log("Minimap widget successfully configured and visible in viewport!")
    return true
end

-- 7. Spawn Minimap
local function InitMinimap(ForceRecreate)
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return false end
    if not PC.Pawn or not PC.Pawn:IsValid() then return false end

    if MinimapWidget and MinimapWidget:IsValid() and not ForceRecreate then
        MinimapWidget:SetVisibility(IsMinimapVisible and 0 or 2)
        return true
    end

    if ForceRecreate and MinimapWidget and MinimapWidget:IsValid() then
        pcall(function() MinimapWidget:RemoveFromParent() end)
        MinimapWidget = nil
    end

    local Class = GetMinimapClass()
    if Class and Class:IsValid() then
        local Created = nil
        local WidgetBPLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if WidgetBPLib and WidgetBPLib:IsValid() and WidgetBPLib.Create then
            pcall(function()
                Created = WidgetBPLib:Create(PC, Class, PC)
            end)
        end
        if not Created or not Created:IsValid() then
            pcall(function()
                Created = StaticConstructObject(Class, PC)
            end)
        end
        if Created and Created:IsValid() then
            MinimapWidget = Created
            CurrentPlayerController = PC
            CurrentPawn = PC.Pawn
            -- Invalidate dirty cache so transform immediately applies
            LastU = nil
            LastV = nil
            LastYaw = nil
            LastZoom = nil
            LastRotateState = nil
            return SetupMinimapWidget(MinimapWidget, PC)
        end
    end
    return false
end

-- 8. Real-time Terrain Transformation (Isotropic Centered Math)
local function UpdateMinimapTerrain(PC)
    if not MinimapWidget or not MinimapWidget:IsValid() or MinimapWidget:GetVisibility() ~= 0 then
        return
    end

    local Pawn = PC and PC.Pawn
    if not Pawn or not Pawn:IsValid() then return end

    local pLoc = Pawn:K2_GetActorLocation()
    if not pLoc then return end

    local mv = GetAreaMapView()
    if not mv or not mv:IsValid() then return end

    -- Native C++ engine projection: exactly projects 3D world position to 2D texture UV [0, 1]
    local out = {}
    local ok = pcall(function()
        mv:GetViewCoordinates(pLoc, false, out, {})
    end)
    if not ok or not out.U or not out.V then return end

    local u = out.U
    local v = out.V

    local pRot = Pawn:K2_GetActorRotation()
    local PlayerYaw = pRot and pRot.Yaw or 0.0

    -- Dirty Checking: skip expensive transform updates if player position, rotation, and zoom haven't changed
    if LastU and LastV and LastYaw and LastZoom and LastRotateState ~= nil then
        local du = math.abs(u - LastU)
        local dv = math.abs(v - LastV)
        local dyaw = math.abs(PlayerYaw - LastYaw)
        if du < 0.0001 and dv < 0.0001 and dyaw < 0.1 and LastZoom == CurrentZoom and LastRotateState == RotateWithPlayer then
            return -- Completely stationary: zero CPU overhead!
        end
    end
    LastU = u
    LastV = v
    LastYaw = PlayerYaw
    LastZoom = CurrentZoom
    LastRotateState = RotateWithPlayer

    -- Both axes use the exact same dimension for 100% isotropic 1:1 geometry
    local S = MinimapSide
    local transX = (0.5 - u) * S
    local transY = (0.5 - v) * S
    local mapAngle = RotateWithPlayer and -PlayerYaw or 0.0

    -- Continuously hide fogs on HUD minimap
    if MinimapWidget.Overlay_Fogs and MinimapWidget.Overlay_Fogs:IsValid() then
        if MinimapWidget.Overlay_Fogs:GetVisibility() ~= 2 then
            MinimapWidget.Overlay_Fogs:SetVisibility(2)
        end
    end

    -- Transform Map Layers:
    -- Pivot placed on player (u, v) ensures rotation & scale occur exactly around player center.
    local layers = {
        MinimapWidget.Canvas_Backgrounds,
        MinimapWidget.Canvas_IconsBelowFog,
        MinimapWidget.Canvas_IconsAboveFog
    }

    for _, layer in ipairs(layers) do
        if layer and layer:IsValid() then
            pcall(function()
                layer:SetRenderTransformPivot({ X = u, Y = v })
                layer:SetRenderScale({ X = CurrentZoom, Y = CurrentZoom })
                if layer.SetRenderAngle then
                    layer:SetRenderAngle(mapAngle)
                end
                layer:SetRenderTranslation({ X = transX, Y = transY })
            end)
        end
    end

    -- Keep Player Icon (Widget_Camera) dead center and pointing straight UP (OSRS compass)
    local cam = MinimapWidget.Widget_Camera
    if cam and cam:IsValid() then
        pcall(function()
            cam:SetVisibility(0)
            cam:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
            cam:SetRenderTranslation({ X = 0.0, Y = 0.0 })
            if cam.SetRenderAngle then
                cam:SetRenderAngle(RotateWithPlayer and 0.0 or PlayerYaw)
            end
        end)
    end
end

-- 9. Check Main Map Visibility (Toggle Minimap off when M is pressed)
local function CheckMainMapVisibility()
    local MainMapOpen = false
    if CachedOfficialTopNav and CachedOfficialTopNav:IsValid() then
        local ok, isVis = pcall(function() return CachedOfficialTopNav:IsVisible() end)
        MainMapOpen = ok and isVis
    elseif CachedGameInstance and CachedGameInstance:IsValid() and CachedGameInstance.MainMenuWidget and CachedGameInstance.MainMenuWidget:IsValid() then
        local ok, isVis = pcall(function() return CachedGameInstance.MainMenuWidget:IsVisible() end)
        MainMapOpen = ok and isVis
    else
        local topNav = GetOfficialTopNav()
        if topNav and topNav:IsValid() then
            local ok, isVis = pcall(function() return topNav:IsVisible() end)
            MainMapOpen = ok and isVis
        end
    end

    if MainMapOpen ~= LastMainMapOpen then
        LastMainMapOpen = MainMapOpen
        Log("[VIS] Main Map open status changed to: " .. tostring(MainMapOpen))
        if MainMapOpen then
            EnsureOfficialMapRestored()
        end
    end

    if MinimapWidget and MinimapWidget:IsValid() then
        local desiredVisibility = (IsMinimapVisible and not MainMapOpen) and 0 or 2
        if MinimapWidget:GetVisibility() ~= desiredVisibility then
            MinimapWidget:SetVisibility(desiredVisibility)
        end
    end
end

-- 10. Keybinds
pcall(function()
    -- F6: Toggle Minimap On/Off
    RegisterKeyBind(Key.F6, function()
        ExecuteInGameThread(function()
            if not MinimapWidget or not MinimapWidget:IsValid() then
                InitMinimap(false)
                return
            end
            IsMinimapVisible = not IsMinimapVisible
            CheckMainMapVisibility()
            Log("Minimap visibility toggled: " .. (IsMinimapVisible and "VISIBLE" or "HIDDEN"))
        end)
    end)

    -- F7: Force Reload
    RegisterKeyBind(Key.F7, function()
        ExecuteInGameThread(function()
            Log("Manual reload requested via F7...")
            EnsureOfficialMapRestored()
            InitMinimap(true)
        end)
    end)

    -- F8: Toggle Rotating Compass vs North-Up Map
    RegisterKeyBind(Key.F8, function()
        ExecuteInGameThread(function()
            RotateWithPlayer = not RotateWithPlayer
            LastRotateState = nil -- Force transform refresh
            Log("Minimap compass rotation: " .. (RotateWithPlayer and "ENABLED (Rotating Map)" or "DISABLED (North-Up)"))
        end)
    end)

    -- PageUp / PageDown: Zoom
    RegisterKeyBind(Key.PAGE_UP, function()
        ExecuteInGameThread(function()
            CurrentZoom = math.min(32.0, CurrentZoom + 1.0)
            LastZoom = nil -- Force transform refresh
            Log(string.format("Minimap zoom: %.1fx", CurrentZoom))
        end)
    end)
    RegisterKeyBind(Key.PAGE_DOWN, function()
        ExecuteInGameThread(function()
            CurrentZoom = math.max(2.0, CurrentZoom - 1.0)
            LastZoom = nil -- Force transform refresh
            Log(string.format("Minimap zoom: %.1fx", CurrentZoom))
        end)
    end)

    -- [ and ]: Size
    RegisterKeyBind(Key.OEM_FOUR, function()
        ExecuteInGameThread(function()
            MinimapSide = math.max(160.0, MinimapSide - 20.0)
            ApplyMinimapTransform()
            LastZoom = nil -- Force transform refresh
            Log(string.format("Minimap size: %.1fx%.1f", MinimapSide, MinimapSide))
        end)
    end)
    RegisterKeyBind(Key.OEM_SIX, function()
        ExecuteInGameThread(function()
            MinimapSide = math.min(600.0, MinimapSide + 20.0)
            ApplyMinimapTransform()
            LastZoom = nil -- Force transform refresh
            Log(string.format("Minimap size: %.1fx%.1f", MinimapSide, MinimapSide))
        end)
    end)
end)

-- 11. Main Loop
local function UpdateMinimap()
    local PC = UEHelpers.GetPlayerController()
    
    -- Always check Main Map visibility (O(1) cached check, zero scans)
    CheckMainMapVisibility()

    local Pawn = PC and PC:IsValid() and PC.Pawn
    if not Pawn or not Pawn:IsValid() then
        if MinimapWidget and MinimapWidget:IsValid() then
            MinimapWidget:SetVisibility(2)
        end
        return
    end

    local ownerChanged = CurrentPlayerController and
        (not CurrentPlayerController:IsValid() or CurrentPlayerController:GetAddress() ~= PC:GetAddress()
        or not CurrentPawn or not CurrentPawn:IsValid() or CurrentPawn:GetAddress() ~= Pawn:GetAddress())
    if ownerChanged or not MinimapWidget or not MinimapWidget:IsValid() then
        if UpdateTick < NextInitTick then return end
        NextInitTick = UpdateTick + 20
        if ownerChanged then
            CachedOfficialMap = nil
            CachedOfficialTopNav = nil
            CachedAreaMapView = nil
            CachedGameInstance = nil
        end
        EnsureOfficialMapRestored()
        InitMinimap(ownerChanged)
        return
    end

    UpdateMinimapTerrain(PC)
end

LoopAsync(50, function()
    UpdateTick = UpdateTick + 1
    if UpdatePending then return false end
    UpdatePending = true
    local queued, queueError = pcall(function()
        ExecuteInGameThread(function()
            local ok, err = pcall(UpdateMinimap)
            UpdatePending = false
            if not ok then
                local message = tostring(err)
                if message ~= LastUpdateError then
                    Log("[UPDATE ERROR] " .. message)
                    LastUpdateError = message
                end
            else
                LastUpdateError = nil
            end
        end)
    end)
    if not queued then
        UpdatePending = false
        if tostring(queueError) ~= LastUpdateError then
            Log("[QUEUE ERROR] " .. tostring(queueError))
            LastUpdateError = tostring(queueError)
        end
    end
    return false
end)

-- On mod load: restore official map right away and print concise status
ExecuteInGameThread(function()
    EnsureOfficialMapRestored()
    
    local PC = UEHelpers.GetPlayerController()
    local pawn = PC and PC.Pawn
    local pLoc = pawn and pawn:K2_GetActorLocation()
    local pRot = pawn and pawn:K2_GetActorRotation()
    Log(string.format("[INIT] Player Loc: (%.1f, %.1f, %.1f) | Yaw=%.1f", 
        pLoc and pLoc.X or 0, pLoc and pLoc.Y or 0, pLoc and pLoc.Z or 0, pRot and pRot.Yaw or 0))

    local mv = GetAreaMapView()
    if mv and mv:IsValid() and pLoc then
        local out = {}
        mv:GetViewCoordinates(pLoc, false, out, {})
        Log(string.format("[INIT] Engine GPS Coordinates: U=%.4f, V=%.4f", out.U or -1, out.V or -1))
    end
end)

Log("OSRS Minimap ready. F6: toggle, F7: recreate, F8: compass rotate, PageUp/Down: zoom, [/]: size.")
