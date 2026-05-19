W2F = W2F or {}

function W2F.Debug(msg, ...)
    if not Config.Debug then return end
    if select('#', ...) > 0 then
        print(('[w2f-multicharacter] %s'):format(msg:format(...)))
    else
        print(('[w2f-multicharacter] %s'):format(msg))
    end
end

function W2F.Clamp(v, min, max)
    if v < min then return min end
    if v > max then return max end
    return v
end

function W2F.Lerp(a, b, t)
    return a + (b - a) * t
end

function W2F.SmoothStep(current, target, speed)
    if math.abs(target - current) < 0.0001 then
        return target
    end
    return current + (target - current) * speed
end

function W2F.EaseOutCubic(t)
    local inv = 1.0 - t
    return 1.0 - (inv * inv * inv)
end

function W2F.EaseInOutCubic(t)
    if t < 0.5 then
        return 4.0 * t * t * t
    end
    local f = (-2.0 * t) + 2.0
    return 1.0 - (f * f * f) / 2.0
end

function W2F.Vec3Lerp(a, b, t)
    return vector3(
        W2F.Lerp(a.x, b.x, t),
        W2F.Lerp(a.y, b.y, t),
        W2F.Lerp(a.z, b.z, t)
    )
end

function W2F.PlayFrontendSound(soundName)
    if not Config.SpawnCinematic.soundHooks then return end
    PlaySoundFrontend(-1, soundName or 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end

function W2F.RotationToDirection(rot)
    local z = math.rad(rot.z)
    local x = math.rad(rot.x)
    local cosX = math.abs(math.cos(x))
    return vector3(-math.sin(z) * cosX, math.cos(z) * cosX, math.sin(x))
end

function W2F.ScreenToWorldRay()
    local cursorX, cursorY = GetNuiCursorPosition()
    local resX, resY = GetActiveScreenResolution()
    if resX == 0 or resY == 0 then
        resX, resY = 1920, 1080
    end

    local normX = cursorX / resX
    local normY = cursorY / resY
    local camPos, camRot = W2F.Camera.GetRenderedTransform()
    local forward = W2F.RotationToDirection(camRot)
    local right = vector3(forward.y, -forward.x, 0.0)
    local up = vector3(0.0, 0.0, 1.0)
    local fov = (W2F.Camera.handle and DoesCamExist(W2F.Camera.handle)) and GetCamFov(W2F.Camera.handle) or GetGameplayCamFov()
    local aspect = resX / resY
    local tanFov = math.tan(math.rad(fov * 0.5))

    local dir = forward
        + right * ((normX - 0.5) * 2.0 * tanFov * aspect)
        + up * ((0.5 - normY) * 2.0 * tanFov)

    local len = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
    if len < 0.0001 then len = 1.0 end
    return camPos, vector3(dir.x / len, dir.y / len, dir.z / len)
end

function W2F.SendNui(action, data)
    SendNUIMessage({
        action = action,
        data = data or {},
    })
end

function W2F.FormatMoney(amount)
    local n = tonumber(amount) or 0
    local formatted = tostring(math.floor(n))
    local k
    while true do
        formatted, k = formatted:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
        if k == 0 then break end
    end
    return ('$%s'):format(formatted)
end

function W2F.FormatPlaytime(minutes)
    local m = tonumber(minutes) or 0
    local hours = math.floor(m / 60)
    local mins = m % 60
    if hours > 0 then
        return ('%dh %dm'):format(hours, mins)
    end
    return ('%dm'):format(mins)
end

function W2F.SetSelectionFocus(enabled)
    SetNuiFocus(enabled, enabled)
    if SetNuiFocusKeepInput then
        SetNuiFocusKeepInput(enabled)
    end
end
