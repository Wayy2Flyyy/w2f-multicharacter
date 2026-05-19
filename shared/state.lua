W2F = W2F or {}

W2F.Selection = {
    active = false,
}

---@class W2FSelectionState
W2F.State = {
    isInSelection = false,
    isIntroPlaying = false,
    isDraggingCamera = false,
    hasDraggedCamera = false,
    hoveredPed = nil,
    hoveredSlot = nil,
    selectedPed = nil,
    selectedSlot = nil,
    selectedCharacter = nil,
    detailsVisible = false,
    isSkySpawnMode = false,
    selectedSpawn = nil,
    isSpawning = false,
    nuiFocused = false,
    cameraActive = false,
    lastClickTime = 0,
    characters = {},
    previewPeds = {},
}

function W2F.ResetState()
    local s = W2F.State
    s.isInSelection = false
    s.isIntroPlaying = false
    s.isDraggingCamera = false
    s.hasDraggedCamera = false
    s.hoveredPed = nil
    s.hoveredSlot = nil
    s.selectedPed = nil
    s.selectedSlot = nil
    s.selectedCharacter = nil
    s.detailsVisible = false
    s.isSkySpawnMode = false
    s.selectedSpawn = nil
    s.isSpawning = false
    s.nuiFocused = false
    s.cameraActive = false
    s.lastClickTime = 0
    s.characters = {}
    s.previewPeds = {}
end

function W2F.SetHovered(slot, ped)
    W2F.State.hoveredPed = ped
    W2F.State.hoveredSlot = slot
end

function W2F.SetSelected(slot, ped, character)
    W2F.State.selectedPed = ped
    W2F.State.selectedSlot = slot
    W2F.State.selectedCharacter = character
    W2F.State.detailsVisible = character ~= nil
end

function W2F.CanClick()
    return (GetGameTimer() - W2F.State.lastClickTime) >= Config.Interaction.clickDebounceMs
end

function W2F.MarkClick()
    W2F.State.lastClickTime = GetGameTimer()
end
