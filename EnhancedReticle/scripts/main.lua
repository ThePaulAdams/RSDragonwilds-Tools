local UEHelpers = require("UEHelpers")

local ModName = "EnhancedReticle"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing Enhanced Reticle Mod (Crash-Safe Event-Driven Build)...")
Log("High-visibility crosshair & cast cursor enhancements.")
Log("Controls: [F4] Toggle, [F11] Cycle Color, [F12] Cycle Size.")
Log("==========================================")

-- Configuration & State
local Config = {
    Enabled = true,

    -- Default: Neon Green (index 1)
    CurrentColorIndex = 1,

    -- Default: 2.0x Prominent (index 3)
    CurrentSizeIndex = 3,

    -- Target reticle widget classes in Dragonwilds
    ReticleClasses = {
        "WBP_ReticleDefault_C",
        "WBP_ReticleAimingUtilityMagic_C",
        "WBP_ReticleMagic_C",
        "WBP_ReticleRangedADS_C",
        "WBP_ReticleStealth_C",
        "WBP_ReticleRepair_C",
        "WBP_FishingReticle_C",
    },

    -- High-Contrast Color Palette
    Colors = {
        { Name = "Neon Green",   R = 0.00, G = 1.00, B = 0.25, A = 1.00 },
        { Name = "OSRS Gold",    R = 1.00, G = 0.84, B = 0.00, A = 1.00 },
        { Name = "Cyan",         R = 0.00, G = 0.90, B = 1.00, A = 1.00 },
        { Name = "Crimson Red",  R = 1.00, G = 0.15, B = 0.15, A = 1.00 },
        { Name = "Hot Pink",     R = 1.00, G = 0.10, B = 0.80, A = 1.00 },
        { Name = "Amber Orange", R = 1.00, G = 0.55, B = 0.00, A = 1.00 },
        { Name = "Pure White",   R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
    },

    -- Size Profiles (Scale Multipliers)
    Sizes = {
        { Name = "1.0x (Vanilla)", Scale = 1.00 },
        { Name = "1.5x (Medium)",  Scale = 1.50 },
        { Name = "2.0x (Large)",   Scale = 2.00 },
        { Name = "2.5x (XL)",      Scale = 2.50 },
        { Name = "3.2x (Massive)", Scale = 3.20 },
    },
}

-- Vanilla defaults for reverting when disabled
local VanillaColor = { R = 1.0, G = 1.0, B = 1.0, A = 0.7 }
local VanillaScale = 1.0

-- Helper: Check if an object is a valid, real game instance (filters out CDOs & archetypes)
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

-- Helper: Find Crosshair Image inside a reticle widget
local function FindCrosshair(widget)
    if not IsValidInstance(widget) then return nil end
    local crosshair = nil
    pcall(function()
        if widget.Crosshair and widget.Crosshair:IsValid() and widget.Crosshair:GetAddress() ~= 0 then
            crosshair = widget.Crosshair
        elseif widget.WidgetTree and widget.WidgetTree:IsValid() then
            if widget.WidgetTree.Crosshair and widget.WidgetTree.Crosshair:IsValid() and widget.WidgetTree.Crosshair:GetAddress() ~= 0 then
                crosshair = widget.WidgetTree.Crosshair
            end
        end
    end)
    return crosshair
end

-- Helper: Apply styling to a crosshair Image
local function StyleCrosshair(crosshair, col, scale)
    if not crosshair or not crosshair:IsValid() or crosshair:GetAddress() == 0 then return end

    pcall(function()
        -- Ensure pivot is centered so scaling expands symmetrically from exact screen center
        crosshair:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })

        -- Scale
        crosshair:SetRenderScale({ X = scale, Y = scale })

        -- Color and Opacity
        crosshair:SetColorAndOpacity({ R = col.R, G = col.G, B = col.B, A = col.A })

        -- Ensure full opacity
        pcall(function() crosshair:SetOpacity(col.A) end)
        pcall(function() crosshair:SetRenderOpacity(col.A) end)
    end)
end

-- Apply styling to all active reticle widgets (strictly executed on Game Thread)
local function ApplyStyleToAllReticles(notifyLog)
    local col = Config.Enabled and Config.Colors[Config.CurrentColorIndex] or VanillaColor
    local scale = Config.Enabled and Config.Sizes[Config.CurrentSizeIndex].Scale or VanillaScale
    local count = 0
    local seenAddresses = {}

    -- Scan individual reticle widget classes
    for _, className in ipairs(Config.ReticleClasses) do
        local ok, instances = pcall(function() return FindAllOf(className) end)
        if ok and instances then
            for _, inst in ipairs(instances) do
                if IsValidInstance(inst) then
                    local ch = FindCrosshair(inst)
                    if ch and ch:IsValid() and ch:GetAddress() ~= 0 then
                        local addr = ch:GetAddress()
                        if not seenAddresses[addr] then
                            seenAddresses[addr] = true
                            StyleCrosshair(ch, col, scale)
                            count = count + 1
                        end
                    end
                end
            end
        end
    end

    if notifyLog then
        local colorName = Config.Colors[Config.CurrentColorIndex].Name
        local sizeName = Config.Sizes[Config.CurrentSizeIndex].Name
        Log(string.format("Applied styling to %d reticle crosshair(s): Color='%s', Scale=%s, Enabled=%s",
            count, colorName, sizeName, tostring(Config.Enabled)))
    end

    return count
end

-- Keybind Actions
local function ToggleEnabled()
    Config.Enabled = not Config.Enabled
    ExecuteInGameThread(function()
        ApplyStyleToAllReticles(true)
    end)
    Log(string.format("Enhanced Reticle: %s", Config.Enabled and "ENABLED" or "DISABLED (Vanilla Restored)"))
end

local function CycleColor()
    Config.CurrentColorIndex = Config.CurrentColorIndex + 1
    if Config.CurrentColorIndex > #Config.Colors then
        Config.CurrentColorIndex = 1
    end
    Config.Enabled = true
    ExecuteInGameThread(function()
        ApplyStyleToAllReticles(true)
    end)
    local cur = Config.Colors[Config.CurrentColorIndex]
    Log(string.format("Reticle Color changed to: [%d/%d] %s", Config.CurrentColorIndex, #Config.Colors, cur.Name))
end

local function CycleSize()
    Config.CurrentSizeIndex = Config.CurrentSizeIndex + 1
    if Config.CurrentSizeIndex > #Config.Sizes then
        Config.CurrentSizeIndex = 1
    end
    Config.Enabled = true
    ExecuteInGameThread(function()
        ApplyStyleToAllReticles(true)
    end)
    local cur = Config.Sizes[Config.CurrentSizeIndex]
    Log(string.format("Reticle Size changed to: [%d/%d] %s", Config.CurrentSizeIndex, #Config.Sizes, cur.Name))
end

-- Keybind Registration helper
local function RegisterBinding(key, callback, desc)
    local ok, err = pcall(function()
        RegisterKeyBind(key, function()
            ExecuteInGameThread(callback)
        end)
    end)
    if ok then
        Log(string.format("Keybind registered: [%s] -> %s", desc, tostring(key)))
    else
        Log(string.format("ERROR registering keybind [%s]: %s", desc, tostring(err)))
    end
end

RegisterBinding(Key.F4,  ToggleEnabled, "F4: Toggle Reticle Enhancement")
RegisterBinding(Key.F11, CycleColor,    "F11: Cycle Reticle Color")
RegisterBinding(Key.F12, CycleSize,     "F12: Cycle Reticle Size")

-- Event-driven hook: automatically apply styling when player spawns/respawns
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
        ExecuteInGameThread(function()
            ApplyStyleToAllReticles(false)
        end)
    end)
end)

-- Initial apply
ExecuteInGameThread(function()
    ApplyStyleToAllReticles(true)
end)

return {
    Config = Config,
    ApplyStyleToAllReticles = ApplyStyleToAllReticles,
    ToggleEnabled = ToggleEnabled,
    CycleColor = CycleColor,
    CycleSize = CycleSize
}
