--- W2F.Spawner - sky picker, fly-to-spawn cinematic, apartment claim,
--- character load + finalize. Rebuilt on top of:
---   * W2F.Session             (canonical phase machine)
---   * W2F.CharacterLoad.Load  (explicit step-by-step character load)
---   * W2F.Streaming           (RAII collision + focus + scene)
---   * W2F.Watchdog            (cinematic / NUI / callback safety nets)
---   * W2F.Nui                 (standardized envelopes + payload builder)
---   * W2F.Frame               (frame-rate-independent smoothing)
---
--- Phase contract:
---   selection -> sky_picker     (BeginSkySequence / OpenFirstSpawnPicker)
---   sky_picker -> flying        (FlyToSpawn)
---   flying -> finalizing -> playing  (cinematic complete + load OK)
---   sky_picker -> finalizing -> playing  (apartment claim)
---   <any spawn phase> -> recovering -> selection  (RecoverFromFailedSpawn)
---
--- isSpawning / isTransitioningToSky / isSkySpawnMode now derive from
--- Session.phase via the adapter in core/session.lua.

W2F.Spawner = {}
W2F.Spawner.previewLoopActive = false
W2F.Spawner.recovering = false
W2F.Spawner.previewAnchor = nil
W2F.Spawner.previewCamAnchor = nil
W2F.Spawner.previewTargets = {}
W2F.Spawner.previewHoveredId = nil
W2F.Spawner.previewCurrentLookAt = nil
W2F.Spawner.previewCurrentCam = nil
W2F.Spawner.smoothedLookGoal = nil
W2F.Spawner.smoothedCamGoal = nil
W2F.Spawner.spawnLoadStarted = false
W2F.Spawner.spawnLoadComplete = false
W2F.Spawner.streamHandle = nil
W2F.Spawner.lastApartmentOptions = nil

local CINEMATIC_TIMEOUTS = {
    skyRise = 12000,
    fly = 18000,
    finalize = 15000,
}

local function dbg(...)
    if W2F.Debug then W2F.Debug(...) end
end

local function resetSpawnLoadFlags()
    W2F.Spawner.spawnLoadStarted = false
    W2F.Spawner.spawnLoadComplete = false
end

local function releaseStreamHandle()
    if W2F.Spawner.streamHandle then
        if W2F.Streaming and W2F.Streaming.Release then
            W2F.Streaming.Release(W2F.Spawner.streamHandle)
        end
        W2F.Spawner.streamHandle = nil
    end
end

function W2F.Spawner.ReleaseStream()
    releaseStreamHandle()
end

-----------------------------------------------------------------------------
--- Cinematic: 3-phase fly-to-spawn.
-----------------------------------------------------------------------------
local function buildPedFlyCinematic(startCamPos, ped, coords, sky, teleported)
    local pedCoords = GetEntityCoords(ped)
    local headingRad = math.rad(coords.w or 0.0)
    local backX, backY = -math.sin(headingRad), -math.cos(headingRad)
    local flyH = sky.flyHeight or 320.0

    local transitPos = vector3(pedCoords.x, pedCoords.y, pedCoords.z + flyH * 0.86)
    local descendMid = vector3(
        pedCoords.x + backX * 5.5,
        pedCoords.y + backY * 5.5,
        pedCoords.z + flyH * 0.34
    )
    local overviewPos = vector3(
        pedCoords.x + backX * 10.0,
        pedCoords.y + backY * 10.0,
        pedCoords.z + flyH * 0.42
    )
    local finalPos = vector3(
        pedCoords.x + backX * 2.6,
        pedCoords.y + backY * 2.6,
        pedCoords.z + 1.55
    )
    local pedFocus = vector3(pedCoords.x, pedCoords.y, pedCoords.z + (sky.pedFocusHeight or 0.95))

    local transitDuration = teleported and 1 or (sky.flyDurationMs or 5200)
    local holdDuration = sky.hoverDurationMs or 1600
    local descendDuration = sky.descendDurationMs or 4200

    local flyStep
    if teleported then
        flyStep = {
            mode = 'flyToSpawn',
            from = startCamPos,
            to = transitPos,
            lookAtFrom = pedFocus,
            lookAtTo = pedFocus,
            duration = transitDuration,
            easing = function(x) return x end,
            fovFrom = sky.fovSky,
            fovTo = sky.fovSky,
            smoothFactor = (sky.cameraSmoothFactor or 0.12),
            lookAtSmoothFactor = (sky.cameraLookAtSmoothFactor or sky.cameraSmoothFactor or 0.12),
            fovSmoothFactor = 0.10,
            swayStrength = 0.0,
            fovBob = 0.0,
        }
    else
        local toTarget = transitPos - startCamPos
        local horizLen = math.sqrt(toTarget.x * toTarget.x + toTarget.y * toTarget.y)
        local perpX, perpY = 0.0, 0.0
        if horizLen > 0.01 then
            perpX = -toTarget.y / horizLen
            perpY = toTarget.x / horizLen
        end
        local arcLift = math.min(180.0, math.max(50.0, horizLen * 0.06))
        local arcPeak = vector3(
            (startCamPos.x + transitPos.x) * 0.5 + perpX * arcLift * 0.30,
            (startCamPos.y + transitPos.y) * 0.5 + perpY * arcLift * 0.30,
            math.max(startCamPos.z, transitPos.z) + arcLift * 0.50
        )

        flyStep = {
            mode = 'flyToSpawn',
            path = { startCamPos, arcPeak, transitPos },
            times = { 0.0, 0.42, 1.0 },
            lookAtFrom = pedFocus,
            lookAtTo = pedFocus,
            duration = transitDuration,
            easing = W2F.EaseInOutQuint,
            fovPath = { sky.fovSky, sky.fovSky, sky.fovSky },
            smoothFactor = (sky.cameraSmoothFactor or 0.12),
            lookAtSmoothFactor = (sky.cameraLookAtSmoothFactor or sky.cameraSmoothFactor or 0.12),
            fovSmoothFactor = 0.10,
            swayStrength = 0.0,
            fovBob = 0.0,
            markers = {
                { at = 0.70, fn = function() W2F.PlayW2FSound(Config.Audio.descentPulse) end },
            },
        }
    end

    local holdStep = {
        mode = 'flyToSpawn',
        from = transitPos,
        to = overviewPos,
        lookAtFrom = vector3(pedCoords.x, pedCoords.y, pedCoords.z + (sky.pedFocusHeight or 0.95) + 16.0),
        lookAtTo = pedFocus,
        duration = holdDuration,
        easing = W2F.EaseInOutCubic,
        fovFrom = sky.fovSky,
        fovTo = sky.fovDescend,
        smoothFactor = (sky.cameraSmoothFactor or 0.12),
        lookAtSmoothFactor = (sky.cameraLookAtSmoothFactor or sky.cameraSmoothFactor or 0.12),
        fovSmoothFactor = 0.10,
        swayStrength = 0.0,
        fovBob = 0.0,
    }

    local descendStep = {
        mode = 'flyToSpawn',
        path = { overviewPos, descendMid, finalPos },
        times = { 0.0, 0.52, 1.0 },
        trackPed = true,
        duration = descendDuration,
        easing = W2F.EaseInOutQuint,
        fovPath = { sky.fovDescend, sky.fovDescend, sky.fovGround },
        smoothFactor = (sky.cameraSmoothFactor or 0.12),
        lookAtSmoothFactor = (sky.cameraLookAtSmoothFactor or sky.cameraSmoothFactor or 0.12),
        fovSmoothFactor = 0.10,
        swayStrength = 0.0,
        fovBob = 0.0,
        markers = {
            { at = 0.50, fn = function() W2F.PlayW2FSound(Config.Audio.descentPulse) end },
            { at = 0.88, fn = function() W2F.PlayW2FSound(Config.Audio.descentPulse) end },
        },
    }

    return { flyStep, holdStep, descendStep }
end

-----------------------------------------------------------------------------
--- Streaming + character load.
---
--- The old `LoadCharacterDuringFly` called Qbox.LoadCharacterAt which
--- returned true on partial failure. The replacement routes through
--- CharacterLoad.Load and surfaces the explicit reason on failure.
-----------------------------------------------------------------------------
local function loadCharacterDuringFly(character, coords)
    if W2F.Spawner.spawnLoadStarted or not character or not character.citizenid or not coords then
        return false, 'invalid_args'
    end
    W2F.Spawner.spawnLoadStarted = true

    if W2F.Cleanup and W2F.Cleanup.ReleaseSelectionWorldState then
        W2F.Cleanup.ReleaseSelectionWorldState('load_character_during_fly')
    end

    if W2F.Hud and W2F.Hud.Hide then W2F.Hud.Hide() end
    W2F.Characters.ClearPreviewPeds()

    W2F.Cleanup.ResetRoutingBucket()
    Wait(150)

    local started = GetGameTimer()
    local ok, reason, _ = W2F.CharacterLoad.Load({
        citizenid = character.citizenid,
        coords = coords,
    })
    local elapsed = GetGameTimer() - started

    if W2F.CharacterLoad.LogResult then
        W2F.CharacterLoad.LogResult(character.citizenid, ok, reason, elapsed)
    end

    if not ok then
        W2F.Spawner.spawnLoadStarted = false
        return false, reason
    end

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)

    W2F.Spawner.spawnLoadComplete = true
    return true
end

function W2F.Spawner.ResolveSpawnCoords(spawnId, character)
    local citizenid = character and character.citizenid or nil
    local resolved = lib.callback.await('w2f-multicharacter:server:requestSpawn', false, spawnId, citizenid)
    if not resolved or not resolved.x then
        return nil
    end
    return vec4(resolved.x, resolved.y, resolved.z, resolved.w or 0.0)
end

-----------------------------------------------------------------------------
--- Sky picker NUI payload.
-----------------------------------------------------------------------------
local function buildSpawnCardsForNui()
    local isNew = W2F.State.isNewCharacter == true
    local spawns = Config.GetSpawnOptionsForNui({ newCharacter = isNew })
    if not isNew then return spawns end

    local apt = Config.Apartments
    if not apt or apt.enabled == false then return spawns end
    if not (W2F.IsQbxPropertiesAvailable and W2F.IsQbxPropertiesAvailable()) then return spawns end

    local character = W2F.State.selectedCharacter
    if not character or not character.citizenid then return spawns end

    local pending = W2F.State.pendingNewCitizenid
    if pending and pending ~= character.citizenid then return spawns end

    local options = lib.callback.await('w2f-multicharacter:server:getApartmentOptions', false, character.citizenid)
    if type(options) ~= 'table' or #options == 0 then return spawns end

    local suffix = apt.cardSuffix or 'Free starter apartment'
    for i = 1, #options do
        local o = options[i]
        spawns[#spawns + 1] = {
            id = o.id,
            label = o.label,
            description = o.description and (o.description .. ' — ' .. suffix) or suffix,
            kind = 'apartment',
            aptIndex = o.index,
            coords = o.coords,
        }
    end
    return spawns
end

W2F.Spawner.BuildSpawnCardsForNui = buildSpawnCardsForNui

local function buildSpawnPreviewCache()
    W2F.Spawner.previewTargets = {}
    if not W2F.State.selectedCharacter then return end
    local citizenid = W2F.State.selectedCharacter.citizenid
    for i = 1, #Config.Spawns do
        local spawn = Config.Spawns[i]
        local resolved = lib.callback.await('w2f-multicharacter:server:resolveSpawnById', false, spawn.id, citizenid)
        if resolved and resolved.x then
            W2F.Spawner.previewTargets[spawn.id] = vector3(resolved.x, resolved.y, resolved.z)
        end
    end

    if W2F.Spawner.lastApartmentOptions then
        for i = 1, #W2F.Spawner.lastApartmentOptions do
            local o = W2F.Spawner.lastApartmentOptions[i]
            if o.coords then
                W2F.Spawner.previewTargets[o.id] = vector3(o.coords.x, o.coords.y, o.coords.z)
            end
        end
    end
end

-----------------------------------------------------------------------------
--- Sky-picker preview loop (frame-rate-independent smoothing).
-----------------------------------------------------------------------------
local function startSpawnPreviewLoop()
    if W2F.Spawner.previewLoopActive or not Config.SpawnPreview.enabled then return end
    W2F.Spawner.previewLoopActive = true
    W2F.Spawner.previewAnchor = Config.GetSceneFocal()
    W2F.Spawner.previewCurrentLookAt = W2F.Spawner.previewAnchor
    W2F.Spawner.smoothedLookGoal = W2F.Spawner.previewAnchor

    if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) then
        W2F.Spawner.previewCamAnchor = GetCamCoord(W2F.Camera.handle)
        W2F.Spawner.previewCurrentCam = W2F.Spawner.previewCamAnchor
        W2F.Spawner.smoothedCamGoal = W2F.Spawner.previewCamAnchor
    end
    buildSpawnPreviewCache()

    CreateThread(function()
        while W2F.Spawner.previewLoopActive and W2F.Session.Is('sky_picker') do
            if W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) and W2F.Camera.mode == 'sky' then
                local preview = Config.SpawnPreview
                local rawLookTarget = W2F.Spawner.previewAnchor
                local rawCamTarget = W2F.Spawner.previewCamAnchor or GetCamCoord(W2F.Camera.handle)
                local hovered = W2F.Spawner.previewHoveredId

                if hovered and W2F.Spawner.previewTargets[hovered] then
                    local t = W2F.Spawner.previewTargets[hovered]
                    RequestCollisionAtCoord(t.x, t.y, t.z)
                    local s = preview.hoverPreviewStrength or 0.55
                    rawLookTarget = vector3(
                        W2F.Spawner.previewAnchor.x + ((t.x - W2F.Spawner.previewAnchor.x) * s),
                        W2F.Spawner.previewAnchor.y + ((t.y - W2F.Spawner.previewAnchor.y) * s),
                        W2F.Spawner.previewAnchor.z + ((t.z - W2F.Spawner.previewAnchor.z) * (s * 0.65))
                    )

                    local camDriftS = preview.hoverCameraDriftStrength or 0.25
                    if W2F.Spawner.previewCamAnchor then
                        rawCamTarget = vector3(
                            W2F.Spawner.previewCamAnchor.x + ((t.x - W2F.Spawner.previewCamAnchor.x) * camDriftS),
                            W2F.Spawner.previewCamAnchor.y + ((t.y - W2F.Spawner.previewCamAnchor.y) * camDriftS),
                            W2F.Spawner.previewCamAnchor.z + ((t.z - W2F.Spawner.previewCamAnchor.z) * (camDriftS * 0.4))
                        )
                    end
                end

                local dt = W2F.Frame.Dt()
                --- Convert the legacy "speed per frame at 60fps" tuning to a
                --- rate (e-folds/sec) so the result is frame-rate-independent.
                local goalRate = (preview.hoverGoalSpeed or 0.12) * 60.0
                local lookRate = (preview.hoverPreviewSpeed or 0.022) * 60.0
                local camRate = (preview.hoverCameraDriftSpeed or 0.018) * 60.0

                W2F.Spawner.smoothedLookGoal = W2F.Frame.SmoothVec3(
                    W2F.Spawner.smoothedLookGoal or rawLookTarget, rawLookTarget, goalRate, dt)
                W2F.Spawner.smoothedCamGoal = W2F.Frame.SmoothVec3(
                    W2F.Spawner.smoothedCamGoal or rawCamTarget, rawCamTarget, goalRate, dt)
                W2F.Spawner.previewCurrentLookAt = W2F.Frame.SmoothVec3(
                    W2F.Spawner.previewCurrentLookAt or W2F.Spawner.smoothedLookGoal,
                    W2F.Spawner.smoothedLookGoal, lookRate, dt)
                W2F.Spawner.previewCurrentCam = W2F.Frame.SmoothVec3(
                    W2F.Spawner.previewCurrentCam or W2F.Spawner.smoothedCamGoal,
                    W2F.Spawner.smoothedCamGoal, camRate, dt)

                local camPos = W2F.Spawner.previewCurrentCam
                SetCamCoord(W2F.Camera.handle, camPos.x, camPos.y, camPos.z)
                local rot = W2F.Camera.GetLookAtRotation(camPos, W2F.Spawner.previewCurrentLookAt)
                W2F.Camera.SetRotation(W2F.Camera.handle, rot)
            end
            Wait(0)
        end
        W2F.Spawner.previewLoopActive = false
        W2F.Spawner.previewHoveredId = nil
        W2F.Spawner.previewCurrentLookAt = nil
        W2F.Spawner.previewCurrentCam = nil
        W2F.Spawner.previewCamAnchor = nil
        W2F.Spawner.smoothedLookGoal = nil
        W2F.Spawner.smoothedCamGoal = nil
    end)
end

W2F.Spawner.StartPreviewLoop = startSpawnPreviewLoop

-----------------------------------------------------------------------------
--- Unified sky picker entry. Replaces the duplicate code in BeginSkySequence
--- and OpenFirstSpawnPicker.
---
---   opts.skipRise   skip the sky-rise cinematic (post-creation direct-spawn)
---   opts.reason     for telemetry / debug
-----------------------------------------------------------------------------
local function pushSkyPickerNui()
    --- Cache apartment metadata so the preview loop can hover the camera
    --- over apartment cards too.
    local spawns = buildSpawnCardsForNui()
    W2F.Spawner.lastApartmentOptions = nil
    local apts = {}
    for i = 1, #spawns do
        if spawns[i].kind == 'apartment' then
            apts[#apts + 1] = spawns[i]
        end
    end
    if #apts > 0 then W2F.Spawner.lastApartmentOptions = apts end

    if W2F.Nui and W2F.Nui.Send then
        W2F.Nui.Send('showSelection', W2F.Nui.BuildSelectionPayload())
    else
        W2F.SendNui('showSelection', { maxSlots = Config.GetMaxCharacterSlots() })
    end
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSelectionHints', {})
    W2F.SendNui('showSkySpawnOptions', {
        spawns = spawns,
        isNewCharacter = W2F.State.isNewCharacter == true,
    })
end

local function createSkyCamDirect()
    local focal = Config.GetSceneFocal()
    local ped = PlayerPedId()
    if ped and ped ~= 0 then
        SetEntityVisible(ped, false, false)
        SetEntityAlpha(ped, 0, false)
        FreezeEntityPosition(ped, true)
        SetEntityCollision(ped, false, false)
        SetEntityInvincible(ped, true)
        SetEntityCoords(ped, focal.x, focal.y, focal.z - 50.0, false, false, false, false)
    end

    if W2F.Camera and W2F.Camera.Destroy then
        W2F.Camera.Destroy()
    end

    local sky = Config.SpawnCinematic
    local skyHeight = sky.skyHeight or 280.0
    local skyPos = vector3(focal.x, focal.y, focal.z + skyHeight)
    local cam = CreateCamWithParams(
        'DEFAULT_SCRIPTED_CAMERA',
        skyPos.x, skyPos.y, skyPos.z,
        0.0, 0.0, 0.0,
        sky.fovSky or 38.0,
        false, 2
    )
    W2F.Camera.handle = cam
    W2F.Camera.active = true
    W2F.Camera.mode = 'sky'
    if W2F.Camera.modeState then
        W2F.Camera.modeState.overview = false
        W2F.Camera.modeState.focused = false
        W2F.Camera.modeState.sky = true
        W2F.Camera.modeState.flyToSpawn = false
        W2F.Camera.modeState.descent = false
        W2F.Camera.modeState.cinematic = false
    end
    if W2F.Camera.SetRotation and W2F.Camera.GetLookAtRotation then
        W2F.Camera.SetRotation(cam, W2F.Camera.GetLookAtRotation(skyPos, focal))
    else
        PointCamAtCoord(cam, focal.x, focal.y, focal.z)
    end
    SetCamActive(cam, true)
    if SetCamMotionBlurStrength then
        SetCamMotionBlurStrength(cam, 0.0)
    end
    RenderScriptCams(true, false, 0, true, true)
    W2F.State.cameraActive = true

    SetTimecycleModifier('MP_corona_heist_blend')
    SetTimecycleModifierStrength(0.22)
    DisplayRadar(false)
end

local function enterSkyPicker(opts)
    opts = opts or {}
    local skipRise = opts.skipRise == true
    local reason = opts.reason or 'enter_sky'

    if not W2F.State.selectedCharacter then return false end

    --- Allow either selection -> sky_picker or sky_picker -> sky_picker (noop).
    local ok, err = W2F.Session.Transition('sky_picker', reason)
    if not ok then
        dbg('enterSkyPicker rejected: %s', tostring(err))
        return false
    end

    W2F.State.detailsVisible = false
    W2F.SetHovered(nil, nil)
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSelectionHints', {})

    if skipRise then
        createSkyCamDirect()
        pushSkyPickerNui()
        W2F.SetSelectionFocus(true, true)
        if W2F.Interaction and W2F.Interaction.StartLoop then
            W2F.Interaction.StartLoop()
        end
        W2F.PlayW2FSound(Config.Audio.locationSelect)
        startSpawnPreviewLoop()
        DoScreenFadeIn(700)
        return true
    end

    --- Sky-rise cinematic path. Pre-flight UI cleanup.
    W2F.SendNui('beginSpawnSequence', {})
    W2F.PlayW2FSound(Config.Audio.spawnPress)

    DoScreenFadeOut(400)
    while not IsScreenFadedOut() do Wait(0) end
    DoScreenFadeIn(500)

    local camPos = W2F.Camera.GetCurrentCoord()
    local focal = Config.GetSceneFocal()
    local sky = Config.SpawnCinematic
    local skyPos = vector3(focal.x, focal.y, focal.z + sky.skyHeight)
    local startFov = (W2F.Camera.handle and DoesCamExist(W2F.Camera.handle))
        and GetCamFov(W2F.Camera.handle)
        or ((Config.Camera and Config.Camera.overview and Config.Camera.overview.fov) or Config.CameraControl.fov)

    W2F.PlayW2FSound(Config.Audio.skyLaunch)

    --- Watchdog: if the rise cinematic stalls we recover instead of stranding
    --- the player on a frozen sky cam.
    W2F.Watchdog.Arm('sky_rise', CINEMATIC_TIMEOUTS.skyRise, function()
        W2F.Spawner.RecoverFromFailedSpawn('Cinematic stalled (sky_rise).')
    end)

    W2F.Camera.RunCinematic({
        {
            mode = 'sky',
            from = camPos,
            to = skyPos,
            lookAt = focal,
            duration = sky.skyRiseDurationMs,
            fovFrom = startFov,
            fovTo = sky.fovSky,
            easing = W2F.EaseInOutQuint,
            swayStrength = 0.05,
            swaySpeed = 0.35,
            fovBob = 0.0,
        },
    }, function()
        W2F.Watchdog.Disarm('sky_rise')
        --- Phase is already sky_picker; just kick the UI + preview loop.
        W2F.Camera.mode = 'sky'
        pushSkyPickerNui()
        startSpawnPreviewLoop()
        W2F.PlayW2FSound(Config.Audio.locationSelect)
    end)

    return true
end

function W2F.Spawner.EnterSkyPicker(opts)
    return enterSkyPicker(opts)
end

function W2F.Spawner.BeginSkySequence()
    return enterSkyPicker({ skipRise = false, reason = 'begin_sky' })
end

function W2F.Spawner.OpenFirstSpawnPicker()
    return enterSkyPicker({ skipRise = true, reason = 'first_spawn' })
end

-----------------------------------------------------------------------------
--- Recovery (always-faded-in, controls-enabled, NUI message surfaced).
-----------------------------------------------------------------------------
function W2F.Spawner.RecoverFromFailedSpawn(message)
    --- Re-entrancy guard: concurrent failure paths (an inline error AND the
    --- watchdog last-resort net, or two failing awaits) must not double-run
    --- recovery and stack duplicate toasts / NUI envelopes / EnterSelection.
    --- The pcall guarantees the flag clears even if a listener throws — without
    --- it, one exception would permanently disable all future recovery.
    if W2F.Spawner.recovering then return end
    W2F.Spawner.recovering = true
    local ok, err = pcall(function()
        --- Always disarm spawn watchdogs first so they can't fire during
        --- recovery and cascade us back into another recovering transition.
        if W2F.Watchdog then
            W2F.Watchdog.Disarm('sky_rise')
            W2F.Watchdog.Disarm('fly')
            W2F.Watchdog.Disarm('finalize')
        end

        --- Surface the failure: notification + NUI envelope (Phase 5 makes the
        --- NUI actually display data.message).
        local msg = message or 'Spawn failed. Try again.'
        lib.notify({ title = 'Spawn', description = msg, type = 'error' })
        if W2F.Nui and W2F.Nui.SendResult then
            W2F.Nui.SendResult('spawnFailed', false, msg)
        else
            W2F.SendNui('spawnFailed', { message = msg })
        end

        if W2F.Telemetry and W2F.Telemetry.RecordFailure then
            W2F.Telemetry.RecordFailure('spawn', msg)
        end

        releaseStreamHandle()
        resetSpawnLoadFlags()
        W2F.Spawner.previewLoopActive = false

        --- Force-fade in so the player isn't stuck on a black screen.
        if IsScreenFadedOut() then DoScreenFadeIn(500) end

        W2F.Camera.cinematic = nil
        W2F.Camera.mode = 'overview'
        if W2F.Camera and W2F.Camera.modeState then
            W2F.Camera.modeState.overview = true
            W2F.Camera.modeState.focused = false
            W2F.Camera.modeState.sky = false
            W2F.Camera.modeState.flyToSpawn = false
            W2F.Camera.modeState.descent = false
            W2F.Camera.modeState.cinematic = false
        end

        --- The apartment-claim and regular fly paths log the player in BEFORE
        --- the spawn completes (CharacterLoad.Load WITHOUT skipLogin). If we
        --- recover after that, the player is still logged in server-side, so the
        --- next spawn's loadCharacter would trip qbx_core's "login twice"
        --- DropPlayer kick. Log back out first. Awaited (not fire-and-forget)
        --- because qbx Logout does an internal save + Wait(200) before clearing
        --- the player. logoutForRecovery NEVER deletes the character.
        pcall(function() lib.callback.await('w2f-multicharacter:server:logoutForRecovery', false) end)

        --- Transition to recovering, then back into selection.
        W2F.Session.Recover('spawn_fail')

        if W2F.Cleanup and W2F.Cleanup.EnableAllControls then
            W2F.Cleanup.EnableAllControls()
        end

        --- Returning to selection from any spawn phase: rebuild the lineup.
        Wait(250)
        if W2F.EnterSelection then
            W2F.EnterSelection('recover')
        end
    end)
    W2F.Spawner.recovering = false
    if not ok then
        print(('[w2f-multicharacter] RecoverFromFailedSpawn error: %s'):format(tostring(err)))
    end
end

-----------------------------------------------------------------------------
--- FlyToSpawn: regular spawn-point cinematic + load.
-----------------------------------------------------------------------------
function W2F.Spawner.FlyToSpawn(spawnId)
    if not W2F.Session.Is('sky_picker') or not W2F.State.selectedCharacter then
        return
    end

    local character = W2F.State.selectedCharacter
    local coords = W2F.Spawner.ResolveSpawnCoords(spawnId, character)
    if not coords then
        W2F.Spawner.RecoverFromFailedSpawn('Could not resolve spawn location.')
        return
    end

    local ok = W2F.Session.Transition('flying', 'fly_to_' .. tostring(spawnId))
    if not ok then return end

    W2F.State.selectedSpawn = spawnId
    W2F.Spawner.previewLoopActive = false
    W2F.SendNui('hideSkySpawnOptions', {})
    W2F.SetSelectionFocus(false, false)

    resetSpawnLoadFlags()
    ClearTimecycleModifier()
    pcall(function() ClearExtraTimecycleModifier() end)

    --- Streaming via RAII handle (auto-released on recover / idle / stop).
    releaseStreamHandle()
    W2F.Spawner.streamHandle = W2F.Streaming.Acquire(
        vector3(coords.x, coords.y, coords.z - 1.0),
        {
            radius = (Config.SpawnCinematic and Config.SpawnCinematic.streamingRadius) or 120.0,
            keepThread = true,
            followCamera = true,
            parkPed = true,
        }
    )

    W2F.PlayW2FSound(Config.Audio.locationSelect)

    --- Cinematic watchdog: if the entire fly cinematic stalls past 18s, recover.
    W2F.Watchdog.Arm('fly', CINEMATIC_TIMEOUTS.fly, function()
        W2F.Spawner.RecoverFromFailedSpawn('Cinematic stalled (fly).')
    end)

    CreateThread(function()
        local loadOk, loadErr = loadCharacterDuringFly(character, coords)
        if not loadOk then
            W2F.Watchdog.Disarm('fly')
            W2F.Spawner.RecoverFromFailedSpawn(
                ('Failed to load character (%s).'):format(tostring(loadErr)))
            return
        end

        local sky = Config.SpawnCinematic
        local startCamPos = W2F.Camera.GetCurrentCoord()
        local pedCoords = GetEntityCoords(PlayerPedId())
        local aboveTarget = vector3(pedCoords.x, pedCoords.y, pedCoords.z + sky.flyHeight)
        local travelDistance = #(aboveTarget - startCamPos)

        local teleported = false
        if travelDistance > (sky.travelFadeDistance or 2600.0) then
            DoScreenFadeOut(sky.travelFadeOutMs or 320)
            while not IsScreenFadedOut() do Wait(0) end
            SetCamCoord(W2F.Camera.handle, aboveTarget.x, aboveTarget.y, aboveTarget.z)
            local focus = vector3(pedCoords.x, pedCoords.y, pedCoords.z + (sky.pedFocusHeight or 0.95))
            W2F.Camera.SetRotation(W2F.Camera.handle, W2F.Camera.GetLookAtRotation(aboveTarget, focus))
            SetCamFov(W2F.Camera.handle, sky.fovSky)
            DoScreenFadeIn(sky.travelFadeInMs or 420)
            startCamPos = aboveTarget
            teleported = true
        end

        local ped = PlayerPedId()
        if not ped or not DoesEntityExist(ped) then
            W2F.Watchdog.Disarm('fly')
            W2F.Spawner.RecoverFromFailedSpawn('Character ped missing.')
            return
        end

        local sequence = buildPedFlyCinematic(startCamPos, ped, coords, sky, teleported)
        W2F.Camera.RunCinematic(sequence, function()
            W2F.Watchdog.Disarm('fly')
            W2F.Spawner.FinalizeSpawn(character, coords)
        end)
    end)
end

-----------------------------------------------------------------------------
--- Apartment claim — login FIRST, then qbx_properties (so it tags the right
--- citizenid). Fixed ordering vs. the legacy code which assumed canClaim
--- ran pre-login.
-----------------------------------------------------------------------------
function W2F.Spawner.ClaimApartment(apartmentIndex)
    if not W2F.Session.Is('sky_picker') or not W2F.State.selectedCharacter then return end
    if not (W2F.IsQbxPropertiesAvailable and W2F.IsQbxPropertiesAvailable()) then
        dbg('ClaimApartment skipped; qbx_properties unavailable')
        W2F.Spawner.FlyToSpawn((Config.Spawn and Config.Spawn.lastLocationFallback) or 'public')
        return
    end

    local character = W2F.State.selectedCharacter
    if not character or not character.citizenid then return end

    local ok = W2F.Session.Transition('finalizing', 'apartment_' .. tostring(apartmentIndex))
    if not ok then return end

    W2F.Spawner.previewLoopActive = false
    W2F.SendNui('hideSkySpawnOptions', {})

    --- Resolve apartment coords from the cached options.
    local entry = W2F.Spawner.lastApartmentOptions
    local coords
    if entry then
        for i = 1, #entry do
            if entry[i].aptIndex == apartmentIndex and entry[i].coords then
                coords = vec4(entry[i].coords.x, entry[i].coords.y, entry[i].coords.z, 0.0)
                break
            end
        end
    end
    --- Never fall back to a hard-coded placeholder (the old `vec4(0,0,72)`
    --- silently teleported the player into the Maze Bank void). If the cached
    --- apartment options don't contain this index's coords, recover cleanly.
    if not coords then
        W2F.Spawner.RecoverFromFailedSpawn('Could not resolve apartment location.')
        return
    end

    DoScreenFadeOut(550)
    while not IsScreenFadedOut() do Wait(0) end

    --- Watchdog: claim + load shouldn't take more than 15s end-to-end.
    W2F.Watchdog.Arm('finalize', CINEMATIC_TIMEOUTS.finalize, function()
        W2F.Spawner.RecoverFromFailedSpawn('Apartment claim stalled.')
    end)

    --- 1. Exit the tutorial bucket so the character is loaded into the
    --- shared world (qbx_properties needs to see the actual interior).
    W2F.Cleanup.EndTutorialSession()
    W2F.Cleanup.ResetRoutingBucket()
    Wait(150)

    --- 2. Login the character via CharacterLoad.Load (explicit failures).
    local loaded, reason = W2F.CharacterLoad.Load({
        citizenid = character.citizenid,
        coords = coords,
    })
    if not loaded then
        W2F.Watchdog.Disarm('finalize')
        W2F.Spawner.RecoverFromFailedSpawn(('Character load failed (%s).'):format(tostring(reason)))
        return
    end

    --- 3. NOW that the player is logged in as the new character, verify the
    --- claim can proceed. The previous order checked first then logged in,
    --- which guaranteed the gate's "you must be logged in" branch fired.
    local canClaim, claimErr = lib.callback.await('w2f-multicharacter:server:canClaimApartment',
        false, apartmentIndex, character.citizenid)
    if not canClaim then
        W2F.Watchdog.Disarm('finalize')
        W2F.Spawner.RecoverFromFailedSpawn(type(claimErr) == 'string' and claimErr or 'Apartment unavailable.')
        return
    end

    --- 4. Hand off to qbx_properties. The network event uses `source` so the
    --- client triggers this from their own session.
    TriggerServerEvent('qbx_properties:server:apartmentSelect', apartmentIndex)

    --- 5. Confirm qbx_properties persisted the claim before treating it as
    --- successful. This character has already been loaded, so recover rather
    --- than trying another normal spawn and risking a second login.
    local confirmOk, claimed = pcall(function()
        return lib.callback.await('w2f-multicharacter:server:confirmApartmentClaimed', false,
            apartmentIndex, character.citizenid)
    end)
    dbg('confirmApartmentClaimed %s', confirmOk and claimed and 'success' or 'failure')
    if not confirmOk or not claimed then
        W2F.Watchdog.Disarm('finalize')
        W2F.Spawner.RecoverFromFailedSpawn('Starter apartment claim could not be confirmed.')
        return
    end

    --- 6. Fire framework "player loaded" events so HUD / radial / banking
    --- init. Without this they never appear because qbx skipped them.
    W2F.Cleanup.FirePlayerLoadedEvents()

    --- 7. Final cleanup of selection UI / camera.
    W2F.State.isNewCharacter = false
    W2F.State.pendingNewCitizenid = nil
    if W2F.Cleanup and W2F.Cleanup.Full then W2F.Cleanup.Full(true) end
    W2F.Cleanup.RestoreFrameworkUi(6)

    W2F.Watchdog.Disarm('finalize')
    releaseStreamHandle()

    W2F.Session.Transition('playing', 'apartment_claimed')
    DoScreenFadeIn(1200)
end

-----------------------------------------------------------------------------
--- FinalizeSpawn (post-fly: re-validate phase, then complete).
-----------------------------------------------------------------------------
W2F.Spawner.spawnCompleteAt = 0
W2F.Spawner.SPAWN_REOPEN_BLOCK_MS = 8000

function W2F.Spawner.IsSpawnCooldownActive()
    local completedAt = W2F.Spawner.spawnCompleteAt or 0
    --- `spawnCompleteAt` starts at 0. Treating 0 as "just finished spawning"
    --- falsely blocks auto-open for the first ~8s of client uptime (GetGameTimer
    --- is also near 0 on fresh connect), which strands the player on the
    --- gameplay camera until the loading watchdog fires.
    if completedAt <= 0 then
        return false
    end
    return (GetGameTimer() - completedAt) < (W2F.Spawner.SPAWN_REOPEN_BLOCK_MS or 0)
end

function W2F.Spawner.FinalizeSpawn(character, coords)
    if not character or not character.citizenid or not coords then
        W2F.Spawner.RecoverFromFailedSpawn('Invalid spawn data.')
        return
    end

    --- Phase check: must be in `flying` (came from FlyToSpawn cinematic).
    --- Anything else means we got here through a stale callback path - recover.
    if not W2F.Session.Is('flying') then
        W2F.Spawner.RecoverFromFailedSpawn('Spawn finalize from wrong phase: ' .. tostring(W2F.Session.phase))
        return
    end

    local ok = W2F.Session.Transition('finalizing', 'finalize_spawn')
    if not ok then
        W2F.Spawner.RecoverFromFailedSpawn('Spawn finalize transition rejected.')
        return
    end

    W2F.Spawner.spawnCompleteAt = GetGameTimer()

    local sky = Config.SpawnCinematic
    local alreadyLoaded = W2F.Spawner.spawnLoadComplete == true

    if W2F.Cleanup and W2F.Cleanup.ReleaseSelectionWorldState then
        W2F.Cleanup.ReleaseSelectionWorldState('finalize_spawn')
    end
    releaseStreamHandle()

    if not alreadyLoaded then
        DoScreenFadeOut(sky.fadeOutMs)
        while not IsScreenFadedOut() do Wait(0) end
    end

    if W2F.Hud and W2F.Hud.Hide then W2F.Hud.Hide() end
    W2F.Characters.ClearPreviewPeds()
    W2F.Camera.Destroy()
    W2F.SetSelectionFocus(false, false)
    W2F.SendNui('resetSelectionUI', {})

    W2F.Cleanup.EnableAllControls()

    if not alreadyLoaded then
        W2F.Cleanup.ResetRoutingBucket()
        Wait(150)

        local loaded, reason = W2F.CharacterLoad.Load({
            citizenid = character.citizenid,
            coords = coords,
        })
        if not loaded then
            W2F.Spawner.spawnCompleteAt = 0
            resetSpawnLoadFlags()
            W2F.Spawner.RecoverFromFailedSpawn(('Failed to load character (%s).'):format(tostring(reason)))
            return
        end
    end

    W2F.ResetState()
    resetSpawnLoadFlags()
    W2F.Spawner.spawnCompleteAt = GetGameTimer()
    DisplayRadar(true)
    W2F.Cleanup.EnableAllControls()
    W2F.Cleanup.ResetPlayerPed()

    W2F.Cleanup.FirePlayerLoadedEvents()
    W2F.Cleanup.RestoreFrameworkUi(6)

    W2F.Session.Transition('playing', 'finalize_complete')

    Wait(alreadyLoaded and 120 or 250)
    DoScreenFadeIn(sky.fadeInMs)
    W2F.PlayW2FSound(Config.Audio.finalSpawn)
end

-----------------------------------------------------------------------------
--- NUI callbacks.
-----------------------------------------------------------------------------
RegisterNUICallback('pressSpawn', function(_, cb)
    if W2F.State.isCreatePanelOpen or W2F.State.isCreatingCharacter then
        cb({ ok = false, error = 'panel_open' })
        return
    end
    if W2F.State.selectedCharacter and W2F.Session.Is('selection') then
        W2F.Spawner.BeginSkySequence()
    end
    cb({ ok = true })
end)

RegisterNUICallback('chooseSkySpawn', function(data, cb)
    local spawnId = data and data.id
    if spawnId and spawnId ~= '' and W2F.Session.Is('sky_picker') then
        local index = type(spawnId) == 'string' and spawnId:match('^apt:(%d+)$')
        if index then
            if W2F.IsQbxPropertiesAvailable and W2F.IsQbxPropertiesAvailable() then
                W2F.Spawner.ClaimApartment(tonumber(index))
            else
                dbg('apartment spawn selected while qbx_properties unavailable; falling back to public spawn')
                W2F.Spawner.FlyToSpawn((Config.Spawn and Config.Spawn.lastLocationFallback) or 'public')
            end
        else
            W2F.Spawner.FlyToSpawn(spawnId)
        end
        cb({ ok = true })
    else
        cb({ ok = false, error = 'invalid_state' })
    end
end)

RegisterNUICallback('previewSkySpawn', function(data, cb)
    if not Config.SpawnPreview.enabled or not W2F.Session.Is('sky_picker') then
        cb({ ok = false })
        return
    end

    local id = data and data.id or nil
    W2F.Spawner.previewHoveredId = (id and id ~= '') and id or nil
    if W2F.Spawner.previewHoveredId then
        W2F.PlayW2FSound(Config.Audio.hover)
    end
    cb({ ok = true })
end)

--- NUI lets the player Escape out of the sky picker. New-character flows
--- (isNewCharacter = true) intentionally have no way back because we'd
--- orphan the freshly created character; everyone else gets a clean
--- "back to selection" path.
RegisterNUICallback('cancelSkySpawn', function(_, cb)
    if not W2F.Session.Is('sky_picker') then
        cb({ ok = false, error = 'invalid_state' })
        return
    end
    if W2F.State.isNewCharacter then
        cb({ ok = false, error = 'new_character_locked' })
        return
    end
    --- Tear down the sky picker UI + recover to selection.
    --- The skipRise sky picker reuses the OVERVIEW camera (RunCinematic never
    --- clears Camera.active), so we MUST destroy the camera here. Otherwise
    --- EnterSelection's `Is('selection') and Camera.active` guard treats the
    --- lineup as already up and no-ops, stranding the player on the sky cam with
    --- no characters. Destroy first (clears Camera.active), then let
    --- EnterSelection own the transition (sky_picker -> selection is allowed).
    W2F.SendNui('hideSkySpawnOptions', {})
    W2F.Spawner.previewLoopActive = false
    W2F.Spawner.previewHoveredId = nil
    if W2F.Camera and W2F.Camera.cinematic then W2F.Camera.cinematic = nil end
    if W2F.Camera and W2F.Camera.Destroy then W2F.Camera.Destroy() end
    if IsScreenFadedOut() then DoScreenFadeIn(400) end
    --- If EnterSelection can't proceed (spawn cooldown, deps not ready, re-entry
    --- in-flight) the camera is already gone, so fall back to the full recovery
    --- path rather than leaving the player on a black screen.
    if not (W2F.EnterSelection and W2F.EnterSelection('sky_cancel')) then
        W2F.Spawner.RecoverFromFailedSpawn('Returned to selection.')
    end
    cb({ ok = true })
end)

-----------------------------------------------------------------------------
--- Session listeners: cleanup hooks for transitions we don't own.
-----------------------------------------------------------------------------
W2F.Session.OnExit('sky_picker', function()
    W2F.Spawner.previewLoopActive = false
end)

W2F.Session.OnEnter('idle', function()
    releaseStreamHandle()
    resetSpawnLoadFlags()
    W2F.Spawner.previewLoopActive = false
    W2F.Spawner.lastApartmentOptions = nil
end)
