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

-- 3. Setup Standalone Minimap Widget (Never touching Official Map)
local function SetupMinimapWidget(Widget, PC)
    if not Widget or not Widget:IsValid() then return false end

    -- Pre-initialize InitialMapSize to prevent any divide-by-zero during early Slate layout
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

    -- Circular shape & player camera frustum
    pcall(function()
        Widget.bIsCircular = false
        if Widget.ReinitShape then Widget:ReinitShape() end
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

    pcall(function()
        -- North-up mode: translate only. Turning does not orbit terrain.
        if MinimapWidget.Canvas_Backgrounds and MinimapWidget.Canvas_Backgrounds:IsValid() then
            local zoomFactor = 1.0
            MinimapWidget.Canvas_Backgrounds:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
            MinimapWidget.Canvas_Backgrounds:SetRenderScale({ X = zoomFactor, Y = zoomFactor })
            MinimapWidget.Canvas_Backgrounds:SetRenderTranslation({ X = offsetX * zoomFactor, Y = offsetY * zoomFactor })
            MinimapWidget.Canvas_Backgrounds:SetRenderAngle(0.0)
        end
        
        -- Override Player Icon to always point UP
        if MinimapWidget.Widget_PlayerIcon and MinimapWidget.Widget_PlayerIcon:IsValid() then
            MinimapWidget.Widget_PlayerIcon:SetRenderAngle(0.0)
        end
        
        -- Center the camera widget
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
-- 6. Resource Map Icons System (Ores & Anima Vents)
-- =========================================================================
local ResourceIconsEnabled = true
local TrackedResourceActors = {}
local NextResourceScanTick = 0
local MapIconCompClass = nil

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
    Clay = {
        TexturePath = "/Game/Art/UI/Icons/Resources_09_24/T_Icon_Clay_Ore_Medium_01.T_Icon_Clay_Ore_Medium_01",
        Fallback = "/Game/Art/UI/Icons/Resources_ConceptArt/T_Icon_Resources_Clay.T_Icon_Resources_Clay",
        Size = 22.0,
        Label = "Clay"
    },
    AnimaVent = {
        TexturePath = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Fallback = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Fire.T_Icons_Rune_Fire",
        Size = 26.0,
        Label = "Anima Vent"
    },
    RuneEssence = {
        TexturePath = "/Game/Art/UI/Icons/T_Resources_Coal.T_Resources_Coal",
        Fallback = "/Game/Art/UI/Icons/Runes/T_Icons_Rune_Air.T_Icons_Rune_Air",
        Size = 24.0,
        Label = "Rune Essence"
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
    if not actor or not actor:IsValid() then return false end
    local addr = actor:GetAddress()
    if TrackedResourceActors[addr] and TrackedResourceActors[addr]:IsValid() then
        return false
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

    -- Create deferred component so properties (Material & Texture) are assigned BEFORE registration
    if not comp or not comp:IsValid() then
        local ok, res = pcall(function()
            return actor:AddComponentByClass(MapIconCompClass, false, {
                Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                Translation = { X = 0, Y = 0, Z = 150.0 },
                Scale3D = { X = 1, Y = 1, Z = 1 }
            }, true)
        end)
        if ok and res and res:IsValid() then
            comp = res
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

            -- Finish registration with properties already populated; native MapTrackerComponent notifies active maps cleanly
            if comp.RegisterComponent then
                comp:RegisterComponent()
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
        end)

        TrackedResourceActors[addr] = comp
        return true
    end
    return false
end

local function ScanAndRegisterResources()
    local PC = UEHelpers.GetPlayerController()
    local Pawn = PC and PC:IsValid() and PC.Pawn
    if not Pawn or not Pawn:IsValid() then return end
    local playerLoc = Pawn:K2_GetActorLocation()
    if not playerLoc then return end

    -- Scan radius: 350 meters around the player
    local maxDistSq = 35000.0 * 35000.0

    local classesToScan = {
        "BP_AnimaVent_C",
        "BP_OreNode_Large_PARENT_C",
        "BP_OreNode_Medium_PARENT_C",
        "BP_OreNode_C",
        "BP_MiningRock_Base_C",
        "BP_RuneEssenceGeyser_Base_C"
    }

    local newCount = 0
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
    if newCount > 0 then
        Log(string.format("[RESOURCE SCAN] Registered %d new resource nodes near player.", newCount))
    end
end

-- 7. Keybinds
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
                pcall(ScanAndRegisterResources)
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

-- 8. Queue at most one game-thread update; retry expensive setup once a second.
local function UpdateMinimap()
    local PC = UEHelpers.GetPlayerController()
    local Pawn = PC and PC:IsValid() and PC.Pawn
    if not Pawn or not Pawn:IsValid() or not Pawn.MapView or not Pawn.MapView:IsValid() then
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
        NextResourceScanTick = ReadyAfterTick + 100 -- 10s delay (5s after minimap spawns)
        TrackedResourceActors = {}
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

    -- Background Resource Scan every 5 seconds (local proximity only, CDOs filtered)
    if ResourceIconsEnabled and UpdateTick >= NextResourceScanTick then
        NextResourceScanTick = UpdateTick + 100
        pcall(ScanAndRegisterResources)
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

Log("OSRS Minimap viewport repair v2 ready. F6: toggle, F7: recreate widget, F9: resource icons, PageUp/Down: zoom, [/]: size.")
