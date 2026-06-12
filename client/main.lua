--- W2F multichar main entry: EnterSelection / CloseSelection / debug
--- commands / session-start watchdog.
---
--- All phase transitions go through W2F.Session.Transition. The legacy
--- carry-over list (`carriedIsNew` / `carriedNewCid` / `carriedVisualSlot`
--- / `carriedAutoSpawn`) is gone — those values live in W2F.Session.context
--- and survive transitions automatically.

local function preparePlayer()
    local ped = PlayerPedId()
    local focal = Config.GetSceneFocal()
    local anchor = (W2F.Render and W2F.Render.GetPedAnchorCoords)
        and W2F.Render.GetPedAnchorCoords(focal)
    local pedZ = anchor and anchor.z or focal.z

    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityInvincible(ped, true)
    SetEntityAlpha(ped, 0, false)
    SetPedConfigFlag(ped, 32, true)
    SetEntityCoords(ped, focal.x, focal.y, pedZ, false, false, false, false)
    FreezeEntityPosition(ped, true)
end

local function applySelectionRoutingBucket()
    local skipBuckets = W2F.Diag and W2F.Diag.Flag and W2F.Diag.Flag('DisableBuckets')
    if skipBuckets then
        if W2F.Diag and W2F.Diag.Log then
            W2F.Diag.Log('Streaming', 'EnterSelection: routing bucket request SKIPPED (DisableBuckets)')
        end
        return
    end
    if not Config.General.UseRoutingBuckets then return end
    --- MLO interiors only stream reliably in bucket 0 — skip isolated buckets.
    if W2F.Interior and W2F.Interior.IsSceneInterior and W2F.Interior.IsSceneInterior() then
        if W2F.Diag and W2F.Diag.Log then
            W2F.Diag.Log('Streaming', 'EnterSelection: routing bucket SKIPPED (interior scene)')
        end
        return
    end
    print('[w2f-multicharacter][enter] setSelectionBucket')
    TriggerServerEvent('w2f-multicharacter:server:setSelectionBucket')
end

--- Belt-and-braces streaming reset before every selection boot. Safemode works
--- partly because it Cleanup + re-enters; cold session start must do the same.
local function resetStreamingForSelection()
    if W2F.Characters and W2F.Characters.ReleaseSceneStream then
        W2F.Characters.ReleaseSceneStream()
    end
    if W2F.Streaming and W2F.Streaming.ReleaseAll then
        W2F.Streaming.ReleaseAll()
    end
    if W2F.Interior and W2F.Interior.Release then
        W2F.Interior.Release()
    end
    pcall(NewLoadSceneStop)
    if ClearFocus then pcall(ClearFocus) end
end

local function ensureWorldRoutingBucket()
    if W2F.Cleanup and W2F.Cleanup.ResetRoutingBucket then
        W2F.Cleanup.ResetRoutingBucket()
    end
end

--- Earliest-possible "the player has a valid hidden position" primer. Called
--- the moment NetworkIsSessionStarted is true, BEFORE the heavy
--- WaitForReady / EnterSelection path runs. This is what kills the FiveM
--- corner loading spinner: the engine considers the player "placed" as soon
--- as a valid SetEntityCoords + non-loading state is observed. If
--- EnterSelection later succeeds it will reposition the player into the
--- multichar interior; if it fails, the player at least won't be stuck on
--- an "infinity loading" screen because the engine has a valid ped.
local function primeSpawn()
    --- Wait briefly for the local ped to exist. Right after session start the
    --- engine sometimes returns 0 from PlayerPedId() for ~50-150ms.
    local deadline = GetGameTimer() + 3000
    while (PlayerPedId() == 0) and GetGameTimer() < deadline do
        Wait(50)
    end

    local ped = PlayerPedId()
    if not ped or ped == 0 then
        print('[w2f-multicharacter][boot] primeSpawn: PlayerPedId still 0 after 3s, skipping')
        return
    end

    local focal = (Config and Config.GetSceneFocal and Config.GetSceneFocal())
        or { x = 0.0, y = 0.0, z = 100.0 }
    local sceneInterior = Config.Scene and Config.Scene.interior or {}
    local keepInside = sceneInterior.keepPlayerInside ~= false
    local primeZ = keepInside and (focal.z or 100.0) or ((focal.z or 100.0) - 50.0)

    local ok, err = pcall(function()
        --- Resurrect FIRST so the engine considers the player "placed" and
        --- the corner spinner stops, then apply the hidden-state modifiers.
        if NetworkResurrectLocalPlayer then
            NetworkResurrectLocalPlayer(focal.x, focal.y, primeZ, 0.0, true, false)
        end
        SetEntityCoords(ped, focal.x, focal.y, primeZ, false, false, false, false)
        SetEntityVisible(ped, false, false)
        SetEntityCollision(ped, false, false)
        SetEntityInvincible(ped, true)
        SetEntityAlpha(ped, 0, false)
        SetPedConfigFlag(ped, 32, true)
        FreezeEntityPosition(ped, true)
    end)
    if not ok then
        print(('[w2f-multicharacter][boot] primeSpawn error: %s'):format(tostring(err)))
    else
        print(('[w2f-multicharacter][boot] primeSpawn ok ped=%s coords=(%.1f, %.1f, %.1f)'):format(
            tostring(ped), focal.x, focal.y, primeZ))
    end
end

local function beginTutorialSession()
    NetworkStartSoloTutorialSession()
    local timeout = GetGameTimer() + 5000
    while not NetworkIsInTutorialSession() and GetGameTimer() < timeout do
        Wait(10)
    end
end

local function fetchCharactersWithTimeout()
    --- Wrap FetchCharacters in a watchdog so a slow MySQL never wedges
    --- selection open. Returns the list or empty on timeout.
    local startup = Config.Startup or {}
    local timeoutMs = startup.fetchCharactersTimeoutMs or 10000
    local done, result = false, nil
    CreateThread(function()
        local ok, list = pcall(W2F.Qbox.FetchCharacters)
        if ok then result = list end
        done = true
    end)
    local deadline = GetGameTimer() + timeoutMs
    while not done and GetGameTimer() < deadline do Wait(20) end
    if not done then
        if W2F.Telemetry and W2F.Telemetry.Record then
            W2F.Telemetry.Record('fetch_characters_timeout', { timeoutMs = timeoutMs })
        end
        lib.notify({
            title = 'Characters',
            description = 'The server is responding slowly. Retrying...',
            type = 'warning',
        })
    end
    return result or {}
end

--- Re-entry guard. Without this, two concurrent EnterSelection calls (e.g.
--- a session-start retry that overlaps with a manual `w2f-multicharacter:client:openSelection`
--- event) can each spin up their own streaming handle, intro thread, and
--- preview-ped lineup — leaking handles and stacking collision requests.
--- Any caller that observes `inFlight` should wait, not kick off another run.
W2F.EnterSelectionInFlight = false

---@return boolean success
function W2F.EnterSelection(reason)
    print(('[w2f-multicharacter][enter] EnterSelection reason=%s phase=%s'):format(
        tostring(reason), tostring(W2F.Session and W2F.Session.phase)))
    --- Already in selection: just no-op (or refresh visuals if camera is dead).
    if W2F.Session.Is('selection') and W2F.Camera and W2F.Camera.active then
        print('[w2f-multicharacter][enter] already in selection with live camera; no-op')
        return true
    end

    if W2F.EnterSelectionInFlight then
        print('[w2f-multicharacter][enter] re-entry blocked: another EnterSelection is in-flight')
        if W2F.Diag and W2F.Diag.Log then
            W2F.Diag.Log('Streaming', 'EnterSelection re-entry blocked (reason=%s)', tostring(reason))
        end
        return false
    end
    W2F.EnterSelectionInFlight = true

    if W2F.Spawner and W2F.Spawner.IsSpawnCooldownActive and W2F.Spawner.IsSpawnCooldownActive() then
        print('[w2f-multicharacter][enter] blocked by spawn cooldown')
        W2F.Debug('EnterSelection blocked by spawn cooldown')
        -- Must clear the in-flight guard on every early exit, otherwise the
        -- next EnterSelection is permanently "re-entry blocked" (stuck on a
        -- black screen until resource restart).
        W2F.EnterSelectionInFlight = false
        return false
    end

    if W2F.Bootstrap and not W2F.Bootstrap.WaitForReady() then
        print('[w2f-multicharacter][enter] aborted: dependencies not ready')
        W2F.Debug('EnterSelection aborted: dependencies not ready')
        W2F.EnterSelectionInFlight = false
        return false
    end

    --- Stale state? Clean up first.
    if W2F.Session.IsActive() and not W2F.Session.Is('bootstrapping') then
        W2F.Cleanup.Full(true)
    end

    --- Move to selection. From any active phase the transition table either
    --- allows it directly or routes through `recovering`.
    local ok = W2F.Session.Transition('selection', reason or 'enter_selection')
    if not ok then
        W2F.Session.Recover('enter_selection_invalid')
        W2F.Session.Transition('selection', reason or 'enter_selection_after_recover')
    end

    local enterOk, err = pcall(function()
        --- The carry-over flags now live in `W2F.Session.context`; the
        --- legacy `W2F.State.isNewCharacter` / `pendingNewCitizenid` are kept
        --- as mirrors so the existing lineup code (which reads these) still
        --- works. They're cleared when the player transitions to `idle`.
        W2F.ResetState()

        --- ExteriorScene swap (no-op when flag is off). Restored by
        --- `W2F.Cleanup.Full(true)`. MUST run BEFORE PrepareScene so the
        --- focal/camera math reads exterior coords.
        if W2F.Diag and W2F.Diag.ApplySceneOverride then
            W2F.Diag.ApplySceneOverride()
        end

        ensureWorldRoutingBucket()
        Wait(100)
        resetStreamingForSelection()

        print('[w2f-multicharacter][enter] preparePlayer')
        preparePlayer()
        pcall(function() exports.spawnmanager:setAutoSpawn(false) end)
        print('[w2f-multicharacter][enter] beginTutorialSession')
        beginTutorialSession()

        ShutdownLoadingScreen()
        ShutdownLoadingScreenNui()

        print('[w2f-multicharacter][enter] DoScreenFadeOut')
        DoScreenFadeOut(500)
        while not IsScreenFadedOut() do Wait(0) end

        if W2F.Performance and W2F.Performance.Activate then
            W2F.Performance.Activate()
        end

        if W2F.Render and W2F.Render.EnterSelection then
            W2F.Render.EnterSelection()
        end

        print('[w2f-multicharacter][enter] PrepareScene (streaming collision)')
        W2F.Characters.PrepareScene()

        --- Load the MLO in bucket 0 before any optional isolated bucket.
        applySelectionRoutingBucket()

        print('[w2f-multicharacter][enter] fetchCharactersWithTimeout')
        local characters = fetchCharactersWithTimeout()
        if W2F.Render and W2F.Render.EnforcePedAnchor then
            W2F.Render.EnforcePedAnchor()
        end
        print(('[w2f-multicharacter][enter] BuildLineup (characters=%d)'):format(
            type(characters) == 'table' and #characters or -1))
        W2F.Characters.BuildLineup(characters)

        if W2F.Characters.FinalizeScenePresentation then
            W2F.Characters.FinalizeScenePresentation()
        end

        --- Session boot uses an instant snap to the fixed overview pose so the
        --- player never sees the gameplay camera or the intro fly-in starting
        --- 12 units above target (which reads as "wrong camera location").
        local instantOverview = reason == 'session'
            or reason == 'watchdog_retry'
            or (Config.Scene and Config.Scene.skipIntroOnBoot == true)
        print(('[w2f-multicharacter][enter] Camera.PlayIntro instant=%s'):format(tostring(instantOverview)))
        W2F.Camera.PlayIntro({ instant = instantOverview })
        if not W2F.Camera.active then
            error('camera failed to initialize')
        end
        print('[w2f-multicharacter][enter] Camera ready; starting interaction loop')

        W2F.Interaction.StartLoop()

        W2F.SetSelectionFocus(true, true)
        local payload = (W2F.Nui and W2F.Nui.BuildSelectionPayload)
            and W2F.Nui.BuildSelectionPayload()
            or {
                maxSlots = Config.GetMaxCharacterSlots(),
                showControlHints = Config.UI.showControlHints,
            }
        W2F.SendNui('showSelection', payload)
        W2F.SendNui('hideCharacterDetails', {})
        W2F.SendNui('hideSkySpawnOptions', {})

        if W2F.Bootstrap then
            local nuiTimeout = (Config.Startup and Config.Startup.nuiReadyTimeoutMs) or 10000
            if not W2F.Bootstrap.nuiReady then
                print(('[w2f-multicharacter][enter] WaitForNui (timeout=%dms)'):format(nuiTimeout))
                W2F.Bootstrap.WaitForNui(nuiTimeout)
            end
            print(('[w2f-multicharacter][enter] NUI ready=%s'):format(tostring(W2F.Bootstrap.nuiReady)))
            if W2F.Bootstrap.nuiReady then
                W2F.SendNui('showSelection', payload)
            end
        end

        --- Post-creation auto-select / auto-spawn handoff. The values are
        --- still in W2F.State after the ResetState above because the
        --- session adapter and Creator.StartPipeline write them BEFORE the
        --- transition to `selection` (they go into Session.context too).
        local carriedIsNew = W2F.State.isNewCharacter
        local carriedNewCid = W2F.State.pendingNewCitizenid
        local carriedAutoSpawn = W2F.State.autoSpawnAfterCreation

        if carriedIsNew and carriedNewCid then
            CreateThread(function()
                Wait(550)
                for _ = 1, 6 do
                    if W2F.Characters.RefreshPedAppearance(carriedNewCid) then break end
                    Wait(350)
                end
                if W2F.Characters.AutoSelectByCitizenid then
                    local selected = W2F.Characters.AutoSelectByCitizenid(carriedNewCid)
                    if selected and carriedAutoSpawn then
                        W2F.State.autoSpawnAfterCreation = false
                        Wait(1200)
                        if W2F.Session.Is('selection') and W2F.State.selectedCharacter then
                            W2F.Spawner.BeginSkySequence()
                        end
                    end
                end
                W2F.State.pendingVisualSlot = nil
            end)
        end

        if W2F.Camera and W2F.Render and W2F.Render.FinalizeBeforeFadeIn then
            W2F.Render.FinalizeBeforeFadeIn()
        elseif W2F.Camera and W2F.Camera.SnapOverview then
            W2F.Camera.SnapOverview()
        end

        print('[w2f-multicharacter][enter] DoScreenFadeIn(800) — selection live')
        DoScreenFadeIn(800)
        if W2F.Diag and W2F.Diag.MaybeAutoPrintSelection then
            W2F.Diag.MaybeAutoPrintSelection()
        end
        W2F.Debug('Selection session started')
    end)

    if not enterOk or not W2F.Camera.active or not W2F.Session.Is('selection') then
        print(('[w2f-multicharacter][enter] FAILED enterOk=%s cameraActive=%s phase=%s err=%s'):format(
            tostring(enterOk), tostring(W2F.Camera and W2F.Camera.active),
            tostring(W2F.Session and W2F.Session.phase), tostring(err)))
        W2F.Debug('EnterSelection failed: %s', tostring(err))
        W2F.Session.Recover('enter_selection_throw')
        W2F.Cleanup.Full(true)
        if IsScreenFadedOut() then DoScreenFadeIn(500) end
        W2F.Session.Transition('idle', 'enter_selection_failed')
        W2F.EnterSelectionInFlight = false
        return false
    end

    print('[w2f-multicharacter][enter] EnterSelection complete')
    W2F.EnterSelectionInFlight = false
    return true
end

function W2F.CloseSelection()
    --- Tear down everything and snap to idle.
    W2F.Cleanup.Full(true)
    W2F.Session.Transition('idle', 'close_selection')
end

-----------------------------------------------------------------------------
--- Event handlers (manual reopen paths).
--- The legacy `Bootstrap.OpenSelectionWithRetry` used to gate everything on
--- `ShouldAutoOpen`; now manual events go through `CanOpen` so they ignore
--- `Config.AutoOpen` (which is intended only for session start).
-----------------------------------------------------------------------------
RegisterNetEvent('w2f-multicharacter:client:openSelection', function()
    if W2F.Bootstrap then
        W2F.Bootstrap.OpenSelectionWithRetry('event', 'manual')
    else
        W2F.EnterSelection('event')
    end
end)

local lastLogoutHandledAt = 0

local function onFrameworkLogout()
    --- Debounce: qbx_core fires both its own playerLoggedOut and (via its
    --- qb compatibility bridge) QBCore:Client:OnPlayerUnload for one logout;
    --- both are registered below, so collapse anything inside 2s into one run.
    local now = GetGameTimer()
    if now - lastLogoutHandledAt < 2000 then return end
    lastLogoutHandledAt = now

    if W2F.Creator and W2F.Creator.suppressAutoOpen then return end
    if W2F.Spawner and W2F.Spawner.IsSpawnCooldownActive and W2F.Spawner.IsSpawnCooldownActive() then
        return
    end

    --- Snap session to idle so the post-spawn `playing` phase is dropped.
    if W2F.Session.IsActive() then
        W2F.Session.Transition('idle', 'logout')
    end

    Wait(500)
    if W2F.Bootstrap then
        W2F.Bootstrap.OpenSelectionWithRetry('logout', 'manual')
    else
        W2F.EnterSelection('logout')
    end
end

RegisterNetEvent('qbx_core:client:playerLoggedOut', onFrameworkLogout)
--- qb-core fires this on the client when QBCore.Player.Logout unloads the
--- character — reopen the lineup, same as QBX.
RegisterNetEvent('QBCore:Client:OnPlayerUnload', onFrameworkLogout)
--- es_extended fires this on the client after esx:playerLogout unloads the
--- character (character switch / recovery) — reopen the lineup, same as QBX.
RegisterNetEvent('esx:onPlayerLogout', onFrameworkLogout)

local function openSelectionOnSessionStart()
    if W2F.Bootstrap and W2F.Bootstrap.OpenSelectionWithRetry then
        W2F.Bootstrap.OpenSelectionWithRetry('session', 'session')
        return
    end

    --- Fallback if bootstrap.lua failed to load for any reason.
    for _ = 1, 3 do
        if W2F.EnterSelection('session') then return end
        Wait(1500)
    end
end

-----------------------------------------------------------------------------
--- Loading-screen watchdog. If `dependencyTimeoutMs` after session-start
--- we still don't have a live camera, force-dismiss the loading screen
--- and try EnterSelection one more time as a last resort.
-----------------------------------------------------------------------------
local function startLoadingScreenWatchdog()
    local cfg = Config.Startup or {}
    local timeoutMs = cfg.dependencyTimeoutMs or 45000

    CreateThread(function()
        local started = GetGameTimer()
        while (GetGameTimer() - started) < timeoutMs do
            Wait(1000)
            if W2F.Camera and W2F.Camera.active then return end
        end

        print(('[w2f-multicharacter][boot] loading-screen watchdog TRIPPED after %dms (phase=%s) — force dismiss + retry'):format(
            GetGameTimer() - started, tostring(W2F.Session and W2F.Session.phase)))
        ShutdownLoadingScreen()
        ShutdownLoadingScreenNui()
        if IsScreenFadedOut() then DoScreenFadeIn(500) end

        --- Last-resort retry. If even this fails we surface an error toast.
        --- `pcall` returns (didNotThrow, returnValue); we must check both so a
        --- clean `return false` from EnterSelection still surfaces the toast.
        local ok, opened = pcall(W2F.EnterSelection, 'watchdog_retry')
        if not ok or not opened then
            lib.notify({
                title = 'Character Select',
                description = 'Could not load the lineup. Try /w2fmc_reloadscene.',
                type = 'error',
            })
        end
    end)
end

CreateThread(function()
    print('[w2f-multicharacter][boot] client thread starting; waiting for session...')
    local sessionStart = GetGameTimer()
    while not NetworkIsSessionStarted() do
        Wait(200)
    end
    print(('[w2f-multicharacter][boot] session live after %dms; dismissing loading screen'):format(GetGameTimer() - sessionStart))

    --- Disable spawnmanager BEFORE shutting down the loading screen so it
    --- can't auto-spawn the player into a default position while we set up
    --- the multichar interior.
    pcall(function() exports.spawnmanager:setAutoSpawn(false) end)

    --- Always dismiss the loading screen the moment the session is live, no
    --- matter what config branch we take.
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()

    --- Prime the player to a valid hidden position immediately. This kills
    --- the FiveM corner loading spinner even if WaitForReady / EnterSelection
    --- takes its sweet time (or fails). Without this, the spinner persists
    --- forever because the engine treats the player as "still loading".
    primeSpawn()

    startLoadingScreenWatchdog()

    if not Config.UseExternalCharacters then
        print('[w2f-multicharacter] Enable qbx_core characters.useExternalCharacters and Config.UseExternalCharacters')
        return
    end

    if not Config.AutoOpen then
        print('[w2f-multicharacter][boot] AutoOpen disabled — selection will not open automatically')
        return
    end

    Wait(800)

    print('[w2f-multicharacter][boot] calling openSelectionOnSessionStart')
    local ok, err = pcall(openSelectionOnSessionStart)
    if not ok then
        print(('[w2f-multicharacter][boot] session start error: %s'):format(tostring(err)))
        if IsScreenFadedOut() then DoScreenFadeIn(500) end
    else
        print('[w2f-multicharacter][boot] openSelectionOnSessionStart returned (async retry loop is running)')
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    W2F.CloseSelection()
end)

-----------------------------------------------------------------------------
--- Debug commands.
-----------------------------------------------------------------------------
local function debugPrintState()
    local s = W2F.State
    local routingBucket = 'n/a'
    if GetPlayerRoutingBucket then
        local ok, bucket = pcall(GetPlayerRoutingBucket, PlayerId())
        if ok and bucket then routingBucket = tostring(bucket) end
    end

    local previewCount = 0
    for _ in pairs(s.previewPeds or {}) do previewCount = previewCount + 1 end

    local selectedCid = s.selectedCharacter and s.selectedCharacter.citizenid or 'nil'
    local hoveredExists = s.hoveredPed and DoesEntityExist(s.hoveredPed) or false
    local selectedExists = s.selectedPed and DoesEntityExist(s.selectedPed) or false

    print(('[w2f-multicharacter][debug] phase=%s | selectedCid=%s | hoveredPed=%s | selectedPed=%s | cameraMode=%s | isDraggingCamera=%s | nuiFocused=%s | routingBucket=%s | previewPeds=%s'):format(
        tostring(W2F.Session and W2F.Session.phase),
        tostring(selectedCid),
        tostring(hoveredExists),
        tostring(selectedExists),
        tostring(W2F.Camera and W2F.Camera.mode or 'nil'),
        tostring(s.isDraggingCamera),
        tostring(s.nuiFocused),
        routingBucket,
        tostring(previewCount)
    ))
end

local function debugReloadScene()
    if not W2F.Session.Is('selection') then
        W2F.EnterSelection('reload_scene')
        return
    end

    W2F.Cleanup.Visuals()
    W2F.Characters.PrepareScene()
    local characters = W2F.Qbox.FetchCharacters()
    W2F.Characters.BuildLineup(characters)
    if W2F.Characters.FinalizeScenePresentation then
        W2F.Characters.FinalizeScenePresentation()
    end
    W2F.SetSelectionFocus(true, true)
    local payload = (W2F.Nui and W2F.Nui.BuildSelectionPayload)
        and W2F.Nui.BuildSelectionPayload()
        or { maxSlots = Config.GetMaxCharacterSlots(), showControlHints = Config.UI.showControlHints }
    W2F.SendNui('showSelection', payload)
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSkySpawnOptions', {})
    W2F.Camera.PlayIntro()
    W2F.Interaction.StartLoop()
end

-----------------------------------------------------------------------------
--- Diagnostic commands (ALWAYS registered — no Config.Debug gate).
---
--- Behaviour with no flags set is identical to the un-instrumented build;
--- these commands are the only knob a developer needs to investigate the
--- `floor-item-batman` style streaming/MLO crash.
-----------------------------------------------------------------------------
RegisterCommand('w2fmc_diag', function()
    if W2F.Diag and W2F.Diag.PrintSnapshot then
        W2F.Diag.PrintSnapshot()
    else
        print('[w2f-multicharacter][stream-debug] diagnostics module not loaded')
    end
end, false)

pcall(function()
    TriggerEvent('chat:addSuggestion', '/w2fmc_diag',
        'Print w2f-multicharacter character selector health snapshot (F8)')
end)

RegisterCommand('w2fmc_safemode', function()
    if not W2F.Diag then
        print('[w2f-multicharacter][stream-debug] diagnostics module not loaded')
        return
    end
    --- Reduced-pressure profile: every flag that's known to ease streaming
    --- load + isolate failure causes is enabled. ExteriorScene is left off
    --- here — `/w2fmc_exteriortest` is the dedicated entry point for that.
    W2F.Diag.SetRuntime({
        SceneSafeMode = true,
        DisableBuckets = true,
        DisablePreviewEmotes = true,
        Streaming = true,
        CollisionLogs = true,
        ExteriorScene = nil,
    })
    W2F.Diag.Print('SAFE MODE ENABLED — reloading selection')
    W2F.Cleanup.Full(false)
    Wait(150)
    W2F.EnterSelection('safemode')
end, false)

RegisterCommand('w2fmc_exteriortest', function()
    if not W2F.Diag then
        print('[w2f-multicharacter][stream-debug] diagnostics module not loaded')
        return
    end
    W2F.Diag.SetRuntime({
        SceneSafeMode = true,
        DisableBuckets = true,
        DisablePreviewEmotes = true,
        ExteriorScene = true,
        Streaming = true,
        CollisionLogs = true,
    })
    W2F.Diag.Print('EXTERIOR TEST ENABLED (LSIA south apron) — reloading selection')
    W2F.Cleanup.Full(false)
    Wait(150)
    W2F.EnterSelection('exteriortest')
end, false)

--- Bisect streaming fixes one variable at a time (reloads selection).
--- Usage: /w2fmc_bisect buckets | sphere | player | default
RegisterCommand('w2fmc_bisect', function(_, args)
    if not W2F.Diag then
        print('[w2f-multicharacter][stream-debug] diagnostics module not loaded')
        return
    end
    local mode = (args and args[1] or 'help'):lower()
    W2F.Diag.ClearRuntime()

    if mode == 'buckets' then
        W2F.Diag.SetRuntime({ DisableBuckets = true, Streaming = true })
        W2F.Diag.Print('BISECT buckets: DisableBuckets=true — reloading selection')
    elseif mode == 'sphere' then
        W2F.Diag.SetRuntime({ ForceRelaxScene = true, Streaming = true })
        W2F.Diag.Print('BISECT sphere: ForceRelaxScene=true (drops load-scene sphere) — reloading')
    elseif mode == 'player' then
        W2F.Diag.SetRuntime({ KeepPlayerUnderground = true, Streaming = true })
        W2F.Diag.Print('BISECT player: KeepPlayerUnderground=true (z-50 hide) — reloading')
    elseif mode == 'default' then
        W2F.Diag.Print('BISECT default: no runtime overrides — reloading selection')
    else
        W2F.Diag.Print('Usage: /w2fmc_bisect buckets|sphere|player|default')
        return
    end

    W2F.Cleanup.Full(false)
    Wait(150)
    W2F.EnterSelection('bisect_' .. mode)
end, false)

RegisterCommand('w2fmc_streamreset', function()
    if not W2F.Diag then
        print('[w2f-multicharacter][stream-debug] diagnostics module not loaded')
        return
    end
    W2F.Diag.Print('STREAM RESET — releasing focus/scene/preview peds, then rebuilding')
    --- Hard release: every focus/scene handle, every preview ped + held anim
    --- dict, NewLoadSceneStop, ClearFocus. This is the same sequence
    --- ReleaseAll runs internally; calling it directly avoids leaving the
    --- session in a half-cleaned state if `Cleanup.Visuals` is interrupted.
    if W2F.Characters and W2F.Characters.ReleaseSceneStream then
        W2F.Characters.ReleaseSceneStream()
    end
    if W2F.Interior and W2F.Interior.Release then
        W2F.Interior.Release()
    end
    if W2F.Streaming and W2F.Streaming.ReleaseAll then
        W2F.Streaming.ReleaseAll()
    end
    if W2F.Characters and W2F.Characters.ClearPreviewPeds then
        W2F.Characters.ClearPreviewPeds()
    end
    pcall(NewLoadSceneStop)
    if ClearFocus then pcall(ClearFocus) end

    --- Only rebuild if we're actually inside selection — outside of it the
    --- spawner / cinematic may own the screen and we'd stomp their handles.
    if W2F.Session and W2F.Session.Is('selection') then
        Wait(100)
        W2F.Characters.PrepareScene()
        local characters = W2F.Qbox.FetchCharacters()
        W2F.Characters.BuildLineup(characters)
        if W2F.Characters.FinalizeScenePresentation then
            W2F.Characters.FinalizeScenePresentation()
        end
        if W2F.Camera and W2F.Camera.SnapOverview then
            W2F.Camera.SnapOverview()
        end
        W2F.Diag.Print('stream reset: scene rebuilt in current selection')
    else
        W2F.Diag.Print('stream reset: not in selection (phase=%s) — handles released only',
            tostring(W2F.Session and W2F.Session.phase))
    end
end, false)

if Config.Debug then
    RegisterCommand('w2fmc_debug', debugPrintState, false)
    --- `w2fmc_state` is identical to `w2fmc_debug`; kept temporarily so
    --- existing muscle memory works. Will be removed in Phase 7 cleanup.
    RegisterCommand('w2fmc_state', debugPrintState, false)

    RegisterCommand('w2fmc_resetcam', function()
        if not W2F.Session.Is('selection') then return end
        W2F.Camera.ReturnToOverview()
    end, false)

    RegisterCommand('w2fmc_cleanup', function() W2F.Cleanup.Full(false) end, false)

    RegisterCommand('w2fmc_testspawn', function(_, args)
        if not W2F.State.selectedCharacter then
            print('[w2f-multicharacter][debug] select a character first')
            return
        end
        if W2F.Session.IsSpawning() then return end
        local spawnId = (args and args[1]) or 'public'
        if not W2F.Session.Is('sky_picker') then
            W2F.Spawner.BeginSkySequence()
            CreateThread(function()
                local timeout = GetGameTimer() + 8000
                while not W2F.Session.Is('sky_picker') and GetGameTimer() < timeout do
                    Wait(50)
                end
                if W2F.Session.Is('sky_picker') then
                    W2F.Spawner.FlyToSpawn(spawnId)
                end
            end)
            return
        end
        W2F.Spawner.FlyToSpawn(spawnId)
    end, false)

    RegisterCommand('w2fmc_reloadscene', debugReloadScene, false)
end

exports('IsSelectionActive', function()
    --- Public export consumed by w2f-pausemenu / others. Returns true while
    --- the multichar flow owns the screen so external resources can hide
    --- their UI / disable controls.
    if W2F.Session and W2F.Session.OwnsScreen then
        return W2F.Session.OwnsScreen()
    end
    local s = W2F.State
    return s.isInSelection or s.isCreatingCharacter or s.isCreatePanelOpen
        or s.isSkySpawnMode or s.isSpawning or s.nuiFocused
end)

exports('GetSessionPhase', function()
    return W2F.Session and W2F.Session.phase or 'idle'
end)
