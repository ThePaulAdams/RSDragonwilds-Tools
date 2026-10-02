local UEHelpers = require("UEHelpers")

local ModName = "ToolkitProbe"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end

-- Developer helper. Ctrl+F12 writes the functions and properties of the
-- objects the toolkit needs to learn about (the open crafting station and its
-- inventory, your inventory, inventory controller, pawn, and whatever item you
-- are hovering) to probe_<time>.txt next to this script, plus a count of loaded
-- classes whose names mention recipes, crafting, stations, raids or beds
-- (only with Config.ClassHistogram = true).
-- Send that file to the toolkit author to finish features that need game names,
-- such as stopping stations from over-crafting leftovers.
local Config = {
    Key = Key.F12,
    Modifiers = { ModifierKey.CONTROL },
    ClassKeywords = { "recipe", "craft", "station", "queue", "raid", "warband", "bed", "respawn", "quickaction", "health" },
    -- Walks every loaded object; slow and crash-prone while the game streams, so off by default.
    ClassHistogram = false,
}

local function Valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:IsValid() and o:GetAddress() ~= 0 end)
    return ok and res
end

local ScriptDir = (debug.getinfo(1, "S").source or ""):match("^@(.*[/\\])") or ""

local function Describe(label, obj, out)
    if not Valid(obj) then
        out[#out + 1] = string.format("== %s: (not found)", label)
        return
    end
    local cls = obj:GetClass()
    out[#out + 1] = string.format("== %s: %s  [class %s]", label, obj:GetFullName(), cls:GetFName():ToString())
    local s = cls
    while Valid(s) do
        out[#out + 1] = "  -- " .. s:GetFName():ToString()
        pcall(function()
            s:ForEachProperty(function(p)
                local kind = ""
                pcall(function() kind = p:GetClass():GetFName():ToString() end)
                local value = ""
                pcall(function()
                    local v = obj[p:GetFName():ToString()]
                    local t = type(v)
                    if t == "number" or t == "boolean" or t == "string" then value = " = " .. tostring(v)
                    elseif t == "userdata" and v.ToString then value = " = " .. v:ToString()
                    elseif t == "userdata" and v.GetArrayNum then value = " (#" .. v:GetArrayNum() .. ")" end
                end)
                out[#out + 1] = string.format("     P %s : %s%s", p:GetFName():ToString(), kind, value)
            end)
        end)
        pcall(function()
            s:ForEachFunction(function(fn)
                out[#out + 1] = "     F " .. fn:GetFName():ToString()
            end)
        end)
        local ok, super = pcall(function() return s:GetSuperStruct() end)
        s = ok and super or nil
        if Valid(s) and s:GetFName():ToString() == "Object" then break end
    end
end

local function OpenStation(pc)
    for _, ui in ipairs(FindAllOf("ProcessingStationUIAPI") or {}) do
        local comp = nil
        pcall(function() comp = ui.ProcessingStationComponent end)
        if Valid(comp) then return comp:GetOwner(), comp end
    end
    for _, ui in ipairs(FindAllOf("CraftingUIAPI") or {}) do
        local comp = nil
        pcall(function() comp = ui.CurrentStation end)
        if Valid(comp) then return comp:GetOwner(), comp end
    end
    for _, ui in ipairs(FindAllOf("WorldActorInventoryUIAPI") or {}) do
        local comp, owner = nil, nil
        pcall(function() comp = ui:GetInventoryComponent() end)
        if Valid(comp) then pcall(function() owner = comp:GetOwner() end) end
        if Valid(owner) and owner ~= pc.Pawn then return owner, comp end
    end
end

local function HoveredItem()
    for _, slot in ipairs(FindAllOf("InventorySlotBase") or {}) do
        local ok, item = pcall(function()
            if slot:IsVisible() and (slot.bIsMousedOver or slot:IsHovered()) then return slot.ContainedItem end
        end)
        if ok and Valid(item) then return item end
    end
end

local function ClassHistogram(out)
    local counts, classWanted = {}, {}
    ForEachUObject(function(obj)
        local cls = nil
        pcall(function() cls = obj:GetClass() end)
        if not cls then return end
        local addr = cls:GetAddress()
        local name = classWanted[addr]
        if name == nil then
            name = false
            local n = ""
            pcall(function() n = cls:GetFName():ToString() end)
            local l = n:lower()
            for _, k in ipairs(Config.ClassKeywords) do
                if l:find(k, 1, true) then name = n; break end
            end
            classWanted[addr] = name
        end
        if name then counts[name] = (counts[name] or 0) + 1 end
    end)
    local rows = {}
    for n, c in pairs(counts) do rows[#rows + 1] = { n, c } end
    table.sort(rows, function(a, b) return a[1] < b[1] end)
    out[#out + 1] = "== Loaded classes matching keywords (instances incl. defaults):"
    for _, r in ipairs(rows) do out[#out + 1] = string.format("   %6d  %s", r[2], r[1]) end
end

local function Probe()
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) then return end
    local out = { "ToolkitProbe " .. os.date("%Y-%m-%d %H:%M:%S") }
    local station, stationInv = OpenStation(pc)
    Describe("Open station / container", station, out)
    Describe("Open station component / inventory", stationInv, out)
    Describe("Player inventory", pc.BP_Components_Inventory, out)
    local ctrl = nil
    pcall(function() ctrl = pc.InventoryController end)
    Describe("Inventory controller", ctrl, out)
    Describe("Pawn", pc.Pawn, out)
    local item = HoveredItem()
    Describe("Hovered item", item, out)
    if Valid(item) then pcall(function() Describe("Hovered item data", item.ItemData, out) end) end
    if Config.ClassHistogram then ClassHistogram(out) end

    local path = ScriptDir .. "probe_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
    local f = io.open(path, "w")
    if f then
        f:write(table.concat(out, "\n"), "\n")
        f:close()
        Log(string.format("Wrote %d lines to %s", #out, path))
    else
        for _, line in ipairs(out) do Log(line) end
    end
end

RegisterKeyBind(Config.Key, Config.Modifiers, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(Probe)
        if not ok then Log("Error: " .. tostring(err)) end
    end)
end)

Log("Ready: Ctrl+F12 writes a probe file (open a crafting station first for the most useful output).")
