W2F.Camera = {
    handle = nil,
    active = false,
    focal = nil,
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
    },
}

local function cfg()
    return Config.CameraControl
end

local function camCfg()
    return Config.Camera or {}
end

local function getOverviewFocal()
    local focal = Config.GetSceneFocal()
    local overview = (camCfg().overview or {})
    return vector3(focal.x, focal.y, focal.z + (overview.height or 0.0))
end

local function syncModeState(mode)
    local state = W2F.Camera.modeState
    state.overview = mode == 'overview'
    state.focused = mode == 'focused'
    state.sky = mode == 'sky'
    state.flyToSpawn = mode == 'flyToSpawn'
    state.descent = mode == 'descent'
end

function W2F.Camera.SetRotation(cam, rot)
    SetCamRot(cam, rot.x, rot.y, rot.z, 2)
end

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

function W2F.Camera.GetLookAtRotation(from, to)
    local dx = to.x - from.x
    local dy = to.y - from.y
    local dz = to.z - from.z
    local distXY = math.sqrt(dx * dx + dy * dy)
    local pitch = math.deg(math.atan2(dz, distXY))
    local yaw = math.deg(math.atan2(dx, -dy))
    return vector3(-pitch, 0.0, yaw)
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
    local c = cfg()
    local cc = camCfg()
    local overview = cc.overview or {}
    local distance = W2F.Clamp(
        overview.distance or Config.GetRecommendedCameraDistance(),
        c.minDistance,
        c.maxDistance
    )
    W2F.Camera.currentYaw = overview.yaw or c.defaultYaw
    W2F.Camera.currentPitch = overview.pitch or c.defaultPitch
    W2F.Camera.currentDistance = distance
    W2F.Camera.targetYaw = overview.yaw or c.defaultYaw
    W2F.Camera.targetPitch = overview.pitch or c.defaultPitch
    W2F.Camera.targetDistance = distance
    W2F.Camera.currentFov = overview.fov or c.fov
    W2F.Camera.targetFov = overview.fov or c.fov

    local pos = W2F.Camera.GetOrbitPosition(focal, distance, W2F.Camera.currentYaw, W2F.Camera.currentPitch)
    W2F.Camera.handle = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    if not W2F.Camera.handle or not DoesCamExist(W2F.Camera.handle) then
        W2F.Camera.handle = nil
        W2F.Camera.active = false
        W2F.State.cameraActive = false
        if Config.Debug then
            print('[w2f-multicharacter] camera create failed')
        end
        return false
    end
    SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
    W2F.Camera.SetRotation(W2F.Camera.handle, W2F.Camera.GetLookAtRotation(pos, focal))
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
    local c = cfg()
    local cc = camCfg()
    local overview = cc.overview or {}
    W2F.Camera.targetYaw = overview.yaw or c.defaultYaw
    W2F.Camera.targetPitch = overview.pitch or c.defaultPitch
    W2F.Camera.targetDistance = W2F.Clamp(
        overview.distance or Config.GetRecommendedCameraDistance(),
        c.minDistance,
        c.maxDistance
    )
    W2F.Camera.targetFov = overview.fov or c.fov
end

function W2F.Camera.ApplyDrag(deltaX, deltaY)
    local c = cfg()
    if not c.enabled then return end
    W2F.Camera.targetYaw = W2F.Clamp(
        W2F.Camera.targetYaw - (deltaX * c.sensitivityX),
        c.minYaw,
        c.maxYaw
    )
    W2F.Camera.targetPitch = W2F.Clamp(
        W2F.Camera.targetPitch - (deltaY * c.sensitivityY),
        c.minPitch,
        c.maxPitch
    )
    W2F.Camera.targetDistance = W2F.Clamp(
        W2F.Camera.targetDistance,
        c.minDistance,
        c.maxDistance
    )
end

function W2F.Camera.Settle()
    local c = cfg()
    local overview = (camCfg().overview or {})
    W2F.Camera.targetYaw = W2F.SmoothStep(W2F.Camera.targetYaw, overview.yaw or c.defaultYaw, c.settleSpeed)
    W2F.Camera.targetPitch = W2F.SmoothStep(W2F.Camera.targetPitch, overview.pitch or c.defaultPitch, c.settleSpeed)
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
    local smooth = cc.smoothing or c.smoothing
    if W2F.Camera.mode == 'overview' and not W2F.State.isDraggingCamera then
        W2F.Camera.Settle()
        smooth = c.settleSpeed
    end

    W2F.Camera.currentYaw = W2F.SmoothStep(W2F.Camera.currentYaw, W2F.Camera.targetYaw, smooth)
    W2F.Camera.currentPitch = W2F.SmoothStep(W2F.Camera.currentPitch, W2F.Camera.targetPitch, smooth)
    W2F.Camera.currentDistance = W2F.SmoothStep(W2F.Camera.currentDistance, W2F.Camera.targetDistance, smooth)
    W2F.Camera.currentFov = W2F.SmoothStep(W2F.Camera.currentFov, W2F.Camera.targetFov, smooth)

    local focal = W2F.Camera.focal
    if W2F.Camera.mode == 'overview' and cc.idleDrift then
        local t = GetGameTimer() * 0.001
        local drift = math.sin((t + W2F.Camera.driftSeed) * 0.35) * (cc.idleDriftStrength or 0.035)
        focal = vector3(focal.x, focal.y, focal.z + drift)
    end
    local desired = W2F.Camera.GetOrbitPosition(
        focal,
        W2F.Camera.currentDistance,
        W2F.Camera.currentYaw,
        W2F.Camera.currentPitch
    )
    W2F.Camera.ApplyTransform(desired, focal, W2F.Camera.currentFov)
end

function W2F.Camera.PlayIntro()
    local scene = Config.Scene
    local focal = getOverviewFocal()
    local c = cfg()
    local cc = camCfg()
    local overview = cc.overview or {}
    local distance = W2F.Clamp(
        overview.distance or Config.GetRecommendedCameraDistance(),
        c.minDistance,
        c.maxDistance
    )
    local yaw = overview.yaw or c.defaultYaw
    local pitch = overview.pitch or c.defaultPitch
    local endPos = W2F.Camera.GetOrbitPosition(focal, distance, yaw, pitch)
    local startPos = vector3(endPos.x, endPos.y, endPos.z + scene.introStartHeight)

    W2F.State.isIntroPlaying = true
    W2F.Camera.Create(focal)
    W2F.Camera.ApplyTransform(startPos, focal, overview.fov or c.fov)

    local startTime = GetGameTimer()
    local duration = scene.introDurationMs

    CreateThread(function()
        while W2F.Camera.active and W2F.State.isIntroPlaying do
            local elapsed = GetGameTimer() - startTime
            local t = W2F.Clamp(elapsed / duration, 0.0, 1.0)
            local eased = W2F.EaseOutCubic(t)
            local pos = W2F.Vec3Lerp(startPos, endPos, eased)
            W2F.Camera.ApplyTransform(pos, focal, overview.fov or c.fov)
            if t >= 1.0 then
                break
            end
            Wait(0)
        end
        W2F.State.isIntroPlaying = false
    end)
end

function W2F.Camera.RunCinematic(sequence, onComplete)
    local first = sequence and sequence[1]
    W2F.Camera.mode = (first and first.mode) or 'flyToSpawn'
    syncModeState(W2F.Camera.mode)
    W2F.Camera.cinematic = {
        sequence = sequence,
        index = 1,
        startTime = GetGameTimer(),
        onComplete = onComplete,
    }
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

    local elapsed = GetGameTimer() - cin.startTime
    local t = W2F.Clamp(elapsed / step.duration, 0.0, 1.0)
    local eased = step.easing and step.easing(t) or W2F.EaseInOutCubic(t)

    local pos = W2F.Vec3Lerp(step.from, step.to, eased)
    local lookAt = step.lookAt or W2F.Camera.focal
    local rot = W2F.Camera.GetLookAtRotation(pos, lookAt)
    SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)

    if step.rotate and step.headingFrom and step.headingTo then
        local heading = W2F.Lerp(step.headingFrom, step.headingTo, eased)
        W2F.Camera.SetRotation(W2F.Camera.handle, vector3(rot.x, rot.y, heading))
    else
        W2F.Camera.SetRotation(W2F.Camera.handle, rot)
    end

    if step.fovFrom and step.fovTo then
        SetCamFov(W2F.Camera.handle, W2F.Lerp(step.fovFrom, step.fovTo, eased))
    end

    if t >= 1.0 then
        cin.index = cin.index + 1
        cin.startTime = GetGameTimer()
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
    local c = cfg()
    local pedCoords = GetEntityCoords(ped)
    W2F.Camera.focal = vector3(pedCoords.x, pedCoords.y, pedCoords.z + (focus.height or 1.4))
    W2F.Camera.targetDistance = W2F.Clamp(focus.distance or 5.5, c.minDistance, c.maxDistance)
    W2F.Camera.targetFov = focus.fov or 35.0
    W2F.Camera.targetPitch = W2F.Clamp(W2F.Camera.targetPitch, c.minPitch, c.maxPitch)
    W2F.Camera.mode = 'focused'
    syncModeState('focused')
end

function W2F.Camera.ReturnToOverview()
    W2F.Camera.focal = getOverviewFocal()
    W2F.Camera.ResetTargets()
    W2F.Camera.mode = 'overview'
    syncModeState('overview')
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
    if step.mode and W2F.Camera.mode ~= step.mode then
        W2F.Camera.mode = step.mode
        syncModeState(step.mode)
    end
