local UEHelpers = require("UEHelpers")
local function Log(message) print("[ModMenu] " .. tostring(message) .. "\n") end

-- Reuse game assets without changing the game's pause widget or navigation tree.
-- Only the two buttons we create are handled by the void click hook below.
local VISIBLE, COLLAPSED, NO_HIT_TEST = 0, 1, 3
local BUTTON = "/Game/UI/Common/WBP_DomAllCapsButton.WBP_DomAllCapsButton_C"
local ITEM = "/Game/UI/Common/WBP_MainMenuTabButton.WBP_MainMenuTabButton_C"
local BACK = "/Game/UI/Common/WBP_DomMainMenuBottomNavButton.WBP_DomMainMenuBottomNavButton_C"
local PAGE = "/Game/UI/Settings/WBP_SettingsWidget.WBP_SettingsWidget_C"
local Dashboard, ToolkitButton, BackButton, Owner, PauseScreen
local DetailTitle, DetailDescription, DetailStatus, DetailBindings, DetailSubtitle
local Items, HitTargets, Owned = {}, {}, {}
local SelectedIndex, CurrentStates = 1, {}
local Visible, Cleaned, Pending = false, false, false
local Tick, NextRetry = 0, 0

local function Valid(object) return object ~= nil and object:IsValid() end
local function Same(a, b) return Valid(a) and Valid(b) and a:GetAddress() == b:GetAddress() end
local function Shared(key)
    if not ModRef then return nil end
    local ok, value = pcall(function() return ModRef:GetSharedVariable(key) end)
    if ok then return value end
end
local function Save(key, value)
    if ModRef then ModRef:SetSharedVariable(key, value) end
end
local function Remove(widget)
    if Valid(widget) then
        pcall(function() widget:SetVisibility(COLLAPSED) end)
        pcall(function() widget:RemoveFromParent() end)
    end
end
local function Remember(widget)
    Owned[#Owned + 1] = widget
    local names = {}
    for _, item in ipairs(Owned) do
        if Valid(item) then names[#names + 1] = item:GetFullName() end
    end
    -- UE4SS shared variables support strings, not Lua tables/UObject references.
    Save("ModMenu.OwnedWidgets", table.concat(names, "\n"))
    return widget
end
local function CleanupOrphans(pc)
    local names = {}
    for _, key in ipairs({"ModMenu.OwnedWidgets", "ModMenu.OwnedName", "ModMenu.OwnedRows"}) do
        local value = Shared(key)
        if type(value) == "string" then
            for name in value:gmatch("[^\n]+") do names[name] = true end
        end
    end
    for _, class in ipairs({"WBP_SettingsWidget_C", "WBP_MainMenuTabButton_C", "WBP_DomTextBlock_C",
        "WBP_PlayerList_C", "WBP_PlayerListItem_C", "WBP_TitleOnlyTooltip_C",
        "WBP_DomAllCapsButton_C", "WBP_DomMainMenuBottomNavButton_C"}) do
        for _, widget in ipairs(FindAllOf(class) or {}) do
            if Valid(widget) then
                if names[widget:GetFullName()] then
                    Remove(widget)
                elseif class == "WBP_DomAllCapsButton_C" and Valid(pc) then
                    -- The previous version forgot to persist its entry button.
                    -- Match its exact label AND standalone viewport/player ownership.
                    local ok, legacy = pcall(function()
                        return widget:IsInViewport() and Same(widget:GetOwningPlayer(), pc)
                            and widget.ButtonLabel:ToString() == "Toolkit  /  MODS & HOTKEYS"
                    end)
                    if ok and legacy then Remove(widget) end
                end
            end
        end
    end
    for _, key in ipairs({"ModMenu.OwnedWidgets", "ModMenu.OwnedName", "ModMenu.OwnedRows"}) do Save(key, "") end
    Cleaned = true
end
local function Destroy()
    for _, widget in ipairs(Owned) do Remove(widget) end
    Dashboard, ToolkitButton, BackButton, Owner, PauseScreen = nil, nil, nil, nil, nil
    DetailTitle, DetailDescription, DetailStatus, DetailBindings, DetailSubtitle = nil, nil, nil, nil, nil
    Items, HitTargets, Owned, Visible = {}, {}, {}, false
    SelectedIndex, CurrentStates = 1, {}
    Save("ModMenu.OwnedWidgets", "")
end
local function FText(value)
    local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    assert(Valid(lib), "text library unavailable")
    return lib:Conv_StringToText(value)
end
local function CreateWidget(pc, path, z)
    local class = StaticFindObject(path)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    assert(Valid(class) and Valid(lib), "game UI asset unavailable: " .. path)
    local widget = lib:Create(pc, class, pc)
    assert(Valid(widget), "game UI construction failed: " .. path)
    Remember(widget)
    widget:SetVisibility(COLLAPSED)
    widget:AddToViewport(z)
    return widget
end
local function SetText(widget, text)
    if Valid(widget) then widget:SetText(FText(text)) end
end
local function SetDisplayText(widget, text)
    if not Valid(widget) then return end
    if Valid(widget.LabelText) then SetText(widget.LabelText, text) else SetText(widget, text) end
end
local function Viewport(pc)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    assert(Valid(lib), "viewport library unavailable")
    local size, dpi = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
    assert(size and dpi and dpi > 0, "viewport not ready")
    return size.X / dpi, size.Y / dpi
end
local function Position(widget, x, y, width, height)
    widget:SetAlignmentInViewport({X=0.0, Y=0.0})
    widget:SetAnchorsInViewport({Minimum={X=0.0,Y=0.0}, Maximum={X=0.0,Y=0.0}})
    widget:SetPositionInViewport({X=x, Y=y}, false)
    widget:SetDesiredSizeInViewport({X=width, Y=height})
end

local Mods = {
    {"AutoRun", "Auto Run", "Runs forward in the camera direction without holding a movement key.", "Num Lock toggle | WASD or Escape stop"},
    {"OSRSMinimap", "OSRS Minimap", "Shows a RuneScape-style minimap and resource markers.", "F6 map | F7 reload | F9 icons | PgUp/PgDn zoom | [ / ] size"},
    {"QuickStack", "Quick Stack", "Stacks nearby items into nearby chests.", "G stack to nearby chests"},
    {"EnhancedReticle", "Enhanced Reticle", "Adds configurable reticle colour and size controls.", "F4 toggle | F1 colour | F2 size"},
    {"TelekineticWoodcraft", "Telekinetic Woodcraft", "Moves and gathers logs from a distance.", "E/V grab/place | Z log magnet | F6 radius"},
    {
        string.char(69, 110, 104, 97, 110, 99, 101, 100, 77, 97, 103, 105, 99, 83, 116, 97, 102, 102),
        string.char(69, 110, 104, 97, 110, 99, 101, 100, 32, 77, 97, 103, 105, 99, 32, 83, 116, 97, 102, 102),
        "Adds staff power tiers, emissive glow, and legendary infusion.",
        "F5 power | F3 glow | F8 infusion | Shift+F8 summon"
    },
    {"ModMenu", "Toolkit Dashboard", "Shows installed Toolkit features and their bindings.", "Pause > Toolkit | Back to menu | Ctrl+F8 toggle"},
}
local function Statuses()
    local values, file = {}, nil
    -- UE4SS loads these Lua mods from enabled.txt. Keep mods.txt as a
    -- fallback for installations that use the consolidated controller list.
    for _, path in ipairs({"enabled.txt", "Mods/enabled.txt", "ue4ss/Mods/enabled.txt",
        "Binaries/Win64/ue4ss/Mods/enabled.txt",
        "F:/Steam/steamapps/common/RSDragonwilds/RSDragonwilds/Binaries/Win64/ue4ss/Mods/enabled.txt",
        "mods.txt", "Mods/mods.txt", "ue4ss/Mods/mods.txt",
        "Binaries/Win64/ue4ss/Mods/mods.txt",
        "F:/Steam/steamapps/common/RSDragonwilds/RSDragonwilds/Binaries/Win64/ue4ss/Mods/mods.txt"}) do
        local ok, handle = pcall(io.open, path, "r")
        if ok and handle then file = handle; break end
    end
    if file then
        for line in file:lines() do
            local id, enabled = line:match("^%s*([%w_-]+)%s*:%s*(%d+)")
            if id then values[id] = tonumber(enabled) == 1 end
        end
        file:close()
    end
    return values
end

local function ActivePause(pc)
    for _, screen in ipairs(FindAllOf("WBP_PauseMenuScreen_C") or {}) do
        if Valid(screen) and Same(screen:GetOwningPlayer(), pc)
            and screen:IsVisible() and screen:IsActivated() then return screen end
    end
end
local function Layout(pc)
    local width, height = Viewport(pc)
    -- Supplemental native action on the right, clear of the original left-hand
    -- actions. Never insert/reposition their widgets.
    if Valid(ToolkitButton) then Position(ToolkitButton, width-392, height-112, 320, 56) end
    if not Visible then return end
    if Valid(BackButton) then Position(BackButton, 72, height-112, 240, 56) end
    local listWidth = math.min(580, width * 0.31)
    local rowHeight = math.min(78, (height-300) / #Mods)
    local x, y = math.max(110, width * 0.055), 244
    for index, item in ipairs(Items) do
        Position(item, x, y+(index-1)*rowHeight, listWidth, rowHeight-8)
        if Valid(HitTargets[index]) then
            Position(HitTargets[index], x, y+(index-1)*rowHeight, listWidth, rowHeight-8)
        end
    end
    if Valid(DetailTitle) then Position(DetailTitle, width * 0.47, 250, width * 0.44, 54) end
    if Valid(DetailSubtitle) then Position(DetailSubtitle, width * 0.47, 308, width * 0.44, 40) end
    if Valid(DetailDescription) then Position(DetailDescription, width * 0.47, 384, width * 0.44, 120) end
    if Valid(DetailStatus) then Position(DetailStatus, width * 0.47, 540, width * 0.44, 46) end
    if Valid(DetailBindings) then Position(DetailBindings, width * 0.47, 614, width * 0.44, 130) end
end
local function Hide()
    Visible = false
    if Valid(Dashboard) then Dashboard:SetVisibility(COLLAPSED) end
    if Valid(BackButton) then BackButton:SetVisibility(COLLAPSED) end
    for _, item in ipairs(Items) do if Valid(item) then item:SetVisibility(COLLAPSED) end end
    for _, target in ipairs(HitTargets) do if Valid(target) then target:SetVisibility(COLLAPSED) end end
    for _, detail in ipairs({DetailTitle, DetailSubtitle, DetailDescription, DetailStatus, DetailBindings}) do
        if Valid(detail) then detail:SetVisibility(COLLAPSED) end
    end
    local pc = UEHelpers.GetPlayerController()
    if Valid(ToolkitButton) then
        ToolkitButton:SetVisibility(Valid(pc) and ActivePause(pc) and VISIBLE or COLLAPSED)
    end
end
local function ConfigureSettingsPage()
    -- The Settings widget is our own instance. Collapse only its native
    -- categories/content so their input handlers cannot change game settings;
    -- the page frame, title trim and typography remain native.
    for _, name in ipairs({
        "Button_Video", "Button_Legal", "Button_Gameplay", "Button_Controls",
        "Button_Audio", "Button_Accessibility", "AudioSubWidget", "AccessibilitySubWidget",
        "GameplaySubWidget", "DeveloperSubWidget", "ControlsSubWidget", "VideoSubWidget",
        "LegalSubWidget", "WBP_SettingTooltipContainer", "SubCategoryScroller",
        "SubCategoryButtonGroup", "SubTabLeftInputActionWidget", "SubTabRightInputActionWidget",
    }) do
        local child = Dashboard[name]
        if Valid(child) then child:SetVisibility(COLLAPSED) end
    end
end
local function CreatePage(pc)
    Dashboard = CreateWidget(pc, PAGE, 9999)
    ConfigureSettingsPage()
    SetText(Dashboard.WBP_MainMenu_ScreenTitle and Dashboard.WBP_MainMenu_ScreenTitle.HeaderTextBlock,
        "MODS & KEY BINDINGS")
    BackButton = CreateWidget(pc, BACK, 10001)
    BackButton:SetLabelText(FText("BACK"))
    BackButton:SetIsFocusable(false)
    -- Standalone Back has no Player List blueprint delegate attached. Its click
    -- only hides our page; it cannot call the game's player-list Back handler.
    for index = 1, #Mods do
        local item = CreateWidget(pc, ITEM, 10000)
        item:SetIsFocusable(false)
        local target = CreateWidget(pc, BUTTON, 10001)
        target:SetLabelText(FText(""))
        target:SetIsFocusable(false)
        target:SetRenderOpacity(0.0)
        Items[index], HitTargets[index] = item, target
    end
    -- MainMenuTabButton is a UserWidget with the game's native label and
    -- selection treatment. It is used as a read-only Settings-style text row;
    -- creating WBP_DomTextBlock directly is invalid because it is a TextBlock,
    -- not a UserWidget accepted by WidgetBlueprintLibrary:Create.
    DetailTitle = CreateWidget(pc, ITEM, 10000)
    DetailSubtitle = CreateWidget(pc, ITEM, 10000)
    DetailDescription = CreateWidget(pc, ITEM, 10000)
    DetailStatus = CreateWidget(pc, ITEM, 10000)
    DetailBindings = CreateWidget(pc, ITEM, 10000)
    for _, detail in ipairs({DetailTitle, DetailSubtitle, DetailDescription, DetailStatus, DetailBindings}) do
        detail:SetIsFocusable(false)
    end
end
local function StateLabel(state)
    return state == true and "ENABLED" or (state == false and "DISABLED" or "UNKNOWN")
end
local function Select(index)
    if not Mods[index] or not Valid(Dashboard) then return end
    SelectedIndex = index
    local mod, state = Mods[index], CurrentStates[Mods[index][1]]
    for itemIndex, item in ipairs(Items) do
        if Valid(item) then
            if itemIndex == index and item.BP_OnSelected then
                pcall(function() item:BP_OnSelected() end)
            elseif itemIndex ~= index and item.BP_OnDeselected then
                pcall(function() item:BP_OnDeselected() end)
            elseif item.BP_OnItemSelectionChanged then
                pcall(function() item:BP_OnItemSelectionChanged(itemIndex == index) end)
            end
        end
    end
    SetDisplayText(DetailTitle, mod[2])
    SetDisplayText(DetailDescription, mod[3])
    SetDisplayText(DetailStatus, "STATUS  /  " .. StateLabel(state))
    SetDisplayText(DetailBindings, "KEY BINDINGS\n" .. mod[4])
end
local function Show(pc, pause)
    if not Valid(pause) then return end
    if not Valid(Dashboard) then CreatePage(pc) end
    ConfigureSettingsPage()
    local states, enabled = Statuses(), 0
    CurrentStates = states
    for index, mod in ipairs(Mods) do
        local state = states[mod[1]]
        if state == true then enabled = enabled + 1 end
        SetDisplayText(Items[index], mod[2])
    end
    SetDisplayText(DetailSubtitle, tostring(enabled) .. " / " .. #Mods .. " configured enabled  |  Read-only")
    Select(1)
    PauseScreen, Visible = pause, true
    Layout(pc)
    Dashboard:SetVisibility(VISIBLE)
    BackButton:SetVisibility(VISIBLE)
    for _, item in ipairs(Items) do item:SetVisibility(VISIBLE) end
    for _, target in ipairs(HitTargets) do target:SetVisibility(VISIBLE) end
    for _, detail in ipairs({DetailTitle, DetailSubtitle, DetailDescription, DetailStatus, DetailBindings}) do
        detail:SetVisibility(VISIBLE)
    end
    if Valid(ToolkitButton) then ToolkitButton:SetVisibility(COLLAPSED) end
    Log("Toolkit page opened by user")
end
local function Toggle()
    if Visible then Hide(); return end
    local pc = UEHelpers.GetPlayerController()
    if Valid(pc) and Same(Owner, pc) then Show(pc, ActivePause(pc)) end
end
local function Guard(callback)
    local ok, message = pcall(callback)
    if not ok then
        -- Remove partial overlays so the stock menu stays usable on Lua failure.
        pcall(Destroy)
        NextRetry = Tick + 40
        Log("Toolkit UI removed after error: " .. tostring(message))
    end
end
local function Update()
    local pc = UEHelpers.GetPlayerController()
    if not Cleaned then CleanupOrphans(pc) end
    if not Valid(pc) then Destroy(); return end
    if Owner and not Same(Owner, pc) then Destroy() end
    Owner = pc
    local pause = ActivePause(pc)
    if not pause then
        if #Owned > 0 then Destroy() end
        return
    end
    if PauseScreen and not Same(PauseScreen, pause) then Destroy(); Owner = pc end
    PauseScreen = pause
    if not Valid(ToolkitButton) then
        ToolkitButton = CreateWidget(pc, BUTTON, 10000)
        ToolkitButton:SetLabelText(FText("TOOLKIT"))
        ToolkitButton:SetIsFocusable(false)
        Log("Toolkit menu button attached")
    end
    Layout(pc)
    ToolkitButton:SetVisibility(Visible and COLLAPSED or VISIBLE)
    -- Opening Pause must NEVER call Show: page creation requires user activation.
end

LoopAsync(250, function()
    if Pending then return false end
    Pending = true
    ExecuteInGameThread(function()
        Tick = Tick + 1
        if Tick >= NextRetry then Guard(Update) end
        Pending = false
    end)
    return false
end)
if Key.F8 and ModifierKey and ModifierKey.CONTROL then
    RegisterKeyBind(Key.F8, {ModifierKey.CONTROL}, function()
        ExecuteInGameThread(function() Guard(Toggle) end)
    end)
end
if Key.ESCAPE then
    RegisterKeyBind(Key.ESCAPE, function()
        -- UE4SS keybinds do not consume the game's Escape input. Mouse Back is
        -- the return-to-menu action; Escape may also resume gameplay.
        ExecuteInGameThread(function() Guard(function() if Visible then Hide() end end) end)
    end)
end
RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(context)
    -- Native hook context is RemoteUnrealParam, not a UWidget.
    local ok, button = pcall(function() return context:get() end)
    if not ok then return end
    Guard(function()
        if Same(button, ToolkitButton) then
            ExecuteInGameThread(function() Guard(Toggle) end)
        elseif Same(button, BackButton) then
            ExecuteInGameThread(function() Guard(Hide) end)
        else
            for index, target in ipairs(HitTargets) do
                if Same(button, target) then
                    ExecuteInGameThread(function() Guard(function() Select(index) end) end)
                    break
                end
            end
        end
    end)
    -- Void hook: no return override, and no handling of the game's own buttons.
end)
Log("Menu flow v5 loaded: Settings layout with native tab items and selected feature details")

