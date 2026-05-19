W2F.Spawner = {}
W2F.Spawner.previewLoopActive = false
W2F.Spawner.previewAnchor = nil
W2F.Spawner.previewTargets = {}
W2F.Spawner.previewHoveredId = nil
W2F.Spawner.previewCurrentLookAt = nil

function W2F.Spawner.ResolveSpawnCoords(spawnId, character)
    local citizenid = character and character.citizenid or nil
    local resolved = lib.callback.await('w2f-multicharacter:server:requestSpawn', false, spawnId, citizenid)
    if not resolved or not resolved.x then
        return nil
    end
    return vec4(resolved.x, resolved.y, resolved.z, resolved.w or 0.0)
end

local function buildSpawnPreviewCache()
    W2F.Spawner.previewTargets = {}
    if not W2F.State.selectedCharacter then return end
    for i = 1, #Config.Spawns do
        local spawn = Config.Spawns[i]
        local coords = W2F.Spawner.ResolveSpawnCoords(spawn.id, W2F.State.selectedCharacter)
        if coords then
            W2F.Spawner.previewTargets[spawn.id] = vector3(coords.x, coords.y, coords.z)
        end
    end
end

local function startSpawnPreviewLoop()
    if W2F.Spawner.previewLoopActive or not Config.SpawnPreview.enabled then return end
    W2F.Spawner.previewLoopActive = true
    W2F.Spawner.previewAnchor = Config.GetSceneFocal()
    W2F.Spawner.previewCurrentLookAt = W2F.Spawner.previewAnchor
    buildSpawnPreviewCache()

    CreateThread(function()
        while W2F.Spawner.previewLoopActive and W2F.State.isSkySpawnMode do
            if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) and W2F.Camera.mode == 'sky' then
                local target = W2F.Spawner.previewAnchor
                local hovered = W2F.Spawner.previewHoveredId
                if hovered and W2F.Spawner.previewTargets[hovered] then
                    local t = W2F.Spawner.previewTargets[hovered]
                    local s = Config.SpawnPreview.hoverPreviewStrength
                    target = vector3(
                        W2F.Spawner.previewAnchor.x + ((t.x - W2F.Spawner.previewAnchor.x) * s),
                        W2F.Spawner.previewAnchor.y + ((t.y - W2F.Spawner.previewAnchor.y) * s),
                        W2F.Spawner.previewAnchor.z + ((t.z - W2F.Spawner.previewAnchor.z) * (s * 0.65))
                    )
                end

                local speed = Config.SpawnPreview.hoverPreviewSpeed
                local cur = W2F.Spawner.previewCurrentLookAt or target
                W2F.Spawner.previewCurrentLookAt = vector3(
                    W2F.SmoothStep(cur.x, target.x, speed),
                    W2F.SmoothStep(cur.y, target.y, speed),
                    W2F.SmoothStep(cur.z, target.z, speed)
                )

                local camPos = GetCamCoord(W2F.Camera.handle)
                local rot = W2F.Camera.GetLookAtRotation(camPos, W2F.Spawner.previewCurrentLookAt)
                W2F.Camera.SetRotation(W2F.Camera.handle, rot)
            end
            Wait(0)
        end
        W2F.Spawner.previewLoopActive = false
        W2F.Spawner.previewHoveredId = nil
        W2F.Spawner.previewCurrentLookAt = nil
    end)
end

function W2F.Spawner.RecoverFromFailedSpawn(message)
    W2F.State.isSpawning = false
    W2F.State.isTransitioningToSky = false
    W2F.State.isSkySpawnMode = false
    W2F.Camera.cinematic = nil
    W2F.Camera.mode = 'overview'
    W2F.Spawner.previewLoopActive = false

    W2F.SendNui('spawnFailed', { message = message or 'Spawn failed. Try again.' })

    if not W2F.State.isInSelection then
        W2F.Selection.active = false
        Wait(300)
        W2F.EnterSelection()
        return
    end

    local focal = Config.GetSceneFocal()
    local created = W2F.Camera.Create(focal)
    W2F.SetSelectionFocus(true, true)
    W2F.SendNui('showSelection', {})
    if not created then
        W2F.Cleanup.Full(true)
        return
    end
    DoScreenFadeIn(500)
end

function W2F.Spawner.BeginSkySequence()
    if W2F.State.isSpawning or W2F.State.isTransitioningToSky or W2F.State.isSkySpawnMode or not W2F.State.selectedCharacter then
        return
    end

    W2F.State.isSpawning = true
    W2F.State.isTransitioningToSky = true
    W2F.State.detailsVisible = false
    W2F.SetHovered(nil, nil)

    W2F.SendNui('beginSpawnSequence', {})
    W2F.PlayW2FSound(Config.Audio.spawnPress)
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSelectionHints', {})

    DoScreenFadeOut(400)
    while not IsScreenFadedOut() do Wait(0) end

    DoScreenFadeIn(500)

    local camPos = W2F.Camera.GetCurrentCoord()
    local focal = Config.GetSceneFocal()
    local sky = Config.SpawnCinematic
    local skyPos = vector3(focal.x, focal.y, focal.z + sky.skyHeight)

    W2F.Camera.mode = 'cinematic'
    W2F.PlayW2FSound(Config.Audio.skyLaunch)

    W2F.Camera.RunCinematic({
        {
            mode = 'sky',
            from = camPos,
            to = skyPos,
            lookAt = focal,
            duration = sky.skyRiseDurationMs,
            fovFrom = (Config.Camera and Config.Camera.overview and Config.Camera.overview.fov) or Config.CameraControl.fov,
            fovTo = sky.fovSky,
            easing = W2F.EaseInOutCubic,
        },
    }, function()
        W2F.State.isTransitioningToSky = false
        W2F.State.isSkySpawnMode = true
        W2F.Camera.mode = 'sky'
        startSpawnPreviewLoop()
        W2F.SendNui('showSkySpawnOptions', {
            spawns = Config.GetSpawnOptionsForNui(),
        })
        W2F.PlayW2FSound(Config.Audio.locationSelect)
    end)
end

function W2F.Spawner.FlyToSpawn(spawnId)
    if W2F.State.isTransitioningToSky or not W2F.State.isSkySpawnMode or not W2F.State.selectedCharacter then
        return
    end

    local character = W2F.State.selectedCharacter
    local coords = W2F.Spawner.ResolveSpawnCoords(spawnId, character)
    if not coords then
        W2F.Spawner.RecoverFromFailedSpawn('Could not resolve spawn location.')
        return
    end

    W2F.State.selectedSpawn = spawnId
    W2F.State.isSkySpawnMode = false
    W2F.Spawner.previewLoopActive = false
    W2F.SendNui('hideSkySpawnOptions', {})

    local sky = Config.SpawnCinematic
    local camPos = W2F.Camera.GetCurrentCoord()
    local aboveTarget = vector3(coords.x, coords.y, coords.z + sky.flyHeight)
    local groundLook = vector3(coords.x, coords.y, coords.z)
    local travelDistance = #(aboveTarget - camPos)

    W2F.PlayW2FSound(Config.Audio.locationSelect)

    local headingFrom = 0.0
    if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) then
        headingFrom = GetCamRot(W2F.Camera.handle, 2).z
    end

    W2F.Camera.mode = 'cinematic'
    if travelDistance > (sky.travelFadeDistance or 2600.0) then
        DoScreenFadeOut(sky.travelFadeOutMs or 320)
        while not IsScreenFadedOut() do Wait(0) end
        SetCamCoord(W2F.Camera.handle, aboveTarget.x, aboveTarget.y, aboveTarget.z)
        W2F.Camera.SetRotation(W2F.Camera.handle, W2F.Camera.GetLookAtRotation(aboveTarget, groundLook))
        SetCamFov(W2F.Camera.handle, sky.fovSky)
        DoScreenFadeIn(sky.travelFadeInMs or 420)
    end

    CreateThread(function()
        while W2F.State.isSpawning and not W2F.State.isSkySpawnMode do
            Wait(900)
            if W2F.Camera.mode == 'descent' then
                W2F.PlayW2FSound(Config.Audio.descentPulse)
            end
        end
    end)

    W2F.Camera.RunCinematic({
        {
            mode = 'flyToSpawn',
            from = camPos,
            to = aboveTarget,
            lookAt = groundLook,
            duration = sky.flyDurationMs,
            fovFrom = sky.fovSky,
            fovTo = sky.fovSky,
            easing = W2F.EaseInOutCubic,
        },
        {
            mode = 'sky',
            from = aboveTarget,
            to = aboveTarget,
            lookAt = groundLook,
            duration = sky.hoverDurationMs,
            fovFrom = sky.fovSky,
            fovTo = sky.fovDescend,
            easing = W2F.EaseOutCubic,
        },
        {
            mode = 'descent',
            from = aboveTarget,
            to = vector3(coords.x + 2.0, coords.y + 2.0, coords.z + 6.0),
            lookAt = groundLook,
            duration = sky.descendDurationMs,
            fovFrom = sky.fovDescend,
            fovTo = sky.fovGround,
            easing = W2F.EaseInOutCubic,
            rotate = true,
            headingFrom = headingFrom,
            headingTo = coords.w + 15.0,
        },
    }, function()
        W2F.Spawner.FinalizeSpawn(character, coords)
    end)
end

function W2F.Spawner.FinalizeSpawn(character, coords)
    if not character or not character.citizenid or not coords then
        W2F.Spawner.RecoverFromFailedSpawn('Invalid spawn data.')
        return
    end

    if W2F.State.isInSelection ~= true then
        return
    end

    local sky = Config.SpawnCinematic
    DoScreenFadeOut(sky.fadeOutMs)
    while not IsScreenFadedOut() do Wait(0) end

    W2F.Characters.ClearPreviewPeds()
    W2F.Camera.Destroy()
    ClearTimecycleModifier()
    W2F.SetSelectionFocus(false, false)

    local loaded = false
    if W2F.Qbox.IsActive() then
        loaded = W2F.Qbox.LoadCharacterAt(character.citizenid, coords)
    else
        TriggerServerEvent('w2f-multicharacter:server:loadCharacter', character, {
            x = coords.x,
            y = coords.y,
            z = coords.z,
            w = coords.w,
        })
        loaded = true
    end

    if not loaded then
        W2F.SendNui('resetSelectionUI', {})
        W2F.Spawner.RecoverFromFailedSpawn('Failed to load character.')
        return
    end

    W2F.Selection.active = false
    W2F.State.isInSelection = false
    W2F.State.isTransitioningToSky = false
    W2F.State.isSpawning = false
    W2F.State.isSkySpawnMode = false
    W2F.ResetState()

    W2F.Cleanup.EndTutorialSession()
    W2F.Cleanup.ResetRoutingBucket()
    DisplayRadar(true)
    W2F.Cleanup.ResetPlayerPed()

    Wait(400)
    DoScreenFadeIn(sky.fadeInMs)
    W2F.PlayW2FSound(Config.Audio.finalSpawn)
end

RegisterNUICallback('pressSpawn', function(_, cb)
    if W2F.State.selectedCharacter and not W2F.State.isSpawning then
        W2F.Spawner.BeginSkySequence()
    end
    cb('ok')
end)

RegisterNUICallback('chooseSkySpawn', function(data, cb)
    local spawnId = data and data.id
    if spawnId and spawnId ~= '' and W2F.State.isSkySpawnMode then
        W2F.Spawner.FlyToSpawn(spawnId)
    end
    cb('ok')
end)

RegisterNUICallback('spawnLocationHover', function(_, cb)
    cb('ok')
end)

RegisterNUICallback('previewSkySpawn', function(data, cb)
    if not Config.SpawnPreview.enabled or not W2F.State.isSkySpawnMode then
        cb('ok')
        return
    end

    local id = data and data.id or nil
    W2F.Spawner.previewHoveredId = (id and id ~= '') and id or nil
    if W2F.Spawner.previewHoveredId then
        W2F.PlayW2FSound(Config.Audio.hover)
    end
    cb('ok')
end)
