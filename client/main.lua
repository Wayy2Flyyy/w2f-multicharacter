local function preparePlayer()
    local ped = cache.ped or PlayerPedId()
    local focal = Config.GetSceneFocal()

    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCoords(ped, focal.x, focal.y, focal.z - 2.0, false, false, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityInvincible(ped, true)
end

local function beginTutorialSession()
    NetworkStartSoloTutorialSession()
    local timeout = GetGameTimer() + 5000
    while not NetworkIsInTutorialSession() and GetGameTimer() < timeout do
        Wait(0)
    end
end

function W2F.EnterSelection()
    if W2F.Selection.active then return end
    W2F.Selection.active = true

    W2F.ResetState()
    W2F.State.isInSelection = true

    preparePlayer()
    beginTutorialSession()
    if Config.General.UseRoutingBuckets then
        TriggerServerEvent('w2f-multicharacter:server:setSelectionBucket')
    end

    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    local characters = W2F.Qbox.FetchCharacters()
    W2F.Characters.BuildLineup(characters)

    SetTimecycleModifier('MP_corona_heist_blend')
    SetTimecycleModifierStrength(0.22)
    DisplayRadar(false)

    W2F.SetSelectionFocus(true, true) -- cursor on, game input for ped clicks
    W2F.SendNui('showSelection', {
        maxSlots = #Config.Scene.pedSlots,
        showControlHints = Config.UI.showControlHints,
    })
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSkySpawnOptions', {})

    W2F.Camera.PlayIntro()
    if not W2F.Camera.active then
        W2F.Cleanup.Full(true)
        return
    end
    W2F.Interaction.StartLoop()

    DoScreenFadeIn(800)
    W2F.Debug('Selection session started')
end

function W2F.CloseSelection()
    W2F.Selection.active = false
    W2F.Cleanup.Full(true)
end

RegisterNetEvent('w2f-multicharacter:client:openSelection', function()
    W2F.EnterSelection()
end)

RegisterNetEvent('qbx_core:client:playerLoggedOut', function()
    if GetInvokingResource() then return end
    Wait(500)
    W2F.EnterSelection()
end)

CreateThread(function()
    while not NetworkIsSessionStarted() do
        Wait(200)
    end

    pcall(function()
        exports.spawnmanager:setAutoSpawn(false)
    end)

    if not Config.AutoOpen then
        return
    end

    if not Config.UseExternalCharacters then
        print('[w2f-multicharacter] Enable qbx_core characters.useExternalCharacters and Config.UseExternalCharacters')
        return
    end

    Wait(500)
    W2F.EnterSelection()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    W2F.CloseSelection()
end)

local function debugPrintState()
    local s = W2F.State
    local routingBucket = 'n/a'
    if GetPlayerRoutingBucket then
        local ok, bucket = pcall(GetPlayerRoutingBucket, PlayerId())
        if ok and bucket then
            routingBucket = tostring(bucket)
        end
    end

    local previewCount = 0
    for _ in pairs(s.previewPeds or {}) do
        previewCount = previewCount + 1
    end

    local selectedCid = s.selectedCharacter and s.selectedCharacter.citizenid or 'nil'
    local hoveredExists = s.hoveredPed and DoesEntityExist(s.hoveredPed) or false
    local selectedExists = s.selectedPed and DoesEntityExist(s.selectedPed) or false

    print(('[w2f-multicharacter][debug] isInSelection=%s | hoveredPed=%s | selectedPed=%s | selectedCharacter=%s | cameraMode=%s | isDraggingCamera=%s | isSkySpawnMode=%s | isSpawning=%s | nuiFocused=%s | routingBucket=%s | previewPeds=%s | activeProps=%s'):format(
        tostring(s.isInSelection),
        tostring(hoveredExists),
        tostring(selectedExists),
        tostring(selectedCid),
        tostring(W2F.Camera and W2F.Camera.mode or 'nil'),
        tostring(s.isDraggingCamera),
        tostring(s.isSkySpawnMode),
        tostring(s.isSpawning),
        tostring(s.nuiFocused),
        routingBucket,
        tostring(previewCount),
        '0'
    ))
end

local function debugReloadScene()
    if not W2F.State.isInSelection then
        W2F.EnterSelection()
        return
    end

    W2F.Cleanup.Visuals()
    local characters = W2F.Qbox.FetchCharacters()
    W2F.Characters.BuildLineup(characters)
    W2F.SetSelectionFocus(true, true)
    W2F.SendNui('showSelection', {
        maxSlots = #Config.Scene.pedSlots,
        showControlHints = Config.UI.showControlHints,
    })
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSkySpawnOptions', {})
    W2F.Camera.PlayIntro()
    W2F.Interaction.StartLoop()
end

if Config.Debug then
    RegisterCommand('w2fmc_debug', function()
        debugPrintState()
    end, false)

    RegisterCommand('w2fmc_state', function()
        debugPrintState()
    end, false)

    RegisterCommand('w2fmc_resetcam', function()
        if not W2F.State.isInSelection then return end
        W2F.Camera.ReturnToOverview()
    end, false)

    RegisterCommand('w2fmc_cleanup', function()
        W2F.Cleanup.Full(false)
    end, false)

    RegisterCommand('w2fmc_testspawn', function(_, args)
        if not W2F.State.isInSelection or not W2F.State.selectedCharacter then
            print('[w2f-multicharacter][debug] select a character first')
            return
        end
        if W2F.State.isSpawning then return end
        local spawnId = (args and args[1]) or 'public'
        if not W2F.State.isSkySpawnMode then
            W2F.Spawner.BeginSkySequence()
            CreateThread(function()
                local timeout = GetGameTimer() + 8000
                while not W2F.State.isSkySpawnMode and GetGameTimer() < timeout do
                    Wait(50)
                end
                if W2F.State.isSkySpawnMode then
                    W2F.Spawner.FlyToSpawn(spawnId)
                end
            end)
            return
        end
        W2F.Spawner.FlyToSpawn(spawnId)
    end, false)

    RegisterCommand('w2fmc_reloadscene', function()
        debugReloadScene()
    end, false)
end
