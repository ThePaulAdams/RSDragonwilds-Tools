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

local ModName = "RaidWarning"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end

-- Warns you on screen when hostiles gather near your base (anywhere within
-- Radius of one of your chests), wherever you are on the map.
local Config = {
    ScanIntervalMs = 2000,
    -- Hostiles within this distance of any of your chests count (60 m).
    Radius = 6000.0,
    -- How many hostiles near the base it takes to raise the alarm.
    MinHostiles = 2,
    -- Don't repeat the alarm for the same raid for this long.
    CooldownSeconds = 120,
    -- Skip the alarm when you are already standing at the base (within this distance of a chest, 40 m).
    QuietWhenHomeRadius = 4000.0,
    -- Non-player characters whose class name contains one of these count as hostile.
    HostilePatterns = { "goblin", "warband", "raider", "bandit" },
    -- Base storage classes used as anchors for "your base".
    BaseAnchorClasses = {
        "BP_BaseBuilding_Chest_C", "BP_BaseBuilding_Chest_Small_C",
        "BP_BaseBuilding_Crate_C", "BP_BaseBuilding_LumberStorage_C",
    },
    DebugLog = true,
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

local function IsWorldActor(a)
    local ok, res = pcall(function()
        return a:IsValid() and not a:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject)
    end)
    return ok and res
end

local function ClassName(a)
    local n = ""
    pcall(function() n = a:GetClass():GetFName():ToString() end)
    return n
end

local function BaseAnchors()
    local anchors = {}
    for _, cls in ipairs(Config.BaseAnchorClasses) do
        local ok, actors = pcall(function() return FindAllOf(cls) end)
        if ok and actors then
            for _, a in ipairs(actors) do
                if IsWorldActor(a) then
                    local loc = nil
                    pcall(function() loc = a:K2_GetActorLocation() end)
                    if loc then anchors[#anchors + 1] = loc end
                end
            end
        end
    end
    return anchors
end

local function DistSq(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function IsHostile(cls)
    local l = cls:lower()
    for _, p in ipairs(Config.HostilePatterns) do
        if l:find(p, 1, true) then return true end
    end
    return false
end

local LastAlarm = -math.huge
local LoggedClasses = {}

local function Scan()
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) or not Valid(pc.Pawn) then return end
    local anchors = BaseAnchors()
    if #anchors == 0 then return end

    local ok, chars = pcall(function() return FindAllOf("Character") end)
    if not ok or not chars then return end

    local radiusSq = Config.Radius * Config.Radius
    local hostiles, nearest = 0, nil
    for _, c in ipairs(chars) do
        if IsWorldActor(c) then
            local isPlayer = false
            pcall(function() isPlayer = c:IsPlayerControlled() end)
            if not isPlayer then
                local loc = nil
                pcall(function() loc = c:K2_GetActorLocation() end)
                if loc then
                    for _, anchor in ipairs(anchors) do
                        local d = DistSq(loc, anchor)
                        if d <= radiusSq then
                            local cls = ClassName(c)
                            if Config.DebugLog and not LoggedClasses[cls] then
                                LoggedClasses[cls] = true
                                Log(string.format("[DISCOVERY] Non-player near base: %s (%s)", cls,
                                    IsHostile(cls) and "counted as hostile" or "ignored"))
                            end
                            if IsHostile(cls) then
                                hostiles = hostiles + 1
                                nearest = anchor
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    if hostiles < Config.MinHostiles then return end
    if os.time() - LastAlarm < Config.CooldownSeconds then return end

    local playerLoc = pc.Pawn:K2_GetActorLocation()
    local home = false
    for _, anchor in ipairs(anchors) do
        if DistSq(playerLoc, anchor) <= Config.QuietWhenHomeRadius ^ 2 then home = true; break end
    end
    LastAlarm = os.time()
    if home then
        Log(string.format("%d hostiles at your base (you are here).", hostiles))
        return
    end
    local metres = math.sqrt(DistSq(playerLoc, nearest)) / 100.0
    Log(string.format("RAID: %d hostiles near your base, %.0f m away.", hostiles, metres))
    Toast.Show(string.format("Raid! %d enemies at your base (%.0f m away)", hostiles, metres), 8)
end

local Busy = false
GameLoop(Config.ScanIntervalMs, function()
    if Busy then return false end
    Busy = true
    ExecuteInGameThread(function()
        local ok, err = pcall(Scan)
        if not ok then Log("Error: " .. tostring(err)) end
        Busy = false
    end)
    return false
end)

Log(string.format("Ready: alerts when %d+ hostiles come within %.0f m of your chests.", Config.MinHostiles, Config.Radius / 100.0))
