local selectionActive = false

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
    if selectionActive then return end
    selectionActive = true

    W2F.ResetState()
    W2F.State.isInSelection = true

    preparePlayer()
    beginTutorialSession()

    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    local characters = W2F.Qbox.FetchCharacters()
    W2F.Characters.BuildLineup(characters)

    SetTimecycleModifier('MP_corona_heist_blend')
    SetTimecycleModifierStrength(0.22)

    W2F.SetSelectionFocus(true)
    W2F.SendNui('showSelection', { maxSlots = #Config.Scene.pedSlots })
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSkySpawnOptions', {})

    W2F.Camera.PlayIntro()
    W2F.Interaction.StartLoop()

    DoScreenFadeIn(800)
    W2F.Debug('Selection started with %s slots filled', tostring(#characters))
end

function W2F.ExitSelection()
    selectionActive = false
    W2F.Spawner.CleanupVisuals()
    W2F.ResetState()

    if NetworkIsInTutorialSession() then
        NetworkEndTutorialSession()
    end

    local ped = cache.ped or PlayerPedId()
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
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
        print('[w2f-multicharacter] Set Config.UseExternalCharacters = true and enable qbx_core characters.useExternalCharacters')
        return
    end

    Wait(500)
    W2F.EnterSelection()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    W2F.ExitSelection()
end)
