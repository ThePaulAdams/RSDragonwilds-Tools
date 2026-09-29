-- Hot-reload-safe timers: UE4SS 3.0 runs these on the game thread and cancels them
-- when the mod unloads (LoopAsync's own thread can hang or crash a reload).
-- Inside a GameLoop body we are already on the game thread, so ExecuteInGameThread
-- runs its callback straight away; everywhere else (key binds) it still queues.
local QueueInGameThread = ExecuteInGameThread
local InGameLoop = false
local function ExecuteInGameThread(fn, ...)
    if InGameLoop then return fn() end
    return QueueInGameThread(fn, ...)
end
local function GameLoop(ms, fn)
    if not LoopInGameThreadWithDelay then return LoopAsync(ms, fn) end
    local handle
    handle = LoopInGameThreadWithDelay(ms, function()
        InGameLoop = true
        local ok, stop = pcall(fn)
        InGameLoop = false
        if not ok then print("[GameLoop] " .. tostring(stop) .. "\n") end
        if ok and stop == true and handle then CancelDelayedAction(handle) end
    end)
    return handle
end
local UEHelpers = require("UEHelpers")

local ModName = "HomeRecall"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end

-- Teleports you home after a short channel. "Home" is the spot you saved with
-- Alt+F7, or your bed if you never saved one.
local Config = {
    RecallKey = Key.F7,
    RecallModifiers = { ModifierKey.CONTROL },
    SetHomeKey = Key.F7,
    SetHomeModifiers = { ModifierKey.ALT },
    -- Stand still this long before the teleport happens (moving cancels it).
    ChannelSeconds = 3,
    -- Moving further than this during the channel cancels it (1 m).
    ChannelMoveTolerance = 100.0,
    CooldownSeconds = 60,
    -- Bed actor classes tried when no home has been saved.
    -- (the only bed class in the object dump is the base-building bedroll)
    BedClasses = { "BP_BaseBuilding_BedRoll_C" },
}

local function Valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:IsValid() and o:GetAddress() ~= 0 end)
    return ok and res
end

-- =========================================================================
-- On-screen toast (reuses the game's own tab-button widget as a text label)
-- =========================================================================
local Toast = { Widget = nil, HideTick = 0, Tick = 0 }
local TOAST_CLASS = "/Game/UI/Common/WBP_MainMenuTabButton.WBP_MainMenuTabButton_C"
do
    local recorded = nil
    if ModRef then pcall(function() recorded = ModRef:GetSharedVariable(ModName .. ".Toast") end) end
    if type(recorded) == "string" and recorded ~= "" then
        ExecuteInGameThread(function()
            for _, w in ipairs(FindAllOf("WBP_MainMenuTabButton_C") or {}) do
                if Valid(w) and w:GetFullName() == recorded then
                    pcall(function() w:RemoveFromParent() end)
                end
            end
        end)
    end
end
local function ToastClass()
    local cls = StaticFindObject(TOAST_CLASS)
    if not Valid(cls) and LoadAsset then
        pcall(function() LoadAsset(TOAST_CLASS) end)
        cls = StaticFindObject(TOAST_CLASS)
    end
    return Valid(cls) and cls or nil
end
function Toast.Show(text, seconds)
    local ok, err = pcall(function()
        local pc = UEHelpers.GetPlayerController()
        if not Valid(pc) then return end
        if not Valid(Toast.Widget) then
            local cls, lib = ToastClass(), StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if not cls or not Valid(lib) then return end
            Toast.Widget = lib:Create(pc, cls, pc)
            if not Valid(Toast.Widget) then return end
            Toast.Widget:SetIsFocusable(false)
            Toast.Widget:AddToViewport(10050)
            if ModRef then ModRef:SetSharedVariable(ModName .. ".Toast", Toast.Widget:GetFullName()) end
        end
        local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size, dpi = layout:GetViewportSize(pc), layout:GetViewportScale(pc)
        local w, h = 620, 64
        Toast.Widget:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
        Toast.Widget:SetAnchorsInViewport({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        Toast.Widget:SetPositionInViewport({ X = size.X / dpi / 2 - w / 2, Y = size.Y / dpi * 0.72 }, false)
        Toast.Widget:SetDesiredSizeInViewport({ X = w, Y = h })
        local textLib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        local label = Valid(Toast.Widget.LabelText) and Toast.Widget.LabelText or Toast.Widget
        label:SetText(textLib:Conv_StringToText(text))
        Toast.Widget:SetVisibility(3) -- HitTestInvisible: never steals clicks
        Toast.HideTick = Toast.Tick + math.floor((seconds or 3) * 10)
    end)
    if not ok then Log("Toast failed: " .. tostring(err)) end
end
GameLoop(100, function()
    Toast.Tick = Toast.Tick + 1
    if Toast.HideTick > 0 and Toast.Tick >= Toast.HideTick then
        Toast.HideTick = 0
        ExecuteInGameThread(function()
            if Valid(Toast.Widget) then pcall(function() Toast.Widget:SetVisibility(1) end) end
        end)
    end
    return false
end)

-- =========================================================================
-- Saved home (one per install; written next to this script)
-- =========================================================================
local ScriptDir = (debug.getinfo(1, "S").source or ""):match("^@(.*[/\\])") or ""
local HomeFile = ScriptDir .. "home.txt"
local Home = nil -- { X, Y, Z, Yaw }

local function LoadHome()
    local f = io.open(HomeFile, "r")
    if not f then return end
    local line = f:read("*l") or ""
    f:close()
    local x, y, z, yaw = line:match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)")
    if x then Home = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z), Yaw = tonumber(yaw) } end
end

local function SaveHome()
    local f = io.open(HomeFile, "w")
    if not f then
        Log("Could not write " .. HomeFile)
        return
    end
    f:write(string.format("%.1f,%.1f,%.1f,%.1f\n", Home.X, Home.Y, Home.Z, Home.Yaw))
    f:close()
end

local function FindBed()
    for _, cls in ipairs(Config.BedClasses) do
        local ok, actors = pcall(function() return FindAllOf(cls) end)
        if ok and actors then
            for _, a in ipairs(actors) do
                local loc = nil
                pcall(function()
                    if not a:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject) then
                        loc = a:K2_GetActorLocation()
                    end
                end)
                if loc then return { X = loc.X, Y = loc.Y, Z = loc.Z, Yaw = 0 }, cls end
            end
        end
    end
    return nil
end

-- =========================================================================
-- Recall
-- =========================================================================
local State = { Channeling = false, EndTick = 0, Start = nil, LastRecall = -math.huge, Tick = 0 }

local function Pawn()
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) or not Valid(pc.Pawn) then return nil end
    return pc.Pawn, pc
end

local function SetHome()
    local pawn, pc = Pawn()
    if not pawn then return end
    local loc, rot = pawn:K2_GetActorLocation(), pc:GetControlRotation()
    Home = { X = loc.X, Y = loc.Y, Z = loc.Z, Yaw = rot.Yaw }
    SaveHome()
    Log(string.format("Home saved at (%.0f, %.0f, %.0f).", Home.X, Home.Y, Home.Z))
    Toast.Show("Home set here", 2)
end

local function Teleport()
    local pawn = Pawn()
    if not pawn then return end
    local dest, source = Home, "saved home"
    if not dest then
        local bedClass
        dest, bedClass = FindBed()
        source = bedClass and ("bed " .. bedClass) or nil
    end
    if not dest then
        Toast.Show("No home set. Press Alt+F7 at home first", 4)
        return
    end
    local ok, res = pcall(function()
        return pawn:K2_TeleportTo({ X = dest.X, Y = dest.Y, Z = dest.Z + 100.0 }, { Pitch = 0, Yaw = dest.Yaw or 0, Roll = 0 })
    end)
    if ok and res ~= false then
        State.LastRecall = os.time()
        Log("Recalled to " .. source)
        Toast.Show("Welcome home", 2)
    else
        Log("Teleport failed: " .. tostring(res))
        Toast.Show("Recall blocked here", 3)
    end
end

local function StartRecall()
    if State.Channeling then
        State.Channeling = false
        Toast.Show("Recall cancelled", 2)
        return
    end
    local wait = Config.CooldownSeconds - (os.time() - State.LastRecall)
    if wait > 0 then
        Toast.Show(string.format("Recall ready in %d s", wait), 2)
        return
    end
    local pawn = Pawn()
    if not pawn then return end
    State.Channeling = true
    State.Start = pawn:K2_GetActorLocation()
    State.EndTick = State.Tick + Config.ChannelSeconds * 10
    Toast.Show(string.format("Recalling home in %d s... hold still", Config.ChannelSeconds), Config.ChannelSeconds + 1)
end

GameLoop(100, function()
    State.Tick = State.Tick + 1
    if not State.Channeling then return false end
    ExecuteInGameThread(function()
        if not State.Channeling then return end
        local pawn = Pawn()
        if not pawn then State.Channeling = false; return end
        local loc = pawn:K2_GetActorLocation()
        local dx, dy, dz = loc.X - State.Start.X, loc.Y - State.Start.Y, loc.Z - State.Start.Z
        if dx * dx + dy * dy + dz * dz > Config.ChannelMoveTolerance ^ 2 then
            State.Channeling = false
            Toast.Show("Recall cancelled (you moved)", 2)
            return
        end
        if State.Tick >= State.EndTick then
            State.Channeling = false
            Teleport()
        end
    end)
    return false
end)

do
    RegisterKeyBind(Config.RecallKey, Config.RecallModifiers, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(StartRecall)
            if not ok then Log("Error: " .. tostring(err)) end
        end)
    end)
end
do
    RegisterKeyBind(Config.SetHomeKey, Config.SetHomeModifiers, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(SetHome)
            if not ok then Log("Error: " .. tostring(err)) end
        end)
    end)
end

LoadHome()
Log(Home and string.format("Ready. Home at (%.0f, %.0f, %.0f).", Home.X, Home.Y, Home.Z)
    or "Ready. No home saved yet: Alt+F7 saves one, Ctrl+F7 recalls (falls back to your bed).")
