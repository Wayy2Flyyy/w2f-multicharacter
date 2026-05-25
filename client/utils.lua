W2F = W2F or {}
W2F.Bootstrap = W2F.Bootstrap or { nuiReady = false, opening = false }

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

function W2F.Vec3SmoothStep(current, target, speed)
    return vector3(
        W2F.SmoothStep(current.x, target.x, speed),
        W2F.SmoothStep(current.y, target.y, speed),
        W2F.SmoothStep(current.z, target.z, speed)
    )
end

--- Shortest-arc yaw interpolation (degrees).
function W2F.SmoothYaw(current, target, speed)
    local delta = target - current
    while delta > 180.0 do delta = delta - 360.0 end
    while delta < -180.0 do delta = delta + 360.0 end
    if math.abs(delta) < 0.01 then return target end
    return current + (delta * speed)
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

function W2F.EaseInOutQuint(t)
    if t < 0.5 then
        return 16.0 * t * t * t * t * t
    end
    local f = (-2.0 * t) + 2.0
    return 1.0 - (f * f * f * f * f) / 2.0
end

function W2F.EaseOutQuint(t)
    local f = 1.0 - t
    return 1.0 - f * f * f * f * f
end

--- Quadratic bezier (P0, P1, P2) — used for swooping camera paths.
function W2F.Vec3Bezier(p0, p1, p2, t)
    local u = 1.0 - t
    local uu = u * u
    local tt = t * t
    return vector3(
        uu * p0.x + 2.0 * u * t * p1.x + tt * p2.x,
        uu * p0.y + 2.0 * u * t * p1.y + tt * p2.y,
        uu * p0.z + 2.0 * u * t * p1.z + tt * p2.z
    )
end

function W2F.Vec3Lerp(a, b, t)
    return vector3(
        W2F.Lerp(a.x, b.x, t),
        W2F.Lerp(a.y, b.y, t),
        W2F.Lerp(a.z, b.z, t)
    )
end

--- Centripetal-ish Catmull-Rom spline (uniform). Passes THROUGH p1 and p2 with
--- C1-continuous tangents -> velocity is continuous across waypoints, which is
--- what kills the "rigid" feel between cinematic phases.
function W2F.Vec3CatmullRom(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    return vector3(
        0.5 * ((2.0 * p1.x) + (-p0.x + p2.x) * t + (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2 + (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3),
        0.5 * ((2.0 * p1.y) + (-p0.y + p2.y) * t + (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2 + (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3),
        0.5 * ((2.0 * p1.z) + (-p0.z + p2.z) * t + (2.0 * p0.z - 5.0 * p1.z + 4.0 * p2.z - p3.z) * t2 + (-p0.z + 3.0 * p1.z - 3.0 * p2.z + p3.z) * t3)
    )
end

function W2F.NumCatmullRom(a, b, c, d, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (-a + 3.0 * b - 3.0 * c + d) * t3)
end

local function findSegment(times, t)
    local n = #times
    for i = 1, n - 1 do
        if t <= times[i + 1] then
            local span = times[i + 1] - times[i]
            if span < 0.000001 then return i, 0.0 end
            return i, (t - times[i]) / span
        end
    end
    return n - 1, 1.0
end

--- Sample a Catmull-Rom path through waypoints at progress t in [0,1].
--- Optional `times` array (same length as waypoints, monotonic 0..1) lets you
--- weight segments so you can hold longer on some waypoints than others — this
--- is how we get a slow "hover over location" before the steep drop.
function W2F.SamplePath(waypoints, t, times)
    local n = #waypoints
    if n == 0 then return vector3(0.0, 0.0, 0.0) end
    if n == 1 then return waypoints[1] end
    if n == 2 then return W2F.Vec3Lerp(waypoints[1], waypoints[2], t) end

    local clamped = W2F.Clamp(t, 0.0, 1.0)
    local segIdx, localT
    if times and #times == n then
        segIdx, localT = findSegment(times, clamped)
    else
        local segments = n - 1
        segIdx = math.min(math.floor(clamped * segments) + 1, segments)
        localT = clamped * segments - (segIdx - 1)
    end

    local p0 = waypoints[math.max(1, segIdx - 1)]
    local p1 = waypoints[segIdx]
    local p2 = waypoints[segIdx + 1]
    local p3 = waypoints[math.min(n, segIdx + 2)]
    return W2F.Vec3CatmullRom(p0, p1, p2, p3, localT)
end

function W2F.SampleNumPath(values, t, times)
    local n = #values
    if n == 0 then return 0.0 end
    if n == 1 then return values[1] end
    if n == 2 then return W2F.Lerp(values[1], values[2], t) end

    local clamped = W2F.Clamp(t, 0.0, 1.0)
    local segIdx, localT
    if times and #times == n then
        segIdx, localT = findSegment(times, clamped)
    else
        local segments = n - 1
        segIdx = math.min(math.floor(clamped * segments) + 1, segments)
        localT = clamped * segments - (segIdx - 1)
    end

    return W2F.NumCatmullRom(
        values[math.max(1, segIdx - 1)],
        values[segIdx],
        values[segIdx + 1],
        values[math.min(n, segIdx + 2)],
        localT
    )
end

function W2F.PlayFrontendSound(soundName)
    if not Config.SpawnCinematic.soundHooks then return end
    PlaySoundFrontend(-1, soundName or 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end

function W2F.PlayW2FSound(soundName)
    if not Config.Audio or Config.Audio.enabled == false then
        return
    end

    if not soundName or soundName == '' then
        return
    end

    local map = {
        ui_hover = 'NAV_UP_DOWN',
        ui_select = 'SELECT',
        ui_details_open = 'NAV_LEFT_RIGHT',
        ui_spawn_press = 'SELECT',
        sky_launch = 'Zoom_In',
        location_select = 'WAYPOINT_SET',
        descent_pulse = '3_2_1',
        final_spawn = 'BACK',
    }

    local frontend = map[soundName] or soundName
    pcall(function()
        PlaySoundFrontend(-1, frontend, 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    end)
end

--- Project a world position to normalized screen coords (0..1). Returns
--- (onScreen, x, y). Wraps the GTA native so callers don't have to worry
--- about its argument order quirks.
function W2F.World3DToScreen(point)
    if not point then return false, 0, 0 end
    local ok, sx, sy = World3dToScreen2d(point.x, point.y, point.z)
    if not ok then return false, 0, 0 end
    return true, sx, sy
end

function W2F.RotationToDirection(rot)
    local z = math.rad(rot.z)
    local x = math.rad(rot.x)
    local cosX = math.abs(math.cos(x))
    return vector3(-math.sin(z) * cosX, math.cos(z) * cosX, math.sin(x))
end

local function vNorm(v)
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if len < 0.0001 then return vector3(0.0, 0.0, 0.0), 0.0 end
    return vector3(v.x / len, v.y / len, v.z / len), len
end

local function vCross(a, b)
    return vector3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
end

function W2F.ScreenToWorldRay()
    local cursorX, cursorY = GetNuiCursorPosition()
    local resX, resY = GetActiveScreenResolution()
    if not resX or resX == 0 or not resY or resY == 0 then
        resX, resY = 1920, 1080
    end
    cursorX = cursorX or (resX * 0.5)
    cursorY = cursorY or (resY * 0.5)

    local normX = (cursorX / resX) * 2.0 - 1.0
    local normY = 1.0 - (cursorY / resY) * 2.0
    local camPos, camRot = W2F.Camera.GetRenderedTransform()
    local forward = vNorm(W2F.RotationToDirection(camRot))
    local right = vNorm(vCross(forward, vector3(0.0, 0.0, 1.0)))
    local up = vNorm(vCross(right, forward))

    local fov = (W2F.Camera.handle and DoesCamExist(W2F.Camera.handle))
        and GetCamFov(W2F.Camera.handle)
        or GetGameplayCamFov()
    local aspect = resX / resY
    local tanFovY = math.tan(math.rad(fov * 0.5))
    local tanFovX = tanFovY * aspect

    local dir = vector3(
        forward.x + right.x * (normX * tanFovX) + up.x * (normY * tanFovY),
        forward.y + right.y * (normX * tanFovX) + up.y * (normY * tanFovY),
        forward.z + right.z * (normX * tanFovX) + up.z * (normY * tanFovY)
    )
    return camPos, (vNorm(dir))
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

function W2F.SetSelectionFocus(hasCursor, keepGameInput)
    local cursor = hasCursor == true
    local keepInput = keepGameInput == true
    W2F.State.nuiFocused = cursor
    SetNuiFocus(cursor, cursor)
    if SetNuiFocusKeepInput then
        SetNuiFocusKeepInput(keepInput)
    end
end

--- True when the player should only interact with multichar NUI (not peds/chat/pause).
function W2F.IsUiLocked()
    if W2F.State.isCreatePanelOpen or W2F.State.isCreatingCharacter then
        return true
    end
    if W2F.Creator and W2F.Creator.active then
        return true
    end
    if W2F.State.isSkySpawnMode or W2F.State.isSpawning or W2F.State.isTransitioningToSky then
        return true
    end
    return false
end
