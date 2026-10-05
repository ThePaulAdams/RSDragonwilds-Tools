local UEHelpers = require("UEHelpers")

local ModName = "OSRSMinimap"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing OSRS Minimap (Ornate RuneScape HUD v3)...")
Log("==========================================")

-- State
local MinimapWidget = nil
local CurrentPlayerController = nil
local IsMinimapVisible = true
local CurrentZoom = 12.0
local CurrentPawn = nil
local PrivateMapView = nil
local UpdatePending = false
local UpdateTick = 0
local NextInitTick = 0
local NextBackgroundTick = 0
local NextOfficialSearchTick = 0
local NextSizeRetryTick = 0
local LastUpdateError = nil
local ReadyPawnAddress = nil
local ReadyAfterTick = 0
local MinimapClass = nil
local CachedBackgroundMID = nil
local CachedBackgroundChild = nil
local LastTerrainOffsetX = nil
local LastTerrainOffsetY = nil
local LastTerrainZoom = nil

-- Visual Frame & Shape State
local IsCircularMode = true
local BorderOuter = nil
local BorderGold = nil
local BorderInner = nil
local CircularBezelImage = nil
local DayNightWidget = nil
local DayNightBezel = nil
local DayNightShadow = nil
local NorthIndicator = nil

-- Resource & AI Tracking State
local ResourceIconsEnabled = true
local AiRadarEnabled = true
local LandmarkIconsEnabled = true
local TrackedResourceActors = {}
local TrackedAiActors = {}
local TrackedLandmarkActors = {}
local NextResourceScanTick = 0
local NextAiScanTick = 0
local NextLandmarkScanTick = 0
local LastResourceScanLocation = nil
local MapIconCompClass = nil
local PurgeAllResourceComponents = nil

-- Persist only a name across Lua reloads, never a transient UObject pointer.
local OwnedWidgetName = nil
if ModRef then
    pcall(function() OwnedWidgetName = ModRef:GetSharedVariable("OSRSMinimap.OwnedWidgetName") end)
end
local function CleanupAllOrphans(keepWidget)
    if not OwnedWidgetName then return end
    local all = FindAllOf("WBP_DominionMinimap_C") or {}
    for _, w in ipairs(all) do
        if w:IsValid() and w:GetFullName() == OwnedWidgetName
            and (not keepWidget or w:GetAddress() ~= keepWidget:GetAddress()) then
            pcall(function() w:DeactivateWidget() end)
            w:RemoveFromParent()
            w:SetVisibility(2)
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
            local parentOk, parent = pcall(function() return M:GetParent() end)
            if M:IsValid() and M:GetFullName() ~= OwnedWidgetName
                and (not MinimapWidget or M:GetAddress() ~= MinimapWidget:GetAddress())
                and parentOk and parent and parent:IsValid() then
                CachedOfficialMap = M
                return CachedOfficialMap
            end
        end
    end
    return nil
end

local function ApplyMinimapTransform()
    if not MinimapWidget or not MinimapWidget:IsValid() then return end
    local side = math.floor(320 * CurrentScale / 0.22)
    MinimapWidget:SetRenderTransformPivot({ X = 0.0, Y = 0.0 })
    MinimapWidget:SetRenderScale({ X = 1.0, Y = 1.0 })
    MinimapWidget:SetRenderTranslation({ X = 0.0, Y = 0.0 })
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() or not layout or not layout:IsValid() then return end
    local viewport = layout:GetViewportSize(PC)
    local dpi = layout:GetViewportScale(PC)
    if not viewport or not dpi or dpi <= 0 then return end
    local x = viewport.X / dpi - side - 24
    MinimapWidget:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
    MinimapWidget:SetPositionInViewport({ X = x, Y = 24.0 }, false)
    MinimapWidget:SetDesiredSizeInViewport({ X = side, Y = side })
    MinimapWidget:SetAnchorsInViewport({ Minimum = {X=0.0,Y=0.0}, Maximum = {X=0.0,Y=0.0} })
    Log(string.format("Viewport minimap: %dx%d, top-right margin 24", side, side))
end

local function GetMapIconWidgetCount(mapWidget)
    if not mapWidget or not mapWidget:IsValid() then return 0 end
    local count = 0
    pcall(function()
        if mapWidget.Canvas_IconsBelowFog and mapWidget.Canvas_IconsBelowFog:IsValid() then
            count = count + mapWidget.Canvas_IconsBelowFog:GetChildrenCount()
        end
        if mapWidget.Canvas_IconsAboveFog and mapWidget.Canvas_IconsAboveFog:IsValid() then
            count = count + mapWidget.Canvas_IconsAboveFog:GetChildrenCount()
        end
    end)
    return count
end

-- =========================================================================
-- 2. Ornate RuneScape Dual-Ring Frame & Sundial Bezel
-- =========================================================================

local function CreateBorderWidget(outer, PC, widgetName)
    local borderClass = StaticFindObject("/Script/UMG.Border")
    if not borderClass or not borderClass:IsValid() then return nil end
    local border = nil
    local ok, res = pcall(function() return StaticConstructObject(borderClass, outer) end)
    if ok and type(res) == "userdata" and res.IsValid and res:IsValid() then
        border = res
    end
    return border
end

local function CreateImageWidget(outer, widgetName)
    local imageClass = StaticFindObject("/Script/UMG.Image")
    if not imageClass or not imageClass:IsValid() then return nil end
    local image = nil
    local ok, res = pcall(function() return StaticConstructObject(imageClass, outer) end)
    if ok and type(res) == "userdata" and res.IsValid and res:IsValid() then
        image = res
    end
    return image
end

local function ConfigureSolidBezel(border, isCircular, r, g, b, a)
    if not border or not border:IsValid() then return end
    pcall(function()
        border:SetVisibility(3) -- HitTestInvisible (visible to render, does not block mouse clicks)
        border:SetBrushColor({ R = r, G = g, B = b, A = a })
        local brush = border.Background
        if brush then
            brush.DrawAs = 4 -- ESlateBrushDrawType::RoundedBox
            brush.TintColor = {
                SpecifiedColor = { R = r, G = g, B = b, A = a },
                ColorUseRule = 0
            }
            local outline = brush.OutlineSettings or {}
            if isCircular then
                outline.RoundingType = 1 -- ESlateBrushRoundingType::HalfRadius (perfect circle)
                outline.CornerRadii = { X = 0.0, Y = 0.0, Z = 0.0, W = 0.0 }
            else
                outline.RoundingType = 0 -- ESlateBrushRoundingType::FixedRadius
                outline.CornerRadii = { X = 12.0, Y = 12.0, Z = 12.0, W = 12.0 }
            end
            outline.Width = 0.0
            outline.bUseBrushTransparency = false
            brush.OutlineSettings = outline
            border:SetBrush(brush)
        end
    end)
end

local function SetupMinimapFrame(Widget, PC)
    if not Widget or not Widget:IsValid() then return end
    local rootCanvas = Widget.WidgetTree and Widget.WidgetTree.RootWidget
    if not rootCanvas or not rootCanvas:IsValid() or not rootCanvas.AddChildToCanvas then return end

    -- Inspect rootCanvas children: prioritize RetainerBox and collapse native square backgrounds
    if rootCanvas.GetChildrenCount then
        for i = 0, rootCanvas:GetChildrenCount() - 1 do
            local c = rootCanvas:GetChildAt(i)
            if c and c:IsValid() then
                local name = c:GetFullName()
                if name:match("RetainerBox") then
                    if c.Slot and c.Slot:IsValid() and c.Slot.SetZOrder then
                        c.Slot:SetZOrder(10)
                    end
                elseif name:match("OpaqueBackground") or name:match("Image_Opaque") then
                    pcall(function() c:SetVisibility(2) end)
                    Log("[FRAME] Collapsed square background: " .. name)
                end
            end
        end
    end

    if Widget.Image_OpaqueBackground and Widget.Image_OpaqueBackground:IsValid() then
        pcall(function() Widget.Image_OpaqueBackground:SetVisibility(2) end)
    end

    -- 1. Outer Antique Bronze Shadow Rim (ZOrder 0, for Tablet/Rectangular Mode ONLY)
    if not BorderOuter or not BorderOuter:IsValid() then
        BorderOuter = CreateBorderWidget(Widget, PC, "OSRSBorderOuter")
        if BorderOuter and BorderOuter:IsValid() then
            local slot = rootCanvas:AddChildToCanvas(BorderOuter)
            if slot and slot:IsValid() then
                slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                slot:SetOffsets({ Left = -6.0, Top = -6.0, Right = -6.0, Bottom = -6.0 })
                slot:SetZOrder(0)
            end
        end
    end
    if BorderOuter and BorderOuter:IsValid() then
        BorderOuter:SetVisibility(IsCircularMode and 2 or 3)
        if not IsCircularMode then
            ConfigureSolidBezel(BorderOuter, false, 0.05, 0.04, 0.02, 0.95)
        end
    end

    -- 2. Circular Ornate RuneScape Golden Bezel Image (ZOrder 50, directly overlaying minimap perimeter)
    if not CircularBezelImage or not CircularBezelImage:IsValid() then
        CircularBezelImage = CreateImageWidget(Widget, "OSRSMinimapBezelImage")
        if CircularBezelImage and CircularBezelImage:IsValid() then
            local slot = rootCanvas:AddChildToCanvas(CircularBezelImage)
            if slot and slot:IsValid() then
                slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                slot:SetOffsets({ Left = -3.0, Top = -3.0, Right = -3.0, Bottom = -3.0 })
                slot:SetZOrder(50)
            end
        end
    end
    if CircularBezelImage and CircularBezelImage:IsValid() then
        pcall(function()
            CircularBezelImage:SetVisibility(IsCircularMode and 3 or 2)
            local ringTex = StaticFindObject("/Game/Art/UI/Craft/T_Craft_CircleTrim.T_Craft_CircleTrim")
                or StaticFindObject("/Game/Art/UI/Enchantment/T_Enchantment_Ring_Yellow.T_Enchantment_Ring_Yellow")
                or StaticFindObject("/Game/Art/UI/Craft/Runecrafting/T_Runecrafting_Ring.T_Runecrafting_Ring")
            if ringTex and ringTex:IsValid() then
                CircularBezelImage:SetBrushFromTexture(ringTex, false)
                Log("[BEZEL] Applied authentic RuneScape ring texture: " .. ringTex:GetFullName())
            end
            CircularBezelImage:SetColorAndOpacity({ R = 1.0, G = 0.84, B = 0.30, A = 1.0 })
        end)
    end

    -- 3. Rectangular Gold Frame for Tablet Mode (ZOrder 5, active when IsCircularMode == false)
    if not BorderGold or not BorderGold:IsValid() then
        BorderGold = CreateBorderWidget(Widget, PC, "OSRSBorderGold")
        if BorderGold and BorderGold:IsValid() then
            local slot = rootCanvas:AddChildToCanvas(BorderGold)
            if slot and slot:IsValid() then
                slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                slot:SetOffsets({ Left = -3.0, Top = -3.0, Right = -3.0, Bottom = -3.0 })
                slot:SetZOrder(5)
            end
        end
    end
    if BorderGold and BorderGold:IsValid() then
        BorderGold:SetVisibility(IsCircularMode and 2 or 3)
        if not IsCircularMode then
            ConfigureSolidBezel(BorderGold, false, 0.96, 0.80, 0.25, 1.0)
        end
    end

    -- 4. Top-layer Compass North Indicator (ZOrder 100, at 12 o'clock)
    if not NorthIndicator or not NorthIndicator:IsValid() then
        NorthIndicator = CreateImageWidget(Widget, "OSRSNorthIndicator")
        if NorthIndicator and NorthIndicator:IsValid() then
            local slot = rootCanvas:AddChildToCanvas(NorthIndicator)
            if slot and slot:IsValid() then
                slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.0 }, Maximum = { X = 0.5, Y = 0.0 } })
                slot:SetAlignment({ X = 0.5, Y = 0.5 })
                slot:SetPosition({ X = 0.0, Y = 0.0 })
                slot:SetSize({ X = 20.0, Y = 20.0 })
                slot:SetZOrder(100)
            end
        end
    end
    if NorthIndicator and NorthIndicator:IsValid() then
        pcall(function()
            NorthIndicator:SetVisibility(IsCircularMode and 3 or 2)
            local markerTex = StaticFindObject("/Game/Art/UI/Compass/2025/T_Compass_DirectionMarker.T_Compass_DirectionMarker")
                or StaticFindObject("/Game/Art/UI/NavIcons/T_Map_Icon_Pin.T_Map_Icon_Pin")
            if markerTex and markerTex:IsValid() then
                NorthIndicator:SetBrushFromTexture(markerTex, false)
            end
            NorthIndicator:SetColorAndOpacity({ R = 0.98, G = 0.20, B = 0.20, A = 1.0 })
        end)
    end
end

local function UpdateMinimapShape(isCircular)
    IsCircularMode = isCircular
    if not MinimapWidget or not MinimapWidget:IsValid() then return end

    pcall(function()
        MinimapWidget.bIsCircular = IsCircularMode
        if MinimapWidget.ReinitShape then
            MinimapWidget:ReinitShape()
        elseif MinimapWidget.InitShape then
            MinimapWidget:InitShape()
        end
    end)

    if CircularBezelImage and CircularBezelImage:IsValid() then
        CircularBezelImage:SetVisibility(IsCircularMode and 3 or 2)
    end
    if BorderGold and BorderGold:IsValid() then
        BorderGold:SetVisibility(IsCircularMode and 2 or 3)
        if not IsCircularMode then
            ConfigureSolidBezel(BorderGold, false, 0.96, 0.80, 0.25, 1.0)
        end
    end
    if BorderOuter and BorderOuter:IsValid() then
        BorderOuter:SetVisibility(IsCircularMode and 2 or 3)
        if not IsCircularMode then
            ConfigureSolidBezel(BorderOuter, false, 0.05, 0.04, 0.02, 0.95)
        end
    end
    if NorthIndicator and NorthIndicator:IsValid() then
        NorthIndicator:SetVisibility(IsCircularMode and 3 or 2)
    end

    Log("[SHAPE] Minimap shape updated to " .. (IsCircularMode and "CIRCULAR (Compass)" or "RECTANGULAR (Tablet)"))
end

-- =========================================================================
-- 3. Setup Standalone Minimap Widget
-- =========================================================================
local function SetupMinimapWidget(Widget, PC)
    if not Widget or not Widget:IsValid() then return false end

    -- Pre-initialize InitialMapSize to prevent divide-by-zero during early Slate layout
    pcall(function()
        local official = GetOfficialMap()
        if official and official:IsValid() and official.InitialMapSize and official.InitialMapSize.X > 0 and official.InitialMapSize.Y > 0 then
            Widget.InitialMapSize = { X = official.InitialMapSize.X, Y = official.InitialMapSize.Y }
        elseif not Widget.InitialMapSize or Widget.InitialMapSize.X <= 0 or Widget.InitialMapSize.Y <= 0 then
            Widget.InitialMapSize = { X = 2580.0, Y = 935.0 }
        end
        Log(string.format("SetupMinimapWidget: InitialMapSize = (%.1f, %.1f)", Widget.InitialMapSize.X, Widget.InitialMapSize.Y))
    end)

    local viewClass = StaticFindObject("/Script/MinimapPlugin.MapViewComponent")
    local created, createError = pcall(function()
        return PC.Pawn:AddComponentByClass(viewClass, false, {
            Rotation={X=0,Y=0,Z=0,W=1}, Translation={X=0,Y=0,Z=0}, Scale3D={X=1,Y=1,Z=1}
        }, false)
    end)
    PrivateMapView = created and createError or nil
    if not PrivateMapView or not PrivateMapView:IsValid() then
        PrivateMapView = PC.Pawn.MapView
        Log("[VIEW] Independent component unavailable; using pawn view safely")
    end
    pcall(function() PrivateMapView.RotationMode = 0 end)
    pcall(function() PrivateMapView.FixedRotation = {Pitch=0,Yaw=0,Roll=0} end)
    pcall(function() PrivateMapView:SetCollisionEnabled(0) end)
    pcall(function() PrivateMapView:SetViewExtent(210000 / CurrentZoom, 210000 / CurrentZoom) end)
    Widget.AutoLocateMapView = 4
    Widget.MapViewComp = PrivateMapView

    -- Add to Viewport with Z-Order 100
    Widget:AddToViewport(100)
    Widget:SetVisibility(IsMinimapVisible and 0 or 2)

    -- Apply RenderTransform for top-right corner
    ApplyMinimapTransform()

    local Pawn = PC and PC.Pawn
    if Pawn and Pawn:IsValid() then
        local MapView = PrivateMapView
        if MapView and MapView:IsValid() then
            pcall(function()
                Widget:SetMapView(MapView)
                Widget.MapViewComp = MapView
                Log("Connected independent minimap view; player/main-map view is untouched")
            end)
        end
    end

    -- Circular shape (OSRS Compass mode by default) & player camera frustum
    pcall(function()
        Widget.bIsCircular = IsCircularMode
        if Widget.ReinitShape then
            Widget:ReinitShape()
        elseif Widget.InitShape then
            Widget:InitShape()
        end
    end)
    pcall(function()
        Widget.bDrawCamera = true
        if Widget.InitDrawFrustum then Widget:InitDrawFrustum() end
    end)

    Widget.AutoLocateMapView = 4

    -- Hide Fog of War / Clouds so the land is clearly visible
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

    -- Resolve the world tracker through the verified native function.
    pcall(function()
        local library = StaticFindObject("/Script/MinimapPlugin.Default__MapFunctionLibrary")
        local trackerOk, tracker = pcall(function()
            return library and library:IsValid() and library:GetMapTracker(PC)
        end)
        if not trackerOk then tracker = nil end
        if not tracker or not tracker:IsValid() then
            local official = GetOfficialMap()
            tracker = official and official:IsValid() and official.MapTrackerComp
        end
        if tracker and tracker:IsValid() then
            Widget.MapTrackerComp = tracker
            Log("Connected Widget.MapTrackerComp: " .. tracker:GetFullName())
        end
    end)

    -- Attach native listeners safely
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

        local switcher = Widget.Switcher_MapActive
        local overlayLayers = nil
        if switcher and switcher:IsValid() and switcher:GetChildrenCount() > 1 then
            overlayLayers = switcher:GetChildAt(1)
        end

        if overlayLayers and overlayLayers:IsValid() then
            overlayLayers:SetVisibility(0)
        end

        local cb = Widget.Canvas_Backgrounds
        if cb and cb:IsValid() then
            local numBgs = cb:GetChildrenCount()
            for i = 0, numBgs - 1 do
                local child = cb:GetChildAt(i)
                if child and child:IsValid() then
                    if i == 0 then
                        child:SetVisibility(0)
                        CachedBackgroundChild = child
                        CachedBackgroundMID = child.BackgroundMaterialInstance
                    else
                        child:SetVisibility(2)
                    end
                end
            end
        end
    end)
    if not cfgOk then
        Log("[CONFIG ERROR] " .. tostring(cfgErr))
    end

    -- Setup Ornate RuneScape Dual-Ring Frame & Sundial Bezel
    SetupMinimapFrame(Widget, PC)

    OwnedWidgetName = Widget:GetFullName()
    if ModRef then ModRef:SetSharedVariable("OSRSMinimap.OwnedWidgetName", OwnedWidgetName) end

    -- Repopulate existing tracked resource icons if this minimap was recreated
    pcall(function()
        if Widget.AddMapIcon then
            local repopCount = 0
            for addr, data in pairs(TrackedResourceActors) do
                local comp = (type(data) == "table") and data.Comp or data
                if comp and comp:IsValid() then
                    local countBefore = GetMapIconWidgetCount(Widget)
                    Widget:AddMapIcon(comp)
                    repopCount = repopCount + 1
                end
            end
            for addr, data in pairs(TrackedAiActors) do
                local comp = (type(data) == "table") and data.Comp or data
                if comp and comp:IsValid() then
                    Widget:AddMapIcon(comp)
                    repopCount = repopCount + 1
                end
            end
            if repopCount > 0 then
                Log(string.format("[REPOPULATE] Re-added %d icons to recreated Minimap.", repopCount))
            end
        end
    end)

    Log("Minimap widget successfully configured with ornate frame and visible in viewport!")
    return true
end

-- =========================================================================
-- 4. Spawn or Locate Minimap
-- =========================================================================
local function InitMinimap(ForceRecreate)
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return false end
    if not PC.Pawn or not PC.Pawn:IsValid() then return false end
    local view = PC.Pawn.MapView
    if not view or not view:IsValid() then return false end

    if MinimapWidget and MinimapWidget:IsValid() and not ForceRecreate then
        MinimapWidget:SetVisibility(IsMinimapVisible and 0 or 2)
        return true
    end

    if ForceRecreate and MinimapWidget and MinimapWidget:IsValid() then
        pcall(function() MinimapWidget:RemoveFromParent() end)
        MinimapWidget = nil
    end

    if ForceRecreate and PurgeAllResourceComponents then
        pcall(PurgeAllResourceComponents)
    end

    CleanupAllOrphans(nil)
    CachedBackgroundMID = nil
    CachedBackgroundChild = nil
    BorderOuter = nil
    BorderGold = nil
    BorderInner = nil
    CircularBezelImage = nil
    DayNightBezel = nil
    DayNightShadow = nil
    NorthIndicator = nil

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

    local cb = MinimapWidget.Canvas_Backgrounds
    if not cb or not cb:IsValid() then return end
    if cb:GetChildrenCount() > 0 then
        CachedBackgroundChild = cb:GetChildAt(0)
    end

    local Pawn = PC and PC.Pawn
    if not Pawn or not Pawn:IsValid() then return end

    local pLoc = Pawn:K2_GetActorLocation()
    if not pLoc then return end

    -- Hide Clouds / Fog Overlays continuously
    pcall(function()
        if MinimapWidget.Overlay_Fogs and MinimapWidget.Overlay_Fogs:IsValid() then
            if MinimapWidget.Overlay_Fogs:GetVisibility() ~= 2 then
                MinimapWidget.Overlay_Fogs:SetVisibility(2)
            end
        end
        if CachedBackgroundChild and CachedBackgroundChild:IsValid() then
            if CachedBackgroundChild.ImageOverlay and CachedBackgroundChild.ImageOverlay:IsValid() then
                if CachedBackgroundChild.ImageOverlay:GetVisibility() ~= 2 then
                    CachedBackgroundChild.ImageOverlay:SetVisibility(2)
                end
            end
            if CachedBackgroundChild.ImageBackground and CachedBackgroundChild.ImageBackground:IsValid() then
                if CachedBackgroundChild.ImageBackground:GetVisibility() ~= 0 then
                    CachedBackgroundChild.ImageBackground:SetVisibility(0)
                end
            end
        end
    end)

    local nativeOffset = MinimapWidget.MapOffset
    if not nativeOffset then return end
    local offsetX, offsetY = nativeOffset.X, nativeOffset.Y

    -- Dirty check: skip expensive Slate matrix transform updates if offset & zoom are unchanged
    if LastTerrainOffsetX and LastTerrainOffsetY and LastTerrainZoom then
        if math.abs(offsetX - LastTerrainOffsetX) < 0.05
            and math.abs(offsetY - LastTerrainOffsetY) < 0.05
            and math.abs(CurrentZoom - LastTerrainZoom) < 0.01 then
            -- Still update dynamic player arrow & camera cone rotation smoothly
            pcall(function()
                if MinimapWidget.Widget_PlayerIcon and MinimapWidget.Widget_PlayerIcon:IsValid() then
                    local pRot = Pawn:K2_GetActorRotation()
                    if pRot and pRot.Yaw then
                        MinimapWidget.Widget_PlayerIcon:SetRenderAngle(pRot.Yaw)
                    end
                end
                if MinimapWidget.Widget_Camera and MinimapWidget.Widget_Camera:IsValid() then
                    local cRot = PC:GetControlRotation()
                    if cRot and cRot.Yaw then
                        MinimapWidget.Widget_Camera:SetRenderAngle(cRot.Yaw)
                    end
                end
            end)
            return
        end
    end
    LastTerrainOffsetX = offsetX
    LastTerrainOffsetY = offsetY
    LastTerrainZoom = CurrentZoom

    pcall(function()
        -- North-up mode: translate only. Turning does not orbit terrain.
        if MinimapWidget.Canvas_Backgrounds and MinimapWidget.Canvas_Backgrounds:IsValid() then
            local zoomFactor = 1.0
            MinimapWidget.Canvas_Backgrounds:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
            MinimapWidget.Canvas_Backgrounds:SetRenderScale({ X = zoomFactor, Y = zoomFactor })
            MinimapWidget.Canvas_Backgrounds:SetRenderTranslation({ X = offsetX * zoomFactor, Y = offsetY * zoomFactor })
            MinimapWidget.Canvas_Backgrounds:SetRenderAngle(0.0)
        end
        
        -- Rotate Player Icon to match player's actual facing direction (North-up GPS navigation)
        if MinimapWidget.Widget_PlayerIcon and MinimapWidget.Widget_PlayerIcon:IsValid() then
            local pRot = Pawn:K2_GetActorRotation()
            if pRot and pRot.Yaw then
                MinimapWidget.Widget_PlayerIcon:SetRenderAngle(pRot.Yaw)
            end
        end
        
        -- Rotate Camera frustum to match player's camera view angle
        if MinimapWidget.Widget_Camera and MinimapWidget.Widget_Camera:IsValid() then
            MinimapWidget.Widget_Camera:SetRenderTranslation({ X = 0.0, Y = 0.0 })
            local cRot = PC:GetControlRotation()
            if cRot and cRot.Yaw then
                MinimapWidget.Widget_Camera:SetRenderAngle(cRot.Yaw)
            end
        end
    end)
end

local LastMainMapOpen = nil
local function CheckMainMapVisibility()
    if not MinimapWidget or not MinimapWidget:IsValid() then return end

    local Official = GetOfficialMap()
    local MainMapOpen = false

    if Official and Official:IsValid() then
        local ok, isVis = pcall(function() return Official:IsVisible() end)
        if ok then
            MainMapOpen = isVis
        else
            MainMapOpen = (Official:GetVisibility() == 0)
        end
    end

    if MainMapOpen ~= LastMainMapOpen then
        LastMainMapOpen = MainMapOpen
        Log("[VIS] MainMapOpen changed to " .. tostring(MainMapOpen))
    end

    -- Safely refresh map size after Slate layout
    if MinimapWidget and MinimapWidget:IsValid() then
        pcall(function()
            local ims = MinimapWidget.InitialMapSize
            if (not ims or ims.X <= 0 or ims.Y <= 0) and UpdateTick >= NextSizeRetryTick then
                NextSizeRetryTick = UpdateTick + 20
                if MinimapWidget.RetryMapSize then
                    MinimapWidget:RetryMapSize()
                end
            end
        end)
    end

    local desiredVisibility = (IsMinimapVisible and not MainMapOpen) and 0 or 2
    if MinimapWidget:GetVisibility() ~= desiredVisibility then
        MinimapWidget:SetVisibility(desiredVisibility)
    end
end

-- =========================================================================
-- 5. Resource Map Icons System (Ores & Anima Vents)
-- =========================================================================

-- Texture Cache
local CachedResourceTextures = {}
local function GetResourceTexture(path)
    if not path or path == "" then return nil end
    if CachedResourceTextures[path] and CachedResourceTextures[path]:IsValid() then
        return CachedResourceTextures[path]
    end
    local tex = StaticFindObject(path)
    if not tex or not tex:IsValid() then
        if StaticLoadObject then
            pcall(function()
                local texClass = StaticFindObject("/Script/Engine.Texture2D")
                tex = StaticLoadObject(texClass, nil, path)
            end)
            if not tex or not tex:IsValid() then
                pcall(function()
                    tex = StaticLoadObject(nil, nil, path)
                end)
            end
        end
    end
    if tex and tex:IsValid() then
        CachedResourceTextures[path] = tex
        return tex
    end
    return nil
end

local DefaultUMGMat = nil
local function GetDefaultUMGMaterial()
    if DefaultUMGMat and DefaultUMGMat:IsValid() then
        return DefaultUMGMat
    end
    DefaultUMGMat = StaticFindObject("/MinimapPlugin/Materials/Icons/M_UMG_MapIcon.M_UMG_MapIcon")
    if not DefaultUMGMat or not DefaultUMGMat:IsValid() then
        if StaticLoadObject then
            pcall(function()
                local matClass = StaticFindObject("/Script/Engine.Material")
                DefaultUMGMat = StaticLoadObject(matClass, nil, "/MinimapPlugin/Materials/Icons/M_UMG_MapIcon.M_UMG_MapIcon")
            end)
            if not DefaultUMGMat or not DefaultUMGMat:IsValid() then
                pcall(function()
                    DefaultUMGMat = StaticLoadObject(nil, nil, "/MinimapPlugin/Materials/Icons/M_UMG_MapIcon.M_UMG_MapIcon")
                end)
            end
        end
    end
    -- Fallback: Borrow the verified material directly from an existing native MapIconComponent
    if not DefaultUMGMat or not DefaultUMGMat:IsValid() then
        pcall(function()
            local allIcons = FindAllOf("MapIconComponent")
            if allIcons then
                for _, iconComp in ipairs(allIcons) do
                    if iconComp and iconComp:IsValid() and iconComp.IconMaterial_UMG and iconComp.IconMaterial_UMG:IsValid() then
                        DefaultUMGMat = iconComp.IconMaterial_UMG
                        Log("[MATERIAL] Found DefaultUMGMat from existing MapIconComponent: " .. DefaultUMGMat:GetFullName())
                        break
                    end
                end
            end
        end)
    end
    return DefaultUMGMat
end

local ResourceTypeConfig = {
    Copper = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Copper_Ore_Medium_01.T_Icon_Copper_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/T_Resources_CopperOre.T_Resources_CopperOre",
        Size = 22.0,
        Label = "Copper Ore"
    },
    Tin = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Tin.T_Icon_Resource_Ore_Tin",
        Fallback = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Tin_Ore_Medium_01.T_Icon_Tin_Ore_Medium_01",
        Size = 22.0,
        Label = "Tin Ore"
    },
    Iron = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Iron_Ore_Medium_01.T_Icon_Iron_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Iron.T_Icon_Resource_Ore_Iron",
        Size = 22.0,
        Label = "Iron Ore"
    },
    Silver = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Silver_Ore_Medium_01.T_Icon_Silver_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/T_Resources_SilverOre.T_Resources_SilverOre",
        Size = 22.0,
        Label = "Silver Ore"
    },
    Gold = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Gold_Ore_Medium_01.T_Icon_Gold_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Gold.T_Icon_Resource_Ore_Gold",
        Size = 22.0,
        Label = "Gold Ore"
    },
    Coal = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Coal.T_Resources_Coal",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Iron.T_Icon_Resource_Ore_Iron",
        Size = 22.0,
        Label = "Coal"
    },
    Clay = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Clay_Ore_Medium_01.T_Icon_Clay_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resources_Clay.T_Icon_Resources_Clay",
        Size = 22.0,
        Label = "Clay"
    },
    Blurite = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Blurite.T_Icon_Resource_Ore_Blurite",
        Fallback = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Tin_Ore_Medium_01.T_Icon_Tin_Ore_Medium_01",
        Size = 22.0,
        Label = "Blurite Ore"
    },
    Adamantite = {
        TexturePath = "/Game/Art/UI/Icons/Icons_0_12_UmS/Icons/T_Icon_Adamantite_Ore.T_Icon_Adamantite_Ore",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Blurite.T_Icon_Resource_Ore_Blurite",
        Size = 22.0,
        Label = "Adamantite Ore"
    },
    Mithril = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Gemstone_Sapphire_01.T_Icon_Gemstone_Sapphire_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Blurite.T_Icon_Resource_Ore_Blurite",
        Size = 22.0,
        Label = "Mithril Ore"
    },
    Runite = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Blurite.T_Icon_Resource_Ore_Blurite",
        Fallback = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Gemstone_Sapphire_01.T_Icon_Gemstone_Sapphire_01",
        Size = 24.0,
        Label = "Runite Ore"
    },
    Stone = {
        TexturePath = "/Game/Art/UI/Skills/Icons/Unlock/Mining/T_Skill_Mining_Detect_Ore.T_Skill_Mining_Detect_Ore",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Iron.T_Icon_Resource_Ore_Iron",
        Size = 20.0,
        Label = "Stone"
    },
    Sandstone = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resources_Clay.T_Icon_Resources_Clay",
        Fallback = "/Game/Art/UI/Skills/Icons/Unlock/Mining/T_Skill_Mining_Detect_Ore.T_Skill_Mining_Detect_Ore",
        Size = 20.0,
        Label = "Sandstone"
    },
    RuneEssence = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Rune_Essence.T_Icon_Rune_Essence",
        Fallback = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Size = 24.0,
        Label = "Rune Essence"
    },
    Tree = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Wood.T_Resources_Wood",
        Fallback = "/Game/Art/UI/Skills/Icons/T_Notification_Skill_Woodcutting.T_Notification_Skill_Woodcutting",
        Size = 22.0,
        Label = "Tree"
    },
    Ash = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Wood.T_Resources_Wood",
        Fallback = "/Game/Art/UI/Skills/Icons/T_Notification_Skill_Woodcutting.T_Notification_Skill_Woodcutting",
        Size = 22.0,
        Label = "Ash Tree"
    },
    Oak = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Wood.T_Resources_Wood",
        Fallback = "/Game/Art/UI/Skills/Icons/T_Notification_Skill_Woodcutting.T_Notification_Skill_Woodcutting",
        Size = 24.0,
        Label = "Oak Tree"
    },
    Willow = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Wood.T_Resources_Wood",
        Fallback = "/Game/Art/UI/Skills/Icons/T_Notification_Skill_Woodcutting.T_Notification_Skill_Woodcutting",
        Size = 24.0,
        Label = "Willow Tree"
    },
    Yew = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Wood.T_Resources_Wood",
        Fallback = "/Game/Art/UI/Skills/Icons/T_Notification_Skill_Woodcutting.T_Notification_Skill_Woodcutting",
        Size = 26.0,
        Label = "Yew Tree"
    },
    Maple = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Wood.T_Resources_Wood",
        Fallback = "/Game/Art/UI/Skills/Icons/T_Notification_Skill_Woodcutting.T_Notification_Skill_Woodcutting",
        Size = 24.0,
        Label = "Maple Tree"
    },
    Fishing = {
        TexturePath = "/Fishing/Art/UI/Icons/Fishing_Skill_Icons/T_Notification_Skill_Fishing.T_Notification_Skill_Fishing",
        Fallback = "/Fishing/Art/UI/Icons/Fishing_Skill_Icons/Fish_Icons/T_Icon_Salmon.T_Icon_Salmon",
        Size = 24.0,
        Label = "Fishing Spot"
    },
    AnimaAir = {
        TexturePath = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Rune_Air.T_Icon_Rune_Air",
        Size = 26.0,
        Label = "Air Anima Vent"
    },
    AnimaFire = {
        TexturePath = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Fire.T_Icons_Rune_Fire",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Rune_Fire.T_Icon_Rune_Fire",
        Size = 26.0,
        Label = "Fire Anima Vent"
    },
    AnimaWater = {
        TexturePath = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Water.T_Icons_Rune_Water",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Rune_Water.T_Icon_Rune_Water",
        Size = 26.0,
        Label = "Water Anima Vent"
    },
    AnimaEarth = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Rune_Earth.T_Icon_Rune_Earth",
        Fallback = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Size = 26.0,
        Label = "Earth Anima Vent"
    },
    AnimaNature = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Rune_Nature.T_Icon_Rune_Nature",
        Fallback = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Size = 26.0,
        Label = "Nature Anima Vent"
    },
    AnimaAstral = {
        TexturePath = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Rune_Astral.T_Icon_Rune_Astral",
        Fallback = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Size = 26.0,
        Label = "Astral Anima Vent"
    },
    AnimaVent = {
        TexturePath = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Fallback = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Fire.T_Icons_Rune_Fire",
        Size = 26.0,
        Label = "Anima Vent"
    }
}

-- 9-Layer Shield: Rejects CDOs, Archetypes, non-world actors, and distant objects
local function IsValidResourceActor(actor, playerLoc, maxDistSq)
    if not actor or not actor:IsValid() then return false end

    local name = nil
    local okName = pcall(function() name = actor:GetFullName() end)
    if not okName or not name or name == "" then return false end

    -- Strictly reject Class Default Objects and Engine Archetypes
    if string.find(name, "Default__") or string.find(name, "REINST_") or string.find(name, "SKEL_") then
        return false
    end

    if EObjectFlags then
        local hasBadFlags = false
        pcall(function()
            if actor:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject) then
                hasBadFlags = true
            end
        end)
        if hasBadFlags then return false end
    end

    -- Actor must belong to the active gameplay world
    local world = nil
    local okW = pcall(function() world = actor:GetWorld() end)
    if not okW or not world or not world:IsValid() then return false end

    -- Actor must have a valid RootComponent
    local root = nil
    local okR = pcall(function() root = actor.RootComponent end)
    if not okR or not root or not root:IsValid() then return false end

    -- Reject actors being destroyed
    local beingDestroyed = false
    pcall(function()
        if actor.IsActorBeingDestroyed and actor:IsActorBeingDestroyed() then
            beingDestroyed = true
        end
    end)
    if beingDestroyed then return false end

    -- Must have a valid location
    local loc = nil
    local okL = pcall(function() loc = actor:K2_GetActorLocation() end)
    if not okL or not loc then return false end

    -- Proximity filter: only consider actors near the player
    if playerLoc and maxDistSq then
        local dx = loc.X - playerLoc.X
        local dy = loc.Y - playerLoc.Y
        if (dx * dx + dy * dy) > maxDistSq then
            return false
        end
    end

    return true
end

local function ClassifyResource(actor)
    if not actor or not actor:IsValid() then return nil end
    local ok, name = pcall(function() return actor:GetFullName() end)
    if not ok or not name then return nil end

    -- Exclude plain stone
    if string.find(name, "OreNode_Stone") or string.find(name, "Rock_Stone") then
        return nil
    end

    -- 1. Anima Vents (Element-specific via AnimaVentData or actor name)
    if string.find(name, "AnimaVent") then
        local elem = nil
        pcall(function()
            if actor.AnimaVentData and actor.AnimaVentData:IsValid() then
                local dataName = actor.AnimaVentData:GetFullName()
                if string.find(dataName, "Fire") then elem = "AnimaFire"
                elseif string.find(dataName, "Water") then elem = "AnimaWater"
                elseif string.find(dataName, "Earth") then elem = "AnimaEarth"
                elseif string.find(dataName, "Nature") then elem = "AnimaNature"
                elseif string.find(dataName, "Astral") then elem = "AnimaAstral"
                elseif string.find(dataName, "Air") then elem = "AnimaAir"
                end
            end
        end)
        if elem then return elem end
        if string.find(name, "Fire") then return "AnimaFire"
        elseif string.find(name, "Water") then return "AnimaWater"
        elseif string.find(name, "Earth") then return "AnimaEarth"
        elseif string.find(name, "Nature") then return "AnimaNature"
        elseif string.find(name, "Astral") then return "AnimaAstral"
        elseif string.find(name, "Air") then return "AnimaAir"
        end
        return "AnimaVent"
    end

    -- 2. Fishing Spots
    if string.find(name, "FishingNode") or string.find(name, "CatchableFish") or string.find(name, "Fishing") then
        return "Fishing"
    end

    -- 3. Trees (Woodcutting - High-Value Trees Only)
    if string.find(name, "Oak") then
        return "Oak"
    elseif string.find(name, "Willow") then
        return "Willow"
    elseif string.find(name, "Yew") then
        return "Yew"
    elseif string.find(name, "Maple") then
        return "Maple"
    end

    -- 4. Specific Ores and Minerals (Prioritize specific minerals over generic names)
    if string.find(name, "RuneEssence") or string.find(name, "Geyser") then
        return "RuneEssence"
    elseif string.find(name, "Runite") then
        return "Runite"
    elseif string.find(name, "Adamant") then
        return "Adamantite"
    elseif string.find(name, "Mithril") then
        return "Mithril"
    elseif string.find(name, "Blurite") then
        return "Blurite"
    elseif string.find(name, "Coal") then
        return "Coal"
    elseif string.find(name, "Silver") then
        return "Silver"
    elseif string.find(name, "Gold") then
        return "Gold"
    elseif string.find(name, "Iron") then
        return "Iron"
    elseif string.find(name, "Copper") then
        return "Copper"
    elseif string.find(name, "Tin") then
        return "Tin"
    elseif string.find(name, "Clay") then
        return "Clay"
    elseif string.find(name, "Sandstone") then
        return "Sandstone"
    end

    -- 5. GameplayTag fallback (for actors named generically)
    local tagStr = nil
    pcall(function()
        if actor.ResourceTag then
            tagStr = tostring(actor.ResourceTag.TagName or "")
        elseif actor.GetResourceTag then
            local tag = actor:GetResourceTag()
            if tag then tagStr = tostring(tag.TagName or "") end
        end
    end)
    if tagStr and tagStr ~= "" then
        if string.find(tagStr, "Copper") then return "Copper"
        elseif string.find(tagStr, "Tin") then return "Tin"
        elseif string.find(tagStr, "Iron") then return "Iron"
        elseif string.find(tagStr, "Silver") then return "Silver"
        elseif string.find(tagStr, "Gold") then return "Gold"
        elseif string.find(tagStr, "Coal") then return "Coal"
        elseif string.find(tagStr, "Clay") then return "Clay"
        elseif string.find(tagStr, "Mithril") then return "Mithril"
        elseif string.find(tagStr, "Adamant") then return "Adamantite"
        elseif string.find(tagStr, "Runite") then return "Runite"
        elseif string.find(tagStr, "Blurite") then return "Blurite"
        elseif string.find(tagStr, "Sandstone") then return "Sandstone"
        end
    end

    return nil
end

local function SetupResourceIcon(actor, resType)
    if not actor or not actor:IsValid() then return false end
    local addr = actor:GetAddress()
    if TrackedResourceActors[addr] then
        local existing = TrackedResourceActors[addr]
        local existingComp = (type(existing) == "table") and existing.Comp or existing
        if existingComp and existingComp:IsValid() then
            return false
        end
    end

    if not MapIconCompClass or not MapIconCompClass:IsValid() then
        MapIconCompClass = StaticFindObject("/Script/MinimapPlugin.MapIconComponent")
    end
    if not MapIconCompClass or not MapIconCompClass:IsValid() then return false end

    local cfg = ResourceTypeConfig[resType] or ResourceTypeConfig.Copper
    local tex = GetResourceTexture(cfg.TexturePath) or GetResourceTexture(cfg.Fallback)
    local umgMat = GetDefaultUMGMaterial()

    -- Look for existing component on actor first
    local comp = nil
    if actor.GetComponentByClass then
        pcall(function() comp = actor:GetComponentByClass(MapIconCompClass) end)
    end

    local isNewComp = false
    local compTransform = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = 0, Y = 0, Z = 150.0 },
        Scale3D = { X = 1, Y = 1, Z = 1 }
    }

    -- Create deferred component so properties (Material & Texture) are assigned BEFORE registration
    if not comp or not comp:IsValid() then
        local ok, res = pcall(function()
            return actor:AddComponentByClass(MapIconCompClass, false, compTransform, true)
        end)
        if ok and res and res:IsValid() then
            comp = res
            isNewComp = true
        else
            -- Fallback to non-deferred if deferred creation failed
            local ok2, res2 = pcall(function()
                return actor:AddComponentByClass(MapIconCompClass, false, compTransform, false)
            end)
            if ok2 and res2 and res2:IsValid() then
                comp = res2
                isNewComp = false
            end
        end
    end

    if comp and comp:IsValid() then
        pcall(function()
            if umgMat and umgMat:IsValid() then
                comp.IconMaterial_UMG = umgMat
                comp.InitialIconMaterial_UMG = umgMat
            end

            if tex and tex:IsValid() then
                comp.IconTexture = tex
            end

            comp.IconSize = cfg.Size
            comp.IconSizeUnit = 0
            comp.IconDrawColor = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
            comp.bIconRotates = false
            comp.IconZOrder = 10
            comp.bHideOwnerInsideFog = false
            comp.bIconVisible = ResourceIconsEnabled

            local iconsBefore = GetMapIconWidgetCount(MinimapWidget)
            local official = GetOfficialMap()
            local offBefore = GetMapIconWidgetCount(official)

            -- Finish registration with properties already populated
            if isNewComp then
                local finishOk = false
                if actor.FinishAddComponent then
                    pcall(function()
                        actor:FinishAddComponent(comp, false, compTransform)
                        finishOk = true
                    end)
                end
                if not finishOk and comp.RegisterComponent then
                    comp:RegisterComponent()
                end
            elseif comp.RegisterComponent then
                comp:RegisterComponent()
            end

            -- Fire material and texture setters so dynamic material instances and widgets bind cleanly
            if comp.SetIconMaterialForUMG and umgMat and umgMat:IsValid() then
                comp:SetIconMaterialForUMG(umgMat)
            end
            if tex and tex:IsValid() and comp.SetIconTexture then
                comp:SetIconTexture(tex)
            end
            if comp.SetIconDrawColor then
                comp:SetIconDrawColor({ R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
            end
            if comp.SetIconSize then
                comp:SetIconSize(cfg.Size, 0)
            end
            if comp.SetIconVisible then
                comp:SetIconVisible(ResourceIconsEnabled)
            end
            if comp.SetIconRotates then
                comp:SetIconRotates(false)
            end
            if comp.SetIconZOrder then
                comp:SetIconZOrder(10)
            end

            -- Ensure MinimapWidget has the icon without creating duplicate stacked widgets
            if MinimapWidget and MinimapWidget:IsValid() and MinimapWidget.AddMapIcon then
                local iconsAfter = GetMapIconWidgetCount(MinimapWidget)
                if iconsAfter == iconsBefore then
                    MinimapWidget:AddMapIcon(comp)
                end
            end

            -- Ensure OfficialMap has the icon without duplicate stacked widgets
            if official and official:IsValid() and official.AddMapIcon then
                local offAfter = GetMapIconWidgetCount(official)
                if offAfter == offBefore then
                    official:AddMapIcon(comp)
                end
            end
        end)

        local loc = nil
        pcall(function() loc = actor:K2_GetActorLocation() end)
        TrackedResourceActors[addr] = {
            Actor = actor,
            Comp = comp,
            Location = loc
        }
        return true
    end
    return false
end

-- =========================================================================
-- 6. Live OSRS Monster & NPC Radar Dots
-- =========================================================================

local function ScanAndRegisterAI()
    if not AiRadarEnabled or not ResourceIconsEnabled then return end
    local PC = UEHelpers.GetPlayerController()
    local Pawn = PC and PC:IsValid() and PC.Pawn
    if not Pawn or not Pawn:IsValid() then return end
    local playerLoc = Pawn:K2_GetActorLocation()
    if not playerLoc then return end

    local maxDistSq = 12000.0 * 12000.0 -- 120m radar radius
    local cullDistSq = 15000.0 * 15000.0 -- 150m cull buffer

    -- 1. Cull dead or far AI
    local culled = 0
    for addr, data in pairs(TrackedAiActors) do
        local actor = (type(data) == "table") and data.Actor or nil
        local comp = (type(data) == "table") and data.Comp or data
        local shouldCull = false
        if not comp or not comp:IsValid() or not actor or not actor:IsValid() then
            shouldCull = true
        else
            local dead = false
            pcall(function()
                if actor.IsActorBeingDestroyed and actor:IsActorBeingDestroyed() then dead = true end
                if actor.HealthComponent and actor.HealthComponent:IsValid() then
                    if actor.HealthComponent.IsDead and actor.HealthComponent:IsDead() then dead = true end
                end
            end)
            if dead then
                shouldCull = true
            else
                local loc = nil
                pcall(function() loc = actor:K2_GetActorLocation() end)
                if loc then
                    local dx = playerLoc.X - loc.X
                    local dy = playerLoc.Y - loc.Y
                    if (dx * dx + dy * dy) > cullDistSq then
                        shouldCull = true
                    end
                else
                    shouldCull = true
                end
            end
        end

        if shouldCull then
            if comp and comp:IsValid() then
                pcall(function()
                    if comp.SetIconVisible then comp:SetIconVisible(false) end
                    comp:K2_DestroyComponent(comp)
                end)
            end
            TrackedAiActors[addr] = nil
            culled = culled + 1
        end
    end

    -- 2. Scan nearby DominionAICharacter actors
    local ok, aiList = pcall(function() return FindAllOf("BP_DominionAICharacter_C") end)
    if not ok or not aiList then return end

    if not MapIconCompClass or not MapIconCompClass:IsValid() then
        MapIconCompClass = StaticFindObject("/Script/MinimapPlugin.MapIconComponent")
    end
    if not MapIconCompClass or not MapIconCompClass:IsValid() then return end

    local dotTex = GetResourceTexture("/Game/Art/UI/Notifications/MilestoneMaterial/T_Diamond_Bg.T_Diamond_Bg")
        or GetResourceTexture("/Game/Art/UI/NavIcons/T_Map_Icon_FriendDot.T_Map_Icon_FriendDot")
        or GetResourceTexture("/Game/Art/UI/HUD/Reticle/T_HUD_Reticle_Point.T_HUD_Reticle_Point")

    local umgMat = GetDefaultUMGMaterial()

    for _, ai in ipairs(aiList) do
        if IsValidResourceActor(ai, playerLoc, maxDistSq) then
            local addr = ai:GetAddress()
            if not TrackedAiActors[addr] then
                -- Check hostility
                local isHostile = false
                pcall(function()
                    if ai.MusicThreatLevel and ai.MusicThreatLevel > 0 then
                        isHostile = true
                    elseif ai.AiAttackComponent and ai.AiAttackComponent:IsValid() then
                        isHostile = true
                    end
                end)

                local comp = nil
                local compTransform = {
                    Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                    Translation = { X = 0, Y = 0, Z = 120.0 },
                    Scale3D = { X = 1, Y = 1, Z = 1 }
                }
                local okAdd, newComp = pcall(function()
                    return ai:AddComponentByClass(MapIconCompClass, false, compTransform, true)
                end)
                if not okAdd or not newComp or not newComp:IsValid() then
                    pcall(function()
                        newComp = ai:AddComponentByClass(MapIconCompClass, false, compTransform, false)
                    end)
                end

                if newComp and newComp:IsValid() then
                    pcall(function()
                        if umgMat and umgMat:IsValid() then
                            newComp.IconMaterial_UMG = umgMat
                            newComp.InitialIconMaterial_UMG = umgMat
                        end
                        if dotTex and dotTex:IsValid() then
                            newComp.IconTexture = dotTex
                        end
                        newComp.IconSize = isHostile and 12.0 or 10.0
                        newComp.IconSizeUnit = 0
                        local color = isHostile
                            and { R = 1.0, G = 0.18, B = 0.18, A = 1.0 } -- Red (Hostile Monster)
                            or  { R = 1.0, G = 0.88, B = 0.12, A = 1.0 } -- Yellow (Neutral / Wildlife)
                        newComp.IconDrawColor = color
                        newComp.bIconRotates = false
                        newComp.IconZOrder = 15
                        newComp.bHideOwnerInsideFog = false
                        newComp.bIconVisible = ResourceIconsEnabled

                        if ai.FinishAddComponent then
                            pcall(function() ai:FinishAddComponent(newComp, false, compTransform) end)
                        elseif newComp.RegisterComponent then
                            newComp:RegisterComponent()
                        end

                        if newComp.SetIconMaterialForUMG and umgMat and umgMat:IsValid() then
                            newComp:SetIconMaterialForUMG(umgMat)
                        end
                        if dotTex and dotTex:IsValid() and newComp.SetIconTexture then
                            newComp:SetIconTexture(dotTex)
                        end
                        if newComp.SetIconDrawColor then
                            newComp:SetIconDrawColor(color)
                        end
                        if newComp.SetIconSize then
                            newComp:SetIconSize(isHostile and 12.0 or 10.0, 0)
                        end
                        if newComp.SetIconVisible then
                            newComp:SetIconVisible(ResourceIconsEnabled)
                        end

                        if MinimapWidget and MinimapWidget:IsValid() and MinimapWidget.AddMapIcon then
                            MinimapWidget:AddMapIcon(newComp)
                        end
                        local official = GetOfficialMap()
                        if official and official:IsValid() and official.AddMapIcon then
                            official:AddMapIcon(newComp)
                        end
                    end)

                    TrackedAiActors[addr] = {
                        Actor = ai,
                        Comp = newComp,
                        Hostile = isHostile
                    }
                end
            end
        end
    end
end

local function ScanAndRegisterLandmarks()
    if not LandmarkIconsEnabled then return end
    local pc = CurrentPlayerController or UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then return end
    local pawn = pc.Pawn or (CurrentPawn and CurrentPawn:IsValid() and CurrentPawn)
    if not pawn or not pawn:IsValid() then return end

    local playerLoc = pawn:K2_GetActorLocation()
    if not playerLoc then return end

    -- 1. Cull invalid or destroyed landmarks
    for addr, data in pairs(TrackedLandmarkActors) do
        local actor = (type(data) == "table") and data.Actor or nil
        local comp = (type(data) == "table") and data.Comp or data
        if not comp or not comp:IsValid() or not actor or not actor:IsValid() then
            if comp and comp:IsValid() then
                pcall(function()
                    if comp.SetIconVisible then comp:SetIconVisible(false) end
                    comp:K2_DestroyComponent(comp)
                end)
            end
            TrackedLandmarkActors[addr] = nil
        end
    end

    if not MapIconCompClass or not MapIconCompClass:IsValid() then
        pcall(function() MapIconCompClass = StaticFindObject("/Script/MinimapPlugin.MapIconComponent") end)
    end
    if not MapIconCompClass or not MapIconCompClass:IsValid() then return end

    local umgMat = GetDefaultUMGMaterial()
    local dotTex = GetResourceTexture("/Game/Art/UI/Notifications/MilestoneMaterial/T_Diamond_Bg.T_Diamond_Bg")
        or GetResourceTexture("/Game/Art/UI/NavIcons/T_Map_Icon_FriendDot.T_Map_Icon_FriendDot")

    local function registerLandmarkActor(actor, isGravestone)
        if not actor or not actor:IsValid() then return end
        local addr = actor:GetAddress()
        if TrackedLandmarkActors[addr] then return end

        local compTransform = {
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Translation = { X = 0, Y = 0, Z = 150.0 },
            Scale3D = { X = 1, Y = 1, Z = 1 }
        }
        local okAdd, newComp = pcall(function()
            return actor:AddComponentByClass(MapIconCompClass, false, compTransform, true)
        end)
        if not okAdd or not newComp or not newComp:IsValid() then
            pcall(function()
                newComp = actor:AddComponentByClass(MapIconCompClass, false, compTransform, false)
            end)
        end
        if newComp and newComp:IsValid() then
            pcall(function()
                if umgMat and umgMat:IsValid() then
                    newComp.IconMaterial_UMG = umgMat
                    newComp.InitialIconMaterial_UMG = umgMat
                end
                if dotTex and dotTex:IsValid() then
                    newComp.IconTexture = dotTex
                end
                newComp.IconSize = isGravestone and 16.0 or 14.0
                newComp.IconSizeUnit = 0
                local color = isGravestone
                    and { R = 1.0, G = 0.15, B = 0.25, A = 1.0 } -- Crimson (Death point)
                    or  { R = 0.2, G = 0.75, B = 1.0, A = 1.0 }  -- Cyan (Lodestone teleport)
                newComp.IconDrawColor = color
                newComp.bIconRotates = false
                newComp.IconZOrder = isGravestone and 25 or 20
                newComp.bHideOwnerInsideFog = false
                newComp.bIconVisible = LandmarkIconsEnabled

                if actor.FinishAddComponent then
                    pcall(function() actor:FinishAddComponent(newComp, false, compTransform) end)
                elseif newComp.RegisterComponent then
                    newComp:RegisterComponent()
                end

                if newComp.SetIconMaterialForUMG and umgMat and umgMat:IsValid() then
                    newComp:SetIconMaterialForUMG(umgMat)
                end
                if dotTex and dotTex:IsValid() and newComp.SetIconTexture then
                    newComp:SetIconTexture(dotTex)
                end
                if newComp.SetIconDrawColor then
                    newComp:SetIconDrawColor(color)
                end
                if newComp.SetIconSize then
                    newComp:SetIconSize(isGravestone and 16.0 or 14.0, 0)
                end
                if newComp.SetIconVisible then
                    newComp:SetIconVisible(LandmarkIconsEnabled)
                end

                if MinimapWidget and MinimapWidget:IsValid() and MinimapWidget.AddMapIcon then
                    MinimapWidget:AddMapIcon(newComp)
                end
            end)

            TrackedLandmarkActors[addr] = {
                Actor = actor,
                Comp = newComp,
                IsGravestone = isGravestone
            }
        end
    end

    -- Scan Lodestones (Teleport crystals)
    local okL, lodestones = pcall(FindAllOf, "Lodestone")
    if okL and lodestones then
        for _, obj in ipairs(lodestones) do
            if obj and obj:IsValid() and not obj:HasAnyFlags(0x00000010 + 0x00000020) then
                registerLandmarkActor(obj, false)
            end
        end
    end

    -- Scan Gravestones (Player death marker)
    local okG, gravestones = pcall(FindAllOf, "Gravestone")
    if okG and gravestones then
        for _, obj in ipairs(gravestones) do
            if obj and obj:IsValid() and not obj:HasAnyFlags(0x00000010 + 0x00000020) then
                registerLandmarkActor(obj, true)
            end
        end
    end
end

PurgeAllResourceComponents = function()
    local ok, allComps = pcall(function() return FindAllOf("MapIconComponent") end)
    if not ok or not allComps then return end
    local destroyed = 0
    for _, comp in ipairs(allComps) do
        if comp and comp:IsValid() then
            local shouldDestroy = false
            pcall(function()
                local owner = comp:GetOwner()
                if not owner or not owner:IsValid() then
                    shouldDestroy = true
                else
                    -- Purge custom resource icons (IconZOrder == 10) or custom AI radar dots (IconZOrder == 15)
                    if comp.IconZOrder == 10 and ClassifyResource(owner) == nil then
                        shouldDestroy = true
                    elseif comp.IconZOrder == 15 then
                        shouldDestroy = true
                    end
                end
            end)
            if shouldDestroy then
                pcall(function()
                    if comp.SetIconVisible then comp:SetIconVisible(false) end
                    comp:K2_DestroyComponent(comp)
                    destroyed = destroyed + 1
                end)
            end
        end
    end
    if destroyed > 0 then
        pcall(function()
            if MinimapWidget and MinimapWidget:IsValid() and MinimapWidget.ForgetDestroyedIcons then
                MinimapWidget:ForgetDestroyedIcons()
            end
            local official = GetOfficialMap()
            if official and official:IsValid() and official.ForgetDestroyedIcons then
                official:ForgetDestroyedIcons()
            end
        end)
        Log(string.format("[PURGE] Destroyed %d unclassified resource/radar icon components from world.", destroyed))
    end
end

local function PruneDeadIconWidgets(Widget)
    if not Widget or not Widget:IsValid() then return 0 end
    local canvases = { Widget.Canvas_IconsBelowFog, Widget.Canvas_IconsAboveFog }
    local totalPruned = 0

    local activeAddrs = {}
    for addr, data in pairs(TrackedResourceActors) do
        local comp = (type(data) == "table") and data.Comp or data
        if comp and comp:IsValid() then
            pcall(function()
                local cAddr = comp:GetAddress()
                if cAddr then activeAddrs[cAddr] = true end
            end)
        end
    end
    for addr, data in pairs(TrackedAiActors) do
        local comp = (type(data) == "table") and data.Comp or data
        if comp and comp:IsValid() then
            pcall(function()
                local cAddr = comp:GetAddress()
                if cAddr then activeAddrs[cAddr] = true end
            end)
        end
    end

    for _, canvas in ipairs(canvases) do
        if canvas and canvas:IsValid() then
            local count = canvas:GetChildrenCount()
            for i = count - 1, 0, -1 do
                local child = canvas:GetChildAt(i)
                if child and child:IsValid() then
                    local shouldRemove = false
                    local comp = nil
                    pcall(function() comp = child.MapIconComp end)

                    if not comp or not comp:IsValid() then
                        shouldRemove = true
                    else
                        local owner = nil
                        pcall(function() owner = comp:GetOwner() end)
                        if not owner or not owner:IsValid() then
                            shouldRemove = true
                        else
                            if comp.IconZOrder == 10 then
                                local cAddr = nil
                                pcall(function() cAddr = comp:GetAddress() end)
                                if not cAddr or not activeAddrs[cAddr] then
                                    shouldRemove = true
                                elseif ClassifyResource(owner) == nil then
                                    shouldRemove = true
                                end
                            elseif comp.IconZOrder == 15 then
                                local cAddr = nil
                                pcall(function() cAddr = comp:GetAddress() end)
                                if not cAddr or not activeAddrs[cAddr] then
                                    shouldRemove = true
                                end
                            end
                        end
                    end

                    if shouldRemove then
                        if comp and comp:IsValid() then
                            pcall(function()
                                if comp.SetIconVisible then comp:SetIconVisible(false) end
                                comp:K2_DestroyComponent(comp)
                            end)
                        end
                        pcall(function()
                            if canvas.RemoveChildAt then
                                canvas:RemoveChildAt(i)
                            elseif canvas.RemoveChild then
                                canvas:RemoveChild(child)
                            else
                                child:RemoveFromParent()
                            end
                            totalPruned = totalPruned + 1
                        end)
                    end
                end
            end
        end
    end

    if totalPruned > 0 then
        pcall(function()
            if Widget.ForgetDestroyedIcons then
                Widget:ForgetDestroyedIcons()
            end
        end)
    end

    return totalPruned
end

local function ScanAndRegisterResources()
    local PC = UEHelpers.GetPlayerController()
    local Pawn = PC and PC:IsValid() and PC.Pawn
    if not Pawn or not Pawn:IsValid() then return end
    local playerLoc = Pawn:K2_GetActorLocation()
    if not playerLoc then return end

    -- Scan radius: 200 meters around the player
    local maxDistSq = 20000.0 * 20000.0
    -- Cull radius: 250 meters around the player (50m hysteresis buffer)
    local cullDistSq = 25000.0 * 25000.0

    -- Phase 1: Distance Culling & Dead Actor Cleanup
    local culledCount = 0
    for addr, data in pairs(TrackedResourceActors) do
        local actor = (type(data) == "table") and data.Actor or nil
        local comp = (type(data) == "table") and data.Comp or data
        local loc = (type(data) == "table") and data.Location or nil

        local shouldCull = false
        if not comp or not comp:IsValid() then
            shouldCull = true
        elseif not actor or not actor:IsValid() then
            shouldCull = true
        else
            if not loc and actor:IsValid() then
                pcall(function() loc = actor:K2_GetActorLocation() end)
            end
            if loc then
                local dx = playerLoc.X - loc.X
                local dy = playerLoc.Y - loc.Y
                local dz = playerLoc.Z - loc.Z
                local distSq = dx * dx + dy * dy + dz * dz
                if distSq > cullDistSq then
                    shouldCull = true
                end
            end
        end

        if shouldCull then
            if comp and comp:IsValid() then
                pcall(function()
                    if comp.SetIconVisible then comp:SetIconVisible(false) end
                    comp:K2_DestroyComponent(comp)
                end)
            end
            TrackedResourceActors[addr] = nil
            culledCount = culledCount + 1
        end
    end

    if culledCount > 0 then
        pcall(function()
            if MinimapWidget and MinimapWidget:IsValid() and MinimapWidget.ForgetDestroyedIcons then
                MinimapWidget:ForgetDestroyedIcons()
            end
            local official = GetOfficialMap()
            if official and official:IsValid() and official.ForgetDestroyedIcons then
                official:ForgetDestroyedIcons()
            end
        end)
    end

    -- Phase 2: Targeted Proximity Scan (Consolidated Parent Classes)
    -- If player hasn't moved more than 5 meters since last resource scan, skip scanning all 17 classes (trees and rocks are static)
    local shouldScanClasses = true
    if LastResourceScanLocation then
        local dx = playerLoc.X - LastResourceScanLocation.X
        local dy = playerLoc.Y - LastResourceScanLocation.Y
        local dz = playerLoc.Z - LastResourceScanLocation.Z
        if (dx * dx + dy * dy + dz * dz) < 250000.0 then -- 5m = 500cm, 500^2 = 250,000
            shouldScanClasses = false
        end
    end

    local newCount = 0
    if shouldScanClasses then
        LastResourceScanLocation = { X = playerLoc.X, Y = playerLoc.Y, Z = playerLoc.Z }
        local classesToScan = {
            "BP_AnimaVent_C",
            "BP_OreNode_C",
            "BP_MiningRock_Base_C",
            "BP_DivineRockBase_C",
            "BP_RuneEssenceGeyser_Base_C",
            "BP_MiningRock_RuneEssence_Static_Base_C",
            "BP_MiningRock_GeyserRuneEssence_C",
            "BP_FishingNodeV2_C",
            "BP_CatchableFish_C",
            "BP_FellableTree_Base_C",
            "BP_FellableTree_Oak_C",
            "BP_FellableTree_Willow_C",
            "BP_YewTree_01_C",
            "BP_YewTree_02_C",
            "BP_YewTree_03_C",
            "BP_DR_Tree_Maple_01_C",
            "BP_DR_Tree_Maple_02_C"
        }

        for _, className in ipairs(classesToScan) do
            local ok, actors = pcall(function() return FindAllOf(className) end)
            if ok and actors then
                for _, actor in ipairs(actors) do
                    if IsValidResourceActor(actor, playerLoc, maxDistSq) then
                        local resType = ClassifyResource(actor)
                        if resType then
                            if SetupResourceIcon(actor, resType) then
                                newCount = newCount + 1
                            end
                        end
                    end
                end
            end
        end
    end

    local prunedMinimap = PruneDeadIconWidgets(MinimapWidget)
    local official = GetOfficialMap()
    local prunedOfficial = official and official:IsValid() and PruneDeadIconWidgets(official) or 0
    local totalPruned = prunedMinimap + prunedOfficial

    local activeResourceCount = 0
    for _ in pairs(TrackedResourceActors) do activeResourceCount = activeResourceCount + 1 end

    if newCount > 0 or culledCount > 0 or totalPruned > 0 then
        Log(string.format("[RESOURCE SCAN] +%d new, -%d culled, -%d widgets pruned. Active tracked resources: %d",
            newCount, culledCount, totalPruned, activeResourceCount))
    end
end

-- =========================================================================
-- 7. Keybinds & Controls
-- =========================================================================
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

    -- F7: Force Reload Widget
    RegisterKeyBind(Key.F7, function()
        ExecuteInGameThread(function()
            Log("Manual reload requested via F7...")
            InitMinimap(true)
        end)
    end)

    -- F8: Toggle Minimap Shape (Circular Compass vs Rectangular Tablet)
    RegisterKeyBind(Key.F8, function()
        ExecuteInGameThread(function()
            UpdateMinimapShape(not IsCircularMode)
        end)
    end)

    -- F9: Toggle Resource Icons & AI Radar Dots On/Off
    RegisterKeyBind(Key.F9, function()
        ExecuteInGameThread(function()
            ResourceIconsEnabled = not ResourceIconsEnabled
            for addr, data in pairs(TrackedResourceActors) do
                local comp = (type(data) == "table") and data.Comp or data
                if comp and comp:IsValid() and comp.SetIconVisible then
                    pcall(function() comp:SetIconVisible(ResourceIconsEnabled) end)
                end
            end
            for addr, data in pairs(TrackedAiActors) do
                local comp = (type(data) == "table") and data.Comp or data
                if comp and comp:IsValid() and comp.SetIconVisible then
                    pcall(function() comp:SetIconVisible(ResourceIconsEnabled) end)
                end
            end
            Log("Resource Icons & AI Radar toggled: " .. (ResourceIconsEnabled and "VISIBLE" or "HIDDEN"))
            if ResourceIconsEnabled then
                pcall(ScanAndRegisterResources)
                pcall(ScanAndRegisterAI)
            end
        end)
    end)

    -- Zoom Controls: PageUp / PageDown / + / -
    local function ZoomIn()
        ExecuteInGameThread(function()
            CurrentZoom = math.min(48.0, CurrentZoom + 1.0)
            Log(string.format("Minimap zoom: %.1fx", CurrentZoom))
        end)
    end
    local function ZoomOut()
        ExecuteInGameThread(function()
            CurrentZoom = math.max(2.0, CurrentZoom - 1.0)
            Log(string.format("Minimap zoom: %.1fx", CurrentZoom))
        end)
    end

    RegisterKeyBind(Key.PAGE_UP, ZoomIn)
    RegisterKeyBind(Key.PAGE_DOWN, ZoomOut)
    pcall(function() RegisterKeyBind(Key.OEM_PLUS, ZoomIn) end)
    pcall(function() RegisterKeyBind(Key.OEM_MINUS, ZoomOut) end)

    -- [ and ]: Size Scale Controls
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

local GameplayStatics = nil
local LastPauseCheckTime = 0
local LastPauseState = false
local function IsGamePaused(pc)
    if not pc or not pc:IsValid() then return false end
    local now = os.clock()
    if now - LastPauseCheckTime < 0.25 then
        return LastPauseState
    end
    LastPauseCheckTime = now

    local ok1, paused = pcall(function() return pc:IsPaused() end)
    if ok1 and paused then
        LastPauseState = true
        return true
    end

    if not GameplayStatics or not GameplayStatics:IsValid() then
        GameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    if GameplayStatics and GameplayStatics:IsValid() then
        local ok2, gPaused = pcall(function() return GameplayStatics:IsGamePaused(pc) end)
        if ok2 and gPaused then
            LastPauseState = true
            return true
        end
    end
    LastPauseState = false
    return false
end

-- =========================================================================
-- 8. Main Update Loop
-- =========================================================================
local WasPaused = false
local function UpdateMinimap()
    local PC = UEHelpers.GetPlayerController()
    local paused = PC and IsGamePaused(PC)
    if UpdateTick % 40 == 0 then
        Log(string.format("[HEARTBEAT] PC=%s, Paused=%s, Widget=%s",
            tostring(PC and PC:IsValid()),
            tostring(paused),
            tostring(MinimapWidget and MinimapWidget:IsValid())))
    end
    if not PC or not PC:IsValid() then return end

    if paused then
        WasPaused = true
        return
    end

    if WasPaused then
        WasPaused = false
        NextAiScanTick = UpdateTick + 30
        NextResourceScanTick = UpdateTick + 50
        NextLandmarkScanTick = UpdateTick + 70
        Log("[PAUSE] Resumed from pause cleanly. Staggered background scans.")
    end

    local Pawn = PC.Pawn
    if not Pawn or not Pawn:IsValid() then
        ReadyPawnAddress = nil
        if MinimapWidget and MinimapWidget:IsValid() then
            MinimapWidget:SetVisibility(2)
        end
        return
    end

    -- Possession happens before the map UI finishes loading. Wait 5 seconds
    -- with the same pawn before creating the overlay or attaching listeners.
    local address = Pawn:GetAddress()
    if ReadyPawnAddress ~= address then
        ReadyPawnAddress = address
        ReadyAfterTick = UpdateTick + 100 -- 5s delay
        for _, data in pairs(TrackedResourceActors) do
            local comp = (type(data) == "table") and data.Comp or data
            if comp and comp:IsValid() then
                pcall(function()
                    if comp.SetIconVisible then comp:SetIconVisible(false) end
                    comp:K2_DestroyComponent(comp)
                end)
            end
        end
        for _, data in pairs(TrackedAiActors) do
            local comp = (type(data) == "table") and data.Comp or data
            if comp and comp:IsValid() then
                pcall(function()
                    if comp.SetIconVisible then comp:SetIconVisible(false) end
                    comp:K2_DestroyComponent(comp)
                end)
            end
        end
        TrackedResourceActors = {}
        TrackedAiActors = {}
        NextResourceScanTick = ReadyAfterTick + 100
        NextAiScanTick = ReadyAfterTick + 60
    end
    if UpdateTick < ReadyAfterTick then return end

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

    -- Private MapView extent for independent zoom
    if PrivateMapView and PrivateMapView:IsValid() then
        pcall(function() PrivateMapView:SetViewExtent(210000 / CurrentZoom, 210000 / CurrentZoom) end)
    end

    local cb = MinimapWidget.Canvas_Backgrounds
    if cb and cb:IsValid() and cb:GetChildrenCount() == 0 and UpdateTick >= NextBackgroundTick then
        NextBackgroundTick = UpdateTick + 20
        local library = StaticFindObject("/Script/MinimapPlugin.Default__MapFunctionLibrary")
        local trackerOk, tracker = pcall(function()
            return library and library:IsValid() and library:GetMapTracker(PC)
        end)
        if not trackerOk then tracker = nil end
        if not tracker or not tracker:IsValid() then
            local official = GetOfficialMap()
            tracker = official and official:IsValid() and official.MapTrackerComp
        end
        if tracker and tracker:IsValid() then
            MinimapWidget.MapTrackerComp = tracker
            pcall(function()
                if MinimapWidget.SetupListeners then
                    MinimapWidget:SetupListeners()
                end
            end)
            if MinimapWidget.InitFillBackground then
                pcall(function() MinimapWidget:InitFillBackground() end)
            end
        end
    end
    CheckMainMapVisibility()
    UpdateMinimapTerrain(PC)

    -- Live AI Monster / NPC Radar Scan every 2 seconds
    if AiRadarEnabled and ResourceIconsEnabled and UpdateTick >= NextAiScanTick then
        NextAiScanTick = UpdateTick + 40
        pcall(ScanAndRegisterAI)
    end

    -- Background Resource Scan every 5 seconds (local proximity only, CDOs filtered)
    if ResourceIconsEnabled and UpdateTick >= NextResourceScanTick then
        NextResourceScanTick = UpdateTick + 100
        pcall(ScanAndRegisterResources)
    end

    -- Live Landmark Scan (Lodestones & Gravestones) every 5 seconds
    if LandmarkIconsEnabled and UpdateTick >= NextLandmarkScanTick then
        NextLandmarkScanTick = UpdateTick + 100
        pcall(ScanAndRegisterLandmarks)
    end
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

Log("OSRS Minimap Ornate HUD v3 ready. F6: toggle, F7: reload, F8: circle/tablet shape, F9: resources/radar, PageUp/Down: zoom, [/]: size.")

-- One-time startup purge of any legacy icon components lingering in world
ExecuteInGameThread(function()
    if PurgeAllResourceComponents then
        pcall(PurgeAllResourceComponents)
    end
end)

-- Immediate reaction to network replication of Lodestones and Gravestones
pcall(RegisterHook, "/Script/Dominion.GameplayObjectRegistry:OnRep_Lodestones", function()
    ExecuteInGameThread(function()
        if ScanAndRegisterLandmarks then pcall(ScanAndRegisterLandmarks) end
    end)
end)

pcall(RegisterHook, "/Script/Dominion.GameplayObjectRegistry:OnRep_Gravestones", function()
    ExecuteInGameThread(function()
        if ScanAndRegisterLandmarks then pcall(ScanAndRegisterLandmarks) end
    end)
end)
