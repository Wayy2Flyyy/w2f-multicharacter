--- W2F.Bootstrap - session-start + reconnect open path.
---
--- Split into:
---   * Bootstrap.ShouldAutoOpen()  - "is auto-open allowed right now?"
---     Used ONLY by the session-start path. Returns false during a fresh
---     login if `Config.AutoOpen` is off, post-creation suppression, or
---     post-spawn cooldown.
---   * Bootstrap.CanOpen()         - "is the resource even able to open?"
---     Used by manual events (openSelection net event, logout handler).
---     Doesn't enforce AutoOpen because manual events are explicit user/
---     framework intent. Still respects post-spawn cooldown.
---   * Bootstrap.OpenSelectionWithRetry() - the actual open loop.
---
--- The legacy `Bootstrap.opening` boolean is gone; we use
--- `W2F.Session.phase == 'bootstrapping'` as the mutex.

W2F.Bootstrap = W2F.Bootstrap or {
    nuiReady = false,
    opening = false,            --- mirrored by session adapter; kept for legacy reads
}

local function startupCfg()
    return Config.Startup or {}
end

local function dbg(...)
    if W2F.Debug then W2F.Debug(...) end
end

function W2F.Bootstrap.IsLoggedIn()
    if W2F.ESX and W2F.ESX.IsActive and W2F.ESX.IsActive() then
        return W2F.ESX.IsLoggedIn()
    end
    if QBX and QBX.PlayerData and QBX.PlayerData.citizenid then
        return true
    end
    if GetResourceState('qbx_core') == 'started' then
        local ok, data = pcall(function()
            return exports.qbx_core:GetPlayerData()
        end)
        if ok and data and data.citizenid then
            return true
        end
    end
    return false
end

--- Which framework core resource has to be up before we can boot. With
--- Config.Framework = 'auto' this accepts whichever supported core starts
--- first (previously the boot loop hard-required qbx_core, which dead-locked
--- ESX servers left on 'auto').
local function frameworkCoreState()
    local fw = Config.Framework or 'auto'
    if type(fw) == 'string' then fw = fw:lower() end

    if fw == 'qbox' then return 'qbx_core', GetResourceState('qbx_core') end
    if fw == 'qbcore' then return 'qb-core', GetResourceState('qb-core') end
    if fw == 'esx' then return 'es_extended', GetResourceState('es_extended') end

    if GetResourceState('qbx_core') == 'started' then return 'qbx_core', 'started' end
    if GetResourceState('qb-core') == 'started' then return 'qb-core', 'started' end
    if GetResourceState('es_extended') == 'started' then return 'es_extended', 'started' end
    return 'auto', 'missing'
end

--- Bounded callback: lib.callback.await blocks indefinitely if the server
--- hasn't registered the callback yet — wrap it so we never lock the entire
--- boot path on a single MySQL hiccup. Uses W2F.Watchdog for the timeout.
local function isReadyWithTimeout(timeoutMs)
    local done, result = false, nil
    CreateThread(function()
        local ok, value = pcall(function()
            return lib.callback.await('w2f-multicharacter:server:isReady', false)
        end)
        if ok then result = value end
        done = true
    end)

    local deadline = GetGameTimer() + (timeoutMs or 3500)
    while not done and GetGameTimer() < deadline do
        Wait(50)
    end
    return done and result == true
end

--- Blocks until the framework core + server DB are ready (or timeout).
function W2F.Bootstrap.WaitForReady()
    local cfg = startupCfg()
    local timeout = GetGameTimer() + (cfg.dependencyTimeoutMs or 45000)
    local started = GetGameTimer()

    --- Diagnostic prints so a stuck boot is observable on the F8 console without
    --- having to toggle Config.Debug.
    local lastReport = 0
    local lastOxLib, lastCore, lastReady = nil, nil, nil

    while GetGameTimer() < timeout do
        local oxLib = GetResourceState('ox_lib')
        local coreName, coreState = frameworkCoreState()
        local oxLibUp = oxLib == 'started'
        local coreUp = coreState == 'started'
        local depsUp = oxLibUp and coreUp

        local ready = false
        if depsUp then
            ready = isReadyWithTimeout(3500)
            if ready then return true end
        end

        --- Print state change OR every 4s while waiting so the user can see
        --- exactly which dep is blocking the boot.
        local now = GetGameTimer()
        if oxLib ~= lastOxLib or coreState ~= lastCore or ready ~= lastReady or (now - lastReport) >= 4000 then
            print(('[w2f-multicharacter][boot] WaitForReady waited=%dms ox_lib=%s core=%s(%s) serverReady=%s')
                :format(now - started, oxLib, coreName, coreState, tostring(ready)))
            lastOxLib, lastCore, lastReady = oxLib, coreState, ready
            lastReport = now
        end

        Wait(400)
    end

    local coreName, coreState = frameworkCoreState()
    print(('[w2f-multicharacter][boot] WaitForReady TIMED OUT after %dms (ox_lib=%s core=%s(%s))')
        :format(GetGameTimer() - started,
            GetResourceState('ox_lib'), coreName, coreState))
    dbg('Bootstrap.WaitForReady timed out')
    return false
end

function W2F.Bootstrap.WaitForNui(timeoutMs)
    local timeout = GetGameTimer() + (timeoutMs or 8000)
    while not W2F.Bootstrap.nuiReady and GetGameTimer() < timeout do
        Wait(50)
    end
    return W2F.Bootstrap.nuiReady
end

--- "Can the resource open the selection screen right now?" Doesn't care
--- about Config.AutoOpen; manual events (openSelection net event, logout)
--- always go through this path.
function W2F.Bootstrap.CanOpen()
    if not Config.UseExternalCharacters then return false end
    if W2F.Spawner and W2F.Spawner.IsSpawnCooldownActive and W2F.Spawner.IsSpawnCooldownActive() then
        return false
    end
    if W2F.Creator and W2F.Creator.suppressAutoOpen then return false end
    --- A bootstrapping/in-progress session is already opening; don't re-enter.
    if W2F.Session and W2F.Session.Is('bootstrapping') then return false end
    return true
end

--- Session-start-only gate: in addition to CanOpen, also enforces AutoOpen
--- and rejects when the player is already logged into a character.
function W2F.Bootstrap.ShouldAutoOpen()
    if not Config.AutoOpen then return false end
    if not W2F.Bootstrap.CanOpen() then return false end
    if W2F.Bootstrap.IsLoggedIn() then return false end
    return true
end

local function attemptOpenSelection(reason)
    print(('[w2f-multicharacter][boot] attemptOpenSelection reason=%s'):format(tostring(reason)))
    --- Mark phase so concurrent attempts no-op via `CanOpen` / `Session.Is`.
    local moved = W2F.Session.Transition('bootstrapping', reason)
    if not moved then
        print('[w2f-multicharacter][boot] attemptOpenSelection: bootstrap transition rejected')
        return false
    end

    --- Shut down loading screen on every attempt in case another resource
    --- redisplayed it. Belt-and-braces.
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()

    if not W2F.Bootstrap.WaitForReady() then
        print('[w2f-multicharacter][boot] attemptOpenSelection: WaitForReady failed; recovering to idle')
        W2F.Session.Transition('recovering', 'deps_timeout')
        W2F.Session.Transition('idle', 'deps_timeout')
        --- Defensive: never leave the player on a black screen even if every
        --- retry failed. We still try to recover, but we MUST surface visible
        --- state so the loading screen / fade-out doesn't strand them.
        if IsScreenFadedOut() then DoScreenFadeIn(500) end
        return false
    end

    print('[w2f-multicharacter][boot] attemptOpenSelection: deps ready, calling EnterSelection')
    local ok, opened = pcall(W2F.EnterSelection, reason)
    if ok and opened then
        print('[w2f-multicharacter][boot] attemptOpenSelection: EnterSelection succeeded')
        return true
    end
    if not ok then
        print(('[w2f-multicharacter][boot] attemptOpenSelection: EnterSelection error: %s'):format(tostring(opened)))
        dbg('Bootstrap EnterSelection error: %s', tostring(opened))
    else
        print('[w2f-multicharacter][boot] attemptOpenSelection: EnterSelection returned false')
    end

    --- EnterSelection failed; fall back to idle so a subsequent retry can
    --- re-enter bootstrapping cleanly.
    W2F.Session.Transition('recovering', 'enter_selection_failed')
    W2F.Session.Transition('idle', 'enter_selection_failed')
    if IsScreenFadedOut() then DoScreenFadeIn(500) end
    return false
end

--- Public entry: retries `attemptOpenSelection` up to `Startup.maxAttempts`
--- with `Startup.attemptDelayMs` between tries. `mode` decides whether the
--- session-start ShouldAutoOpen gate applies or just CanOpen.
---   mode = 'session'  -> ShouldAutoOpen (session start)
---   mode = 'manual'   -> CanOpen (logout event / openSelection net event)
function W2F.Bootstrap.OpenSelectionWithRetry(reason, mode)
    print(('[w2f-multicharacter][boot] OpenSelectionWithRetry queued reason=%s mode=%s'):format(
        tostring(reason), tostring(mode)))

    local cfg = startupCfg()
    local maxAttempts = cfg.maxAttempts or 6
    local delay = cfg.attemptDelayMs or 1500

    CreateThread(function()
        pcall(function()
            exports.spawnmanager:setAutoSpawn(false)
        end)

        ShutdownLoadingScreen()
        ShutdownLoadingScreenNui()

        for attempt = 1, maxAttempts do
            local gate = (mode == 'manual') and W2F.Bootstrap.CanOpen() or W2F.Bootstrap.ShouldAutoOpen()
            if not gate then
                print(('[w2f-multicharacter][boot] attempt %d/%d gate false reason=%s mode=%s ' ..
                    '(useExternal=%s autoOpen=%s loggedIn=%s spawnCooldown=%s suppress=%s phase=%s)')
                    :format(attempt, maxAttempts, tostring(reason), tostring(mode),
                        tostring(Config.UseExternalCharacters),
                        tostring(Config.AutoOpen),
                        tostring(W2F.Bootstrap.IsLoggedIn()),
                        tostring(W2F.Spawner and W2F.Spawner.IsSpawnCooldownActive
                            and W2F.Spawner.IsSpawnCooldownActive()),
                        tostring(W2F.Creator and W2F.Creator.suppressAutoOpen),
                        tostring(W2F.Session and W2F.Session.phase)))
                if attempt >= maxAttempts then
                    print('[w2f-multicharacter][boot] all retries exhausted (gate never opened)')
                    if IsScreenFadedOut() then DoScreenFadeIn(500) end
                    break
                end
                Wait(delay)
            else
                print(('[w2f-multicharacter][boot] attempt %d/%d'):format(attempt, maxAttempts))
                ShutdownLoadingScreen()
                ShutdownLoadingScreenNui()

                if attemptOpenSelection(reason) then
                    print(('[w2f-multicharacter][boot] open OK on attempt %d'):format(attempt))
                    dbg('Bootstrap open ok attempt=%d reason=%s mode=%s',
                        attempt, tostring(reason), tostring(mode))
                    return
                end

                print(('[w2f-multicharacter][boot] attempt %d/%d FAILED reason=%s mode=%s'):format(
                    attempt, maxAttempts, tostring(reason), tostring(mode)))
                if attempt >= maxAttempts then
                    print('[w2f-multicharacter][boot] all retries exhausted; falling back to fade-in')
                    ShutdownLoadingScreen()
                    ShutdownLoadingScreenNui()
                    if IsScreenFadedOut() then DoScreenFadeIn(500) end
                else
                    Wait(delay)
                end
            end
        end
    end)
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Bootstrap.nuiReady = false
    end
end)

RegisterNUICallback('nuiReady', function(_, cb)
    W2F.Bootstrap.nuiReady = true

    --- Re-emit the selection payload if we're already showing the lineup
    --- (NUI reloaded mid-session).
    if W2F.Session and W2F.Session.Is('selection') then
        local payload = (W2F.Nui and W2F.Nui.BuildSelectionPayload)
            and W2F.Nui.BuildSelectionPayload()
            or {
                maxSlots = #Config.Scene.pedSlots,
                showControlHints = Config.UI.showControlHints,
            }
        W2F.SendNui('showSelection', payload)
    end

    cb('ok')
end)
