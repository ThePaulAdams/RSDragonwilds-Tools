local UEHelpers = require("UEHelpers")

local ModName = "BulkOpen"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end

-- Opens every bag/pack in the backpack with one key press, one item at a time,
-- using whichever "use item" function the game accepts. The first function that
-- actually shrinks a pack stack is remembered for the rest of the session.
local Config = {
    Key = Key.F11,
    Modifiers = { ModifierKey.SHIFT },
    -- Milliseconds between opens. The game may ignore uses that arrive faster
    -- than its own open animation/cooldown.
    OpenIntervalMs = 250,
    -- Give up after this many attempts that did not shrink any pack.
    MaxFailedAttempts = 6,
    -- An item counts as a bag when its data class is one of these (the object dump
    -- shows every pack, e.g. ITEM_Consumable_GoblinPack, as BP_Consumables_ItemEmitter_C)...
    DataClasses = { "BP_Consumables_ItemEmitter_C" },
    -- ...or its asset path contains one of these...
    PathPatterns = { "consumable_goblinpack", "lootbag", "loot_bag" },
    -- ...or its display name ends with one of these words.
    NameSuffixes = { " pack", " bag", " sack", " pouch" },
    -- Never open these, even when a pattern above matches.
    Exclude = { "backpack", "rune pouch", "seed", "tea bag", "quiver" },
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
LoopAsync(100, function()
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
-- Inventory helpers
-- =========================================================================
local function ItemName(item)
    local name = ""
    pcall(function() name = item:GetPlayerFacingName():ToString() end)
    return name or ""
end

-- "ClassName /Game/Path/Asset.Asset" of the item's data asset.
local function ItemPath(item)
    local path = ""
    pcall(function() path = item.ItemData:GetFullName() end)
    return path or ""
end

local function DataClass(item)
    local cls = ""
    pcall(function() cls = item.ItemData:GetClass():GetFName():ToString() end)
    return cls or ""
end

local function IsBag(item)
    local name, path = ItemName(item):lower(), ItemPath(item):lower()
    for _, word in ipairs(Config.Exclude) do
        if name:find(word, 1, true) or path:find((word:gsub(" ", "_")), 1, true) then return false end
    end
    local cls = DataClass(item)
    for _, c in ipairs(Config.DataClasses) do
        if cls == c then return true end
    end
    for _, pat in ipairs(Config.PathPatterns) do
        if path:find(pat, 1, true) then return true end
    end
    for _, suffix in ipairs(Config.NameSuffixes) do
        if name:sub(-#suffix) == suffix then return true end
    end
    return false
end

local function Context()
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) or not Valid(pc.Pawn) then return nil end
    local inv = pc.BP_Components_Inventory
    if not Valid(inv) then return nil end
    local ctrl = nil
    pcall(function()
        ctrl = pc.InventoryController
        if not Valid(ctrl) and pc.GetInventoryController then ctrl = pc:GetInventoryController() end
    end)
    return pc, pc.Pawn, inv, Valid(ctrl) and ctrl or nil
end

-- Returns { {Slot=zeroBased, Item=item, Count=n, Name=s}, ... } and the total count.
local function FindBags(inv)
    local bags, total = {}, 0
    local slots = 0
    pcall(function() slots = inv.ItemSlots:GetArrayNum() end)
    for i = 1, slots do
        local item = nil
        pcall(function() item = inv.ItemSlots[i] end)
        if Valid(item) and IsBag(item) then
            local count = 1
            pcall(function() count = item:GetStackSize() end)
            bags[#bags + 1] = { Slot = i - 1, Item = item, Count = count, Name = ItemName(item) }
            total = total + count
        end
    end
    return bags, total
end

-- Every candidate is a function that tries one way of using the item in a slot.
-- They are attempted in order until one shrinks the pack count. Names come from
-- the game's object dump: InventoryController:UseItemFromInventory(Inventory, SlotIndex)
-- and UsableItemInterface:UseItem(PlayerController, Inventory, SlotIndex).
local Methods = {
    { "InventoryController:UseItemFromInventory(inv, slot)", function(pc, pawn, inv, ctrl, bag) return ctrl:UseItemFromInventory(inv, bag.Slot) end },
    { "Item:UseItem(pc, inv, slot)", function(pc, pawn, inv, ctrl, bag) return bag.Item:UseItem(pc, inv, bag.Slot) end },
}

-- Logs every function whose name looks like "use/consume/open" on the objects
-- involved, once, so a failed run tells us exactly what to call instead.
local Discovered = false
local function ListFunctions(obj, pattern)
    local names, seen = {}, {}
    pcall(function()
        local cls = obj:GetClass()
        while Valid(cls) do
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if not seen[n] and n:lower():find(pattern) then
                    seen[n] = true
                    names[#names + 1] = n
                end
            end)
            cls = cls:GetSuperStruct()
        end
    end)
    return names
end
local function Discover(inv, ctrl, bag)
    if Discovered then return end
    Discovered = true
    for label, obj in pairs({ InventoryController = ctrl, Inventory = inv, Item = bag and bag.Item }) do
        if Valid(obj) then
            local list = {}
            for _, p in ipairs({ "use", "consume", "open", "activate" }) do
                for _, n in ipairs(ListFunctions(obj, p)) do list[#list + 1] = n end
            end
            Log(string.format("[DISCOVERY] %s (%s) functions: %s", label, obj:GetClass():GetFName():ToString(),
                #list > 0 and table.concat(list, ", ") or "(none)"))
        end
    end
end

-- =========================================================================
-- Opening loop
-- =========================================================================
local Run = { Active = false, MethodIndex = nil, TryIndex = 1, Failures = 0, Opened = 0, LastTotal = 0, Busy = false }
local LockedMethod = nil -- index into Methods that worked earlier this session

local function Finish(reason)
    Run.Active = false
    Log(string.format("Done (%s). Opened %d bag(s).", reason, Run.Opened))
    if Run.Opened > 0 then
        Toast.Show(string.format("Opened %d bag%s", Run.Opened, Run.Opened == 1 and "" or "s"), 3)
    elseif reason ~= "no bags" then
        Toast.Show("Could not open bags (see UE4SS log)", 4)
    end
end

local function Step()
    local pc, pawn, inv, ctrl = Context()
    if not pc then return Finish("player not ready") end
    local bags, total = FindBags(inv)

    -- Judge the previous attempt by whether the pack count went down.
    if Run.MethodIndex then
        if total < Run.LastTotal then
            Run.Opened = Run.Opened + (Run.LastTotal - total)
            Run.Failures = 0
            if LockedMethod ~= Run.MethodIndex then
                LockedMethod = Run.MethodIndex
                Log("Using " .. Methods[LockedMethod][1])
            end
        else
            Run.Failures = Run.Failures + 1
            if not LockedMethod then Run.TryIndex = Run.TryIndex + 1 end
        end
    end

    if total == 0 then return Finish(Run.Opened > 0 and "all bags opened" or "no bags") end
    if Run.Failures >= Config.MaxFailedAttempts and LockedMethod then return Finish("bags stopped opening") end
    if not LockedMethod and Run.TryIndex > #Methods then
        Discover(inv, ctrl, bags[1])
        return Finish("no known use function worked")
    end

    local index = LockedMethod or Run.TryIndex
    local method = Methods[index]
    local ok, err = pcall(method[2], pc, pawn, inv, ctrl, bags[1])
    if Config.DebugLog and not LockedMethod then
        Log(string.format("Trying %s on '%s' -> %s", method[1], bags[1].Name, ok and "called" or tostring(err)))
    end
    if not ok and not LockedMethod then
        -- The call itself failed, so it cannot have opened anything; move on immediately.
        Run.MethodIndex = nil
        Run.TryIndex = Run.TryIndex + 1
        Run.LastTotal = total
        return
    end
    Run.MethodIndex = index
    Run.LastTotal = total
end

local function Start()
    if Run.Active then
        Finish("cancelled")
        return
    end
    local pc, _, inv = Context()
    if not pc then return end
    local bags, total = FindBags(inv)
    if total == 0 then
        Toast.Show("No bags to open", 2)
        return
    end
    Log(string.format("Opening %d bag(s) across %d stack(s)...", total, #bags))
    Run = { Active = true, MethodIndex = nil, TryIndex = 1, Failures = 0, Opened = 0, LastTotal = total, Busy = false }
end

LoopAsync(Config.OpenIntervalMs, function()
    if not Run.Active or Run.Busy then return false end
    Run.Busy = true
    ExecuteInGameThread(function()
        local ok, err = pcall(Step)
        if not ok then
            Log("Error: " .. tostring(err))
            Run.Active = false
        end
        Run.Busy = false
    end)
    return false
end)

do
    RegisterKeyBind(Config.Key, Config.Modifiers, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(Start)
            if not ok then Log("Error: " .. tostring(err)) end
        end)
    end)
end

Log("Ready: Shift+F11 opens every bag/pack in your backpack (press again to stop).")
