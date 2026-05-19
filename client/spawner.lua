W2F.Spawner = {}

local function getSpawnById(id)
    for _, spawn in ipairs(Config.Spawns) do
        if spawn.id == id then
            return spawn
        end
    end
end

function W2F.Spawner.ResolveSpawnCoords(spawnId)
    local spawn = getSpawnById(spawnId)
    if not spawn then return nil end

    if spawn.type == 'last' then
        local last = lib.callback.await('w2f-multicharacter:server:getLastLocation', false, W2F.State.selectedCharacter)
        if last and last.x then
            return vec4(last.x, last.y, last.z, last.w or 0.0)
        end
        local fallback = getSpawnById(spawn.fallback or 'public')
        return fallback and fallback.coords or nil
    end

    return spawn.coords
end

function W2F.Spawner.BeginSkySequence()
    if W2F.State.isSpawning or not W2F.State.selectedCharacter then
        return
    end

    W2F.State.isSpawning = true
    W2F.State.isSkySpawnMode = true
    W2F.State.detailsVisible = false

    W2F.SendNui('beginSpawnSequence', {})
    W2F.SendNui('hideCharacterDetails', {})

    DoScreenFadeOut(400)
    while not IsScreenFadedOut() do Wait(0) end

    W2F.SendNui('hideSkySpawnOptions', {})
    DoScreenFadeIn(500)

    local camPos = W2F.Camera.GetCurrentCoord()
    local focal = Config.Scene.focal
    local sky = Config.SpawnCinematic
    local skyPos = vector3(focal.x, focal.y, focal.z + sky.skyHeight)

    W2F.Camera.mode = 'cinematic'
    W2F.PlayFrontendSound('Zoom_In')

    W2F.Camera.RunCinematic({
        {
            from = camPos,
            to = skyPos,
            lookAt = focal,
            duration = sky.skyRiseDurationMs,
            fovFrom = Config.CameraControl.fov,
            fovTo = sky.fovSky,
            easing = W2F.EaseInOutCubic,
        },
    }, function()
        W2F.Camera.mode = 'sky'
        W2F.SendNui('showSkySpawnOptions', {
            spawns = Config.Spawns,
        })
        W2F.PlayFrontendSound('SELECT')
    end)
end

function W2F.Spawner.FlyToSpawn(spawnId)
    if not W2F.State.isSkySpawnMode then return end

    local coords = W2F.Spawner.ResolveSpawnCoords(spawnId)
    if not coords then return end

    W2F.State.selectedSpawn = spawnId
    W2F.SendNui('hideSkySpawnOptions', {})
    W2F.State.isSkySpawnMode = false

    local sky = Config.SpawnCinematic
    local camPos = W2F.Camera.GetCurrentCoord()
    local aboveTarget = vector3(coords.x, coords.y, coords.z + sky.flyHeight)
    local hoverTarget = vector3(coords.x, coords.y, coords.z + sky.descendEndHeight + 40.0)
    local groundLook = vector3(coords.x, coords.y, coords.z)

    W2F.PlayFrontendSound('WAYPOINT_SET')

    W2F.Camera.RunCinematic({
        {
            from = camPos,
            to = aboveTarget,
            lookAt = groundLook,
            duration = sky.flyDurationMs,
            fovFrom = sky.fovSky,
            fovTo = sky.fovSky,
            easing = W2F.EaseInOutCubic,
        },
        {
            from = aboveTarget,
            to = hoverTarget,
            lookAt = groundLook,
            duration = sky.hoverDurationMs,
            fovFrom = sky.fovSky,
            fovTo = sky.fovDescend,
            easing = W2F.EaseOutCubic,
        },
        {
            from = hoverTarget,
            to = vector3(coords.x + 2.0, coords.y + 2.0, coords.z + 6.0),
            lookAt = groundLook,
            duration = sky.descendDurationMs,
            fovFrom = sky.fovDescend,
            fovTo = sky.fovGround,
            easing = W2F.EaseInOutCubic,
            rotate = true,
            headingFrom = GetCamRot(W2F.Camera.handle, 2).z,
            headingTo = coords.w + 15.0,
        },
    }, function()
        W2F.Spawner.FinalizeSpawn(coords)
    end)
end

function W2F.Spawner.FinalizeSpawn(coords)
    local sky = Config.SpawnCinematic
    DoScreenFadeOut(sky.fadeOutMs)
    while not IsScreenFadedOut() do Wait(0) end

    W2F.Spawner.Cleanup()

    local ped = cache.ped or PlayerPedId()
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, coords.w)
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)

    TriggerServerEvent('w2f-multicharacter:server:loadCharacter', W2F.State.selectedCharacter)

    Wait(500)
    DoScreenFadeIn(sky.fadeInMs)
    W2F.PlayFrontendSound('BACK')
end

function W2F.Spawner.Cleanup()
    W2F.Characters.ClearPreviewPeds()
    W2F.Camera.Destroy()
    SetNuiFocus(false, false)
    W2F.SendNui('resetSelectionUI', {})
    ClearTimecycleModifier()
    W2F.ResetState()
end

RegisterNUICallback('pressSpawn', function(_, cb)
    if W2F.State.selectedCharacter and not W2F.State.isSpawning then
        W2F.Spawner.BeginSkySequence()
    end
    cb('ok')
end)

RegisterNUICallback('chooseSkySpawn', function(data, cb)
    local spawnId = data and data.id
    if spawnId and W2F.State.isSkySpawnMode then
        W2F.Spawner.FlyToSpawn(spawnId)
    end
    cb('ok')
end)
