local UEHelpers = require("UEHelpers")

local ModName = "RecipeLookup"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end

-- Alt+F12 shows what you can make. At an open crafting station it lists that
-- station's recipes; elsewhere it lists every recipe. Ingredients are counted
-- from your backpack plus chests within 12 m (the game's own craft-from-chest range).
-- Press Alt+F12 again for the next page; Escape closes the list.
--
-- Recipe data comes straight from the game's RecipeData assets
-- (/Script/Dominion.RecipeData: ItemsConsumed / ItemsCreated arrays of
-- ItemDataContainer { ItemData, Count }). No full object scan is done.
local Config = {
    Key = Key.F12,
    Modifiers = { ModifierKey.ALT },
    ChestRadius = 1200.0,
    LinesPerPage = 10,
    HideAfterSeconds = 25,
    ChestClasses = {
        "BP_BaseBuilding_Chest_C", "BP_BaseBuilding_Chest_Small_C",
        "BP_BaseBuilding_Crate_C", "BP_BaseBuilding_LumberStorage_C",
    },
}

local function Valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:IsValid() and o:GetAddress() ~= 0 end)
    return ok and res
end

local function NameOf(o)
    local n = ""
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

local function ClassNameOf(o)
    local n = ""
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

-- =========================================================================
-- Panel (a game tab-button widget used as a multi-line text box)
-- =========================================================================
local PANEL_CLASS = "/Game/UI/Common/WBP_MainMenuTabButton.WBP_MainMenuTabButton_C"
local Panel = { Widget = nil, HideTick = 0, Tick = 0, Lines = {}, Page = 1, Title = "" }
do
    local recorded = nil
    if ModRef then pcall(function() recorded = ModRef:GetSharedVariable(ModName .. ".Panel") end) end
    if type(recorded) == "string" and recorded ~= "" then
        ExecuteInGameThread(function()
            for _, w in ipairs(FindAllOf("WBP_MainMenuTabButton_C") or {}) do
                if Valid(w) and w:GetFullName() == recorded then pcall(function() w:RemoveFromParent() end) end
            end
        end)
    end
end

local function PanelText(text)
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) then return end
    if not Valid(Panel.Widget) then
        local cls = StaticFindObject(PANEL_CLASS)
        if not Valid(cls) and LoadAsset then
            pcall(function() LoadAsset(PANEL_CLASS) end)
            cls = StaticFindObject(PANEL_CLASS)
        end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if not Valid(cls) or not Valid(lib) then
            Log(text)
            return
        end
        Panel.Widget = lib:Create(pc, cls, pc)
        if not Valid(Panel.Widget) then return end
        Panel.Widget:SetIsFocusable(false)
        Panel.Widget:AddToViewport(10040)
        if ModRef then ModRef:SetSharedVariable(ModName .. ".Panel", Panel.Widget:GetFullName()) end
    end
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local size, dpi = layout:GetViewportSize(pc), layout:GetViewportScale(pc)
    local h = 60 + Config.LinesPerPage * 2 * 30
    Panel.Widget:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
    Panel.Widget:SetAnchorsInViewport({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    Panel.Widget:SetPositionInViewport({ X = 60, Y = math.max(40, size.Y / dpi / 2 - h / 2) }, false)
    Panel.Widget:SetDesiredSizeInViewport({ X = 760, Y = h })
    local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    local label = Valid(Panel.Widget.LabelText) and Panel.Widget.LabelText or Panel.Widget
    label:SetText(lib:Conv_StringToText(text))
    Panel.Widget:SetVisibility(3)
    Panel.HideTick = Panel.Tick + Config.HideAfterSeconds * 10
end

local function HidePanel()
    Panel.HideTick = 0
    if Valid(Panel.Widget) then pcall(function() Panel.Widget:SetVisibility(1) end) end
end

LoopAsync(100, function()
    Panel.Tick = Panel.Tick + 1
    if Panel.HideTick > 0 and Panel.Tick >= Panel.HideTick then ExecuteInGameThread(HidePanel) end
    return false
end)


-- =========================================================================
-- Recipe data (RecipeData assets)
-- =========================================================================
local function ItemDataName(data)
    -- ItemData.Name is the player-facing FText (per the object dump).
    for _, getter in ipairs({
        function() return data.Name:ToString() end,
        function() return data:GetName():ToString() end,
    }) do
        local ok, n = pcall(getter)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    local n = NameOf(data):gsub("^DA_", ""):gsub("^Item_", ""):gsub("^item_", ""):gsub("_", " ")
    return n
end

-- Reads a TArray<ItemDataContainer> into { {Data, Name, Count} }.
local function ReadContainers(arr)
    local out = {}
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    for i = 1, n do
        pcall(function()
            local e = arr[i]
            local data = e.ItemData
            if Valid(data) then
                local count = tonumber(e.Count) or 1
                out[#out + 1] = { Data = data, Name = ItemDataName(data), Count = math.max(1, count) }
            end
        end)
    end
    return out
end

local Recipes = nil       -- list of { Address, Name, Ingredients = { {Data, Name, Count} } }

local function ParseRecipe(obj)
    local ingredients = ReadContainers(obj.ItemsConsumed)
    if #ingredients == 0 then return nil end
    local outputs = ReadContainers(obj.ItemsCreated)
    local name = outputs[1] and outputs[1].Name
        or NameOf(obj):gsub("^DA_", ""):gsub("^Recipe_", ""):gsub("_", " ")
    if outputs[1] and outputs[1].Count > 1 then name = string.format("%s x%d", name, outputs[1].Count) end
    return { Address = obj:GetAddress(), Name = name, Ingredients = ingredients }
end

local function BuildRecipes()
    Recipes = {}
    local all = FindAllOf("RecipeData") or {}
    local seen = {}
    for _, obj in ipairs(all) do
        if Valid(obj) then
            local addr = obj:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                local ok, r = pcall(ParseRecipe, obj)
                if ok and r then Recipes[#Recipes + 1] = r end
            end
        end
    end
    Log(string.format("Parsed %d recipe(s) with ingredients from %d RecipeData object(s).", #Recipes, #all))
end

-- =========================================================================
-- Open station (processing stations like the furnace, crafting benches)
-- =========================================================================
local function StationDistanceOk(comp, here)
    local ok = true
    pcall(function()
        local loc = comp:GetOwner():K2_GetActorLocation()
        local dx, dy, dz = loc.X - here.X, loc.Y - here.Y, loc.Z - here.Z
        ok = dx * dx + dy * dy + dz * dz <= 1000.0 * 1000.0
    end)
    return ok
end

local function RecipeSet(arr)
    local set, n = {}, 0
    pcall(function()
        local count = arr:GetArrayNum()
        for i = 1, count do
            local r = arr[i]
            if Valid(r) then set[r:GetAddress()] = true; n = n + 1 end
        end
    end)
    return set, n
end

-- Returns stationName, { [recipeAddress] = true } for the station whose menu is open.
local function OpenStationRecipes(pc)
    local here = pc.Pawn:K2_GetActorLocation()
    for _, ui in ipairs(FindAllOf("ProcessingStationUIAPI") or {}) do
        local comp = nil
        pcall(function() comp = ui.ProcessingStationComponent end)
        if Valid(comp) and StationDistanceOk(comp, here) then
            local set, n = RecipeSet(comp.RecipesCache)
            if n > 0 then return ClassNameOf(comp:GetOwner()), set end
        end
    end
    for _, ui in ipairs(FindAllOf("CraftingUIAPI") or {}) do
        local comp = nil
        pcall(function() comp = ui.CurrentStation end)
        if Valid(comp) and StationDistanceOk(comp, here) then
            local set, n = RecipeSet(comp.ValidRecipes)
            if n > 0 then return ClassNameOf(comp:GetOwner()), set end
        end
    end
    return nil, nil
end

-- =========================================================================
-- Availability (backpack + chests in range)
-- =========================================================================
local function AddInventory(counts, inv)
    local n = 0
    pcall(function() n = inv.ItemSlots:GetArrayNum() end)
    for i = 1, n do
        pcall(function()
            local item = inv.ItemSlots[i]
            if Valid(item) and Valid(item.ItemData) then
                local a = item.ItemData:GetAddress()
                counts[a] = (counts[a] or 0) + (item:GetStackSize() or 1)
            end
        end)
    end
end

local function Availability(pc)
    local counts = {}
    if Valid(pc.BP_Components_Inventory) then AddInventory(counts, pc.BP_Components_Inventory) end
    local here = pc.Pawn:K2_GetActorLocation()
    local r2 = Config.ChestRadius * Config.ChestRadius
    for _, cls in ipairs(Config.ChestClasses) do
        for _, chest in ipairs(FindAllOf(cls) or {}) do
            pcall(function()
                local loc = chest:K2_GetActorLocation()
                local dx, dy, dz = loc.X - here.X, loc.Y - here.Y, loc.Z - here.Z
                if dx * dx + dy * dy + dz * dz <= r2 then
                    local inv = chest.BP_Components_WorldItemInventory
                    if not Valid(inv) then inv = chest.Inventory end
                    if Valid(inv) then AddInventory(counts, inv) end
                end
            end)
        end
    end
    return counts
end

local function RenderPage()
    local total = math.max(1, math.ceil(#Panel.Lines / Config.LinesPerPage))
    if Panel.Page > total then Panel.Page = 1 end
    local first = (Panel.Page - 1) * Config.LinesPerPage + 1
    local out = { string.format("%s   (page %d/%d, Alt+F12 next, Esc close)", Panel.Title, Panel.Page, total) }
    for i = first, math.min(#Panel.Lines, first + Config.LinesPerPage - 1) do out[#out + 1] = Panel.Lines[i] end
    PanelText(table.concat(out, "\n"))
end

local function Show()
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) or not Valid(pc.Pawn) then return end

    -- A second press while the list is up turns the page.
    if Panel.HideTick > 0 and #Panel.Lines > 0 then
        Panel.Page = Panel.Page + 1
        RenderPage()
        return
    end

    if not Recipes or #Recipes == 0 then
        PanelText("Indexing recipes...")
        BuildRecipes()
    end
    if #Recipes == 0 then
        PanelText("Recipe data not found (no RecipeData loaded yet). Try again once in your world.")
        return
    end

    local station, stationSet = OpenStationRecipes(pc)
    local list = {}
    for _, r in ipairs(Recipes) do
        if not stationSet or stationSet[r.Address] then list[#list + 1] = r end
    end
    if station and #list == 0 then
        Log("[DISCOVERY] No parsed recipes matched station " .. station .. "; showing all.")
        list = Recipes
    end

    local have = Availability(pc)
    local rows = {}
    for _, r in ipairs(list) do
        local ready, parts = true, {}
        for _, ing in ipairs(r.Ingredients) do
            local n = have[ing.Data:GetAddress()] or 0
            if n < ing.Count then ready = false end
            parts[#parts + 1] = string.format("%s %d/%d", ing.Name, n, ing.Count)
        end
        rows[#rows + 1] = { Ready = ready, Name = r.Name, Text = table.concat(parts, ", ") }
    end
    table.sort(rows, function(a, b)
        if a.Ready ~= b.Ready then return a.Ready end
        return a.Name < b.Name
    end)

    Panel.Lines = {}
    local readyCount = 0
    for _, row in ipairs(rows) do
        if row.Ready then readyCount = readyCount + 1 end
        Panel.Lines[#Panel.Lines + 1] = string.format("%s %s:  %s", row.Ready and "[READY]" or "[ -- ]", row.Name, row.Text)
    end
    Panel.Title = string.format("%s: %d of %d craftable", station and station:gsub("^BP_", ""):gsub("_C$", "") or "All recipes",
        readyCount, #rows)
    Panel.Page = 1
    RenderPage()
end

RegisterKeyBind(Config.Key, Config.Modifiers, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(Show)
        if not ok then Log("Error: " .. tostring(err)) end
    end)
end)
if Key.ESCAPE then
    RegisterKeyBind(Key.ESCAPE, function() ExecuteInGameThread(HidePanel) end)
end

Log("Ready: Alt+F12 lists recipes and what you can craft (station recipes when a station is open).")
