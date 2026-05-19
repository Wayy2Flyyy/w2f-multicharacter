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
}

local function cfg()
    return Config.CameraControl
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
    local distance = Config.GetRecommendedCameraDistance()
    W2F.Camera.currentYaw = c.defaultYaw
    W2F.Camera.currentPitch = c.defaultPitch
    W2F.Camera.currentDistance = distance
    W2F.Camera.targetYaw = c.defaultYaw
    W2F.Camera.targetPitch = c.defaultPitch
    W2F.Camera.targetDistance = distance
    W2F.Camera.currentFov = c.fov
    W2F.Camera.targetFov = c.fov

    local pos = W2F.Camera.GetOrbitPosition(focal, distance, c.defaultYaw, c.defaultPitch)
    W2F.Camera.handle = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
    W2F.Camera.SetRotation(W2F.Camera.handle, W2F.Camera.GetLookAtRotation(pos, focal))
    SetCamFov(W2F.Camera.handle, c.fov)
    SetCamActive(W2F.Camera.handle, true)
    RenderScriptCams(true, false, 0, true, true)
    W2F.Camera.active = true
    W2F.State.cameraActive = true
    W2F.Camera.mode = 'overview'
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
end

function W2F.Camera.ResetTargets()
    local c = cfg()
    W2F.Camera.targetYaw = c.defaultYaw
    W2F.Camera.targetPitch = c.defaultPitch
    W2F.Camera.targetDistance = Config.GetRecommendedCameraDistance()
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
    W2F.Camera.targetYaw = W2F.SmoothStep(W2F.Camera.targetYaw, c.defaultYaw, c.settleSpeed)
    W2F.Camera.targetPitch = W2F.SmoothStep(W2F.Camera.targetPitch, c.defaultPitch, c.settleSpeed)
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

function W2F.Camera.UpdateOverview()
    if not W2F.Camera.active or not W2F.Camera.handle or W2F.Camera.mode ~= 'overview' then
        return
    end
    if W2F.State.isIntroPlaying then
        return
    end

    local c = cfg()
    local smooth = c.smoothing
    if not W2F.State.isDraggingCamera then
        W2F.Camera.Settle()
        smooth = c.settleSpeed
    end

    W2F.Camera.currentYaw = W2F.SmoothStep(W2F.Camera.currentYaw, W2F.Camera.targetYaw, smooth)
    W2F.Camera.currentPitch = W2F.SmoothStep(W2F.Camera.currentPitch, W2F.Camera.targetPitch, smooth)
    W2F.Camera.currentDistance = W2F.SmoothStep(W2F.Camera.currentDistance, W2F.Camera.targetDistance, smooth)
    W2F.Camera.currentFov = W2F.SmoothStep(W2F.Camera.currentFov, W2F.Camera.targetFov, smooth)

    local focal = W2F.Camera.focal
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
    local focal = Config.GetSceneFocal()
    local c = cfg()
    local distance = Config.GetRecommendedCameraDistance()
    local endPos = W2F.Camera.GetOrbitPosition(focal, distance, c.defaultYaw, c.defaultPitch)
    local startPos = vector3(endPos.x, endPos.y, endPos.z + scene.introStartHeight)

    W2F.State.isIntroPlaying = true
    W2F.Camera.Create(focal)
    W2F.Camera.ApplyTransform(startPos, focal, c.fov)

    local startTime = GetGameTimer()
    local duration = scene.introDurationMs

    CreateThread(function()
        while W2F.Camera.active and W2F.State.isIntroPlaying do
            local elapsed = GetGameTimer() - startTime
            local t = W2F.Clamp(elapsed / duration, 0.0, 1.0)
            local eased = W2F.EaseOutCubic(t)
            local pos = W2F.Vec3Lerp(startPos, endPos, eased)
            W2F.Camera.ApplyTransform(pos, focal, c.fov)
            if t >= 1.0 then
                break
            end
            Wait(0)
        end
        W2F.State.isIntroPlaying = false
    end)
end

function W2F.Camera.RunCinematic(sequence, onComplete)
    W2F.Camera.mode = 'cinematic'
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
    if W2F.Camera.mode == 'overview' then
        W2F.Camera.UpdateOverview()
    end
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
