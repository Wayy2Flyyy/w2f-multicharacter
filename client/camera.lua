W2F.Camera = {
    handle = nil,
    active = false,
    --- Smoothed focal lerps from `focal` toward `focalTarget` each frame.
    --- Lower = silkier look-at chase (more lag, less snap).
    focal = nil,
    focalTarget = nil,
    focalSmoothing = 0.045,
    --- Smoothed rotation for locked overview path so look-at glides instead
    --- of snapping when focal changes (e.g. after a hover/preview).
    --- Lower = gentler swing.
    smoothPitch = nil,
    smoothYaw = nil,
    rotSmoothing = 0.06,
    --- Resolved base orbit (matches Config.Scene.overviewCamera when set).
    baseYaw = 0.0,
    basePitch = 0.0,
    baseDistance = 9.0,
    baseFov = 42.0,
    --- Live + targeted absolute orbit values (base +/- drag offset).
    currentYaw = 0.0,
    currentPitch = 0.0,
    currentDistance = 9.0,
    targetYaw = 0.0,
    targetPitch = 0.0,
    targetDistance = 9.0,
    currentFov = 42.0,
    targetFov = 42.0,
    mode = 'overview',
    cinematic = nil,
    driftSeed = 0.0,
    modeState = {
        overview = true,
        focused = false,
        sky = false,
        flyToSpawn = false,
        descent = false,
        cinematic = false,
    },
}

local function cfg()
    return Config.CameraControl
end

local function camCfg()
    return Config.Camera or {}
end

local function getSceneOverviewCamera()
    local scene = Config.Scene
    return scene and scene.overviewCamera
end

--- vec3 position + optional fixed GTA heading (vec4.w).
local function getOverviewCameraPose()
    local cam = getSceneOverviewCamera()
    if not cam then return nil, nil end
    if cam.w then
        return vector3(cam.x, cam.y, cam.z), cam.w
    end
    return vector3(cam.x, cam.y, cam.z), nil
end

local function getOverviewFocal()
    local scene = Config.Scene
    if scene and scene.overviewFocal then
        return scene.overviewFocal
    end
    local focal = Config.GetSceneFocal()
    local extraHeight = (camCfg().overview or {}).height or 0.0
    return vector3(focal.x, focal.y, focal.z + extraHeight)
end

local function syncModeState(mode)
    local state = W2F.Camera.modeState
    state.overview = mode == 'overview'
    state.focused = mode == 'focused'
    state.sky = mode == 'sky'
    state.flyToSpawn = mode == 'flyToSpawn'
    state.descent = mode == 'descent'
    state.cinematic = mode == 'cinematic'
end

function W2F.Camera.SetRotation(cam, rot)
    SetCamRot(cam, rot.x, rot.y, rot.z, 2)
end

--- Spherical orbit position around `focal` using GTA heading conventions.
--- yawDeg = 0  -> camera south of focal (looking north).
--- yawDeg = 90 -> camera east of focal (looking west).
--- pitchDeg > 0 -> camera above focal (looking down).
function W2F.Camera.GetOrbitPosition(focal, distance, yawDeg, pitchDeg)
    local yaw = math.rad(yawDeg)
    local pitch = math.rad(pitchDeg)
    local cosPitch = math.cos(pitch)
    local offset = vector3(
        math.sin(yaw) * cosPitch * distance,
        -math.cos(yaw) * cosPitch * distance,
        math.sin(pitch) * distance
    )
    return vector3(focal.x + offset.x, focal.y + offset.y, focal.z + offset.z)
end

--- Returns a GTA cam rotation (pitch, roll, heading) so that `from` looks at `to`.
function W2F.Camera.GetLookAtRotation(from, to)
    local dx = to.x - from.x
    local dy = to.y - from.y
    local dz = to.z - from.z
    local distXY = math.sqrt(dx * dx + dy * dy)
    local pitch = math.deg(math.atan2(dz, distXY))
    local yaw = math.deg(math.atan2(-dx, dy))
    return vector3(pitch, 0.0, yaw)
end

--- Resolve orbit parameters that recreate the fixed scene camera (if set),
--- otherwise fall back to Config.Camera.overview defaults.
local function resolveOverviewOrbit(focal)
    local fixedPos = select(1, getOverviewCameraPose())
    if fixedPos then
        local offset = vector3(fixedPos.x - focal.x, fixedPos.y - focal.y, fixedPos.z - focal.z)
        local distance = #offset
        if distance > 0.01 then
            local pitch = math.deg(math.asin(W2F.Clamp(offset.z / distance, -1.0, 1.0)))
            --- Derive yaw from camera→focal geometry so orbit math matches the
            --- actual look direction. vec4.w is position-only metadata.
            local yaw = math.deg(math.atan2(offset.x, -offset.y))
            return yaw, pitch, distance
        end
    end

    local c = cfg()
    local overview = (camCfg().overview or {})
    local distance = W2F.Clamp(
        overview.distance or Config.GetRecommendedCameraDistance(),
        c.minDistance,
        c.maxDistance
    )
    return overview.yaw or c.defaultYaw or 0.0,
        overview.pitch or c.defaultPitch or 0.0,
        distance
end

function W2F.Camera.ProbeCollision(focal, desired)
    if not cfg().collisionProbe then
        return desired
    end

    local handle = StartShapeTestRay(
        desired.x, desired.y, desired.z,
        focal.x, focal.y, focal.z,
        1, 0, 7
    )

    local retval, hit, hitCoords = GetShapeTestResult(handle)
    local attempts = 0
    while retval == 1 and attempts < 5 do
        Wait(0)
        retval, hit, hitCoords = GetShapeTestResult(handle)
        attempts = attempts + 1
    end

    if hit == 1 and hitCoords then
        return vector3(
            hitCoords.x + (desired.x - hitCoords.x) * 0.12,
            hitCoords.y + (desired.y - hitCoords.y) * 0.12,
            hitCoords.z + (desired.z - hitCoords.z) * 0.12
        )
    end

    return desired
end

function W2F.Camera.Create(focal)
    W2F.Camera.Destroy()
    W2F.Camera.focal = focal
    W2F.Camera.focalTarget = focal
    local c = cfg()
    local cc = camCfg()
    local overview = cc.overview or {}
    local yaw, pitch, distance = resolveOverviewOrbit(focal)
    distance = W2F.Clamp(distance, c.minDistance, c.maxDistance)

    W2F.Camera.baseYaw = yaw
    W2F.Camera.basePitch = pitch
    W2F.Camera.baseDistance = distance
    W2F.Camera.baseFov = overview.fov or c.fov

    W2F.Camera.currentYaw = yaw
    W2F.Camera.currentPitch = pitch
    W2F.Camera.currentDistance = distance
    W2F.Camera.targetYaw = yaw
    W2F.Camera.targetPitch = pitch
    W2F.Camera.targetDistance = distance
    W2F.Camera.currentFov = W2F.Camera.baseFov
    W2F.Camera.targetFov = W2F.Camera.baseFov

    local pos = W2F.Camera.GetOrbitPosition(focal, distance, yaw, pitch)
    W2F.Camera.handle = nil
    for _ = 1, 8 do
        local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        if cam and cam ~= 0 and DoesCamExist(cam) then
            W2F.Camera.handle = cam
            break
        end
        Wait(100)
    end
    if not W2F.Camera.handle or not DoesCamExist(W2F.Camera.handle) then
        W2F.Camera.handle = nil
        W2F.Camera.active = false
        W2F.State.cameraActive = false
        if Config.Debug then
            print('[w2f-multicharacter] camera create failed after retries')
        end
        return false
    end

    SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
    local initialRot = W2F.Camera.GetLookAtRotation(pos, focal)
    W2F.Camera.SetRotation(W2F.Camera.handle, initialRot)
    W2F.Camera.smoothPitch = initialRot.x
    W2F.Camera.smoothYaw = initialRot.z
    SetCamFov(W2F.Camera.handle, W2F.Camera.currentFov)
    SetCamActive(W2F.Camera.handle, true)
    RenderScriptCams(true, false, 0, true, true)

    W2F.Camera.active = true
    W2F.State.cameraActive = true
    W2F.Camera.mode = 'overview'
    syncModeState('overview')
    W2F.Camera.driftSeed = GetGameTimer() * 0.001
    return true
end

function W2F.Camera.Destroy()
    if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) then
        RenderScriptCams(false, true, 500, true, true)
        DestroyCam(W2F.Camera.handle, false)
    end
    W2F.Camera.handle = nil
    W2F.Camera.active = false
    W2F.State.cameraActive = false
    W2F.Camera.cinematic = nil
    W2F.Camera.mode = 'overview'
    syncModeState('overview')
end

function W2F.Camera.ResetTargets()
    W2F.Camera.targetYaw = W2F.Camera.baseYaw
    W2F.Camera.targetPitch = W2F.Camera.basePitch
    W2F.Camera.targetDistance = W2F.Camera.baseDistance
    W2F.Camera.targetFov = W2F.Camera.baseFov
end

--- Drag deltas are accumulated as offsets clamped relative to the base orbit.
function W2F.Camera.ApplyDrag(deltaX, deltaY)
    local c = cfg()
    if not c.enabled then return end

    local desiredYaw = W2F.Camera.targetYaw - (deltaX * c.sensitivityX)
    local desiredPitch = W2F.Camera.targetPitch - (deltaY * c.sensitivityY)

    local yawDelta = W2F.Clamp(desiredYaw - W2F.Camera.baseYaw, c.minYaw, c.maxYaw)
    local pitchDelta = W2F.Clamp(desiredPitch - W2F.Camera.basePitch, c.minPitch, c.maxPitch)

    W2F.Camera.targetYaw = W2F.Camera.baseYaw + yawDelta
    W2F.Camera.targetPitch = W2F.Camera.basePitch + pitchDelta
    W2F.Camera.targetDistance = W2F.Clamp(W2F.Camera.targetDistance, c.minDistance, c.maxDistance)
end

function W2F.Camera.Settle()
    local c = cfg()
    --- Use frame-rate independent smoothing so settle time is consistent at
    --- any FPS. The legacy `SmoothStep(a,b,factor)` is per-frame and decays
    --- almost twice as fast at 144Hz as at 60Hz, which made overview feel
    --- "stuck" on high-refresh monitors. `settleSpeed` is treated as a rate
    --- (per second) when used with W2F.Frame.Smooth.
    local dt = (W2F.Frame and W2F.Frame.Dt and W2F.Frame.Dt()) or GetFrameTime()
    local rate = c.settleSpeedRate or ((c.settleSpeed or 0.04) * 12.0)
    if W2F.Frame and W2F.Frame.Smooth then
        W2F.Camera.targetYaw = W2F.Frame.SmoothYaw and W2F.Frame.SmoothYaw(W2F.Camera.targetYaw, W2F.Camera.baseYaw, rate, dt)
            or W2F.Frame.Smooth(W2F.Camera.targetYaw, W2F.Camera.baseYaw, rate, dt)
        W2F.Camera.targetPitch = W2F.Frame.Smooth(W2F.Camera.targetPitch, W2F.Camera.basePitch, rate, dt)
    else
        W2F.Camera.targetYaw = W2F.SmoothStep(W2F.Camera.targetYaw, W2F.Camera.baseYaw, c.settleSpeed)
        W2F.Camera.targetPitch = W2F.SmoothStep(W2F.Camera.targetPitch, W2F.Camera.basePitch, c.settleSpeed)
    end
end

function W2F.Camera.ApplyTransform(pos, focal, fov)
    if not W2F.Camera.handle then return end
    local safe = W2F.Camera.ProbeCollision(focal, pos)
    local rot = W2F.Camera.GetLookAtRotation(safe, focal)
    SetCamCoord(W2F.Camera.handle, safe.x, safe.y, safe.z)
    W2F.Camera.SetRotation(W2F.Camera.handle, rot)
    if fov then
        SetCamFov(W2F.Camera.handle, fov)
    end
end

function W2F.Camera.UpdateOrbitMode()
    if not W2F.Camera.active or not W2F.Camera.handle then
        return
    end
    if W2F.State.isIntroPlaying then
        return
    end

    local c = cfg()
    local cc = camCfg()
    local dt = (W2F.Frame and W2F.Frame.Dt and W2F.Frame.Dt()) or GetFrameTime()

    --- Per-second smoothing rate for orbit values. Designers can either set
    --- `smoothingRate` directly or leave the legacy per-frame `smoothing`
    --- knob, which is treated as a 60Hz baseline (factor * 12 ≈ same look).
    local rateOrbit = cc.smoothingRate or c.smoothingRate
    if not rateOrbit then
        local legacy = cc.smoothing or c.smoothing or 0.10
        rateOrbit = legacy * 12.0
    end
    local rateFocal = cc.focalSmoothingRate or (W2F.Camera.focalSmoothing or 0.10) * 12.0
    local rateRot = cc.rotSmoothingRate or (W2F.Camera.rotSmoothing or 0.08) * 12.0

    if W2F.Camera.mode == 'overview' and not W2F.State.isDraggingCamera then
        W2F.Camera.Settle()
        --- Settle path uses settleSpeedRate (handled inside Settle).
        rateOrbit = c.settleSpeedRate or (c.settleSpeed or 0.04) * 12.0
    end

    if W2F.Frame and W2F.Frame.Smooth then
        W2F.Camera.currentYaw = W2F.Frame.SmoothYaw(W2F.Camera.currentYaw, W2F.Camera.targetYaw, rateOrbit, dt)
        W2F.Camera.currentPitch = W2F.Frame.Smooth(W2F.Camera.currentPitch, W2F.Camera.targetPitch, rateOrbit, dt)
        W2F.Camera.currentDistance = W2F.Frame.Smooth(W2F.Camera.currentDistance, W2F.Camera.targetDistance, rateOrbit, dt)
        W2F.Camera.currentFov = W2F.Frame.Smooth(W2F.Camera.currentFov, W2F.Camera.targetFov, rateOrbit, dt)
    else
        --- Pre-services fallback — same behaviour as the legacy build.
        local smoothLegacy = cc.smoothing or c.smoothing
        W2F.Camera.currentYaw = W2F.SmoothStep(W2F.Camera.currentYaw, W2F.Camera.targetYaw, smoothLegacy)
        W2F.Camera.currentPitch = W2F.SmoothStep(W2F.Camera.currentPitch, W2F.Camera.targetPitch, smoothLegacy)
        W2F.Camera.currentDistance = W2F.SmoothStep(W2F.Camera.currentDistance, W2F.Camera.targetDistance, smoothLegacy)
        W2F.Camera.currentFov = W2F.SmoothStep(W2F.Camera.currentFov, W2F.Camera.targetFov, smoothLegacy)
    end

    if W2F.Camera.focalTarget then
        if W2F.Frame and W2F.Frame.SmoothVec3 then
            W2F.Camera.focal = W2F.Frame.SmoothVec3(W2F.Camera.focal, W2F.Camera.focalTarget, rateFocal, dt)
        else
            local fs = W2F.Camera.focalSmoothing or 0.10
            W2F.Camera.focal = vector3(
                W2F.SmoothStep(W2F.Camera.focal.x, W2F.Camera.focalTarget.x, fs),
                W2F.SmoothStep(W2F.Camera.focal.y, W2F.Camera.focalTarget.y, fs),
                W2F.SmoothStep(W2F.Camera.focal.z, W2F.Camera.focalTarget.z, fs)
            )
        end
    end

    local focal = W2F.Camera.focal
    local allowDrift = (W2F.Performance and W2F.Performance.CameraIdleDrift and W2F.Performance.CameraIdleDrift())
        or cc.idleDrift
    if W2F.Camera.mode == 'overview' and allowDrift then
        --- Wall-clock drift seeded per-camera so two cameras don't sync up
        --- (caused noticeable visual beating). 0.35 Hz is a slow breathing
        --- rhythm that reads as "alive" without distracting the eye.
        local t = GetGameTimer() * 0.001
        local drift = math.sin((t + W2F.Camera.driftSeed) * 0.35) * (cc.idleDriftStrength or 0.035)
        focal = vector3(focal.x, focal.y, focal.z + drift)
    end

    --- Locked overview: stay at configured vec3/vec4 position and always look
    --- at the focal point. vec4.w is ignored for rotation — forcing a stored
    --- heading made the camera face ~180° away from the ped lineup.
    --- Pitch/yaw are interpolated toward the look-at target so the camera
    --- glides into focal changes instead of snapping.
    local fixedPos = select(1, getOverviewCameraPose())

    --- Drag offsets: relative to base orbit. When the user drags we want the
    --- LOCKED camera to feel "live" by pivoting the look direction (yaw/pitch
    --- shift) without leaving the fixed position. The legacy code returned
    --- early from this branch the moment a drag started, snapping the camera
    --- out of the fixed pose and back into orbit mode mid-drag.
    local yawDelta = W2F.Camera.targetYaw - W2F.Camera.baseYaw
    local pitchDelta = W2F.Camera.targetPitch - W2F.Camera.basePitch
    local dragActive = math.abs(yawDelta) > 0.01 or math.abs(pitchDelta) > 0.01

    if W2F.Camera.mode == 'overview' and fixedPos then
        local rot = W2F.Camera.GetLookAtRotation(fixedPos, focal)
        local targetYaw = rot.z + yawDelta
        local targetPitch = rot.x + pitchDelta * 0.6 --- keep pitch tame on the locked pose

        if W2F.Frame and W2F.Frame.Smooth then
            W2F.Camera.smoothPitch = W2F.Frame.Smooth(W2F.Camera.smoothPitch or targetPitch, targetPitch, rateRot, dt)
            W2F.Camera.smoothYaw = W2F.Frame.SmoothYaw(W2F.Camera.smoothYaw or targetYaw, targetYaw, rateRot, dt)
        else
            local rs = W2F.Camera.rotSmoothing or 0.08
            W2F.Camera.smoothPitch = W2F.SmoothStep(W2F.Camera.smoothPitch or targetPitch, targetPitch, rs)
            local currentYaw = W2F.Camera.smoothYaw or targetYaw
            local delta = targetYaw - currentYaw
            while delta > 180.0 do delta = delta - 360.0 end
            while delta < -180.0 do delta = delta + 360.0 end
            W2F.Camera.smoothYaw = currentYaw + (delta * rs)
        end

        SetCamCoord(W2F.Camera.handle, fixedPos.x, fixedPos.y, fixedPos.z)
        W2F.Camera.SetRotation(W2F.Camera.handle, vector3(W2F.Camera.smoothPitch, rot.y, W2F.Camera.smoothYaw))
        SetCamFov(W2F.Camera.handle, W2F.Camera.currentFov)
        --- Touch dragActive so static analyzers don't warn; consumed by
        --- consumers that gate other systems on whether the camera is being
        --- "actively flown" by the player.
        W2F.Camera.dragActive = dragActive
        return
    end

    local desired = W2F.Camera.GetOrbitPosition(
        focal,
        W2F.Camera.currentDistance,
        W2F.Camera.currentYaw,
        W2F.Camera.currentPitch
    )
    W2F.Camera.ApplyTransform(desired, focal, W2F.Camera.currentFov)
end

---@param opts? { instant?: boolean }
function W2F.Camera.PlayIntro(opts)
    opts = opts or {}
    local scene = Config.Scene
    local focal = getOverviewFocal()
    W2F.Camera.Create(focal)
    if not W2F.Camera.handle then return end

    if opts.instant then
        W2F.State.isIntroPlaying = false
        W2F.Camera.SnapOverview()
        return
    end

    local fixedPos = select(1, getOverviewCameraPose())
    local endPos = fixedPos or W2F.Camera.GetOrbitPosition(
        focal,
        W2F.Camera.baseDistance,
        W2F.Camera.baseYaw,
        W2F.Camera.basePitch
    )
    local startPos = vector3(endPos.x, endPos.y, endPos.z + (scene.introStartHeight or 12.0))
    local fov = W2F.Camera.baseFov

    W2F.State.isIntroPlaying = true
    SetCamCoord(W2F.Camera.handle, startPos.x, startPos.y, startPos.z)
    W2F.Camera.SetRotation(W2F.Camera.handle, W2F.Camera.GetLookAtRotation(startPos, focal))
    SetCamFov(W2F.Camera.handle, fov)

    local startTime = GetGameTimer()
    local duration = scene.introDurationMs or 2800

    CreateThread(function()
        while W2F.Camera.active and W2F.State.isIntroPlaying do
            local elapsed = GetGameTimer() - startTime
            local t = W2F.Clamp(elapsed / duration, 0.0, 1.0)
            local eased = W2F.EaseOutCubic(t)
            local pos = W2F.Vec3Lerp(startPos, endPos, eased)
            SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
            W2F.Camera.SetRotation(W2F.Camera.handle, W2F.Camera.GetLookAtRotation(pos, focal))
            SetCamFov(W2F.Camera.handle, fov)
            if t >= 1.0 then break end
            Wait(0)
        end
        W2F.State.isIntroPlaying = false
        if W2F.Camera.SnapOverview then
            W2F.Camera.SnapOverview()
        elseif W2F.Camera.handle and W2F.Camera.focal then
            local endRot = W2F.Camera.GetLookAtRotation(endPos, focal)
            W2F.Camera.smoothPitch = endRot.x
            W2F.Camera.smoothYaw = endRot.z
        end
    end)
end

function W2F.Camera.RunCinematic(sequence, onComplete)
    local first = sequence and sequence[1]
    W2F.Camera.mode = (first and first.mode) or 'flyToSpawn'
    syncModeState(W2F.Camera.mode)
    --- Cinematic owns the screen — hide the hologram while it's running so
    --- the panel doesn't snap around with the camera; restored on completion.
    if W2F.Hud and W2F.Hud.SetVisible then W2F.Hud.SetVisible(false) end
    local userOnComplete = onComplete
    W2F.Camera.cinematic = {
        sequence = sequence,
        index = 1,
        startTime = GetGameTimer(),
        onComplete = function()
            if W2F.Hud and W2F.Hud.SetVisible then W2F.Hud.SetVisible(true) end
            if userOnComplete then pcall(userOnComplete) end
        end,
        swaySeed = GetGameTimer() * 0.0011,
        renderPos = nil,
        renderLookAt = nil,
        renderFov = nil,
        smoothPitch = nil,
        smoothYaw = nil,
    }
end

local function resolveFrameIndependentFactor(baseFactor)
    local f = W2F.Clamp(baseFactor or 0.0, 0.0, 1.0)
    if f <= 0.0 then return 0.0 end
    if f >= 1.0 then return 1.0 end
    local dt = GetFrameTime() or (1.0 / 60.0)
    local framesAt60 = dt * 60.0
    return 1.0 - math.pow(1.0 - f, framesAt60)
end

local function applyCinematicSmoothing(cin, step, pos, lookAt, fov)
    local posSmooth = step.smoothFactor
    if posSmooth == nil then
        posSmooth = (Config.SpawnCinematic and Config.SpawnCinematic.cameraSmoothFactor) or 0.0
    end
    local lookSmooth = step.lookAtSmoothFactor
    if lookSmooth == nil then
        lookSmooth = (Config.SpawnCinematic and Config.SpawnCinematic.cameraLookAtSmoothFactor) or posSmooth
    end

    posSmooth = resolveFrameIndependentFactor(posSmooth)
    lookSmooth = resolveFrameIndependentFactor(lookSmooth)

    if (not posSmooth or posSmooth <= 0.0) and (not lookSmooth or lookSmooth <= 0.0) then
        local rot = W2F.Camera.GetLookAtRotation(pos, lookAt)
        return pos, rot, fov
    end

    if not cin.renderPos then
        cin.renderPos = pos
        cin.renderLookAt = lookAt
        local seedRot = W2F.Camera.GetLookAtRotation(pos, lookAt)
        cin.smoothPitch = seedRot.x
        cin.smoothYaw = seedRot.z
        cin.renderFov = fov
    end

    if posSmooth > 0.0 then
        cin.renderPos = W2F.Vec3SmoothStep(cin.renderPos, pos, posSmooth)
    else
        cin.renderPos = pos
    end
    if lookSmooth > 0.0 then
        cin.renderLookAt = W2F.Vec3SmoothStep(cin.renderLookAt or lookAt, lookAt, lookSmooth)
    else
        cin.renderLookAt = lookAt
    end
    pos = cin.renderPos

    local rotSmooth = posSmooth > 0.0 and posSmooth or lookSmooth
    local targetRot = W2F.Camera.GetLookAtRotation(pos, cin.renderLookAt or lookAt)
    cin.smoothPitch = W2F.SmoothStep(cin.smoothPitch, targetRot.x, rotSmooth)
    cin.smoothYaw = W2F.SmoothYaw(cin.smoothYaw, targetRot.z, rotSmooth)
    local rot = vector3(cin.smoothPitch, targetRot.y, cin.smoothYaw)

    if fov then
        local fovSmooth = resolveFrameIndependentFactor(step.fovSmoothFactor or posSmooth)
        cin.renderFov = W2F.SmoothStep(cin.renderFov or fov, fov, fovSmooth)
        fov = cin.renderFov
    end

    return pos, rot, fov
end

function W2F.Camera.UpdateCinematic()
    local cin = W2F.Camera.cinematic
    if not cin or not W2F.Camera.handle then return end

    local step = cin.sequence[cin.index]
    if not step then
        local done = cin.onComplete
        W2F.Camera.cinematic = nil
        if done then done() end
        return
    end

    if step.mode and W2F.Camera.mode ~= step.mode then
        W2F.Camera.mode = step.mode
        syncModeState(step.mode)
    end

    local duration = step.duration or 1.0
    if duration <= 0 then duration = 1.0 end

    local elapsed = GetGameTimer() - cin.startTime
    local t = W2F.Clamp(elapsed / duration, 0.0, 1.0)
    --- Path steps default to ease-in-out so acceleration/deceleration feels
    --- natural instead of rigidly linear along the spline parameter.
    local defaultEasing = step.path and W2F.EaseInOutCubic or W2F.EaseInOutCubic
    local eased = step.easing and step.easing(t) or defaultEasing(t)

    --- Position: spline path (multi-waypoint) > quadratic bezier > linear lerp.
    local pos
    if step.path then
        pos = W2F.SamplePath(step.path, eased, step.times)
    elseif step.control then
        pos = W2F.Vec3Bezier(step.from, step.control, step.to, eased)
    else
        pos = W2F.Vec3Lerp(step.from, step.to, eased)
    end

    --- Look-at: spline path > two-point lerp > static > live ped tracking.
    local lookAt = step.lookAt or W2F.Camera.focal
    if step.trackPed then
        local ped = PlayerPedId()
        if ped and DoesEntityExist(ped) then
            local c = GetEntityCoords(ped)
            local h = (Config.SpawnCinematic and Config.SpawnCinematic.pedFocusHeight) or 0.95
            lookAt = vector3(c.x, c.y, c.z + h)
        end
    elseif step.lookAtPath then
        lookAt = W2F.SamplePath(step.lookAtPath, eased, step.lookAtTimes or step.times)
    elseif step.lookAtFrom and step.lookAtTo then
        lookAt = W2F.Vec3Lerp(step.lookAtFrom, step.lookAtTo, eased)
    end

    --- Subtle handheld sway (drift on yaw/pitch). Disabled when 0/nil.
    local swayYaw, swayPitch = 0.0, 0.0
    if step.swayStrength and step.swayStrength > 0 then
        local now = GetGameTimer() * 0.001
        local seed = cin.swaySeed or 0.0
        swayYaw = math.sin((now + seed) * (step.swaySpeed or 0.6)) * step.swayStrength
        swayPitch = math.cos((now + seed * 1.13) * (step.swaySpeed or 0.6) * 0.85) * step.swayStrength * 0.6
    end

    local rot = W2F.Camera.GetLookAtRotation(pos, lookAt)

    --- FOV: spline path > two-point lerp. Optional sine bob for breathing motion.
    local fov
    if step.fovPath then
        fov = W2F.SampleNumPath(step.fovPath, eased, step.fovTimes or step.times)
    elseif step.fovFrom and step.fovTo then
        fov = W2F.Lerp(step.fovFrom, step.fovTo, eased)
    end
    if fov and step.fovBob and step.fovBob > 0 then
        local now = GetGameTimer() * 0.001
        local seed = cin.swaySeed or 0.0
        fov = fov + math.sin((now + seed) * (step.fovBobSpeed or 0.7)) * step.fovBob
    end

    pos, rot, fov = applyCinematicSmoothing(cin, step, pos, lookAt, fov)
    rot = vector3(rot.x + swayPitch, rot.y, rot.z + swayYaw)

    SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
    W2F.Camera.SetRotation(W2F.Camera.handle, rot)
    if fov then
        SetCamFov(W2F.Camera.handle, fov)
    end

    --- Fire-once progress markers (sound cues, mode swaps, etc).
    if step.markers then
        cin.markersFired = cin.markersFired or {}
        for i = 1, #step.markers do
            local m = step.markers[i]
            if not cin.markersFired[i] and t >= (m.at or 0.0) then
                cin.markersFired[i] = true
                if m.fn then pcall(m.fn) end
            end
        end
    end

    --- Per-frame progress callback (rarely needed; markers handle most cases).
    if step.onProgress then
        pcall(step.onProgress, t, eased, step, cin)
    end

    if t >= 1.0 then
        --- Carry over the time we ran *past* the step end so the next step
        --- starts mid-flight rather than at zero. Without this, low-FPS or
        --- long-frame stalls silently lose 30-60ms each step boundary, which
        --- shows up as a tiny "hiccup" at every transition.
        local overrun = elapsed - duration
        cin.index = cin.index + 1
        cin.startTime = GetGameTimer() - math.max(0, overrun)
        cin.markersFired = nil
    end
end

function W2F.Camera.Update()
    if W2F.Camera.cinematic then
        W2F.Camera.UpdateCinematic()
        return
    end
    if W2F.Camera.mode == 'overview' or W2F.Camera.mode == 'focused' then
        W2F.Camera.UpdateOrbitMode()
    end
end

function W2F.Camera.FocusOnPed(ped)
    if not ped or not DoesEntityExist(ped) or not W2F.Camera.active then return end
    local focus = (camCfg().focus or {})
    local pedCoords = GetEntityCoords(ped)
    --- Camera position is fully locked — only update the focal target so the
    --- hologram tracking thread has the correct world anchor. Mode stays
    --- 'overview' so UpdateOrbitMode keeps the camera at the fixed position.
    W2F.Camera.focalTarget = vector3(
        pedCoords.x,
        pedCoords.y,
        pedCoords.z + (focus.height or 1.4)
    )
    --- Subtle "zoom in" while selected, without moving the locked overview cam.
    local focusFov = focus.fov or 35.0
    W2F.Camera.targetFov = W2F.Clamp(focusFov, 28.0, W2F.Camera.baseFov)
end

function W2F.Camera.ReturnToOverview()
    W2F.Camera.focalTarget = getOverviewFocal()
    --- Camera never moved, so no orbit reset needed — just restore the focal
    --- target so it tracks the ped centroid again.
    W2F.Camera.targetFov = W2F.Camera.baseFov
    W2F.Camera.mode = 'overview'
    syncModeState('overview')
    W2F.Camera.SnapOverview()
end

--- Force the overview camera to the configured fixed pose (or resolved orbit
--- end point) looking at the lineup focal. Used after intro completes and as
--- a cold-boot safety net once interior streaming lands.
function W2F.Camera.SnapOverview()
    if not W2F.Camera.active or not W2F.Camera.handle or not DoesCamExist(W2F.Camera.handle) then
        return
    end

    local focal = getOverviewFocal()
    W2F.Camera.focal = focal
    W2F.Camera.focalTarget = focal

    local fixedPos = select(1, getOverviewCameraPose())
    local endPos = fixedPos or W2F.Camera.GetOrbitPosition(
        focal,
        W2F.Camera.baseDistance,
        W2F.Camera.baseYaw,
        W2F.Camera.basePitch
    )
    local rot = W2F.Camera.GetLookAtRotation(endPos, focal)

    SetCamCoord(W2F.Camera.handle, endPos.x, endPos.y, endPos.z)
    W2F.Camera.SetRotation(W2F.Camera.handle, rot)
    W2F.Camera.smoothPitch = rot.x
    W2F.Camera.smoothYaw = rot.z
    SetCamFov(W2F.Camera.handle, W2F.Camera.baseFov)
    RenderScriptCams(true, false, 0, true, true)
end

function W2F.Camera.GetCurrentCoord()
    if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) then
        return GetCamCoord(W2F.Camera.handle)
    end
    return GetGameplayCamCoord()
end

function W2F.Camera.GetRenderedTransform()
    if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) then
        return GetCamCoord(W2F.Camera.handle), GetCamRot(W2F.Camera.handle, 2)
    end
    return GetGameplayCamCoord(), GetGameplayCamRot(2)
end
