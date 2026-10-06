-- Custom Builds (single-player)
--
-- Place any model from the model viewer export in the world. N opens a model browser
-- (categories + picture tiles made of the game's own widgets); the picked model then
-- follows the crosshair as a see-through ghost and a left click places it as the mod's
-- own static prop. Placed models are saved in placed.txt and restored on load; no game
-- building piece is involved (a Lua mod cannot safely create build pieces in this game).
-- Keys and files: see README.md.
--
-- Safety rules this file follows (each learned from a crash):
--   * every object is checked with Valid() before any call on it;
--   * timers use the remembered player controller only and stop when the world changes
--     (scanning objects while a world is torn down returns freed objects);
--   * props are fully set up before they finish spawning;
--   * install new versions only while the game is closed (hot reload can hang UE4SS).
--
-- Console (F10): cb (list), cb <n> (pick), cb off, cb find <words>, cb undo, cb ui,
-- cb import, cb restore, cb probe, cb menuprobe, cb spawn <n> / cb clear (test props).

local UEHelpers = require("UEHelpers")

local ModName = "CustomBuilds"
local function Log(msg) print(string.format("[%s] %s\n", ModName, tostring(msg))) end
LastConsoleOut = nil
function Say(msg)
    Log(msg)
    if LastConsoleOut then
        pcall(function() LastConsoleOut:Log(ModName .. ": " .. tostring(msg)) end)
    end
end

local Config = {
    ZOffset = 0.0,          -- raise (+) or lower (-) models relative to the placed piece, in cm
    PlaceDistance = 2500.0, -- how far away (cm) the crosshair can place a model
    BarrelAnchor = false,    -- old method: models on top of a placed barrel (kept for old saves)
    -- The small decoration placed under each model (its data asset name). The model
    -- browser selects it for you; the wood barrel is cheap and hidden by most models.
    BasePiece = "BUILDPIECE_DA_BaseBuilding_Decoration_General_Wood_Barrel_01",
}

-- The working folder differs between setups, so look for models.txt in a few places.
local ModDir = nil
do
    local dirs = {}
    pcall(function()
        local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])[Ss]cripts[/\\]")
        if dir then dirs[#dirs + 1] = dir end
    end)
    -- Relative to the game's Binaries\Win64 folder, for both UE4SS folder layouts.
    for _, d in ipairs({ "ue4ss/Mods/CustomBuilds/", "Mods/CustomBuilds/", "../Mods/CustomBuilds/" }) do
        dirs[#dirs + 1] = d
    end
    for _, d in ipairs(dirs) do
        local f = io.open(d .. "models.txt", "r")
        if f then f:close(); ModDir = d; break end
    end
    ModDir = ModDir or dirs[#dirs]
end

-- =========================================================================
-- Helpers
-- =========================================================================
local function Valid(o)
    if not o then return false end
    local ok, res = pcall(function() return o:IsValid() and o:GetAddress() ~= 0 end)
    return ok and res
end

-- Both check Valid first: calling a method on an empty object reference crashes the
-- game inside UE4SS, and pcall cannot catch that.
local function NameOf(o)
    local n = ""
    if not Valid(o) then return n end
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

local function ClassName(o)
    local n = ""
    if not Valid(o) then return n end
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function Get(p)
    if type(p) == "userdata" or type(p) == "table" then
        local ok, v = pcall(function() return p:get() end)
        if ok and v ~= nil then return v end
    end
    return p
end

-- World tracking. Leaving a world (main menu, loading another save) destroys every
-- actor the mod holds; calling anything on those crashes the game. So every delayed
-- job checks it is still in the world it was scheduled in, and a world change makes
-- the mod drop all its references without touching them.
local OnWorldChange = {}   -- functions that drop references
local LastWorld = nil

-- The local player controller, remembered when the player (re)spawns. Timers use only
-- this reference and never scan the game's objects: while a world is being torn down
-- a scan can return objects that are already freed, and touching those crashes.
local MyPC = nil

-- For user actions (keys, clicks, console): the remembered one, else look it up.
local function GetPC()
    if Valid(MyPC) then return MyPC end
    local pc = UEHelpers.GetPlayerController()
    if Valid(pc) then MyPC = pc end
    return pc
end

local GameplayStatics = nil
local LastPauseCheckTime = 0
local LastPauseState = false
local function IsGamePaused(pc)
    if not Valid(pc) then return false end
    local now = os.clock()
    if now - LastPauseCheckTime < 0.25 then
        return LastPauseState
    end
    LastPauseCheckTime = now

    local ok1, paused = pcall(function() return pc:IsPaused() end)
    if ok1 and paused then
        LastPauseState = true
        return true
    end

    if not Valid(GameplayStatics) then
        GameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    if Valid(GameplayStatics) then
        local ok2, gPaused = pcall(function() return GameplayStatics:IsGamePaused(pc) end)
        if ok2 and gPaused then
            LastPauseState = true
            return true
        end
    end
    LastPauseState = false
    return false
end

local function WorldKey()
    local key = nil
    pcall(function()
        local pc = MyPC
        if Valid(pc) then
            local w = pc:GetWorld()
            if Valid(w) then key = w:GetAddress() end
        end
    end)
    return key
end

local function CheckWorld()
    local key = WorldKey()
    if key ~= LastWorld then
        LastWorld = key
        for _, f in ipairs(OnWorldChange) do pcall(f) end
    end
    return key
end

-- Runs fn on the game thread after ms, only if still in the same world.
local function Later(ms, fn)
    local key = WorldKey()
    local function run()
        if key == nil or CheckWorld() ~= key then return end
        fn()
    end
    if ExecuteInGameThreadWithDelay then
        ExecuteInGameThreadWithDelay(ms, run)
    elseif ExecuteWithDelay then
        ExecuteWithDelay(ms, function() ExecuteInGameThread(run) end)
    end
end

local function Dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Viewer path (RSDragonwilds/Content/Art/X.X) or game path (/Game/Art/X.X) -> game path.
local function GamePath(p)
    p = Trim(p):gsub("\\", "/")
    if p:sub(1, 1) ~= "/" then
        local root, rest = p:match("^([^/]+)/Content/(.+)$")
        if root == "RSDragonwilds" then p = "/Game/" .. rest
        elseif root then p = "/" .. root .. "/" .. rest
        else p = "/" .. p end
    end
    if not p:match("%.[^/]+$") then p = p .. "." .. p:match("([^/]+)$") end
    return p
end

-- =========================================================================
-- Models and saved placements
-- =========================================================================
local Models = {}

local AllModels = {}   -- every mesh from the viewer export (models-all.txt), with Group

-- "name | mesh [| category]" lines. Meshes are only loaded when picked.
local function ReadList(file, into, defaultGroup)
    local f = io.open(ModDir .. file, "r")
    if not f then return false end
    for line in f:lines() do
        if not line:match("^%s*#") and line:find("|", 1, true) then
            local name, path, group = line:match("^(.-)|([^|]+)|(.+)$")
            if not name then name, path = line:match("^(.-)|(.+)$") end
            name, path = Trim(name or ""), GamePath(path or "")
            if name ~= "" and path ~= "" then
                into[#into + 1] = { Name = name, Mesh = path, Group = group and Trim(group) or defaultGroup }
            end
        end
    end
    f:close()
    return true
end

local function LoadModels()
    Models, AllModels = {}, {}
    if not ReadList("models.txt", Models, "Favourites") then Log("models.txt not found in " .. ModDir) end
    ReadList("models-all.txt", AllModels, "Other")
    Log(string.format("%d favourites in models.txt, %d models in models-all.txt", #Models, #AllModels))
end


-- =========================================================================
-- Saved placements: piece id -> position, rotation and model mesh
-- =========================================================================
local Placed = {}   -- id (string) -> { X, Y, Z, QX, QY, QZ, QW, Mesh }
local Order = {}    -- ids in placement order this session (for cb undo)

local NUM = "([-%d%.e]+)"

local Unparsed = {}   -- lines of placed.txt the mod could not read; kept as they are on save

local LastText = nil   -- placed.txt as last read or written by the mod (to spot outside edits)

-- Parses placed.txt text into records and the lines it could not read.
local function ParsePlaced(text)
    local placed, unparsed = {}, {}
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local id, x, y, z, qx, qy, qz, qw, mesh = line:match("^(m?%d+)|" .. string.rep(NUM .. "|", 7) .. "(.+)$")
        if not id and not line:match("^%s*#") and line:match("%S") then unparsed[#unparsed + 1] = line end
        if id then
            local r = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z),
                QX = tonumber(qx), QY = tonumber(qy), QZ = tonumber(qz), QW = tonumber(qw) }
            -- mesh, then optional "|key=value;..." extras (older lines: "|<base mesh>")
            local m, extra = mesh:match("^(.-)|(.+)$")
            r.Mesh = m or mesh
            if extra and extra:find("=", 1, true) then
                for k, v in extra:gmatch("(%w+)=([^;]*)") do
                    if k == "base" then r.Base = v ~= "" and v or nil
                    elseif k == "pitch" then r.Pitch = tonumber(v)
                    elseif k == "roll" then r.Roll = tonumber(v)
                    elseif k == "scale" then r.Scale = tonumber(v)
                    elseif k == "portal" then r.Portal = v ~= "" and v or nil
                    elseif k == "target" then r.Target = v ~= "" and v or nil end
                end
            else
                r.Base = extra
            end
            placed[id] = r
        end
    end
    return placed, unparsed
end

local function RecordLine(id, r)
    local s = string.format("%s|%.2f|%.2f|%.2f|%.6f|%.6f|%.6f|%.6f|%s|base=%s;pitch=%g;roll=%g;scale=%g",
        id, r.X, r.Y, r.Z, r.QX, r.QY, r.QZ, r.QW, r.Mesh, r.Base or "", r.Pitch or 0, r.Roll or 0, r.Scale or 1)
    if r.Portal and r.Portal ~= "" then s = s .. ";portal=" .. r.Portal end
    if r.Target and r.Target ~= "" then s = s .. ";target=" .. r.Target end
    return s
end

local function ReadFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

local function LoadPlaced()
    local text = ReadFile(ModDir .. "placed.txt")
    LastText = text
    Placed, Unparsed = {}, {}
    if not text then return end
    Placed, Unparsed = ParsePlaced(text)
    local n = 0
    for _ in pairs(Placed) do n = n + 1 end
    if #Unparsed > 0 then Log(string.format("[DISCOVERY] %d lines in placed.txt could not be read; they are kept", #Unparsed)) end
    Log(string.format("%d placed models on record", n))
end

local function SavePlaced()
    -- Keep the previous file as placed.txt.bak before writing a new one.
    local old = ReadFile(ModDir .. "placed.txt")
    if old then
        local bak = io.open(ModDir .. "placed.txt.bak", "wb")
        if bak then bak:write(old); bak:close() end
    end
    local lines = { "# CustomBuilds: piece id|x|y|z|qx|qy|qz|qw|mesh|base=..;pitch=..;roll=..;scale=.. Written by the mod." }
    for id, r in pairs(Placed) do lines[#lines + 1] = RecordLine(id, r) end
    for _, line in ipairs(Unparsed) do lines[#lines + 1] = line end
    local text = table.concat(lines, "\n") .. "\n"
    local f = io.open(ModDir .. "placed.txt", "wb")
    if not f then Log("Could not write placed.txt"); return end
    f:write(text)
    f:close()
    LastText = text
end

-- =========================================================================
-- Model props
-- =========================================================================
local MeshCache = {}

local function LoadMesh(path)
    local m = MeshCache[path]
    if Valid(m) then return m end
    m = StaticFindObject(path)
    if not Valid(m) and LoadAsset then
        pcall(LoadAsset, path)
        m = StaticFindObject(path)
        if not Valid(m) then
            pcall(LoadAsset, (path:gsub("%.[^/]+$", "")))
            m = StaticFindObject(path)
        end
    end
    if Valid(m) then MeshCache[path] = m; return m end
    Log("Mesh not found: " .. path)
    return nil
end

local function Pawn()
    local pc = GetPC()
    if Valid(pc) and Valid(pc.Pawn) then return pc, pc.Pawn end
end

-- Spawns a static mesh actor showing `meshPath` at r (X,Y,Z, QX..QW). Returns the actor.
-- Unreal rotator (degrees) to quaternion, as FRotator::Quaternion does it.
local function RotToQuat(pitch, yaw, roll)
    local r = math.pi / 360
    local sp, cp = math.sin(pitch * r), math.cos(pitch * r)
    local sy, cy = math.sin(yaw * r), math.cos(yaw * r)
    local sr, cr = math.sin(roll * r), math.cos(roll * r)
    return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy,
             Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy }
end

-- =========================================================================
-- NPCs & Base Companions
-- =========================================================================
local BaseNPCs = {} -- [address] = { Actor = a, Blueprint = bpPath, Mesh = mesh, Name = name, Key = key }
OnWorldChange[#OnWorldChange + 1] = function() BaseNPCs = {} end

local NPCMeshToBlueprint = {
    -- Doric
    ["/Game/Art/Skeleton/NPC/Humanoid/Doric_01/SK_Doric_01.SK_Doric_01"] = "/Game/Gameplay/NPCs/BP_NPC_Doric.BP_NPC_Doric_C",
    -- Wise Old Man
    ["/Game/Art/Skeleton/NPC/Humanoid/WiseOldMan_01/SK_WiseOldMan_01.SK_WiseOldMan_01"] = "/Game/Gameplay/NPCs/BP_NPC_WiseOldMan.BP_NPC_WiseOldMan_C",
    -- Vannaka
    ["/Game/Art/Skeleton/NPC/Humanoid/Vannaka_01/SK_Vannaka_01.SK_Vannaka_01"] = "/Game/Gameplay/NPCs/BP_NPC_Vannaka_Fellhollow.BP_NPC_Vannaka_Fellhollow_C",
    -- Zanik
    ["/Game/Art/Skeleton/NPC/Humanoid/Zanik_01/SK_Zanik_01.SK_Zanik_01"] = "/Game/Gameplay/NPCs/BP_NPC_Zanik_Fellhollow.BP_NPC_Zanik_Fellhollow_C",
    -- Cook (Goblin Chef)
    ["/Game/Art/Skeleton/NPC/Humanoid/M_MED_Goblin_Ranged_01/SK_M_MED_Goblin_Ranged_01.SK_M_MED_Goblin_Ranged_01"] = "/Game/Gameplay/NPCs/CooksAssistant_NPCs/BP_NPC_Cook.BP_NPC_Cook_C",
    -- Death
    ["/Game/Art/Skeleton/NPC/Humanoid/Death_01/SK_Death_01.SK_Death_01"] = "/Game/Gameplay/NPCs/BP_NPC_Death.BP_NPC_Death_C",
    -- Postie Pete
    ["/Game/Art/Skeleton/NPC/Hybrid/Postie_Pete_01/SK_Postie_Pete_01.SK_Postie_Pete_01"] = "/Game/Gameplay/NPCs/BP_NPC_PostiePete.BP_NPC_PostiePete_C",
    -- Chicken
    ["/Game/Art/Skeleton/NPC/Avian/Chicken_01/SK_Chicken_01.SK_Chicken_01"] = "/Game/Gameplay/NPCs/CooksAssistant_NPCs/BP_NPC_Quest_Chicken.BP_NPC_Quest_Chicken_C",
    -- Cow
    ["/Game/Art/Skeleton/NPC/Creatures/Cow_01/SK_Cow_01.SK_Cow_01"] = "/Game/Gameplay/NPCs/CooksAssistant_NPCs/BP_NPC_Quest_Cow.BP_NPC_Quest_Cow_C",
    -- Garou (Elder Garou & Moon Garou variants)
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_MoonGarou_01/SK_M_MED_MoonGarou_01_Outfit_01.SK_M_MED_MoonGarou_01_Outfit_01"] = "/Game/Gameplay/NPCs/BP_NPC_Elder_Garou.BP_NPC_Elder_Garou_C",
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_MoonGarou_01/SK_M_MED_MoonGarou_01_Outfit_02.SK_M_MED_MoonGarou_01_Outfit_02"] = "/Game/Gameplay/NPCs/BP_NPC_Elder_Garou.BP_NPC_Elder_Garou_C",
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_MoonGarou_01/SK_M_MED_MoonGarou_01_Outfit_03.SK_M_MED_MoonGarou_01_Outfit_03"] = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Hawker.BP_NPC_UmS_Trader_Hawker_C", -- Domri The Merchant
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_MoonGarou_01/SK_M_MED_MoonGarou_01_Outfit_04.SK_M_MED_MoonGarou_01_Outfit_04"] = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Smith.BP_NPC_UmS_Trader_Smith_C", -- Valas The Blacksmith
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_MoonGarou_01/SK_M_MED_MoonGarou_01_Outfit_05.SK_M_MED_MoonGarou_01_Outfit_05"] = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Hunter.BP_NPC_UmS_Trader_Hunter_C", -- Lagra The Hunter
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_MoonGarou_01/SK_M_MED_MoonGarou_01_Outfit_07.SK_M_MED_MoonGarou_01_Outfit_07"] = "/Game/Gameplay/NPCs/BP_NPC_Elder_Garou.BP_NPC_Elder_Garou_C",
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_MoonGarou_01/SK_M_MED_MoonGarou_01_Outfit_08.SK_M_MED_MoonGarou_01_Outfit_08"] = "/Game/Gameplay/NPCs/BP_NPC_Elder_Garou.BP_NPC_Elder_Garou_C",
    -- Chinchompas
    ["/Game/Art/Skeleton/NPC/Creatures/Chinchompa_01/SK_Chinchompa_01.SK_Chinchompa_01"] = "/ScornedWilderness/Gameplay/BaseBuilding/Blueprints/BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa.BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa_C",
    ["/DowdunReach/Art/Skeleton/NPC/Creatures/Chinchompa_Carnivorous_01/SK_Chinchompa_Carnivorous_01.SK_Chinchompa_Carnivorous_01"] = "/Game/Gameplay/AI/Chinchompa/BP_AI_Chinchompa_Character.BP_AI_Chinchompa_Character_C",
    -- Base Props & Training
    ["/Game/Art/Skeleton/NPC/Mechanical/TrainingDummy_01/SK_TrainingDummy_01.SK_TrainingDummy_01"] = "/Game/Gameplay/BaseBuilding/Actors/Props/BP_BaseBuilding_TrainingDummy.BP_BaseBuilding_TrainingDummy_C",
    ["/Game/Art/Skeleton/NPC/Mechanical/ArmourMannequin_01/SK_ArmourMannequin_01.SK_ArmourMannequin_01"] = "/Game/Gameplay/BaseBuilding/Actors/Props/BP_BaseBuilding_ArmourMannequin.BP_BaseBuilding_ArmourMannequin_C",
    -- Guard & Quest NPCs
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/M_MED_KotHaar_Ket_01/SK_M_MED_KotHaar_Ket_01.SK_M_MED_KotHaar_Ket_01"] = "/Game/Gameplay/NPCs/BP_NPC_KotHaarBouncer.BP_NPC_KotHaarBouncer_C",
    ["/ScornedWilderness/Art/Skeleton/NPC/Humanoid/Zilyana_01/SK_Zilyana_01.SK_Zilyana_01"] = "/ScornedWilderness/Gameplay/Quests/NPCs/BP_NPC_SW_Zilyana.BP_NPC_SW_Zilyana_C",
    ["/UmbralSands/Art/Skeleton/NPC/Humanoid/Icthlarin_01/SK_Icthlarin_01.SK_Icthlarin_01"] = "/UmbralSands/Gameplay/Quests/NPCs/BP_NPC_Icthlarin.BP_NPC_Icthlarin_C",
}

local NPCBarks = {
    doric = {
        "Doric: Welcome to my workshop! What are we crafting today?",
        "Doric: A solid foundation. That's the secret to any good structure.",
        "Doric: Need an anvil? I've seen some fine ore in the hills nearby.",
        "Doric: Keep hammering away! Great things take time.",
    },
    wise = {
        "Wise Old Man: Ah, a fine fortress you've constructed here!",
        "Wise Old Man: Mind if I take a look around? I won't touch the gold, promise...",
        "Wise Old Man: Have you checked on the bank lately? Just curious.",
        "Wise Old Man: Back in my adventuring days, we had to build our own castles!",
    },
    vannaka = {
        "Vannaka: Stand tall, warrior! Even in your sanctuary, vigilance is key.",
        "Vannaka: A well-defended perimeter will keep the wilderness beasts at bay.",
        "Vannaka: Ready for your next task? The realm always needs defenders.",
    },
    zanik = {
        "Zanik: It's so bright up here! Much better than the tunnels.",
        "Zanik: Wow, you built all of this? The surface world is incredible!",
        "Zanik: Let me know if you need any help exploring!",
    },
    cook = {
        "Cook: Ah, the kitchen is coming along nicely! Any extra cabbage?",
        "Cook: If you smell something burning... it's definitely not my soufflé.",
        "Cook: A true adventurer fights on a full stomach!",
    },
    death = {
        "Death: DO NOT MIND ME. I AM MERELY VISITING... FOR NOW.",
        "Death: YOUR ARCHITECTURE IS SURPRISINGLY PERMANENT.",
        "Death: I WILL SEE YOU SOON. BUT NOT TODAY.",
    },
    pete = {
        "Postie Pete: Mail call! Nothing for you today, but lovely base you have here!",
        "Postie Pete: Neither rain nor wilderness dragons shall stop the post!",
    },
    garou = {
        "Elder Garou: *The wolf elder lowers his head in deep respect for your domain.*",
        "Elder Garou: The moon watches over our pack... and over your hearth.",
    },
    domri = {
        "Domri - The Merchant: Welcome, traveller! Looking for rare goods and trinkets from the Alcarrid Camp?",
        "Domri - The Merchant: My wares are the finest in the sands. Bring me moonstones and we'll trade!",
        "Domri - The Merchant: The desert is harsh, but honest commerce always thrives.",
    },
    merchant = {
        "Domri - The Merchant: Welcome, traveller! Looking for rare goods and trinkets from the Alcarrid Camp?",
        "Domri - The Merchant: My wares are the finest in the sands. Bring me moonstones and we'll trade!",
    },
    valas = {
        "Valas - The Blacksmith: The forge heat never cools in the desert. Need a sturdy blade tempered?",
        "Valas - The Blacksmith: Good steel and sharp edges - that's what keeps you alive out there.",
    },
    lagra = {
        "Lagra - The Hunter: Watch your flanks out in the dunes. Beasts strike without warning.",
        "Lagra - The Hunter: Fresh game, fresh pelts. The hunt never ceases.",
    },
    chin = {
        "Chinchompa: *Squeak! The fluffy creature nuzzles against your boots.*",
        "Chinchompa: *Sniffs the air excitedly and wiggles its whiskers.*",
    },
    cow = {
        "Cow: Mooooo! *Chews peacefully on some fresh grass.*",
    },
    chicken = {
        "Chicken: Bwuuuk bwuk bwuk! *Pecks at the floor.*",
    },
    dummy = {
        "Training Dummy: *Stands firm, ready for combat practice.*",
    },
    mannequin = {
        "Armour Mannequin: *Holds your gear proudly on display.*",
    },
    zilyana = {
        "Commander Zilyana: Saradomin's light shines upon this bastion.",
    },
    guard = {
        "Guard: Keep the peace, citizen. This base is under my watch.",
    }
}

local function ResolveNPCBlueprint(path)
    if not path then return nil end
    if NPCMeshToBlueprint[path] then return NPCMeshToBlueprint[path] end
    local lower = path:lower()
    for k, v in pairs(NPCMeshToBlueprint) do
        if k:lower() == lower or k:lower():find(lower, 1, true) then return v end
    end
    if path:find("BP_NPC_") or path:find("_Character_C") then return path end
    return nil
end

local function TraceGroundZ(x, y, z, ignoreActor)
    local pc, pawn = Pawn()
    local world = nil
    if Valid(pc) then pcall(function() world = pc:GetWorld() end) end
    if not Valid(world) and Valid(pawn) then pcall(function() world = pawn:GetWorld() end) end
    if not Valid(world) then return nil end

    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not Valid(ksl) then return nil end

    local start = { X = x, Y = y, Z = z + 500.0 }
    local finish = { X = x, Y = y, Z = z - 2000.0 }
    local outHit = {}
    local ignoreList = ignoreActor and { ignoreActor } or {}
    local ok, hit = pcall(function()
        return ksl:LineTraceSingle(world, start, finish, 0, false, ignoreList, 0, outHit, false, {}, {}, 0.0)
    end)
    if ok and hit and outHit.Location then
        return outHit.Location.Z
    end
    return nil
end

local function SpawnNPC(bpPath, r, movable, origMesh)
    local pc, pawn = Pawn()
    if not pawn then return nil, "not in world" end
    local cls = StaticFindObject(bpPath)
    if not Valid(cls) and LoadAsset then
        pcall(LoadAsset, bpPath)
        cls = StaticFindObject(bpPath)
        if not Valid(cls) then
            pcall(LoadAsset, (bpPath:gsub("%.[^/]+$", "")))
            cls = StaticFindObject(bpPath)
        end
    end
    if not Valid(cls) then return nil, "NPC class not found: " .. bpPath end

    local yaw = r.Yaw
    if not yaw then
        local x, y, z, w = r.QX or 0, r.QY or 0, r.QZ or 0, r.QW or 1
        yaw = math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
    end
    local s = r.Scale or 1

    -- Terrain raycast snapping to prevent floating or sunken actors on slopes
    local spawnZ = r.Z + Config.ZOffset
    local groundZ = TraceGroundZ(r.X, r.Y, r.Z, pawn)
    if groundZ then
        spawnZ = groundZ + Config.ZOffset
    end

    local xf = {
        Rotation = RotToQuat(r.Pitch or 0, yaw, r.Roll or 0),
        Translation = { X = r.X, Y = r.Y, Z = spawnZ },
        Scale3D = { X = s, Y = s, Z = s },
    }
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    -- CollisionHandlingOverride: 2 = AdjustIfPossibleButAlwaysSpawn
    local a = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 2, nil, 0)
    if not Valid(a) then
        a = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 1, nil, 1)
    end
    if not Valid(a) then return nil, "deferred spawn failed" end

    -- Enable movable root mobility so rotation & interaction positioning are permitted
    pcall(function()
        if Valid(a.RootComponent) then
            a.RootComponent:SetMobility(2) -- EComponentMobility::Movable
        end
    end)

    -- Automatically hide tutorial placeholder boxes/crates baked into FTUE character blueprints
    for _, prop in ipairs({"StaticMesh_0", "ReplacementMeshComponent1", "StaticMesh", "ReplacementMesh", "ReplacementMeshComponent"}) do
        pcall(function()
            local comp = a[prop]
            if Valid(comp) then comp:SetVisibility(false, false) end
        end)
    end

    -- Companion identification tag
    pcall(function() a.Tags:Add("BaseCompanion") end)

    a = gs:FinishSpawningActor(a, xf, 0)
    if not Valid(a) then return nil, "finish spawn failed" end

    -- Isolate companion from vanilla Fellhollow quest trees
    pcall(function()
        local conv = a:GetComponentByClass(StaticFindObject("/Script/Dominion.DomConversationParticipant"))
        if Valid(conv) then
            conv:K2_DestroyComponent(conv)
        end
    end)

    -- Register companion for interaction
    local addr = a:GetAddress()
    local name = a:GetFName():ToString()
    local key = bpPath:match("BP_NPC_([%w_]+)") or bpPath:match("([^/%.]+)_C$") or "npc"
    BaseNPCs[addr] = {
        Actor = a,
        Blueprint = bpPath,
        Mesh = origMesh or r.Mesh,
        Name = name,
        Key = key:lower()
    }

    return a
end

-- Spawns a static mesh actor (or SkeletalMesh / NPC Character) showing `meshPath` at r
local function SpawnModel(meshPath, r, movable)
    local _, pawn = Pawn()
    if not pawn then return nil, "not in a world" end

    -- 1. Check if mapped to a living NPC Character Blueprint
    local bpPath = ResolveNPCBlueprint(meshPath)
    if bpPath then
        return SpawnNPC(bpPath, r, movable, meshPath)
    end

    local mesh = LoadMesh(meshPath)
    if not mesh then return nil, "mesh not found: " .. meshPath end
    local yaw = r.Yaw
    if not yaw then
        local x, y, z, w = r.QX or 0, r.QY or 0, r.QZ or 0, r.QW or 1
        yaw = math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
    end
    local s = r.Scale or 1
    local xf = {
        Rotation = RotToQuat(r.Pitch or 0, yaw, r.Roll or 0),
        Translation = { X = r.X, Y = r.Y, Z = r.Z + Config.ZOffset },
        Scale3D = { X = s, Y = s, Z = s },
    }
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")

    -- 2. Check if it's a Skeletal Mesh
    local isSkel = false
    pcall(function() isSkel = mesh:GetClass():GetFName():ToString() == "SkeletalMesh" end)
    if isSkel then
        local cls = StaticFindObject("/Script/Engine.SkeletalMeshActor")
        local a = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 1, nil, 1)
        if not Valid(a) then return nil, "skel spawn failed" end
        local c = a.SkeletalMeshComponent
        if movable then
            pcall(function() c:SetMobility(2) end)
            pcall(function() if Valid(a.RootComponent) then a.RootComponent:SetMobility(2) end end)
        end
        pcall(function() c:SetSkeletalMeshAsset(mesh) end)
        pcall(function() c.bNeverDistanceCull = true end)
        a = gs:FinishSpawningActor(a, xf, 1)
        return a
    end

    -- 3. Standard StaticMeshActor
    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
    local a = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 1, nil, 1)
    if not Valid(a) then return nil, "spawn failed" end
    local c = a.StaticMeshComponent
    if movable then
        pcall(function() c:SetMobility(2) end)
        pcall(function() if Valid(a.RootComponent) then a.RootComponent:SetMobility(2) end end)
    end
    pcall(function() c:SetStaticMesh(mesh) end)
    pcall(function() c.bNeverDistanceCull = true end)
    pcall(function() c.bAllowCullDistanceVolume = false end)
    pcall(function() c.LDMaxDrawDistance = 0.0 end)
    pcall(function() c.CachedMaxDrawDistance = 0.0 end)
    a = gs:FinishSpawningActor(a, xf, 1)
    if not Valid(a) then return nil, "finish spawn failed" end
    -- In case the spawn step reset the mesh.
    pcall(function()
        local cur = a.StaticMeshComponent.StaticMesh
        if not Valid(cur) then
            a.StaticMeshComponent:SetMobility(2)
            a.StaticMeshComponent:SetStaticMesh(mesh)
        end
    end)
    return a
end

-- Tilt (pitch), turn (roll) and size on top of the yaw the piece was placed with.
local function YawOf(r)
    local x, y, z, w = r.QX or 0, r.QY or 0, r.QZ or 0, r.QW or 1
    return math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
end

-- Per-model default orientation (orient.txt: mesh|pitch|roll|scale). Fixing a model
-- once, e.g. standing a castle entrance up, applies to all later placements of it.
local Orient = {}

local function LoadOrient()
    Orient = {}
    local f = io.open(ModDir .. "orient.txt", "r")
    if not f then return end
    for line in f:lines() do
        local mesh, p, r, s = line:match("^([^#|][^|]*)|([-%d%.e]+)|([-%d%.e]+)|([-%d%.e]+)")
        if mesh then Orient[mesh] = { Pitch = tonumber(p), Roll = tonumber(r), Scale = tonumber(s) } end
    end
    f:close()
end

local function SaveOrient()
    local f = io.open(ModDir .. "orient.txt", "w")
    if not f then return end
    f:write("# CustomBuilds: default tilt/turn/size per model (mesh|pitch|roll|scale). Written by the mod.\n")
    for mesh, o in pairs(Orient) do
        f:write(string.format("%s|%g|%g|%g\n", mesh, o.Pitch, o.Roll, o.Scale))
    end
    f:close()
end

local function OrientFor(mesh)
    local o = Orient[mesh]
    return o and { Pitch = o.Pitch, Roll = o.Roll, Scale = o.Scale } or { Pitch = 0, Roll = 0, Scale = 1 }
end

local function ApplyTransform(a, r)
    if not Valid(a) then return end
    pcall(function() a:K2_SetActorRotation({ Pitch = r.Pitch or 0, Yaw = YawOf(r), Roll = r.Roll or 0 }, true) end)
    local s = r.Scale or 1
    pcall(function() a:SetActorScale3D({ X = s, Y = s, Z = s }) end)
end

local Props = {}   -- id (string) -> spawned actor
OnWorldChange[#OnWorldChange + 1] = function() Props = {} end

local function DestroyProp(id)
    local a = Props[id]
    if Valid(a) then
        BaseNPCs[a:GetAddress()] = nil
        pcall(function() a:K2_DestroyActor() end)
    end
    Props[id] = nil
    for _, sfx in ipairs({ "_fx", "_fx1", "_fx2" }) do
        local fx = Props[id .. sfx]
        if Valid(fx) then pcall(function() fx:K2_DestroyActor() end) end
        Props[id .. sfx] = nil
    end
end

-- =========================================================================
-- Pieces
-- =========================================================================
local function Manager()
    for _, m in ipairs(FindAllOf("GlobalBuildingManager") or {}) do
        if Valid(m) and not NameOf(m):find("^Default__") then return m end
    end
end

local function LastPieceId()
    local id = nil
    pcall(function() id = tonumber(Manager().GeneratedPieceID) end)
    return id
end

-- true / false, or nil when the game's piece list cannot be read.
local function PieceExists(id)
    local m = Manager()
    if not m then return nil end
    local ok, res = pcall(function() return m.BuildingPieces:Contains(tonumber(id)) end)
    if ok then return res and true or false end
    return nil
end

-- Put missing props back. A record is only dropped when its piece is gone AND the
-- game just reported a piece destroyed at that spot (`at`): the game's piece list
-- may not hold far-away pieces, so "not in the list" alone is not proof.
-- Props this mod already spawned in this world before a reload of the mod: adopt
-- them instead of spawning duplicates.
CompanionClassNames = {
    "BP_NPC_Doric_C",
    "BP_NPC_Doric",
    "BP_NPC_WiseOldMan_C",
    "BP_NPC_WiseOldMan",
    "BP_NPC_Vannaka_Fellhollow_C",
    "BP_NPC_Vannaka_Fellhollow",
    "BP_NPC_Zanik_Fellhollow_C",
    "BP_NPC_Zanik_Fellhollow",
    "BP_NPC_Cook_C",
    "BP_NPC_Cook",
    "BP_NPC_Death_C",
    "BP_NPC_Death",
    "BP_NPC_PostiePete_C",
    "BP_NPC_PostiePete",
    "BP_NPC_Quest_Chicken_C",
    "BP_NPC_Quest_Chicken",
    "BP_NPC_Quest_Cow_C",
    "BP_NPC_Quest_Cow",
    "BP_NPC_Elder_Garou_C",
    "BP_NPC_Elder_Garou",
    "BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa_C",
    "BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa",
    "BP_BaseBuilding_TrainingDummy_C",
    "BP_BaseBuilding_TrainingDummy",
    "BP_BaseBuilding_ArmourMannequin_C",
    "BP_BaseBuilding_ArmourMannequin",
    "BP_NPC_KotHaarBouncer_C",
    "BP_NPC_KotHaarBouncer",
    "BP_NPC_SW_Zilyana_C",
    "BP_NPC_SW_Zilyana",
    "BP_NPC_Base_C",
    "BP_NPC_Base",
    "DominionNPCCharacter",
    "DominionCharacterBase",
    "Character",
    "Pawn",
    "SkeletalMeshActor"
}

function FindAllCompanions()
    local companions = {}
    local seenAddr = {}

    local function addActor(a)
        if not Valid(a) then return end
        local ok, addr = pcall(function() return a:GetAddress() end)
        if not ok or not addr or seenAddr[addr] then return end
        seenAddr[addr] = true
        companions[#companions + 1] = a
    end

    for _, cls in ipairs(CompanionClassNames) do
        local ok, list = pcall(function() return FindAllOf(cls) end)
        if ok and list then
            for _, a in ipairs(list) do
                if Valid(a) then
                    local name = NameOf(a):lower()
                    local cname = ClassName(a):lower()
                    if cls:find("^BP_NPC_") or cls:find("Chinchompa") or cls:find("TrainingDummy") or cls:find("ArmourMannequin") then
                        addActor(a)
                    elseif name:find("doric") or cname:find("doric") or name:find("companion") or cname:find("companion") then
                        addActor(a)
                    end
                end
            end
        end
    end

    for _, info in pairs(BaseNPCs or {}) do
        if info and Valid(info.Actor) then addActor(info.Actor) end
    end

    for id, a in pairs(Props or {}) do
        local r = Placed and Placed[id]
        if r and ResolveNPCBlueprint(r.Mesh) and Valid(a) then
            addActor(a)
        end
    end

    for _, a in ipairs(TestProps or {}) do
        if Valid(a) then addActor(a) end
    end

    return companions
end

function CleanupCompanions(keepSingle)
    local companions = FindAllCompanions()
    local destroyed = 0
    local kept = 0

    if not keepSingle then
        for _, a in ipairs(companions) do
            if Valid(a) then
                pcall(function() a:K2_DestroyActor() end)
                destroyed = destroyed + 1
            end
        end
        BaseNPCs = {}
        TestProps = {}
        for id, a in pairs(Props or {}) do
            local r = Placed and Placed[id]
            if r and ResolveNPCBlueprint(r.Mesh) then
                Props[id] = nil
            end
        end
    else
        local placedNPCs = {}
        for id, r in pairs(Placed or {}) do
            if ResolveNPCBlueprint(r.Mesh) then
                placedNPCs[#placedNPCs + 1] = { id = id, r = r }
            end
        end

        local claimedActors = {}
        for _, p in ipairs(placedNPCs) do
            local targetLoc = { X = p.r.X, Y = p.r.Y, Z = p.r.Z + Config.ZOffset }
            local bestActor = nil
            local bestDist = 9999999
            for _, a in ipairs(companions) do
                if Valid(a) and not claimedActors[a:GetAddress()] then
                    local ok, loc = pcall(function() return a:K2_GetActorLocation() end)
                    if ok and loc then
                        local d = Dist(loc, targetLoc)
                        if d < bestDist then
                            bestDist = d
                            bestActor = a
                        end
                    end
                end
            end

            if bestActor then
                local addr = bestActor:GetAddress()
                claimedActors[addr] = true
                Props[p.id] = bestActor
                BaseNPCs[addr] = {
                    Actor = bestActor,
                    Name = "Doric",
                    Key = (p.r.Mesh or "doric"):lower(),
                    Mesh = p.r.Mesh
                }
                kept = kept + 1
            end
        end

        if #placedNPCs == 0 then
            local keptClasses = {}
            for _, a in ipairs(companions) do
                if Valid(a) then
                    local cname = ClassName(a)
                    if not keptClasses[cname] then
                        keptClasses[cname] = a
                        claimedActors[a:GetAddress()] = true
                        kept = kept + 1
                        BaseNPCs[a:GetAddress()] = {
                            Actor = a,
                            Name = "Doric",
                            Key = "doric"
                        }
                    end
                end
            end
        end

        for _, a in ipairs(companions) do
            if Valid(a) and not claimedActors[a:GetAddress()] then
                pcall(function() a:K2_DestroyActor() end)
                destroyed = destroyed + 1
            end
        end
    end

    TestProps = {}
    Log(string.format("[COMPANION] Cleanup completed: destroyed %d, kept %d", destroyed, kept))
    return destroyed, kept
end

local function AdoptExisting()
    local missing = {}
    for id, r in pairs(Placed) do
        if not Valid(Props[id]) then missing[#missing + 1] = id end
    end
    if #missing == 0 then return end
    for _, a in ipairs(FindAllOf("StaticMeshActor") or {}) do
        if Valid(a) and NameOf(a):find("^StaticMeshActor_") then
            local ok, loc = pcall(function() return a:K2_GetActorLocation() end)
            if ok and loc then
                for _, id in ipairs(missing) do
                    local r = Placed[id]
                    if not Valid(Props[id]) and Dist(loc, { X = r.X, Y = r.Y, Z = r.Z + Config.ZOffset }) < 2 then
                        local meshPath = ""
                        pcall(function()
                            local sm = a.StaticMeshComponent.StaticMesh
                            if Valid(sm) then meshPath = sm:GetFullName() end
                        end)
                        if meshPath:find(r.Mesh:match("[^/]+$"), 1, true) then Props[id] = a end
                    end
                end
            end
        end
    end

    local allComps = FindAllCompanions()
    for _, id in ipairs(missing) do
        local r = Placed[id]
        if ResolveNPCBlueprint(r.Mesh) and not Valid(Props[id]) then
            local targetLoc = { X = r.X, Y = r.Y, Z = r.Z + Config.ZOffset }
            local bestActor = nil
            local bestDist = 9999999
            for _, a in ipairs(allComps) do
                if Valid(a) then
                    local ok, loc = pcall(function() return a:K2_GetActorLocation() end)
                    if ok and loc then
                        local d = Dist(loc, targetLoc)
                        if d < 1500 and d < bestDist then
                            bestActor = a
                            bestDist = d
                        end
                    end
                end
            end
            if bestActor then
                Props[id] = bestActor
                BaseNPCs[bestActor:GetAddress()] = {
                    Key = (r.Mesh or "doric"):lower(),
                    Name = "Doric",
                    Actor = bestActor,
                    Mesh = r.Mesh
                }
            end
        end
    end
end

local GameWorld = nil

local function Restore(at)
    local spawned, removed = 0, 0
    if not Manager() then return 0, 0 end
    GameWorld = WorldKey()
    pcall(AdoptExisting)
    pcall(function() CleanupCompanions(true) end)

    for id, r in pairs(Placed) do
        local exists = id:find("^m") and true or PieceExists(id)
        if exists == false and at and Dist(at, r) <= 300 then
            DestroyProp(id)
            Placed[id] = nil
            removed = removed + 1
        elseif exists == true and not Valid(Props[id]) then
            local bpPath = ResolveNPCBlueprint(r.Mesh)
            if bpPath then
                local targetLoc = { X = r.X, Y = r.Y, Z = r.Z + Config.ZOffset }
                local allComps = FindAllCompanions()
                local bestActor = nil
                local bestDist = 9999999
                local duplicates = {}

                for _, a in ipairs(allComps) do
                    if Valid(a) then
                        local ok, loc = pcall(function() return a:K2_GetActorLocation() end)
                        if ok and loc then
                            local d = Dist(loc, targetLoc)
                            if d < 1500 then
                                if not bestActor or d < bestDist then
                                    if bestActor then duplicates[#duplicates + 1] = bestActor end
                                    bestActor = a
                                    bestDist = d
                                else
                                    duplicates[#duplicates + 1] = a
                                end
                            end
                        end
                    end
                end

                for _, dup in ipairs(duplicates) do
                    pcall(function() dup:K2_DestroyActor() end)
                end

                if bestActor then
                    Props[id] = bestActor
                    BaseNPCs[bestActor:GetAddress()] = {
                        Key = (r.Mesh or "doric"):lower(),
                        Name = "Doric",
                        Actor = bestActor,
                        Mesh = r.Mesh
                    }
                else
                    local a, err = SpawnModel(r.Mesh, r)
                    if a then Props[id] = a; spawned = spawned + 1 else Log("Restore " .. id .. ": " .. tostring(err)) end
                end
            else
                local a, err = SpawnModel(r.Mesh, r)
                if a then Props[id] = a; spawned = spawned + 1 else Log("Restore " .. id .. ": " .. tostring(err)) end
            end
        end
    end
    if removed > 0 then SavePlaced() end
    return spawned, removed
end

-- Surface / Camera helpers
local function CameraView()
    local pc = GetPC()
    if not Valid(pc) then return nil end
    local cam = nil
    pcall(function() cam = pc.PlayerCameraManager end)
    if not Valid(cam) then return nil end
    local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
    local fwd = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):GetForwardVector(rot)
    return pc, loc, rot, fwd
end

local function WriteText(name, text)
    if not ModDir then return false end
    local f = io.open(ModDir .. name, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function PieceNames()
    local names = {}
    for _, d in ipairs(FindAllOf("BuildingPieceData") or {}) do
        if Valid(d) and not NameOf(d):find("^Default__") then
            local idx = nil
            pcall(function() idx = tonumber(d.BuildingPieceDataIndex) end)
            if idx and idx >= 0 and not names[idx] then names[idx] = NameOf(d) end
        end
    end
    return names
end

local LastPieceCount = -1
local LastExportAt = 0
local function ExportNativePieces(playerLoc)
    local now = os.clock()
    if now - LastExportAt < 2 then return end
    LastExportAt = now

    local m = Manager()
    if not m then return end
    local names = PieceNames()
    local lines = { "# CustomBuilds base reference: piece|x|y|z|yaw. Auto-exported for base builder." }
    local count = 0
    pcall(function()
        m.BuildingPieces:ForEach(function(_, state)
            local cv = Get(state).ClientVisible
            local l = cv.Location
            count = count + 1
            lines[#lines + 1] = string.format("%s|%.2f|%.2f|%.2f|%.2f",
                names[tonumber(cv.BuildingPieceDataIndex)] or ("piece" .. tostring(cv.BuildingPieceDataIndex)),
                l.X, l.Y, l.Z, cv.Yaw)
        end)
    end)
    if count ~= LastPieceCount then
        LastPieceCount = count
        WriteText("base.txt", table.concat(lines, "\n") .. "\n")
        Log(string.format("Auto-exported %d native building pieces to base.txt", count))
    end
end

-- Live sync: when placed.txt is changed by something else (e.g. the ashenfallen.com
-- base builder writing into this folder), make the world match it. Checked every
-- couple of seconds from the ghost loop; nothing happens while the file is unchanged.
local SyncAt = 0
local function SyncPlaced()
    if not GameWorld or WorldKey() ~= GameWorld then return end
    local _, pawn = Pawn()
    if pawn then
        local loc = pawn:K2_GetActorLocation()
        local _, _, rot = CameraView()
        local yaw = rot and rot.Yaw or 0
        WriteText("player.txt", string.format("%.2f|%.2f|%.2f|%.2f\n", loc.X, loc.Y, loc.Z, yaw))
        ExportNativePieces(loc)
    end
    if LoadQuests then pcall(LoadQuests) end
    if SyncInventory then pcall(SyncInventory) end
    local text = ReadFile(ModDir .. "placed.txt")
    if not text or text == LastText then return end
    LastText = text
    local new, unparsed = ParsePlaced(text)
    local added, changed, removed = 0, 0, 0
    for id, r in pairs(Placed) do
        local n = new[id]
        if not n then
            DestroyProp(id); removed = removed + 1
        elseif RecordLine(id, n) ~= RecordLine(id, r) then
            DestroyProp(id); changed = changed + 1
        end
    end
    for id in pairs(new) do if not Placed[id] then added = added + 1 end end
    Placed, Unparsed = new, unparsed
    for id, r in pairs(Placed) do
        if not Valid(Props[id]) then
            local exists = id:find("^m") and true or PieceExists(id)
            if exists then
                local a = SpawnModel(r.Mesh, r)
                if a then Props[id] = a end
            end
        end
    end
    Log(string.format("placed.txt changed outside the game: %d added, %d changed, %d removed", added, changed, removed))
end

-- =========================================================================
-- Hiding the base decoration. Small decorations are drawn as instances of one mesh
-- in the game's building instance components; the instance at the piece's exact
-- spot is shrunk to nothing, which removes its look and its collision. The game
-- rebuilds those components when an area streams back in, so a slow timer checks
-- the records near the player and hides them again when needed.
-- =========================================================================
local HIDDEN_SCALE = 0.0001
local Hidden = {}   -- id -> { Comp, Index } where the base instance was last hidden
OnWorldChange[#OnWorldChange + 1] = function() Hidden = {} end

-- Instanced mesh components that may draw building pieces: the game's own
-- BuildingHISMC first, then any other (hierarchical) instanced component, skipping
-- foliage and landscape grass.
local function InstanceComps()
    local list, seen = {}, {}
    for _, cls in ipairs({ "BuildingHISMC", "HierarchicalInstancedStaticMeshComponent", "InstancedStaticMeshComponent" }) do
        for _, c in ipairs(FindAllOf(cls) or {}) do
            if Valid(c) and not seen[c:GetAddress()] then
                seen[c:GetAddress()] = true
                local owner = ""
                pcall(function() owner = ClassName(c:GetOwner()) end)
                if not owner:find("Foliage") and not owner:find("Landscape") and not owner:find("Grass") then
                    list[#list + 1] = c
                end
            end
        end
    end
    return list
end

local OutParamChecked = false
local function InstanceTransform(comp, index)
    local t = {}
    local ok, err = pcall(function() comp:GetInstanceTransform(index, t, true) end)
    if not OutParamChecked then
        OutParamChecked = true
        Log("[DISCOVERY] GetInstanceTransform: ok=" .. tostring(ok) .. " translation read=" .. tostring(t.Translation ~= nil)
            .. (ok and "" or (" err=" .. tostring(err))))
    end
    if ok and t.Translation then return t end
    return nil
end

-- Logs what instanced pieces are near a spot (used when a base could not be found).
local function DescribeInstancesNear(r)
    local comps = InstanceComps()
    Log(string.format("[DISCOVERY] %d instanced components to search", #comps))
    local shown = 0
    for _, comp in ipairs(comps) do
        local hits = nil
        pcall(function() hits = comp:GetInstancesOverlappingSphere({ X = r.X, Y = r.Y, Z = r.Z }, 150.0, true) end)
        local n = 0
        pcall(function() n = hits:GetArrayNum() end)
        if n > 0 and shown < 12 then
            shown = shown + 1
            local mesh, owner = "", ""
            pcall(function() mesh = NameOf(comp.StaticMesh) end)
            pcall(function() owner = ClassName(comp:GetOwner()) end)
            local best = math.huge
            for k = 1, n do
                local t = InstanceTransform(comp, Get(hits[k]))
                if t then best = math.min(best, Dist(t.Translation, r)) end
            end
            Log(string.format("[DISCOVERY]   %s on %s mesh %s: %d near, closest origin %.0f cm",
                ClassName(comp), owner, mesh, n, best))
        end
    end
    if shown == 0 then Log("[DISCOVERY]   no instanced component has instances within 1.5 m") end
end

local function IsShrunk(t)
    local s = t.Scale3D
    return s and math.abs(s.X) < 0.01
end

local function Shrink(comp, index, t)
    local q, p = t.Rotation, t.Translation
    return comp:UpdateInstanceTransform(index, {
        Rotation = { X = q.X, Y = q.Y, Z = q.Z, W = q.W },
        Translation = { X = p.X, Y = p.Y, Z = p.Z },
        Scale3D = { X = HIDDEN_SCALE, Y = HIDDEN_SCALE, Z = HIDDEN_SCALE },
    }, true, true, true)
end

-- Finds the instance whose origin is at the record's spot and shrinks it.
-- Returns the base mesh name when found (stored so later searches are cheaper).
local function HideBase(id, r)
    local h = Hidden[id]
    if h and Valid(h.Comp) then
        local t = InstanceTransform(h.Comp, h.Index)
        if t and Dist(t.Translation, r) < 5 then
            if not IsShrunk(t) then Shrink(h.Comp, h.Index, t) end
            return r.Base
        end
    end
    Hidden[id] = nil
    for _, comp in ipairs(InstanceComps()) do
        if Valid(comp) and not NameOf(comp):find("^Default__") then
            local meshName = ""
            pcall(function() meshName = NameOf(comp.StaticMesh) end)
            if not r.Base or meshName == r.Base then
                local hits = nil
                pcall(function() hits = comp:GetInstancesOverlappingSphere({ X = r.X, Y = r.Y, Z = r.Z }, 30.0, true) end)
                local n = 0
                pcall(function() n = hits:GetArrayNum() end)
                for k = 1, n do
                    local index = Get(hits[k])
                    local t = InstanceTransform(comp, index)
                    if t and Dist(t.Translation, r) < 5 then
                        if not IsShrunk(t) then Shrink(comp, index, t) end
                        Hidden[id] = { Comp = comp, Index = index }
                        return meshName
                    end
                end
            end
        end
    end
    return nil
end

local HideTicking = false
OnWorldChange[#OnWorldChange + 1] = function() HideTicking = false end

-- Every 3 s: re-hide the bases of models within 80 m (areas stream back in).
local function HideTick()
    local _, pawn = Pawn()
    if pawn then
        local here = pawn:K2_GetActorLocation()
        for id, r in pairs(Placed) do
            -- A base that could not be found is only searched for again every 30 s.
            if not id:find("^m") and Dist(here, r) < 8000 and (not r.RetryAt or os.clock() >= r.RetryAt) then
                local ok, base = pcall(HideBase, id, r)
                r.RetryAt = (ok and base) and nil or (os.clock() + 30)
            end
        end
    end
    Later(3000, HideTick)
end

local function StartHideTimer()
    -- Only needed for the old barrel method; the search is heavy, so it is off otherwise.
    if not Config.BarrelAnchor then return end
    if HideTicking then return end
    HideTicking = true
    Later(3000, HideTick)
end

-- =========================================================================
-- Placement
-- =========================================================================
local Skin = nil   -- model picked with "cb <n>", or nil

pcall(function()
    RegisterHook("/Script/Dominion.BuildModeComponent:Server_SpawnBuilding", function(self, index, transform)
        CheckWorld()
        -- Models are placed by the mod's own placer now; normal building is left alone.
        if not Skin or not Config.BarrelAnchor then return end
        local model = Skin
        local r = nil
        local ok, err = pcall(function()
            local t = Get(transform)
            local p, q = t.Translation, t.Rotation
            r = { X = p.X, Y = p.Y, Z = p.Z, QX = q.X, QY = q.Y, QZ = q.Z, QW = q.W, Mesh = model.Mesh }
            local o = OrientFor(model.Mesh)
            r.Pitch, r.Roll, r.Scale = o.Pitch, o.Roll, o.Scale
        end)
        if not ok then Log("Could not read the placement: " .. tostring(err)); return end
        -- Check how well the ghost's source matches where the piece really goes.
        pcall(function()
            local h = PlacementHelper()
            if h then
                local l = h:K2_GetActorLocation()
                Log(string.format("[DISCOVERY] build helper is %.0f cm from the placed spot", Dist(l, r)))
            end
        end)
        local before = LastPieceId()
        -- The piece gets its id while the game handles the placement; look shortly after.
        Later(400, function()
            local id = LastPieceId()
            if not id or id == before then
                Log("No new piece after placing (blocked spot?); nothing added")
                return
            end
            local key = tostring(id)
            local a, why = SpawnModel(r.Mesh, r)
            if not a then Log("Could not show " .. model.Name .. ": " .. tostring(why)); return end
            Props[key] = a
            Placed[key] = r
            Order[#Order + 1] = key
            local ok, base = pcall(HideBase, key, r)
            if ok and base then
                r.Base = base
                Log(string.format("Placed %s on piece %s (base %s hidden)", model.Name, key, base))
            else
                Log(string.format("Placed %s on piece %s; [DISCOVERY] base not hidden yet: %s",
                    model.Name, key, ok and "no instance at the spot" or tostring(base)))
                pcall(DescribeInstancesNear, r)
            end
            SavePlaced()
            StartHideTimer()
        end)
    end)
end)

-- =========================================================================
-- Ghost: a see-through, non-colliding copy of the picked model that follows the
-- build placement while a model is picked. Driven by a game-thread timer that only
-- runs while a model is picked (cb off stops it). No LoopAsync.
-- =========================================================================
local Ghost = { Actor = nil, Mesh = nil, Comp = nil, Ticking = false, Warned = false }
OnWorldChange[#OnWorldChange + 1] = function()
    Ghost.Actor, Ghost.Mesh, Ghost.Comp, Ghost.Ticking = nil, nil, nil, false
end

local function Weak(w)
    local o = nil
    pcall(function() o = w:Get() end)
    if not Valid(o) then pcall(function() o = w:get() end) end
    return Valid(o) and o or nil
end

local function PlayerBuildComp()
    if Valid(Ghost.Comp) then return Ghost.Comp end
    local pc = GetPC()
    local first = nil
    for _, c in ipairs(FindAllOf("BuildModeComponent") or {}) do
        if Valid(c) and not NameOf(c):find("^Default__") then
            first = first or c
            local owner = nil
            pcall(function() owner = c:GetOwner() end)
            if Valid(owner) and Valid(pc) and (owner:GetAddress() == pc:GetAddress()
                or (Valid(pc.Pawn) and owner:GetAddress() == pc.Pawn:GetAddress())) then
                Ghost.Comp = c
                return c
            end
        end
    end
    Ghost.Comp = first
    return first
end

-- The build helper actor the game moves to the placement spot, while placing.
local function PlacementHelper()
    local comp = PlayerBuildComp()
    if not comp then return nil end
    if not Weak(comp.CurrentlyPlacingPieceData) then return nil end
    return Weak(comp.BuildingHelperActor)
end

local function GhostMaterial()
    local m = nil
    pcall(function() m = StaticFindObject("/Script/Dominion.Default__BuildingSettings").LoadedGhostMaterial end)
    return Valid(m) and m or nil
end

local function HideGhost()
    if Valid(Ghost.Actor) then pcall(function() Ghost.Actor:SetActorHiddenInGame(true) end) end
end

local function DestroyGhost()
    if Valid(Ghost.Actor) then pcall(function() Ghost.Actor:K2_DestroyActor() end) end
    Ghost.Actor, Ghost.Mesh = nil, nil
end

-- The mod's own placer: while a model is picked, its see-through copy follows the
-- surface under the crosshair (a line trace from the camera). Left click places the
-- real model there; no game building piece is involved, so no base object, no
-- foundation rules and no material cost.
local Placer = { Yaw = 0, Spot = nil, TraceNoted = false }


-- Surface point under the crosshair within Config.PlaceDistance, or nil.
local function CrosshairHit()
    local pc, loc, rot, fwd = CameraView()
    if not pc then return nil end
    local start = { X = loc.X + fwd.X * 30, Y = loc.Y + fwd.Y * 30, Z = loc.Z + fwd.Z * 30 }
    local finish = { X = loc.X + fwd.X * Config.PlaceDistance, Y = loc.Y + fwd.Y * Config.PlaceDistance,
        Z = loc.Z + fwd.Z * Config.PlaceDistance }
    local ignore = {}
    local _, pawn = Pawn()
    if pawn then ignore = { pawn } end
    local hit = {}
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local ok, res = pcall(function()
        return ksl:LineTraceSingle(pc, start, finish, 0, false, ignore, 0, hit, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    end)
    local p = nil
    pcall(function() p = hit.ImpactPoint or hit.Location end)
    if not Placer.TraceNoted then
        Placer.TraceNoted = true
        local keys = {}
        for k in pairs(hit) do keys[#keys + 1] = tostring(k) end
        Log(string.format("[DISCOVERY] crosshair trace: ok=%s hit=%s point=%s fields=%s", tostring(ok),
            tostring(res), tostring(p ~= nil), table.concat(keys, ",")))
    end
    if not ok or not res or not p or not p.X then return nil end
    local actor = nil
    pcall(function()
        -- The hit component comes back as a weak reference; resolve it first.
        local c = hit.Component
        local resolved = Weak(c)
        if resolved then c = resolved end
        if Valid(c) then
            local o = c:GetOwner()
            if Valid(o) then actor = o end
        end
    end)
    return { X = p.X, Y = p.Y, Z = p.Z }, rot, actor
end

-- =========================================================================
-- Snapping (End cycles the mode while placing):
--   EDGES: flush against the side or top of a nearby custom model, same rotation.
--   GRID : 50 cm grid lined up with the nearest game building piece,
--          turning in 15 degree steps from that piece's direction.
--   FREE : exactly where you aim.
-- In every mode the model's bottom sits on the surface you aim at (when not tilted).
-- =========================================================================
local SNAP_MODES = { "EDGES", "GRID", "FREE" }
Placer.Snap = 1

local BoundsCache = {}
local function MeshBounds(meshPath)
    local b = BoundsCache[meshPath]
    if b then return b end
    local mesh = LoadMesh(meshPath)
    if not mesh then return nil end
    local ok, bb = pcall(function() return mesh:GetBounds() end)
    if not ok or not bb then return nil end
    local okRead = pcall(function()
        b = { O = { X = bb.Origin.X, Y = bb.Origin.Y, Z = bb.Origin.Z },
              E = { X = bb.BoxExtent.X, Y = bb.BoxExtent.Y, Z = bb.BoxExtent.Z } }
    end)
    if not okRead then return nil end
    BoundsCache[meshPath] = b
    return b
end

-- Engine vectors copied into plain tables right away (nil if any part is missing).
local function V(v)
    local t = nil
    pcall(function() t = { X = v.X, Y = v.Y, Z = v.Z } end)
    if t and type(t.X) == "number" and type(t.Y) == "number" and type(t.Z) == "number" then return t end
    return nil
end

-- Nearest game building piece (position and yaw), refreshed at most twice a second.
local PieceCache = { At = -1, Near = nil }
OnWorldChange[#OnWorldChange + 1] = function() PieceCache.Manager, PieceCache.Near = nil, nil end
local function NearestGamePiece(p)
    local now = os.clock()
    if now - PieceCache.At < 0.5 and PieceCache.Near then return PieceCache.Near end
    PieceCache.At = now
    -- The manager is looked up once per world, not on every tick.
    if not Valid(PieceCache.Manager) then
        PieceCache.Manager = nil
        for _, g in ipairs(FindAllOf("GlobalBuildingManager") or {}) do
            if Valid(g) and not NameOf(g):find("^Default__") then PieceCache.Manager = g; break end
        end
    end
    local m = PieceCache.Manager
    if not m then return nil end
    local best, bestD = nil, 1500
    pcall(function()
        m.BuildingPieces:ForEach(function(_, state)
            local s = Get(state)
            local cv = s.ClientVisible
            local l = cv.Location
            local d = Dist(l, p)
            if d < bestD then best, bestD = { X = l.X, Y = l.Y, Z = l.Z, Yaw = cv.Yaw }, d end
        end)
    end)
    PieceCache.Near = best
    return best
end

-- Returns the snapped pivot, yaw, pitch, roll (or nil to use the plain spot).
local function SnapSpot(p, yaw, o, fine)
    local function Add(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
    local function Sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
    local function Mul(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end
    local function ToWorld(f, r, u, v)
        return { X = f.X * v.X + r.X * v.Y + u.X * v.Z, Y = f.Y * v.X + r.Y * v.Y + u.Y * v.Z,
                 Z = f.Z * v.X + r.Z * v.Y + u.Z * v.Z }
    end
    local mode = SNAP_MODES[Placer.Snap]
    local sb = MeshBounds(Skin.Mesh)
    local ss = o.Scale
    local upright = (o.Pitch % 360 == 0) and (o.Roll % 360 == 0)

    -- The picked model turned by the player relative to the model it snaps to.
    local rel = math.rad(Placer.Yaw % 360)
    local rc, rs = math.cos(rel), math.sin(rel)
    local sE = sb and { X = math.abs(sb.E.X * rc) + math.abs(sb.E.Y * rs), Y = math.abs(sb.E.X * rs) + math.abs(sb.E.Y * rc), Z = sb.E.Z }
    local sO = sb and { X = sb.O.X * rc - sb.O.Y * rs, Y = sb.O.X * rs + sb.O.Y * rc, Z = sb.O.Z }
    if mode == "EDGES" and sb then
        local best, bestD = nil, math.huge
        for id, r in pairs(Placed) do
            local a = Props[id]
            if Valid(a) then
                local l = V(a:K2_GetActorLocation())
                if l and Dist(l, p) < 3000 then
                    local nb = MeshBounds(r.Mesh)
                    if nb then
                        local ns = r.Scale or 1
                        local f, rt, u = V(a:GetActorForwardVector()), V(a:GetActorRightVector()), V(a:GetActorUpVector())
                        if f and rt and u then
                        local same = r.Mesh == Skin.Mesh
                        local centreN = Add(l, ToWorld(f, rt, u, Mul(nb.O, ns)))
                        local originS = ToWorld(f, rt, u, Mul(sO, ss))
                        for _, side in ipairs({
                            { f, nb.E.X * ns + sE.X * ss }, { Mul(f, -1), nb.E.X * ns + sE.X * ss },
                            { rt, nb.E.Y * ns + sE.Y * ss }, { Mul(rt, -1), nb.E.Y * ns + sE.Y * ss },
                            { u, nb.E.Z * ns + sE.Z * ss },
                        }) do
                            local centre = Add(centreN, Mul(side[1], side[2]))
                            local d = Dist(centre, p)
                            local reach = math.max(sb.E.X, sb.E.Y, sb.E.Z) * ss * 1.2 + 50
                            if d < bestD and d < reach then
                                local rot = a:K2_GetActorRotation()
                                bestD = d
                                best = { Pivot = Sub(centre, originS), Yaw = (rot.Yaw + Placer.Yaw) % 360,
                                         Pitch = same and rot.Pitch or o.Pitch, Roll = same and rot.Roll or o.Roll }
                            end
                        end
                        end
                    end
                end
            end
        end
        if best then return best.Pivot, best.Yaw, best.Pitch, best.Roll end
    end

    local pivot = { X = p.X, Y = p.Y, Z = p.Z }
    if mode == "GRID" then
        local piece = NearestGamePiece(p)
        local step = fine and 25 or 50
        local gyaw = piece and piece.Yaw or 0
        local origin = piece or { X = 0, Y = 0, Z = 0 }
        -- Snap in the piece's own axes, then back to world.
        local c, s = math.cos(math.rad(gyaw)), math.sin(math.rad(gyaw))
        local dx, dy = p.X - origin.X, p.Y - origin.Y
        local lx, ly = dx * c + dy * s, -dx * s + dy * c
        lx, ly = math.floor(lx / step + 0.5) * step, math.floor(ly / step + 0.5) * step
        pivot.X, pivot.Y = origin.X + lx * c - ly * s, origin.Y + lx * s + ly * c
        yaw = gyaw + math.floor(((yaw - gyaw) % 360) / 15 + 0.5) * 15
    end
    -- Sit the model's bottom on the surface.
    if sb and upright then pivot.Z = pivot.Z - (sb.O.Z - sb.E.Z) * ss end
    return pivot, yaw, o.Pitch, o.Roll
end

local function UpdateGhost()
    local p, rot = CrosshairHit()
    if not p then Placer.Spot = nil; HideGhost(); return end
    local o = OrientFor(Skin.Mesh)
    -- Facing the player by default; Left/Right turn it from there.
    local yaw = (rot.Yaw + 180 + Placer.Yaw) % 360
    local pivot, syaw, spitch, sroll = SnapSpot(p, yaw, o, false)
    -- Nudge (Alt + arrows, Alt + /-), relative to where the camera looks.
    local nd = Placer.Nudge
    if nd then
        local cy = math.rad(rot.Yaw)
        pivot = { X = pivot.X + math.cos(cy) * nd.F - math.sin(cy) * nd.R,
                  Y = pivot.Y + math.sin(cy) * nd.F + math.cos(cy) * nd.R, Z = pivot.Z + nd.U }
    end
    Placer.Spot = { X = pivot.X, Y = pivot.Y, Z = pivot.Z, Yaw = syaw, Pitch = spitch, Roll = sroll }
    if not Valid(Ghost.Actor) or Ghost.Mesh ~= Skin.Mesh then
        DestroyGhost()
        local a = SpawnModel(Skin.Mesh, { X = p.X, Y = p.Y, Z = p.Z }, true)
        if not a then return end
        local c = a.StaticMeshComponent or a.SkeletalMeshComponent
        if Valid(c) then
            pcall(function() c:SetCollisionEnabled(0) end)
            pcall(function() c:SetCastShadow(false) end)
            local mat = GhostMaterial()
            if mat then
                local n = 1
                pcall(function() n = c:GetNumMaterials() end)
                for i = 0, n - 1 do pcall(function() c:SetMaterial(i, mat) end) end
            end
        end
        Ghost.Actor, Ghost.Mesh = a, Skin.Mesh
    end
    pcall(function() Ghost.Actor:SetActorHiddenInGame(false) end)
    Ghost.Actor:K2_SetActorLocationAndRotation({ X = pivot.X, Y = pivot.Y, Z = pivot.Z + Config.ZOffset },
        { Pitch = spitch, Yaw = syaw, Roll = sroll }, false, {}, true)
    pcall(function() Ghost.Actor:SetActorScale3D({ X = o.Scale, Y = o.Scale, Z = o.Scale }) end)
end

-- =========================================================================
-- Teleporters / Portals
-- Touching a portal teleports the player to its paired destination portal.
-- =========================================================================
local PortalCooldownUntil = 0
local LastTeleportedPortal = nil

local function CheckPortals()
    if not Placed or not CheckWorld() then return end
    local pc, pawn = Pawn()
    if not Valid(pawn) or not Valid(pc) or IsGamePaused(pc) then return end

    local now = os.clock()
    local pLoc = pawn:K2_GetActorLocation()
    if not pLoc then return end

    -- Clear departure portal lockout once player moves away (> 2.8m) from exit portal
    if LastTeleportedPortal then
        local lastRec = nil
        for _, rec in pairs(Placed) do
            if rec.Portal and rec.Portal:lower() == LastTeleportedPortal:lower() then
                lastRec = rec; break
            end
        end
        if lastRec then
            local dx = pLoc.X - lastRec.X
            local dy = pLoc.Y - lastRec.Y
            if (dx*dx + dy*dy) > 78400 then
                LastTeleportedPortal = nil
            end
        else
            LastTeleportedPortal = nil
        end
    end

    for id, r in pairs(Placed) do
        if r.Portal and r.Portal ~= "" then
            -- Clean up legacy cylinder FX if present
            local oldFx = Props[id .. "_fx"]
            if Valid(oldFx) then
                pcall(function() oldFx:K2_DestroyActor() end)
                Props[id .. "_fx"] = nil
            end

            -- Spawn two Campfire 01 Ashes back-to-back scaled up floating above the portal
            if not r.Mesh:find("SM_Campfire_01_Ashes") then
                local fxKey1 = id .. "_fx1"
                local fxKey2 = id .. "_fx2"
                if not Valid(Props[fxKey1]) or not Valid(Props[fxKey2]) then
                    local yaw = 0
                    if r.QW and r.QZ then
                        local atan = math.atan2 or math.atan
                        yaw = math.deg(2 * atan(r.QZ, r.QW))
                    end
                    local rad = math.rad(yaw)
                    local fwdX = math.cos(rad)
                    local fwdY = math.sin(rad)
                    local s = (r.Scale or 1) * 1.95
                    local z = r.Z + 120
                    local ashesMesh = "/Game/Art/Env/Props/Env_Props/Human_Props/Campsite/SM_Campfire_01_Ashes.SM_Campfire_01_Ashes"

                    if not Valid(Props[fxKey1]) then
                        local r1 = { X = r.X - fwdX * 8, Y = r.Y - fwdY * 8, Z = z, Pitch = -90, Roll = 0, Yaw = yaw, Scale = s }
                        local a1 = SpawnModel(ashesMesh, r1)
                        if a1 then Props[fxKey1] = a1 end
                    end
                    if not Valid(Props[fxKey2]) then
                        local r2 = { X = r.X + fwdX * 8, Y = r.Y + fwdY * 8, Z = z, Pitch = 90, Roll = 0, Yaw = yaw, Scale = s }
                        local a2 = SpawnModel(ashesMesh, r2)
                        if a2 then Props[fxKey2] = a2 end
                    end
                end
            end

            if r.Target and r.Target ~= "" then
                local dx = pLoc.X - r.X
                local dy = pLoc.Y - r.Y
                local dz = pLoc.Z - r.Z
                local hDist2 = dx*dx + dy*dy

                -- Generous 2.5m (250cm) horizontal touch radius and vertical tolerance
                if hDist2 <= 62500 and dz >= -60 and dz <= 350 then
                    local isRecent = LastTeleportedPortal and LastTeleportedPortal:lower() == r.Portal:lower()
                    if not isRecent and now >= PortalCooldownUntil then
                        -- Find paired destination portal
                        local targetRec, targetId = nil, nil
                        for tid, tr in pairs(Placed) do
                            if tr.Portal and (tr.Portal:lower() == r.Target:lower() or tid == r.Target) then
                                targetRec = tr
                                targetId = tid
                                break
                            end
                        end

                        if targetRec then
                            local destYaw = 0
                            if targetRec.QW and targetRec.QZ then
                                local atan = math.atan2 or math.atan
                                destYaw = math.deg(2 * atan(targetRec.QZ, targetRec.QW))
                            end

                            local rad = math.rad(destYaw)
                            local exitX = targetRec.X + math.cos(rad) * 120
                            local exitY = targetRec.Y + math.sin(rad) * 120
                            local exitZ = targetRec.Z + 130

                            local teleported = false

                            -- Attempt 1: K2_TeleportTo with forward offset and safe +130cm capsule height
                            local ok1, res1 = pcall(function()
                                return pawn:K2_TeleportTo({ X = exitX, Y = exitY, Z = exitZ }, { Pitch = 0, Yaw = destYaw, Roll = 0 })
                            end)
                            if ok1 and res1 ~= false then
                                teleported = true
                            end

                            -- Attempt 2: Directly above destination center at +140cm
                            if not teleported then
                                local ok2, res2 = pcall(function()
                                    return pawn:K2_TeleportTo({ X = targetRec.X, Y = targetRec.Y, Z = targetRec.Z + 140 }, { Pitch = 0, Yaw = destYaw, Roll = 0 })
                                end)
                                if ok2 and res2 ~= false then
                                    teleported = true
                                end
                            end

                            -- Attempt 3: K2_SetActorLocation (non-swept, guarantees placement through any geometry)
                            if not teleported then
                                local ok3 = pcall(function()
                                    pawn:K2_SetActorLocation({ X = targetRec.X, Y = targetRec.Y, Z = targetRec.Z + 140 }, false, nil, true)
                                    pawn:K2_SetActorRotation({ Pitch = 0, Yaw = destYaw, Roll = 0 }, false)
                                end)
                                if ok3 then
                                    teleported = true
                                end
                            end

                            if teleported then
                                pcall(function()
                                    pc:SetControlRotation({ Pitch = 0, Yaw = destYaw, Roll = 0 })
                                end)
                                pcall(function()
                                    if Valid(pawn.CharacterMovement) then
                                        pawn.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
                                    end
                                end)

                                PortalCooldownUntil = now + 1.5
                                LastTeleportedPortal = targetRec.Portal
                                Say(string.format("Portal: teleported from '%s' to '%s'", r.Portal, targetRec.Portal or r.Target))
                                return
                            else
                                Log(string.format("Portal: teleport failed from '%s' to '%s'", r.Portal, r.Target))
                            end
                        else
                            Log(string.format("Portal '%s' target '%s' not found", r.Portal, r.Target))
                        end
                    end
                end
            end
        end
    end
end

-- One permanent game-thread loop (UE4SS's own looping timer, created once when the
-- mod loads) drives the ghost; it does nothing unless a model is picked. Creating new
-- timers from inside timer callbacks, as this used to, corrupted UE4SS's timer list
-- and crashed the game.
local GhostLoop = nil

local function GhostStep()
    local pc = GetPC()
    if not Valid(pc) then return end

    local now = os.clock()
    if now - SyncAt > 2 then
        SyncAt = now
        if CheckWorld() then
            local ok, err = pcall(SyncPlaced)
            if not ok then Log("Sync: " .. tostring(err)) end
        end
    end
    pcall(function() if UpdateQuestWorldMarkers then UpdateQuestWorldMarkers() end end)
    local pok, perr = pcall(CheckPortals)
    if not pok then Log("Portal error: " .. tostring(perr)) end

    if IsGamePaused(pc) then return end
    if not Skin then
        -- CheckWorld first: after a world change the old ghost is gone and must not be touched.
        if Ghost.Actor and CheckWorld() then DestroyGhost() end
        return
    end
    if not CheckWorld() then return end
    local ok, err = pcall(UpdateGhost)
    if not ok then Log("Ghost: " .. tostring(err)) end
end

local function StartGhost()
    Ghost.Comp, Ghost.Warned = nil, false
end

local PlaceCount = 0

-- Places the picked model where the ghost is. Returns a message.
-- Undo history (Backspace): the latest place, delete or move first.
local History = {}
local function Remember(entry)
    History[#History + 1] = entry
    if #History > 50 then table.remove(History, 1) end
end

local function PlaceNow()
    if not Skin then return nil end
    local s = Placer.Spot
    if not s then return "Nothing under the crosshair within reach" end
    PlaceCount = PlaceCount + 1
    local key = string.format("m%d%03d", os.time(), PlaceCount % 1000)
    local o = OrientFor(Skin.Mesh)
    local half = math.rad(s.Yaw) / 2
    local r = { X = s.X, Y = s.Y, Z = s.Z, QX = 0, QY = 0, QZ = math.sin(half), QW = math.cos(half),
        Mesh = Skin.Mesh, Pitch = s.Pitch or o.Pitch, Roll = s.Roll or o.Roll, Scale = o.Scale }
    local a, why = SpawnModel(r.Mesh, r)
    if not a then return "Could not place: " .. tostring(why) end
    Props[key], Placed[key] = a, r
    Order[#Order + 1] = key
    SavePlaced()
    Placer.LastKey = key
    return "Placed " .. Skin.Name
end

-- The placed custom model nearest the point under the crosshair (within `radius` cm).
local function FindLookedAt(radius)
    local p, _, actor = CrosshairHit()
    if not p then return nil end
    -- Exactly the model under the crosshair, if the trace hit one of ours.
    if actor then
        local addr = actor:GetAddress()
        for id, a in pairs(Props) do
            if Valid(a) and a:GetAddress() == addr and Placed[id] then return id end
        end
    end
    local best, bestD = nil, radius or 300
    for id, r in pairs(Placed) do
        local a = Props[id]
        local loc = Valid(a) and a:K2_GetActorLocation() or r
        local d = Dist(loc, p)
        if d < bestD then best, bestD = id, d end
    end
    return best
end

local function RemoveLookedAt(radius)
    local id = FindLookedAt(radius)
    if not id then return nil end
    Remember({ Kind = "delete", Id = id, R = Placed[id] })
    DestroyProp(id)
    Placed[id] = nil
    SavePlaced()
    return "Removed the model"
end

local function ModelForMesh(mesh)
    for _, list in ipairs({ Models, AllModels }) do
        for _, m in ipairs(list) do if m.Mesh == mesh then return m end end
    end
    return { Name = PrettyName and PrettyName(mesh) or mesh:match("([^/%.]+)%.[^/]*$") or mesh, Mesh = mesh }
end

-- A piece was taken down or destroyed: tidy up its model.
pcall(function()
    RegisterHook("/Script/Dominion.CellBuildingManager:NetMulticast_PlayDestructionSFX", function(self, index, location)
        CheckWorld()
        local at = nil
        pcall(function()
            local l = Get(location)
            at = { X = l.X, Y = l.Y, Z = l.Z }
        end)
        if not at then return end
        Later(500, function() pcall(Restore, at) end)
    end)
end)

-- World loaded: put the recorded models back.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
    pcall(function()
        local pc = self:get()
        if Valid(pc) and pc:IsLocalPlayerController() then MyPC = pc end
    end)
    CheckWorld()
    Later(5000, function()
        StartHideTimer()
        if Skin then StartGhost() end
        -- Props from a previous world are no longer valid, so Restore respawns them;
        -- after a respawn in the same world they still are and are left alone.
        local ok, spawned, removed = pcall(Restore)
        if ok and (spawned > 0 or removed > 0) then
            Log(string.format("Restored %d models (%d whose piece is gone removed)", spawned, removed))
        elseif not ok then
            Log("Restore error: " .. tostring(spawned))
        end
    end)
end)

local ShowHint, HideHint   -- defined with the adjust keys below
local MenuProbeFn = nil   -- set below; runs once when the build menu first opens
local MenuProbed = false

-- =========================================================================
-- Model browser: a panel of the game's own buttons shown next to the build menu
-- while it is open. Click a model to pick it; the mod then selects the base
-- decoration (Config.BasePiece) so placement starts straight away.
-- =========================================================================
local BUTTON_CLASS = "/Game/UI/Common/WBP_DomAllCapsButton.WBP_DomAllCapsButton_C"
local LABEL_CLASS = "/Game/UI/Common/WBP_MainMenuTabButton.WBP_MainMenuTabButton_C"
local VISIBLE, COLLAPSED = 0, 1
local PER_PAGE = 16
local TILE_CLASS = "/Game/UI/Building/GridNav/WBP_BuildingCategoryItemSlot.WBP_BuildingCategoryItemSlot_C"
local TILES_PER_PAGE = 32

local UI = { Built = false, Visible = false, Title = nil, Category = nil, Rows = {}, RowModel = {},
    Prev = nil, Next = nil, Off = nil, Import = nil, Page = 1, Cat = 1, Owned = {}, Tiles = {}, TileModel = {} }

OnWorldChange[#OnWorldChange + 1] = function()
    -- The widgets belonged to the old world's player and went with it.
    UI.Built, UI.Visible, UI.Title, UI.Category, UI.Rows, UI.RowModel = false, false, nil, nil, {}, {}
    UI.Prev, UI.Next, UI.Off, UI.Import, UI.SearchBtn, UI.Owned = nil, nil, nil, nil, nil, {}
    UI.Tiles, UI.TileModel = {}, {}
    UI.Header, UI.CatPrev, UI.CatNext = nil, nil, nil
    UI.Backdrop = nil
    UI.SearchMode, UI.SearchQuery = false, ""
end

-- Widgets left behind by a previous load of this mod (hot reload).
if ModRef then
    local recorded = nil
    pcall(function() recorded = ModRef:GetSharedVariable(ModName .. ".UI") end)
    if type(recorded) == "string" and recorded ~= "" then
        local names = {}
        for n in recorded:gmatch("[^|]+") do names[n] = true end
        ExecuteInGameThread(function()
            for _, cls in ipairs({ "WBP_DomAllCapsButton_C", "WBP_MainMenuTabButton_C", "WBP_BuildingCategoryItemSlot_C", "WBP_Panel_Building_C", "WBP_Panel_C" }) do
                for _, w in ipairs(FindAllOf(cls) or {}) do
                    if Valid(w) and names[w:GetFullName()] then pcall(function() w:RemoveFromParent() end) end
                end
            end
        end)
    end
end

local function Text(s)
    return StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(s)
end

-- Two levels: a list of categories (Favourites = models.txt, Search results, then
-- the viewer's folders), and the models of the chosen category.
local SEARCH, FAVOURITES = "SEARCH RESULTS", "FAVOURITES"
local RECENT, PLACED_IN_WORLD = "RECENT", "PLACED IN WORLD"
local SearchResults = {}

-- Recent models: the last 8 unique models placed (newest first).
local RecentModels = {}
local MAX_RECENT = 8
local function AddRecent(m)
    if not m or not m.Mesh then return end
    -- Remove any existing entry for this mesh so it moves to the front.
    for i = #RecentModels, 1, -1 do
        if RecentModels[i].Mesh == m.Mesh then table.remove(RecentModels, i) end
    end
    table.insert(RecentModels, 1, m)
    while #RecentModels > MAX_RECENT do table.remove(RecentModels) end
end

-- Placed in World: returns models currently placed, deduped for the category list
-- but full list for tiles.
local function PlacedModels()
    local out = {}
    local seen = {}
    for _, id in ipairs(Order) do
        local r = Placed[id]
        if r and not seen[r.Mesh] then
            seen[r.Mesh] = true
            out[#out + 1] = ModelForMesh(r.Mesh)
        end
    end
    -- Also pick up entries not in Order (loaded from save).
    for id, r in pairs(Placed) do
        if not seen[r.Mesh] then
            seen[r.Mesh] = true
            out[#out + 1] = ModelForMesh(r.Mesh)
        end
    end
    return out
end

local QUICK_FILTERS = {
    { Name = "★ BONES & SKULLS", Query = "bone" },
    { Name = "★ ROCKS & STONES", Query = "rock" },
    { Name = "★ TREES & WOOD", Query = "tree" },
    { Name = "★ WALLS & FLOORS", Query = "wall" },
    { Name = "★ LIGHTS & TORCHES", Query = "light" },
    { Name = "★ CHESTS & CRATES", Query = "chest" },
    { Name = "★ STATUES & RUINS", Query = "statue" },
    { Name = "★ DOORS & GATES", Query = "door" },
}
local ActiveFilterIdx = 0

-- Pre-cached filter lists so clicking a filter is instantaneous
local FilterCache = {}
local function ModelsForFilter(query)
    if FilterCache[query] then return FilterCache[query] end
    local needle = query:lower()
    local out = {}
    local seen = {}
    for _, list in ipairs({ Models, AllModels }) do
        for _, m in ipairs(list) do
            if not seen[m.Mesh] then
                if m.Name:lower():find(needle, 1, true) or m.Mesh:lower():find(needle, 1, true) then
                    seen[m.Mesh] = true
                    out[#out + 1] = m
                end
            end
        end
    end
    FilterCache[query] = out
    return out
end

local function Groups()
    local counts, list = {}, {}
    -- Recent first (if any).
    if #RecentModels > 0 then list[#list + 1] = { Name = RECENT, Count = #RecentModels } end
    if #Models > 0 then list[#list + 1] = { Name = FAVOURITES, Count = #Models } end
    if UI.Search then list[#list + 1] = { Name = SEARCH, Count = #SearchResults } end
    -- Placed in World.
    local placedList = PlacedModels()
    if #placedList > 0 then list[#list + 1] = { Name = PLACED_IN_WORLD, Count = #placedList } end
    -- Quick Search Filters directly in the categories list
    for _, qf in ipairs(QUICK_FILTERS) do
        local matches = ModelsForFilter(qf.Query)
        if #matches > 0 then
            list[#list + 1] = { Name = qf.Name, Count = #matches, FilterQuery = qf.Query }
        end
    end
    for _, m in ipairs(AllModels) do counts[m.Group] = (counts[m.Group] or 0) + 1 end
    local names = {}
    for g in pairs(counts) do names[#names + 1] = g end
    table.sort(names)
    for _, g in ipairs(names) do list[#list + 1] = { Name = g, Count = counts[g] } end
    return list
end

local function ModelsIn(group)
    if group == FAVOURITES then return Models end
    if group == SEARCH then return SearchResults end
    if group == RECENT then return RecentModels end
    if group == PLACED_IN_WORLD then return PlacedModels() end
    for _, qf in ipairs(QUICK_FILTERS) do
        if group == qf.Name then return ModelsForFilter(qf.Query) end
    end
    local out = {}
    for _, m in ipairs(AllModels) do
        if m.Group == group then out[#out + 1] = m end
    end
    return out
end

local function Search(text)
    local needle = text:lower()
    SearchResults = {}
    for _, list in ipairs({ Models, AllModels }) do
        for _, m in ipairs(list) do
            if m.Name:lower():find(needle, 1, true) or m.Mesh:lower():find(needle, 1, true) then
                SearchResults[#SearchResults + 1] = m
            end
        end
    end
    UI.Search = text
    UI.Group, UI.Page = SEARCH, 1
    return #SearchResults
end

local function NewWidget(pc, path, z)
    local cls = StaticFindObject(path)
    if not Valid(cls) and LoadAsset then
        pcall(LoadAsset, path)
        cls = StaticFindObject(path)
        if not Valid(cls) then
            pcall(LoadAsset, (path:gsub("%.[^/]+$", "")))   -- package path form
            cls = StaticFindObject(path)
        end
    end
    if not Valid(cls) then error("widget class not available: " .. path) end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local w = lib:Create(pc, cls, pc)
    if not Valid(w) then error("could not create " .. path) end
    w:SetIsFocusable(false)
    w:SetVisibility(COLLAPSED)
    w:AddToViewport(z)
    UI.Owned[#UI.Owned + 1] = w
    return w
end

local function Place(w, x, y, width, height)
    w:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
    w:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
    w:SetPositionInViewport({ X = x, Y = y }, false)
    w:SetDesiredSizeInViewport({ X = width, Y = height })
end

local function Label(w, s)
    pcall(function()
        if Valid(w.LabelText) then w.LabelText:SetText(Text(s)) else w:SetLabelText(Text(s)) end
    end)
end

-- A game panel as the window background, so the text reads over any scene. The panel
-- classes load when the game first shows them, so this is retried each time the
-- window opens until one works.
-- The window background: the mod's own dark, gold-framed panel picture (ui\panel.png)
-- shown on a spare build-menu tile widget stretched behind the window. (The game's
-- panel widgets can't be created on demand, so the mod draws its own.)
local function LoadModTexture(rel)
    local path = ModDir .. rel
    local f = io.open(path, "rb")
    if not f and rel:sub(-4) == ".png" then
        local txtPath = ModDir .. rel:sub(1, -5) .. ".txt"
        f = io.open(txtPath, "rb")
        if f then path = txtPath end
    end
    if not f then return nil end
    f:close()
    local full = path
    pcall(function()
        local abs = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ConvertToAbsolutePath(path)
        if abs and abs.ToString then abs = abs:ToString() end
        if type(abs) == "string" and abs ~= "" then full = abs end
    end)
    local ok, t = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(GetPC(), full)
    end)
    Log("[TEXTURE_LOAD] Path: " .. path .. " | ok=" .. tostring(ok) .. " | valid=" .. tostring(ok and Valid(t)))
    return (ok and Valid(t)) and t or nil
end

local function EnsureBackdrop(pc)
    if Valid(UI.Backdrop) then return end
    UI.Backdrop, UI.BackdropBox, UI.BackdropImg = nil, nil, nil
    local tex = LoadModTexture("ui/panel.png")
    if not tex then
        if not UI.BackdropNoted then UI.BackdropNoted = true; Log("[DISCOVERY] ui/panel.png missing or not loadable") end
        return
    end
    local ok, w = pcall(NewWidget, pc, TILE_CLASS, 10040)
    if not ok or not Valid(w) then
        if not UI.BackdropNoted then UI.BackdropNoted = true; Log("[DISCOVERY] No widget for the window background: " .. tostring(w)) end
        return
    end
    local img = nil
    pcall(function() img = w.ItemImage end)
    if not Valid(img) then return end
    UI.PanelTex = tex   -- keep a reference
    pcall(function()
        img:SetBrushFromTexture(tex, false)
        img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 })
        -- Set 9-slice box drawing so the gold corners stay crisp
        if img.Brush then
            img.Brush.DrawAs = 1 -- Box (9-slice)
            img.Brush.Margin = { Left = 0.08, Top = 0.08, Right = 0.08, Bottom = 0.08 }
        end
    end)
    pcall(function() if Valid(w.NewBuildingPieceIcon) then w.NewBuildingPieceIcon:SetVisibility(COLLAPSED) end end)
    pcall(function() if Valid(w.IconFavourited) then w.IconFavourited:SetVisibility(COLLAPSED) end end)
    -- Find any SizeBox in the widget hierarchy
    UI.BackdropBoxes = {}
    pcall(function()
        local function check(node)
            if not Valid(node) then return end
            if node.SetWidthOverride or node.WidthOverride ~= nil then
                UI.BackdropBoxes[#UI.BackdropBoxes + 1] = node
            end
        end
        local p = img
        while Valid(p) do
            check(p)
            p = pcall(function() return p:GetParent() end) and p:GetParent() or nil
        end
        if Valid(w.WidgetTree) and Valid(w.WidgetTree.RootWidget) then
            check(w.WidgetTree.RootWidget)
            local root = w.WidgetTree.RootWidget
            local n = pcall(function() return root:GetChildrenCount() end) and root:GetChildrenCount() or 0
            for i = 0, n - 1 do
                pcall(function() check(root:GetChildAt(i)) end)
            end
        end
    end)
    UI.BackdropImg = img
    UI.Backdrop = w
end

-- A free-standing panel (for dialog and hint bars): { W = widget, Img, Boxes }.
local function MakePanel(pc, z)
    local tex = LoadModTexture("ui/panel.png")
    if not tex then return nil end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local cls = StaticFindObject(TILE_CLASS)
    if not Valid(cls) then return nil end
    local w = lib:Create(pc, cls, pc)
    if not Valid(w) then return nil end
    w:SetIsFocusable(false)
    w:AddToViewport(z)
    local p = { W = w, Tex = tex }
    pcall(function()
        p.Img = w.ItemImage
        p.Img:SetBrushFromTexture(tex, false)
        p.Img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 })
        if p.Img.Brush then
            p.Img.Brush.ImageSize = { X = 512, Y = 512 }
            p.Img.Brush.DrawAs = 1 -- Box (9-slice)
            p.Img.Brush.Margin = { Left = 0.08, Top = 0.08, Right = 0.08, Bottom = 0.08 }
        end
    end)
    pcall(function() if Valid(w.NewBuildingPieceIcon) then w.NewBuildingPieceIcon:SetVisibility(COLLAPSED) end end)
    pcall(function() if Valid(w.IconFavourited) then w.IconFavourited:SetVisibility(COLLAPSED) end end)
    p.Boxes = {}
    pcall(function()
        local function check(node)
            if not Valid(node) then return end
            if node.SetWidthOverride or node.WidthOverride ~= nil then
                p.Boxes[#p.Boxes + 1] = node
            end
        end
        local node = p.Img
        while Valid(node) do
            check(node)
            node = pcall(function() return node:GetParent() end) and node:GetParent() or nil
        end
        if Valid(w.WidgetTree) and Valid(w.WidgetTree.RootWidget) then
            check(w.WidgetTree.RootWidget)
            local root = w.WidgetTree.RootWidget
            local n = pcall(function() return root:GetChildrenCount() end) and root:GetChildrenCount() or 0
            for i = 0, n - 1 do
                pcall(function() check(root:GetChildAt(i)) end)
            end
        end
    end)
    return p
end

local function SizePanel(p, x, y, w, h)
    if not p or not Valid(p.W) then return end
    local cx = x + w / 2
    local cy = y + h / 2
    p.W:SetAlignmentInViewport({ X = 0.5, Y = 0.5 })
    p.W:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
    p.W:SetPositionInViewport({ X = cx, Y = cy }, false)
    p.W:SetDesiredSizeInViewport({ X = 512, Y = 512 })
    if p.Boxes then
        for _, box in ipairs(p.Boxes) do
            pcall(function()
                box.bOverride_Width = true
                box.bOverride_Height = true
                box:SetWidthOverride(512)
                box:SetHeightOverride(512)
            end)
        end
    end
    if Valid(p.Img) then
        pcall(function()
            p.Img:SetBrushSize({ X = 512, Y = 512 })
            if p.Img.Brush then
                p.Img.Brush.ImageSize = { X = 512, Y = 512 }
                p.Img.Brush.DrawAs = 1
                p.Img.Brush.Margin = { Left = 0.08, Top = 0.08, Right = 0.08, Bottom = 0.08 }
            end
        end)
    end
    pcall(function()
        p.W:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        p.W.RenderTransformPivot = { X = 0.5, Y = 0.5 }
        p.W:SetRenderScale({ X = w / 512, Y = h / 512 })
    end)
    pcall(function() p.W:SetVisibility(VISIBLE) end)
end

local function BuildUI(pc)
    UI.Title = NewWidget(pc, LABEL_CLASS, 10050)
    UI.Category = NewWidget(pc, LABEL_CLASS, 10050)   -- search hint / live search query
    UI.Header = NewWidget(pc, LABEL_CLASS, 10050)     -- selected category + page
    for i = 1, PER_PAGE do UI.Rows[i] = NewWidget(pc, BUTTON_CLASS, 10051) end
    UI.CatPrev = NewWidget(pc, BUTTON_CLASS, 10051)
    UI.CatNext = NewWidget(pc, BUTTON_CLASS, 10051)
    UI.SearchBtn = NewWidget(pc, BUTTON_CLASS, 10051)
    UI.Prev = NewWidget(pc, BUTTON_CLASS, 10051)
    UI.Next = NewWidget(pc, BUTTON_CLASS, 10051)
    UI.Off = NewWidget(pc, BUTTON_CLASS, 10051)
    UI.Import = NewWidget(pc, BUTTON_CLASS, 10051)
    -- The build menu's own tiles for the models (picture + the game's hover look).
    local okTiles, err = pcall(function()
        for i = 1, TILES_PER_PAGE do UI.Tiles[i] = NewWidget(pc, TILE_CLASS, 10052) end
    end)
    if not okTiles then
        UI.Tiles = {}
        Log("[DISCOVERY] Build menu tiles unavailable: " .. tostring(err))
    end
    local names = {}
    for _, w in ipairs(UI.Owned) do names[#names + 1] = w:GetFullName() end
    if ModRef then pcall(function() ModRef:SetSharedVariable(ModName .. ".UI", table.concat(names, "|")) end) end
    UI.Built = true
end

local function Layout(pc)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local size, dpi = lib:GetViewportSize(pc), lib:GetViewportScale(pc)
    local vw, vh = size.X / dpi, size.Y / dpi
    -- Compact, crisp layout that fits any screen: categories on left, tiles on right.
    local listW, rowH, h, gap = 340, 28, 42, 16
    local tileCols, tileSize = 8, 72
    local gridW = tileCols * (tileSize + 4) -- 8 * 76 = 608
    local total = listW + gap + gridW         -- 340 + 16 + 608 = 964
    local x = math.floor(vw / 2 - total / 2)
    local y = math.max(20, math.floor(vh / 2 - 350))
    local startY = y
    local xr = x + listW + gap
    Place(UI.Title, x, y, total, h); y = y + h + 4
    Place(UI.Category, x, y, listW, h)
    Place(UI.Header, xr, y, gridW, h)
    y = y + h + 8
    local top = y
    for i = 1, PER_PAGE do Place(UI.Rows[i], x, top + (i - 1) * (rowH + 2), listW, rowH) end
    local listBottom = top + PER_PAGE * (rowH + 2) + 6
    local halfW = math.floor(listW / 2 - 2)
    Place(UI.CatPrev, x, listBottom, halfW, h)
    Place(UI.CatNext, x + halfW + 4, listBottom, halfW, h)
    Place(UI.SearchBtn, x, listBottom + h + 4, listW, h)
    for i, t in ipairs(UI.Tiles) do
        local col, row = (i - 1) % tileCols, math.floor((i - 1) / tileCols)
        Place(t, xr + col * (tileSize + 4), top + row * (tileSize + 4), tileSize, tileSize)
    end
    local gy = top + TILE_ROWS * (tileSize + 4) + 10
    local third = math.floor((gridW - 8) / 3)
    Place(UI.Prev, xr, gy, third, h)
    Place(UI.Next, xr + third + 4, gy, third, h)
    Place(UI.Off, xr + 2 * (third + 4), gy, third, h)
    Place(UI.Import, xr, gy + h + 4, gridW, h)
    if Valid(UI.Backdrop) then
        local maxBottom = math.max(gy + 2 * h + 8, listBottom + 2 * h + 12)
        local targetLeft = x - 20
        local targetTop = startY - 14
        local bw = total + 40
        local bh = maxBottom - targetTop + 20
        local centerX = targetLeft + bw / 2
        local centerY = targetTop + bh / 2
        -- Center-anchored placement: alignment (0.5, 0.5) at (centerX, centerY)
        -- Scales symmetrically around center so it covers from targetLeft to targetLeft+bw
        UI.Backdrop:SetAlignmentInViewport({ X = 0.5, Y = 0.5 })
        UI.Backdrop:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        UI.Backdrop:SetPositionInViewport({ X = centerX, Y = centerY }, false)
        UI.Backdrop:SetDesiredSizeInViewport({ X = 512, Y = 512 })
        if UI.BackdropBoxes then
            for _, box in ipairs(UI.BackdropBoxes) do
                pcall(function()
                    box.bOverride_Width = true
                    box.bOverride_Height = true
                    box:SetWidthOverride(512)
                    box:SetHeightOverride(512)
                end)
            end
        end
        if Valid(UI.BackdropImg) then
            pcall(function() UI.BackdropImg:SetBrushSize({ X = 512, Y = 512 }) end)
            pcall(function()
                if UI.BackdropImg.Brush then
                    UI.BackdropImg.Brush.ImageSize = { X = 512, Y = 512 }
                    UI.BackdropImg.Brush.DrawAs = 1 -- Box (9-slice)
                    UI.BackdropImg.Brush.Margin = { Left = 0.08, Top = 0.08, Right = 0.08, Bottom = 0.08 }
                end
            end)
        end
        pcall(function()
            UI.Backdrop:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
            UI.Backdrop.RenderTransformPivot = { X = 0.5, Y = 0.5 }
            UI.Backdrop:SetRenderScale({ X = bw / 512, Y = bh / 512 })
        end)
    end
end

local BasePiece   -- defined below with the base-selection code

-- Thumbnails: CustomBuilds\thumbs\Game\...\SM_X.png (made by make-thumbs.ps1),
-- loaded on demand as textures and kept while the tile shows them.
local Thumbs = {}
local function Thumb(mesh)
    local tex = Thumbs[mesh]
    if Valid(tex) then return tex end
    local path = ModDir .. "thumbs" .. mesh:gsub("%.[^/]+$", "") .. ".png"
    local f = io.open(path, "rb")
    if not f then
        if not UI.ThumbMissNoted then UI.ThumbMissNoted = true; Log("[DISCOVERY] No thumbnail file at " .. path) end
        return nil
    end
    f:close()
    -- The engine may resolve relative paths differently from Lua, so pass an absolute one.
    local full = path
    pcall(function()
        local abs = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ConvertToAbsolutePath(path)
        if abs and abs.ToString then abs = abs:ToString() end
        if type(abs) == "string" and abs ~= "" then full = abs end
    end)
    local ok, t = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
            :ImportFileAsTexture2D(GetPC(), full)
    end)
    if ok and Valid(t) then
        if not UI.ThumbOkNoted then UI.ThumbOkNoted = true; Log("[DISCOVERY] Thumbnail loaded: " .. path) end
        Thumbs[mesh] = t
        return t
    end
    Log("[DISCOVERY] Could not load thumbnail " .. path .. ": " .. tostring(t))
    return nil
end

local function SetTile(tile, m)
    if not UI.SetTileNoted then
        UI.SetTileNoted = true
        Log(string.format("[DISCOVERY] drawing tiles: tile valid=%s ItemImage valid=%s", tostring(Valid(tile)),
            tostring(pcall(function() return Valid(tile.ItemImage) end) and Valid(tile.ItemImage))))
    end
    -- No build item on our tiles, so the game shows no (wrong) tooltip for them.
    local img = nil
    pcall(function() img = tile.ItemImage end)
    if not Valid(img) then return end
    local tex = Thumb(m.Mesh)
    if tex then
        local ok, err = pcall(function() img:SetBrushFromTexture(tex, false) end)
        img:SetVisibility(3) -- HitTestInvisible: picture only, clicks go to the tile
        pcall(function() img:SetRenderOpacity(1.0) end)
        pcall(function() img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 }) end)
        if not UI.TileNoted then
            UI.TileNoted = true
            local tw, th = -1, -1
            pcall(function() tw, th = tex:Blueprint_GetSizeX(), tex:Blueprint_GetSizeY() end)
            local vis, op = "?", "?"
            pcall(function() vis = tostring(tile:GetVisibility()); op = tostring(tile:GetRenderOpacity()) end)
            Log(string.format("[DISCOVERY] tile picture: brush set=%s %s texture %dx%d tile visibility=%s opacity=%s",
                tostring(ok), ok and "" or tostring(err), tw, th, vis, op))
        end
    else
        img:SetVisibility(COLLAPSED)
    end
    -- The game dims tiles you cannot afford; ours are always full strength.
    pcall(function() tile:SetBuildableOpacity(1.0) end)
    pcall(function() tile:SetRenderOpacity(1.0) end)
    pcall(function() if Valid(tile.NewBuildingPieceIcon) then tile.NewBuildingPieceIcon:SetVisibility(COLLAPSED) end end)
    pcall(function() if Valid(tile.IconFavourited) then tile.IconFavourited:SetVisibility(Skin == m and 3 or COLLAPSED) end end)
end

local function Refresh()
    local pc = GetPC()
    if Valid(pc) then Layout(pc) end
    local groups = Groups()
    if not UI.Group and #groups > 0 then UI.Group = groups[1].Name end
    if not UI.TilesNoted then
        UI.TilesNoted = true
        Log(string.format("[DISCOVERY] model window: %d tile widgets", #UI.Tiles))
    end
    Label(UI.Title, "CUSTOM MODELS")
    if UI.ActiveFilterName then
        Label(UI.Category, string.format("FILTER: %s (%d) | F10: cb find", UI.ActiveFilterName:gsub("^★ ", ""), #SearchResults))
    elseif UI.Search then
        Label(UI.Category, string.format("SEARCH: %s (%d) | F10: cb find", UI.Search:upper(), #SearchResults))
    else
        local total = #Models + #AllModels
        Label(UI.Category, string.format("%d MODELS | F10: cb find <word>", total))
    end

    -- Left: categories, a page at a time.
    local cpages = math.max(1, math.ceil(#groups / PER_PAGE))
    UI.CatPage = math.max(1, math.min(UI.CatPage or 1, cpages))
    UI.RowModel = {}
    for i = 1, PER_PAGE do
        local g = groups[(UI.CatPage - 1) * PER_PAGE + i]
        local row = UI.Rows[i]
        if g then
            UI.RowModel[i] = g
            -- "Env / Architecture / Human" reads as "ARCHITECTURE / HUMAN".
            local shown = g.Name:gsub("^Env / ", "")
            Label(row, string.format("%s%s  (%d)", g.Name == UI.Group and "> " or "", shown:upper(), g.Count))
            row:SetVisibility(VISIBLE)
        else
            row:SetVisibility(COLLAPSED)
        end
    end
    Label(UI.CatPrev, "< CATEGORIES")
    Label(UI.CatNext, string.format("%d/%d  CATEGORIES >", UI.CatPage, cpages))
    if UI.ActiveFilterName then
        Label(UI.SearchBtn, string.format("CYCLE: %s >", UI.ActiveFilterName:gsub("^★ ", "")))
    elseif UI.Search then
        Label(UI.SearchBtn, "FILTER: CLICK TO CYCLE")
    else
        Label(UI.SearchBtn, "FILTER: BONES, ROCKS... (CLICK)")
    end

    -- Right: the chosen category's models as build-menu tiles.
    local items = UI.Group and ModelsIn(UI.Group) or {}
    local pages = math.max(1, math.ceil(#items / TILES_PER_PAGE))
    UI.Page = math.max(1, math.min(UI.Page, pages))
    local name = UI.Group == SEARCH and ("SEARCH: " .. (UI.Search or "")) or (UI.Group or "")
    UI.HeaderText = string.format("%s   %d/%d", name:upper(), UI.Page, pages)
    Label(UI.Header, UI.HeaderText)
    UI.TileModel = {}
    for i, tile in ipairs(UI.Tiles) do
        local m = items[(UI.Page - 1) * TILES_PER_PAGE + i]
        if m then
            UI.TileModel[i] = m
            SetTile(tile, m)
            tile:SetVisibility(VISIBLE)
        else
            tile:SetVisibility(COLLAPSED)
        end
    end
    Label(UI.Prev, "< PREV")
    Label(UI.Next, "NEXT >")
    Label(UI.Off, Skin and "STOP PLACING" or "CLOSE")
    Label(UI.Import, "IMPORT STARRED FROM VIEWER")
end

-- The window can be opened outside the build menu, so it shows the mouse cursor and
-- lets the mouse reach the UI while open, and gives control back when closed.
local InputTaken = false

local function TakeMouse(pc)
    local shown = false
    pcall(function() shown = pc.bShowMouseCursor end)
    if shown then return end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok = pcall(function()
        pc.bShowMouseCursor = true
        lib:SetInputMode_GameAndUIEx(pc, nil, 0, false, false)
    end)
    InputTaken = ok
end

local function GiveMouseBack(pc)
    if not InputTaken then return end
    InputTaken = false
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    pcall(function()
        pc.bShowMouseCursor = false
        lib:SetInputMode_GameOnly(pc, false)
    end)
end

local function ShowUI()
    local pc = GetPC()
    if not Valid(pc) or #Models + #AllModels == 0 then return end
    if not UI.Built then BuildUI(pc) end
    pcall(EnsureBackdrop, pc)
    -- By name, not a list literal: a missing widget must not stop the others showing.
    for _, key in ipairs({ "Title", "Category", "Header", "CatPrev", "CatNext", "SearchBtn", "Prev", "Next", "Off", "Import" }) do
        local w = UI[key]
        if Valid(w) then w:SetVisibility(VISIBLE) end
    end
    -- The background is picture only; clicks pass through it.
    if Valid(UI.Backdrop) then
        pcall(function() UI.Backdrop:SetVisibility(3) end)
        pcall(function() UI.Backdrop:SetRenderOpacity(1.0) end)
    end
    UI.Visible = true
    Refresh()
    TakeMouse(pc)
end

local function HideUI()
    if not UI.Built then return end
    for _, w in ipairs(UI.Owned) do
        if Valid(w) then pcall(function() w:SetVisibility(COLLAPSED) end) end
    end
    UI.Visible = false
    local pc = GetPC()
    if Valid(pc) then GiveMouseBack(pc) end
end

local BasePieceCache = nil
BasePiece = function()
    if Valid(BasePieceCache) then return BasePieceCache end
    for _, d in ipairs(FindAllOf("BuildingPieceData") or {}) do
        if Valid(d) and NameOf(d) == Config.BasePiece then BasePieceCache = d; return d end
    end
    return nil
end

-- Start placing the base decoration, the same way a click in the build menu does.
local function SelectBase()
    local base = BasePiece()
    if not base then
        Log("Base decoration " .. Config.BasePiece .. " not found; pick any small decoration yourself")
        return false
    end
    for _, ui in ipairs(FindAllOf("BuildingUIAPI") or {}) do
        if Valid(ui) and not NameOf(ui):find("^Default__") then
            local ok, err = pcall(function() ui:CallOnBuildingItemSelected(base) end)
            if ok then return true end
            Log("Selecting the base decoration failed: " .. tostring(err))
        end
    end
    return false
end

local function Pick(m)
    if not LoadMesh(m.Mesh) then Log("Mesh not found for " .. m.Name); return end
    Skin = m
    AddRecent(m)
    StartGhost()
    Log("Picked " .. m.Name)
    Placer.Yaw, Placer.Nudge = 0, nil
    HideUI()
    -- Leave the game's own build mode, so its ghost (e.g. a barrel) isn't shown too.
    local comp = PlayerBuildComp()
    if comp and Weak(comp.CurrentlyPlacingPieceData) then
        pcall(function() comp:ExitAnyMode() end)
    end
    if ShowHint then ShowHint() end
end

-- Adds models from the viewer's "Export starred" file (starred-objects.json in
-- Downloads or in this mod's folder) to models.txt, skipping ones already listed.
local function PrettyName(path)
    local n = path:match("([^/%.]+)%.[^/]*$") or path:match("([^/]+)$") or path
    n = n:gsub("^SM_", ""):gsub("_", " ")
    return n
end

local function ImportStarred()
    local files = { ModDir .. "starred-objects.json" }
    local home = os.getenv("USERPROFILE")
    if home then files[#files + 1] = home .. "/Downloads/starred-objects.json" end
    local have = {}
    for _, m in ipairs(Models) do have[m.Mesh] = true end
    local added, found = {}, false
    for _, file in ipairs(files) do
        local f = io.open(file, "r")
        if f then
            found = true
            local body = f:read("*a")
            f:close()
            for p in body:gmatch('"objectPath"%s*:%s*"([^"]+)"') do
                local mesh = GamePath(p)
                if not have[mesh] then
                    have[mesh] = true
                    added[#added + 1] = { Name = PrettyName(mesh), Mesh = mesh }
                end
            end
        end
    end
    if not found then return "No starred-objects.json in Downloads or the mod folder. Use Export starred in the viewer first." end
    if #added == 0 then return "Nothing new to import" end
    local f = io.open(ModDir .. "models.txt", "a")
    if not f then return "Could not write models.txt" end
    f:write("\n# Imported from the viewer's starred list\n")
    for _, m in ipairs(added) do
        f:write(m.Name .. " | " .. m.Mesh .. "\n")
        Models[#Models + 1] = m
    end
    f:close()
    return string.format("Imported %d models", #added)
end

-- Show the browser with the build menu and hide it with the menu.
local function OnMenu(open)
    CheckWorld()
    ExecuteInGameThread(function()
        -- The browser is its own window now (N key); the build menu no longer opens it.
        local ok, err = true, nil
        if not ok then Log("Browser: " .. tostring(err)); pcall(HideUI) end
    end)
end

local MenuHookSeen = false
pcall(function()
    RegisterHook("/Script/Dominion.BuildModeComponent:OnSelectionMenuVisibilityUpdated", function(self, open)
        if not MenuHookSeen then MenuHookSeen = true; Log("[DISCOVERY] build menu visibility hook fires") end
        OnMenu(Get(open) == true)
    end)
end)

pcall(function()
    RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(context)
        if not UI.Visible and not InDialogue then return end
        local ok, button = pcall(function() return context:get() end)
        if not ok or not Valid(button) then return end
        local addr = button:GetAddress()
        local function is(w) return Valid(w) and w:GetAddress() == addr end
        ExecuteInGameThread(function()
            if InDialogue and DialogueUI and DialogueUI.Buttons then
                for i, btn in ipairs(DialogueUI.Buttons) do
                    if is(btn) then
                        if SafeSelectChoice then SafeSelectChoice(i) elseif SelectDialogueChoice then pcall(SelectDialogueChoice, i) end
                        return
                    end
                end
            end
            if not UI.Visible then return end
            if is(UI.Prev) then
                UI.Page = math.max(1, UI.Page - 1); Refresh()
            elseif is(UI.Next) then
                UI.Page = UI.Page + 1; Refresh()
            elseif is(UI.CatPrev) then
                UI.CatPage = math.max(1, (UI.CatPage or 1) - 1); Refresh()
            elseif is(UI.CatNext) then
                UI.CatPage = (UI.CatPage or 1) + 1; Refresh()
            elseif is(UI.Off) then
                if Skin then Skin = nil; HideHint(); Refresh() else HideUI() end
            elseif is(UI.Import) then
                local msg = ImportStarred()
                Log(msg)
                Label(UI.Import, msg:upper())
                Refresh()
                Label(UI.Import, msg:upper())
            elseif is(UI.SearchBtn) then
                ActiveFilterIdx = (ActiveFilterIdx % (#QUICK_FILTERS + 1)) + 1
                if ActiveFilterIdx > #QUICK_FILTERS then
                    ActiveFilterIdx = 0
                    UI.ActiveFilterName = nil
                    UI.Search = nil
                    UI.Group = FAVOURITES
                    UI.Page = 1
                else
                    local f = QUICK_FILTERS[ActiveFilterIdx]
                    UI.ActiveFilterName = f.Name
                    SearchResults = ModelsForFilter(f.Query)
                    UI.Search = f.Query
                    UI.Group = f.Name
                    UI.Page = 1
                end
                Refresh()
            else
                for i, tile in ipairs(UI.Tiles) do
                    if is(tile) and UI.TileModel[i] then Pick(UI.TileModel[i]); return end
                end
                for i, row in ipairs(UI.Rows) do
                    local item = UI.RowModel[i]
                    if is(row) and item then
                        UI.Group, UI.Page = item.Name, 1
                        if item.FilterQuery then
                            UI.ActiveFilterName = item.Name
                            SearchResults = ModelsForFilter(item.FilterQuery)
                            UI.Search = item.FilterQuery
                        end
                        Refresh()
                        break
                    end
                end
            end
        end)
    end)
end)

-- =========================================================================
-- Console
-- =========================================================================
local TestProps = {}
OnWorldChange[#OnWorldChange + 1] = function()
    TestProps = {}
    pcall(function() if HideAllQuestMarkers then HideAllQuestMarkers() end end)
end

local function Probe(say)
    local _, pawn = Pawn()
    if not pawn then say("not in a world"); return end
    local placing = nil
    for _, comp in ipairs(FindAllOf("BuildModeComponent") or {}) do
        pcall(function()
            local w = comp.CurrentlyPlacingPieceData
            local d = nil
            pcall(function() d = w:Get() end)
            if not Valid(d) then pcall(function() d = w:get() end) end
            if Valid(d) then placing = d end
        end)
    end
    say("Placing: " .. (placing and NameOf(placing) or "nothing selected"))
    say("Last piece id: " .. tostring(LastPieceId()) .. " | piece list readable: "
        .. tostring(PieceExists(LastPieceId() or 0) ~= nil))
    local n, live = 0, 0
    for id in pairs(Placed) do
        n = n + 1
        if Valid(Props[id]) then live = live + 1 end
    end
    say(string.format("Models on record: %d, showing now: %d, picked: %s", n, live, Skin and Skin.Name or "none"))
end


-- =========================================================================
-- Adjusting the picked model. Keys only act while a model is picked:
--   Up/Down     tilt 90 deg (Shift: 15 deg)     Left/Right  turn 90 deg (Shift: 15 deg)
--   + / -       bigger / smaller                Home        reset
-- The change becomes that model's default (orient.txt) and is applied to the latest
-- placed copy of it straight away. N opens/closes the browser, Esc closes it.
-- =========================================================================
local Hint = { Widget = nil }
OnWorldChange[#OnWorldChange + 1] = function() Hint.Widget, Hint.Backdrop = nil, nil end

local Moving = nil   -- { Id, Record } while a placed model is picked back up to move it

local function HintText()
    local o = OrientFor(Skin.Mesh)
    local nd = Placer.Nudge
    local moved = nd and (nd.F ~= 0 or nd.R ~= 0 or nd.U ~= 0)
    return string.format("%s%s     TURN %g   TILT %g   ROLL %g   SIZE %.2f   SNAP %s%s\n"
        .. "LEFT CLICK place     RIGHT CLICK / ESC stop     N models     BACKSPACE undo     DEL delete     INS move\n"
        .. "LEFT/RIGHT turn (Ctrl: 1°, Ctrl+Shift: 0.1°)   UP/DOWN tilt   CTRL+UP/DOWN roll   SHIFT = 90   +/- size   ALT(+Shift) nudge   END snap   HOME reset",
        Moving and "MOVING: " or "", Skin.Name:upper(), Placer.Yaw, o.Pitch, o.Roll, o.Scale,
        SNAP_MODES[Placer.Snap], moved and "   NUDGED" or "")
end

local function HintWidget(pc, path, z)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local cls = StaticFindObject(path)
    if not Valid(cls) and LoadAsset then pcall(LoadAsset, path); cls = StaticFindObject(path) end
    if not Valid(cls) then return nil end
    local w = lib:Create(pc, cls, pc)
    if not Valid(w) then return nil end
    w:SetIsFocusable(false)
    w:AddToViewport(z)
    return w
end

ShowHint = function()
    if not Skin then return end
    local pc = GetPC()
    if not Valid(pc) then return end
    if not Valid(Hint.Widget) then
        Hint.Widget = HintWidget(pc, LABEL_CLASS, 10061)
        if not Hint.Widget then return end
        -- The mod's dark panel behind the text so it reads over any background.
        local ok, bg = pcall(MakePanel, pc, 10060)
        Hint.Backdrop = ok and bg or nil
    end
    local lay = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local size, dpi = lay:GetViewportSize(pc), lay:GetViewportScale(pc)
    local vw, vh = size.X / dpi, size.Y / dpi
    local w, h = 1100, 96
    local x, y = vw / 2 - w / 2, vh - h - 150
    if Hint.Backdrop and Valid(Hint.Backdrop.W) then SizePanel(Hint.Backdrop, x - 20, y - 10, w + 40, h + 20) end
    Place(Hint.Widget, x, y, w, h)
    Label(Hint.Widget, HintText())
    Hint.Widget:SetVisibility(3) -- HitTestInvisible
end

HideHint = function()
    if Valid(Hint.Widget) then pcall(function() Hint.Widget:SetVisibility(COLLAPSED) end) end
    if Hint.Backdrop and Valid(Hint.Backdrop.W) then pcall(function() Hint.Backdrop.W:SetVisibility(COLLAPSED) end) end
end

local function RoundRot(v)
    local m = v % 360
    if m < 0 then m = m + 360 end
    return math.floor(m * 100 + 0.5) / 100
end

local function Adjust(dYaw, dPitch, dRoll, scaleMul, reset)
    if not Skin then return end
    local o = OrientFor(Skin.Mesh)
    if reset then
        o = { Pitch = 0, Roll = 0, Scale = 1 }
        Placer.Yaw = 0
        Placer.Nudge = nil
    else
        Placer.Yaw = RoundRot(Placer.Yaw + dYaw)
        o.Pitch = RoundRot(o.Pitch + dPitch)
        o.Roll = RoundRot(o.Roll + dRoll)
        o.Scale = math.max(0.05, math.min(20, o.Scale * scaleMul))
    end
    -- Tilt, roll and size become this model's default for next time.
    Orient[Skin.Mesh] = o
    SaveOrient()
    ShowHint()
end

local ModReady = false   -- set at the very end of loading; keys do nothing before that

local LastPress = {}
local function Bind(key, mods, fn)
    local id = tostring(key) .. (mods and ("+" .. tostring(mods[1])) or "")
    local run = function()
        -- Holding a key repeats it very fast; handle at most one press per 80 ms so the
        -- game thread isn't flooded with queued jobs.
        local now = os.clock()
        if LastPress[id] and now - LastPress[id] < 0.08 then return end
        LastPress[id] = now
        ExecuteInGameThread(function()
        if not ModReady then return end
        CheckWorld()
        local ok, err = pcall(fn)
        if not ok then Log("Key: " .. tostring(err)) end
    end) end
    if mods then RegisterKeyBind(key, mods, run) else RegisterKeyBind(key, run) end
end

do
    local SHIFT, CTRL = { ModifierKey.SHIFT }, { ModifierKey.CONTROL }
    local CTRL_SHIFT = { ModifierKey.CONTROL, ModifierKey.SHIFT }
    Bind(Key.LEFT_ARROW, nil, function() Adjust(-15, 0, 0, 1) end)
    Bind(Key.RIGHT_ARROW, nil, function() Adjust(15, 0, 0, 1) end)
    Bind(Key.LEFT_ARROW, SHIFT, function() Adjust(-90, 0, 0, 1) end)
    Bind(Key.RIGHT_ARROW, SHIFT, function() Adjust(90, 0, 0, 1) end)
    Bind(Key.LEFT_ARROW, CTRL, function() Adjust(-1, 0, 0, 1) end)
    Bind(Key.RIGHT_ARROW, CTRL, function() Adjust(1, 0, 0, 1) end)
    Bind(Key.LEFT_ARROW, CTRL_SHIFT, function() Adjust(-0.1, 0, 0, 1) end)
    Bind(Key.RIGHT_ARROW, CTRL_SHIFT, function() Adjust(0.1, 0, 0, 1) end)

    Bind(Key.UP_ARROW, nil, function() Adjust(0, 15, 0, 1) end)
    Bind(Key.DOWN_ARROW, nil, function() Adjust(0, -15, 0, 1) end)
    Bind(Key.UP_ARROW, SHIFT, function() Adjust(0, 90, 0, 1) end)
    Bind(Key.DOWN_ARROW, SHIFT, function() Adjust(0, -90, 0, 1) end)
    Bind(Key.UP_ARROW, CTRL, function() Adjust(0, 0, 90, 1) end)
    Bind(Key.DOWN_ARROW, CTRL, function() Adjust(0, 0, -90, 1) end)
    Bind(Key.UP_ARROW, CTRL_SHIFT, function() Adjust(0, 1, 0, 1) end)
    Bind(Key.DOWN_ARROW, CTRL_SHIFT, function() Adjust(0, -1, 0, 1) end)

    Bind(Key.OEM_PLUS, nil, function() Adjust(0, 0, 0, 1.25) end)
    Bind(Key.OEM_MINUS, nil, function() Adjust(0, 0, 0, 0.8) end)
    Bind(Key.HOME, nil, function() Adjust(0, 0, 0, 1, true) end)
    -- Nudge the model 10 cm at a time: Alt + Up/Down = away/towards you, Alt + Left/Right =
    -- left/right, Alt + '+'/'-' = up/down. Home clears it.
    -- Alt + Shift nudges 1 cm (0.01 m) at a time for fine placement.
    local ALT = { ModifierKey.ALT }
    local ALT_SHIFT = { ModifierKey.ALT, ModifierKey.SHIFT }
    local function Nudge(f, r, u)
        if not Skin then return end
        local n = Placer.Nudge or { F = 0, R = 0, U = 0 }
        n.F, n.R, n.U = n.F + f, n.R + r, n.U + u
        Placer.Nudge = n
        ShowHint()
    end
    Bind(Key.UP_ARROW, ALT, function() Nudge(10, 0, 0) end)
    Bind(Key.DOWN_ARROW, ALT, function() Nudge(-10, 0, 0) end)
    Bind(Key.RIGHT_ARROW, ALT, function() Nudge(0, 10, 0) end)
    Bind(Key.LEFT_ARROW, ALT, function() Nudge(0, -10, 0) end)
    Bind(Key.OEM_PLUS, ALT, function() Nudge(0, 0, 10) end)
    Bind(Key.OEM_MINUS, ALT, function() Nudge(0, 0, -10) end)
    Bind(Key.UP_ARROW, ALT_SHIFT, function() Nudge(1, 0, 0) end)
    Bind(Key.DOWN_ARROW, ALT_SHIFT, function() Nudge(-1, 0, 0) end)
    Bind(Key.RIGHT_ARROW, ALT_SHIFT, function() Nudge(0, 1, 0) end)
    Bind(Key.LEFT_ARROW, ALT_SHIFT, function() Nudge(0, -1, 0) end)
    Bind(Key.OEM_PLUS, ALT_SHIFT, function() Nudge(0, 0, 1) end)
    Bind(Key.OEM_MINUS, ALT_SHIFT, function() Nudge(0, 0, -1) end)

    -- End cycles snapping: edges of your models / grid of the nearest building / free.
    Bind(Key.END, nil, function()
        if not Skin then return end
        Placer.Snap = Placer.Snap % #SNAP_MODES + 1
        ShowHint()
    end)
end

-- Place with a left click, stop with a right click or Esc.
Moving = nil

Bind(Key.LEFT_MOUSE_BUTTON, nil, function()
    if not Skin or UI.Visible then return end
    local msg = PlaceNow()
    if msg then Log(msg) end
    local placed = msg and msg:find("^Placed")
    if placed and Moving then
        Remember({ Kind = "move", NewId = Placer.LastKey, OldId = Moving.Id, OldR = Moving.Record })
    elseif placed then
        Remember({ Kind = "place", Id = Placer.LastKey })
    end
    if Moving and placed then
        -- A moved model is put down once; then back to normal play.
        Moving = nil
        Skin = nil
        HideHint()
    end
end)

local function StopPlacing()
    if not Skin then return end
    if Moving then
        -- Cancelled a move: put the model back where it was.
        local id, r = Moving.Id, Moving.Record
        Moving = nil
        local a = SpawnModel(r.Mesh, r)
        if a then Props[id] = a end
        Placed[id] = r
        SavePlaced()
    end
    Skin = nil
    HideHint()
end
-- Backspace: undo the latest place, delete or move (this session, up to 50 steps).
-- (Not Ctrl+Z: the game ignores Ctrl, so Z would also fire the game's and other mods' Z.)
local function PutBack(id, r)
    local a = SpawnModel(r.Mesh, r)
    if a then Props[id] = a end
    Placed[id] = r
end

local function Undo()
    local e = table.remove(History)
    if not e then return "Nothing to undo" end
    if e.Kind == "place" then
        DestroyProp(e.Id)
        Placed[e.Id] = nil
    elseif e.Kind == "delete" then
        PutBack(e.Id, e.R)
    elseif e.Kind == "move" then
        DestroyProp(e.NewId)
        Placed[e.NewId] = nil
        PutBack(e.OldId, e.OldR)
    end
    SavePlaced()
    return "Undid the last " .. e.Kind
end
Bind(Key.BACKSPACE, nil, function()
    if UI.Visible then return end
    Log(Undo())
end)

Bind(Key.RIGHT_MOUSE_BUTTON, nil, function() StopPlacing() end)
-- Esc only does something while the browser is open or a model is being placed.
Bind(Key.ESCAPE, nil, function()
    if InDialogue and HideDialogue then HideDialogue(); return end
    if UI.Visible then HideUI() elseif Skin then StopPlacing() end
end)

-- Delete removes the custom model you are looking at (as it always did).
Bind(Key.DEL, nil, function()
    if UI.Visible then return end
    Log(RemoveLookedAt(300) or "No custom model there")
end)

-- Move: Insert picks the model you aim at back up; aim, adjust
-- and left click to put it down again (right click / Esc puts it back).
local function MoveLookedAt()
    if Skin or UI.Visible then return end
    local id = FindLookedAt(250)
    if not id then return end
    local r = Placed[id]
    DestroyProp(id)
    Placed[id] = nil
    SavePlaced()
    Moving = { Id = id, Record = r }
    Placer.Nudge = nil
    local m = ModelForMesh(r.Mesh)
    Orient[r.Mesh] = { Pitch = r.Pitch or 0, Roll = r.Roll or 0, Scale = r.Scale or 1 }
    -- Keep the way it faced: the placer's yaw is relative to the camera.
    local _, _, rot = CameraView()
    local yaw = 0
    pcall(function() yaw = YawOf(r) end)
    Placer.Yaw = rot and ((yaw - rot.Yaw - 180) % 360) or 0
    Skin = m
    StartGhost()
    ShowHint()
    Log("Moving " .. m.Name)
end
Bind(Key.INS, nil, MoveLookedAt)
Bind(Key.N, nil, function()
    if UI.Visible then HideUI() else ShowUI() end
end)

-- =========================================================================
-- Custom Quests & Interactive Dialogue Engine
-- =========================================================================
Quests = {}             -- Loaded from quests.json
QuestStates = {}        -- [questId] = { state = "unstarted"|"active"|"completed", progress = 0 }
ActiveQuestId = nil     -- Active tracked quest id
InDialogue = false      -- True while dialogue box is open
CurrentDialogue = nil   -- { Quest, Choices = {} }
DialogueUI = { Built = false, Panel = nil, Speaker = nil, Text = nil, Buttons = {} }
TrackerUI = { Built = false, Panel = nil, Title = nil, Sub = nil }

function JsonDecode(str)
    if not str or str == "" then return nil end
    local pos = 1
    local len = #str

    local function skipWhitespace()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1
        local buf = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == '\\' then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == 'n' then buf[#buf + 1] = '\n'
                elseif esc == 'r' then buf[#buf + 1] = '\r'
                elseif esc == 't' then buf[#buf + 1] = '\t'
                else buf[#buf + 1] = esc end
                pos = pos + 1
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parseNumber()
        local s, e, num = str:find("^([%-]?%d+%.?%d*[eE]?[%+%-]?%d*)", pos)
        if s then
            pos = e + 1
            return tonumber(num)
        end
        return nil
    end

    local function parseObject()
        pos = pos + 1
        local obj = {}
        skipWhitespace()
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while pos <= len do
            skipWhitespace()
            if str:sub(pos, pos) ~= '"' then break end
            local key = parseString()
            skipWhitespace()
            if str:sub(pos, pos) == ':' then pos = pos + 1 end
            local val = parseValue()
            obj[key] = val
            skipWhitespace()
            local c = str:sub(pos, pos)
            if c == ',' then
                pos = pos + 1
            elseif c == '}' then
                pos = pos + 1
                break
            else
                break
            end
        end
        return obj
    end

    local function parseArray()
        pos = pos + 1
        local arr = {}
        skipWhitespace()
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        while pos <= len do
            local val = parseValue()
            arr[#arr + 1] = val
            skipWhitespace()
            local c = str:sub(pos, pos)
            if c == ',' then
                pos = pos + 1
            elseif c == ']' then
                pos = pos + 1
                break
            else
                break
            end
        end
        return arr
    end

    parseValue = function()
        skipWhitespace()
        if pos > len then return nil end
        local c = str:sub(pos, pos)
        if c == '{' then
            return parseObject()
        elseif c == '[' then
            return parseArray()
        elseif c == '"' then
            return parseString()
        elseif c == 't' and str:sub(pos, pos + 3) == "true" then
            pos = pos + 4; return true
        elseif c == 'f' and str:sub(pos, pos + 4) == "false" then
            pos = pos + 5; return false
        elseif c == 'n' and str:sub(pos, pos + 3) == "null" then
            pos = pos + 4; return nil
        else
            return parseNumber()
        end
    end

    local ok, res = pcall(parseValue)
    return ok and res or nil
end

function SaveQuestsState()
    local path = ModDir .. "save_quests.txt"
    if io.open(ModDir .. "save_quests.json", "rb") then
        path = ModDir .. "save_quests.json"
    end
    local f = io.open(path, "wb")
    if not f then return end
    local lines = { "{" }
    local first = true
    for qid, s in pairs(QuestStates) do
        local comma = first and "" or ","
        first = false
        if s.completedAt then
            lines[#lines + 1] = string.format('  %s"%s": { "state": "%s", "progress": %d, "completedAt": %d }',
                comma, qid, s.state or "unstarted", s.progress or 0, math.floor(s.completedAt))
        else
            lines[#lines + 1] = string.format('  %s"%s": { "state": "%s", "progress": %d }',
                comma, qid, s.state or "unstarted", s.progress or 0)
        end
    end
    lines[#lines + 1] = "}\n"
    f:write(table.concat(lines, "\n"))
    f:close()
end

function CheckDailyReset(quest)
    if not quest or quest.repeatable ~= "daily" then return false end
    local s = QuestStates[quest.id]
    if not s or s.state ~= "completed" or not s.completedAt then return false end
    local now = os.time()
    local cDate = os.date("!*t", s.completedAt)
    local nDate = os.date("!*t", now)
    local isNewDay = (nDate.year > cDate.year)
        or (nDate.year == cDate.year and nDate.yday > cDate.yday)
        or (now - s.completedAt >= 86400)
    if isNewDay then
        Log(string.format("[QUESTS] Daily reset triggered for '%s' (completed at %s, now %s)",
            quest.id, os.date("!%Y-%m-%d %H:%M:%S", s.completedAt), os.date("!%Y-%m-%d %H:%M:%S", now)))
        s.state = "unstarted"
        s.progress = 0
        s.completedAt = nil
        QuestStates[quest.id] = s
        pcall(SaveQuestsState)
        pcall(UpdateTrackerUI)
        return true
    end
    return false
end

function CheckAllDailyQuests()
    for _, q in ipairs(Quests or {}) do
        pcall(CheckDailyReset, q)
    end
end

LastQuestsText = nil
function LoadQuests()
    local text = ReadFile(ModDir .. "quests.txt")
    if not text or text == "" then text = ReadFile(ModDir .. "quests.json") end
    if text and text ~= "" and text ~= LastQuestsText then
        LastQuestsText = text
        local data = JsonDecode(text)
        if data and data.quests then
            Quests = data.quests
            Log(string.format("[QUESTS] Loaded %d custom quests", #Quests))
        end
    end
    local saveText = ReadFile(ModDir .. "save_quests.txt")
    if not saveText or saveText == "" then saveText = ReadFile(ModDir .. "save_quests.json") end
    if saveText and saveText ~= "" then
        local save = JsonDecode(saveText)
        if save then QuestStates = save end
    end
    pcall(CheckAllDailyQuests)
    ActiveQuestId = nil
    for qid, s in pairs(QuestStates) do
        if s.state == "active" then
            ActiveQuestId = qid
            break
        end
    end
end

function QuestForNPC(npc)
    if not npc or not Quests or #Quests == 0 then return nil end
    local npcKey = (npc.Key or ""):lower()
    local npcName = (npc.Name or ""):lower()
    local npcMesh = (npc.Mesh or ""):lower()

    for _, q in ipairs(Quests) do
        local qNpc = (q.npc or ""):lower()
        local qName = (q.npcName or ""):lower()
        if qNpc ~= "" and (npcKey:find(qNpc, 1, true) or npcMesh:find(qNpc, 1, true)) then
            return q
        elseif qName ~= "" and (npcName:find(qName, 1, true) or npcKey:find(qName, 1, true)) then
            return q
        end
    end
    return nil
end

function GetPlayerInventory()
    local pc = GetPC()
    if not Valid(pc) then return nil end
    local inv = nil
    pcall(function() inv = pc.BP_Components_Inventory end)
    if Valid(inv) then return inv end
    pcall(function() inv = pc.Inventory end)
    if Valid(inv) then return inv end

    local pawn = nil
    pcall(function() pawn = pc.Pawn or pc.AcknowledgedPawn end)
    if Valid(pawn) then
        pcall(function() inv = pawn.BP_Components_Inventory end)
        if Valid(inv) then return inv end
        pcall(function() inv = pawn.Inventory end)
        if Valid(inv) then return inv end
    end
    return nil
end

function ItemMatchesTarget(itemName, targetName)
    if not itemName or not targetName then return false end
    local iname = tostring(itemName):lower():gsub("[^%w%s]", " ")
    local tname = tostring(targetName):lower():gsub("[^%w%s]", " ")

    local ic = iname:gsub("%s+", "")
    local tc = tname:gsub("%s+", "")
    if ic == tc then return true end
    if ic:find(tc, 1, true) or tc:find(ic, 1, true) then return true end

    -- Check if all words from target are in candidate name (e.g. "Iron Ore" -> "iron" and "ore" in "da item ore iron")
    local allWordsMatch = true
    local wordCount = 0
    for word in tname:gmatch("%S+") do
        wordCount = wordCount + 1
        if not iname:find(word, 1, true) then
            allWordsMatch = false
            break
        end
    end
    if wordCount > 0 and allWordsMatch then return true end
    return false
end

function CountPlayerItems(targetItemName)
    if not targetItemName or targetItemName == "" then return 0 end
    local inv = GetPlayerInventory()
    if not Valid(inv) then return 0 end

    local numSlots = 0
    pcall(function() numSlots = inv.ItemSlots:GetArrayNum() end)
    if numSlots <= 0 then return 0 end

    local total = 0

    for i = 1, numSlots do
        local item = nil
        pcall(function() item = inv.ItemSlots[i] end)
        if item and Valid(item) then
            local count = 0
            pcall(function() count = item:GetStackSize() end)
            if not count or count <= 0 then count = 1 end

            local matched = false
            local namesToCheck = {}

            pcall(function()
                local facing = item:GetPlayerFacingName()
                if facing and facing.ToString then namesToCheck[#namesToCheck + 1] = facing:ToString() end
            end)
            pcall(function()
                if item.ItemData and Valid(item.ItemData) then
                    namesToCheck[#namesToCheck + 1] = item.ItemData:GetFName():ToString()
                    namesToCheck[#namesToCheck + 1] = item.ItemData:GetFullName()
                end
            end)
            pcall(function() namesToCheck[#namesToCheck + 1] = item:GetFName():ToString() end)

            for _, n in ipairs(namesToCheck) do
                if ItemMatchesTarget(n, targetItemName) then
                    matched = true
                    break
                end
            end

            if matched then
                total = total + count
            end
        end
    end
    return total
end

function DeductPlayerItems(targetItemName, amountToDeduct)
    if not targetItemName or not amountToDeduct or amountToDeduct <= 0 then return end
    local inv = GetPlayerInventory()
    if not Valid(inv) then return end
    local pc = GetPC()

    local numSlots = 0
    pcall(function() numSlots = inv.ItemSlots:GetArrayNum() end)
    if numSlots <= 0 then return end

    local remaining = amountToDeduct

    for i = 1, numSlots do
        if remaining <= 0 then break end
        local item = nil
        pcall(function() item = inv.ItemSlots[i] end)
        if item and Valid(item) then
            local matched = false
            local namesToCheck = {}

            pcall(function()
                local facing = item:GetPlayerFacingName()
                if facing and facing.ToString then namesToCheck[#namesToCheck + 1] = facing:ToString() end
            end)
            pcall(function()
                if item.ItemData and Valid(item.ItemData) then
                    namesToCheck[#namesToCheck + 1] = item.ItemData:GetFName():ToString()
                    namesToCheck[#namesToCheck + 1] = item.ItemData:GetFullName()
                end
            end)
            pcall(function() namesToCheck[#namesToCheck + 1] = item:GetFName():ToString() end)

            for _, n in ipairs(namesToCheck) do
                if ItemMatchesTarget(n, targetItemName) then
                    matched = true
                    break
                end
            end

            if matched then
                local count = 0
                pcall(function() count = item:GetStackSize() end)
                if not count or count <= 0 then count = 1 end

                local take = math.min(count, remaining)
                local slotZero = i - 1
                local didRemove = false

                -- Method 1: RemoveItem if taking whole stack
                if take >= count then
                    pcall(function()
                        local res = inv:RemoveItem(item)
                        if res ~= false then didRemove = true end
                    end)
                end

                -- Method 2: RemoveItemByData
                if not didRemove and item.ItemData and Valid(item.ItemData) then
                    pcall(function()
                        local res = inv:RemoveItemByData(item.ItemData, take)
                        if res ~= false then didRemove = true end
                    end)
                end

                -- Method 3: RemoveFromSlot
                if not didRemove then
                    pcall(function()
                        local res = inv:RemoveFromSlot(slotZero, take, pc)
                        if res ~= false then didRemove = true end
                    end)
                end

                -- Method 4: Stack reduction fallback
                if not didRemove then
                    if take < count then
                        pcall(function() item:SetStackSize(count - take); didRemove = true end)
                    else
                        pcall(function() item:SetStackSize(0); inv:RemoveItem(item); didRemove = true end)
                    end
                end

                remaining = remaining - take
                Log(string.format("[QUEST] Deducted %d of '%s' from slot %d (remaining to deduct: %d)", take, namesToCheck[1] or targetItemName, i, remaining))
            end
        end
    end
end

function FindItemData(searchName)
    if not searchName or searchName == "" then return nil end
    local inv = GetPlayerInventory()

    -- 1. Scan player inventory slots
    if Valid(inv) then
        local numSlots = 0
        pcall(function() numSlots = inv.ItemSlots:GetArrayNum() end)
        for i = 1, numSlots do
            local item = nil
            pcall(function() item = inv.ItemSlots[i] end)
            if item and Valid(item) and Valid(item.ItemData) then
                local d = item.ItemData
                local n1 = d:GetFName():ToString()
                local n2 = d:GetFullName()
                if ItemMatchesTarget(n1, searchName) or ItemMatchesTarget(n2, searchName) then
                    return d
                end
            end
        end
    end

    -- 2. Scan RecipeData items (consumed or created)
    local okRecipes, recipes = pcall(FindAllOf, "RecipeData")
    if okRecipes and recipes then
        for _, r in ipairs(recipes) do
            if Valid(r) then
                for _, containerArr in ipairs({ r.ItemsCreated, r.ItemsConsumed }) do
                    if containerArr then
                        local n = 0
                        pcall(function() n = containerArr:GetArrayNum() end)
                        for i = 1, n do
                            pcall(function()
                                local e = containerArr[i]
                                local d = e and e.ItemData
                                if Valid(d) then
                                    local n1 = d:GetFName():ToString()
                                    local n2 = d:GetFullName()
                                    if ItemMatchesTarget(n1, searchName) or ItemMatchesTarget(n2, searchName) then
                                        return d
                                    end
                                end
                            end)
                        end
                    end
                end
            end
        end
    end

    -- 3. Scan loaded ItemData UObjects
    local classes = { "ItemData", "DominionItemData", "ConsumableItemData", "ResourceItemData", "EquipmentItemData" }
    for _, clsName in ipairs(classes) do
        local ok, objs = pcall(FindAllOf, clsName)
        if ok and objs then
            for _, obj in ipairs(objs) do
                if Valid(obj) then
                    local n1 = obj:GetFName():ToString()
                    local n2 = obj:GetFullName()
                    if ItemMatchesTarget(n1, searchName) or ItemMatchesTarget(n2, searchName) then
                        return obj
                    end
                end
            end
        end
    end

    -- 4. Direct known paths & alias mapping
    local knownPaths = {
        zamorak = "/Game/Gameplay/Items/Consumables/Misc/ITEM_Consumable_Pack_Zamorak_Mage.ITEM_Consumable_Pack_Zamorak_Mage",
        zamorakian = "/Game/Gameplay/Items/Consumables/Misc/ITEM_Consumable_Pack_Zamorak_Mage.ITEM_Consumable_Pack_Zamorak_Mage",
        zamorak_warrior = "/Game/Gameplay/Items/Consumables/Misc/ITEM_Consumable_Pack_Zamorak_Warrior.ITEM_Consumable_Pack_Zamorak_Warrior",
        shrimp = "/Fishing/Gameplay/Items/Fishes/Shrimp/ITEM_Resources_Fish_Raw_Shrimp.ITEM_Resources_Fish_Raw_Shrimp",
        raw_shrimp = "/Fishing/Gameplay/Items/Fishes/Shrimp/ITEM_Resources_Fish_Raw_Shrimp.ITEM_Resources_Fish_Raw_Shrimp",
        garou = "/Game/Gameplay/Items/Consumables/DA_ITEM_Consumable_GarouPack.DA_ITEM_Consumable_GarouPack",
        iron_ore = "/Game/Gameplay/Items/Resources/DA_Item_Ore_Iron.DA_Item_Ore_Iron",
        iron_ingot = "/Game/Art/Item/Resources/Ingots/DA_Item_Ingot_Iron.DA_Item_Ingot_Iron"
    }

    local sLower = tostring(searchName):lower()
    for alias, p in pairs(knownPaths) do
        if sLower:find(alias, 1, true) or ItemMatchesTarget(alias, searchName) then
            local obj = StaticFindObject(p)
            if not Valid(obj) and LoadAsset then
                pcall(LoadAsset, p)
                obj = StaticFindObject(p)
            end
            if Valid(obj) then return obj end
        end
    end

    -- If searchName looks like a full asset path directly
    if searchName:find("^/") then
        local obj = StaticFindObject(searchName)
        if not Valid(obj) and LoadAsset then
            pcall(LoadAsset, searchName)
            obj = StaticFindObject(searchName)
        end
        if Valid(obj) then return obj end
    end

    return nil
end

function GivePlayerItem(itemDataOrName, count)
    local inv = GetPlayerInventory()
    if not Valid(inv) then return false, "No inventory component" end

    local itemData = itemDataOrName
    if type(itemDataOrName) == "string" then
        itemData = FindItemData(itemDataOrName)
    end
    if not Valid(itemData) then
        return false, "ItemData not found for: " .. tostring(itemDataOrName)
    end

    -- Preload UI skill icons if granting tomes (prevents UQuickAccessBarBase FindObject null-deref crash)
    pcall(function()
        local fullName = itemData:GetFullName()
        if fullName:find("Tome", 1, true) and LoadAsset then
            local skill = fullName:match("Tome_Tier%d+_([%w_]+)") or fullName:match("Tome_([%w_]+)")
            if skill then
                pcall(LoadAsset, "/Game/Art/UI/Icons/Skill_Tomes_Concept_Art/T_Icon_Skill_Tome_" .. skill .. ".T_Icon_Skill_Tome_" .. skill)
                pcall(LoadAsset, "/Game/Art/UI/Skills/Icons/Tags/T_Icon_Tag_Skill_" .. skill .. ".T_Icon_Tag_Skill_" .. skill)
                pcall(LoadAsset, "/Fishing/Art/UI/Icons/Fishing_Skill_Icons/T_Icon_Skill_Tome_Fishing.T_Icon_Skill_Tome_Fishing")
                pcall(LoadAsset, "/Fishing/Art/UI/Icons/Fishing_Skill_Icons/T_Icon_Tag_Skill_Fishing.T_Icon_Tag_Skill_Fishing")
            end
        end
    end)

    local added = 0
    local targetCount = count or 1
    pcall(function()
        local maxStack = 20
        pcall(function() maxStack = itemData:GetMaxStackSize() end)
        if not maxStack or maxStack <= 0 then maxStack = 20 end

        while added < targetCount do
            local chunk = math.min(targetCount - added, maxStack)

            -- Check inventory capacity before attempting AddItemByData
            local canAdd = true
            pcall(function()
                if inv.CanAddItemByData then
                    canAdd = inv:CanAddItemByData(itemData, chunk)
                end
            end)
            if not canAdd then
                Log("[REWARD] Player inventory full; cannot add " .. tostring(chunk) .. " items")
                break
            end

            -- Pass nil for FGameplayTagContainer to ensure zero-initialization in UE4SS
            local ok = false
            pcall(function()
                ok = inv:AddItemByData(itemData, chunk, 1.0, nil)
            end)
            if not ok then break end
            added = added + chunk
        end
    end)

    if added > 0 then
        Log(string.format("[REWARD] Given %d x %s to player inventory", added, itemData:GetFName():ToString()))
        return true, added
    else
        return false, "AddItemByData failed or inventory full"
    end
end

function DeliverQuestReward(quest)
    if not quest or not quest.rewards then return end
    local r = quest.rewards
    local itemName = r.item
    local count = r.count or 1
    if not itemName or itemName == "" then return end

    local ok, res = GivePlayerItem(itemName, count)
    if ok then
        Say(string.format("Received Reward: %d x %s!", count, itemName))
    else
        Log(string.format("[REWARD] Could not spawn item: %s (%s)", tostring(itemName), tostring(res)))
        Say(string.format("Quest Complete! Reward: %s", r.text or (count .. "x " .. itemName)))
    end
end

function SyncInventory()
    if not GameWorld or WorldKey() ~= GameWorld then return end
    local inv = GetPlayerInventory()
    local pc = GetPC()
    if not Valid(inv) then return end

    -- 1. Read & process commands from inventory_cmd.txt if it exists
    local cmdText = ReadFile(ModDir .. "inventory_cmd.txt")
    if cmdText and cmdText:match("%S") then
        -- Clear cmd file immediately so commands don't re-execute
        WriteText("inventory_cmd.txt", "")
        for line in cmdText:gmatch("[^\r\n]+") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" and not line:find("^#") then
                local parts = {}
                for part in line:gmatch("[^|]+") do
                    parts[#parts + 1] = part
                end
                local op = parts[1] and parts[1]:lower()
                if op == "add" then
                    -- add|<itemIdOrName>|<count>
                    local id = parts[2]
                    local count = tonumber(parts[3]) or 1
                    if id and count > 0 then
                        local ok, res = GivePlayerItem(id, count)
                        Log(string.format("[INV_CMD] add %s x%d -> %s", id, count, tostring(res)))
                    end
                elseif op == "move" then
                    -- move|<fromSlot>|<toSlot>|<amount>
                    local fromSlot = tonumber(parts[2])
                    local toSlot = tonumber(parts[3])
                    local amount = tonumber(parts[4]) or -1
                    if fromSlot and toSlot and inv.MoveItem then
                        pcall(function()
                            inv:MoveItem(fromSlot, inv, toSlot, pc, amount)
                        end)
                        Log(string.format("[INV_CMD] move slot %d -> %d (amt: %d)", fromSlot, toSlot, amount))
                    end
                elseif op == "remove" then
                    -- remove|<slot>|<count>
                    local slot = tonumber(parts[2])
                    local count = tonumber(parts[3]) or 1
                    if slot and inv.RemoveFromSlot then
                        pcall(function()
                            inv:RemoveFromSlot(slot, count, pc)
                        end)
                        Log(string.format("[INV_CMD] remove slot %d (count: %d)", slot, count))
                    end
                elseif op == "clean" then
                    -- fill stacks
                    if inv.FillStacks then
                        pcall(function() inv:FillStacks() end)
                        Log("[INV_CMD] fill stacks / clean")
                    end
                elseif op == "clear" then
                    -- clear inventory
                    if inv.ClearInventory then
                        pcall(function() inv:ClearInventory() end)
                        Log("[INV_CMD] clear inventory")
                    end
                end
            end
        end
    end

    -- 2. Export current inventory state to inventory.json
    local numSlots = 0
    pcall(function() numSlots = inv.ItemSlots:GetArrayNum() end)
    local maxSlots = 40
    pcall(function()
        if inv.MaxSlotCount and inv.MaxSlotCount > 0 then maxSlots = inv.MaxSlotCount end
    end)
    if numSlots > maxSlots then maxSlots = numSlots end

    local slotEntries = {}
    for i = 1, numSlots do
        local slotIdx = i - 1
        local item = nil
        pcall(function() item = inv.ItemSlots[i] end)
        if item and Valid(item) then
            local count = 1
            pcall(function() count = item:GetStackSize() end)
            local name = "Unknown"
            pcall(function()
                local fn = item:GetPlayerFacingName()
                if fn and fn.ToString then name = fn:ToString() end
            end)
            local itemId = ""
            local itemPath = ""
            local maxStack = 20
            pcall(function()
                local d = item.ItemData or (item.BP_GetItemData and item:BP_GetItemData())
                if Valid(d) then
                    itemId = d:GetFName():ToString()
                    itemPath = d:GetFullName()
                    if d.GetMaxStackSize then maxStack = d:GetMaxStackSize() end
                end
            end)
            local durability = 1.0
            pcall(function()
                if item.GetDurability then durability = item:GetDurability() end
            end)
            local maxDurability = 1.0
            pcall(function()
                if item.GetMaxDurability then maxDurability = item:GetMaxDurability() end
            end)

            local function jsonStr(s)
                return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '') .. '"'
            end

            slotEntries[#slotEntries + 1] = string.format(
                '{"slot":%d,"name":%s,"id":%s,"path":%s,"count":%d,"maxStack":%d,"durability":%.2f,"maxDurability":%.2f}',
                slotIdx, jsonStr(name), jsonStr(itemId), jsonStr(itemPath), count, maxStack, durability, maxDurability
            )
        end
    end

    local json = string.format('{"maxSlots":%d,"slots":[%s],"time":%d}\n', maxSlots, table.concat(slotEntries, ","), os.time())
    WriteText("inventory.json", json)
end

function CheckQuestObjective(quest)
    if not quest or not quest.objective then return true end
    local obj = quest.objective
    local qid = quest.id
    local state = QuestStates[qid] or {}
    local target = obj.count or 1

    if obj.type == "item" then
        local invCount = CountPlayerItems(obj.item)
        state.progress = invCount
        QuestStates[qid] = state
        return invCount >= target
    end

    local prog = state.progress or 0
    return prog >= target
end

UpdateTrackerUI = nil -- forward decl

function BuildDialogueUI(pc)
    if DialogueUI.Built and Valid(DialogueUI.Speaker) then return true end
    local ok, panel = pcall(MakePanel, pc, 10080)
    DialogueUI.Panel = ok and panel or nil
    DialogueUI.Speaker = NewWidget(pc, LABEL_CLASS, 10082)
    DialogueUI.Text = NewWidget(pc, LABEL_CLASS, 10082)
    DialogueUI.Buttons = {}
    for i = 1, 4 do
        DialogueUI.Buttons[i] = NewWidget(pc, BUTTON_CLASS, 10082)
    end
    DialogueUI.Built = true
    return true
end

function HideDialogue()
    InDialogue = false
    CurrentDialogue = nil
    if DialogueUI.Panel and Valid(DialogueUI.Panel.W) then
        pcall(function() DialogueUI.Panel.W:SetVisibility(COLLAPSED) end)
    end
    if Valid(DialogueUI.Speaker) then pcall(function() DialogueUI.Speaker:SetVisibility(COLLAPSED) end) end
    if Valid(DialogueUI.Text) then pcall(function() DialogueUI.Text:SetVisibility(COLLAPSED) end) end
    for i = 1, 4 do
        if Valid(DialogueUI.Buttons[i]) then pcall(function() DialogueUI.Buttons[i]:SetVisibility(COLLAPSED) end) end
    end
end

function ShowDialogueNode(quest, speakerName, text, choices)
    local pc = GetPC()
    if not Valid(pc) then return end
    if not BuildDialogueUI(pc) then return end

    InDialogue = true
    CurrentDialogue = {
        Quest = quest,
        Choices = choices or {}
    }

    local lay = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local size, dpi = lay:GetViewportSize(pc), lay:GetViewportScale(pc)
    local vw, vh = size.X / dpi, size.Y / dpi

    -- Large, immersive dialog box dimensions
    local pw = math.min(960, math.floor(vw - 80))
    local numChoices = choices and #choices or 0
    local ph = math.max(260, 160 + numChoices * 30)
    local px = math.floor((vw - pw) / 2)
    -- Position safely above the player health/action bars (sitting at ~vh - 90 to vh - 20)
    local py = math.floor(vh - ph - 110)

    if DialogueUI.Panel and Valid(DialogueUI.Panel.W) then
        SizePanel(DialogueUI.Panel, px, py, pw, ph)
        pcall(function() DialogueUI.Panel.W:SetVisibility(VISIBLE) end)
    end

    if Valid(DialogueUI.Speaker) then
        Place(DialogueUI.Speaker, px + 35, py + 18, pw - 70, 32)
        Label(DialogueUI.Speaker, string.format("[ %s ]", speakerName:upper()))
        DialogueUI.Speaker:SetVisibility(VISIBLE)
    end

    if Valid(DialogueUI.Text) then
        Place(DialogueUI.Text, px + 38, py + 56, pw - 76, 75)
        Label(DialogueUI.Text, text)
        pcall(function()
            if DialogueUI.Text.LabelText then
                DialogueUI.Text.LabelText:SetAutoWrapText(true)
                DialogueUI.Text.LabelText:SetWrapTextAt(pw - 76)
            end
        end)
        DialogueUI.Text:SetVisibility(VISIBLE)
    end

    for i = 1, 4 do
        local btn = DialogueUI.Buttons[i]
        if Valid(btn) then
            if i <= numChoices then
                local ch = choices[i]
                local by = py + 144 + (i - 1) * 28
                Place(btn, px + 38, by, pw - 76, 26)
                Label(btn, string.format("[ %d ]  %s", i, ch.text))
                btn:SetVisibility(VISIBLE)
            else
                btn:SetVisibility(COLLAPSED)
            end
        end
    end
end

function SelectDialogueChoice(index)
    if not InDialogue or not CurrentDialogue then return end
    local choices = CurrentDialogue.Choices
    if not choices or not choices[index] then return end
    local ch = choices[index]
    local quest = CurrentDialogue.Quest

    if ch.action == "start_quest" then
        QuestStates[quest.id] = { state = "active", progress = 0 }
        ActiveQuestId = quest.id
        pcall(SaveQuestsState)
        pcall(UpdateTrackerUI)
        pcall(Say, string.format("Quest Started: %s", quest.title))
        pcall(HideDialogue)
        return
    elseif ch.action == "complete_quest" then
        if quest.objective and quest.objective.type == "item" then
            pcall(DeductPlayerItems, quest.objective.item, quest.objective.count or 1)
        end
        pcall(DeliverQuestReward, quest)
        QuestStates[quest.id] = {
            state = "completed",
            progress = quest.objective and quest.objective.count or 1,
            completedAt = os.time()
        }
        if ActiveQuestId == quest.id then ActiveQuestId = nil end
        pcall(SaveQuestsState)
        pcall(UpdateTrackerUI)
        pcall(Say, string.format("Quest Completed: %s! Reward: %s", quest.title, quest.rewards and quest.rewards.text or "Glory"))
        pcall(HideDialogue)
        return
    elseif ch.action == "close" then
        pcall(HideDialogue)
        return
    end

    if ch.target and quest.startDialogue and quest.startDialogue.branches and quest.startDialogue.branches[ch.target] then
        local b = quest.startDialogue.branches[ch.target]
        local speaker = b.speaker or quest.npcName or "NPC"
        local bChoices = b.choices or { { text = "Continue", action = b.action or "close" } }
        ShowDialogueNode(quest, speaker, b.text, bChoices)
        return
    end

    pcall(HideDialogue)
end

UpdateTrackerUI = function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc = GetPC()
            if not Valid(pc) then return end
            if not ActiveQuestId then
                if TrackerUI and TrackerUI.Panel and Valid(TrackerUI.Panel.W) then
                    pcall(function() TrackerUI.Panel.W:SetVisibility(COLLAPSED) end)
                end
                if TrackerUI and Valid(TrackerUI.Title) then pcall(function() TrackerUI.Title:SetVisibility(COLLAPSED) end) end
                if TrackerUI and Valid(TrackerUI.Sub) then pcall(function() TrackerUI.Sub:SetVisibility(COLLAPSED) end) end
                return
            end

            local quest = nil
            for _, q in ipairs(Quests or {}) do
                if q.id == ActiveQuestId then quest = q; break end
            end
            if not quest then return end

            if not TrackerUI.Built or not Valid(TrackerUI.Title) then
                local okP, panel = pcall(MakePanel, pc, 10050)
                TrackerUI.Panel = okP and panel or nil
                local okT, t = pcall(NewWidget, pc, LABEL_CLASS, 10051)
                TrackerUI.Title = okT and t or nil
                local okS, s = pcall(NewWidget, pc, LABEL_CLASS, 10051)
                TrackerUI.Sub = okS and s or nil
                TrackerUI.Built = true
            end

            local lay = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
            if not Valid(lay) then return end
            local size, dpi = lay:GetViewportSize(pc), lay:GetViewportScale(pc)
            if not size or not dpi or dpi <= 0 then return end
            local vw, vh = size.X / dpi, size.Y / dpi

            local tw, th = 360, 76
            local tx, ty = vw - tw - 24, 75

            if TrackerUI.Panel and Valid(TrackerUI.Panel.W) then
                SizePanel(TrackerUI.Panel, tx, ty, tw, th)
                pcall(function() TrackerUI.Panel.W:SetVisibility(VISIBLE) end)
            end

            if Valid(TrackerUI.Title) then
                Place(TrackerUI.Title, tx + 16, ty + 10, tw - 32, 24)
                Label(TrackerUI.Title, string.format("[QUEST] %s", quest.title))
                pcall(function() TrackerUI.Title:SetVisibility(VISIBLE) end)
            end

            local qstate = QuestStates[ActiveQuestId] or {}
            local obj = quest.objective or {}
            local cur = qstate.progress or 0
            if obj.type == "item" then
                local invCount = CountPlayerItems(obj.item)
                cur = invCount
                qstate.progress = invCount
                QuestStates[ActiveQuestId] = qstate
            end
            local target = obj.count or 1
            local objText = obj.hudText or obj.trackerText or quest.description or "Objective"

            if Valid(TrackerUI.Sub) then
                Place(TrackerUI.Sub, tx + 18, ty + 38, tw - 36, 24)
                Label(TrackerUI.Sub, string.format("> %s: %d / %d", objText, cur, target))
                pcall(function() TrackerUI.Sub:SetVisibility(VISIBLE) end)
            end
        end)
        if not ok then Log("[TRACKER] Update error: " .. tostring(err)) end
    end)
end

function HandleCompanionInteraction(npc)
    if not npc then return false end
    local quest = QuestForNPC(npc)
    if not quest then return false end

    pcall(CheckDailyReset, quest)

    local qid = quest.id
    local state = QuestStates[qid] and QuestStates[qid].state or "unstarted"

    if state == "unstarted" then
        local sd = quest.startDialogue or {}
        local speaker = sd.speaker or quest.npcName or npc.Name or "NPC"
        local choices = sd.choices or { { text = "Understood", action = "close" } }
        ShowDialogueNode(quest, speaker, sd.text or "Greetings!", choices)
        return true
    elseif state == "active" then
        if CheckQuestObjective(quest) then
            local td = quest.turnInDialogue or {}
            local speaker = td.speaker or quest.npcName or npc.Name or "NPC"
            local choices = td.choices or { { text = "Complete Quest", action = "complete_quest" } }
            ShowDialogueNode(quest, speaker, td.text or "You completed it!", choices)
            return true
        else
            local pd = quest.progressDialogue or {}
            local speaker = pd.speaker or quest.npcName or npc.Name or "NPC"
            local choices = pd.choices or { { text = "I'm on it.", action = "close" } }
            ShowDialogueNode(quest, speaker, pd.text or "Still working on it?", choices)
            return true
        end
    elseif state == "completed" then
        local cd = quest.completedDialogue or {}
        if cd.text then
            local speaker = cd.speaker or quest.npcName or npc.Name or "NPC"
            ShowDialogueNode(quest, speaker, cd.text, { { text = "See you around.", action = "close" } })
            return true
        end
    end
    return false
end

-- =========================================================================
-- Quest Markers (3D Overhead Bobbing & Minimap Icons)
-- =========================================================================
QuestMarkerUI = { Markers = {}, Built = false }
CompanionMinimapIcons = {}
RegisteredMinimapIcons = {}
CachedQuestTextures = {}
DefaultUMGMat = nil
MapIconCompClass = nil
LastDailyCheckTime = 0
LastMinimapCheckTime = 0
LastCompanionScanTime = 0
LastObjectiveCheckTime = 0
LastObjectiveResult = {}
CachedWorldCompanions = {}

OnWorldChange[#OnWorldChange + 1] = function()
    for _, m in pairs(QuestMarkerUI.Markers or {}) do
        if m and Valid(m.Widget) then
            pcall(function() m.Widget:RemoveFromViewport() end)
        end
    end
    QuestMarkerUI.Markers = {}
    CompanionMinimapIcons = {}
    RegisteredMinimapIcons = {}
    LastObjectiveResult = {}
    CachedWorldCompanions = {}
    LastCompanionScanTime = 0
end

function GetQuestTexture(path)
    if not path or path == "" then return nil end
    if CachedQuestTextures[path] and Valid(CachedQuestTextures[path]) then
        return CachedQuestTextures[path]
    end
    local tex = StaticFindObject(path)
    if not Valid(tex) and StaticLoadObject then
        pcall(function()
            local texClass = StaticFindObject("/Script/Engine.Texture2D")
            tex = StaticLoadObject(texClass, nil, path)
        end)
    end
    if Valid(tex) then CachedQuestTextures[path] = tex end
    return tex
end

function GetMapIconMaterial()
    if Valid(DefaultUMGMat) then return DefaultUMGMat end
    local path = "/MinimapPlugin/Materials/Icons/M_UMG_MapIcon.M_UMG_MapIcon"
    local mat = StaticFindObject(path)
    if not Valid(mat) and StaticLoadObject then
        pcall(function()
            local matClass = StaticFindObject("/Script/Engine.Material")
            mat = StaticLoadObject(matClass, nil, path)
        end)
    end
    if Valid(mat) then DefaultUMGMat = mat end
    return mat
end

function EnsureCompanionMinimapIcon(actor, quest, markerState)
    if not Valid(actor) then return nil end
    local addr = nil
    pcall(function() addr = actor:GetAddress() end)
    if not addr then return nil end

    if not MapIconCompClass or not Valid(MapIconCompClass) then
        MapIconCompClass = StaticFindObject("/Script/MinimapPlugin.MapIconComponent")
    end
    if not MapIconCompClass or not Valid(MapIconCompClass) then return nil end

    local comp = CompanionMinimapIcons[addr]
    if not Valid(comp) then
        if actor.GetComponentByClass then
            pcall(function() comp = actor:GetComponentByClass(MapIconCompClass) end)
        end
    end

    local transform = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = 0, Y = 0, Z = 120.0 },
        Scale3D = { X = 1, Y = 1, Z = 1 }
    }

    if not Valid(comp) then
        local ok, res = pcall(function()
            return actor:AddComponentByClass(MapIconCompClass, false, transform, false)
        end)
        if ok and Valid(res) then
            comp = res
            CompanionMinimapIcons[addr] = comp
        end
    end
    if not Valid(comp) then return nil end

    local tex = GetQuestTexture("/Game/Art/UI/Map/T_Map_Primary_Quest_Icon_NPC.T_Map_Primary_Quest_Icon_NPC")
        or GetQuestTexture("/Game/Art/UI/NavIcons/T_NavIcons_QuestMarker.T_NavIcons_QuestMarker")
        or GetQuestTexture("/MinimapPlugin/Textures/Icons/T_Icon_Placeholder.T_Icon_Placeholder")

    local umgMat = GetMapIconMaterial()

    pcall(function()
        if Valid(umgMat) then
            comp.IconMaterial_UMG = umgMat
            comp.InitialIconMaterial_UMG = umgMat
            if comp.SetIconMaterialForUMG then comp:SetIconMaterialForUMG(umgMat) end
        end
        if Valid(tex) and comp.SetIconTexture then comp:SetIconTexture(tex) end

        local color = { R = 1.0, G = 0.85, B = 0.15, A = 1.0 }
        local size = 26.0
        local visible = (markerState ~= nil)

        if markerState == "available" then
            color = { R = 1.0, G = 0.85, B = 0.15, A = 1.0 }
            size = 28.0
        elseif markerState == "active" then
            color = { R = 0.7, G = 0.85, B = 1.0, A = 1.0 }
            size = 24.0
        elseif markerState == "turnin" then
            color = { R = 1.0, G = 0.95, B = 0.1, A = 1.0 }
            size = 32.0
        end

        if comp.SetIconDrawColor then comp:SetIconDrawColor(color) end
        if comp.SetIconSize then comp:SetIconSize(size, 0) end
        if comp.SetIconZOrder then comp:SetIconZOrder(160) end
        if comp.SetIconVisible then comp:SetIconVisible(visible) end
        if comp.SetObjectiveArrowEnabled then comp:SetObjectiveArrowEnabled(visible) end

        local arrowTex = GetQuestTexture("/MinimapPlugin/Textures/Icons/T_Icon_ObjectiveArrow.T_Icon_ObjectiveArrow")
        if Valid(arrowTex) and comp.SetObjectiveArrowTexture then
            comp:SetObjectiveArrowTexture(arrowTex)
        end
    end)

    if not RegisteredMinimapIcons[addr] then
        RegisteredMinimapIcons[addr] = true
        pcall(function()
            local maps = FindAllOf("WBP_DominionMinimap_C") or {}
            for _, m in ipairs(maps) do
                if Valid(m) and m.AddMapIcon then
                    m:AddMapIcon(comp)
                end
            end
        end)
    end

    return comp
end

function NewQuestMarkerWidget(pc)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not Valid(lib) then return nil end
    local cls = StaticFindObject(BUTTON_CLASS)
    if not Valid(cls) and LoadAsset then
        pcall(LoadAsset, BUTTON_CLASS)
        cls = StaticFindObject(BUTTON_CLASS)
    end
    if not Valid(cls) then
        cls = StaticFindObject(LABEL_CLASS)
        if not Valid(cls) and LoadAsset then
            pcall(LoadAsset, LABEL_CLASS)
            cls = StaticFindObject(LABEL_CLASS)
        end
    end
    if not Valid(cls) then return nil end
    local w = lib:Create(pc, cls, pc)
    if not Valid(w) then return nil end
    w:SetIsFocusable(false)
    w:SetVisibility(1) -- COLLAPSED
    w:AddToViewport(10095)
    return w
end

function EnsureQuestMarkerWidget(addr, pc)
    if QuestMarkerUI.Markers[addr] and Valid(QuestMarkerUI.Markers[addr].Widget) then
        return QuestMarkerUI.Markers[addr]
    end
    local w = NewQuestMarkerWidget(pc)
    if not Valid(w) then return nil end

    local m = {
        Widget = w,
        Visible = false
    }
    QuestMarkerUI.Markers[addr] = m
    return m
end

function HideAllQuestMarkers()
    for _, m in pairs(QuestMarkerUI.Markers or {}) do
        if m and Valid(m.Widget) then
            pcall(function() m.Widget:SetVisibility(1) end)
        end
        if m then m.Visible = false end
    end
end

function UpdateQuestWorldMarkers()
    local pc = GetPC()
    if not Valid(pc) then
        HideAllQuestMarkers()
        return
    end

    local _, pawn = Pawn()
    if not Valid(pawn) then
        HideAllQuestMarkers()
        return
    end

    local pLoc = nil
    local okLoc, locRes = pcall(function() return pawn:K2_GetActorLocation() end)
    if okLoc and locRes then pLoc = locRes end
    if not pLoc then return end

    local nowClock = os.clock()
    if nowClock - LastDailyCheckTime > 5.0 then
        LastDailyCheckTime = nowClock
        pcall(CheckAllDailyQuests)
    end

    local updateMinimap = false
    if nowClock - LastMinimapCheckTime > 1.0 then
        LastMinimapCheckTime = nowClock
        updateMinimap = true
    end

    local checkObjectives = false
    if nowClock - LastObjectiveCheckTime > 0.5 then
        LastObjectiveCheckTime = nowClock
        checkObjectives = true
    end

    local companions = {}
    for _, info in pairs(BaseNPCs or {}) do
        if info and Valid(info.Actor) then companions[#companions + 1] = info end
    end
    if #companions == 0 then
        if nowClock - LastCompanionScanTime > 5.0 then
            LastCompanionScanTime = nowClock
            CachedWorldCompanions = FindAllCompanions()
        end
        for _, a in ipairs(CachedWorldCompanions or {}) do
            if Valid(a) then
                companions[#companions + 1] = { Actor = a, Name = "Doric", Key = "doric" }
            end
        end
    end

    local seenMarkers = {}
    local timeSec = os.clock()

    for _, info in ipairs(companions) do
        local actor = info.Actor
        if Valid(actor) then
            local addr = nil
            pcall(function() addr = actor:GetAddress() end)
            if addr then
                local quest = QuestForNPC(info)
                if quest then
                    local qid = quest.id
                    local st = QuestStates[qid] and QuestStates[qid].state or "unstarted"
                    local markerType = nil

                    if st == "unstarted" then
                        markerType = "available"
                    elseif st == "active" then
                        if checkObjectives or LastObjectiveResult[qid] == nil then
                            LastObjectiveResult[qid] = CheckQuestObjective(quest)
                        end
                        if LastObjectiveResult[qid] then
                            markerType = "turnin"
                        else
                            markerType = "active"
                        end
                    end

                    if updateMinimap then
                        pcall(EnsureCompanionMinimapIcon, actor, quest, markerType)
                    end

                    local m = EnsureQuestMarkerWidget(addr, pc)
                    if m and markerType then
                        seenMarkers[addr] = true
                        local aLoc = nil
                        pcall(function() aLoc = actor:K2_GetActorLocation() end)

                        if aLoc then
                            local dist = Dist(aLoc, pLoc)
                            if dist <= 3500 then
                                local bob = math.sin(timeSec * 3.8) * 7.0
                                local offsetZ = 85.0
                                pcall(function()
                                    if Valid(actor.CapsuleComponent) then
                                        local hh = actor.CapsuleComponent:GetScaledCapsuleHalfHeight()
                                        if hh and hh > 30.0 then offsetZ = hh + 25.0 end
                                    end
                                end)
                                local headLoc = { X = aLoc.X, Y = aLoc.Y, Z = aLoc.Z + offsetZ + bob }

                                local okP, retP, scrPos = pcall(function()
                                    return pc:ProjectWorldLocationToScreen(headLoc, false)
                                end)

                                if okP and retP == true and scrPos and scrPos.X and scrPos.Y then
                                    local lay = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
                                    local dpi = 1.0
                                    if Valid(lay) then
                                        local s = lay:GetViewportScale(pc)
                                        if s and s > 0 then dpi = s end
                                    end
                                    local sx = scrPos.X / dpi
                                    local sy = scrPos.Y / dpi

                                    local scale = math.max(0.8, math.min(1.2, 1.25 - (dist / 3500) * 0.45))
                                    local bw = math.floor(52 * scale)
                                    local bh = math.floor(48 * scale)

                                    local w = m.Widget
                                    if Valid(w) then
                                        w:SetAlignmentInViewport({ X = 0.5, Y = 1.0 })
                                        w:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
                                        w:SetPositionInViewport({ X = sx, Y = sy }, false)
                                        w:SetDesiredSizeInViewport({ X = bw, Y = bh })

                                        local symbol = "!"
                                        if markerType == "available" then
                                            symbol = "!"
                                        elseif markerType == "active" then
                                            symbol = "?"
                                        elseif markerType == "turnin" then
                                            symbol = "?"
                                        end

                                        pcall(function()
                                            if Valid(w.LabelText) then
                                                w.LabelText:SetText(Text(symbol))
                                            elseif Valid(w.ButtonLabel) then
                                                w.ButtonLabel:SetText(Text(symbol))
                                            else
                                                w:SetLabelText(Text(symbol))
                                            end
                                        end)

                                        pcall(function()
                                            local txt = Valid(w.LabelText) and w.LabelText or (Valid(w.ButtonLabel) and w.ButtonLabel or nil)
                                            if Valid(txt) then
                                                local col = { R = 1.0, G = 0.85, B = 0.15, A = 1.0 }
                                                if markerType == "active" then
                                                    col = { R = 0.75, G = 0.8, B = 0.85, A = 0.95 }
                                                elseif markerType == "turnin" then
                                                    local pulse = 0.8 + 0.2 * math.sin(timeSec * 6.0)
                                                    col = { R = 1.0, G = pulse, B = 0.1, A = 1.0 }
                                                end
                                                txt:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
                                            end
                                        end)

                                        pcall(function() w:SetVisibility(0) end) -- VISIBLE
                                        m.Visible = true
                                    end
                                else
                                    if Valid(m.Widget) then pcall(function() m.Widget:SetVisibility(1) end) end
                                    m.Visible = false
                                end
                            else
                                if Valid(m.Widget) then pcall(function() m.Widget:SetVisibility(1) end) end
                                m.Visible = false
                            end
                        end
                    end
                end
            end
        end
    end

    for addr, m in pairs(QuestMarkerUI.Markers) do
        if not seenMarkers[addr] and m.Visible then
            if Valid(m.Widget) then pcall(function() m.Widget:SetVisibility(1) end) end
            m.Visible = false
        end
    end
end

-- Key bindings for dialogue choices
function SafeBind(k, fn)
    if k then pcall(Bind, k, nil, fn) end
end
function SafeSelectChoice(index)
    ExecuteInGameThread(function()
        local ok, err = pcall(SelectDialogueChoice, index)
        if not ok then
            Log("SelectDialogueChoice error: " .. tostring(err))
            pcall(HideDialogue)
        end
    end)
end
SafeBind(Key.ONE, function() if InDialogue then SafeSelectChoice(1) end end)
SafeBind(Key.TWO, function() if InDialogue then SafeSelectChoice(2) end end)
SafeBind(Key.THREE, function() if InDialogue then SafeSelectChoice(3) end end)
SafeBind(Key.FOUR, function() if InDialogue then SafeSelectChoice(4) end end)
SafeBind(Key.SPACE_BAR, function() if InDialogue then SafeSelectChoice(1) end end)
SafeBind(Key.ESCAPE, function() if InDialogue then HideDialogue() end end)
SafeBind(Key.NUM_ONE, function() if InDialogue then SafeSelectChoice(1) end end)
SafeBind(Key.NUM_TWO, function() if InDialogue then SafeSelectChoice(2) end end)
SafeBind(Key.NUM_THREE, function() if InDialogue then SafeSelectChoice(3) end end)
SafeBind(Key.NUM_FOUR, function() if InDialogue then SafeSelectChoice(4) end end)

-- =========================================================================
-- Base Companion Interaction (E)
-- =========================================================================
function TriggerCompanionBark(npc)
    if not npc then return end
    local k = npc.Key or "npc"
    local barks = NPCBarks[k]
    if not barks then
        for barkKey, list in pairs(NPCBarks) do
            if k:find(barkKey, 1, true) then barks = list; break end
        end
    end
    if not barks then
        barks = {
            string.format("%s: Hello there, builder!", npc.Name or "Companion"),
            string.format("%s: A peaceful day in your base.", npc.Name or "Companion")
        }
    end
    local bark = barks[math.random(#barks)]
    Say(bark)
end

Bind(Key.E, nil, function()
    if UI.Visible or Skin then return end
    local _, pawn = Pawn()
    if not pawn then return end
    -- 1. Check if aiming directly at a companion (within 350cm)
    local lookedId = FindLookedAt(350)
    local a = lookedId and Props[lookedId]
    if Valid(a) and BaseNPCs[a:GetAddress()] then
        local npc = BaseNPCs[a:GetAddress()]
        if HandleCompanionInteraction(npc) then return end
        TriggerCompanionBark(npc)
        return
    end
    -- 2. Check closest companion within 250 cm
    local p = pawn:K2_GetActorLocation()
    local bestNpc, bestD = nil, 62500 -- 250cm squared
    for addr, n in pairs(BaseNPCs) do
        if Valid(n.Actor) then
            local l = n.Actor:K2_GetActorLocation()
            local dx, dy, dz = l.X - p.X, l.Y - p.Y, l.Z - p.Z
            local d2 = dx*dx + dy*dy + dz*dz
            if d2 < bestD then
                bestNpc = n
                bestD = d2
            end
        end
    end
    if bestNpc then
        if HandleCompanionInteraction(bestNpc) then return end
        TriggerCompanionBark(bestNpc)
    end
end)

-- Hovering one of our tiles shows the model's name in the panel title.
do
    local function TileIndex(ctx)
        if not UI.Visible then return nil end
        local ok, tile = pcall(function() return ctx:get() end)
        if not ok or not Valid(tile) then return nil end
        for i, t in ipairs(UI.Tiles) do
            if Valid(t) and t:GetAddress() == tile:GetAddress() then return i end
        end
        return nil
    end
    pcall(function()
        RegisterHook("/Script/Dominion.BuildingUISlotBase:OnSlotHovered", function(ctx)
            local i = TileIndex(ctx)
            if i and UI.TileModel[i] then
                local name = UI.TileModel[i].Name:upper()
                ExecuteInGameThread(function() Label(UI.Header, name) end)
            end
        end)
    end)
    -- A click on one of our tiles may arrive as the game's own "slot selected".
    pcall(function()
        RegisterHook("/Script/Dominion.BuildingUISlotBase:OnSlotSelected", function(ctx)
            local i = TileIndex(ctx)
            if i and UI.TileModel[i] then
                local m = UI.TileModel[i]
                ExecuteInGameThread(function() if UI.Visible then Pick(m) end end)
            end
        end)
    end)
    pcall(function()
        RegisterHook("/Script/Dominion.BuildingUISlotBase:OnSlotUnhovered", function(ctx)
            if TileIndex(ctx) and UI.HeaderText then
                local text = UI.HeaderText
                ExecuteInGameThread(function() Label(UI.Header, text) end)
            end
        end)
    end)
end

-- Writes the build menu's widget structure to the log (build menu must be open).
MenuProbeFn = function(Say)
    local function cls(o) return ClassName(o) end
    local function dump(w, depth, maxDepth)
        if not Valid(w) or depth > maxDepth then return end
        local extra = ""
        pcall(function() if w.GetText then extra = " text='" .. w:GetText():ToString() .. "'" end end)
        Log(string.rep("  ", depth) .. cls(w) .. " " .. NameOf(w) .. extra)
        local n = 0
        pcall(function() n = w:GetChildrenCount() end)
        for i = 0, math.min(n, 30) - 1 do
            local c = nil
            pcall(function() c = w:GetChildAt(i) end)
            dump(c, depth + 1, maxDepth)
        end
        pcall(function()
            local root = w.WidgetTree.RootWidget
            if Valid(root) then dump(root, depth + 1, maxDepth) end
        end)
    end
    local slots = FindAllOf("WBP_BuildingCategoryItemSlot_C") or {}
    Say(string.format("%d build menu tiles", #slots))
    local shown = 0
    for _, s in ipairs(slots) do
        local vis = false
        pcall(function() vis = s:IsVisible() end)
        if vis and shown < 2 then
            shown = shown + 1
            local d = nil
            pcall(function() d = s.ContainedItemDataRow end)
            Log("TILE data=" .. (Valid(d) and NameOf(d) or "?") .. " index=" .. tostring(s.CategorySlotIndex))
            local p, chain = nil, {}
            pcall(function() p = s:GetParent() end)
            for _ = 1, 6 do
                if not Valid(p) then break end
                chain[#chain + 1] = cls(p) .. ":" .. NameOf(p)
                local q = nil
                pcall(function() q = p:GetParent() end)
                p = q
            end
            Log("TILE parents: " .. table.concat(chain, " <- "))
            dump(s, 0, 6)
        end
    end
    for _, c in ipairs(FindAllOf("BuildingAccordionCategoryContent") or {}) do
        local vis = false
        pcall(function() vis = c:IsVisible() end)
        if vis then
            local n = 0
            pcall(function() n = c.ContentContainer:GetChildrenCount() end)
            Log(string.format("CATEGORY %s container=%s children=%d slotclass=%s", NameOf(c),
                Valid(c.ContentContainer) and cls(c.ContentContainer) or "?", n,
                NameOf(c.ItemSlotWidgetRef)))
        end
    end
    for _, t in ipairs(FindAllOf("WBP_Building_NavigableTabButton_C") or {}) do
        Log("TAB " .. NameOf(t))
    end
    Say("Build menu structure written to UE4SS.log")
end

-- For the ashenfallen.com base builder: "cb anchor" saves where you aim (or stand) as
-- the anchor of your build (anchor.txt) and your normal building pieces within 150 m
-- as a reference (base.txt). The website builds around the anchor and writes
-- placed.txt in world positions, which the mod then shows live.
function SetAnchor()
    local _, pawn = Pawn()
    if not pawn then return "Not in a world" end
    local p = CrosshairHit()
    if not p then
        local l = pawn:K2_GetActorLocation()
        p = { X = l.X, Y = l.Y, Z = l.Z - 90 }
    end
    local _, _, rot = CameraView()
    local yaw = rot and rot.Yaw or 0
    WriteText("anchor.txt", string.format("# CustomBuilds anchor: x|y|z|yaw (cm, degrees). Written by cb anchor.\n%.2f|%.2f|%.2f|%.2f\n",
        p.X, p.Y, p.Z, yaw))
    WriteText("player.txt", string.format("%.2f|%.2f|%.2f|%.2f\n", p.X, p.Y, p.Z, yaw))
    -- The normal building pieces around it, as a reference for the website.
    local m = Manager()
    local names = PieceNames()
    local lines = { "# CustomBuilds base reference: piece|x|y|z|yaw. Written by cb anchor." }
    local count = 0
    if m then
        pcall(function()
            m.BuildingPieces:ForEach(function(_, state)
                local cv = Get(state).ClientVisible
                local l = cv.Location
                if Dist(l, p) < 15000 then
                    count = count + 1
                    lines[#lines + 1] = string.format("%s|%.2f|%.2f|%.2f|%.2f",
                        names[tonumber(cv.BuildingPieceDataIndex)] or ("piece" .. tostring(cv.BuildingPieceDataIndex)),
                        l.X, l.Y, l.Z, cv.Yaw)
                end
            end)
        end)
    end
    WriteText("base.txt", table.concat(lines, "\n") .. "\n")
    return string.format("Anchor set; %d building pieces within 150 m saved for the base builder", count)
end

RegisterConsoleCommandHandler("cb", function(full, params, out)
    LastConsoleOut = out
    CheckWorld()
    local cmd = params[1] and params[1]:lower() or ""
    local ok, err = pcall(function()
        if cmd == "" or cmd == "list" then
            for i, m in ipairs(Models) do Say(string.format("%d  %s", i, m.Name)) end
            Say("Picked: " .. (Skin and Skin.Name or "none") .. ". Type cb <number>, then place a small decoration.")
        elseif tonumber(cmd) then
            local m = Models[tonumber(cmd)]
            if not m then Say("No model " .. cmd); return end
            if not LoadMesh(m.Mesh) then Say("Mesh not found for " .. m.Name); return end
            Skin = m
            StartGhost()
            ShowHint()
            Say("Picked " .. m.Name .. ". Left click places it where you look; right click or Esc stops.")
        elseif cmd == "off" then
            Skin = nil
            HideHint()
            Say("Off. Pieces you place are normal again.")
        elseif cmd == "undo" then
            Say(Undo())
        elseif cmd == "ui" then
            if UI.Visible then HideUI() else ShowUI() end
        elseif cmd == "menuprobe" then
            MenuProbeFn(Say)
        elseif cmd == "find" or cmd == "search" then
            local words = {}
            for i = 2, #params do words[#words + 1] = params[i] end
            local text = table.concat(words, " ")
            if text == "" then Say("Type: cb find <words>, e.g. cb find statue"); return end
            local n = Search(text)
            Say(string.format("%d models match \"%s\". Open the build menu to see them.", n, text))
            if UI.Visible then Refresh() end
        elseif cmd == "import" then
            Say(ImportStarred())
        elseif cmd == "anchor" then
            Say(SetAnchor())
        elseif cmd == "restore" then
            local spawned, removed = Restore()
            Say(string.format("Restored %d models, removed %d whose piece is gone", spawned, removed))
        elseif cmd == "probe" then
            Probe(Say)
        elseif cmd == "spawn" then
            local m = Models[tonumber(params[2] or "1") or 1]
            if not m then Say("No such model"); return end
            local _, pawn = Pawn()
            local loc, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
            local a, why = SpawnModel(m.Mesh, { X = loc.X + fwd.X * 400, Y = loc.Y + fwd.Y * 400, Z = loc.Z - 90 })
            if a then TestProps[#TestProps + 1] = a; Say("Spawned " .. m.Name .. " 4 m in front of you (test only, not saved)")
            else Say(tostring(why)) end
        elseif cmd == "clear" then
            for _, a in ipairs(TestProps) do if Valid(a) then pcall(function() a:K2_DestroyActor() end) end end
            TestProps = {}
            local d, _ = CleanupCompanions(false)
            Say(string.format("Test props and %d companion(s) removed", d))
        elseif cmd == "npcs" then
            Say("Available NPCs: doric, wise, vannaka, zanik, cook, death, pete, chicken, cow, garou, chin, pet_chin, dummy, mannequin, guard, zilyana")
            Say("Usage: cb npc <name>, cb npc clean (removes duplicates), cb npc clear (removes all)")
        elseif cmd == "npc" then
            local which = params[2] and params[2]:lower() or "doric"
            if which == "clean" then
                local d, k = CleanupCompanions(true)
                Say(string.format("Cleaned duplicates: removed %d, kept %d companion(s)", d, k))
                return
            elseif which == "clear" or which == "purge" or which == "reset" then
                local d, _ = CleanupCompanions(false)
                local removedPlaced = 0
                for id, r in pairs(Placed or {}) do
                    if ResolveNPCBlueprint(r.Mesh) then
                        DestroyProp(id)
                        Placed[id] = nil
                        removedPlaced = removedPlaced + 1
                    end
                end
                if removedPlaced > 0 then SavePlaced() end
                BaseNPCs = {}
                Say(string.format("Cleared all companions (%d actors removed, %d placed records cleared). Clean slate!", d, removedPlaced))
                return
            end
            local npcMap = {
                doric = "/Game/Gameplay/NPCs/BP_NPC_Doric.BP_NPC_Doric_C",
                wise = "/Game/Gameplay/NPCs/BP_NPC_WiseOldMan.BP_NPC_WiseOldMan_C",
                wiseoldman = "/Game/Gameplay/NPCs/BP_NPC_WiseOldMan.BP_NPC_WiseOldMan_C",
                vannaka = "/Game/Gameplay/NPCs/BP_NPC_Vannaka_Fellhollow.BP_NPC_Vannaka_Fellhollow_C",
                zanik = "/Game/Gameplay/NPCs/BP_NPC_Zanik_Fellhollow.BP_NPC_Zanik_Fellhollow_C",
                cook = "/Game/Gameplay/NPCs/CooksAssistant_NPCs/BP_NPC_Cook.BP_NPC_Cook_C",
                death = "/Game/Gameplay/NPCs/BP_NPC_Death.BP_NPC_Death_C",
                pete = "/Game/Gameplay/NPCs/BP_NPC_PostiePete.BP_NPC_PostiePete_C",
                chicken = "/Game/Gameplay/NPCs/CooksAssistant_NPCs/BP_NPC_Quest_Chicken.BP_NPC_Quest_Chicken_C",
                cow = "/Game/Gameplay/NPCs/CooksAssistant_NPCs/BP_NPC_Quest_Cow.BP_NPC_Quest_Cow_C",
                garou = "/Game/Gameplay/NPCs/BP_NPC_Elder_Garou.BP_NPC_Elder_Garou_C",
                chin = "/ScornedWilderness/Gameplay/BaseBuilding/Blueprints/BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa.BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa_C",
                pet_chin = "/ScornedWilderness/Gameplay/BaseBuilding/Blueprints/BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa.BP_BaseBuilding_Decoration_DeluxeEdition_Pet_Chinchompa_C",
                dummy = "/Game/Gameplay/BaseBuilding/Actors/Props/BP_BaseBuilding_TrainingDummy.BP_BaseBuilding_TrainingDummy_C",
                mannequin = "/Game/Gameplay/BaseBuilding/Actors/Props/BP_BaseBuilding_ArmourMannequin.BP_BaseBuilding_ArmourMannequin_C",
                guard = "/Game/Gameplay/NPCs/BP_NPC_KotHaarBouncer.BP_NPC_KotHaarBouncer_C",
                zilyana = "/ScornedWilderness/Gameplay/Quests/NPCs/BP_NPC_SW_Zilyana.BP_NPC_SW_Zilyana_C",
                domri = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Hawker.BP_NPC_UmS_Trader_Hawker_C",
                merchant = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Hawker.BP_NPC_UmS_Trader_Hawker_C",
                hawker = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Hawker.BP_NPC_UmS_Trader_Hawker_C",
                valas = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Smith.BP_NPC_UmS_Trader_Smith_C",
                blacksmith = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Smith.BP_NPC_UmS_Trader_Smith_C",
                lagra = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Hunter.BP_NPC_UmS_Trader_Hunter_C",
                hunter = "/UmbralSands/Gameplay/NPCs/BP_NPC_UmS_Trader_Hunter.BP_NPC_UmS_Trader_Hunter_C",
            }
            local bpPath = npcMap[which] or ResolveNPCBlueprint(which) or which
            local _, pawn = Pawn()
            if not pawn then Say("Not in world"); return end
            local loc = pawn:K2_GetActorLocation()
            local fwd = pawn:GetActorForwardVector()
            local rot = pawn:K2_GetActorRotation()
            local r = {
                X = loc.X + fwd.X * 250,
                Y = loc.Y + fwd.Y * 250,
                Z = loc.Z - 40,
                Yaw = (rot.Yaw or 0) + 180,
                Pitch = 0,
                Roll = 0,
                Scale = 1
            }
            local a, why = SpawnNPC(bpPath, r, false)
            if Valid(a) then
                TestProps[#TestProps + 1] = a
                Say("Spawned Companion: " .. which .. "! Walk up and press E to chat. Use cb clear to remove.")
            else
                Say("Failed to spawn " .. which .. ": " .. tostring(why))
            end
        elseif cmd == "quest" or cmd == "quests" then
            local sub = params[2] and params[2]:lower() or ""
            if sub == "reload" then
                LoadQuests()
                UpdateTrackerUI()
                Say("Reloaded quests from quests.json")
            elseif sub == "reset" then
                QuestStates = {}
                SaveQuestsState()
                ActiveQuestId = nil
                LoadQuests()
                UpdateTrackerUI()
                Say("Reset all quest progression!")
            elseif sub == "daily" then
                CheckAllDailyQuests()
                Say("Checked daily reset for repeatable quests.")
            elseif sub == "step" then
                if ActiveQuestId then
                    local q = nil
                    for _, quest in ipairs(Quests or {}) do
                        if quest.id == ActiveQuestId then q = quest; break end
                    end
                    local st = QuestStates[ActiveQuestId] or { state = "active", progress = 0 }
                    st.progress = (st.progress or 0) + 1
                    QuestStates[ActiveQuestId] = st
                    SaveQuestsState()
                    UpdateTrackerUI()
                    Say(string.format("Quest '%s' stepped: %d/%d", (q and q.title or ActiveQuestId), st.progress, (q and q.objective and q.objective.count or 1)))
                else
                    Say("No active quest to advance.")
                end
            elseif sub == "check" then
                if ActiveQuestId then
                    local q = nil
                    for _, quest in ipairs(Quests or {}) do
                        if quest.id == ActiveQuestId then q = quest; break end
                    end
                    if q and q.objective and q.objective.type == "item" then
                        local c = CountPlayerItems(q.objective.item)
                        Say(string.format("Quest '%s': Found %d/%d '%s' in inventory", q.title, c, q.objective.count or 1, q.objective.item))
                    else
                        Say(string.format("Active quest '%s' is not an item collection objective.", q and q.title or ActiveQuestId))
                    end
                else
                    Say("No active quest to check.")
                end
            elseif sub == "complete" then
                if ActiveQuestId then
                    local q = nil
                    for _, quest in ipairs(Quests or {}) do
                        if quest.id == ActiveQuestId then q = quest; break end
                    end
                    local st = QuestStates[ActiveQuestId] or { state = "completed", progress = 1 }
                    st.state = "completed"
                    QuestStates[ActiveQuestId] = st
                    ActiveQuestId = nil
                    SaveQuestsState()
                    UpdateTrackerUI()
                    Say(string.format("Quest '%s' marked completed!", (q and q.title or "Quest")))
                else
                    Say("No active quest to complete.")
                end
            else
                Say("Quest commands: cb quest reload, cb quest reset, cb quest step, cb quest check, cb quest complete")
                local count = 0
                for _, q in ipairs(Quests or {}) do
                    count = count + 1
                    local st = QuestStates[q.id] and QuestStates[q.id].state or "unstarted"
                    local prog = QuestStates[q.id] and QuestStates[q.id].progress or 0
                    Say(string.format(" - [%s] %s (%s, %d/%d)", q.id, q.title or "Untitled", st, prog, (q.objective and q.objective.count or 1)))
                end
                if count == 0 then Say("No quests currently loaded. Check quests.json!") end
            end
        elseif cmd == "inv" then
            local inv = GetPlayerInventory()
            if not Valid(inv) then
                Say("Player inventory component not found.")
            else
                local numSlots = 0
                pcall(function() numSlots = inv.ItemSlots:GetArrayNum() end)
                local found = 0
                for i = 1, numSlots do
                    local item = nil
                    pcall(function() item = inv.ItemSlots[i] end)
                    if item and Valid(item) then
                        local count = 0
                        pcall(function() count = item:GetStackSize() end)
                        local name = nil
                        pcall(function()
                            local facing = item:GetPlayerFacingName()
                            if facing and facing.ToString then name = facing:ToString() end
                        end)
                        if not name or name == "" then
                            pcall(function() if item.ItemData then name = item.ItemData:GetFName():ToString() end end)
                        end
                        if name then
                            found = found + 1
                            Say(string.format("Slot %d: %s x%d", i, name, count or 1))
                        end
                    end
                end
                if found == 0 then Say("Player inventory is empty.") end
            end
        elseif cmd == "clean" then
            local d, k = CleanupCompanions(true)
            Say(string.format("Cleaned duplicates: removed %d, kept %d companion(s)", d, k))
        elseif cmd == "reward" then
            local item = params[2] or "GarouPack"
            local count = tonumber(params[3]) or 10
            local ok, res = GivePlayerItem(item, count)
            if ok then
                Say(string.format("Gave player %d x %s!", count, item))
            else
                Say(string.format("Reward test failed: %s", tostring(res)))
            end
        elseif cmd == "portals" then
            local count = 0
            for id, r in pairs(Placed) do
                if r.Portal and r.Portal ~= "" then
                    count = count + 1
                    Say(string.format("Portal '%s' (id %s) -> Target '%s' at (%.0f, %.0f, %.0f)", r.Portal, id, r.Target or "none", r.X, r.Y, r.Z))
                end
            end
            if count == 0 then Say("No portals configured in placed.txt") end
        else
            Say("Commands: cb, cb <n>, cb off, cb undo, cb restore, cb probe, cb spawn <n>, cb npcs, cb npc <name>, cb clean, cb quest, cb portals, cb inv, cb reward, cb clear")
        end
    end)
    if not ok then Say("Error: " .. tostring(err)) end
    return true
end)

Log("Mod folder: " .. tostring(ModDir))
LoadModels()
LoadPlaced()
LoadOrient()
pcall(LoadQuests)
Log("Ready. F10 console: cb")
ModReady = true

-- Loaded (or reloaded) while already in a world: put models back and keep bases hidden.
ExecuteInGameThread(function()
    GetPC()
    if WorldKey() then
        CheckWorld()
        pcall(Restore)
        pcall(function() CleanupCompanions(true) end)
        StartHideTimer()
    end
end)

-- The ghost's loop, created once here (never from inside another timer).
if LoopInGameThreadWithDelay then
    GhostLoop = LoopInGameThreadWithDelay(50, function()
        local ok, err = pcall(GhostStep)
        if not ok then Log("Ghost loop: " .. tostring(err)) end
    end)
else
    Log("[DISCOVERY] LoopInGameThreadWithDelay is missing; no placement preview")
end
