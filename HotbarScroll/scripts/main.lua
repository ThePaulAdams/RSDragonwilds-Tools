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

-- The game has no "selected slot" index. The hotbar is the first
-- NumberOfQuickActionSlots slots of the backpack, and the number keys *use*
-- the item in a slot (which equips it). So the current slot is the one whose
-- item is held in the right hand.
local SlotReaders = {
    { "held item vs hotbar slots", function(pc, pawn, inv, ctrl)
        local held = pawn.PlayerEquipmentComponent:GetHeldEquipmentDataRight()
        if not Valid(held) then return nil end
        local addr = held:GetAddress()
        local count = inv.NumberOfQuickActionSlots
        for i = 1, count do
            local item = inv.ItemSlots[i]
            if Valid(item) and Valid(item.ItemData) and item.ItemData:GetAddress() == addr then return i - 1 end
        end
        return nil
    end },
}
-- Selecting a hotbar slot (zero-based index), as the number keys do.
local SlotSelectors = {
    { "QuickAccessBar:UseItemInSlot(i)", function(pc, pawn, inv, ctrl, i)
        local bar = FindFirstOf("WBP_Inventory_QuickAccesBar_C")
        if not Valid(bar) then error("quick access bar widget not found") end
        return bar:UseItemInSlot(i)
    end },
    { "InventoryController:UseItemFromInventory(inv, i)", function(pc, pawn, inv, ctrl, i) return ctrl:UseItemFromInventory(inv, i) end },
}

-- Hotbar slots that hold something (zero-based); empty slots are skipped while scrolling.
local function FilledSlots(inv, count)
    local filled = {}
    for i = 1, count do
        local item = nil
        pcall(function() item = inv.ItemSlots[i] end)
        if Valid(item) then filled[#filled + 1] = i - 1 end
    end
    return filled
end
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
    local filled = FilledSlots(inv, count)
    if #filled == 0 then return end
    -- Step to the next filled slot after (or before) the current one.
    local current = CurrentIndex(pc, pawn, inv, ctrl)
    local pos = nil
    for k, s in ipairs(filled) do
        if direction > 0 and s > current then pos = k; break end
        if direction < 0 and s < current then pos = k end
    end
    if not pos then
        if not Config.Wrap then return end
        pos = direction > 0 and 1 or #filled
    end
    local nextIndex = filled[pos]
    if nextIndex == current then return end

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

local Busy, LastError, LastScroll = false, nil, 0
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
            -- WasInputKeyJustPressed is frame-latched; 50 ms debounce stops one notch counting twice.
            if up ~= down and os.clock() - LastScroll > 0.05 then
                LastScroll = os.clock()
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
