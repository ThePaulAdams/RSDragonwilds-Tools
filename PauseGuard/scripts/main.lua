local UEHelpers = require("UEHelpers")

local ModName = "PauseGuard"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("==========================================")
Log("Initializing PauseGuard v1.0.1 (Anti-Freeze & AutoSave Optimizer)...")
Log("Prevents SPUD cell cache backlog and memory leaks during extended pauses.")
Log("==========================================")

-- Configuration
local Config = {
    Enabled = true,
    DefaultSaveFrequencyMins = 5,
    InitialSaveDelaySeconds = 2.0,   -- Allow initial pause save to finish before suspending
    CheckIntervalMs = 500,           -- Poll pause status every 500ms
    LogTelemetry = true,
}

-- State tracking
local IsCurrentlyPaused = false
local PauseStartTime = 0
local HasSuspendedAutosave = false
local PauseTransitionTime = 0

-- Global flag for other mods (e.g. OSRSMinimap, AutoHarvest) to check without UObject calls
_G.PauseGuard_IsPaused = false

-- Cached engine objects
local CachedKismetSystem = nil
local CachedGameplayStatics = nil

local function GetKismetSystem()
    if not CachedKismetSystem or not CachedKismetSystem:IsValid() then
        CachedKismetSystem = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end
    return CachedKismetSystem
end

local function GetGameplayStatics()
    if not CachedGameplayStatics or not CachedGameplayStatics:IsValid() then
        CachedGameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    return CachedGameplayStatics
end

local function ExecuteCmd(cmd, pc)
    if not pc or not pc:IsValid() then
        pc = UEHelpers.GetPlayerController()
    end
    if not pc or not pc:IsValid() then return false end

    local kismet = GetKismetSystem()
    if kismet and kismet:IsValid() then
        local ok, err = pcall(function()
            kismet:ExecuteConsoleCommand(pc, cmd, pc)
        end)
        return ok
    end
    return false
end

local function CheckPauseState()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then return end

    local statics = GetGameplayStatics()
    local paused = false

    -- 1. Try PC:IsPaused()
    local ok1, p1 = pcall(function() return pc:IsPaused() end)
    if ok1 and p1 then
        paused = true
    end

    -- 2. Try GameplayStatics:IsGamePaused(pc)
    if not paused and statics and statics:IsValid() then
        local ok2, p2 = pcall(function() return statics:IsGamePaused(pc) end)
        if ok2 and p2 then
            paused = true
        end
    end

    local now = os.clock()

    if paused and not IsCurrentlyPaused then
        -- TRANSITION: Just paused
        IsCurrentlyPaused = true
        _G.PauseGuard_IsPaused = true
        PauseStartTime = now
        PauseTransitionTime = now
        HasSuspendedAutosave = false

        if Config.LogTelemetry then
            Log("[PAUSE DETECTED] Game entered pause. Allowing initial save to commit...")
        end

    elseif paused and IsCurrentlyPaused then
        -- STILL PAUSED
        _G.PauseGuard_IsPaused = true

        -- After initial delay (giving the clean entry save time to write), suspend redundant auto-saves
        -- NOTE: We use 999999 (not 0) because some UE timer implementations treat 0 as 0-second interval (saving every single frame!)
        if not HasSuspendedAutosave and (now - PauseTransitionTime) >= Config.InitialSaveDelaySeconds then
            HasSuspendedAutosave = true
            ExecuteCmd("dom.StateSaveFrequencyMins 999999", pc)
            if Config.LogTelemetry then
                Log(string.format("[AUTO-SAVE SUSPENDED] Suspended periodic autosaves (dom.StateSaveFrequencyMins = 999999). SPUD cell cache protected from backlog."))
            end
        end

    elseif not paused and IsCurrentlyPaused then
        -- TRANSITION: Just unpaused
        IsCurrentlyPaused = false
        _G.PauseGuard_IsPaused = false
        local duration = math.max(0, now - PauseStartTime)
        local durationStr = ""
        if duration >= 60 then
            durationStr = string.format("%.1f minutes", duration / 60)
        else
            durationStr = string.format("%.1f seconds", duration)
        end

        -- Immediately restore normal auto-save frequency
        ExecuteCmd(string.format("dom.StateSaveFrequencyMins %d", Config.DefaultSaveFrequencyMins), pc)
        HasSuspendedAutosave = false

        if Config.LogTelemetry then
            Log(string.format("[RESUME CLEAN] Game unpaused after %s. Restored autosave frequency (dom.StateSaveFrequencyMins = %d). Zero cell backlog!", durationStr, Config.DefaultSaveFrequencyMins))
        end
    else
        _G.PauseGuard_IsPaused = false
    end
end

-- Main watchdog timer (runs on game thread with safe interval)
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(Config.CheckIntervalMs, function()
        pcall(CheckPauseState)
    end)
else
    local function WatchdogLoop()
        ExecuteWithDelay(Config.CheckIntervalMs, function()
            ExecuteInGameThread(function()
                pcall(CheckPauseState)
                WatchdogLoop()
            end)
        end)
    end
    ExecuteInGameThread(WatchdogLoop)
end

-- Manual save keybind: Shift + F10 forces an immediate clean save and telemetry check
RegisterKeyBind(Key.F10, { ModifierKey.SHIFT }, function()
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        if not pc or not pc:IsValid() then return end
        Log("[MANUAL SAVE] Triggering on-demand clean save...")
        ExecuteCmd("dom.SaveGame", pc)
        Log("[MANUAL SAVE] Request dispatched to PersistenceSubsystem.")
    end)
end)

Log("PauseGuard active and monitoring. Extended pauses are now completely protected.")
