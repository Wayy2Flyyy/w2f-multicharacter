--- W2F.Watchdog - armed timers with recover callbacks.
---
--- Every long-running flow step (cinematic, NUI ready, character load,
--- server callback await) arms a watchdog before starting and disarms it
--- on success. If the watchdog fires, its `recover` callback runs and the
--- session is forced into `recovering` so we never end up with disabled
--- controls or a stuck cinematic.
---
--- Usage:
---   W2F.Watchdog.Arm('fly', 12000, function(name) ... end)
---   ... do work ...
---   W2F.Watchdog.Disarm('fly')
---
--- Or scoped:
---   W2F.Watchdog.WithTimeout('callback', 5000, function()
---       return lib.callback.await('foo', false)
---   end)

W2F = W2F or {}
W2F.Watchdog = W2F.Watchdog or {
    armed = {},
    --- Telemetry: incremented each time a watchdog actually fires.
    tripCount = 0,
}

local function nowMs()
    return GetGameTimer()
end

local function debug(...)
    if W2F.Debug then W2F.Debug(...) end
end

--- Arms a watchdog named `name`. After `timeoutMs` it calls `recover(name)`
--- unless `Disarm` has been called first. Calling Arm with the same name
--- replaces the existing watchdog.
function W2F.Watchdog.Arm(name, timeoutMs, recover)
    if type(name) ~= 'string' or #name == 0 then
        error('Watchdog.Arm: name required')
    end
    timeoutMs = tonumber(timeoutMs) or 0
    if timeoutMs <= 0 then return end

    --- Bump generation so any in-flight thread for a prior arm exits.
    local prev = W2F.Watchdog.armed[name]
    local generation = (prev and prev.generation or 0) + 1
    W2F.Watchdog.armed[name] = {
        startedAt = nowMs(),
        timeoutMs = timeoutMs,
        recover = recover,
        generation = generation,
    }

    CreateThread(function()
        Wait(timeoutMs)
        local entry = W2F.Watchdog.armed[name]
        if not entry or entry.generation ~= generation then
            --- Disarmed or replaced — nothing to do.
            return
        end

        W2F.Watchdog.armed[name] = nil
        W2F.Watchdog.tripCount = W2F.Watchdog.tripCount + 1

        debug('Watchdog %s tripped after %dms', name, timeoutMs)

        if W2F.Telemetry and W2F.Telemetry.Record then
            W2F.Telemetry.Record('watchdog_trip', {
                name = name,
                timeoutMs = timeoutMs,
            })
        end

        if recover then
            local ok, err = pcall(recover, name)
            if not ok then
                print(('[w2f-multicharacter] watchdog recover %s error: %s')
                    :format(name, tostring(err)))
            end
        end

        --- Last-resort safety net: even if `recover` didn't move us, force
        --- a `recovering` transition so the session machine can clean up.
        --- BUT skip it when:
        ---   * the recover callback RE-ARMED this watchdog (armed[name] is
        ---     non-nil again) — a self-re-arming watchdog (e.g. the appearance
        ---     editor's, which re-arms while the player is still editing)
        ---     deliberately did NOT move the phase, so recovering here would
        ---     tear the world down on an actively-editing player; or
        ---   * we already landed in `selection`/`recovering` — recovering again
        ---     would fire `recovering`'s OnEnter teardown on the freshly rebuilt
        ---     lineup with nothing to re-enter selection (a hard soft-lock).
        if W2F.Session and W2F.Session.IsActive and W2F.Session.IsActive()
            and not (W2F.Watchdog.IsArmed and W2F.Watchdog.IsArmed(name))
            and not W2F.Session.Is('selection')
            and not W2F.Session.Is('recovering') then
            W2F.Session.Recover('watchdog_' .. name)
        end
    end)
end

function W2F.Watchdog.Disarm(name)
    if W2F.Watchdog.armed[name] then
        W2F.Watchdog.armed[name] = nil
    end
end

function W2F.Watchdog.DisarmAll()
    for name in pairs(W2F.Watchdog.armed) do
        W2F.Watchdog.armed[name] = nil
    end
end

function W2F.Watchdog.IsArmed(name)
    return W2F.Watchdog.armed[name] ~= nil
end

--- Runs `fn` with a watchdog. If `fn` returns before timeout, the watchdog
--- is automatically disarmed. Returns whatever `fn` returns.
function W2F.Watchdog.WithTimeout(name, timeoutMs, recover, fn)
    if type(recover) == 'function' and fn == nil then
        --- Convenience: (name, ms, fn) form when there is no separate recover.
        fn = recover
        recover = nil
    end
    W2F.Watchdog.Arm(name, timeoutMs, recover)
    local ok, result = pcall(fn)
    W2F.Watchdog.Disarm(name)
    if not ok then error(result) end
    return result
end

--- Snapshot of currently armed watchdogs for `/w2fmc_overlay`.
function W2F.Watchdog.Snapshot()
    local now = nowMs()
    local out = {}
    for name, entry in pairs(W2F.Watchdog.armed) do
        out[#out + 1] = {
            name = name,
            remainingMs = math.max(0, entry.timeoutMs - (now - entry.startedAt)),
            timeoutMs = entry.timeoutMs,
        }
    end
    table.sort(out, function(a, b) return a.remainingMs < b.remainingMs end)
    return out
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Watchdog.DisarmAll()
    end
end)
