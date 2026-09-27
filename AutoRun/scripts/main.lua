local UEHelpers = require('UEHelpers')
local active, pending, owner, runner = false, false, nil, nil
local function valid(v) return v and v:IsValid() end
local function log(s) print('[AutoRun] ' .. s .. '\n') end
local function stop()
    if active then log('OFF') end
    active, owner, runner = false, nil, nil
end
local function context()
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) or pc.bShowMouseCursor or pc:IsMoveInputIgnored() then return end
    local statics = StaticFindObject('/Script/Engine.Default__GameplayStatics')
    if not valid(statics) or statics:IsGamePaused(pc) then return end
    local pawn = pc.Pawn
    if not valid(pawn) or not pawn:IsLocallyControlled() then return end
    local movement = pawn:GetMovementComponent()
    -- Only walking/nav-walking/falling: no forced flight, swimming or disabled movement.
    if not valid(movement) then return end
    local mode = movement.MovementMode
    if mode ~= 1 and mode ~= 2 and mode ~= 3 then return end
    return pc, pawn
end
local function guarded(fn)
    local ok, err = pcall(fn)
    if not ok then stop(); log('Stopped after error: ' .. tostring(err)) end
end
RegisterKeyBind(Key.NUM_LOCK, function()
    ExecuteInGameThread(function() guarded(function()
        if active then stop(); return end
        local pc, pawn = context()
        if not pc then return end
        owner, runner, active = pc:GetAddress(), pawn:GetAddress(), true
        log('ON — Num Lock or movement keys to stop')
    end) end)
end)
-- Never synthesize a held OS key. Each movement contribution lasts one frame.
for _, name in ipairs({'W','A','S','D','UP_ARROW','DOWN_ARROW','LEFT_ARROW','RIGHT_ARROW',
    'ESCAPE','TAB','M','I','RETURN','LEFT_MOUSE_BUTTON','RIGHT_MOUSE_BUTTON'}) do
    if Key[name] then RegisterKeyBind(Key[name], function() ExecuteInGameThread(stop) end) end
end
LoopAsync(16, function()
    if not active or pending then return false end
    pending = true
    ExecuteInGameThread(function()
        guarded(function()
            if not active then return end
            local pc, pawn = context()
            if not pc or pc:GetAddress() ~= owner or pawn:GetAddress() ~= runner then stop(); return end
            local yaw = math.rad(pc:GetControlRotation().Yaw)
            pawn:AddMovementInput({X=math.cos(yaw), Y=math.sin(yaw), Z=0.0}, 1.0, false)
        end)
        pending = false
    end)
    return false
end)
log('Ready: Num Lock toggles camera-forward autorun; movement/menu keys cancel. Starts OFF.')
