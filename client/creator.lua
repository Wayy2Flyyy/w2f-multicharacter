--- W2F.Creator - character creation form + appearance handoff.
---
--- Rebuilt to drive transitions through `W2F.Session.Transition` and to use
--- `W2F.Streaming.WithCoords` for the appearance editor location.
---
--- Two pipelines, picked by `Config.CharacterCreation.directToApartment`:
---   * directToApartment = true (default): form -> server createCharacter
---     -> log in as new char -> apartment claim -> clothing editor opens
---     INSIDE the apartment (via qbx_properties' built-in CreateFirstCharacter
---     hook). If qbx_properties is unavailable or the claim cannot be confirmed,
---     creation falls back to the legacy appearance editor before the spawn picker.
---   * directToApartment = false (legacy): form -> server createCharacter
---     -> appearance editor at LSIA -> spawn picker -> apartment/location.
---
--- Phase contract (direct-to-apartment):
---   selection -> creating       (OpenRegistration -> form submit -> StartPipeline)
---   creating -> finalizing      (server createCharacter ok, apartment claim ready)
---   finalizing -> playing       (apartmentSelect + framework events done)
---   any -> recovering           (model swap timeout / create failure)
---
--- Phase contract (legacy LSIA):
---   selection -> creating       (OpenRegistration -> form submit -> StartPipeline)
---   creating -> appearance      (server createCharacter ok)
---   appearance -> sky_picker    (illenium save + GoDirectlyToSpawn)
---   appearance -> selection     (cancel or directToSpawnPicker disabled)

W2F.Creator = {
    active = false,                     --- legacy mirror; kept by session adapter
    suppressAutoOpen = false,           --- still used by bootstrap / logout handlers
    pendingVisualSlot = nil,
}

local SELECT_RETRY_DELAYS_MS = { 250, 500, 1000, 2000 }

local function dbg(...)
    if W2F.Debug then W2F.Debug(...) end
end

--- True only when the starter-apartment pipeline can actually run: the flow
--- is enabled in config AND the configured apartment resource is started.
--- On any server without that resource this returns false and creation uses
--- the standalone appearance-editor -> spawn-picker flow instead.
local function apartmentSystemAvailable()
    local cc = Config.CharacterCreation or {}
    if cc.directToApartment == false then return false end
    local res = cc.apartmentResource
    if res == nil then res = 'qbx_properties' end
    if not res or res == '' then return false end
    return GetResourceState(res) == 'started'
end

local function getCreationConfig()
    local cc = Config.CharacterCreation or {}
    return {
        nationalities = cc.nationalities or { 'American' },
        defaultNationality = cc.defaultNationality or 'American',
        birthdateMin = cc.birthdateMin or '1940-01-01',
        birthdateMax = cc.birthdateMax or '2006-12-31',
        nameMinLength = cc.nameMinLength or 2,
        nameMaxLength = cc.nameMaxLength or 24,
    }
end

function W2F.Creator.HideMulticharUiForAppearance(reason)
    dbg('HideMulticharUiForAppearance reason=%s', tostring(reason or 'unspecified'))

    W2F.SendNui('closeCreateCharacter', {})
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSkySpawnOptions', {})
    W2F.SendNui('hideSelectionHints', {})
    W2F.SendNui('resetSelectionUI', {})
    W2F.SendNui('setVisible', { visible = false })
    W2F.SendNui('hide', {})

    W2F.SetSelectionFocus(false, false)
    SetNuiFocus(false, false)
    if SetNuiFocusKeepInput then SetNuiFocusKeepInput(false) end
    dbg('NUI focus cleared reason=%s', tostring(reason or 'unspecified'))
end

local function saveAppearanceThenFinish(appearance, cc, gender, coords, heading)
    W2F.Creator.HideMulticharUiForAppearance('appearance_save_start')
    dbg('appearance callback returned')

    local savedOk, saveErr = lib.callback.await(
        'w2f-multicharacter:server:saveNewCharacterAppearance',
        false,
        appearance
    )
    dbg('saveNewCharacterAppearance %s reason=%s', savedOk and 'success' or 'failure', tostring(saveErr))

    if not savedOk then
        lib.notify({
            title = 'Character Appearance',
            description = type(saveErr) == 'string' and saveErr or 'Could not save your appearance. Please try again.',
            type = 'error',
        })
        W2F.Creator.HideMulticharUiForAppearance('appearance_save_failed')
        --- Keep the logged-in character and reopen the editor when possible.
        if W2F.Session.Is('appearance') and coords then
            dbg('reopening appearance editor after save failure')
            W2F.Creator.OpenAppearance(gender or 0, coords, heading or 0.0)
        end
        return false
    end

    W2F.Creator.HideMulticharUiForAppearance('appearance_saved')

    --- Leave the appearance phase so the input-lock loop stops before spawn handoff.
    if W2F.Session.Is('appearance') then
        W2F.Session.Transition('selection', 'appearance_saved')
        dbg('session phase after save=%s', tostring(W2F.Session.phase))
    end
    if W2F.Cleanup and W2F.Cleanup.EnableAllControls then
        W2F.Cleanup.EnableAllControls()
    end

    local ok = lib.callback.await('w2f-multicharacter:server:finishCreation', false)
    dbg('finishCreation %s', ok and 'success' or 'failure')
    if not ok then
        W2F.Creator.HideMulticharUiForAppearance('finish_creation_failed')
        W2F.Creator.ReturnToSelection(true)
        return false
    end

    W2F.Creator.HideMulticharUiForAppearance('finish_creation')
    if cc.directToSpawnPicker ~= false then
        W2F.Creator.HideMulticharUiForAppearance('before_spawn_picker')
        W2F.Creator.GoDirectlyToSpawn()
    else
        W2F.Creator.ReturnToSelection(true)
    end
    return true
end

function W2F.Creator.OpenRegistration(visualSlot)
    if not Config.CharacterCreation or Config.CharacterCreation.enabled == false then
        return
    end
    --- Only allow opening the form from the selection phase.
    if not W2F.Session.Is('selection') then
        return
    end

    --- Move to `creating`. The state machine adapter will set
    --- W2F.State.isCreatePanelOpen / isCreatingCharacter for legacy code.
    local ok = W2F.Session.Transition('creating', 'open_form')
    if not ok then return end

    W2F.Creator.pendingVisualSlot = visualSlot
    W2F.State.pendingVisualSlot = visualSlot
    W2F.Characters.ClearSelection()
    W2F.SendNui('openCreateCharacter', {
        slot = visualSlot,
        config = getCreationConfig(),
    })
    W2F.SetSelectionFocus(true, false)
    if not W2F.Interaction.loopRunning then
        W2F.Interaction.StartLoop()
    end
end

function W2F.Creator.CloseRegistration()
    --- Closing the registration form (but not via submit) returns to selection.
    if W2F.Session.Is('creating') then
        W2F.Session.Transition('selection', 'close_form')
    end
    W2F.SendNui('closeCreateCharacter', {})
    if W2F.Session.Is('selection') and not W2F.Creator.active then
        W2F.SetSelectionFocus(true, true)
    end
end

-----------------------------------------------------------------------------
--- preparePlayerForCustomization
---
--- Loads the freemode model, places the ped at `coords`, applies visibility
--- + collision flags. Returns (ok, ped, reason).
---
--- The old version waited up to 5s for the model swap and continued silently
--- on timeout. Now we return an explicit failure so the caller can recover.
-----------------------------------------------------------------------------
local function preparePlayerForCustomization(coords, heading, gender)
    local model = (gender == 1) and `mp_f_freemode_01` or `mp_m_freemode_01`
    if not lib.requestModel(model, 10000) then
        return false, nil, 'model_load_failed'
    end
    --- Is the ped ALREADY this freemode model? The save-failure reopen path
    --- (saveAppearanceThenFinish -> OpenAppearance) re-enters with the
    --- just-edited ped still loaded; used below to avoid wiping the edited
    --- appearance back to neutral defaults.
    local hadModel = GetEntityModel(PlayerPedId()) == model
    SetPlayerModel(PlayerId(), model)

    local timeout = GetGameTimer() + 5000
    while GetEntityModel(PlayerPedId()) ~= model and GetGameTimer() < timeout do
        Wait(0)
    end
    --- Release our request reference on BOTH the success and timeout paths; the
    --- ped holds its own reference post-swap so the model stays resident.
    SetModelAsNoLongerNeeded(model)
    if GetEntityModel(PlayerPedId()) ~= model then
        return false, nil, 'model_swap_timeout'
    end

    --- Ground-snap the placement Z. The configured appearance location stores a
    --- nominal Z that can sit a few metres above the real ground; with the ped
    --- unfrozen it would fall out of the camera frame the instant the appearance
    --- editor opens ("can't see the ped"). Probe down from just above the
    --- nominal Z (collision is already streamed in by the caller) and use the
    --- ground when we found one meaningfully below.
    local placeZ = coords.z
    local foundGround, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 2.0, false)
    if foundGround and (coords.z - groundZ) > 1.0 then
        placeZ = groundZ
    end

    local ped = PlayerPedId()
    SetEntityCoords(ped, coords.x, coords.y, placeZ, false, false, false, false)
    SetEntityHeading(ped, heading or 0.0)

    --- Re-query — qbx_core / clothing resources may have swapped the ped
    --- during the model load and we must apply visibility to the live one.
    ped = PlayerPedId()
    SetEntityCoords(ped, coords.x, coords.y, placeZ, false, false, false, false)
    SetEntityHeading(ped, heading or 0.0)
    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)
    SetEntityInvincible(ped, true)
    SetEntityCollision(ped, true, true)
    SetPedConfigFlag(ped, 32, false)
    FreezeEntityPosition(ped, false)
    ClearPedTasksImmediately(ped)

    --- Initialise the freemode ped's appearance so it RENDERS immediately. The
    --- raw SetPlayerModel above leaves head-blend + component variation
    --- uninitialised, and the engine won't draw a freemode ped until that data
    --- exists — so without this the character stays invisible until the player
    --- first touches the creation menu (e.g. changes mother/father, which fires
    --- the first SetPedHeadBlendData). Mirrors illenium-appearance's own
    --- setPlayerModel defaults.
    ---
    --- Only on a GENUINE model swap: on the save-failure reopen the ped is
    --- already the edited model, so re-applying neutral defaults would snap the
    --- just-edited face/body back to default before the editor reappears.
    if not hadModel then
        if model == `mp_f_freemode_01` then
            SetPedDefaultComponentVariation(ped)
            SetPedHeadBlendData(ped, 45, 21, 0, 20, 15, 0, 0.3, 0.1, 0.0, false)
        elseif model == `mp_m_freemode_01` then
            SetPedDefaultComponentVariation(ped)
            SetPedHeadBlendData(ped, 0, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, false)
        end
    end

    return true, ped
end

-----------------------------------------------------------------------------
--- OpenAppearance
---
--- Streams collision via `W2F.Streaming.WithCoords` so the editor never
--- runs on unloaded geometry, then hands off to illenium-appearance.
--- On illenium save/cancel we decide whether to GoDirectlyToSpawn or
--- ReturnToSelection.
-----------------------------------------------------------------------------
function W2F.Creator.OpenAppearance(gender, coords, heading)
    dbg('OpenAppearance called gender=%s', tostring(gender))
    W2F.Creator.HideMulticharUiForAppearance('before_appearance')
    local cc = Config.CharacterCreation or {}
    local radius = cc.appearanceStreamRadius or 75.0

    --- Acquire a streaming handle now; we release it once illenium finishes.
    --- Cant use WithCoords + a closure because illenium's callback runs async.
    local streamHandle = W2F.Streaming.Acquire(coords, {
        radius = radius,
        keepThread = true,
        followCamera = false,
        focus = true,
        scene = true,
    })

    --- Block until collision lands or we timeout (non-fatal).
    W2F.Streaming.WaitForCollision(coords, 4000)

    local prepOk, _ped, prepErr = preparePlayerForCustomization(coords, heading, gender)
    if not prepOk then
        if streamHandle then W2F.Streaming.Release(streamHandle) end
        lib.notify({
            title = 'Character Creation',
            description = ('Could not prepare the character editor (%s).'):format(tostring(prepErr)),
            type = 'error',
        })
        --- Roll back the partial server-side character then return to selection.
        W2F.Creator.HideMulticharUiForAppearance('appearance_prep_failed')
        pcall(function() lib.callback.await('w2f-multicharacter:server:cancelCreation', false) end)
        W2F.Creator.ReturnToSelection(false)
        return
    end

    --- Fade in BEFORE handing off to illenium-appearance because its
    --- startPlayerCustomization spins on `repeat Wait(0) until IsScreenFadedIn()`.
    DoScreenFadeIn(700)
    while not IsScreenFadedIn() do Wait(0) end
    --- Release focus so the appearance editor's own focus stays put.
    if ClearFocus then ClearFocus() end

    local function teardownStreaming()
        if streamHandle then
            W2F.Streaming.Release(streamHandle)
            streamHandle = nil
        end
    end

    --- Recover the appearance phase if illenium never fires its callback
    --- (silent error, or the resource is stopped/restarted). Without this the
    --- creator input-lock loop (`while Session.In('creating','appearance')`)
    --- pins the player with controls disabled and a half-created character.
    local function appearanceRecover(reason)
        if W2F.Watchdog then W2F.Watchdog.Disarm('appearance') end
        W2F.Creator._appearanceRecover = nil
        --- Tell illenium to hard-abort its editor (camera off + NUI hidden +
        --- stats restored) WITHOUT re-invoking its callback — we run our own
        --- recovery below. abortPlayerCustomization is a safe no-op / swallowed
        --- 'No such export' on builds that don't have it.
        pcall(function()
            if GetResourceState('illenium-appearance') == 'started' then
                exports['illenium-appearance']:abortPlayerCustomization()
            end
        end)
        SetNuiFocus(false, false)
        if SetNuiFocusKeepInput then SetNuiFocusKeepInput(false) end
        pcall(function() TriggerServerEvent('illenium-appearance:server:ResetRoutingBucket') end)
        teardownStreaming()
        W2F.Creator.HideMulticharUiForAppearance('appearance_recover_' .. tostring(reason))
        pcall(function() lib.callback.await('w2f-multicharacter:server:cancelCreation', false) end)
        W2F.Creator.ReturnToSelection(false)
    end

    --- Re-arming watchdog: while the player is legitimately editing illenium
    --- holds NUI focus, so we re-arm instead of recovering; only a loss of
    --- focus while still pinned in 'appearance' (i.e. illenium died) recovers.
    local function armAppearanceWatchdog()
        if not (W2F.Watchdog and W2F.Watchdog.Arm) then return end
        W2F.Watchdog.Arm('appearance', 120000, function()
            if not W2F.Session.Is('appearance') then return end
            if IsNuiFocused() then
                armAppearanceWatchdog()
                return
            end
            appearanceRecover('watchdog')
        end)
    end

    if cc.preferIllenium ~= false and GetResourceState('illenium-appearance') == 'started' then
        TriggerServerEvent('illenium-appearance:server:ChangeRoutingBucket')
        Wait(200)

        --- Must mirror illenium's GetDefaultConfig() shape COMPLETELY.
        --- startPlayerCustomization stores this config verbatim (no merge
        --- with defaults) and the web UI reads componentConfig.masks /
        --- propConfig.hats etc. unconditionally — omitting those tables
        --- crashes the NUI ("Cannot read properties of undefined") the
        --- moment the editor opens, killing the whole creation flow.
        local appearanceConfig = {
            ped = true,
            headBlend = true,
            faceFeatures = true,
            headOverlays = true,
            components = true,
            componentConfig = {
                masks = true,
                upperBody = true,
                lowerBody = true,
                bags = true,
                shoes = true,
                scarfAndChains = true,
                bodyArmor = true,
                shirts = true,
                decals = true,
                jackets = true,
            },
            props = true,
            propConfig = {
                hats = true,
                glasses = true,
                ear = true,
                watches = true,
                bracelets = true,
            },
            tattoos = false,
            enableExit = false,
            hasTracker = false,
            automaticFade = true,
        }

        --- Expose the recover hook so onClientResourceStop can fire it instantly
        --- if illenium is restarted (rather than waiting for the watchdog).
        W2F.Creator._appearanceRecover = appearanceRecover
        armAppearanceWatchdog()

        local function onIlleniumDone(appearance)
            --- FIRST: stop the watchdog + instant-recover hook so neither fires
            --- on the now-completed handoff.
            if W2F.Watchdog then W2F.Watchdog.Disarm('appearance') end
            W2F.Creator._appearanceRecover = nil
            TriggerServerEvent('illenium-appearance:server:ResetRoutingBucket')
            teardownStreaming()

            if appearance then
                saveAppearanceThenFinish(appearance, cc, gender, coords, heading)
            else
                dbg('appearance save failure (illenium customization cancelled)')
                W2F.Creator.HideMulticharUiForAppearance('appearance_cancelled')
                lib.callback.await('w2f-multicharacter:server:cancelCreation', false)
                W2F.Creator.ReturnToSelection(false)
            end
        end

        --- Guard the export: illenium-appearance could stop between the
        --- GetResourceState check above and this call, which would otherwise
        --- throw an uncaught "No such export" and strand the player mid-create.
        local started = pcall(function()
            exports['illenium-appearance']:startPlayerCustomization(onIlleniumDone, appearanceConfig)
        end)
        if not started then
            if W2F.Watchdog then W2F.Watchdog.Disarm('appearance') end
            W2F.Creator._appearanceRecover = nil
            pcall(function() TriggerServerEvent('illenium-appearance:server:ResetRoutingBucket') end)
            teardownStreaming()
            dbg('appearance save failure (illenium startPlayerCustomization export unavailable)')
            W2F.Creator.HideMulticharUiForAppearance('appearance_export_failed')
            lib.callback.await('w2f-multicharacter:server:cancelCreation', false)
            W2F.Creator.ReturnToSelection(false)
        end
        return
    end

    --- ESX fallback: esx_skin's saveable menu. esx_skin persists the skin to
    --- users.skin itself on submit, so we go through saveNewCharacterAppearance
    --- with a nil payload afterwards (the server's verify-only branch).
    if W2F.ESX and W2F.ESX.IsActive and W2F.ESX.IsActive()
        and GetResourceState('esx_skin') == 'started' then
        local finished, savedEsx = false, false
        TriggerEvent('esx_skin:openSaveableMenu', function()
            savedEsx = true
            finished = true
        end, function()
            finished = true
        end)

        CreateThread(function()
            local deadline = GetGameTimer() + 300000
            while not finished and GetGameTimer() < deadline do
                Wait(250)
            end
            teardownStreaming()

            if not savedEsx then
                dbg('appearance save failure (esx_skin menu cancelled or timed out)')
                W2F.Creator.HideMulticharUiForAppearance('esx_skin_appearance_cancelled')
                lib.callback.await('w2f-multicharacter:server:cancelCreation', false)
                W2F.Creator.ReturnToSelection(false)
                return
            end

            saveAppearanceThenFinish(nil, cc, gender, coords, heading)
        end)
        return
    end

    --- Fallback: qb-clothes flow. We wait on a save event so we don't poll
    --- for IsNuiFocused (the old fallback waited 5 minutes for the editor
    --- to close, which produced ghost sessions if the player Alt-F4'd).
    local saved = false
    local savedAppearance = nil
    local cancelled = false
    local function onSave(appearance)
        saved = true
        if type(appearance) == 'table' then savedAppearance = appearance end
    end
    AddEventHandler('qb-clothing:client:loadPlayerClothing', onSave)
    AddEventHandler('illenium-appearance:client:appearanceSaved', onSave)
    TriggerEvent('qb-clothes:client:CreateFirstCharacter')

    CreateThread(function()
        --- Watchdog: if neither save nor focus-loss is observed within 5
        --- minutes we treat it as cancelled and clean up.
        local deadline = GetGameTimer() + 300000
        local wasFocused = false
        while GetGameTimer() < deadline do
            if saved then break end
            if IsNuiFocused() then
                wasFocused = true
            elseif wasFocused then
                break
            end
            Wait(250)
        end

        if not saved then cancelled = true end
        RemoveEventHandler('qb-clothing:client:loadPlayerClothing', onSave)
        RemoveEventHandler('illenium-appearance:client:appearanceSaved', onSave)
        teardownStreaming()

        if cancelled then
            dbg('appearance save failure (fallback clothing editor did not save)')
            W2F.Creator.HideMulticharUiForAppearance('fallback_appearance_cancelled')
            lib.callback.await('w2f-multicharacter:server:cancelCreation', false)
            W2F.Creator.ReturnToSelection(false)
            return
        end

        --- Some qb-clothes builds persist server-side before emitting their save
        --- event and do not pass the appearance payload back to this resource.
        --- Verify the playerskins row exists before finishCreation.
        saveAppearanceThenFinish(savedAppearance, cc, gender, coords, heading)
    end)
end

local function startCreatorInputLock()
    CreateThread(function()
        while W2F.Session.In('creating', 'appearance') do
            W2F.Interaction.DisableControls()
            SetPauseMenuActive(false)
            Wait(0)
        end
    end)
end

local function startLegacyAppearance(result, visualSlot, reason)
    local transOk = W2F.Session.Is('appearance')
        or W2F.Session.Transition('appearance', reason or 'create_ok')
    if not transOk then
        pcall(function() lib.callback.await('w2f-multicharacter:server:cancelCreation', false) end)
        W2F.Creator.ReturnToSelection(false)
        return false
    end

    local cc = Config.CharacterCreation or {}
    local coords = cc.appearanceLocation
    if not coords then
        local slot = Config.Scene.pedSlots[visualSlot]
        coords = slot and Config.GetSlotCoords(slot) or Config.GetSceneFocal()
    end

    dbg('legacy appearance fallback started reason=%s', tostring(reason or 'legacy_config'))
    W2F.Creator.HideMulticharUiForAppearance('legacy_appearance_start')
    W2F.Creator.OpenAppearance(result.gender or 0, coords, coords.w or 0.0)
    return true
end

-----------------------------------------------------------------------------
--- StartPipeline - kicked off from the submit NUI callback.
---
--- Sequence (legacy LSIA, when directToApartment is false):
---   1. Transition `creating` -> `appearance` (after server createCharacter
---      succeeds). The transition itself updates the legacy flags.
---   2. Fade out + run cleanup (tutorial, camera, lineup).
---   3. Call server createCharacter; on failure recover -> selection.
---   4. On success, OpenAppearance() at the configured appearanceLocation.
---
--- Sequence (direct-to-apartment, default):
---   1. Fade out + cleanup (tutorial, camera, lineup) — same as legacy.
---   2. Call server createCharacter; on failure recover -> selection.
---   3. On success, SpawnDirectlyInApartment() logs the player in, claims
---      the starter apartment, and lets qbx_properties open the clothing
---      editor INSIDE the apartment.
-----------------------------------------------------------------------------
function W2F.Creator.StartPipeline(formData, visualSlot)
    if not W2F.Session.Is('creating') and not W2F.Session.Is('selection') then return end
    if W2F.Session.Is('appearance') then return end

    --- We were in `creating` (form open). Stay there until the server returns
    --- success; on failure we go back to `selection`, on success we move
    --- forward (either to `appearance` for the legacy LSIA flow or to
    --- `finalizing` for the direct-to-apartment flow).
    W2F.Creator.suppressAutoOpen = true
    W2F.Creator.pendingVisualSlot = visualSlot
    W2F.State.pendingVisualSlot = visualSlot

    W2F.Creator.HideMulticharUiForAppearance('pipeline_start')
    if W2F.Hud and W2F.Hud.Hide then W2F.Hud.Hide() end

    --- Creation must run outside the tutorial/routing bucket so clothing and
    --- framework resources behave exactly like a normal character session.
    if W2F.Cleanup then
        W2F.Cleanup.EndTutorialSession()
        W2F.Cleanup.ResetRoutingBucket()
    end

    W2F.Characters.ClearPreviewPeds()
    W2F.Camera.Destroy()

    DoScreenFadeOut(450)
    while not IsScreenFadedOut() do Wait(0) end

    local ok, result = lib.callback.await('w2f-multicharacter:server:createCharacter', false, formData)
    if not ok or type(result) ~= 'table' then
        DoScreenFadeIn(400)
        lib.notify({
            title = 'New Character',
            description = type(result) == 'string' and result or 'Could not create character.',
            type = 'error',
        })
        if W2F.Nui and W2F.Nui.SendResult then
            W2F.Nui.SendResult('createCharacterResult', false,
                type(result) == 'string' and result or 'create_failed')
        end
        W2F.Creator.ReturnToSelection(false)
        return
    end

    dbg('createCharacter success citizenid=%s cid=%s', tostring(result.citizenid), tostring(result.cid))
    W2F.Creator.HideMulticharUiForAppearance('create_success')

    --- Stash the new character's id BEFORE transitioning so the spawn /
    --- apartment paths can read it.
    W2F.State.pendingNewCitizenid = result.citizenid
    W2F.State.isNewCharacter = true
    W2F.State.pendingVisualSlot = visualSlot
    W2F.State.autoSpawnAfterCreation = true
    W2F.State.pendingNewCharacterMeta = {
        citizenid = result.citizenid,
        cid = result.cid,
        firstname = result.firstname,
        lastname = result.lastname,
        gender = result.gender,
    }

    if W2F.Nui and W2F.Nui.SendResult then
        W2F.Nui.SendResult('createCharacterResult', true, nil, result)
    end

    startCreatorInputLock()

    --- NEW (preferred): direct-to-apartment. Skip the LSIA appearance hop
    --- and the spawn picker entirely. Player lands inside their starter
    --- apartment with the clothing editor already opening on top.
    ---
    --- Only taken when an apartment resource is actually running (see
    --- `apartmentSystemAvailable`). Without one we fall through to the
    --- standalone appearance + spawn-picker pipeline below, so the resource
    --- works with or without any apartment system.
    if apartmentSystemAvailable() then
        W2F.Creator.SpawnDirectlyInApartment()
        return
    end

    --- Standalone (no-apartment) pipeline: transition to `appearance` and run
    --- the editor at the configured outdoor location, then hand off to the
    --- spawn picker. Also used as the runtime fallback by
    --- SpawnDirectlyInApartment when no apartments are actually available.
    W2F.Creator.RunAppearancePipeline(result.gender or 0, visualSlot, 'create_ok')
end

-----------------------------------------------------------------------------
--- RunAppearancePipeline - standalone appearance editor -> spawn picker.
---
--- Transitions `creating -> appearance` and opens the clothing editor at the
--- configured `appearanceLocation`. On illenium/qb-clothes save this hands off
--- to GoDirectlyToSpawn (the spawn picker), which works with or without an
--- apartment system. Returns false if the phase transition was rejected
--- (in which case the partial character is rolled back).
-----------------------------------------------------------------------------
function W2F.Creator.RunAppearancePipeline(gender, visualSlot, reason)
    local cc = Config.CharacterCreation or {}

    local transOk = W2F.Session.Transition('appearance', reason or 'create_ok')
    if not transOk then
        --- Couldn't transition (unexpected) - roll back and recover.
        pcall(function() lib.callback.await('w2f-multicharacter:server:cancelCreation', false) end)
        W2F.Creator.ReturnToSelection(false)
        return false
    end

    local coords = cc.appearanceLocation
    if not coords then
        local slot = Config.Scene.pedSlots[visualSlot]
        coords = slot and Config.GetSlotCoords(slot) or Config.GetSceneFocal()
    end
    local heading = coords.w or 0.0

    W2F.Creator.OpenAppearance(gender or 0, coords, heading)
    return true
end

-----------------------------------------------------------------------------
--- SpawnDirectlyInApartment - direct-to-apartment pipeline.
---
--- Runs AFTER `createCharacter` has returned the new citizenid. Skips the
--- LSIA appearance editor and the spawn picker entirely. Logs in as the new
--- character, claims the configured starter apartment, and lets
--- qbx_properties' apartmentSelect handler open the clothing editor INSIDE
--- the apartment.
---
--- Phase path: creating -> finalizing -> playing.
-----------------------------------------------------------------------------
function W2F.Creator.SpawnDirectlyInApartment()
    dbg('SpawnDirectlyInApartment called')
    if not (W2F.IsQbxPropertiesAvailable and W2F.IsQbxPropertiesAvailable()) then
        dbg('qbx_properties unavailable fallback selected')
        startLegacyAppearance(W2F.State.pendingNewCharacterMeta or {}, W2F.State.pendingVisualSlot,
            'qbx_properties_unavailable')
        return
    end

    local meta = W2F.State.pendingNewCharacterMeta or {}
    local citizenid = meta.citizenid or W2F.State.pendingNewCitizenid
    if not citizenid then
        W2F.Creator.ReturnToSelection(true)
        return
    end

    local cc = Config.CharacterCreation or {}
    local apartmentIndex = cc.starterApartmentIndex or 1

    --- StartPipeline already faded out. Belt-and-braces.
    if not IsScreenFadedOut() then
        DoScreenFadeOut(450)
        while not IsScreenFadedOut() do Wait(0) end
    end

    --- Generation token so the watchdog can CANCEL this in-flight coroutine.
    --- Without it the watchdog rolls the character back (delete + logout) while
    --- the coroutine is still suspended on an await; when that await resumes it
    --- would re-fire apartmentSelect for a deleted/logged-out citizenid and fall
    --- through into FirePlayerLoadedEvents on corrupted state. Every await below
    --- is followed by `if aborted() then return end`.
    W2F.Creator.aptRun = (W2F.Creator.aptRun or 0) + 1
    local myRun = W2F.Creator.aptRun
    local function aborted() return W2F.Creator.aptRun ~= myRun end

    --- Watchdog: if the whole "login + apartment claim + clothing open"
    --- sequence stalls for any reason (slow MySQL, missing qbx_properties,
    --- model swap timeout, ...) we must recover instead of leaving the
    --- player stranded on a black screen.
    if W2F.Watchdog and W2F.Watchdog.Arm then
        W2F.Watchdog.Arm('creator_apt', 25000, function()
            --- Invalidate the in-flight run FIRST so a late-resuming await bails
            --- at its next aborted() checkpoint instead of mutating state.
            W2F.Creator.aptRun = (W2F.Creator.aptRun or 0) + 1
            if W2F.Debug then W2F.Debug('SpawnDirectlyInApartment watchdog tripped') end
            if IsScreenFadedOut() then DoScreenFadeIn(500) end
            --- createCharacter already logged the player in as this new
            --- character. A 25s stall means the apartment handoff never
            --- completed, so roll the half-created character back (server-side
            --- logout + delete) before returning to the lineup. Without this,
            --- the next spawn calls qbx_core loadCharacter while the player is
            --- still logged in, which qbx rejects as a "login twice" kick.
            pcall(function()
                lib.callback.await('w2f-multicharacter:server:cancelCreation', false)
            end)
            W2F.Creator.ReturnToSelection(false)
        end)
    end

    local function abort(reason, message)
        if W2F.Watchdog then W2F.Watchdog.Disarm('creator_apt') end
        lib.notify({
            title = 'Character',
            description = message or 'Could not start your character.',
            type = 'error',
        })
        if W2F.Nui and W2F.Nui.SendResult then
            W2F.Nui.SendResult('spawnFailed', false, reason or 'spawn_failed')
        end
        --- Best-effort: roll back the partial server-side character so the
        --- slot is free and the lineup is correct on the next attempt.
        pcall(function() lib.callback.await('w2f-multicharacter:server:cancelCreation', false) end)
        W2F.Creator.ReturnToSelection(false)
    end

    --- Step 1: resolve the configured apartment's enter coords from the
    --- server (also acts as an ownership / qbx_properties sanity check).
    local apts = lib.callback.await('w2f-multicharacter:server:getApartmentOptions',
        false, citizenid) or {}
    if aborted() then return end
    local enterCoords
    if type(apts) == 'table' then
        for i = 1, #apts do
            local apt = apts[i]
            if apt and apt.index == apartmentIndex and apt.coords then
                enterCoords = vec4(apt.coords.x, apt.coords.y, apt.coords.z, 0.0)
                break
            end
        end
        --- Fallback: first available apartment (config index might point
        --- at a slot qbx_properties doesn't expose).
        if not enterCoords and apts[1] and apts[1].coords then
            apartmentIndex = apts[1].index or apartmentIndex
            enterCoords = vec4(apts[1].coords.x, apts[1].coords.y, apts[1].coords.z, 0.0)
        end
    end
    if not enterCoords then
        --- Apartment resource is started but exposes no usable apartment
        --- (misconfigured index, empty apartmentOptions, properties table
        --- missing, ...). Rather than rolling back the freshly-created
        --- character, gracefully fall back to the standalone appearance ->
        --- spawn-picker flow so creation still completes.
        dbg('SpawnDirectlyInApartment: no apartments available, falling back to appearance flow')
        if W2F.Watchdog then W2F.Watchdog.Disarm('creator_apt') end
        lib.notify({
            title = 'Apartment',
            description = 'No starter apartment is available. Opening character appearance instead.',
            type = 'warning',
        })
        W2F.Creator.RunAppearancePipeline(meta.gender or 0,
            W2F.State.pendingVisualSlot, 'apt_unavailable_fallback')
        return
    end

    --- Step 2: tell our own server we're selecting this character (writes
    --- `session[src].selectedCitizenid` so the audit log + later finalize
    --- callbacks know which character we mean).
    local selectOk = lib.callback.await('w2f-multicharacter:server:selectCharacter',
        false, citizenid)
    if not selectOk then
        --- Could be the per-source cooldown. Retry once after a short wait.
        Wait(500)
        selectOk = lib.callback.await('w2f-multicharacter:server:selectCharacter',
            false, citizenid)
    end
    if aborted() then return end
    if not selectOk then
        abort('select_failed', 'Could not select your new character.')
        return
    end

    --- Step 3: actually place the player at the apartment enter coords.
    --- createCharacter already logged them in via qbx_core:Login — do NOT
    --- call loadCharacter again or qbx_core kicks for "login twice".
    --- qbx_properties will teleport them into the interior on apartmentSelect.
    local loaded, reason = W2F.CharacterLoad.Load({
        citizenid = citizenid,
        coords = enterCoords,
        skipLogin = true,
    })
    if aborted() then return end
    if not loaded then
        abort(tostring(reason), ('Could not load character (%s).'):format(tostring(reason)))
        return
    end

    --- Step 4: validate the claim AFTER login (so canClaimApartment's
    --- "you must be logged in as the new character" branch sees us).
    local canClaim, claimErr = lib.callback.await('w2f-multicharacter:server:canClaimApartment',
        false, apartmentIndex, citizenid)
    if aborted() then return end
    if not canClaim then
        if W2F.Watchdog then W2F.Watchdog.Disarm('creator_apt') end
        dbg('apartment claim precheck failed; falling back to legacy appearance reason=%s', tostring(claimErr))
        lib.notify({
            title = 'Apartment',
            description = 'Starter apartment unavailable. Opening character appearance instead.',
            type = 'warning',
        })
        startLegacyAppearance(meta, W2F.State.pendingVisualSlot, 'apt_claim_denied')
        return
    end

    --- Step 5: hand off to qbx_properties. The server-side handler:
    ---   1. inserts the property row + tags the owner
    ---   2. calls EnterProperty which teleports the player into the interior
    ---   3. waits 200ms
    ---   4. fires `qb-clothes:client:CreateFirstCharacter` on the client,
    ---      which illenium-appearance / qb-clothes both listen for and use
    ---      to open the clothing editor at the player's current position.
    --- CRITICAL: bail here if the watchdog already rolled the character back, so
    --- we don't create an orphaned property row for a deleted citizenid.
    if aborted() then return end
    TriggerServerEvent('qbx_properties:server:apartmentSelect', apartmentIndex)

    --- Step 6: audit the claim (the await also gives qbx ~50-100ms to start
    --- processing apartmentSelect, so when we fade in next the teleport is
    --- usually already complete).
    local confirmOk, claimed = pcall(function()
        return lib.callback.await('w2f-multicharacter:server:confirmApartmentClaimed',
            false, apartmentIndex, citizenid)
    end)
    dbg('confirmApartmentClaimed %s', confirmOk and claimed and 'success' or 'failure')
    if aborted() then return end
    if not confirmOk or not claimed then
        if W2F.Watchdog then W2F.Watchdog.Disarm('creator_apt') end
        lib.notify({
            title = 'Apartment',
            description = 'Starter apartment could not be confirmed. Opening character appearance instead.',
            type = 'warning',
        })
        startLegacyAppearance(meta, W2F.State.pendingVisualSlot, 'apt_claim_unconfirmed')
        return
    end

    --- Step 7: transition to `finalizing`. From `creating` this is now an
    --- allowed transition (see session.lua) for exactly this pipeline.
    local finOk = W2F.Session.Transition('finalizing', 'creator_apt_claim')
    if not finOk then
        --- Shouldn't happen but never trust the state machine; force a
        --- recover so the player isn't stuck in `creating`. The apartment is
        --- already CLAIMED (committed) at this point, so disarm the watchdog
        --- first — otherwise it would fire cancelCreation and DELETE a valid,
        --- apartment-owning character — and `return` so we don't fall through to
        --- FirePlayerLoadedEvents / fade on a rejected transition.
        if W2F.Watchdog then W2F.Watchdog.Disarm('creator_apt') end
        W2F.Session.Recover('creator_apt_claim_invalid')
        return
    end

    --- Step 8: clear lineup visuals / camera / focus. Cleanup.Full also
    --- runs ResetPlayerPed which re-enables visibility on the freshly
    --- loaded character ped.
    if W2F.Cleanup and W2F.Cleanup.Full then W2F.Cleanup.Full(true) end

    --- Step 9: fire framework "player loaded" events so qbx_hud, banking,
    --- radial menu, weathersync etc. wake up for the new character.
    W2F.Cleanup.FirePlayerLoadedEvents()
    W2F.Cleanup.RestoreFrameworkUi(6)

    --- Step 10: done — we're playing. The clothing editor will pop up on
    --- top within ~200ms via qbx_properties' CreateFirstCharacter trigger.
    W2F.State.isNewCharacter = false
    W2F.State.pendingNewCitizenid = nil

    if W2F.Watchdog then W2F.Watchdog.Disarm('creator_apt') end

    W2F.Session.Transition('playing', 'creator_apt_complete')

    --- Clear suppression AFTER reaching `playing` so a late `playerLoggedOut`
    --- can't accidentally re-open the lineup mid-handoff.
    W2F.Creator.suppressAutoOpen = false

    --- Fade in so illenium-appearance's `IsScreenFadedIn()` spinner passes.
    DoScreenFadeIn(1200)
end

-----------------------------------------------------------------------------
--- GoDirectlyToSpawn - bypass the character selector after a successful
--- creation and drop the player into the spawn picker.
---
--- Suppression: `suppressAutoOpen` is held until the player's spawn finalizes
--- (`playing` phase) so a late `playerLoggedOut` event from QBX can't
--- re-trigger the lineup mid-flight.
-----------------------------------------------------------------------------
local function awaitSelectCharacter(citizenid)
    --- pcall the await: a rejected/timed-out callback (ox_lib throws through
    --- Citizen.Await on its internal timeout) would otherwise kill this thread
    --- before the caller's ReturnToSelection fallback runs. The second arg stays
    --- `false` (no callback) — it is NOT a timeout; a number would no-op retries.
    local function trySelect()
        local ok, res = pcall(lib.callback.await, 'w2f-multicharacter:server:selectCharacter', false, citizenid)
        return ok and res
    end
    --- Exponential backoff. The first call can race with QBX's logout cleanup
    --- and get rejected on cooldown; subsequent attempts wait progressively
    --- longer so we don't hammer the rate limit.
    for i, delay in ipairs(SELECT_RETRY_DELAYS_MS) do
        if trySelect() then return true end
        Wait(delay)
        dbg('selectCharacter retry %d/%d (waiting %dms)', i, #SELECT_RETRY_DELAYS_MS, delay)
    end
    --- Final attempt.
    return trySelect()
end

function W2F.Creator.GoDirectlyToSpawn()
    dbg('GoDirectlyToSpawn called')
    W2F.Creator.HideMulticharUiForAppearance('go_direct_spawn')
    local meta = W2F.State.pendingNewCharacterMeta or {}
    local citizenid = meta.citizenid or W2F.State.pendingNewCitizenid
    if not citizenid then
        W2F.Creator.ReturnToSelection(true)
        return
    end

    local character = {
        citizenid = citizenid,
        cid = meta.cid,
        charinfo = {
            firstname = meta.firstname or '',
            lastname = meta.lastname or '',
        },
    }

    --- Suppress auto-open: held until `playing` is reached.
    W2F.Creator.suppressAutoOpen = true

    --- Watchdog: the fade-out + tutorial-session loop + up to 5 selectCharacter
    --- awaits all block while the screen is black. A non-responding server (qbx
    --- mid-restart) would otherwise hang behind ox_lib's long callback timeout —
    --- a black-screen soft-lock. Recover to the lineup if the handoff stalls.
    if W2F.Watchdog and W2F.Watchdog.Arm then
        W2F.Watchdog.Arm('go_direct_spawn', 20000, function()
            if IsScreenFadedOut() then DoScreenFadeIn(500) end
            W2F.Creator.suppressAutoOpen = false
            W2F.Creator.ReturnToSelection(true)
        end)
    end

    DoScreenFadeOut(450)
    while not IsScreenFadedOut() do Wait(0) end

    if ClearFocus then ClearFocus() end
    if W2F.Cleanup and W2F.Cleanup.ResetRoutingBucket then
        W2F.Cleanup.ResetRoutingBucket()
    end
    if Config.General.UseRoutingBuckets then
        TriggerServerEvent('w2f-multicharacter:server:setSelectionBucket')
    end
    if not NetworkIsInTutorialSession() then
        NetworkStartSoloTutorialSession()
        local started = GetGameTimer()
        while not NetworkIsInTutorialSession() and (GetGameTimer() - started) < 3000 do
            Wait(0)
        end
    end

    local selectOk = awaitSelectCharacter(citizenid)
    if not selectOk then
        if W2F.Watchdog then W2F.Watchdog.Disarm('go_direct_spawn') end
        lib.notify({
            title = 'Character',
            description = 'Could not select new character. Returning to lineup.',
            type = 'error',
        })
        W2F.Creator.ReturnToSelection(true)
        return
    end

    --- Move from `appearance` directly to `selection` first (so the spawn
    --- picker has a clean state machine view), then hand off to
    --- `OpenFirstSpawnPicker` which will transition to `sky_picker`.
    W2F.Session.Transition('selection', 'direct_spawn_handoff')
    W2F.State.isNewCharacter = true
    W2F.State.pendingNewCitizenid = citizenid
    W2F.SetSelected(W2F.State.pendingVisualSlot, nil, character)

    if not (W2F.Spawner and W2F.Spawner.OpenFirstSpawnPicker) then
        if W2F.Watchdog then W2F.Watchdog.Disarm('go_direct_spawn') end
        W2F.Creator.ReturnToSelection(true)
        return
    end

    W2F.Spawner.OpenFirstSpawnPicker()
    --- Handoff to the spawn picker succeeded; the picker owns the flow now.
    if W2F.Watchdog then W2F.Watchdog.Disarm('go_direct_spawn') end

    --- Clear suppression only after the player has actually entered the
    --- world (`playing`). We attach a one-shot listener so a late logout
    --- event right after the apartment claim still doesn't reopen lineup.
    W2F.Session.OnEnter('playing', function()
        W2F.Creator.suppressAutoOpen = false
    end)
    --- Also clear it on `idle` / `selection` re-entry so a recover path
    --- can still re-open the lineup manually.
    W2F.Session.OnEnter('idle', function()
        W2F.Creator.suppressAutoOpen = false
    end)
end

function W2F.Creator.ReturnToSelection(keepNewCharacter)
    W2F.Creator.HideMulticharUiForAppearance('return_to_selection')
    --- Hold suppression until EnterSelection completes (so a logout-driven
    --- re-open doesn't race the manual one we're about to do).
    W2F.Creator.suppressAutoOpen = true

    --- Move back to selection. The state machine adapter will reset the
    --- legacy flags (isCreatingCharacter / isCreatePanelOpen / isInSelection).
    W2F.Session.Transition('selection', 'return_to_selection')

    if keepNewCharacter ~= true then
        W2F.State.pendingNewCitizenid = nil
        W2F.State.isNewCharacter = false
        W2F.State.autoSpawnAfterCreation = false
        W2F.State.pendingVisualSlot = nil
    end

    if W2F.Cleanup and W2F.Cleanup.Visuals then
        W2F.Cleanup.Visuals()
    end
    W2F.Camera.Destroy()
    W2F.SetSelectionFocus(false, false)

    DoScreenFadeOut(300)
    while not IsScreenFadedOut() do Wait(0) end

    Wait(200)
    --- EnterSelection itself transitions back into `selection` (it asserts
    --- the phase on entry). suppressAutoOpen is cleared inside the listener
    --- we attach below so we don't release the brake before EnterSelection
    --- finishes.
    local ok = pcall(function() W2F.EnterSelection('creator_return') end)
    if not ok then
        --- Last resort: just clear and let the next event handle re-open.
        W2F.Creator.suppressAutoOpen = false
    else
        --- Successful EnterSelection — clear the suppression on a small
        --- delay so logout-driven retries don't immediately fire.
        CreateThread(function()
            Wait(500)
            W2F.Creator.suppressAutoOpen = false
        end)
    end
end

RegisterNUICallback('submitCreateCharacter', function(data, cb)
    local slot = tonumber(data and data.slot) or W2F.Creator.pendingVisualSlot
    if not slot then
        cb({ ok = false, error = 'No slot selected.' })
        return
    end

    --- Don't block here — StartPipeline yields (lib.callback.await), so we
    --- have to fire-and-forget on a thread and return immediately to the
    --- NUI. The NUI's busy flag resets when it receives `createCharacterResult`.
    CreateThread(function()
        W2F.Creator.StartPipeline({
            firstname = data.firstname,
            lastname = data.lastname,
            nationality = data.nationality,
            gender = tonumber(data.gender),
            birthdate = data.birthdate,
        }, slot)
    end)

    cb({ ok = true })
end)

RegisterNUICallback('cancelCreateCharacter', function(_, cb)
    W2F.Creator.pendingVisualSlot = nil
    W2F.State.pendingVisualSlot = nil
    W2F.Creator.CloseRegistration()
    cb({ ok = true })
end)

--- If illenium-appearance is stopped/restarted while the player is mid-edit,
--- recover the appearance phase IMMEDIATELY instead of waiting up to the
--- watchdog interval. The recover hook is only set while the illenium editor is
--- the active handoff (cleared the moment its callback fires).
AddEventHandler('onClientResourceStop', function(res)
    if res ~= 'illenium-appearance' then return end
    if not (W2F.Session and W2F.Session.Is('appearance')) then return end
    local recover = W2F.Creator._appearanceRecover
    if recover then
        W2F.Creator._appearanceRecover = nil
        CreateThread(function() pcall(recover, 'illenium_stopped') end)
    end
end)
