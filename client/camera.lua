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
    mode = 'overview', -- overview | sky | cinematic
    cinematic = nil,
}

local function cfg()
    return Config.CameraControl
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

function W2F.Camera.ProbeCollision(from, to)
    if not cfg().collisionProbe then
        return to
    end
    local handle = StartShapeTestRay(from.x, from.y, from.z, to.x, to.y, to.z, 1, 0, 7)
    local _, hit, hitCoords = GetShapeTestResult(handle)
    if hit == 1 then
        return vector3(
            hitCoords.x + (from.x - hitCoords.x) * 0.08,
            hitCoords.y + (from.y - hitCoords.y) * 0.08,
            hitCoords.z + (from.z - hitCoords.z) * 0.08
        )
    end
    return to
end

function W2F.Camera.Create(focal)
    W2F.Camera.Destroy()
    W2F.Camera.focal = focal
    local c = cfg()
    W2F.Camera.currentYaw = c.defaultYaw
    W2F.Camera.currentPitch = c.defaultPitch
    W2F.Camera.currentDistance = c.defaultDistance
    W2F.Camera.targetYaw = c.defaultYaw
    W2F.Camera.targetPitch = c.defaultPitch
    W2F.Camera.targetDistance = c.defaultDistance
    W2F.Camera.currentFov = c.fov
    W2F.Camera.targetFov = c.fov

    local pos = W2F.Camera.GetOrbitPosition(focal, c.defaultDistance, c.defaultYaw, c.defaultPitch)
    W2F.Camera.handle = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
    SetCamRot(W2F.Camera.handle, W2F.Camera.GetLookAtRotation(pos, focal), 2)
    SetCamFov(W2F.Camera.handle, c.fov)
    SetCamActive(W2F.Camera.handle, true)
    RenderScriptCams(true, false, 0, true, true)
    W2F.Camera.active = true
    W2F.Camera.mode = 'overview'
end

function W2F.Camera.Destroy()
    if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) then
        RenderScriptCams(false, true, 500, true, true)
        DestroyCam(W2F.Camera.handle, false)
    end
    W2F.Camera.handle = nil
    W2F.Camera.active = false
    W2F.Camera.cinematic = nil
end

function W2F.Camera.ResetTargets()
    local c = cfg()
    W2F.Camera.targetYaw = c.defaultYaw
    W2F.Camera.targetPitch = c.defaultPitch
    W2F.Camera.targetDistance = c.defaultDistance
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

function W2F.Camera.UpdateOverview()
    if not W2F.Camera.active or not W2F.Camera.handle or W2F.Camera.mode ~= 'overview' then
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
    local safe = W2F.Camera.ProbeCollision(focal, desired)
    local rot = W2F.Camera.GetLookAtRotation(safe, focal)
    SetCamCoord(W2F.Camera.handle, safe.x, safe.y, safe.z)
    SetCamRot(W2F.Camera.handle, rot.x, rot.y, rot.z, 2)
    SetCamFov(W2F.Camera.handle, W2F.Camera.currentFov)
end

function W2F.Camera.PlayIntro()
    local scene = Config.Scene
    local focal = scene.focal
    local c = cfg()
    local endPos = W2F.Camera.GetOrbitPosition(focal, c.defaultDistance, c.defaultYaw, c.defaultPitch)
    local startPos = vector3(endPos.x, endPos.y, endPos.z + scene.introStartHeight)

    W2F.Camera.Create(focal)
    SetCamCoord(W2F.Camera.handle, startPos.x, startPos.y, startPos.z)
    local rot = W2F.Camera.GetLookAtRotation(startPos, focal)
    SetCamRot(W2F.Camera.handle, rot.x, rot.y, rot.z, 2)

    local startTime = GetGameTimer()
    local duration = scene.introDurationMs

    CreateThread(function()
        while W2F.Camera.active and W2F.Camera.mode == 'overview' do
            local elapsed = GetGameTimer() - startTime
            local t = W2F.Clamp(elapsed / duration, 0.0, 1.0)
            local eased = W2F.EaseOutCubic(t)
            local pos = W2F.Vec3Lerp(startPos, endPos, eased)
            local r = W2F.Camera.GetLookAtRotation(pos, focal)
            SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
            SetCamRot(W2F.Camera.handle, r.x, r.y, r.z, 2)
            if t >= 1.0 then break end
            Wait(0)
        end
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
        if cin.onComplete then cin.onComplete() end
        W2F.Camera.cinematic = nil
        return
    end

    local elapsed = GetGameTimer() - cin.startTime
    local t = W2F.Clamp(elapsed / step.duration, 0.0, 1.0)
    local eased = step.easing and step.easing(t) or W2F.EaseInOutCubic(t)

    local pos = W2F.Vec3Lerp(step.from, step.to, eased)
    local lookAt = step.lookAt or W2F.Camera.focal
    local rot = W2F.Camera.GetLookAtRotation(pos, lookAt)
    SetCamCoord(W2F.Camera.handle, pos.x, pos.y, pos.z)
    SetCamRot(W2F.Camera.handle, rot.x, rot.y, rot.z, 2)

    if step.fovFrom and step.fovTo then
        local fov = W2F.Lerp(step.fovFrom, step.fovTo, eased)
        SetCamFov(W2F.Camera.handle, fov)
    end

    if step.rotate and step.headingFrom and step.headingTo then
        local heading = W2F.Lerp(step.headingFrom, step.headingTo, eased)
        SetCamRot(W2F.Camera.handle, rot.x, rot.y, heading, 2)
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
    return GetFinalRenderedCamCoord()
end
