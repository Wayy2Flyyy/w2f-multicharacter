W2F.Cleanup = {}

function W2F.Cleanup.ResetPlayerPed()
    local ped = cache.ped or PlayerPedId()
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
    SetEntityVisible(ped, true, false)
end

function W2F.Cleanup.ResetRoutingBucket()
    if Config.General.UseRoutingBuckets then
        TriggerServerEvent('w2f-multicharacter:server:resetSelectionBucket')
    end
end

function W2F.Cleanup.EndTutorialSession()
    if NetworkIsInTutorialSession() then
        NetworkEndTutorialSession()
    end
end

function W2F.Cleanup.Visuals()
    W2F.Characters.ClearPreviewPeds()
    W2F.Camera.Destroy()
    ClearTimecycleModifier()
    pcall(function() ClearExtraTimecycleModifier() end)
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
    W2F.Cleanup.EndTutorialSession()
    W2F.Cleanup.ResetRoutingBucket()
    DisplayRadar(true)

    if exitSelection ~= false then
        W2F.ResetState()
    end

    W2F.Cleanup.ResetPlayerPed()
end
