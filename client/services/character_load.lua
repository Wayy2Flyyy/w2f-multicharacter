--- W2F.CharacterLoad - explicit, step-by-step character load.
---
--- Replaces `W2F.Qbox.LoadCharacterAt` which returned `true` on partial
--- failure (the audit's biggest reliability finding). Every step has its
--- own timeout + reason string, and the function returns
---   (ok, reason, ped, telemetry)
--- so callers can route the failure into `Session.Recover(reason)` and the
--- NUI `spawnFailed` toast.
---
--- Steps (in order):
---   1. qbx_core:server:loadCharacter         - canonical login on the server
---   2. wait for QBX.PlayerData.citizenid     - playerData sync
---   3. fetch saved model + appearance        - getPreviewPedData
---   4. lib.requestModel + SetPlayerModel     - model swap
---   5. wait for ped model swap               - GetEntityModel poll
---   6. apply appearance (illenium / qb)      - tryApplySkin
---   7. RequestCollisionAtCoord + wait        - streaming
---   8. SetEntityCoords / Heading / unfreeze  - placement
---
--- Each step records timing under `W2F.Telemetry.RecordSpan` so the overlay
--- can show which step is the bottleneck on slow machines.

W2F = W2F or {}
W2F.CharacterLoad = W2F.CharacterLoad or {}

local DEFAULT_TIMEOUTS = {
    serverLoad = 8000,
    playerData = 8000,
    model = 6000,
    appearance = 4000,
    collision = 6000,
}

local function tnow()
    return GetGameTimer()
end

local function recordSpan(name, started)
    if W2F.Telemetry and W2F.Telemetry.RecordSpan then
        W2F.Telemetry.RecordSpan(name, tnow() - started)
    end
end

local function getPlayerData()
    if QBX and QBX.PlayerData and QBX.PlayerData.citizenid then
        return QBX.PlayerData
    end
    if exports.qbx_core and exports.qbx_core.GetPlayerData then
        local ok, data = pcall(function() return exports.qbx_core:GetPlayerData() end)
        if ok then return data end
    end
    return nil
end

local function awaitWithTimeout(name, timeoutMs, ...)
    local done, value, errResult = false, nil, nil
    local args = { ... }
    CreateThread(function()
        local ok, v = pcall(lib.callback.await, name, false, table.unpack(args))
        if ok then
            value = v
        else
            errResult = v
        end
        done = true
    end)
    local deadline = tnow() + (timeoutMs or 5000)
    while not done and tnow() < deadline do
        Wait(20)
    end
    return done, value, errResult
end

local function loadAppearance(ped, citizenid, appearance)
    if not ped or ped == 0 then return false, 'no_ped' end

    if GetResourceState('illenium-appearance') == 'started' then
        if appearance then
            pcall(function()
                exports['illenium-appearance']:setPedAppearance(ped, appearance)
            end)
        end
        pcall(function()
            exports['illenium-appearance']:setPlayerModel(ped)
        end)
        pcall(function()
            exports['illenium-appearance']:loadPlayerSkin()
        end)
        return true
    end

    if GetResourceState('fivem-appearance') == 'started' then
        if appearance then
            pcall(function()
                exports['fivem-appearance']:setPlayerAppearance(appearance)
            end)
        end
        return true
    end

    if GetResourceState('qb-clothing') == 'started' and appearance then
        pcall(function()
            TriggerEvent('qb-clothing:client:loadPlayerClothing', appearance, ped)
        end)
        return true
    end

    if citizenid then
        local ok, saved = awaitWithTimeout('w2f-multicharacter:server:getAppearance', 3500, citizenid)
        if ok and saved and GetResourceState('illenium-appearance') == 'started' then
            pcall(function()
                exports['illenium-appearance']:setPedAppearance(ped, saved)
            end)
            return true
        end
    end

    return false, 'no_appearance_provider'
end

--- Loads `citizenid` and places the resulting ped at `coords` (vector4).
---
--- Returns (true, nil, ped) on success or (false, reason) on failure.
--- `reason` is one of: `no_qbox`, `server_timeout`, `server_denied`,
--- `playerdata_timeout`, `model_load_failed`, `model_swap_timeout`,
--- `appearance_failed`, `collision_timeout`.
function W2F.CharacterLoad.Load(opts)
    opts = opts or {}
    local citizenid = opts.citizenid
    local function fail(reason)
        if W2F.Debug then
            W2F.Debug('CharacterLoad.Load failure citizenid=%s reason=%s', tostring(citizenid), tostring(reason))
        end
        return false, reason
    end
    local coords = opts.coords
    if not citizenid or not coords then
        return fail('missing_args')
    end

    if not (W2F.Qbox and W2F.Qbox.IsActive and W2F.Qbox.IsActive()) then
        return fail('no_qbox')
    end

    local timeouts = opts.timeouts or {}
    local t = setmetatable(timeouts, { __index = DEFAULT_TIMEOUTS })

    --- Step 1: server-side login (skip when the player is already logged in
    --- as this citizenid — e.g. direct-to-apartment after createCharacter).
    if not opts.skipLogin then
        --- Orphaned-login guard: awaitWithTimeout spawns an uncancellable
        --- thread, so a prior attempt that timed out client-side may have
        --- completed the qbx login a moment later. On the retry the player is
        --- already logged in as this citizenid; re-issuing loadCharacter would
        --- trip qbx_core's "login twice" DropPlayer. Treat already-logged-in as
        --- success and skip straight to the playerData validation below.
        local pd0 = getPlayerData()
        if pd0 and pd0.citizenid == citizenid then
            recordSpan('charload.server_load', tnow())
        else
            local stepStarted = tnow()
            local done, success = awaitWithTimeout('qbx_core:server:loadCharacter', t.serverLoad, citizenid)
            if not done then
                recordSpan('charload.server_load', stepStarted)
                return fail('server_timeout')
            end
            if success == false then
                recordSpan('charload.server_load', stepStarted)
                return fail('server_denied')
            end
            recordSpan('charload.server_load', stepStarted)
        end
    end

    --- Step 2: wait for QBX playerData to reflect.
    local stepStarted = tnow()
    local pdDeadline = stepStarted + t.playerData
    local pd = getPlayerData()
    while (not pd or pd.citizenid ~= citizenid) and tnow() < pdDeadline do
        Wait(50)
        pd = getPlayerData()
    end
    recordSpan('charload.playerdata', stepStarted)
    if not pd or pd.citizenid ~= citizenid then
        return fail('playerdata_timeout')
    end

    --- Step 3: fetch saved model + appearance.
    stepStarted = tnow()
    local model, appearance = nil, nil
    if W2F.Qbox.GetPreviewPedData then
        local ok, m, a = pcall(W2F.Qbox.GetPreviewPedData, citizenid)
        if ok then model, appearance = m, a end
    end
    recordSpan('charload.fetch_model', stepStarted)

    --- Step 4: model swap.
    if model then
        stepStarted = tnow()
        local hash = type(model) == 'string' and joaat(model) or model
        --- Reject a non-ped hash too: SetPlayerModel with a valid-in-cdimage but
        --- non-ped model (corrupted/migrated character row) hard-crashes the game.
        if not hash or not IsModelInCdimage(hash) or not IsModelAPed(hash) then
            return fail('model_invalid')
        end
        if lib and lib.requestModel then
            local ok = lib.requestModel(hash, t.model)
            if not ok then
                return fail('model_load_failed')
            end
        else
            RequestModel(hash)
            local modelDeadline = tnow() + t.model
            while not HasModelLoaded(hash) and tnow() < modelDeadline do
                Wait(0)
            end
            if not HasModelLoaded(hash) then
                return fail('model_load_failed')
            end
        end

        SetPlayerModel(PlayerId(), hash)

        local swapDeadline = tnow() + t.model
        while GetEntityModel(PlayerPedId()) ~= hash and tnow() < swapDeadline do
            Wait(0)
        end
        SetModelAsNoLongerNeeded(hash)
        recordSpan('charload.model_swap', stepStarted)
        if GetEntityModel(PlayerPedId()) ~= hash then
            return fail('model_swap_timeout')
        end
    end

    --- Step 5: appearance.
    stepStarted = tnow()
    local ped = PlayerPedId()
    local appliedOk, appliedErr = loadAppearance(ped, citizenid, appearance)
    Wait(150)
    recordSpan('charload.appearance', stepStarted)
    if not appliedOk then
        return fail(appliedErr or 'appearance_failed')
    end

    --- Step 6: collision streaming at destination.
    stepStarted = tnow()
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    local colDeadline = tnow() + t.collision
    while not HasCollisionLoadedAroundEntity(PlayerPedId()) and tnow() < colDeadline do
        Wait(0)
    end
    recordSpan('charload.collision', stepStarted)
    --- Collision timeout is non-fatal (some interiors never report loaded)
    --- but record it so the overlay shows the problem.

    --- Step 7: placement + flag cleanup.
    stepStarted = tnow()
    ped = PlayerPedId()
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, coords.w or 0.0)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)
    SetPedConfigFlag(ped, 32, false)
    ClearPedTasksImmediately(ped)
    recordSpan('charload.placement', stepStarted)

    return true, nil, ped
end

--- Convenience: log a load attempt to telemetry events ring.
function W2F.CharacterLoad.LogResult(citizenid, ok, reason, elapsedMs)
    if W2F.Telemetry and W2F.Telemetry.Record then
        W2F.Telemetry.Record(ok and 'charload_ok' or 'charload_fail', {
            citizenid = citizenid,
            reason = reason,
            elapsedMs = elapsedMs,
        })
    end
end
