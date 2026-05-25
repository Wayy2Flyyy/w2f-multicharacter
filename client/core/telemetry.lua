--- W2F.Telemetry - span timings + event ring + on-screen debug overlay.
---
--- - `Span(name, fn)` wraps a closure and records elapsed ms.
--- - `Record(event, data)` appends to a ring buffer with phase + timestamp.
--- - `/w2fmc_telemetry` prints aggregate stats + the latest events.
--- - `/w2fmc_overlay` toggles an on-screen DrawText2D overlay (phase,
---   last 12 transitions, armed watchdogs, last failure).
---
--- All disabled unless `Config.Debug` is true.

W2F = W2F or {}
W2F.Telemetry = W2F.Telemetry or {
    spans = {},
    events = {},
    eventMax = 128,
    failures = {},
    failureMax = 16,
    overlay = false,
}

local function nowMs()
    return GetGameTimer()
end

local function debugEnabled()
    return Config and Config.Debug
end

--- Records a single elapsed-time sample under `name`.
function W2F.Telemetry.RecordSpan(name, elapsedMs)
    local bucket = W2F.Telemetry.spans[name]
    if not bucket then
        bucket = { count = 0, total = 0, min = math.huge, max = -math.huge, last = 0 }
        W2F.Telemetry.spans[name] = bucket
    end
    bucket.count = bucket.count + 1
    bucket.total = bucket.total + elapsedMs
    bucket.last = elapsedMs
    if elapsedMs < bucket.min then bucket.min = elapsedMs end
    if elapsedMs > bucket.max then bucket.max = elapsedMs end
end

--- Wraps `fn`, records elapsed ms under `name`, returns whatever `fn` returns.
function W2F.Telemetry.Span(name, fn)
    if not debugEnabled() then return fn() end
    local started = nowMs()
    local ok, a, b, c = pcall(fn)
    local elapsed = nowMs() - started
    W2F.Telemetry.RecordSpan(name, elapsed)
    if not ok then
        W2F.Telemetry.RecordFailure(name, a)
        error(a)
    end
    return a, b, c
end

--- Appends `event` + `data` to the ring buffer.
function W2F.Telemetry.Record(event, data)
    if not debugEnabled() then return end
    local entry = {
        at = nowMs(),
        phase = (W2F.Session and W2F.Session.phase) or 'idle',
        event = event,
        data = data,
    }
    local r = W2F.Telemetry.events
    r[#r + 1] = entry
    while #r > W2F.Telemetry.eventMax do
        table.remove(r, 1)
    end
end

--- Logs a failure for the overlay's "last failure" pane.
function W2F.Telemetry.RecordFailure(source, err)
    local f = W2F.Telemetry.failures
    f[#f + 1] = {
        at = nowMs(),
        phase = (W2F.Session and W2F.Session.phase) or 'idle',
        source = source,
        err = tostring(err),
    }
    while #f > W2F.Telemetry.failureMax do
        table.remove(f, 1)
    end
end

function W2F.Telemetry.GetSpans()
    local out = {}
    for name, b in pairs(W2F.Telemetry.spans) do
        out[name] = {
            count = b.count,
            avg = b.total / math.max(1, b.count),
            min = b.min == math.huge and 0 or b.min,
            max = b.max == -math.huge and 0 or b.max,
            last = b.last,
        }
    end
    return out
end

function W2F.Telemetry.Reset()
    W2F.Telemetry.spans = {}
    W2F.Telemetry.events = {}
    W2F.Telemetry.failures = {}
end

-----------------------------------------------------------------------------
--- /w2fmc_telemetry — prints spans + last events + last failures to console.
-----------------------------------------------------------------------------
RegisterCommand('w2fmc_telemetry', function()
    if not debugEnabled() then
        print('[w2f-multicharacter] telemetry disabled (Config.Debug=false)')
        return
    end

    print('=== w2f-multicharacter Telemetry ===')
    print('Phase: ' .. tostring(W2F.Session and W2F.Session.phase))

    print('-- Spans --')
    local spans = W2F.Telemetry.GetSpans()
    local names = {}
    for n in pairs(spans) do names[#names + 1] = n end
    table.sort(names)
    for _, name in ipairs(names) do
        local s = spans[name]
        print(('  %-32s n=%d avg=%.1fms min=%.0f max=%.0f last=%.0f')
            :format(name, s.count, s.avg, s.min, s.max, s.last))
    end

    print('-- Watchdog trips: ' .. tostring(W2F.Watchdog and W2F.Watchdog.tripCount or 0))

    print('-- Last failures --')
    local f = W2F.Telemetry.failures
    for i = math.max(1, #f - 5), #f do
        local e = f[i]
        if e then
            print(('  [%dms phase=%s] %s: %s'):format(e.at, e.phase, e.source, e.err))
        end
    end

    print('-- Transition history --')
    if W2F.Session and W2F.Session.GetHistory then
        local h = W2F.Session.GetHistory()
        for i = math.max(1, #h - 8), #h do
            local e = h[i]
            print(('  [%dms] %s -> %s (%s)'):format(e.at, e.from, e.to, tostring(e.reason)))
        end
    end
end, false)

-----------------------------------------------------------------------------
--- /w2fmc_overlay — on-screen overlay showing phase, transitions, watchdogs.
-----------------------------------------------------------------------------
local overlayThread = nil
local function drawText(x, y, scale, text, alpha)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(255, 255, 255, alpha or 220)
    SetTextOutline()
    SetTextDropShadow()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

local function drawBackground(x, y, w, h)
    DrawRect(x + w * 0.5, y + h * 0.5, w, h, 0, 0, 0, 160)
end

local function runOverlay()
    while W2F.Telemetry.overlay do
        --- Background panel for readability.
        drawBackground(0.005, 0.28, 0.35, 0.36)

        local y = 0.30
        local phase = tostring(W2F.Session and W2F.Session.phase)
        local fps = math.floor(1.0 / math.max(0.0001, GetFrameTime() or (1 / 60)))
        local wdCount = W2F.Watchdog and #(W2F.Watchdog.Snapshot()) or 0
        local trips = W2F.Watchdog and W2F.Watchdog.tripCount or 0

        drawText(0.01, y, 0.34,
            ('w2fmc | phase=%s | fps=%d | wd=%d trips=%d'):format(phase, fps, wdCount, trips))
        y = y + 0.026

        --- Streaming + camera mode snapshot.
        local cam = W2F.Camera and W2F.Camera.mode or '?'
        local streams = (W2F.Streaming and W2F.Streaming.handles) and 0 or 0
        if W2F.Streaming and W2F.Streaming.handles then
            for _ in pairs(W2F.Streaming.handles) do streams = streams + 1 end
        end
        drawText(0.01, y, 0.27, ('  cam=%s  streams=%d  cinematic=%s'):format(
            cam, streams, tostring(W2F.Camera and W2F.Camera.cinematic ~= nil)))
        y = y + 0.024

        --- Transition history (last 6 to keep panel tight).
        drawText(0.01, y, 0.27, 'transitions:')
        y = y + 0.022
        local hist = (W2F.Session and W2F.Session.GetHistory and W2F.Session.GetHistory()) or {}
        for i = math.max(1, #hist - 5), #hist do
            local e = hist[i]
            if e then
                drawText(0.012, y, 0.25, ('  %s -> %s (%s)'):format(e.from, e.to, tostring(e.reason)))
                y = y + 0.020
            end
        end

        --- Armed watchdog timers.
        local wds = (W2F.Watchdog and W2F.Watchdog.Snapshot()) or {}
        if #wds > 0 then
            drawText(0.01, y, 0.27, 'armed watchdogs:')
            y = y + 0.022
            for i = 1, math.min(#wds, 4) do
                local w = wds[i]
                drawText(0.012, y, 0.25, ('  %s (%dms remaining)'):format(w.name, w.remainingMs))
                y = y + 0.020
            end
        end

        --- Last failure.
        local f = W2F.Telemetry.failures
        local last = f[#f]
        if last then
            drawText(0.01, y, 0.27, ('last fail [%s]: %s'):format(last.source, last.err), 200)
            y = y + 0.022
        end

        --- Last spans (top 4 by recent activity).
        local spans = W2F.Telemetry.GetSpans()
        local rows, names = {}, {}
        for n in pairs(spans) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do rows[#rows + 1] = { name = n, span = spans[n] } end
        if #rows > 0 then
            drawText(0.01, y, 0.27, 'spans (last):')
            y = y + 0.022
            for i = 1, math.min(#rows, 4) do
                local r = rows[i]
                drawText(0.012, y, 0.24,
                    ('  %s n=%d avg=%.0fms last=%.0fms'):format(
                        r.name, r.span.count, r.span.avg, r.span.last))
                y = y + 0.019
            end
        end

        Wait(0)
    end
    overlayThread = nil
end

RegisterCommand('w2fmc_overlay', function()
    if not debugEnabled() then
        print('[w2f-multicharacter] overlay disabled (Config.Debug=false)')
        return
    end
    W2F.Telemetry.overlay = not W2F.Telemetry.overlay
    if W2F.Telemetry.overlay and not overlayThread then
        overlayThread = CreateThread(runOverlay)
        print('[w2f-multicharacter] overlay enabled')
    else
        print('[w2f-multicharacter] overlay disabled')
    end
end, false)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Telemetry.overlay = false
    end
end)
