--- Hologram HUD for the selected ped. Frame-rate independent smoothing,
--- centralised visibility control (the camera/spawner modules call
--- W2F.Hud.SetVisible whenever a cinematic owns the screen), and a strict
--- "respect Config.Highlight.hologramEnabled" gate.

W2F.Hud = W2F.Hud or {}
W2F.Hud.active = false
W2F.Hud.visible = true  --- external gate (camera/spawner can hide us)
W2F.Hud.data = nil
--- Smoothed screen-space anchor so the hologram glides instead of micro-
--- jittering with every breathing/idle animation tick on the ped.
W2F.Hud.smoothSX = nil
W2F.Hud.smoothSY = nil
W2F.Hud.smoothScale = nil
W2F.Hud._lastVisible = nil  --- last visibility we pushed to NUI; gates updates.

local HOLO_OFFSET_UP = 2.48   --- slightly lower so panel sits tighter to head
local HOLO_BASE_DISTANCE = 6.3
--- Rate (per second) used by the frame-rate independent smoother.
local HOLO_SMOOTH_RATE = 16.0
local HOLO_CLARITY_SHARPEN = 1.22
local HOLO_HIDDEN_PAYLOAD = { visible = false }

--- Anchor directly above the ped's head — no forward/back lateral offset so
--- the hologram projects centred over the ped regardless of camera angle.
local function getAnchor(ped)
    local coords = GetEntityCoords(ped)
    return vector3(coords.x, coords.y, coords.z + HOLO_OFFSET_UP)
end

local function pushHidden()
    --- Avoid spamming NUI with the same hidden payload every frame.
    if W2F.Hud._lastVisible == false then return end
    W2F.SendNui('updateHologram', HOLO_HIDDEN_PAYLOAD)
    W2F.Hud._lastVisible = false
end

local function clearSmoothBuffers()
    W2F.Hud.smoothSX = nil
    W2F.Hud.smoothSY = nil
    W2F.Hud.smoothScale = nil
end

function W2F.Hud.Show(payload)
    W2F.Hud.data = payload or {}
    W2F.Hud.active = true
    clearSmoothBuffers()
end

function W2F.Hud.Hide()
    if not W2F.Hud.active then return end
    W2F.Hud.active = false
    W2F.Hud.data = nil
    clearSmoothBuffers()
    pushHidden()
end

--- External visibility gate; cinematic camera + spawner call this to suppress
--- the hologram while they own the screen. Leaves Show/Hide alone so the
--- selected character bookkeeping survives the cinematic.
function W2F.Hud.SetVisible(visible)
    visible = visible ~= false
    if W2F.Hud.visible == visible then return end
    W2F.Hud.visible = visible
    if not visible then
        clearSmoothBuffers()
        pushHidden()
    end
end

--- Returns the configured Hud scale bounds; honours Config.Highlight overrides
--- so designers can dial these without code edits.
local function scaleBounds()
    local ui = (Config and Config.UI) or {}
    local hl = (Config and Config.Highlight) or {}
    local minScale = ui.hologramMinScale or hl.hologramMinScale or 0.74
    local maxScale = ui.hologramMaxScale or hl.hologramMaxScale or 1.85
    --- Defensive: if someone sets max < min, swap them so Clamp doesn't NaN.
    if maxScale < minScale then minScale, maxScale = maxScale, minScale end
    return minScale, maxScale
end

function W2F.Hud.Update()
    if not W2F.Hud.active or not W2F.Hud.visible then return end

    --- Respect the config gate (hologramEnabled = false fully disables the
    --- HUD without forcing every callsite to check first). Lives under
    --- Config.UI in this codebase; tolerate Highlight overrides too.
    local uiCfg = (Config and Config.UI) or {}
    local hlCfg = (Config and Config.Highlight) or {}
    if uiCfg.hologramEnabled == false or hlCfg.hologramEnabled == false then
        pushHidden()
        return
    end

    local ped = W2F.State.selectedPed
    if not ped or not DoesEntityExist(ped) then
        W2F.Hud.Hide()
        return
    end

    local anchor = getAnchor(ped)
    local onScreen, sx, sy = World3dToScreen2d(anchor.x, anchor.y, anchor.z)
    if not onScreen then
        --- Clear smoothing so we don't "snap" back through a frame of old
        --- coordinates when the ped re-enters the frustum.
        clearSmoothBuffers()
        pushHidden()
        return
    end

    local camPos = W2F.Camera.GetCurrentCoord()
    local dist = #(anchor - camPos)
    if dist < 0.5 then dist = 0.5 end

    local minScale, maxScale = scaleBounds()
    local scale = W2F.Clamp((HOLO_BASE_DISTANCE / dist) * HOLO_CLARITY_SHARPEN, minScale, maxScale)

    --- Frame-rate independent smoothing — old SmoothStep tied feel to FPS.
    local dt = (W2F.Frame and W2F.Frame.Dt and W2F.Frame.Dt()) or GetFrameTime()
    local smooth = (W2F.Frame and W2F.Frame.Smooth) or function(cur, target, _rate, _dt)
        --- Fallback for early-load paths that race the Frame service.
        return cur + (target - cur) * 0.2
    end

    W2F.Hud.smoothSX = W2F.Hud.smoothSX and smooth(W2F.Hud.smoothSX, sx, HOLO_SMOOTH_RATE, dt) or sx
    W2F.Hud.smoothSY = W2F.Hud.smoothSY and smooth(W2F.Hud.smoothSY, sy, HOLO_SMOOTH_RATE, dt) or sy
    W2F.Hud.smoothScale = W2F.Hud.smoothScale and smooth(W2F.Hud.smoothScale, scale, HOLO_SMOOTH_RATE, dt) or scale

    W2F.SendNui('updateHologram', {
        visible = true,
        x = W2F.Hud.smoothSX,
        y = W2F.Hud.smoothSY,
        scale = W2F.Hud.smoothScale,
        data = W2F.Hud.data,
    })
    W2F.Hud._lastVisible = true
end

CreateThread(function()
    while true do
        if W2F.Hud.active and W2F.Session and W2F.Session.Is('selection') then
            W2F.Hud.Update()
            local hudWait = (W2F.Performance and W2F.Performance.Get and W2F.Performance.Get('hudUpdateMs')) or 33
            Wait(hudWait)
        else
            --- Make sure hidden payload is published on session exit so the
            --- NUI doesn't carry stale text into the next phase.
            if W2F.Hud._lastVisible == true then pushHidden() end
            Wait(120)
        end
    end
end)

--- Session integration: hide whenever we leave selection, fully reset on idle.
if W2F.Session and W2F.Session.OnEnter then
    W2F.Session.OnExit('selection', function()
        clearSmoothBuffers()
        pushHidden()
    end)
    W2F.Session.OnEnter('idle', function()
        W2F.Hud.Hide()
    end)
end
