local function preparePlayer()
    local ped = cache.ped or PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCoords(ped, Config.Scene.focal.x, Config.Scene.focal.y, Config.Scene.focal.z - 2.0, false, false, false, false)
    SetEntityCollision(ped, false, false)
end

function W2F.EnterSelection()
    if W2F.State.isInSelection then return end

    W2F.ResetState()
    W2F.State.isInSelection = true

    preparePlayer()
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    local characters = lib.callback.await('w2f-multicharacter:server:getCharacters', false) or {}
    W2F.Characters.BuildLineup(characters)

    SetTimecycleModifier('MP_corona_heist_blend')
    SetTimecycleModifierStrength(0.25)

    SetNuiFocus(true, true)
    W2F.SendNui('showSelection', { maxSlots = #Config.Scene.pedSlots })
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('hideSkySpawnOptions', {})

    W2F.Camera.PlayIntro()
    W2F.Interaction.StartLoop()

    DoScreenFadeIn(800)
    W2F.Debug('Selection started with %d characters', #characters)
end

function W2F.ExitSelection()
    W2F.Spawner.Cleanup()
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
        Wait(100)
    end

    pcall(function()
        exports.spawnmanager:setAutoSpawn(false)
    end)

    Wait(500)
    W2F.EnterSelection()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    W2F.ExitSelection()
end)
