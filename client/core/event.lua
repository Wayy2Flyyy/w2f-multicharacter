--- W2F.Event - internal pub/sub bus.
---
--- Sits next to `W2F.Session` and is used for non-state-machine signals
--- (hover changed, click, spawn outcome, NUI ready, etc) so flow modules
--- don't need to know about each other or expose globals.
---
--- Use `W2F.Session.OnEnter/OnExit` for state-machine events; use this for
--- everything else. Subscribers are called synchronously in registration
--- order; errors are caught and logged so a bad subscriber never wedges
--- the bus.

W2F = W2F or {}
W2F.Event = W2F.Event or {
    subscribers = {},
}

local function bucket(name)
    local b = W2F.Event.subscribers[name]
    if not b then
        b = {}
        W2F.Event.subscribers[name] = b
    end
    return b
end

--- Register a subscriber. Returns an opaque token usable with `Off`.
function W2F.Event.On(name, fn)
    if type(fn) ~= 'function' then
        error('W2F.Event.On: handler must be a function')
    end
    local b = bucket(name)
    b[#b + 1] = fn
    return fn
end

--- One-shot subscriber: fires once then unregisters.
function W2F.Event.Once(name, fn)
    local wrapped
    wrapped = function(...)
        W2F.Event.Off(name, wrapped)
        return fn(...)
    end
    return W2F.Event.On(name, wrapped)
end

function W2F.Event.Off(name, token)
    local b = W2F.Event.subscribers[name]
    if not b then return end
    for i = #b, 1, -1 do
        if b[i] == token then
            table.remove(b, i)
        end
    end
end

function W2F.Event.OffAll(name)
    W2F.Event.subscribers[name] = nil
end

--- Synchronously dispatches `name` to all subscribers. Subscriber errors
--- are caught and printed; one bad subscriber never blocks the rest.
function W2F.Event.Emit(name, ...)
    local b = W2F.Event.subscribers[name]
    if not b or #b == 0 then return end
    --- Iterate over a snapshot so subscribers that unsubscribe themselves
    --- (via `Once`) don't trip the iterator.
    local snapshot = {}
    for i = 1, #b do snapshot[i] = b[i] end
    for i = 1, #snapshot do
        local ok, err = pcall(snapshot[i], ...)
        if not ok then
            print(('[w2f-multicharacter] event %s subscriber error: %s')
                :format(tostring(name), tostring(err)))
        end
    end
end

--- Wipes every subscriber. Called on resource stop.
function W2F.Event.Reset()
    W2F.Event.subscribers = {}
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Event.Reset()
    end
end)
