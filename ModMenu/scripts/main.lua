local UEHelpers = require("UEHelpers")

local ModName = "ModMenu"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing RSDragonwilds Toolkit Mod Menu...")
Log("Controls: Press [ESC] to view Toolkit Mods in Pause Menu")
Log("          Or press [F8] anytime during gameplay")
Log("==========================================")

-- ============================================================
-- State
-- ============================================================
local StandaloneOverlay = nil
local IsStandaloneVisible = false

local InjectedButton = nil
local InjectedCard = nil
local LastPauseMenuAddr = nil

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
        Keys = "[F8] Toggle Anytime  |  ESC Pause Menu",
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
    table.insert(lines, " Click [TOOLKIT MODS] or press [F8] to toggle overlay")
    table.insert(lines, "==========================================================")
    return table.concat(lines, "\n")
end

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

-- ============================================================
-- Pause Menu Injection: Button + In-Screen Dashboard Card
-- ============================================================

local function SetupPauseMenuModCard(pauseMenu)
    if not IsValidUObject(pauseMenu) then return end

    local addr = pauseMenu:GetAddress()
    if addr == LastPauseMenuAddr and InjectedButton and InjectedButton:IsValid() then
        return
    end

    local vbox = nil
    pcall(function() vbox = pauseMenu.VerticalBox_PauseMenu end)
    if not vbox or not vbox:IsValid() then return end

    local canvas = nil
    pcall(function()
        if pauseMenu.CanvasPanel_0 and pauseMenu.CanvasPanel_0:IsValid() then
            canvas = pauseMenu.CanvasPanel_0
        elseif pauseMenu.WidgetTree and pauseMenu.WidgetTree.CanvasPanel_0 and pauseMenu.WidgetTree.CanvasPanel_0:IsValid() then
            canvas = pauseMenu.WidgetTree.CanvasPanel_0
        end
    end)

    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return end

    local WBLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not WBLib or not WBLib:IsValid() then return end

    -- 1. Create In-Screen Dashboard Card on Pause Menu's CanvasPanel
    local card = nil
    local tooltipClass = StaticFindObject("/Game/UI/Common/WBP_TitleOnlyTooltip.WBP_TitleOnlyTooltip_C")
    if tooltipClass and tooltipClass:IsValid() and canvas and canvas:IsValid() then
        pcall(function() card = WBLib:Create(PC, tooltipClass, PC) end)
        if not card or not card:IsValid() then
            pcall(function() card = StaticConstructObject(tooltipClass, PC) end)
        end

        if card and card:IsValid() then
            -- Configure Card text & typography
            pcall(function()
                if card.Title and card.Title:IsValid() then
                    card.Title:SetText(MakeFText(GenerateMenuText()))
                    card.Title:SetAutoWrapText(true)
                    card.Title:SetColorAndOpacity({
                        SpecifiedColor = { R = 0.96, G = 0.89, B = 0.62, A = 1.0 },
                        ColorUseRule = 0
                    })
                    card.Title:SetShadowOffset({ X = 1.5, Y = 1.5 })
                    card.Title:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.9 })
                end
                if card.Background and card.Background:IsValid() then
                    card.Background:SetColorAndOpacity({ R = 0.03, G = 0.04, B = 0.08, A = 0.96 })
                end
                if card.SizeBox_2 and card.SizeBox_2:IsValid() then
                    card.SizeBox_2:SetWidthOverride(620.0)
                    card.SizeBox_2:SetHeightOverride(560.0)
                end
            end)

            -- Add to Pause Menu CanvasPanel
            local slot = nil
            pcall(function() slot = canvas:AddChildToCanvas(card) end)
            if slot and slot:IsValid() then
                pcall(function()
                    slot:SetPosition({ X = 580.0, Y = 90.0 })
                    slot:SetSize({ X = 620.0, Y = 560.0 })
                    slot:SetZOrder(50)
                    slot:SetAutoSize(false)
                end)
            end

            card:SetVisibility(0) -- Show by default when pause menu opens
            InjectedCard = card
            Log("Attached Toolkit Mod Dashboard card to Pause Menu CanvasPanel!")
        end
    end

    -- 2. Inject "TOOLKIT MODS" Button into VerticalBox_PauseMenu
    local btnClass = StaticFindObject("/Game/UI/Common/WBP_DomAllCapsButton.WBP_DomAllCapsButton_C")
    local pauseStyle = StaticFindObject("/Game/UI/Styles/Buttons/PauseMenu/CUIS_PauseButtonStyle.CUIS_PauseButtonStyle_C")
    if btnClass and btnClass:IsValid() then
        local btn = nil
        pcall(function() btn = WBLib:Create(PC, btnClass, PC) end)
        if not btn or not btn:IsValid() then
            pcall(function() btn = StaticConstructObject(btnClass, PC) end)
        end

        if btn and btn:IsValid() then
            pcall(function() btn:SetLabelText(MakeFText("TOOLKIT MODS")) end)
            if pauseStyle and pauseStyle:IsValid() then
                pcall(function() btn:SetStyle(pauseStyle) end)
            end

            -- Toggle card visibility on button click
            pcall(function()
                if btn.OnButtonBaseClicked then
                    btn.OnButtonBaseClicked:Add(function(clickedBtn)
                        Log("TOOLKIT MODS button clicked in Pause Menu!")
                        if InjectedCard and InjectedCard:IsValid() then
                            local vis = InjectedCard:GetVisibility()
                            if vis == 0 then
                                InjectedCard:SetVisibility(2) -- Collapsed
                                Log("Dashboard card collapsed.")
                            else
                                InjectedCard.Title:SetText(MakeFText(GenerateMenuText()))
                                InjectedCard:SetVisibility(0) -- Visible
                                Log("Dashboard card made visible.")
                            end
                        end
                    end)
                end
            end)

            -- Add to VerticalBox_PauseMenu
            local addOk = pcall(function() vbox:AddChildToVerticalBox(btn) end)
            if addOk then
                InjectedButton = btn
                LastPauseMenuAddr = addr
                Log(string.format("Injected 'TOOLKIT MODS' button [0x%X] into Pause Menu VerticalBox!", btn:GetAddress()))
            end
        end
    end
end

-- ============================================================
-- Hook: On Pause Menu Opened (BP_GetDesiredFocusTarget)
-- ============================================================

RegisterHook("/Game/UI/InGameMenus/WBP_PauseMenuScreen.WBP_PauseMenuScreen_C:BP_GetDesiredFocusTarget", function(Context)
    local pm = Context:get()
    if pm and pm:IsValid() then
        ExecuteInGameThread(function()
            SetupPauseMenuModCard(pm)
        end)
    end
end)

-- Polling fallback: ensures injection occurs even if hook didn't fire
LoopAsync(300, function()
    ExecuteInGameThread(function()
        local pauseMenus = FindAllOf("WBP_PauseMenuScreen_C") or {}
        for _, pm in ipairs(pauseMenus) do
            if IsValidUObject(pm) then
                SetupPauseMenuModCard(pm)
                break
            end
        end

        -- Clean up references when pause menu closes
        if InjectedButton and not InjectedButton:IsValid() then
            InjectedButton = nil
            InjectedCard = nil
            LastPauseMenuAddr = nil
        end
    end)
    return false
end)

-- ============================================================
-- Standalone Viewport Overlay for [F8] Keybind
-- ============================================================

local function ToggleStandaloneOverlay()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return end

    if IsStandaloneVisible and StandaloneOverlay and StandaloneOverlay:IsValid() then
        StandaloneOverlay:SetVisibility(2)
        IsStandaloneVisible = false
        Log("Standalone Mod Menu overlay hidden [F8].")
        return
    end

    if not StandaloneOverlay or not StandaloneOverlay:IsValid() then
        CleanupAllOrphans(nil)
        local tooltipClass = StaticFindObject("/Game/UI/Common/WBP_TitleOnlyTooltip.WBP_TitleOnlyTooltip_C")
        if not tooltipClass or not tooltipClass:IsValid() then return end

        local WBLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local widget = nil
        if WBLib and WBLib:IsValid() and WBLib.Create then
            pcall(function() widget = WBLib:Create(PC, tooltipClass, PC) end)
        end
        if not widget or not widget:IsValid() then
            pcall(function() widget = StaticConstructObject(tooltipClass, PC) end)
        end
        if not widget or not widget:IsValid() then return end

        StandaloneOverlay = widget
        OwnedWidgetName = StandaloneOverlay:GetFullName()
        if ModRef then
            pcall(function() ModRef:SetSharedVariable("ModMenu.OwnedWidgetName", OwnedWidgetName) end)
        end

        StandaloneOverlay:AddToViewport(9999)
    end

    -- Update layout & text
    pcall(function()
        local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local viewport = layout:GetViewportSize(PC)
        local dpi = layout:GetViewportScale(PC)
        local screenW = viewport.X / dpi
        local screenH = viewport.Y / dpi

        StandaloneOverlay:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
        StandaloneOverlay:SetPositionInViewport({ X = math.max(screenW * 0.42, 540.0), Y = math.max((screenH - 580.0) * 0.42, 60.0) }, false)
        StandaloneOverlay:SetDesiredSizeInViewport({ X = 640.0, Y = 580.0 })

        if StandaloneOverlay.SizeBox_2 and StandaloneOverlay.SizeBox_2:IsValid() then
            StandaloneOverlay.SizeBox_2:SetWidthOverride(640.0)
            StandaloneOverlay.SizeBox_2:SetHeightOverride(580.0)
        end
        if StandaloneOverlay.Background and StandaloneOverlay.Background:IsValid() then
            StandaloneOverlay.Background:SetColorAndOpacity({ R = 0.03, G = 0.04, B = 0.08, A = 0.96 })
        end
        if StandaloneOverlay.Title and StandaloneOverlay.Title:IsValid() then
            StandaloneOverlay.Title:SetText(MakeFText(GenerateMenuText()))
            StandaloneOverlay.Title:SetAutoWrapText(true)
            StandaloneOverlay.Title:SetColorAndOpacity({
                SpecifiedColor = { R = 0.96, G = 0.89, B = 0.62, A = 1.0 },
                ColorUseRule = 0
            })
            StandaloneOverlay.Title:SetShadowOffset({ X = 1.5, Y = 1.5 })
            StandaloneOverlay.Title:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.9 })
        end

        StandaloneOverlay:SetVisibility(0)
        IsStandaloneVisible = true
        Log("Standalone Mod Menu overlay shown [F8].")
    end)
end

-- Keybind: [F8] Toggle Standalone Overlay
if Key.F8 then
    RegisterKeyBind(Key.F8, function()
        ExecuteInGameThread(function()
            ToggleStandaloneOverlay()
        end)
    end)
    Log("Keybind registered: [F8: Toggle Standalone Mod Menu Overlay]")
end

Log("Toolkit Mod Menu initialized successfully.")
