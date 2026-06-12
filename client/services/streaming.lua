--- W2F.Streaming - RAII-style world streaming helpers.
---
--- The native pairs (`NewLoadSceneStartSphere`/`NewLoadSceneStop`,
--- `SetFocusPosAndVel`/`ClearFocus`, plus ad-hoc per-tick
--- `RequestCollisionAtCoord` threads) used to be sprinkled across spawner
--- and creator with no guarantee they'd be paired on every exit. Failure
--- branches leaked focus + scene handles for the rest of the session.
---
--- This service exposes:
---   handle = W2F.Streaming.Acquire(coords, opts) -> resource handle
---   W2F.Streaming.Release(handle)
---   W2F.Streaming.WithCoords(coords, opts, fn) -> runs fn under acquire/release
---   W2F.Streaming.WaitForCollision(coords, timeoutMs) -> bool
---
--- Every acquired handle is tracked; on resource stop / session recover
--- they're all released, so no flow can leak streaming state.

W2F = W2F or {}
W2F.Streaming = W2F.Streaming or {
    handles = {},
    nextId = 1,
    --- True iff at least one handle currently has `keepThread = true`.
    threadActive = false,
}

local function debug(...)
    if W2F.Debug then W2F.Debug(...) end
end

local function spawnerCfg()
    return (Config.SpawnCinematic) or {}
end

local function defaultRadius()
    return spawnerCfg().streamingRadius or 120.0
end

local function perfCfg()
    return Config.Performance or {}
end

local function keepaliveIntervalMs(handle)
    if handle and handle.keepThreadIntervalMs then
        return handle.keepThreadIntervalMs
    end
    if W2F.Diag and W2F.Diag.Flag and W2F.Diag.Flag('SceneSafeMode') then
        return 100
    end
    if W2F.Performance and W2F.Performance.StreamKeepaliveMs then
        return W2F.Performance.StreamKeepaliveMs()
    end
    return perfCfg().streamKeepaliveMs or 750
end

local function focusRefreshMs(handle)
    if handle and handle.focusRefreshMs then
        return handle.focusRefreshMs
    end
    if W2F.Performance and W2F.Performance.StreamFocusRefreshMs then
        return W2F.Performance.StreamFocusRefreshMs()
    end
    return perfCfg().streamFocusRefreshMs or 4000
end

local function emitCollision(handle)
    local c = handle.coords
    RequestCollisionAtCoord(c.x, c.y, c.z)
    if handle.focus then
        local now = GetGameTimer()
        handle._lastFocusAt = handle._lastFocusAt or 0
        if now - handle._lastFocusAt >= focusRefreshMs(handle) then
            SetFocusPosAndVel(c.x, c.y, c.z, 0.0, 0.0, 0.0)
            handle._lastFocusAt = now
        end
    end
end

local function ensureThread()
    if W2F.Streaming.threadActive then return end
    W2F.Streaming.threadActive = true

    CreateThread(function()
        while W2F.Streaming.threadActive do
            local stillActive = false
            local waitMs = (W2F.Performance and W2F.Performance.StreamKeepaliveMs and W2F.Performance.StreamKeepaliveMs())
                or perfCfg().streamKeepaliveMs or 750
            for _, handle in pairs(W2F.Streaming.handles) do
                if handle.keepThread and not handle.released then
                    stillActive = true
                    local interval = keepaliveIntervalMs(handle)
                    if interval < waitMs then waitMs = interval end
                    emitCollision(handle)
                    --- followCamera only during cinematics / spawn fly — never
                    --- during the fixed overview lineup (doubles collision load).
                    if handle.followCamera
                        and W2F.Camera and W2F.Camera.GetCurrentCoord
                    then
                        local camPos = W2F.Camera.GetCurrentCoord()
                        if camPos then
                            RequestCollisionAtCoord(camPos.x, camPos.y, camPos.z)
                        end
                    end
                    if W2F.Diag and W2F.Diag.LogCollisionTick then
                        W2F.Diag.LogCollisionTick(handle)
                    end
                end
            end
            if not stillActive then
                W2F.Streaming.threadActive = false
                return
            end
            Wait(waitMs)
        end
    end)
end

local function applyAcquire(handle)
    local c = handle.coords
    RequestCollisionAtCoord(c.x, c.y, c.z)
    if handle.scene then
        NewLoadSceneStartSphere(c.x, c.y, c.z, handle.radius, 0)
    end
    if handle.focus then
        SetFocusPosAndVel(c.x, c.y, c.z, 0.0, 0.0, 0.0)
    end
end

local function applyRelease(handle)
    --- Only stop scene/focus when no OTHER live handle needs them.
    local anyScene, anyFocus = false, false
    for id, other in pairs(W2F.Streaming.handles) do
        if id ~= handle.id and not other.released then
            if other.scene then anyScene = true end
            if other.focus then anyFocus = true end
        end
    end

    if handle.scene and not anyScene then
        NewLoadSceneStop()
    end
    if handle.focus and not anyFocus then
        if ClearFocus then ClearFocus() end
    end
end

--- Acquires a streaming session at `coords`. Returns an opaque handle to
--- pass to `Release`. Always pair with `Release` (or use `WithCoords`).
---
--- Options:
---   radius          - load-scene sphere radius (default Config.SpawnCinematic.streamingRadius)
---   keepThread      - keep re-requesting collision while active (default true)
---   keepThreadIntervalMs - override Config.Performance.streamKeepaliveMs for this handle
---   focusRefreshMs  - override Config.Performance.streamFocusRefreshMs for this handle
---   followCamera    - when keepThread, also request collision at camera pos
---   focus           - default true; calls SetFocusPosAndVel / ClearFocus
---   scene           - default true; calls NewLoadSceneStartSphere / Stop
---   parkPed         - default false; teleports the local ped near coords
function W2F.Streaming.Acquire(coords, opts)
    if not coords then
        return nil, 'no_coords'
    end
    opts = opts or {}

    local handle = {
        id = W2F.Streaming.nextId,
        coords = vector3(coords.x, coords.y, coords.z),
        radius = opts.radius or defaultRadius(),
        keepThread = opts.keepThread ~= false,
        keepThreadIntervalMs = opts.keepThreadIntervalMs,
        focusRefreshMs = opts.focusRefreshMs,
        followCamera = opts.followCamera == true,
        focus = opts.focus ~= false,
        scene = opts.scene ~= false,
        released = false,
        acquiredAt = GetGameTimer(),
        _lastFocusAt = GetGameTimer(),
    }
    W2F.Streaming.nextId = W2F.Streaming.nextId + 1
    W2F.Streaming.handles[handle.id] = handle

    applyAcquire(handle)

    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming',
            'Acquire #%d coords=(%.1f,%.1f,%.1f) r=%.0f focus=%s scene=%s keepThread=%s followCamera=%s',
            handle.id, handle.coords.x, handle.coords.y, handle.coords.z, handle.radius,
            tostring(handle.focus), tostring(handle.scene),
            tostring(handle.keepThread), tostring(handle.followCamera))
    end

    if opts.parkPed then
        local ped = PlayerPedId()
        SetEntityCoords(ped, handle.coords.x, handle.coords.y, handle.coords.z - 1.0,
            false, false, false, false)
    end

    if handle.keepThread then
        ensureThread()
    end

    debug('Streaming.Acquire #%d coords=(%.1f,%.1f,%.1f) r=%.0f',
        handle.id, handle.coords.x, handle.coords.y, handle.coords.z, handle.radius)
    return handle
end

function W2F.Streaming.Release(handle)
    if not handle or handle.released then return end
    handle.released = true
    W2F.Streaming.handles[handle.id] = nil
    applyRelease(handle)
    debug('Streaming.Release #%d (after %dms)', handle.id, GetGameTimer() - handle.acquiredAt)
    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'Release #%d (after %dms) focus=%s scene=%s',
            handle.id, GetGameTimer() - handle.acquiredAt,
            tostring(handle.focus), tostring(handle.scene))
    end
end

--- Releases every outstanding handle. Used on resource stop and as the
--- final cleanup leg of `Session.Recover`.
function W2F.Streaming.ReleaseAll()
    local count = 0
    for _, handle in pairs(W2F.Streaming.handles) do
        handle.released = true
        count = count + 1
    end
    W2F.Streaming.handles = {}
    NewLoadSceneStop()
    if ClearFocus then ClearFocus() end
    W2F.Streaming.threadActive = false
    debug('Streaming.ReleaseAll')
    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'ReleaseAll handles=%d (NewLoadSceneStop + ClearFocus)', count)
    end
end

--- Convenience: runs `fn(handle)` with streaming acquired, releases on exit
--- even if `fn` errors. Returns whatever `fn` returns.
function W2F.Streaming.WithCoords(coords, opts, fn)
    if type(opts) == 'function' and fn == nil then
        fn = opts
        opts = nil
    end
    local handle, err = W2F.Streaming.Acquire(coords, opts)
    if not handle then return nil, err end
    local ok, r1, r2 = pcall(fn, handle)
    W2F.Streaming.Release(handle)
    if not ok then error(r1) end
    return r1, r2
end

--- Blocks (with Wait) until `HasCollisionLoadedAroundEntity` reports true OR
--- the timeout elapses. Returns `true` if loaded, `false` on timeout.
function W2F.Streaming.WaitForCollision(coords, timeoutMs)
    if not coords then return false end
    local ped = PlayerPedId()
    local deadline = GetGameTimer() + (timeoutMs or 5000)

    while GetGameTimer() < deadline do
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        if HasCollisionLoadedAroundEntity(ped) then
            return true
        end
        Wait(50)
    end
    return false
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Streaming.ReleaseAll()
    end
end)

--- Session listener: full cleanup on every transition back to idle.
if W2F.Session and W2F.Session.OnEnter then
    W2F.Session.OnEnter('idle', function() W2F.Streaming.ReleaseAll() end)
    --- Also clean up on recovering so failure paths can't leak focus/scene.
    W2F.Session.OnEnter('recovering', function() W2F.Streaming.ReleaseAll() end)
end
