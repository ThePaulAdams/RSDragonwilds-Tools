local UEHelpers = require("UEHelpers")

local ModName = "AutoHarvest"
local function Log(msg)
    print(string.format("[%s] %s\n", ModName, tostring(msg)))
end

Log("Initializing AutoHarvest (Smart Proximity Gathering)...")

local RESOURCE_CLASSES = { "HarvestableResource", "GatherableResource" }
local RESOURCE_PATHS = { "/Script/Dominion.HarvestableResource", "/Script/Dominion.GatherableResource" }
local TEMPLATE_FLAGS = 0x00000010 + 0x00000020 -- RF_ClassDefaultObject + RF_ArchetypeObject
local WEIGHT_EPSILON = 1e-6
local MATERIAL_PATH_FRAGMENTS = { "/Game/Gameplay/Items/Resources/Plant/" }

-- Configuration defaults
local Config = {
    Enabled = true,
    RadiusCm = 350,
    ScanIntervalMs = 500,
    MaxItemWeight = 0.2,
    AllowItemCategories = { "Item.Food" },
    GatherMaterials = true,
    ToggleKey = Key.F11,
    NotifyHarvest = false,
}

local function StartsWithAny(text, prefixes)
    for _, prefix in ipairs(prefixes) do
        if text:sub(1, #prefix) == prefix then return true end
    end
    return false
end

local function ContainsAny(text, fragments)
    for _, fragment in ipairs(fragments) do
        if text:find(fragment, 1, true) then return true end
    end
    return false
end

local function HasAllowedYield(actor, pawn)
    local items = nil
    pcall(function() items = actor:GetDroppableItemData(pawn) end)
    if not items then return false end

    for index = 1, #items do
        local ok, item = pcall(function() return items[index]:get() end)
        if ok and item and item:IsValid() then
            local weight = 0.0
            pcall(function() weight = item:GetRawWeight() end)
            if weight <= Config.MaxItemWeight + WEIGHT_EPSILON then
                local cat = ""
                pcall(function() cat = item:GetCategory().TagName:ToString() end)
                if StartsWithAny(cat, Config.AllowItemCategories) then return true end

                if Config.GatherMaterials then
                    local fullName = ""
                    pcall(function() fullName = item:GetFullName() end)
                    if ContainsAny(fullName, MATERIAL_PATH_FRAGMENTS) then return true end
                end
            end
        end
    end
    return false
end

local function CandidateDistance(actor, pawn, location, limit)
    if not actor or not actor:IsValid() then return nil end
    local position = actor:K2_GetActorLocation()
    if not position then return nil end

    local dx, dy, dz = position.X - location.X, position.Y - location.Y, position.Z - location.Z
    local distSq = dx * dx + dy * dy + dz * dz
    if distSq > limit then return nil end

    local avail = false
    pcall(function() avail = actor:IsResourceAvailable() end)
    if not avail then return nil end

    if not HasAllowedYield(actor, pawn) then return nil end
    return distSq
end

local Controller = nil
local Resources = {}

local function TrackResource(actor)
    if actor and actor:IsValid() and not actor:HasAnyFlags(TEMPLATE_FLAGS) then
        local addr = actor:GetAddress()
        if addr and addr ~= 0 then
            Resources[addr] = actor
        end
    end
end

for _, path in ipairs(RESOURCE_PATHS) do
    NotifyOnNewObject(path, function(actor)
        ExecuteInGameThread(function() TrackResource(actor) end)
    end)
end

local function HarvestNearby()
    if not Config.Enabled then return end

    if not Controller or not Controller:IsValid() then
        Controller = UEHelpers.GetPlayerController()
    end
    if not Controller or not Controller:IsValid() then return end

    -- Avoid harvesting while menus/cursor are open or while game is paused
    if Controller.bShowMouseCursor then return end
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if statics and statics:IsValid() and statics:IsGamePaused(Controller) then return end

    local pawn = Controller.Pawn
    if not pawn or not pawn:IsValid() then return end

    local location = pawn:K2_GetActorLocation()
    if not location then return end

    local target, nearest = nil, Config.RadiusCm * Config.RadiusCm
    for address, actor in pairs(Resources) do
        local distance = nil
        if actor and actor:IsValid() and not actor:IsActorBeingDestroyed() then
            distance = CandidateDistance(actor, pawn, location, nearest)
        else
            Resources[address] = nil
        end
        if distance and (not target or distance < nearest) then
            target, nearest = actor, distance
        end
    end

    if target and target:IsValid() then
        local ok, err = pcall(function() target:OnInteraction(pawn) end)
        if ok and Config.NotifyHarvest then
            Log("Harvested nearby resource")
        end
    end
end

local function ScanLoop()
    local interval = Config.ScanIntervalMs
    if _G.PauseGuard_IsPaused then
        interval = 2000
    end
    ExecuteWithDelay(interval, function()
        ExecuteInGameThread(ScanLoop)
    end)
    if not _G.PauseGuard_IsPaused then
        local ok, err = pcall(HarvestNearby)
        if not ok then
            Log("Scan error: " .. tostring(err))
        end
    end
end

RegisterKeyBind(Config.ToggleKey, function()
    Config.Enabled = not Config.Enabled
    Log(Config.Enabled and "AutoHarvest: ENABLED" or "AutoHarvest: DISABLED")
end)

ExecuteInGameThread(function()
    for _, class in ipairs(RESOURCE_CLASSES) do
        for _, actor in ipairs(FindAllOf(class) or {}) do
            TrackResource(actor)
        end
    end
    Log("AutoHarvest loaded and active. Proximity: " .. Config.RadiusCm .. "cm. Toggle with [F11].")
    ScanLoop()
end)
