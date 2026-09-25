local UEHelpers = require("UEHelpers")

local ModName = "ModMenu"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing RSDragonwilds Toolkit Mod Menu...")
Log("Controls: [F7] Toggle Mod Menu Overlay")
Log("          Also available from the Pause Menu!")
Log("==========================================")

-- ============================================================
-- State
-- ============================================================
local OverlayWidget = nil
local IsOverlayVisible = false
local InjectedButton = nil
local InjectedButtonAddr = nil

-- ============================================================
-- Toolkit Mods Registry
-- ============================================================
local ToolkitMods = {
    {
        Id = "OSRSMinimap",
        Name = "OSRS Minimap",
        Keys = "F6 Toggle | F9 Icons",
        Desc = "Old School RuneScape minimap with compass rotation & resource nodes.",
    },
    {
        Id = "QuickStack",
        Name = "Quick Stack",
        Keys = "G Quick Stack",
        Desc = "Auto-deposit matching items into nearby chests.",
    },
    {
        Id = "EnhancedReticle",
        Name = "Enhanced Reticle",
        Keys = "F4 Toggle | F1 Color | F2 Size",
        Desc = "High-visibility crosshair with vibrant colors & scaling.",
    },
    {
        Id = "TelekineticWoodcraft",
        Name = "Telekinetic Woodcraft",
        Keys = "E/V Grab | Z Magnet | F6 AoE",
        Desc = "Telekinetic log manipulation & mass woodpile harvesting.",
    },
    {
        Id = "ModMenu",
        Name = "Toolkit Mod Menu",
        Keys = "F7 Toggle | Pause Menu",
        Desc = "In-game mod status dashboard & hotkey reference.",
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
-- Overlay Widget (uses WBP_TitleOnlyTooltip_C as a canvas)
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
    table.insert(lines, "====================================================")
    table.insert(lines, "   RUNESCAPE: DRAGONWILDS  -  TOOLKIT MOD MENU")
    table.insert(lines, "====================================================")
    table.insert(lines, "")

    for i, mod in ipairs(ToolkitMods) do
        local enabled = statuses[mod.Id]
        if enabled == nil then enabled = true end
        local tag = enabled and "[ON]" or "[OFF]"
        local local_tag = mod.LocalOnly and " (Local)" or ""
        table.insert(lines, string.format(" %d. %s %s%s", i, mod.Name, tag, local_tag))
        table.insert(lines, string.format("    Keys: %s", mod.Keys))
        table.insert(lines, string.format("    %s", mod.Desc))
        table.insert(lines, "")
    end

    local active = 0
    local total = 0
    for _, m in ipairs(ToolkitMods) do
        total = total + 1
        local s = statuses[m.Id]
        if s == nil or s then active = active + 1 end
    end

    table.insert(lines, "----------------------------------------------------")
    table.insert(lines, string.format(" %d / %d Mods Active  |  Press F7 or ESC to close", active, total))
    table.insert(lines, "====================================================")
    return table.concat(lines, "\n")
end

local function CreateOverlay()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return nil end

    if OverlayWidget and OverlayWidget:IsValid() then
        return OverlayWidget
    end

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
    OverlayWidget:AddToViewport(150)
    OverlayWidget:SetVisibility(2) -- start hidden

    -- Position: left side of screen
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if layout and layout:IsValid() and PC:IsValid() then
        pcall(function()
            OverlayWidget:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
            OverlayWidget:SetPositionInViewport({ X = 40.0, Y = 80.0 }, false)
            OverlayWidget:SetDesiredSizeInViewport({ X = 580.0, Y = 520.0 })
            OverlayWidget:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        end)
    end

    -- SizeBox overrides
    if OverlayWidget.SizeBox_2 and OverlayWidget.SizeBox_2:IsValid() then
        pcall(function()
            OverlayWidget.SizeBox_2:SetWidthOverride(580.0)
            OverlayWidget.SizeBox_2:SetHeightOverride(520.0)
        end)
    end

    -- Background: dark slate translucent
    if OverlayWidget.Background and OverlayWidget.Background:IsValid() then
        pcall(function()
            OverlayWidget.Background:SetColorAndOpacity({ R = 0.02, G = 0.03, B = 0.06, A = 0.94 })
        end)
    end

    Log("Overlay widget created (Z-Order 150).")
    return OverlayWidget
end

local function RefreshOverlayText()
    if not OverlayWidget or not OverlayWidget:IsValid() then return end
    local content = GenerateMenuText()
    local ftext = MakeFText(content)
    if OverlayWidget.Title and OverlayWidget.Title:IsValid() then
        pcall(function()
            OverlayWidget.Title:SetText(ftext)
            OverlayWidget.Title:SetAutoWrapText(true)
            OverlayWidget.Title:SetColorAndOpacity({
                SpecifiedColor = { R = 0.95, G = 0.88, B = 0.65, A = 1.0 },
                ColorUseRule = 0
            })
            OverlayWidget.Title:SetShadowOffset({ X = 1.5, Y = 1.5 })
            OverlayWidget.Title:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.85 })
        end)
    end
end

local function ShowOverlay()
    local w = CreateOverlay()
    if not w then return end
    RefreshOverlayText()
    w:SetVisibility(0) -- Visible
    IsOverlayVisible = true
    Log("Mod Menu overlay shown.")
end

local function HideOverlay()
    if OverlayWidget and OverlayWidget:IsValid() then
        OverlayWidget:SetVisibility(2) -- Collapsed
    end
    IsOverlayVisible = false
    Log("Mod Menu overlay hidden.")
end

local function ToggleOverlay()
    if IsOverlayVisible then
        HideOverlay()
    else
        ShowOverlay()
    end
end

-- ============================================================
-- Pause Menu Button Injection
-- ============================================================

local function IsValidInstance(obj)
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

local function TryInjectPauseMenuButton()
    -- Find live WBP_PauseMenuScreen_C instances
    local ok, instances = pcall(function() return FindAllOf("WBP_PauseMenuScreen_C") end)
    if not ok or not instances then return end

    for _, pauseMenu in ipairs(instances) do
        if not IsValidInstance(pauseMenu) then goto continue_pm end

        -- Check if VerticalBox_PauseMenu exists
        local vbox = nil
        pcall(function() vbox = pauseMenu.VerticalBox_PauseMenu end)
        if not vbox or not vbox:IsValid() then goto continue_pm end

        -- Check if we already injected (don't double-inject)
        if InjectedButton and InjectedButton:IsValid() and InjectedButtonAddr then
            -- Already injected, just ensure it's there
            goto continue_pm
        end

        -- Find the button class (WBP_DomAllCapsButton_C)
        local btnClass = StaticFindObject("/Game/UI/Common/WBP_DomAllCapsButton.WBP_DomAllCapsButton_C")
        if not btnClass or not btnClass:IsValid() then goto continue_pm end

        -- Find the pause button style
        local pauseStyle = StaticFindObject("/Game/UI/Styles/Buttons/PauseMenu/CUIS_PauseButtonStyle.CUIS_PauseButtonStyle_C")

        -- Create the button
        local PC = UEHelpers.GetPlayerController()
        if not PC or not PC:IsValid() then goto continue_pm end

        local btn = nil
        local WBLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if WBLib and WBLib:IsValid() and WBLib.Create then
            pcall(function() btn = WBLib:Create(PC, btnClass, PC) end)
        end
        if not btn or not btn:IsValid() then goto continue_pm end

        -- Set the button text
        pcall(function()
            btn:SetLabelText(MakeFText("TOOLKIT MODS"))
        end)

        -- Apply pause menu style
        if pauseStyle and pauseStyle:IsValid() then
            pcall(function() btn:SetStyle(pauseStyle) end)
        end

        -- Insert into the VerticalBox after the Settings button (index 1)
        -- The order in VerticalBox_PauseMenu is:
        --   0: ResumeButton
        --   1: SettingsButton
        --   2: PlayerListButton
        --   3: WorldDetails
        --   4: ExitToMainMenuButton
        --   ...
        -- We insert at index 2 (after Settings, before PlayerList)
        local addOk = pcall(function()
            vbox:AddChildToVerticalBox(btn)
        end)
        if not addOk then goto continue_pm end

        InjectedButton = btn
        InjectedButtonAddr = btn:GetAddress()

        Log("Injected 'TOOLKIT MODS' button into Pause Menu!")

        ::continue_pm::
    end
end

-- ============================================================
-- Poll for Pause Menu & Button Click Detection
-- ============================================================

local LastPauseCheckTick = 0
local LastButtonCheckTick = 0

LoopAsync(500, function()
    -- Try to inject the button whenever the pause menu is open
    pcall(TryInjectPauseMenuButton)

    -- Check if our injected button was clicked
    if InjectedButton and InjectedButton:IsValid() then
        local isSelected = false
        pcall(function()
            isSelected = InjectedButton:GetSelected()
        end)
        if isSelected then
            -- Deselect immediately to allow re-clicking
            pcall(function() InjectedButton:SetSelectedInternal(false, false, false) end)
            ToggleOverlay()
        end
    else
        -- Button was destroyed (pause menu closed), clean up reference
        if InjectedButtonAddr then
            InjectedButton = nil
            InjectedButtonAddr = nil
        end
    end

    -- Auto-hide overlay when pause menu closes (game resumes)
    if IsOverlayVisible then
        local pauseMenus = nil
        pcall(function() pauseMenus = FindAllOf("WBP_PauseMenuScreen_C") end)
        local anyVisible = false
        if pauseMenus then
            for _, pm in ipairs(pauseMenus) do
                if IsValidInstance(pm) then
                    local vis = 2
                    pcall(function() vis = pm:GetVisibility() end)
                    if vis == 0 then anyVisible = true; break end
                end
            end
        end
        -- Don't auto-hide if triggered by F7 (the user might want it during gameplay)
    end

    return false
end)

-- ============================================================
-- Keybind: [F7] Toggle Overlay (works anytime, not just pause)
-- ============================================================
RegisterKeyBind(Key.F7, function()
    ToggleOverlay()
end)

Log("Keybind registered: [F7: Toggle Mod Menu Overlay]")
Log("Toolkit Mod Menu initialized. Press F7 or find 'TOOLKIT MODS' in the Pause Menu.")
