W2F = W2F or {}

--- DEPRECATED-IN-PLACE.
---
--- `W2F.Selection.active` used to be the "are we in any multichar phase?" flag.
--- It is kept here for backward-compat and is now AUTO-SYNCED from
--- `W2F.Session.phase` by the adapter in `client/core/session.lua`.
--- Prefer `W2F.Session.IsActive()` for new code.
W2F.Selection = {
    active = false,
}

--- W2F.State is the shared scratchpad for everything that isn't worth its own
--- module: hover/click bookkeeping, drag offsets, lineup cache, etc.
---
--- Historically it also stored ~8 parallel boolean phase flags (`isInSelection`,
--- `isCreatingCharacter`, `isSkySpawnMode`, `isSpawning`,
--- `isTransitioningToSky`, `isCreatePanelOpen`, etc). Those flags are still
--- here for backward-compat reads but they are now derived from
--- `W2F.Session.phase` (see `client/core/session.lua`); writing them
--- directly is a NO-OP because the next session transition will overwrite
--- the value. New code MUST call `W2F.Session.Transition(...)` instead.
---@class W2FSelectionState
W2F.State = {
    --- Phase mirror flags (DERIVED — do not write). See `W2F.Session.phase`.
    isInSelection = false,
    isCreatingCharacter = false,
    isCreatePanelOpen = false,
    isSkySpawnMode = false,
    isSpawning = false,
    isTransitioningToSky = false,

    --- Genuine per-session scratch (still writable). These will gradually
    --- migrate into `W2F.Session.context`.
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
    selectedSpawn = nil,

    --- Set true once a brand-new character finishes creation+appearance;
    --- consumed by the spawn picker so apartment cards are shown.
    isNewCharacter = false,
    pendingNewCitizenid = nil,
    --- Snapshot of the just-created character so the direct-to-spawn flow
    --- has a selectedCharacter without needing to rebuild the lineup.
    pendingNewCharacterMeta = nil,
    --- Visual ped slot the player clicked to create (lineup position).
    pendingVisualSlot = nil,
    --- When true, EnterSelection auto-triggers BeginSkySequence immediately
    --- after the new character is selected, skipping manual spawn press.
    autoSpawnAfterCreation = false,

    nuiFocused = false,
    cameraActive = false,
    clickDebounce = 70,
    lastClickTime = 0,
    lastPedClickTime = 0,
    characters = {},
    previewPeds = {},
    appearanceCache = {},
    modelCache = {},
}

--- Facade: returns the canonical session phase (or 'idle' before core loads).
function W2F.State.Phase()
    return W2F.Session and W2F.Session.phase or 'idle'
end

--- Facade: convenience wrapper around `W2F.Session.Transition` that no-ops
--- gracefully when the state machine isn't loaded yet (shared script timing).
function W2F.State.Transition(target, reason, ctx)
    if W2F.Session and W2F.Session.Transition then
        return W2F.Session.Transition(target, reason, ctx)
    end
    return false, 'session_not_loaded'
end

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
    s.isCreatingCharacter = false
    s.isCreatePanelOpen = false
    s.isNewCharacter = false
    s.pendingNewCitizenid = nil
    s.pendingNewCharacterMeta = nil
    s.pendingVisualSlot = nil
    s.autoSpawnAfterCreation = false
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
