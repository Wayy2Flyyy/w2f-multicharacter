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
    dragStartX = nil,
    dragStartY = nil,
    hoveredPed = nil,
    hoveredSlot = nil,
    isHoveringPed = false,
    selectedPed = nil,
    selectedSlot = nil,
    selectedCharacter = nil,
    detailsVisible = false,
    isTransitioningToSky = false,
    isSkySpawnMode = false,
    selectedSpawn = nil,
    isSpawning = false,
    nuiFocused = false,
    cameraActive = false,
    clickDebounce = 350,
    lastClickTime = 0,
    lastPedClickTime = 0,
    characters = {},
    previewPeds = {},
    appearanceCache = {},
    modelCache = {},
}

function W2F.ResetState()
    local s = W2F.State
    s.isInSelection = false
    s.isIntroPlaying = false
    s.isDraggingCamera = false
    s.hasDraggedCamera = false
    s.dragStartX = nil
    s.dragStartY = nil
    s.hoveredPed = nil
    s.hoveredSlot = nil
    s.isHoveringPed = false
    s.selectedPed = nil
    s.selectedSlot = nil
    s.selectedCharacter = nil
    s.detailsVisible = false
    s.isTransitioningToSky = false
    s.isSkySpawnMode = false
    s.selectedSpawn = nil
    s.isSpawning = false
    s.nuiFocused = false
    s.cameraActive = false
    s.clickDebounce = Config.Interaction.clickDebounceMs
    s.lastClickTime = 0
    s.lastPedClickTime = 0
    s.characters = {}
    s.previewPeds = {}
    s.appearanceCache = {}
    s.modelCache = {}
end

function W2F.SetHovered(slot, ped)
    W2F.State.hoveredPed = ped
    W2F.State.hoveredSlot = slot
    W2F.State.isHoveringPed = ped ~= nil
end

function W2F.SetSelected(slot, ped, character)
    W2F.State.selectedPed = ped
    W2F.State.selectedSlot = slot
    W2F.State.selectedCharacter = character
    W2F.State.detailsVisible = character ~= nil
end

function W2F.CanClick()
    return (GetGameTimer() - W2F.State.lastClickTime) >= (W2F.State.clickDebounce or Config.Interaction.clickDebounceMs)
end

function W2F.MarkClick()
    W2F.State.lastClickTime = GetGameTimer()
end

function W2F.MarkPedClick()
    local now = GetGameTimer()
    W2F.State.lastClickTime = now
    W2F.State.lastPedClickTime = now
end
