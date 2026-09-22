local UEHelpers = require("UEHelpers")

local ModName = "OSRSMinimap"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing OSRS Minimap (Zero Main Map Touch)...")
Log("==========================================")

-- State
local MinimapWidget = nil
local CurrentPlayerController = nil
local IsMinimapVisible = true
local CurrentZoom = 16.0
local CurrentPawn = nil
local UpdatePending = false
local UpdateTick = 0
local NextInitTick = 0
local NextBackgroundTick = 0
local NextOfficialSearchTick = 0
local NextSizeRetryTick = 0
local LastUpdateError = nil
local MinimapClass = nil
local CachedBackgroundMID = nil
local CachedBackgroundChild = nil

-- KEY FIX: Clean up ANY existing mod minimaps from viewport immediately to prevent GPU stacking lag!
local function CleanupAllOrphans(keepWidget)
    local all = FindAllOf("WBP_DominionMinimap_C")
    if all then
        local count = 0
        for _, w in ipairs(all) do
            if w:IsValid() and not string.find(w:GetFullName(), "MapPanel") then
                if not keepWidget or w:GetAddress() ~= keepWidget:GetAddress() then
                    pcall(function()
                        w:RemoveFromParent()
                        w:SetVisibility(2)
                    end)
                    count = count + 1
                end
            end
        end
        if count > 0 then
            Log(string.format("[CLEANUP] Removed %d orphaned Minimap widgets from viewport!", count))
        end
    end
end

-- Keybinds reference
local Key = Key

-- 1. Helper: Find Minimap Class
local function GetMinimapClass()
    if MinimapClass and MinimapClass:IsValid() then
        return MinimapClass
    end

    local ClassPath = "/Game/UI/HUD/ModifiedMinimapPlugin/WBP_DominionMinimap.WBP_DominionMinimap_C"
    MinimapClass = StaticFindObject(ClassPath)
    if MinimapClass and MinimapClass:IsValid() then
        Log("Found Minimap class via StaticFindObject: " .. ClassPath)
        return MinimapClass
    end

    local AssetRegistryHelpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if AssetRegistryHelpers and AssetRegistryHelpers:IsValid() then
        local AssetData = {
            ["PackageName"] = UEHelpers.FindOrAddFName("/Game/UI/HUD/ModifiedMinimapPlugin/WBP_DominionMinimap"),
            ["AssetName"] = UEHelpers.FindOrAddFName("WBP_DominionMinimap_C")
        }
        local LoadedAsset = AssetRegistryHelpers:GetAsset(AssetData)
        if LoadedAsset and LoadedAsset:IsValid() then
            MinimapClass = LoadedAsset
            Log("Loaded Minimap class via AssetRegistryHelpers: " .. ClassPath)
            return MinimapClass
        end
    end

    if StaticLoadObject then
        local Loaded = StaticLoadObject(nil, nil, ClassPath)
        if Loaded and Loaded:IsValid() then
            MinimapClass = Loaded
            Log("Loaded Minimap class via StaticLoadObject: " .. ClassPath)
            return MinimapClass
        end
    end

    Log("[Warning] Could not load Minimap class: " .. ClassPath)
    return nil
end

local CurrentScale = 0.22
local Offset_X = -25.0
local Offset_Y = 25.0

local function GetScreenAspectRatio()
    local Engine = UEHelpers.GetEngine()
    if Engine and Engine:IsValid() and Engine.GameViewport then
        local Size = { X = 0, Y = 0 }
        pcall(function()
            Engine.GameViewport:GetViewportSize(Size)
        end)
        if Size.X and Size.Y and Size.Y > 0 then
            return Size.X / Size.Y
        end
    end
    return 16.0 / 9.0
end

local CachedOfficialMap = nil
local function GetOfficialMap()
    if CachedOfficialMap and CachedOfficialMap:IsValid() then
        return CachedOfficialMap
    end

    if UpdateTick < NextOfficialSearchTick then return nil end
    NextOfficialSearchTick = UpdateTick + 20
    local AllMinimaps = FindAllOf("WBP_DominionMinimap_C")
    if AllMinimaps then
        for _, M in ipairs(AllMinimaps) do
            if M:IsValid() and string.find(M:GetFullName(), "MapPanel") then
                CachedOfficialMap = M
                return CachedOfficialMap
            end
        end
    end
    return nil
end

local function ApplyMinimapTransform()
    if not MinimapWidget or not MinimapWidget:IsValid() then return end
    pcall(function()
        local AspectRatio = GetScreenAspectRatio()
        local Scale_Y = CurrentScale
        local Scale_X = CurrentScale / AspectRatio

        if MinimapWidget.SetRenderTransformPivot then
            MinimapWidget:SetRenderTransformPivot({ X = 1.0, Y = 0.0 })
        end
        if MinimapWidget.SetRenderScale then
            MinimapWidget:SetRenderScale({ X = Scale_X, Y = Scale_Y })
        end
        if MinimapWidget.SetRenderTranslation then
            MinimapWidget:SetRenderTranslation({ X = Offset_X, Y = Offset_Y })
        end
        Log(string.format("Applied Minimap Transform: Scale=(%.3f, %.3f), Offset=(%.1f, %.1f)", Scale_X, Scale_Y, Offset_X, Offset_Y))
    end)
end

-- 3. Setup Standalone Minimap Widget (Never touching Official Map)
local function SetupMinimapWidget(Widget, PC)
    if not Widget or not Widget:IsValid() then return false end

    -- Add to Viewport with Z-Order 100
    Widget:AddToViewport(100)
    Widget:SetVisibility(IsMinimapVisible and 0 or 2)
    pcall(function()
        if Widget.ActivateWidget then Widget:ActivateWidget() end
    end)

    -- Apply RenderTransform for top-right corner
    ApplyMinimapTransform()

    local Pawn = PC and PC.Pawn
    if Pawn and Pawn:IsValid() then
        local MapView = Pawn.MapView
        if MapView and MapView:IsValid() then
            pcall(function()
                Widget:SetMapView(MapView)
                Widget.MapViewComp = MapView
                Log("Connected Widget to Pawn.MapView (read-only)")
            end)
        end
    end

    -- Circular shape & player camera frustum
    pcall(function()
        Widget.bIsCircular = false
        if Widget.ReinitShape then Widget:ReinitShape() end
    end)
    pcall(function()
        Widget.bDrawCamera = true
        if Widget.InitDrawFrustum then Widget:InitDrawFrustum() end
    end)

    -- Hide Fog of War / Clouds so the land is clearly visible!
    pcall(function()
        if Widget.Overlay_Fogs and Widget.Overlay_Fogs:IsValid() then
            Widget.Overlay_Fogs:SetVisibility(2)
            local count = Widget.Overlay_Fogs:GetChildrenCount()
            for i = 0, count - 1 do
                local fc = Widget.Overlay_Fogs:GetChildAt(i)
                if fc and fc:IsValid() then fc:SetVisibility(2) end
            end
            Log("Set Widget.Overlay_Fogs and children to COLLAPSED (2) - Clouds hidden!")
        end
        if Widget.ShowFog then
            Widget:ShowFog(false)
            Log("Called Widget:ShowFog(false)")
        end
    end)

    -- Connect MapTrackerComp from GameState or OfficialMap
    pcall(function()
        local Official = GetOfficialMap()
        local tracker = Official and Official:IsValid() and Official.MapTrackerComp
        if not tracker or not tracker:IsValid() then
            local GS = UEHelpers.GetGameStateBase()
            tracker = GS and GS:IsValid() and GS.MapTracker
        end
        if tracker and tracker:IsValid() then
            Widget.MapTrackerComp = tracker
            Log("Connected Widget.MapTrackerComp: " .. tracker:GetFullName())
        end
    end)

    -- Set InitialMapSize to match Official Map so layout math succeeds
    pcall(function()
        local Official = GetOfficialMap()
        if Official and Official:IsValid() and Official.InitialMapSize and Official.InitialMapSize.X > 0 then
            Widget.InitialMapSize = { X = Official.InitialMapSize.X, Y = Official.InitialMapSize.Y }
            Log(string.format("Copied InitialMapSize from Official: (%.1f, %.1f)", Widget.InitialMapSize.X, Widget.InitialMapSize.Y))
        else
            Widget.InitialMapSize = { X = 2580.0, Y = 935.0 }
            Log("Set default InitialMapSize: (2580.0, 935.0)")
        end
    end)

    -- Initialize map via native plugin lifecycle functions
    pcall(function()
        if Widget.InitMap then
            Widget:InitMap()
            Log("Called Widget:InitMap()")
        end
    end)
    pcall(function()
        if Widget.SetupListeners then
            Widget:SetupListeners()
            Log("Called Widget:SetupListeners()")
        end
    end)
    pcall(function()
        if Widget.SetupViewListener then
            Widget:SetupViewListener()
            Log("Called Widget:SetupViewListener()")
        end
    end)
    pcall(function()
        if Widget.InitFillBackground then
            Widget:InitFillBackground()
            Log("Called Widget:InitFillBackground()")
        end
    end)

    -- Populate icons only. AddMapBackground() reparents the native background
    -- widget and therefore steals it from the main map. InitFillBackground()
    -- above creates this widget's own background instances safely.
    pcall(function()
        local tracker = Widget.MapTrackerComp
        if not tracker or not tracker:IsValid() then return end

        -- Add icons without touching the background arrays.
        local icons = tracker.MapIcons
        if icons then
            local numIcons = icons.GetArrayNum and icons:GetArrayNum() or 0
            Log(string.format("[POPULATE] tracker.MapIcons has %d items", numIcons))
            for i = 1, numIcons do
                local icon = icons[i]
                if icon and icon:IsValid() then
                    pcall(function()
                        if Widget.AddMapIcon then
                            Widget:AddMapIcon(icon)
                        end
                    end)
                end
            end
            Log(string.format("    Populated %d icons into Widget!", numIcons))
        end

        -- Check that native initialization produced independent backgrounds.
        local sw = Widget.Switcher_MapActive
        if sw and sw:IsValid() and sw:GetChildrenCount() > 1 then
            local ol = sw:GetChildAt(1)
            if ol and ol:IsValid() and ol:GetChildrenCount() > 1 then
                local cb = ol:GetChildAt(1)
                if cb and cb:IsValid() then
                    local cbCount = cb:GetChildrenCount()
                    Log(string.format("[POPULATE CHECK] Canvas_Backgrounds child count: %d", cbCount))
                    for cIdx = 0, cbCount - 1 do
                        local child = cb:GetChildAt(cIdx)
                        if child and child:IsValid() then
                            Log(string.format("  [Canvas_Bg Child %d] %s (Vis: %d)", cIdx, child:GetFullName(), child:GetVisibility()))
                            child:SetVisibility(0)
                        end
                    end
                end
            end
        end
    end)

    -- Configure layers safely
    local cfgOk, cfgErr = pcall(function()
        if Widget.WidgetTree and Widget.WidgetTree.RootWidget then
            Widget.WidgetTree.RootWidget:SetVisibility(0)
            Log("Set Widget.WidgetTree.RootWidget (CanvasPanel_0) to VISIBLE (0)!")
        end

        if Widget.Switcher_MapActive then
            Widget.Switcher_MapActive:SetVisibility(0)
            pcall(function()
                Widget.Switcher_MapActive:SetActiveWidgetIndex(1)
                Log("Called Widget.Switcher_MapActive:SetActiveWidgetIndex(1)")
            end)
        end

        -- Get Overlay_Layers from Switcher_MapActive child 1
        local switcher = Widget.Switcher_MapActive
        local overlayLayers = nil
        if switcher and switcher:IsValid() and switcher:GetChildrenCount() > 1 then
            overlayLayers = switcher:GetChildAt(1)
        end

        if overlayLayers and overlayLayers:IsValid() then
            overlayLayers:SetVisibility(0)
        end

        -- Focused Diagnostic on Canvas_Backgrounds and Map Coordinates
        Log("=== DIAGNOSTIC: Canvas_Backgrounds & Coordinates ===")
        local PC_Pawn = PC and PC.Pawn
        if PC_Pawn and PC_Pawn:IsValid() then
            local pLoc = PC_Pawn:K2_GetActorLocation()
            Log(string.format("Pawn Location: (X=%.1f, Y=%.1f, Z=%.1f)", pLoc.X, pLoc.Y, pLoc.Z))
        end

        local cb = Widget.Canvas_Backgrounds
        if cb and cb:IsValid() then
            local numBgs = cb:GetChildrenCount()
            Log(string.format("Widget.Canvas_Backgrounds has %d children", numBgs))
            local mapW = Widget.InitialMapSize and Widget.InitialMapSize.X or 2580.0
            local mapH = Widget.InitialMapSize and Widget.InitialMapSize.Y or 935.0
            for i = 0, numBgs - 1 do
                local child = cb:GetChildAt(i)
                if child and child:IsValid() then
                    local cSlot = child.Slot
                    pcall(function()
                        if cSlot and cSlot:IsValid() then
                            if cSlot.SetSize then cSlot:SetSize({ X = mapW, Y = mapH }) end
                            if cSlot.SetPosition then cSlot:SetPosition({ X = 0.0, Y = 0.0 }) end
                        end
                    end)
                    if i == 0 then
                        child:SetVisibility(0) -- Visible: Main landmass!
                        CachedBackgroundChild = child
                        CachedBackgroundMID = child.BackgroundMaterialInstance
                        Log(string.format("  [Overworld Bg 0] Visible | Mat: %s",
                            CachedBackgroundMID and CachedBackgroundMID:IsValid() and CachedBackgroundMID:GetFullName() or "nil"))
                    else
                        child:SetVisibility(2) -- Collapsed: Hide underground cave so it doesn't cover land!
                        Log(string.format("  [Underground Bg %d] Collapsed (hidden)", i))
                    end
                end
            end
        end

        Log("=== END DIAGNOSTIC ===")
    end)
    if not cfgOk then
        Log("[CONFIG ERROR] " .. tostring(cfgErr))
    end

    -- Clean up any orphaned mod minimaps from viewport (keep only this active one)
    CleanupAllOrphans(Widget)

    Log("Minimap widget successfully configured and visible in viewport!")
    return true
end

-- 4. Spawn or Locate Minimap
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

    CachedBackgroundMID = nil
    CachedBackgroundChild = nil
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
            return SetupMinimapWidget(MinimapWidget, PC)
        end
    end

    return false
end



local function UpdateMinimapTerrain(PC)
    if not MinimapWidget or not MinimapWidget:IsValid() or MinimapWidget:GetVisibility() ~= 0 then
        return
    end

    local Pawn = PC and PC.Pawn
    if not Pawn or not Pawn:IsValid() then return end

    -- Hide Clouds / Fog Overlays continuously
    pcall(function()
        if MinimapWidget.Overlay_Fogs and MinimapWidget.Overlay_Fogs:IsValid() then
            if MinimapWidget.Overlay_Fogs:GetVisibility() ~= 2 then
                MinimapWidget.Overlay_Fogs:SetVisibility(2)
            end
        end
    end)

    pcall(function()
        if MinimapWidget.Canvas_Backgrounds and MinimapWidget.Canvas_Backgrounds:IsValid() then
            local zoomFactor = 8.0
            MinimapWidget.Canvas_Backgrounds:SetRenderScale({ X = zoomFactor, Y = zoomFactor })
            
            local Official = GetOfficialMap()
            if Official and Official:IsValid() then
                if Official:GetVisibility() ~= 0 then
                    Official.AutoLocateMapView = 2
                end
                
                local nativeOffset = Official.MapOffset
                if nativeOffset then
                    MinimapWidget.Canvas_Backgrounds:SetRenderTranslation({ X = nativeOffset.X * zoomFactor, Y = nativeOffset.Y * zoomFactor })
                end
            end
            
            MinimapWidget.Canvas_Backgrounds:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
            local PawnRot = Pawn:K2_GetActorRotation()
            if PawnRot then
                MinimapWidget.Canvas_Backgrounds:SetRenderAngle(-PawnRot.Yaw)
            end
        end
        
        if MinimapWidget.Widget_PlayerIcon and MinimapWidget.Widget_PlayerIcon:IsValid() then
            MinimapWidget.Widget_PlayerIcon:SetRenderAngle(0.0)
        end
        
        if MinimapWidget.Widget_Camera and MinimapWidget.Widget_Camera:IsValid() then
            MinimapWidget.Widget_Camera:SetRenderTranslation({ X = 0.0, Y = 0.0 })
        end
    end)
end


-- 6. Keybinds
pcall(function()
    -- F6: Toggle Minimap On/Off (F8 is reserved for the UE4SS GUI)
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
            InitMinimap(true)
        end)
    end)

    -- PageUp / PageDown: Zoom
    RegisterKeyBind(Key.PAGE_UP, function()
        ExecuteInGameThread(function()
            CurrentZoom = math.min(48.0, CurrentZoom + 1.0)
            Log(string.format("Minimap zoom: %.1fx", CurrentZoom))
        end)
    end)
    RegisterKeyBind(Key.PAGE_DOWN, function()
        ExecuteInGameThread(function()
            CurrentZoom = math.max(2.0, CurrentZoom - 1.0)
            Log(string.format("Minimap zoom: %.1fx", CurrentZoom))
        end)
    end)

    -- [ and ]: Size
    RegisterKeyBind(Key.OEM_FOUR, function()
        ExecuteInGameThread(function()
            CurrentScale = math.max(0.08, CurrentScale - 0.02)
            ApplyMinimapTransform()
        end)
    end)
    RegisterKeyBind(Key.OEM_SIX, function()
        ExecuteInGameThread(function()
            CurrentScale = math.min(0.50, CurrentScale + 0.02)
            ApplyMinimapTransform()
        end)
    end)
end)

-- 7. Queue at most one game-thread update; retry expensive setup once a second.
local function UpdateMinimap()
    local PC = UEHelpers.GetPlayerController()
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
            NextOfficialSearchTick = 0
        end
        InitMinimap(ownerChanged)
        return
    end

    local cb = MinimapWidget.Canvas_Backgrounds
    if cb and cb:IsValid() and cb:GetChildrenCount() == 0 and UpdateTick >= NextBackgroundTick then
        NextBackgroundTick = UpdateTick + 20
        local Official = GetOfficialMap()
        local tracker = Official and Official:IsValid() and Official.MapTrackerComp
        if tracker and tracker:IsValid() then
            MinimapWidget.MapTrackerComp = tracker
            if MinimapWidget.InitFillBackground then MinimapWidget:InitFillBackground() end
        end
    end
    CheckMainMapVisibility()
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

Log("OSRS Minimap ready. F6: toggle, F7: recreate widget, PageUp/Down: zoom, [/]: size.")

