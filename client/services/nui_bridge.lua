--- W2F.Nui - NUI Lua<->web bridge with standardized envelopes + payload
--- builders.
---
--- Before the rebuild, the `showSelection` payload was duplicated in 4 sites
--- (main.lua, spawner.lua, bootstrap.lua) and `RegisterNUICallback` returned
--- bare strings (`cb('ok')`) so JS had no way to surface errors. After:
---
---   - W2F.Nui.Send(action, data)           -- thin wrapper, ok envelope
---   - W2F.Nui.BuildSelectionPayload()      -- one source of truth
---   - W2F.Nui.Register(name, fn)           -- fn returns (payload | nil, err)
---     and the response is always `{ ok, error?, payload? }`
---
--- This file does NOT yet replace every send/callback in the codebase; flows
--- are migrated in Phase 3. It just adds the new primitives + the payload
--- builder so duplication can be deleted.

W2F = W2F or {}
W2F.Nui = W2F.Nui or {
    registered = {},
}

local function debug(...)
    if W2F.Debug then W2F.Debug(...) end
end

--- Sends a plain message (`action`, `data`) - identical signature to the
--- legacy `W2F.SendNui` so it's a drop-in replacement.
function W2F.Nui.Send(action, data)
    SendNUIMessage({ action = action, data = data or {} })
end

--- Sends a message with a result envelope. Use for events that have a
--- success/failure semantic ("spawnFailed", "createCharacterResult", ...).
---
---   W2F.Nui.SendResult('createCharacter', false, 'name_taken')
---   W2F.Nui.SendResult('createCharacter', true, nil, { citizenid = '...' })
function W2F.Nui.SendResult(action, ok, error, payload)
    SendNUIMessage({
        action = action,
        data = {
            ok = ok and true or false,
            error = (not ok) and (error or 'unknown') or nil,
            payload = payload,
            --- Mirror at the top level too so consumers that don't read the
            --- envelope still see a `message`.
            message = (not ok) and error or nil,
        },
    })
end

--- Wraps `RegisterNUICallback` with a unified envelope. `fn` must return
--- either:
---   - (payload, nil)         -> { ok = true, payload = payload }
---   - (nil, errorString)     -> { ok = false, error = errorString }
---   - nothing (just side-effects) -> { ok = true }
---
--- Errors thrown inside `fn` are caught and become `{ ok = false, error = ... }`.
function W2F.Nui.Register(name, fn)
    if W2F.Nui.registered[name] then
        debug('NUI callback %s already registered, replacing', name)
    end
    W2F.Nui.registered[name] = true

    RegisterNUICallback(name, function(data, cb)
        local ok, payload, err = pcall(fn, data or {})
        if not ok then
            print(('[w2f-multicharacter] NUI %s error: %s'):format(name, tostring(payload)))
            cb({ ok = false, error = tostring(payload) })
            return
        end
        if err == nil and (payload == nil or type(payload) == 'table') then
            cb({ ok = true, payload = payload })
        elseif err then
            cb({ ok = false, error = tostring(err) })
        else
            --- `payload` is non-table non-nil (string/bool/number). Treat it
            --- as either an error string or a boolean ok value.
            if type(payload) == 'string' and not payload:match('^ok') then
                cb({ ok = false, error = payload })
            else
                cb({ ok = true, payload = payload })
            end
        end
    end)
end

-----------------------------------------------------------------------------
--- Payload builders.
-----------------------------------------------------------------------------

--- Returns the standard `showSelection` payload. Replaces the inline copies
--- in main.lua / spawner.lua / bootstrap.lua.
function W2F.Nui.BuildSelectionPayload()
    local createCfg = Config.CharacterCreation or {}
    return {
        maxSlots = #Config.Scene.pedSlots,
        showControlHints = Config.UI.showControlHints,
        canCreate = createCfg.enabled ~= false,
        createConfig = {
            nationalities = createCfg.nationalities,
            defaultNationality = createCfg.defaultNationality,
            birthdateMin = createCfg.birthdateMin,
            birthdateMax = createCfg.birthdateMax,
        },
    }
end

--- Standard sky-picker payload. `entries` is built by the spawner.
function W2F.Nui.BuildSkySpawnPayload(entries, opts)
    opts = opts or {}
    return {
        entries = entries or {},
        showApartmentSection = opts.showApartmentSection == true,
        defaultSelection = opts.defaultSelection,
        title = opts.title,
        subtitle = opts.subtitle,
    }
end

--- Convenience: emit a NUI toast with a level + message. The web client
--- (post-Phase 5) shows this in the hint bar / a transient toast.
function W2F.Nui.Toast(level, message, durationMs)
    SendNUIMessage({
        action = 'toast',
        data = {
            level = level or 'info',
            message = message or '',
            durationMs = durationMs or 4000,
        },
    })
end
