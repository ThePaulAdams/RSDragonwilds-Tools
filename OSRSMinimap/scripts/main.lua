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
-- Keep the shared/native map a little farther out when the game cannot expose
-- a separate MapViewComponent to Lua.  PageUp/PageDown still adjust this at
-- runtime without requiring a restart.
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
local NeedsOwnershipAudit = true
local NeedsLayoutAudit = true
local MinimapClass = nil
local CachedBackgroundMID = nil
local CachedBackgroundChild = nil

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
    -- Viewport coordinates are DPI-independent. Anchoring explicitly avoids
    -- full-screen render-pivot offsets on ultrawide monitors.
    MinimapWidget:SetRenderTransformPivot({ X = 0.0, Y = 0.0 })
    MinimapWidget:SetRenderScale({ X = 1.0, Y = 1.0 })
    MinimapWidget:SetRenderTranslation({ X = 0.0, Y = 0.0 })
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local PC = UEHelpers.GetPlayerController()
    local viewport = layout:GetViewportSize(PC)
    local dpi = layout:GetViewportScale(PC)
    local x = viewport.X / dpi - side - 24
    MinimapWidget:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
    MinimapWidget:SetPositionInViewport({ X = x, Y = 24.0 }, false)
    MinimapWidget:SetDesiredSizeInViewport({ X = side, Y = side })
    MinimapWidget:SetAnchorsInViewport({ Minimum = {X=0.0,Y=0.0}, Maximum = {X=0.0,Y=0.0} })
    Log(string.format("Viewport minimap: %dx%d, top-right margin 24", side, side))
end

-- 3. Setup Standalone Minimap Widget (Never touching Official Map)
local function SetupMinimapWidget(Widget, PC)
    if not Widget or not Widget:IsValid() then return false end

    local viewClass = StaticFindObject("/Script/MinimapPlugin.MapViewComponent")
    local created, createError = pcall(function()
        return PC.Pawn:AddComponentByClass(viewClass, false, {
            Rotation={X=0,Y=0,Z=0,W=1}, Translation={X=0,Y=0,Z=0}, Scale3D={X=1,Y=1,Z=1}
        }, false)
    end)
    PrivateMapView = created and createError or nil
    if not PrivateMapView or not PrivateMapView:IsValid() then
        -- Some UE4SS builds do not expose AddComponentByClass to Lua. Keep
        -- the existing native view in that case instead of aborting the mod.
        PrivateMapView = PC.Pawn.MapView
        Log("[VIEW] Independent component unavailable; using pawn view safely")
    end
    pcall(function() PrivateMapView.RotationMode = 0 end)
    pcall(function() PrivateMapView.FixedRotation = {Pitch=0,Yaw=0,Roll=0} end)
    pcall(function() PrivateMapView:SetCollisionEnabled(0) end)
    pcall(function() PrivateMapView:SetViewExtent(210000 / CurrentZoom, 210000 / CurrentZoom) end)
    Widget.AutoLocateMapView = 4 -- Disabled, before Construct can select a shared view.
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

    -- Circular shape & player camera frustum
    pcall(function()
        Widget.bIsCircular = false
        if Widget.ReinitShape then Widget:ReinitShape() end
    end)
    pcall(function()
        Widget.bDrawCamera = true
        if Widget.InitDrawFrustum then Widget:InitDrawFrustum() end
    end)

    -- Verified enum: Disabled = 4; the old value 2 selected a map background.
    Widget.AutoLocateMapView = 4

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

    -- Initialize map via native plugin lifecycle functions
    pcall(function()
        -- InitMap requires geometry; initialize after Slate has laid out the widget.
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

    -- Native tracker listeners populate this widget. Do not pass existing
    -- background or icon widgets to AddMapBackground/AddMapIcon.

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
    OwnedWidgetName = Widget:GetFullName()
    if ModRef then ModRef:SetSharedVariable("OSRSMinimap.OwnedWidgetName", OwnedWidgetName) end

    Log("Minimap widget successfully configured and visible in viewport!")
    return true
end

-- 4. Spawn or Locate Minimap
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

    CleanupAllOrphans(nil)
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

    -- Canvas transforms do not require a background material instance.
    local cb = MinimapWidget.Canvas_Backgrounds
    if not cb or not cb:IsValid() then return end
    if cb:GetChildrenCount() > 0 then
        CachedBackgroundChild = cb:GetChildAt(0)
    end

    local Pawn = PC and PC.Pawn
    if not Pawn or not Pawn:IsValid() then return end

    local pLoc = Pawn:K2_GetActorLocation()
    if not pLoc then return end

    -- Hide Clouds / Fog Overlays continuously (even when stationary!)
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

    -- Let the native map widget calculate GPS and MapOffset. Reusing that
    -- value avoids duplicating world bounds and keeps the main map untouched.
    local nativeOffset = MinimapWidget.MapOffset
    if not nativeOffset then return end
    local offsetX, offsetY = nativeOffset.X, nativeOffset.Y

    pcall(function()
        -- North-up mode: translate only. Turning must not orbit the terrain.
        if MinimapWidget.Canvas_Backgrounds and MinimapWidget.Canvas_Backgrounds:IsValid() then
            local zoomFactor = 1.0
            MinimapWidget.Canvas_Backgrounds:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
            MinimapWidget.Canvas_Backgrounds:SetRenderScale({ X = zoomFactor, Y = zoomFactor })
            MinimapWidget.Canvas_Backgrounds:SetRenderTranslation({ X = offsetX * zoomFactor, Y = offsetY * zoomFactor })
            MinimapWidget.Canvas_Backgrounds:SetRenderAngle(0.0)
        end
        
        -- Override Player Icon to always point UP (since the map rotates around them)
        if MinimapWidget.Widget_PlayerIcon and MinimapWidget.Widget_PlayerIcon:IsValid() then
            MinimapWidget.Widget_PlayerIcon:SetRenderAngle(0.0)
        end
        
        -- Also center the camera widget
        if MinimapWidget.Widget_Camera and MinimapWidget.Widget_Camera:IsValid() then
            MinimapWidget.Widget_Camera:SetRenderTranslation({ X = 0.0, Y = 0.0 })
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
        if MainMapOpen and Official and Official:IsValid() then
            pcall(function()
                local offCb = Official.Canvas_Backgrounds
                if offCb and offCb:IsValid() then
                    local count = offCb:GetChildrenCount()
                    Log(string.format("[OFFICIAL OPEN] Canvas_Backgrounds child count: %d", count))
                    for i = 0, count - 1 do
                        local c = offCb:GetChildAt(i)
                        if c and c:IsValid() then
                            local s = c.Slot
                            local pos = s and s.GetPosition and s:GetPosition() or { X = -1, Y = -1 }
                            local sz = s and s.GetSize and s:GetSize() or { X = -1, Y = -1 }
                            Log(string.format("  [Off Child %d] %s | Vis=%d | Pos=(%.1f, %.1f) | Size=(%.1f, %.1f)",
                                i, c:GetFName():ToString(), c:GetVisibility(), pos.X, pos.Y, sz.X, sz.Y))
                        end
                    end
                end
                if Official.InitialMapSize then
                    Log(string.format("[OFFICIAL OPEN] InitialMapSize = (%.1f, %.1f)", Official.InitialMapSize.X, Official.InitialMapSize.Y))
                end
                if Official.MapOffset then
                    Log(string.format("[OFFICIAL OPEN] MapOffset = (%.1f, %.1f)", Official.MapOffset.X, Official.MapOffset.Y))
                end
            end)
        end
    end

    -- Check if Minimap needs RetryMapSize
    if MinimapWidget and MinimapWidget:IsValid() then
        local ok, err = pcall(function()
            local ims = MinimapWidget.InitialMapSize
            if (not ims or ims.X <= 0 or ims.Y <= 0) and UpdateTick >= NextSizeRetryTick then
                NextSizeRetryTick = UpdateTick + 20
                Log(string.format("[RETRY_MAP_SIZE] Minimap InitialMapSize is (%.1f, %.1f). Calling RetryMapSize()...",
                    ims and ims.X or -1, ims and ims.Y or -1))
                if MinimapWidget.RetryMapSize then
                    MinimapWidget:RetryMapSize()
                end
                local newIms = MinimapWidget.InitialMapSize
                Log(string.format("[RETRY_MAP_SIZE] After RetryMapSize, InitialMapSize = (%.1f, %.1f)",
                    newIms and newIms.X or -1, newIms and newIms.Y or -1))
                local cb = MinimapWidget.Canvas_Backgrounds
                if cb and cb:IsValid() then
                    local count = cb:GetChildrenCount()
                    Log(string.format("[RETRY_MAP_SIZE] Canvas_Backgrounds count: %d", count))
                    for i = 0, count - 1 do
                        local c = cb:GetChildAt(i)
                        if c and c:IsValid() and c.Slot then
                            local pos = c.Slot.GetPosition and c.Slot:GetPosition() or { X = -1, Y = -1 }
                            local bsz = c.Slot.GetSize and c.Slot:GetSize() or { X = -1, Y = -1 }
                            Log(string.format("  [Bg %d] Pos=(%.1f, %.1f), Size=(%.1f, %.1f)", i, pos.X, pos.Y, bsz.X, bsz.Y))
                        end
                    end
                end
            end
        end)
        if not ok then
            Log("[RETRY_MAP_SIZE ERROR] " .. tostring(err))
        end
    end

    local desiredVisibility = (IsMinimapVisible and not MainMapOpen) and 0 or 2
    if MinimapWidget:GetVisibility() ~= desiredVisibility then
        MinimapWidget:SetVisibility(desiredVisibility)
    end
end

-- =========================================================================
-- 6. Resource Map Icons System (Ores & Anima Vents)
-- =========================================================================
local ResourceIconsEnabled = true
local DiscoveredResources = {}
local TrackedResourceActors = {}
local NextResourceScanTick = 0
local MapIconCompClass = nil

-- Texture Cache
local CachedResourceTextures = {}
local function GetResourceTexture(path)
    if not path then return nil end
    if CachedResourceTextures[path] then return CachedResourceTextures[path] end
    local tex = StaticFindObject(path)
    if not tex or not tex:IsValid() then
        if StaticLoadObject then
            pcall(function() tex = StaticLoadObject(nil, nil, path) end)
        end
    end
    if tex and tex:IsValid() then
        CachedResourceTextures[path] = tex
    end
    return tex
end

local ResourceTypeConfig = {
    Copper = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Copper_Ore_Medium_01.T_Icon_Copper_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/T_Resources_CopperOre.T_Resources_CopperOre",
        Color = { R = 1.0, G = 0.55, B = 0.25, A = 1.0 },
        Size = 22.0,
        Label = "Copper Ore"
    },
    Tin = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Tin_Ore_Medium_01.T_Icon_Tin_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Tin.T_Icon_Resource_Ore_Tin",
        Color = { R = 0.85, G = 0.90, B = 0.95, A = 1.0 },
        Size = 22.0,
        Label = "Tin Ore"
    },
    Iron = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Iron_Ore_Medium_01.T_Icon_Iron_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Iron.T_Icon_Resource_Ore_Iron",
        Color = { R = 0.70, G = 0.50, B = 0.40, A = 1.0 },
        Size = 22.0,
        Label = "Iron Ore"
    },
    Silver = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Silver_Ore_Medium_01.T_Icon_Silver_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/T_Resources_SilverOre.T_Resources_SilverOre",
        Color = { R = 0.95, G = 0.95, B = 1.0, A = 1.0 },
        Size = 22.0,
        Label = "Silver Ore"
    },
    Gold = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Gold_Ore_Medium_01.T_Icon_Gold_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resource_Ore_Gold.T_Icon_Resource_Ore_Gold",
        Color = { R = 1.0, G = 0.84, B = 0.0, A = 1.0 },
        Size = 22.0,
        Label = "Gold Ore"
    },
    Clay = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Clay_Ore_Medium_01.T_Icon_Clay_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resources_Clay.T_Icon_Resources_Clay",
        Color = { R = 0.82, G = 0.52, B = 0.35, A = 1.0 },
        Size = 22.0,
        Label = "Clay"
    },
    AnimaVent = {
        TexturePath = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Fallback = "/Game/Art/UI/Icons/T_Icon_Rune_Fire.T_Icon_Rune_Fire",
        Color = { R = 0.3, G = 0.85, B = 1.0, A = 1.0 },
        Size = 26.0,
        Label = "Anima Vent"
    },
    RuneEssence = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Coal.T_Resources_Coal",
        Color = { R = 0.8, G = 0.6, B = 1.0, A = 1.0 },
        Size = 22.0,
        Label = "Rune Essence"
    }
}

local function ClassifyResource(actor)
    if not actor or not actor:IsValid() then return nil end
    local name = actor:GetFullName()
    if string.find(name, "AnimaVent") then
        return "AnimaVent"
    elseif string.find(name, "Copper") then
        return "Copper"
    elseif string.find(name, "Tin") then
        return "Tin"
    elseif string.find(name, "Iron") then
        return "Iron"
    elseif string.find(name, "Silver") then
        return "Silver"
    elseif string.find(name, "Gold") then
        return "Gold"
    elseif string.find(name, "Clay") then
        return "Clay"
    elseif string.find(name, "RuneEssence") or string.find(name, "Geyser") then
        return "RuneEssence"
    elseif string.find(name, "OreNode") or string.find(name, "MiningRock") then
        return "Copper"
    end
    return nil
end

local function SetupResourceIcon(actor, resType)
    if not actor or not actor:IsValid() then return end
    local addr = actor:GetAddress()
    if TrackedResourceActors[addr] and TrackedResourceActors[addr]:IsValid() then
        return
    end

    if not MapIconCompClass or not MapIconCompClass:IsValid() then
        MapIconCompClass = StaticFindObject("/Script/MinimapPlugin.MapIconComponent")
    end
    if not MapIconCompClass or not MapIconCompClass:IsValid() then return end

    local cfg = ResourceTypeConfig[resType] or ResourceTypeConfig.Copper
    local tex = GetResourceTexture(cfg.TexturePath) or GetResourceTexture(cfg.Fallback)

    local comp = nil
    local ok, res = pcall(function()
        return actor:AddComponentByClass(MapIconCompClass, false, {
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Translation = { X = 0, Y = 0, Z = 150.0 },
            Scale3D = { X = 1, Y = 1, Z = 1 }
        }, false)
    end)
    if ok and res and res:IsValid() then
        comp = res
    end

    if comp and comp:IsValid() then
        pcall(function()
            if comp.RegisterComponent then comp:RegisterComponent() end
            if tex and tex:IsValid() and comp.SetIconTexture then
                comp:SetIconTexture(tex)
            end
            if comp.SetIconSize then
                comp:SetIconSize(cfg.Size, 0)
            else
                comp.IconSize = cfg.Size
            end
            if comp.SetIconDrawColor then
                comp:SetIconDrawColor(cfg.Color)
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
            if comp.SetIconTooltipText then
                comp:SetIconTooltipText(cfg.Label)
            end
            comp.bHideOwnerInsideFog = false
        end)

        pcall(function()
            if MinimapWidget and MinimapWidget:IsValid() and MinimapWidget.AddMapIcon then
                MinimapWidget:AddMapIcon(comp)
            end
            local official = GetOfficialMap()
            if official and official:IsValid() and official.AddMapIcon then
                official:AddMapIcon(comp)
            end
        end)

        TrackedResourceActors[addr] = comp
        local loc = actor:K2_GetActorLocation()
        Log(string.format("[RESOURCE] Added map icon for %s at (%.0f, %.0f)", resType, loc.X, loc.Y))
    else
        Log(string.format("[RESOURCE ERR] Could not add MapIconComponent to %s: %s", actor:GetFullName(), tostring(res)))
    end
end

local function ScanAndRegisterResources()
    local classesToScan = {
        "BP_AnimaVent_C",
        "BP_OreNode_Large_PARENT_C",
        "BP_OreNode_Medium_PARENT_C",
        "BP_OreNode_C",
        "BP_MiningRock_Base_C",
        "BP_RuneEssenceGeyser_Base_C"
    }

    local foundTotal = 0
    for _, className in ipairs(classesToScan) do
        local actors = FindAllOf(className)
        if actors then
            for _, actor in ipairs(actors) do
                if actor and actor:IsValid() then
                    local resType = ClassifyResource(actor)
                    if resType then
                        SetupResourceIcon(actor, resType)
                        foundTotal = foundTotal + 1
                    end
                end
            end
        end
    end
    if foundTotal > 0 then
        Log(string.format("[RESOURCE SCAN] Registered %d resource nodes.", foundTotal))
    end
end

-- 7. Keybinds
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

    -- F9: Toggle Resource Icons On/Off
    RegisterKeyBind(Key.F9, function()
        ExecuteInGameThread(function()
            ResourceIconsEnabled = not ResourceIconsEnabled
            for addr, comp in pairs(TrackedResourceActors) do
                if comp and comp:IsValid() and comp.SetIconVisible then
                    pcall(function() comp:SetIconVisible(ResourceIconsEnabled) end)
                end
            end
            Log("Resource Icons toggled: " .. (ResourceIconsEnabled and "VISIBLE" or "HIDDEN"))
            if ResourceIconsEnabled then
                ScanAndRegisterResources()
            end
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
    if NeedsOwnershipAudit then
        NeedsOwnershipAudit = false
        for _, candidate in ipairs(FindAllOf("WBP_DominionMinimap_C") or {}) do
            pcall(function()
                if candidate:IsValid() then
                    local parent = candidate:GetParent()
                    -- One-time migration of the exact orphan observed in this
                    -- session's log; never classify other game widgets by name pattern.
                    if (candidate:GetFullName() == "WBP_DominionMinimap_C /Engine/Transient.DomGameEngine_2147482588:BP_DominionGameInstance_C_2147482516.WBP_DominionMinimap_C_2147462564"
                        or candidate:GetFullName() == "WBP_DominionMinimap_C /Engine/Transient.DomGameEngine_2147482588:BP_DominionGameInstance_C_2147482516.WBP_DominionMinimap_C_2147388445")
                        and (not parent or not parent:IsValid()) then
                        pcall(function() candidate:DeactivateWidget() end)
                        candidate:RemoveFromParent()
                        candidate:SetVisibility(2)
                        Log("[MIGRATION] Removed verified legacy mod overlay")
                    end
                    Log("[OWNERSHIP] " .. candidate:GetFullName() .. " | parent=" ..
                        (parent and parent:IsValid() and parent:GetFullName() or "none"))
                end
            end)
        end
    end
    local PC = UEHelpers.GetPlayerController()
    local Pawn = PC and PC:IsValid() and PC.Pawn
    if not Pawn or not Pawn:IsValid() or not Pawn.MapView or not Pawn.MapView:IsValid() then
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

    -- Native projection centers on the attached private component. Zoom is
    -- independent of the component used by the game's full-screen map.
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
            local initialized = pcall(function()
                local geometry = MinimapWidget.GetCachedGeometry and MinimapWidget:GetCachedGeometry() or nil
                MinimapWidget:InitMap(geometry)
            end)
            if initialized then Log("[INIT] Native map initialized using laid-out geometry") end
        end
    end
    CheckMainMapVisibility()
    UpdateMinimapTerrain(PC)

    -- Background Resource Scan every 5 seconds
    if ResourceIconsEnabled and UpdateTick >= NextResourceScanTick then
        NextResourceScanTick = UpdateTick + 100
        ScanAndRegisterResources()
    end

    if NeedsLayoutAudit and UpdateTick > 20 then
        NeedsLayoutAudit = false
        local slate = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary")
        local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local vp = layout:GetViewportSize(PC)
        Log(string.format("[LAYOUT] viewport %.0fx%.0f scale %.3f", vp.X, vp.Y, layout:GetViewportScale(PC)))
        for _, w in ipairs({MinimapWidget, MinimapWidget.Canvas_Backgrounds, MinimapWidget.Switcher_MapActive}) do
            if w and w.GetCachedGeometry then
                local geom = w:GetCachedGeometry()
                local size = slate:GetLocalSize(geom)
                local pos = slate:LocalToAbsolute(geom, {X=0,Y=0})
                Log(string.format("[LAYOUT] %s size %.1f,%.1f origin %.1f,%.1f", w:GetFullName(),size.X,size.Y,pos.X,pos.Y))
            end
        end
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

Log("OSRS Minimap viewport repair v2 ready. F6: toggle, F7: recreate widget, PageUp/Down: zoom, [/]: size.")
