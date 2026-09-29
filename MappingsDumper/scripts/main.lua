-- MappingsDumper: writes Mappings.usmap once, so ModelViewer's exporter can read the game's UE5 assets.
-- Does nothing if a mappings file already exists. Installed and used by ModelViewer/export-models.ps1.
local function log(s) print('[MappingsDumper] ' .. s .. '\n') end

local function exists(path)
    local f = io.open(path, 'rb')
    if f then f:close() return true end
    return false
end

local candidates = { 'Mappings.usmap', 'ue4ss/Mappings.usmap', 'UE4SS/Mappings.usmap' }
for _, p in ipairs(candidates) do
    if exists(p) then
        log('Mappings file already present (' .. p .. '), nothing to do.')
        return
    end
end

local dumped = false
-- Wait until the game has a player controller (main menu or world), so reflection data is loaded.
LoopAsync(5000, function()
    if dumped then return true end
    local pc = FindFirstOf('PlayerController')
    if not pc or not pc:IsValid() then return false end
    dumped = true
    ExecuteWithDelay(5000, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(DumpUSMAP)
            if ok then log('Wrote Mappings.usmap.') else log('DumpUSMAP failed: ' .. tostring(err)) end
        end)
    end)
    return true
end)
log('Waiting for the game to load before writing Mappings.usmap...')
