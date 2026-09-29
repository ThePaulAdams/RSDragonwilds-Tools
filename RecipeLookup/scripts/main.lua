local UEHelpers = require("UEHelpers")

local ModName = "RecipeLookup"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end

-- Ctrl+J shows what you can make. At an open crafting station it lists that
-- station's recipes; elsewhere it lists every recipe. Ingredients are counted
-- from your backpack plus chests within 12 m (the game's own craft-from-chest range).
-- Press Ctrl+J again for the next page; Escape closes the list.
local Config = {
    Key = Key.J,
    Modifiers = { ModifierKey.CONTROL },
    ChestRadius = 1200.0,
    LinesPerPage = 10,
    HideAfterSeconds = 25,
    -- Words that identify recipe classes, ingredient lists, outputs and stations.
    RecipeClassWords = { "recipe" },
    IngredientWords = { "ingredient", "input", "cost", "require", "material", "component", "resource" },
    OutputWords = { "output", "result", "product", "crafted", "reward", "item" },
    StationWords = { "station", "bench", "crafter", "facility", "workshop", "building" },
    CountWords = { "count", "amount", "quantity", "num", "stack" },
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

local function HasWord(s, words)
    local l = s:lower()
    for _, w in ipairs(words) do
        if l:find(w, 1, true) then return true end
    end
    return false
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
-- Reflection helpers
-- =========================================================================
local function ForEachPropOf(structOrClass, fn)
    local s = structOrClass
    while Valid(s) do
        pcall(function() s:ForEachProperty(fn) end)
        local okSuper, super = pcall(function() return s:GetSuperStruct() end)
        s = okSuper and super or nil
    end
end

local function PropKind(prop)
    local k = ""
    pcall(function() k = prop:GetClass():GetFName():ToString() end)
    return k -- e.g. ArrayProperty, ObjectProperty, SoftObjectProperty, IntProperty, StructProperty
end

-- Resolves object / soft-object / weak values to a UObject.
local function AsObject(v)
    if v == nil then return nil end
    if Valid(v) then return v end
    for _, getter in ipairs({
        function() return v:get() end,
        function() return v:Get() end,
        function() return v:LoadSynchronous() end,
    }) do
        local ok, o = pcall(getter)
        if ok and Valid(o) then return o end
    end
    return nil
end

local function ItemDataName(data)
    for _, getter in ipairs({
        function() return data:GetPlayerFacingName():ToString() end,
        function() return data.Name:ToString() end,
        function() return data.ItemName:ToString() end,
        function() return data.DisplayName:ToString() end,
        function() return data.PlayerFacingName:ToString() end,
    }) do
        local ok, n = pcall(getter)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    local n = NameOf(data):gsub("^DA_", ""):gsub("^Item_", ""):gsub("^item_", ""):gsub("_", " ")
    return n
end

-- Reads one {item, count} struct generically.
local function ReadEntry(elem, structType)
    local item, count = nil, nil
    ForEachPropOf(structType, function(p)
        local n, kind = p:GetFName():ToString(), PropKind(p)
        local ok, v = pcall(function() return elem[n] end)
        if not ok then return end
        if not item and kind:find("Object") then item = AsObject(v) end
        if not count and (kind == "IntProperty" or kind == "FloatProperty" or kind == "ByteProperty")
            and HasWord(n, Config.CountWords) then count = tonumber(v) end
    end)
    return item, count or 1
end

-- =========================================================================
-- Recipe discovery
-- =========================================================================
local Recipes = nil -- list of { Name, Output, Ingredients = { {Data, Name, Count} }, Station }

local function ParseRecipe(obj)
    local recipe = { Ingredients = {}, Station = "" }
    local cls = obj:GetClass()
    ForEachPropOf(cls, function(p)
        local n, kind = p:GetFName():ToString(), PropKind(p)
        local ok, v = pcall(function() return obj[n] end)
        if not ok or v == nil then return end

        if kind == "ArrayProperty" then
            local inner, innerKind, structType = nil, "", nil
            pcall(function() inner = p:GetInner() end)
            if inner then
                innerKind = PropKind(inner)
                if innerKind == "StructProperty" then pcall(function() structType = inner:GetStruct() end) end
            end
            local isIngredients = HasWord(n, Config.IngredientWords)
            local isOutput = HasWord(n, Config.OutputWords) and not isIngredients
            if (isIngredients or isOutput) and structType then
                pcall(function()
                    v:ForEach(function(_, e)
                        local item, count = ReadEntry(e:get(), structType)
                        if item then
                            if isIngredients then
                                recipe.Ingredients[#recipe.Ingredients + 1] = { Data = item, Name = ItemDataName(item), Count = count }
                            elseif not recipe.Output then
                                recipe.Output = item
                            end
                        end
                    end)
                end)
            elseif HasWord(n, Config.StationWords) then
                pcall(function()
                    v:ForEach(function(_, e)
                        local x = e:get()
                        local o = AsObject(x)
                        local s = o and NameOf(o) or ""
                        if s == "" then pcall(function() s = x.TagName:ToString() end) end
                        recipe.Station = recipe.Station .. " " .. s
                    end)
                end)
            end
        elseif kind:find("Object") or kind == "ClassProperty" then
            if HasWord(n, Config.StationWords) then
                local o = AsObject(v)
                if o then recipe.Station = recipe.Station .. " " .. NameOf(o) end
            elseif not recipe.Output and HasWord(n, Config.OutputWords) then
                recipe.Output = AsObject(v)
            end
        elseif kind == "StructProperty" then
            if HasWord(n, Config.StationWords) then
                pcall(function() recipe.Station = recipe.Station .. " " .. v.TagName:ToString() end)
            elseif not recipe.Output and HasWord(n, Config.OutputWords) then
                local structType = nil
                pcall(function() structType = p:GetStruct() end)
                if structType then recipe.Output = ReadEntry(v, structType) end
            end
        end
    end)
    if #recipe.Ingredients == 0 then return nil end
    recipe.Name = recipe.Output and ItemDataName(recipe.Output)
        or NameOf(obj):gsub("^DA_", ""):gsub("^Recipe_", ""):gsub("_", " ")
    recipe.Station = recipe.Station:lower()
    return recipe
end

local function BuildRecipes()
    Recipes = {}
    local classMatch, candidates, classCounts = {}, {}, {}
    ForEachUObject(function(obj)
        local cls = nil
        pcall(function() cls = obj:GetClass() end)
        if not cls then return end
        local addr = cls:GetAddress()
        local m = classMatch[addr]
        if m == nil then
            m = HasWord(NameOf(cls), Config.RecipeClassWords)
            classMatch[addr] = m
        end
        if m then
            local isTemplate = true
            pcall(function()
                isTemplate = obj:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject)
            end)
            if not isTemplate then
                candidates[#candidates + 1] = obj
                local cn = NameOf(cls)
                classCounts[cn] = (classCounts[cn] or 0) + 1
            end
        end
    end)
    local summary = {}
    for cn, c in pairs(classCounts) do summary[#summary + 1] = cn .. "=" .. c end
    Log("[DISCOVERY] Recipe-like classes loaded: " .. (#summary > 0 and table.concat(summary, ", ") or "(none)"))

    for _, obj in ipairs(candidates) do
        local ok, r = pcall(ParseRecipe, obj)
        if ok and r then Recipes[#Recipes + 1] = r end
    end
    Log(string.format("Parsed %d recipe(s) with ingredients from %d candidate object(s).", #Recipes, #candidates))
    if #Recipes == 0 and #candidates > 0 then
        -- Show the shape of one candidate so the parser can be taught its field names.
        local sample, fields = candidates[1], {}
        ForEachPropOf(sample:GetClass(), function(p) fields[#fields + 1] = p:GetFName():ToString() .. ":" .. PropKind(p) end)
        Log("[DISCOVERY] " .. NameOf(sample) .. " fields: " .. table.concat(fields, ", "))
    end
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

local function OpenStationName()
    for _, ui in ipairs(FindAllOf("WorldActorInventoryUIAPI") or {}) do
        local owner = nil
        pcall(function() owner = ui:GetInventoryComponent():GetOwner() end)
        if Valid(owner) then
            local cn = ClassNameOf(owner)
            local l = cn:lower()
            if not (l:find("chest") or l:find("crate") or l:find("storage")) then return cn end
        end
    end
    return nil
end

-- A recipe belongs to a station when a distinctive word of its station field
-- appears in the station's class name (e.g. "Furnace" in BP_BaseBuilding_Furnace_C).
local function RecipeFitsStation(recipe, stationClass)
    if recipe.Station == "" then return false end
    local cls = stationClass:lower()
    for word in recipe.Station:gmatch("[%a]+") do
        if #word >= 4 and word ~= "station" and word ~= "crafting" and word ~= "base" and word ~= "building"
            and cls:find(word, 1, true) then
            return true
        end
    end
    return false
end

-- =========================================================================
-- Show
-- =========================================================================
local function RenderPage()
    local total = math.max(1, math.ceil(#Panel.Lines / Config.LinesPerPage))
    if Panel.Page > total then Panel.Page = 1 end
    local first = (Panel.Page - 1) * Config.LinesPerPage + 1
    local out = { string.format("%s   (page %d/%d, Ctrl+J next, Esc close)", Panel.Title, Panel.Page, total) }
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

    if not Recipes then
        PanelText("Indexing recipes...")
        BuildRecipes()
    end
    if #Recipes == 0 then
        PanelText("Recipe data not found. Press Ctrl+F12 (ToolkitProbe) at a station and send the log to the toolkit author.")
        return
    end

    local station = OpenStationName()
    local list = {}
    for _, r in ipairs(Recipes) do
        if not station or RecipeFitsStation(r, station) then list[#list + 1] = r end
    end
    if station and #list == 0 then
        Log("No recipes matched station " .. station .. "; showing all.")
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

Log("Ready: Ctrl+J lists recipes and what you can craft (station recipes when a station is open).")
