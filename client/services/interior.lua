--- W2F.Interior — explicit MLO/interior streaming for the selection scene.
---
--- Custom MLOs and IPL-backed interiors require PinInteriorInMemory and a valid
--- local ped probe inside the interior volume. Routing buckets and underground
--- player placement break this; this service owns the interior-native load path.

W2F = W2F or {}
W2F.Interior = W2F.Interior or {
    active = false,
    interiorId = 0,
    pinned = false,
}

local function interiorCfg()
    return (Config.Scene and Config.Scene.interior) or {}
end

function W2F.Interior.ResolveIdAt(coords)
    if not coords or not GetInteriorAtCoords then return 0 end
    return GetInteriorAtCoords(coords.x, coords.y, coords.z) or 0
end

function W2F.Interior.IsValidInterior(interiorId)
    if not interiorId or interiorId == 0 then return false end
    if IsValidInterior then
        return IsValidInterior(interiorId) == true
    end
    return true
end

--- True when the lineup focal resolves to a valid interior (MLO/IPL shell).
function W2F.Interior.IsSceneInterior()
    local cfg = interiorCfg()
    if cfg.forceExterior == true then return false end
    if cfg.forceMloScene == true then return true end
    if not Config.GetSceneFocal then return false end
    local focal = Config.GetSceneFocal()
    return W2F.Interior.IsValidInterior(W2F.Interior.ResolveIdAt(focal))
end

--- Streaming radius for the lineup scene (safemode default: 40m for MLO).
function W2F.Interior.ResolveStreamRadius(default)
    local cfg = interiorCfg()
    if cfg.streamRadius then return cfg.streamRadius end
    if W2F.Diag and W2F.Diag.ResolveStreamRadius then
        return W2F.Diag.ResolveStreamRadius(default)
    end
    if W2F.Interior.IsSceneInterior() then
        return 40.0
    end
    return default
end

function W2F.Interior.StreamKeepaliveMs()
    local cfg = interiorCfg()
    if cfg.streamKeepaliveMs then return cfg.streamKeepaliveMs end
    if W2F.Interior.IsSceneInterior() then return 100 end
    return nil
end

function W2F.Interior.StreamFocusRefreshMs()
    local cfg = interiorCfg()
    if cfg.streamFocusRefreshMs then return cfg.streamFocusRefreshMs end
    if W2F.Interior.IsSceneInterior() then return 500 end
    return nil
end

--- Re-probe and pin after the scene sphere has streamed the MLO shell.
function W2F.Interior.TryPinAt(focal)
    if not focal then return false end
    local interiorId = W2F.Interior.ResolveIdAt(focal)
    if not W2F.Interior.IsValidInterior(interiorId) then
        return false
    end
    if W2F.Interior.interiorId == interiorId and W2F.Interior.pinned then
        return W2F.Interior.IsReady()
    end
    W2F.Interior.interiorId = interiorId
    W2F.Interior.active = true
    local cfg = interiorCfg()
    if cfg.pinInterior ~= false then
        pcall(function()
            PinInteriorInMemory(interiorId)
            if RefreshInterior then RefreshInterior(interiorId) end
        end)
        W2F.Interior.pinned = true
    end
    return W2F.Interior.IsReady()
end

--- Interior/MLO scenes must keep NewLoadSceneStartSphere for the whole session.
function W2F.Interior.ShouldKeepSceneSphere()
    local cfg = interiorCfg()
    if cfg.keepSceneSphere == true then return true end
    if cfg.keepSceneSphere == false then return false end
    return W2F.Interior.IsSceneInterior()
end

function W2F.Interior.RequestIpls()
    local ipls = interiorCfg().ipls
    if not ipls or not RequestIpl then return end
    for i = 1, #ipls do
        local ipl = ipls[i]
        if ipl and type(ipl) == 'string' then
            RequestIpl(ipl)
        end
    end
end

function W2F.Interior.IsReady()
    local id = W2F.Interior.interiorId
    if not W2F.Interior.IsValidInterior(id) then return true end
    if IsInteriorReady then
        return IsInteriorReady(id) == true
    end
    return true
end

--- Loads optional IPLs, pins the interior at `focal`, waits for readiness.
---@return boolean ready
function W2F.Interior.Acquire(focal, timeoutMs)
    W2F.Interior.Release()
    if not focal then return false end

    W2F.Interior.RequestIpls()

    local interiorId = W2F.Interior.ResolveIdAt(focal)
    W2F.Interior.interiorId = interiorId
    W2F.Interior.active = true

    if not W2F.Interior.IsValidInterior(interiorId) then
        if W2F.Diag and W2F.Diag.Log then
            W2F.Diag.Log('Streaming', 'Interior.Acquire: no interior at focal (exterior scene)')
        end
        return true
    end

    local cfg = interiorCfg()
    if cfg.pinInterior ~= false then
        pcall(function()
            PinInteriorInMemory(interiorId)
            if RefreshInterior then RefreshInterior(interiorId) end
        end)
        W2F.Interior.pinned = true
    end

    if IsInteriorReady then
        local deadline = GetGameTimer() + (timeoutMs or 15000)
        while GetGameTimer() < deadline do
            if IsInteriorReady(interiorId) then
                break
            end
            if RefreshInterior then RefreshInterior(interiorId) end
            Wait(50)
        end
    end

    local ready = W2F.Interior.IsReady()
    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'Interior.Acquire id=%d pinned=%s ready=%s',
            interiorId, tostring(W2F.Interior.pinned), tostring(ready))
    end
    return ready
end

function W2F.Interior.Release()
    local id = W2F.Interior.interiorId
    if W2F.Interior.pinned and id and id ~= 0 then
        pcall(function()
            if UnpinInterior then UnpinInterior(id) end
        end)
    end
    W2F.Interior.active = false
    W2F.Interior.interiorId = 0
    W2F.Interior.pinned = false
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Interior.Release()
    end
end)

if W2F.Session and W2F.Session.OnEnter then
    W2F.Session.OnEnter('idle', function()
        W2F.Interior.Release()
    end)
    W2F.Session.OnEnter('recovering', function()
        W2F.Interior.Release()
    end)
end
