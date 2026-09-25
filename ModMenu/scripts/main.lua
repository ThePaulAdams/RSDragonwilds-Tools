local UEHelpers = require("UEHelpers")

local ModName = "ModMenu"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing RSDragonwilds Toolkit Mod Menu...")
Log("Controls: [F8] Toggle Mod Menu Overlay anytime")
Log("          Auto-displays on the Pause Menu (ESC)!")
Log("==========================================")

-- ============================================================
-- State
-- ============================================================
local OverlayWidget = nil
local IsOverlayVisible = false
local ManualToggleState = false
local WasPauseMenuOpen = false

-- Persist widget name across Lua reloads to clean up orphans
local OwnedWidgetName = nil
if ModRef then
    pcall(function() OwnedWidgetName = ModRef:GetSharedVariable("ModMenu.OwnedWidgetName") end)
end

local function CleanupAllOrphans(keepWidget)
    if not OwnedWidgetName then return end
    local all = FindAllOf("WBP_TitleOnlyTooltip_C") or {}
    for _, w in ipairs(all) do
        if w:IsValid() and w:GetFullName() == OwnedWidgetName
            and (not keepWidget or w:GetAddress() ~= keepWidget:GetAddress()) then
            pcall(function()
                w:RemoveFromParent()
                w:SetVisibility(2)
            end)
        end
    end
end

-- ============================================================
-- Toolkit Mods Registry
-- ============================================================
local ToolkitMods = {
    {
        Id = "OSRSMinimap",
        Name = "OSRS Minimap",
        Keys = "[F6] Toggle Map  |  [F9] Resource Icons",
        Desc = "Old School RuneScape minimap with rotating player compass & resource tracking.",
    },
    {
        Id = "QuickStack",
        Name = "Quick Stack",
        Keys = "[G] Quick Stack to Nearby Chests",
        Desc = "Smart auto-depositing matching inventory items into chests within 25m.",
    },
    {
        Id = "EnhancedReticle",
        Name = "Enhanced Reticle",
        Keys = "[F4] Toggle  |  [F1] Cycle Color  |  [F2] Cycle Size",
        Desc = "High-contrast aiming reticle with 7 luminous colors & 5 dynamic sizes.",
    },
    {
        Id = "TelekineticWoodcraft",
        Name = "Telekinetic Woodcraft",
        Keys = "[E]/[V] Grab  |  [Z] Log Magnet  |  [F6] Radius",
        Desc = "Telekinetic log manipulation & 150m vacuum into flat woodpiles for Splinter.",
    },
    {
        Id = "ModMenu",
        Name = "Toolkit Mod Menu",
        Keys = "[F8] Toggle Overlay  |  Auto-shown on ESC",
        Desc = "In-game mod status dashboard and hotkey control reference.",
    },
}

-- ============================================================
-- Helpers
-- ============================================================

-- Convert string to FText via KismetTextLibrary
local function MakeFText(str)
    local TextLib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    if TextLib and TextLib:IsValid() and TextLib.Conv_StringToText then
        local ok, ftext = pcall(function() return TextLib:Conv_StringToText(str) end)
        if ok and ftext then return ftext end
    end
    return str
end

-- Read mods.txt to detect which mods are active
local function GetModStatuses()
    local statuses = {}
    local paths = {
        "mods.txt",
        "Mods/mods.txt",
        "ue4ss/Mods/mods.txt",
        "Binaries/Win64/ue4ss/Mods/mods.txt",
        "F:\\Steam\\steamapps\\common\\RSDragonwilds\\RSDragonwilds\\Binaries\\Win64\\ue4ss\\Mods\\mods.txt",
    }

    local file = nil
    for _, p in ipairs(paths) do
        local ok, f = pcall(io.open, p, "r")
        if ok and f then file = f; break end
    end

    if file then
        for line in file:lines() do
            local id, state = line:match("^%s*([%w_-]+)%s*:%s*(%d+)")
            if id and state then
                statuses[id] = (tonumber(state) == 1)
            end
        end
        file:close()
    else
        for _, m in ipairs(ToolkitMods) do statuses[m.Id] = true end
    end
    return statuses
end

-- ============================================================
-- Overlay Widget (uses WBP_TitleOnlyTooltip_C with Top Z-Order 9999)
-- ============================================================

local OverlayClass = nil
local function GetOverlayClass()
    if OverlayClass and OverlayClass:IsValid() then return OverlayClass end
    local path = "/Game/UI/Common/WBP_TitleOnlyTooltip.WBP_TitleOnlyTooltip_C"
    OverlayClass = StaticFindObject(path)
    if OverlayClass and OverlayClass:IsValid() then return OverlayClass end
    if StaticLoadObject then
        local l = StaticLoadObject(nil, nil, path)
        if l and l:IsValid() then OverlayClass = l; return OverlayClass end
    end
    return nil
end

local function GenerateMenuText()
    local statuses = GetModStatuses()
    local lines = {}
    table.insert(lines, "==========================================================")
    table.insert(lines, "       RUNESCAPE: DRAGONWILDS - TOOLKIT MOD DASHBOARD     ")
    table.insert(lines, "==========================================================")
    table.insert(lines, "")

    local activeCount = 0
    local totalCount = 0

    for i, mod in ipairs(ToolkitMods) do
        totalCount = totalCount + 1
        local enabled = statuses[mod.Id]
        if enabled == nil then enabled = true end
        if enabled then activeCount = activeCount + 1 end

        local statusTag = enabled and "[ENABLED - ACTIVE]" or "[DISABLED]"

        table.insert(lines, string.format(" [%d] %-28s %s", i, mod.Name, statusTag))
        table.insert(lines, string.format("     Hotkeys : %s", mod.Keys))
        table.insert(lines, string.format("     Details : %s", mod.Desc))
        table.insert(lines, "")
    end

    table.insert(lines, "----------------------------------------------------------")
    table.insert(lines, string.format(" Status: %d / %d Toolkit Mods Active  |  UE4SS Mod System", activeCount, totalCount))
    table.insert(lines, " Press [F8] to toggle overlay anytime during gameplay")
    table.insert(lines, "==========================================================")
    return table.concat(lines, "\n")
end

local function UpdateMenuLayout(widget)
    if not widget or not widget:IsValid() then return end

    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() or not layout or not layout:IsValid() then return end

    local viewport = layout:GetViewportSize(PC)
    local dpi = layout:GetViewportScale(PC)
    if not viewport or not dpi or dpi <= 0 then return end

    local cardWidth = 640.0
    local cardHeight = 580.0

    -- Position on the center-right side next to the pause menu
    local screenW = viewport.X / dpi
    local screenH = viewport.Y / dpi
    local posX = math.max(screenW * 0.42, 540.0)
    local posY = math.max((screenH - cardHeight) * 0.42, 60.0)

    widget:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
    widget:SetPositionInViewport({ X = posX, Y = posY }, false)
    widget:SetDesiredSizeInViewport({ X = cardWidth, Y = cardHeight })
    widget:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })

    -- SizeBox overrides
    if widget.SizeBox_2 and widget.SizeBox_2:IsValid() then
        pcall(function()
            widget.SizeBox_2:SetWidthOverride(cardWidth)
            widget.SizeBox_2:SetHeightOverride(cardHeight)
        end)
    end

    -- Background: dark translucent Slate card
    if widget.Background and widget.Background:IsValid() then
        pcall(function()
            widget.Background:SetColorAndOpacity({ R = 0.03, G = 0.04, B = 0.08, A = 0.96 })
        end)
    end
end

local function RefreshOverlayText()
    if not OverlayWidget or not OverlayWidget:IsValid() then return end
    local content = GenerateMenuText()
    local ftext = MakeFText(content)
    if OverlayWidget.Title and OverlayWidget.Title:IsValid() then
        pcall(function()
            OverlayWidget.Title:SetText(ftext)
            OverlayWidget.Title:SetAutoWrapText(true)
            -- Warm gold / luminous runes typography
            OverlayWidget.Title:SetColorAndOpacity({
                SpecifiedColor = { R = 0.96, G = 0.89, B = 0.62, A = 1.0 },
                ColorUseRule = 0
            })
            OverlayWidget.Title:SetShadowOffset({ X = 1.5, Y = 1.5 })
            OverlayWidget.Title:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.9 })
        end)
    end
end

local function CreateOverlay()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return nil end

    if OverlayWidget and OverlayWidget:IsValid() then
        return OverlayWidget
    end

    CleanupAllOrphans(nil)

    local Class = GetOverlayClass()
    if not Class or not Class:IsValid() then
        Log("[Error] WBP_TitleOnlyTooltip_C class not found.")
        return nil
    end

    local widget = nil
    local WBLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if WBLib and WBLib:IsValid() and WBLib.Create then
        pcall(function() widget = WBLib:Create(PC, Class, PC) end)
    end
    if not widget or not widget:IsValid() then
        pcall(function() widget = StaticConstructObject(Class, PC) end)
    end
    if not widget or not widget:IsValid() then
        Log("[Error] Failed to create overlay widget.")
        return nil
    end

    OverlayWidget = widget
    OwnedWidgetName = OverlayWidget:GetFullName()
    if ModRef then
        pcall(function() ModRef:SetSharedVariable("ModMenu.OwnedWidgetName", OwnedWidgetName) end)
    end

    -- Add to Viewport with Top Z-Order (9999) so it always renders above the Pause Menu and Game HUD
    OverlayWidget:AddToViewport(9999)
    OverlayWidget:SetVisibility(2) -- start hidden

    UpdateMenuLayout(OverlayWidget)
    RefreshOverlayText()

    Log("Overlay widget created (Top Z-Order 9999).")
    return OverlayWidget
end

local function ShowOverlay()
    local w = CreateOverlay()
    if not w then return end
    RefreshOverlayText()
    UpdateMenuLayout(w)
    w:SetVisibility(0) -- Visible
    IsOverlayVisible = true
    Log(">>> Mod Menu overlay SHOWN.")
end

local function HideOverlay()
    if OverlayWidget and OverlayWidget:IsValid() then
        OverlayWidget:SetVisibility(2) -- Collapsed
    end
    IsOverlayVisible = false
    Log(">>> Mod Menu overlay HIDDEN.")
end

local function ToggleOverlay()
    if IsOverlayVisible then
        HideOverlay()
        ManualToggleState = false
    else
        ShowOverlay()
        ManualToggleState = true
    end
end

-- ============================================================
-- Safe Pause Menu State Polling (Pure Game Thread Execution)
-- ============================================================

local function IsValidUObject(obj)
    if not obj then return false end
    local ok, valid = pcall(function()
        if not obj:IsValid() or obj:GetAddress() == 0 then return false end
        if obj:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject) then
            return false
        end
        return true
    end)
    return ok and valid
end

LoopAsync(300, function()
    ExecuteInGameThread(function()
        local PC = UEHelpers.GetPlayerController()
        if not PC or not PC:IsValid() then return end

        -- Check if WBP_PauseMenuScreen_C is open and visible
        local pauseMenus = FindAllOf("WBP_PauseMenuScreen_C") or {}
        local isPauseMenuOpen = false

        for _, pm in ipairs(pauseMenus) do
            if IsValidUObject(pm) then
                local vis = 2
                pcall(function() vis = pm:GetVisibility() end)
                if vis == 0 then
                    isPauseMenuOpen = true
                    break
                end
            end
        end

        -- Handle transition: Pause Menu Opened
        if isPauseMenuOpen and not WasPauseMenuOpen then
            WasPauseMenuOpen = true
            Log("Pause Menu opened -> Showing Toolkit Mod Menu")
            ShowOverlay()
        -- Handle transition: Pause Menu Closed
        elseif not isPauseMenuOpen and WasPauseMenuOpen then
            WasPauseMenuOpen = false
            Log("Pause Menu closed -> Hiding Toolkit Mod Menu")
            if not ManualToggleState then
                HideOverlay()
            end
        end

        -- If overlay is visible, keep layout synced
        if IsOverlayVisible and OverlayWidget and OverlayWidget:IsValid() then
            UpdateMenuLayout(OverlayWidget)
        end
    end)

    return false
end)

-- ============================================================
-- Keybind: [F8] Toggle Overlay anytime
-- ============================================================
if Key.F8 then
    RegisterKeyBind(Key.F8, function()
        Log("F8 pressed -> Toggle Mod Menu")
        ExecuteInGameThread(function()
            ToggleOverlay()
        end)
    end)
    Log("Keybind registered: [F8: Toggle Mod Menu Overlay]")
end

Log("Toolkit Mod Menu initialized successfully.")
