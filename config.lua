Config = {}

Config.Debug = false

--- Set true only when qbx_core/config/client.lua has characters.useExternalCharacters = true
Config.UseExternalCharacters = true

--- Opens selection on session start (requires UseExternalCharacters)
Config.AutoOpen = true

-- Character selection scene (ped lineup)
Config.Scene = {
    pedSlots = {
        vec4(-1360.8, -1486.1, 3.04, 208.0),
        vec4(-1357.8, -1487.1, 3.07, 209.5),
        vec4(-1354.7, -1488.0, 3.10, 211.0),
        vec4(-1351.6, -1488.9, 3.07, 212.5),
        vec4(-1348.6, -1489.9, 3.04, 214.0),
    },
    introDurationMs = 2800,
    introStartHeight = 16.0,
    --- Extra height added to ped-center focal point for camera look-at
    focalHeightOffset = 0.85,
}

Config.CameraControl = {
    enabled = true,
    sensitivityX = 0.08,
    sensitivityY = 0.04,
    smoothing = 0.12,
    minYaw = -35.0,
    maxYaw = 35.0,
    minPitch = -8.0,
    maxPitch = 12.0,
    minDistance = 7.0,
    maxDistance = 11.0,
    defaultDistance = 9.0,
    --- Slight diagonal in front of lineup (premium showcase angle)
    defaultYaw = -10.0,
    defaultPitch = 4.0,
    settleSpeed = 0.08,
    fov = 42.0,
    collisionProbe = true,
}

Config.Camera = {
    overview = {
        distance = 9.0,
        height = 1.8,
        fov = 42.0,
        yaw = 0.0,
        pitch = 4.0,
    },
    focus = {
        distance = 5.5,
        height = 1.4,
        fov = 35.0,
    },
    smoothing = 0.12,
    idleDrift = true,
    idleDriftStrength = 0.035,
    resetTime = 900,
}

Config.Highlight = {
    outlineColor = { r = 255, g = 255, b = 255 },
    selectedColor = { r = 120, g = 200, b = 255 },
}

Config.Interaction = {
    clickDebounceMs = 350,
    rayMaxDistance = 14.0,
    pedSelectRadius = 1.45,
    dragThreshold = 8.0,
}

Config.SpawnCinematic = {
    skyHeight = 420.0,
    skyRiseDurationMs = 2200,
    flyDurationMs = 4500,
    flyHeight = 380.0,
    hoverDurationMs = 1200,
    descendDurationMs = 3200,
    descendEndHeight = 28.0,
    fovSky = 50.0,
    fovDescend = 48.0,
    fovGround = 42.0,
    fadeOutMs = 800,
    fadeInMs = 900,
    soundHooks = true,
}

Config.Spawns = {
    {
        id = 'last',
        label = 'Last Location',
        type = 'last',
        fallback = 'public',
    },
    {
        id = 'police',
        label = 'Police Station',
        coords = vec4(441.23, -981.89, 30.69, 90.0),
    },
    {
        id = 'public',
        label = 'Public Centre',
        coords = vec4(215.76, -810.12, 30.73, 160.0),
    },
    {
        id = 'hospital',
        label = 'Hospital',
        coords = vec4(298.54, -584.41, 43.26, 70.0),
    },
}

Config.UseQbox = true
Config.MaxCharacters = 5

--- Computes the camera look-at focal point from ped slot positions.
function Config.GetSceneFocal()
    local slots = Config.Scene.pedSlots
    if not slots or #slots == 0 then
        return vec3(0.0, 0.0, 0.0)
    end

    local sumX, sumY, sumZ = 0.0, 0.0, 0.0
    for i = 1, #slots do
        sumX = sumX + slots[i].x
        sumY = sumY + slots[i].y
        sumZ = sumZ + slots[i].z
    end

    local count = #slots
    return vec3(
        sumX / count,
        sumY / count,
        (sumZ / count) + (Config.Scene.focalHeightOffset or 0.0)
    )
end

--- NUI-safe spawn list (no vector values).
--- Distance from focal point based on ped lineup span (keeps all peds in frame).
function Config.GetRecommendedCameraDistance()
    local slots = Config.Scene.pedSlots
    local c = Config.CameraControl
    if not slots or #slots < 2 then
        return c.defaultDistance
    end

    local first, last = slots[1], slots[#slots]
    local span = #(vector3(first.x, first.y, first.z) - vector3(last.x, last.y, last.z))
    local distance = span * 1.25 + 5.5
    if distance < c.minDistance then return c.minDistance end
    if distance > c.maxDistance then return c.maxDistance end
    return distance
end

function Config.GetSpawnOptionsForNui()
    local options = {}
    for i = 1, #Config.Spawns do
        local spawn = Config.Spawns[i]
        options[#options + 1] = {
            id = spawn.id,
            label = spawn.label,
        }
    end
    return options
end
