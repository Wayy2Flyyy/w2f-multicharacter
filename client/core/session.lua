--- W2F.Session - canonical state machine for the multichar flow.
---
--- Replaces the ~8 parallel booleans (`isInSelection`, `isCreatingCharacter`,
--- `isSkySpawnMode`, `isSpawning`, `isTransitioningToSky`, `Selection.active`,
--- `Creator.active`, `Bootstrap.opening`) with a single canonical phase plus
--- a strict transition table. Legacy flags are kept in sync via an adapter
--- listener installed at the bottom of this file so older modules continue
--- to work while flows migrate to `W2F.Session`.
---
--- Phases:
---   idle           -> nothing active; player is in the world or fully logged out
---   bootstrapping  -> session start / re-entry; waiting on deps + NUI + chars
---   selection      -> lineup interior; peds drawn, hover + click enabled
---   creating       -> NUI registration form open (name / DOB)
---   appearance     -> illenium-appearance editor open
---   sky_picker     -> sky camera + spawn cards / apartment cards visible
---   flying         -> fly-to-spawn cinematic running
---   finalizing     -> character load + post-spawn cleanup running
---   playing        -> handed off to the framework HUD; resource quiescent
---   recovering     -> failure handler; fades in + restores controls
---
--- Usage:
---   local ok, err = W2F.Session.Transition('selection', 'bootstrap_done')
---   W2F.Session.OnEnter('flying', function(from, to, reason, ctx) ... end)
---   if W2F.Session.In('flying', 'finalizing') then ... end

W2F = W2F or {}

local function noopTimer()
    return 0
end
local function safeGetTimer()
    if GetGameTimer then return GetGameTimer() end
    return noopTimer()
end

local TRANSITIONS = {
    idle = {
        bootstrapping = true,
        --- Direct open path used by console commands (/w2fmc_open) and the
        --- `openSelection` net event that fires after qbx logout.
        selection = true,
        recovering = true,
    },
    bootstrapping = {
        selection = true,
        idle = true,
        recovering = true,
    },
    selection = {
        creating = true,
        sky_picker = true,
        recovering = true,
        idle = true,
        bootstrapping = true,
    },
    creating = {
        appearance = true,
        selection = true,
        --- Direct-to-apartment flow: skip the appearance editor entirely and
        --- route from the create form straight into the apartment claim,
        --- which routes through `finalizing -> playing`. The clothing editor
        --- opens INSIDE the apartment via qbx_properties' chain.
        finalizing = true,
        recovering = true,
        idle = true,
    },
    appearance = {
        sky_picker = true,
        selection = true,
        --- Direct-to-apartment flow: after `createCharacter` succeeds, the
        --- creator skips the spawn picker and feeds the new character
        --- straight into the apartment claim, which routes through
        --- `finalizing -> playing`. The clothing editor opens INSIDE the
        --- apartment via qbx_properties' chain.
        finalizing = true,
        recovering = true,
        idle = true,
    },
    sky_picker = {
        flying = true,
        finalizing = true,
        selection = true,
        recovering = true,
        idle = true,
    },
    flying = {
        finalizing = true,
        recovering = true,
        idle = true,
    },
    finalizing = {
        playing = true,
        recovering = true,
        idle = true,
    },
    playing = {
        idle = true,
        bootstrapping = true,
    },
    recovering = {
        selection = true,
        idle = true,
        bootstrapping = true,
    },
}

W2F.Session = {
    phase = 'idle',
    previousPhase = nil,
    transitionAt = 0,
    --- Free-form scratchpad for per-run data (selected character, pending
    --- new citizenid, etc). Cleared automatically on transition to idle.
    context = {},
    transitions = TRANSITIONS,
    listeners = {
        enter = {},
        exit = {},
        transition = {},
    },
    --- Ring buffer of the last 32 transitions for telemetry / `/w2fmc_overlay`.
    history = {},
    historyMax = 32,
}

local function fire(listeners, ...)
    if not listeners then return end
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], ...)
        if not ok then
            print(('[w2f-multicharacter] session listener error: %s'):format(tostring(err)))
        end
    end
end

local function recordHistory(from, to, reason)
    local entry = {
        from = from,
        to = to,
        reason = reason,
        at = safeGetTimer(),
    }
    local h = W2F.Session.history
    h[#h + 1] = entry
    while #h > W2F.Session.historyMax do
        table.remove(h, 1)
    end
end

function W2F.Session.OnEnter(phase, fn)
    local list = W2F.Session.listeners.enter
    list[phase] = list[phase] or {}
    local arr = list[phase]
    arr[#arr + 1] = fn
end

function W2F.Session.OnExit(phase, fn)
    local list = W2F.Session.listeners.exit
    list[phase] = list[phase] or {}
    local arr = list[phase]
    arr[#arr + 1] = fn
end

--- Fires on EVERY transition; `fn(from, to, reason, ctx)`.
function W2F.Session.OnTransition(fn)
    local arr = W2F.Session.listeners.transition
    arr[#arr + 1] = fn
end

--- Attempts to move to `target`. Returns (true) on success or
--- (false, errorReason) when the transition isn't permitted.
---
--- `recovering` and `idle` are always allowed from any phase (escape hatches).
---
--- `ctx` is optional; when provided its keys are merged into `Session.context`
--- BEFORE listeners fire, so listeners can read the new context immediately.
function W2F.Session.Transition(target, reason, ctx)
    local from = W2F.Session.phase
    if target == from then
        --- Allow same-state "ping" so callers can merge context without
        --- worrying about whether they're already in the right phase.
        if ctx then
            for k, v in pairs(ctx) do
                W2F.Session.context[k] = v
            end
        end
        return true, 'noop'
    end

    local valid = (target == 'recovering' or target == 'idle')
        or (TRANSITIONS[from] and TRANSITIONS[from][target] == true)
    if not valid then
        local err = ('invalid_transition: %s -> %s (reason=%s)'):format(
            tostring(from), tostring(target), tostring(reason))
        print('[w2f-multicharacter] ' .. err)
        return false, err
    end

    W2F.Session.previousPhase = from
    W2F.Session.phase = target
    W2F.Session.transitionAt = safeGetTimer()

    if ctx then
        for k, v in pairs(ctx) do
            W2F.Session.context[k] = v
        end
    end

    --- Clear context when returning to a "fully reset" state so leftover
    --- selection data can't leak across sessions.
    if target == 'idle' then
        W2F.Session.context = {}
    end

    recordHistory(from, target, reason)

    --- Telemetry: record the transition + per-phase entry time so the
    --- overlay can show the time spent in each phase.
    if W2F.Telemetry and W2F.Telemetry.Record then
        W2F.Telemetry.Record('session_transition', {
            from = from, to = target, reason = reason,
        })
    end

    --- Listener order: exit(from) -> transition(any) -> enter(to).
    --- Errors inside listeners are caught and logged so a bad subscriber
    --- can never wedge the entire state machine.
    fire(W2F.Session.listeners.exit[from], from, target, reason, W2F.Session.context)
    fire(W2F.Session.listeners.transition, from, target, reason, W2F.Session.context)
    fire(W2F.Session.listeners.enter[target], from, target, reason, W2F.Session.context)

    return true
end

function W2F.Session.Is(phase)
    return W2F.Session.phase == phase
end

--- Variadic check: `Session.In('flying', 'finalizing')`.
function W2F.Session.In(...)
    local cur = W2F.Session.phase
    for i = 1, select('#', ...) do
        if cur == (select(i, ...)) then return true end
    end
    return false
end

--- True iff we're anywhere inside the multichar flow (not idle or playing).
function W2F.Session.IsActive()
    local p = W2F.Session.phase
    return p ~= 'idle' and p ~= 'playing'
end

--- Convenience: the spawner / camera ask this a lot. True when spawn cinematic
--- or post-spawn cleanup is running. Replaces the standalone `isSpawning` flag.
function W2F.Session.IsSpawning()
    local p = W2F.Session.phase
    return p == 'flying' or p == 'finalizing'
end

--- Replaces `isInSelection` reads. Covers the entire visible selection /
--- creator / spawn picker / cinematic window (anything that owns the screen).
function W2F.Session.OwnsScreen()
    local p = W2F.Session.phase
    return p == 'bootstrapping'
        or p == 'selection'
        or p == 'creating'
        or p == 'appearance'
        or p == 'sky_picker'
        or p == 'flying'
        or p == 'finalizing'
        or p == 'recovering'
end

--- Context helpers (preferred over poking at `W2F.State.*`).
function W2F.Session.Set(key, value)
    W2F.Session.context[key] = value
end

function W2F.Session.Get(key, default)
    local v = W2F.Session.context[key]
    if v == nil then return default end
    return v
end

--- Soft-reset: jump to `recovering`, listeners will fade in + restore controls.
function W2F.Session.Recover(reason)
    return W2F.Session.Transition('recovering', reason)
end

--- Hard-reset: snap back to `idle`. Use sparingly (resource stop / fatal).
function W2F.Session.HardReset(reason)
    W2F.Session.Transition('idle', reason or 'hard_reset')
end

--- Returns a copy of the transition history for telemetry / debugging.
function W2F.Session.GetHistory()
    local out, src = {}, W2F.Session.history
    for i = 1, #src do
        out[i] = {
            from = src[i].from,
            to = src[i].to,
            reason = src[i].reason,
            at = src[i].at,
        }
    end
    return out
end

-----------------------------------------------------------------------------
--- Legacy-flag adapter.
---
--- Every prior boolean (`W2F.State.isInSelection`, `W2F.Selection.active`,
--- `W2F.Creator.active`, etc.) is derived from `Session.phase` here. Once
--- the rebuild migrates every consumer to call `Session.In(...)` directly,
--- this adapter can be deleted.
-----------------------------------------------------------------------------
W2F.Session.OnTransition(function(_from, to, _reason, _ctx)
    local s = W2F.State
    if s then
        s.isInSelection = (to == 'selection' or to == 'creating'
            or to == 'appearance' or to == 'sky_picker'
            or to == 'flying' or to == 'finalizing'
            or to == 'recovering')
        s.isCreatingCharacter = (to == 'creating' or to == 'appearance')
        s.isCreatePanelOpen = (to == 'creating')
        s.isSkySpawnMode = (to == 'sky_picker')
        s.isSpawning = (to == 'flying' or to == 'finalizing')
        s.isTransitioningToSky = (W2F.Session.previousPhase == 'selection' and to == 'sky_picker')
    end

    W2F.Selection = W2F.Selection or {}
    W2F.Selection.active = (to ~= 'idle' and to ~= 'playing')

    W2F.Creator = W2F.Creator or {}
    W2F.Creator.active = (to == 'creating' or to == 'appearance')

    W2F.Bootstrap = W2F.Bootstrap or {}
    W2F.Bootstrap.opening = (to == 'bootstrapping')
end)
