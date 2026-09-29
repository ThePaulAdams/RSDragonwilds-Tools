local UEHelpers = require("UEHelpers")

local ModName = "HotbarScroll"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end

-- Mouse wheel cycles the hotbar. The wheel is read from the player controller
-- every frame; nothing happens while a menu or the cursor is up.
local Config = {
    Invert = false,
    -- Wrap from the last slot back to the first.
    Wrap = true,
    DebugLog = true,
}

local function Valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:IsValid() and o:GetAddress() ~= 0 end)
    return ok and res
end

local WheelUp, WheelDown = nil, nil

local function Context()
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) or not Valid(pc.Pawn) then return nil end
    if pc.bShowMouseCursor then return nil end
    local inv = pc.BP_Components_Inventory
    local ctrl = nil
    pcall(function()
        ctrl = pc.InventoryController
        if not Valid(ctrl) and pc.GetInventoryController then ctrl = pc:GetInventoryController() end
    end)
    return pc, pc.Pawn, Valid(inv) and inv or nil, Valid(ctrl) and ctrl or nil
end

-- Reading the currently selected hotbar slot.
local SlotReaders = {
    { "Inventory.ActiveQuickActionSlot", function(pc, pawn, inv, ctrl) return inv.ActiveQuickActionSlot end },
    { "Inventory.SelectedQuickActionSlot", function(pc, pawn, inv, ctrl) return inv.SelectedQuickActionSlot end },
    { "Inventory:GetActiveQuickActionSlot()", function(pc, pawn, inv, ctrl) return inv:GetActiveQuickActionSlot() end },
    { "Inventory:GetSelectedQuickActionSlotIndex()", function(pc, pawn, inv, ctrl) return inv:GetSelectedQuickActionSlotIndex() end },
    { "InventoryController.ActiveQuickActionSlot", function(pc, pawn, inv, ctrl) return ctrl.ActiveQuickActionSlot end },
    { "InventoryController:GetActiveQuickActionSlot()", function(pc, pawn, inv, ctrl) return ctrl:GetActiveQuickActionSlot() end },
    { "Pawn.ActiveQuickActionSlot", function(pc, pawn, inv, ctrl) return pawn.ActiveQuickActionSlot end },
}
-- Selecting a hotbar slot (zero-based index).
local SlotSelectors = {
    { "InventoryController:SelectQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return ctrl:SelectQuickActionSlot(i) end },
    { "InventoryController:SetActiveQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return ctrl:SetActiveQuickActionSlot(i) end },
    { "InventoryController:ActivateQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return ctrl:ActivateQuickActionSlot(i) end },
    { "InventoryController:EquipQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return ctrl:EquipQuickActionSlot(i) end },
    { "Inventory:SetActiveQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return inv:SetActiveQuickActionSlot(i) end },
    { "Inventory:SelectQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return inv:SelectQuickActionSlot(i) end },
    { "Pawn:SelectQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return pawn:SelectQuickActionSlot(i) end },
    { "Pawn:EquipQuickActionSlot(i)", function(pc, pawn, inv, ctrl, i) return pawn:EquipQuickActionSlot(i) end },
}
local Reader, Selector = nil, nil
local OwnIndex = 0
local Disabled = false

local function ListMatching(obj, words)
    local names, seen = {}, {}
    pcall(function()
        local cls = obj:GetClass()
        while Valid(cls) do
            local function consider(n)
                local l = n:lower()
                for _, w in ipairs(words) do
                    if l:find(w, 1, true) and not seen[n] then seen[n] = true; names[#names + 1] = n; return end
                end
            end
            cls:ForEachFunction(function(fn) consider(fn:GetFName():ToString()) end)
            cls:ForEachProperty(function(p) consider(p:GetFName():ToString()) end)
            cls = cls:GetSuperStruct()
        end
    end)
    return names
end

local function Discover(pc, pawn, inv, ctrl)
    for label, obj in pairs({ PlayerController = pc, Pawn = pawn, Inventory = inv, InventoryController = ctrl }) do
        if Valid(obj) then
            local list = ListMatching(obj, { "quickaction", "quickaccess", "hotbar", "quickslot" })
            Log(string.format("[DISCOVERY] %s hotbar members: %s", label, #list > 0 and table.concat(list, ", ") or "(none)"))
        end
    end
end

local function CurrentIndex(pc, pawn, inv, ctrl)
    if Reader then
        local ok, v = pcall(Reader[2], pc, pawn, inv, ctrl)
        if ok and type(v) == "number" then return v end
    else
        for _, r in ipairs(SlotReaders) do
            local ok, v = pcall(r[2], pc, pawn, inv, ctrl)
            if ok and type(v) == "number" and v >= 0 and v < 32 then
                Reader = r
                Log("Reading the selected slot from " .. r[1])
                return v
            end
        end
    end
    return OwnIndex
end

local function Scroll(direction)
    local pc, pawn, inv, ctrl = Context()
    if not pc or not inv then return end
    local count = 8
    pcall(function() count = inv.NumberOfQuickActionSlots or 8 end)
    if count <= 0 then return end
    local nextIndex = CurrentIndex(pc, pawn, inv, ctrl) + direction
    if Config.Wrap then
        nextIndex = nextIndex % count
    else
        nextIndex = math.max(0, math.min(count - 1, nextIndex))
    end

    local candidates = Selector and { Selector } or SlotSelectors
    for _, s in ipairs(candidates) do
        local ok, err = pcall(s[2], pc, pawn, inv, ctrl, nextIndex)
        if ok then
            if not Selector then
                Selector = s
                Log("Selecting slots with " .. s[1])
            end
            OwnIndex = nextIndex
            return
        elseif Config.DebugLog and not Selector then
            Log(string.format("%s failed: %s", s[1], tostring(err)))
        end
    end
    Disabled = true
    Discover(pc, pawn, inv, ctrl)
    Log("No hotbar select function worked; wheel scrolling is off until reload. Send the DISCOVERY lines above to the toolkit author.")
end

local Busy, LastError = false, nil
LoopAsync(10, function()
    if Disabled or Busy then return false end
    Busy = true
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc = UEHelpers.GetPlayerController()
            if not Valid(pc) then return end
            WheelUp = WheelUp or { KeyName = FName("MouseScrollUp") }
            WheelDown = WheelDown or { KeyName = FName("MouseScrollDown") }
            local up = pc:WasInputKeyJustPressed(WheelUp)
            local down = pc:WasInputKeyJustPressed(WheelDown)
            if up ~= down then
                local dir = up and -1 or 1
                if Config.Invert then dir = -dir end
                Scroll(dir)
            end
        end)
        if not ok and tostring(err) ~= LastError then Log("Error: " .. tostring(err)) end
        LastError = (not ok) and tostring(err) or nil
        Busy = false
    end)
    return false
end)

Log("Ready: mouse wheel cycles hotbar slots (off while menus are open).")
