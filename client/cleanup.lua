W2F.Cleanup = {}

local function currentPed()
    --- Always re-query in case qbx_core spawned a new ped during loadCharacter.
    return PlayerPedId()
end

function W2F.Cleanup.ResetPlayerPed()
    local ped = currentPed()
    if not ped or ped == 0 then return end
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)
    SetPedConfigFlag(ped, 32, false)
    ClearPedTasksImmediately(ped)
end

function W2F.Cleanup.EnableAllControls()
    EnableAllControlActions(0)
    EnableAllControlActions(1)
    EnableAllControlActions(2)
    --- Restore the chat resource (we hard-suppressed it while in selection).
    if GetResourceState('chat') == 'started' then
        pcall(TriggerEvent, 'chat:setActive', true)
    end
end

--- Fires the framework "player loaded" events that dozens of resources
--- (qbx_hud, qbx_radialmenu, qbx_properties, illenium-appearance, etc.)
--- listen for. qbx_core's built-in character.lua fires these itself but
--- that entire file is skipped when useExternalCharacters = true, so we
--- must replicate the sequence here after loading a character.
function W2F.Cleanup.FirePlayerLoadedEvents()
    --- Server-side: sets Player(source).state.isLoggedIn = true and
    --- triggers every server handler listening for this event.
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')

    --- Client-side: sets QBX.IsLoggedIn, ends the tutorial session,
    --- and triggers every client handler (hud init, radial menu, etc.).
    TriggerEvent('QBCore:Client:OnPlayerLoaded')

    --- Auxiliary events the default QBX spawn flow fires.
    TriggerServerEvent('qb-houses:server:SetInsideMeta', 0, false)
    TriggerServerEvent('qb-apartments:server:SetInsideMeta', 0, 0, false)
    TriggerEvent('qb-weathersync:client:EnableSync')
end

--- Restores framework UI/HUD state after multichar hands control back.
--- Some HUD resources miss their first refresh right after model swaps, so
--- callers can request retries with staggered delays.
function W2F.Cleanup.RestoreFrameworkUi(retries)
    local attempts = retries or 1
    if attempts < 1 then attempts = 1 end

    CreateThread(function()
        local delays = { 0, 250, 700, 1300, 2500, 4000 }
        for i = 1, attempts do
            local d = delays[i] or 1300
            if d > 0 then Wait(d) end

            DisplayRadar(true)
            SetNuiFocus(false, false)
            if SetNuiFocusKeepInput then
                SetNuiFocusKeepInput(false)
            end

            if GetResourceState('qbx_hud') == 'started' then
                pcall(TriggerEvent, 'qbx_hud:client:showHud')
                pcall(TriggerEvent, 'hud:client:LoadMap')
            end
        end
    end)
end

function W2F.Cleanup.ResetRoutingBucket()
    --- Always return to bucket 0 for MLO streaming, even when isolated buckets
    --- are disabled — other resources may have moved the player elsewhere.
    TriggerServerEvent('w2f-multicharacter:server:resetSelectionBucket')
end

function W2F.Cleanup.EndTutorialSession()
    if NetworkIsInTutorialSession() then
        NetworkEndTutorialSession()
    end
end

--- Drops EVERY multichar world override that breaks gameplay interiors if left
--- active after spawn: lineup focus/scene sphere, timecycle, artificial lights,
--- tutorial session, interior pin, performance governor threads.
---
--- MUST run when leaving `selection` and again on `playing` / `idle` as
--- belt-and-braces. Stopping the resource fixed Pillbox because this is
--- exactly what onResourceStop / Cleanup.Full already did.
function W2F.Cleanup.ReleaseSelectionWorldState(reason)
    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'ReleaseSelectionWorldState (%s)', tostring(reason or 'unspecified'))
    end

    if W2F.Performance and W2F.Performance.Deactivate then
        W2F.Performance.Deactivate()
    end

    if W2F.Render and W2F.Render.LeaveSelection then
        W2F.Render.LeaveSelection()
    end

    if W2F.Characters and W2F.Characters.ReleaseSceneStream then
        W2F.Characters.ReleaseSceneStream()
    end

    if W2F.Spawner and W2F.Spawner.ReleaseStream then
        W2F.Spawner.ReleaseStream()
    end

    if W2F.Streaming and W2F.Streaming.ReleaseAll then
        W2F.Streaming.ReleaseAll()
    end

    if W2F.Interior and W2F.Interior.Release then
        W2F.Interior.Release()
    end

    ClearTimecycleModifier()
    pcall(function() ClearExtraTimecycleModifier() end)

    if SetArtificialLightsState then
        SetArtificialLightsState(false)
    end

    pcall(NewLoadSceneStop)
    if ClearFocus then pcall(ClearFocus) end

    W2F.Cleanup.EndTutorialSession()
end

function W2F.Cleanup.Visuals()
    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'Cleanup.Visuals: releasing scene stream + preview peds + camera')
    end
    W2F.Cleanup.ReleaseSelectionWorldState('visuals')
    if W2F.Hud and W2F.Hud.Hide then
        W2F.Hud.Hide()
    end
    W2F.Characters.ClearPreviewPeds()
    W2F.Camera.Destroy()
    if AnimpostfxIsRunning('DeathFailOut') then
        StopScreenEffect('DeathFailOut')
    end
    if IsScreenFadedOut() then
        DoScreenFadeIn(250)
    end
    W2F.SetSelectionFocus(false, false)
    W2F.SendNui('resetSelectionUI', {})
end

function W2F.Cleanup.Full(exitSelection)
    W2F.Cleanup.Visuals()
    W2F.Cleanup.ResetRoutingBucket()
    DisplayRadar(true)
    W2F.Cleanup.EnableAllControls()
    W2F.Cleanup.RestoreFrameworkUi(2)

    if exitSelection ~= false then
        W2F.ResetState()
        W2F.Selection.active = false
        --- Restore Config.Scene if the ExteriorScene override was applied for
        --- this session. Safe to call unconditionally — no-op when not applied.
        if W2F.Diag and W2F.Diag.RestoreSceneOverride then
            W2F.Diag.RestoreSceneOverride()
        end
    end

    W2F.Cleanup.ResetPlayerPed()

    --- Belt-and-braces (ReleaseSelectionWorldState already did this).
    pcall(NewLoadSceneStop)
    if ClearFocus then pcall(ClearFocus) end
    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'Cleanup.Full done (NewLoadSceneStop + ClearFocus belt-and-braces)')
    end
end

if W2F.Session and W2F.Session.OnExit then
    W2F.Session.OnExit('selection', function()
        W2F.Cleanup.ReleaseSelectionWorldState('session_exit_selection')
    end)
end

if W2F.Session and W2F.Session.OnEnter then
    W2F.Session.OnEnter('playing', function()
        W2F.Cleanup.ReleaseSelectionWorldState('session_enter_playing')
    end)
    W2F.Session.OnEnter('idle', function()
        W2F.Cleanup.ReleaseSelectionWorldState('session_enter_idle')
    end)
    W2F.Session.OnEnter('recovering', function()
        W2F.Cleanup.ReleaseSelectionWorldState('session_enter_recovering')
    end)
end
