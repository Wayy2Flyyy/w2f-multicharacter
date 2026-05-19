Config = {}

Config.Debug = false

-- Character selection scene (ped lineup + camera focal point)
Config.Scene = {
    focal = vec3(-1355.93, -1487.78, 4.04),
    pedSlots = {
        vec4(-1360.2, -1485.5, 3.04, 210.0),
        vec4(-1357.1, -1486.8, 3.04, 210.0),
        vec4(-1354.0, -1488.1, 3.04, 210.0),
        vec4(-1350.9, -1489.4, 3.04, 210.0),
        vec4(-1347.8, -1490.7, 3.04, 210.0),
    },
    introDurationMs = 2800,
    introStartHeight = 18.0,
}

Config.CameraControl = {
    enabled = true,
    holdButton = 'LEFT_CLICK',
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
    defaultYaw = 0.0,
    defaultPitch = 4.0,
    settleSpeed = 0.08,
    fov = 42.0,
    collisionProbe = true,
}

Config.Highlight = {
    hoverAlpha = 0.35,
    selectedAlpha = 0.55,
    outlineColor = { r = 255, g = 255, b = 255 },
    selectedColor = { r = 120, g = 200, b = 255 },
}

Config.Interaction = {
    clickDebounceMs = 350,
    rayMaxDistance = 12.0,
    pedSelectRadius = 1.35,
}

Config.SpawnCinematic = {
    skyHeight = 420.0,
    skyRiseDurationMs = 2200,
    skyRiseEasing = 0.08,
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
    soundHooks = true, -- plays GTA frontend sounds when available
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

-- Qbox integration (do not duplicate core logic)
Config.UseQbox = true
Config.MaxCharacters = 5
