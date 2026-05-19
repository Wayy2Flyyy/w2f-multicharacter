W2F.Interaction = {
    lastMouseX = nil,
    lastMouseY = nil,
    dragDistance = 0.0,
    loopRunning = false,
}

local function isLeftClickHeld()
    return IsDisabledControlPressed(0, 24) or IsControlPressed(0, 24)
end

local function wasLeftClickPressed()
    return IsDisabledControlJustPressed(0, 24) or IsControlJustPressed(0, 24)
end

local function wasLeftClickReleased()
    return IsDisabledControlJustReleased(0, 24) or IsControlJustReleased(0, 24)
end

function W2F.Interaction.UpdateCameraDrag()
    if not W2F.State.isInSelection or W2F.State.isSkySpawnMode or W2F.State.isSpawning then
        return
    end
    if W2F.Camera.mode ~= 'overview' or W2F.State.isIntroPlaying then
        return
    end

    local camCfg = Config.CameraControl
    if not camCfg.enabled then return end

    local cursorX, cursorY = GetNuiCursorPosition()
    if not cursorX then return end

    if isLeftClickHeld() then
        if not W2F.State.isDraggingCamera then
            W2F.State.isDraggingCamera = true
            W2F.Interaction.dragDistance = 0.0
            W2F.Interaction.lastMouseX = cursorX
            W2F.Interaction.lastMouseY = cursorY
        else
            local dx = cursorX - (W2F.Interaction.lastMouseX or cursorX)
            local dy = cursorY - (W2F.Interaction.lastMouseY or cursorY)
            W2F.Interaction.dragDistance = W2F.Interaction.dragDistance + math.abs(dx) + math.abs(dy)
            W2F.Camera.ApplyDrag(dx, dy)
            W2F.Interaction.lastMouseX = cursorX
            W2F.Interaction.lastMouseY = cursorY
        end
    elseif wasLeftClickReleased() and W2F.State.isDraggingCamera then
        W2F.State.isDraggingCamera = false
        W2F.Interaction.lastMouseX = nil
        W2F.Interaction.lastMouseY = nil
        CreateThread(function()
            Wait(50)
            W2F.Interaction.dragDistance = 0.0
        end)
    end
end

function W2F.Interaction.UpdatePedTargeting()
    if not W2F.State.isInSelection or W2F.State.isSkySpawnMode or W2F.State.isSpawning then
        return
    end
    if W2F.State.isDraggingCamera or W2F.State.isIntroPlaying then
        return
    end

    local origin, direction = W2F.ScreenToWorldRay()
    local slot, entry = W2F.Characters.FindPedNearRay(origin, direction)

    if slot and entry then
        if W2F.State.hoveredPed ~= entry.ped then
            W2F.SetHovered(slot, entry.ped)
            W2F.Characters.RefreshHighlights()
            W2F.SendNui('updateHoveredPed', { slot = slot })
        end
    elseif W2F.State.hoveredPed then
        W2F.SetHovered(nil, nil)
        W2F.Characters.RefreshHighlights()
        W2F.SendNui('updateHoveredPed', { slot = nil })
    end
end

function W2F.Interaction.HandleClick()
    if not W2F.State.isInSelection or W2F.State.isSkySpawnMode or W2F.State.isSpawning then
        return
    end
    if W2F.State.isIntroPlaying or W2F.State.isDraggingCamera then
        return
    end
    if not wasLeftClickPressed() or not W2F.CanClick() then
        return
    end

    if W2F.Interaction.dragDistance > Config.Interaction.dragThreshold then
        W2F.Interaction.dragDistance = 0.0
        return
    end

    local origin, direction = W2F.ScreenToWorldRay()
    local slot, entry = W2F.Characters.FindPedNearRay(origin, direction)

    if slot and entry and entry.character then
        if W2F.State.selectedPed ~= entry.ped then
            W2F.Characters.SelectSlot(slot, entry)
        end
    elseif W2F.State.detailsVisible then
        W2F.MarkClick()
        W2F.Characters.ClearSelection()
    end
end

function W2F.Interaction.DisableControls()
    DisableAllControlActions(0)
    EnableControlAction(0, 24, true)
    EnableControlAction(0, 245, true)
end

function W2F.Interaction.StartLoop()
    if W2F.Interaction.loopRunning then
        return
    end
    W2F.Interaction.loopRunning = true

    CreateThread(function()
        while W2F.State.isInSelection do
            W2F.Interaction.DisableControls()

            if W2F.Camera.mode == 'overview'
                and not W2F.State.isSpawning
                and not W2F.State.isSkySpawnMode
            then
                W2F.Interaction.UpdateCameraDrag()
                W2F.Interaction.UpdatePedTargeting()
                W2F.Interaction.HandleClick()
            end

            W2F.Camera.Update()
            Wait(0)
        end
        W2F.Interaction.loopRunning = false
    end)
end

RegisterNUICallback('selectCharacterPed', function(data, cb)
    local slot = tonumber(data and data.slot)
    if slot then
        local entry = W2F.State.previewPeds[slot]
        if entry and W2F.CanClick() then
            W2F.Characters.SelectSlot(slot, entry)
        end
    end
    cb('ok')
end)

RegisterNUICallback('cancelDetails', function(_, cb)
    if W2F.CanClick() then
        W2F.Characters.ClearSelection()
    end
    cb('ok')
end)

RegisterNUICallback('resetCamera', function(_, cb)
    W2F.Camera.ResetTargets()
    cb('ok')
end)
