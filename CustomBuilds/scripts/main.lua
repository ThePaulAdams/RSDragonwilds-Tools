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
                    elseif k == "scale" then r.Scale = tonumber(v) end
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
    return string.format("%s|%.2f|%.2f|%.2f|%.6f|%.6f|%.6f|%.6f|%s|base=%s;pitch=%g;roll=%g;scale=%g",
        id, r.X, r.Y, r.Z, r.QX, r.QY, r.QZ, r.QW, r.Mesh, r.Base or "", r.Pitch or 0, r.Roll or 0, r.Scale or 1)
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

-- Spawns a static mesh actor showing `meshPath` at r (X, Y, Z, yaw as QX..QW or Yaw,
-- Pitch, Roll, Scale). Everything is set before the actor finishes spawning, so the
-- engine registers it with its final mesh, transform and draw settings: placed props
-- stay static and are never hidden by distance. `movable` is for the moving ghost.
local function SpawnModel(meshPath, r, movable)
    local _, pawn = Pawn()
    if not pawn then return nil, "not in a world" end
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
    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
    local a = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 1, nil, 1)
    if not Valid(a) then return nil, "spawn failed" end
    local c = a.StaticMeshComponent
    if movable then pcall(function() c:SetMobility(2) end) end
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
    if Valid(a) then pcall(function() a:K2_DestroyActor() end) end
    Props[id] = nil
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
end

local GameWorld = nil   -- world key once a real game world (with a building manager) is seen

local function Restore(at)
    local spawned, removed = 0, 0
    -- Only in a real game world, never the main menu's.
    if not Manager() then return 0, 0 end
    GameWorld = WorldKey()
    pcall(AdoptExisting)
    for id, r in pairs(Placed) do
        local exists = id:find("^m") and true or PieceExists(id)
        if exists == false and at and Dist(at, r) <= 300 then
            DestroyProp(id)
            Placed[id] = nil
            removed = removed + 1
        elseif exists == true and not Valid(Props[id]) then
            local a, err = SpawnModel(r.Mesh, r)
            if a then Props[id] = a; spawned = spawned + 1 else Log("Restore " .. id .. ": " .. tostring(err)) end
        end
    end
    if removed > 0 then SavePlaced() end
    return spawned, removed
end

-- Live sync: when placed.txt is changed by something else (e.g. the ashenfallen.com
-- base builder writing into this folder), make the world match it. Checked every
-- couple of seconds from the ghost loop; nothing happens while the file is unchanged.
local SyncAt = 0
local function SyncPlaced()
    if not GameWorld or WorldKey() ~= GameWorld then return end
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

local function Add(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
local function Sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function Mul(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end

-- Local (mesh) offset to world, using an actor's axes.
local function ToWorld(f, r, u, v)
    return { X = f.X * v.X + r.X * v.Y + u.X * v.Z, Y = f.Y * v.X + r.Y * v.Y + u.Y * v.Z,
             Z = f.Z * v.X + r.Z * v.Y + u.Z * v.Z }
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
        local c = a.StaticMeshComponent
        pcall(function() c:SetCollisionEnabled(0) end)
        pcall(function() c:SetCastShadow(false) end)
        local mat = GhostMaterial()
        if mat then
            local n = 1
            pcall(function() n = c:GetNumMaterials() end)
            for i = 0, n - 1 do pcall(function() c:SetMaterial(i, mat) end) end
        end
        Ghost.Actor, Ghost.Mesh = a, Skin.Mesh
    end
    pcall(function() Ghost.Actor:SetActorHiddenInGame(false) end)
    Ghost.Actor:K2_SetActorLocationAndRotation({ X = pivot.X, Y = pivot.Y, Z = pivot.Z + Config.ZOffset },
        { Pitch = spitch, Yaw = syaw, Roll = sroll }, false, {}, true)
    pcall(function() Ghost.Actor:SetActorScale3D({ X = o.Scale, Y = o.Scale, Z = o.Scale }) end)
end

-- One permanent game-thread loop (UE4SS's own looping timer, created once when the
-- mod loads) drives the ghost; it does nothing unless a model is picked. Creating new
-- timers from inside timer callbacks, as this used to, corrupted UE4SS's timer list
-- and crashed the game.
local GhostLoop = nil

local function GhostStep()
    local now = os.clock()
    if now - SyncAt > 2 then
        SyncAt = now
        if CheckWorld() then
            local ok, err = pcall(SyncPlaced)
            if not ok then Log("Sync: " .. tostring(err)) end
        end
    end
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
local TILE_COLS, TILE_ROWS, TILE_SIZE = 8, 4, 80
local TILES_PER_PAGE = TILE_COLS * TILE_ROWS

local UI = { Built = false, Visible = false, Title = nil, Category = nil, Rows = {}, RowModel = {},
    Prev = nil, Next = nil, Off = nil, Import = nil, Page = 1, Cat = 1, Owned = {}, Tiles = {}, TileModel = {} }

OnWorldChange[#OnWorldChange + 1] = function()
    -- The widgets belonged to the old world's player and went with it.
    UI.Built, UI.Visible, UI.Title, UI.Category, UI.Rows, UI.RowModel = false, false, nil, nil, {}, {}
    UI.Prev, UI.Next, UI.Off, UI.Import, UI.Owned = nil, nil, nil, nil, {}
    UI.Tiles, UI.TileModel = {}, {}
    UI.Header, UI.CatPrev, UI.CatNext = nil, nil, nil
    UI.Backdrop = nil
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
local SearchResults = {}

local function Groups()
    local counts, list = {}, {}
    if #Models > 0 then list[#list + 1] = { Name = FAVOURITES, Count = #Models } end
    if UI.Search then list[#list + 1] = { Name = SEARCH, Count = #SearchResults } end
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
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    pcall(function() img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 }) end)
    pcall(function() if Valid(w.NewBuildingPieceIcon) then w.NewBuildingPieceIcon:SetVisibility(COLLAPSED) end end)
    pcall(function() if Valid(w.IconFavourited) then w.IconFavourited:SetVisibility(COLLAPSED) end end)
    -- The tile's size box fixes it at tile size; it is resized with the window in Layout.
    pcall(function()
        local box = img:GetParent():GetParent()
        if Valid(box) and box.SetWidthOverride then UI.BackdropBox = box end
    end)
    UI.BackdropImg = img
    UI.Backdrop = w
end

-- A free-standing panel (for the hint bar): { W = widget, Box, Img }.
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
        p.Box = p.Img:GetParent():GetParent()
    end)
    pcall(function() if Valid(w.NewBuildingPieceIcon) then w.NewBuildingPieceIcon:SetVisibility(COLLAPSED) end end)
    pcall(function() if Valid(w.IconFavourited) then w.IconFavourited:SetVisibility(COLLAPSED) end end)
    return p
end

local function SizePanel(p, x, y, w, h)
    Place(p.W, x, y, w, h)
    if Valid(p.Box) then pcall(function() p.Box:SetWidthOverride(w); p.Box:SetHeightOverride(h) end) end
    if Valid(p.Img) then pcall(function() p.Img:SetDesiredSizeOverride({ X = w, Y = h }) end) end
    pcall(function() p.W:SetVisibility(3) end)
end

local function BuildUI(pc)
    UI.Title = NewWidget(pc, LABEL_CLASS, 10050)
    UI.Category = NewWidget(pc, LABEL_CLASS, 10050)   -- search hint
    UI.Header = NewWidget(pc, LABEL_CLASS, 10050)     -- selected category + page
    for i = 1, PER_PAGE do UI.Rows[i] = NewWidget(pc, BUTTON_CLASS, 10051) end
    UI.CatPrev = NewWidget(pc, BUTTON_CLASS, 10051)
    UI.CatNext = NewWidget(pc, BUTTON_CLASS, 10051)
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
    -- Like the build menu: categories on the left, the chosen one's tiles on the right.
    local listW, rowH, h, gap = 360, 30, 44, 16
    local gridW = TILE_COLS * (TILE_SIZE + 5)
    local total = listW + gap + gridW
    local x = math.floor(vw / 2 - total / 2)
    local y = math.max(30, math.floor(vh / 2 - 360))
    local xr = x + listW + gap
    Place(UI.Title, x, y, total, h); y = y + h + 4
    Place(UI.Category, x, y, listW, h)
    Place(UI.Header, xr, y, gridW, h)
    y = y + h + 8
    local top = y
    for i = 1, PER_PAGE do Place(UI.Rows[i], x, top + (i - 1) * (rowH + 2), listW, rowH) end
    local listBottom = top + PER_PAGE * (rowH + 2) + 6
    Place(UI.CatPrev, x, listBottom, listW / 2 - 2, h)
    Place(UI.CatNext, x + listW / 2 + 2, listBottom, listW / 2 - 2, h)
    for i, t in ipairs(UI.Tiles) do
        local col, row = (i - 1) % TILE_COLS, math.floor((i - 1) / TILE_COLS)
        Place(t, xr + col * (TILE_SIZE + 5), top + row * (TILE_SIZE + 5), TILE_SIZE, TILE_SIZE)
    end
    local gy = top + TILE_ROWS * (TILE_SIZE + 5) + 10
    local third = math.floor((gridW - 8) / 3)
    Place(UI.Prev, xr, gy, third, h)
    Place(UI.Next, xr + third + 4, gy, third, h)
    Place(UI.Off, xr + 2 * (third + 4), gy, third, h)
    Place(UI.Import, xr, gy + h + 4, gridW, h)
    if Valid(UI.Backdrop) then
        local top = math.max(30, math.floor(vh / 2 - 360))
        local bw, bh = total + 80, (gy + 2 * h + 4) - top + 60
        Place(UI.Backdrop, x - 40, top - 30, bw, bh)
        if Valid(UI.BackdropBox) then
            pcall(function() UI.BackdropBox:SetWidthOverride(bw); UI.BackdropBox:SetHeightOverride(bh) end)
        end
        if Valid(UI.BackdropImg) then pcall(function() UI.BackdropImg:SetDesiredSizeOverride({ X = bw, Y = bh }) end) end
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
    Label(UI.Category, "SEARCH: F10  cb find <words>")

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

    -- Right: the chosen category's models as build-menu tiles.
    local items = UI.Group and ModelsIn(UI.Group) or {}
    local pages = math.max(1, math.ceil(#items / TILES_PER_PAGE))
    UI.Page = math.max(1, math.min(UI.Page, pages))
    local name = UI.Group == "SEARCH RESULTS" and ("SEARCH: " .. (UI.Search or "")) or (UI.Group or "")
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
    for _, key in ipairs({ "Title", "Category", "Header", "CatPrev", "CatNext", "Prev", "Next", "Off", "Import" }) do
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
        if not UI.Visible then return end
        local ok, button = pcall(function() return context:get() end)
        if not ok or not Valid(button) then return end
        local addr = button:GetAddress()
        local function is(w) return Valid(w) and w:GetAddress() == addr end
        ExecuteInGameThread(function()
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
            else
                for i, tile in ipairs(UI.Tiles) do
                    if is(tile) and UI.TileModel[i] then Pick(UI.TileModel[i]); return end
                end
                for i, row in ipairs(UI.Rows) do
                    local item = UI.RowModel[i]
                    if is(row) and item then
                        UI.Group, UI.Page = item.Name, 1
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
OnWorldChange[#OnWorldChange + 1] = function() TestProps = {} end

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
    return string.format("%s%s     TURN %d   TILT %d   ROLL %d   SIZE %.2f   SNAP %s%s\n"
        .. "LEFT CLICK place     RIGHT CLICK / ESC stop     N models     BACKSPACE undo     DEL delete     INS move\n"
        .. "LEFT/RIGHT turn   UP/DOWN tilt   CTRL+UP/DOWN roll   SHIFT = 90   +/- size   ALT+ARROWS, ALT +/- nudge   END snap   HOME reset",
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

local function Adjust(dYaw, dPitch, dRoll, scaleMul, reset)
    if not Skin then return end
    local o = OrientFor(Skin.Mesh)
    if reset then
        o = { Pitch = 0, Roll = 0, Scale = 1 }
        Placer.Yaw = 0
        Placer.Nudge = nil
    else
        Placer.Yaw = (Placer.Yaw + dYaw) % 360
        o.Pitch = (o.Pitch + dPitch) % 360
        o.Roll = (o.Roll + dRoll) % 360
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

local SHIFT, CTRL = { ModifierKey.SHIFT }, { ModifierKey.CONTROL }
Bind(Key.LEFT_ARROW, nil, function() Adjust(-15, 0, 0, 1) end)
Bind(Key.RIGHT_ARROW, nil, function() Adjust(15, 0, 0, 1) end)
Bind(Key.LEFT_ARROW, SHIFT, function() Adjust(-90, 0, 0, 1) end)
Bind(Key.RIGHT_ARROW, SHIFT, function() Adjust(90, 0, 0, 1) end)
Bind(Key.UP_ARROW, nil, function() Adjust(0, 15, 0, 1) end)
Bind(Key.DOWN_ARROW, nil, function() Adjust(0, -15, 0, 1) end)
Bind(Key.UP_ARROW, SHIFT, function() Adjust(0, 90, 0, 1) end)
Bind(Key.DOWN_ARROW, SHIFT, function() Adjust(0, -90, 0, 1) end)
Bind(Key.UP_ARROW, CTRL, function() Adjust(0, 0, 90, 1) end)
Bind(Key.DOWN_ARROW, CTRL, function() Adjust(0, 0, -90, 1) end)
Bind(Key.OEM_PLUS, nil, function() Adjust(0, 0, 0, 1.25) end)
Bind(Key.OEM_MINUS, nil, function() Adjust(0, 0, 0, 0.8) end)
Bind(Key.HOME, nil, function() Adjust(0, 0, 0, 1, true) end)
-- Nudge the model 10 cm at a time: Alt + Up/Down = away/towards you, Alt + Left/Right =
-- left/right, Alt + '+'/'-' = up/down. Home clears it.
local ALT = { ModifierKey.ALT }
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

-- End cycles snapping: edges of your models / grid of the nearest building / free.
Bind(Key.END, nil, function()
    if not Skin then return end
    Placer.Snap = Placer.Snap % #SNAP_MODES + 1
    ShowHint()
end)

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

-- Hovering one of our tiles shows the model's name in the panel title.
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
local function WriteText(name, text)
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

local function SetAnchor()
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
    local function Say(msg)
        Log(msg)
        pcall(function() out:Log(ModName .. ": " .. msg) end)
    end
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
            Say("Test props removed")
        else
            Say("Commands: cb, cb <n>, cb off, cb undo, cb restore, cb probe, cb spawn <n>, cb clear")
        end
    end)
    if not ok then Say("Error: " .. tostring(err)) end
    return true
end)

Log("Mod folder: " .. tostring(ModDir))
LoadModels()
LoadPlaced()
LoadOrient()
Log("Ready. F10 console: cb")
ModReady = true

-- Loaded (or reloaded) while already in a world: put models back and keep bases hidden.
ExecuteInGameThread(function()
    GetPC()
    if WorldKey() then
        CheckWorld()
        pcall(Restore)
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
