--- W2F.Render — unified visual environment for the character selection phase.
---
--- Owns everything that affects how the world LOOKS and STREAMS during
--- selection: timecycle, population suppression, interior boot priming, local
--- player visibility, and pre-fade-in camera finalization. Streaming handles
--- remain in W2F.Streaming; scene orchestration stays in W2F.Characters.

W2F = W2F or {}
W2F.Render = W2F.Render or {
    phase = 'idle',
    _integrityActive = false,
    _anchorActive = false,
}

local function cfg()
    return Config.Rendering or {}
end

local function sceneInteriorCfg()
    return (Config.Scene and Config.Scene.interior) or {}
end

--- Target coords for the hidden local ped during selection (streaming probe).
function W2F.Render.GetPedAnchorCoords(focal)
    if not focal then
        focal = Config.GetSceneFocal and Config.GetSceneFocal()
    end
    if not focal then return nil end

    --- Streaming probe uses slot floor Z, not chest-height focal Z.
    local anchorZ = focal.z
    local slots = Config.Scene and Config.Scene.pedSlots
    if slots and #slots > 0 then
        local sumZ = 0.0
        for i = 1, #slots do
            local c = Config.GetSlotCoords(slots[i])
            if c then sumZ = sumZ + c.z end
        end
        anchorZ = sumZ / #slots
    end

    local interior = sceneInteriorCfg()
    local keepUnderground = W2F.Diag and W2F.Diag.Flag and W2F.Diag.Flag('KeepPlayerUnderground')
    local keepInside = not keepUnderground and interior.keepPlayerInside ~= false
    local hideOffset = cfg().playerHideOffset or 50.0
    local z = keepInside and anchorZ or (anchorZ - hideOffset)
    return vector3(focal.x, focal.y, z)
end

local function applyHiddenPedState(ped)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityInvincible(ped, true)
    SetEntityAlpha(ped, 0, false)
    SetPedConfigFlag(ped, 32, true)
    FreezeEntityPosition(ped, true)
end

--- Keeps the local ped at the lineup anchor. qbx/spawnmanager can swap or
--- teleport the ped (e.g. to MRPD) — without this the MLO never streams.
function W2F.Render.EnforcePedAnchor()
    if W2F.Render.phase ~= 'selection' then return false end
    if W2F.Session and not W2F.Session.Is('selection') then return false end

    local anchor = W2F.Render.GetPedAnchorCoords()
    if not anchor then return false end

    local ped = PlayerPedId()
    if not ped or ped == 0 then return false end

    local coords = GetEntityCoords(ped)
    local dx = coords.x - anchor.x
    local dy = coords.y - anchor.y
    local dz = coords.z - anchor.z
    local driftSq = dx * dx + dy * dy + dz * dz

    if driftSq > 0.25 then
        SetEntityCoords(ped, anchor.x, anchor.y, anchor.z, false, false, false, false)
        applyHiddenPedState(ped)
        return true
    end

    if not IsEntityVisible(ped) then
        applyHiddenPedState(ped)
    end
    return false
end

--- Returns every vec3 the engine must have collision/streaming for before the
--- lineup camera can frame the scene correctly.
function W2F.Render.CollectScenePoints()
    local points = {}
    local seen = {}

    local function add(v)
        if not v then return end
        local key = ('%.2f,%.2f,%.2f'):format(v.x, v.y, v.z)
        if seen[key] then return end
        seen[key] = true
        points[#points + 1] = vector3(v.x, v.y, v.z)
    end

    if Config.GetSceneFocal then
        add(Config.GetSceneFocal())
    end

    local scene = Config.Scene
    if scene and scene.overviewCamera then
        add(scene.overviewCamera)
    end

    local slots = scene and scene.pedSlots
    if slots then
        for i = 1, #slots do
            add(Config.GetSlotCoords(slots[i]))
        end
    end

    return points
end

--- One-shot collision priming at every scene anchor (focal, camera, slots).
--- Safe to call during boot AND during the lightweight integrity pass.
function W2F.Render.PrimeScenePoints()
    for _, pt in ipairs(W2F.Render.CollectScenePoints()) do
        RequestCollisionAtCoord(pt.x, pt.y, pt.z)
    end
end

--- Applies the selection visual environment (time, weather sync off, density).
function W2F.Render.EnterSelection()
    if W2F.Render.phase == 'selection' then return end
    W2F.Render.phase = 'selection'

    DisplayRadar(false)

    local r = cfg()
    if r.suppressWeatherSync ~= false then
        pcall(function() TriggerEvent('qb-weathersync:client:DisableSync') end)
    end

    local freeze = r.freezeTime
    if freeze and freeze.hour then
        NetworkOverrideClockTime(freeze.hour, freeze.minute or 0, 0)
    end

    if r.artificialLights == true then
        SetArtificialLightsState(true)
    end

    W2F.Render.ApplyTimecycle('neutral')
    W2F.Render.StartIntegrityMonitor()
    W2F.Render.StartPedAnchor()
end

--- Restores world rendering state when leaving selection.
function W2F.Render.LeaveSelection()
    W2F.Render.StopPedAnchor()
    W2F.Render.StopIntegrityMonitor()
    W2F.Render.phase = 'idle'

    ClearTimecycleModifier()
    pcall(function() ClearExtraTimecycleModifier() end)

    if cfg().artificialLights == true then
        SetArtificialLightsState(false)
    end

    if cfg().suppressWeatherSync ~= false then
        pcall(function() TriggerEvent('qb-weathersync:client:EnableSync') end)
    end
end

--- Per-frame population suppression — call from the interaction loop.
function W2F.Render.SuppressWorldPopulation()
    if W2F.Render.phase ~= 'selection' then return end
    if cfg().suppressWorldPopulation == false then return end

    SetPedDensityMultiplierThisFrame(0.0)
    SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)
    SetVehicleDensityMultiplierThisFrame(0.0)
    SetRandomVehicleDensityMultiplierThisFrame(0.0)
    SetParkedVehicleDensityMultiplierThisFrame(0.0)
end

--- Applies lineup timecycle. `profileName` maps to Config.SceneProfiles lighting.
function W2F.Render.ApplyTimecycle(profileName)
    local r = cfg()
    local profile = Config.SceneProfiles and Config.SceneProfiles[profileName or 'neutral']
    local lighting = profile and profile.lighting or 'clean'

    local modifier = r.timecycle or 'MP_corona_heist_blend'
    local strength = r.timecycleStrength or 0.22

    if lighting == 'emergency' then
        modifier = r.timecycleEmergency or 'MP_corona_heist_blend'
        strength = r.timecycleStrengthEmergency or 0.30
    elseif lighting == 'medical' then
        modifier = r.timecycleMedical or 'int_hospital2_dm'
        strength = r.timecycleStrengthMedical or 0.24
    elseif lighting == 'garage' then
        modifier = r.timecycleGarage or 'int_carrier_hanger'
        strength = r.timecycleStrengthGarage or 0.20
    elseif lighting == 'dark' then
        modifier = r.timecycleDark or 'V_FIB_IT3'
        strength = r.timecycleStrengthDark or 0.32
    end

    SetTimecycleModifier(modifier)
    SetTimecycleModifierStrength(strength)
end

--- Places the local player inside the interior for streaming probes.
function W2F.Render.PlacePlayerForStreaming(focal)
    local anchor = W2F.Render.GetPedAnchorCoords(focal)
    if not anchor then return end
    local ped = PlayerPedId()
    if not ped or ped == 0 then return end
    SetEntityCoords(ped, anchor.x, anchor.y, anchor.z, false, false, false, false)
    applyHiddenPedState(ped)
end

--- Hides the local player once the interior + lineup are ready.
function W2F.Render.HideLocalPlayer(focal)
    W2F.Render.PlacePlayerForStreaming(focal)
end

--- Final camera + render pass immediately before fade-in.
function W2F.Render.FinalizeBeforeFadeIn()
    W2F.Render.PrimeScenePoints()

    if W2F.Camera and W2F.Camera.SnapOverview then
        W2F.Camera.SnapOverview()
    end

    if W2F.Camera and W2F.Camera.handle and DoesCamExist(W2F.Camera.handle) then
        RenderScriptCams(true, false, 0, true, true)
        SetCamActive(W2F.Camera.handle, true)
    end
end

--- Lightweight integrity monitor: one collision prime every N seconds while
--- in selection so the MLO doesn't silently unload after RelaxSceneStream.
function W2F.Render.StartIntegrityMonitor()
    if W2F.Render._integrityActive then return end
    local interval = (W2F.Performance and W2F.Performance.IntegrityCheckMs and W2F.Performance.IntegrityCheckMs())
        or cfg().integrityCheckMs or 8000
    if interval <= 0 then return end

    W2F.Render._integrityActive = true
    CreateThread(function()
        while W2F.Render._integrityActive and W2F.Render.phase == 'selection' do
            Wait(interval)
            if W2F.Render.phase ~= 'selection' then break end
            if W2F.Session and not W2F.Session.Is('selection') then break end
            W2F.Render.PrimeScenePoints()
            if W2F.Interior and W2F.Interior.TryPinAt and Config.GetSceneFocal then
                W2F.Interior.TryPinAt(Config.GetSceneFocal())
            end
        end
        W2F.Render._integrityActive = false
    end)
end

function W2F.Render.StopIntegrityMonitor()
    W2F.Render._integrityActive = false
end

--- Continuous ped anchor while in selection (qbx can relocate the ped mid-boot).
function W2F.Render.StartPedAnchor()
    if W2F.Render._anchorActive then return end
    W2F.Render._anchorActive = true
    CreateThread(function()
        while W2F.Render._anchorActive and W2F.Render.phase == 'selection' do
            if W2F.Session and not W2F.Session.Is('selection') then break end
            W2F.Render.EnforcePedAnchor()
            local interval = 250
            if W2F.Interior and W2F.Interior.IsSceneInterior and W2F.Interior.IsSceneInterior() then
                interval = 100
            end
            Wait(interval)
        end
        W2F.Render._anchorActive = false
    end)
end

function W2F.Render.StopPedAnchor()
    W2F.Render._anchorActive = false
end

--- Session hooks.
if W2F.Session and W2F.Session.OnEnter then
    W2F.Session.OnEnter('idle', function()
        W2F.Render.LeaveSelection()
    end)
    W2F.Session.OnEnter('recovering', function()
        W2F.Render.LeaveSelection()
    end)
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Render.LeaveSelection()
    end
end)
