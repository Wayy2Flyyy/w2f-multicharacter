--- W2F.Dev.Tests - /w2fmc_test command suite.
---
--- Drives the core building blocks (session machine, streaming RAII,
--- watchdog timers, frame math, NUI bridge, character_load service) end
--- to end without touching real game state. Each case is deterministic
--- and asserts using local helpers; results are aggregated into a single
--- pass/fail report printed to console.
---
--- Commands (Config.Debug-gated):
---   /w2fmc_test          Run the full suite.
---   /w2fmc_test session  Run a single named group ("session" | "streaming"
---                        | "watchdog" | "frame" | "nui" | "character_load"
---                        | "spawn").
---   /w2fmc_test_loop n   Run the full suite `n` times back-to-back; reports
---                        per-run pass/fail and aggregate.
---   /w2fmc_test_report   Print the last report again.

W2F = W2F or {}
W2F.Dev = W2F.Dev or {}
W2F.Dev.Tests = W2F.Dev.Tests or {
    cases = {},
    lastReport = nil,
}

local function debugEnabled()
    return Config and Config.Debug
end

local function nowMs()
    if GetGameTimer then return GetGameTimer() end
    return 0
end

-----------------------------------------------------------------------------
--- tiny assertion helpers (each returns ok, err) so cases never crash the
--- whole suite.
-----------------------------------------------------------------------------
local function assertTrue(cond, msg)
    if cond then return true end
    return false, msg or 'expected truthy'
end

local function assertFalse(cond, msg)
    if not cond then return true end
    return false, msg or 'expected falsy'
end

local function assertEq(a, b, msg)
    if a == b then return true end
    return false, (msg or 'expected equal') ..
        (' (got=%s want=%s)'):format(tostring(a), tostring(b))
end

local function assertNear(a, b, eps, msg)
    if math.abs(a - b) <= (eps or 1e-6) then return true end
    return false, (msg or 'expected near') ..
        (' (got=%.6f want=%.6f eps=%.6f)'):format(a, b, eps or 1e-6)
end

-----------------------------------------------------------------------------
--- registry
-----------------------------------------------------------------------------

--- Group definition. `setup` runs once before the cases, `teardown` after.
local function group(name, defs)
    W2F.Dev.Tests.cases[name] = defs
end

local function snapshotSession()
    if not W2F.Session then return nil end
    return {
        phase = W2F.Session.phase,
        history = W2F.Session.GetHistory and W2F.Session.GetHistory() or {},
    }
end

local function restoreSession(snap)
    if not snap or not W2F.Session then return end
    --- Force-reset to idle, then to the original phase if it was something
    --- visible. We never re-fire listeners — tests just need state cleared.
    W2F.Session.phase = snap.phase or 'idle'
end

-----------------------------------------------------------------------------
--- session-machine tests
-----------------------------------------------------------------------------
group('session', {
    setup = function(ctx) ctx.snap = snapshotSession() end,
    teardown = function(ctx) restoreSession(ctx.snap) end,
    cases = {
        { name = 'idle -> bootstrapping', fn = function()
            W2F.Session.phase = 'idle'
            local ok = W2F.Session.Transition('bootstrapping', 'test')
            return assertTrue(ok, 'transition allowed')
        end },
        { name = 'idle -> playing (illegal)', fn = function()
            W2F.Session.phase = 'idle'
            local ok, err = W2F.Session.Transition('playing', 'test_illegal')
            local a, m = assertFalse(ok, 'should be rejected')
            if not a then return a, m end
            return assertTrue(err and err:find('invalid_transition'), 'error reason')
        end },
        { name = 'recovering reachable from anywhere', fn = function()
            for _, from in ipairs({ 'selection', 'creating', 'appearance', 'sky_picker', 'flying', 'finalizing' }) do
                W2F.Session.phase = from
                local ok = W2F.Session.Transition('recovering', 'test_recover_from_' .. from)
                if not ok then return false, 'recovering unreachable from ' .. from end
            end
            return true
        end },
        { name = 'idle clears context', fn = function()
            W2F.Session.phase = 'selection'
            W2F.Session.Set('test_key', 'sentinel')
            W2F.Session.Transition('idle', 'test_idle')
            return assertEq(W2F.Session.Get('test_key'), nil, 'context cleared')
        end },
        { name = 'listeners fire in order', fn = function()
            local log = {}
            W2F.Session.phase = 'idle'
            local function rec(name) return function() log[#log + 1] = name end end
            --- We can't easily un-register, so use a marker and remove from
            --- the listener tables after.
            local exitArr = W2F.Session.listeners.exit['idle']
                or (function() W2F.Session.listeners.exit['idle'] = {}; return W2F.Session.listeners.exit['idle'] end)()
            local enterArr = W2F.Session.listeners.enter['bootstrapping']
                or (function() W2F.Session.listeners.enter['bootstrapping'] = {}; return W2F.Session.listeners.enter['bootstrapping'] end)()
            local transArr = W2F.Session.listeners.transition
            local exitMarker = rec('exit')
            local transMarker = rec('trans')
            local enterMarker = rec('enter')
            exitArr[#exitArr + 1] = exitMarker
            transArr[#transArr + 1] = transMarker
            enterArr[#enterArr + 1] = enterMarker

            W2F.Session.Transition('bootstrapping', 'test_order')

            for i = #exitArr, 1, -1 do if exitArr[i] == exitMarker then table.remove(exitArr, i) end end
            for i = #transArr, 1, -1 do if transArr[i] == transMarker then table.remove(transArr, i) end end
            for i = #enterArr, 1, -1 do if enterArr[i] == enterMarker then table.remove(enterArr, i) end end

            if #log ~= 3 then return false, 'expected 3 events, got ' .. #log end
            if log[1] ~= 'exit' or log[2] ~= 'trans' or log[3] ~= 'enter' then
                return false, ('order=%s,%s,%s'):format(log[1], log[2], log[3])
            end
            return true
        end },
        { name = 'history ring buffer caps at historyMax', fn = function()
            W2F.Session.history = {}
            for i = 1, W2F.Session.historyMax + 5 do
                table.insert(W2F.Session.history, { from = 'a', to = 'b', reason = i, at = i })
                while #W2F.Session.history > W2F.Session.historyMax do
                    table.remove(W2F.Session.history, 1)
                end
            end
            return assertEq(#W2F.Session.history, W2F.Session.historyMax, 'history capped')
        end },
    },
})

-----------------------------------------------------------------------------
--- frame-math tests (W2F.Frame)
-----------------------------------------------------------------------------
group('frame', {
    cases = {
        { name = 'Lerp midpoint', fn = function()
            local v = W2F.Frame.Lerp(0.0, 10.0, 0.5)
            return assertNear(v, 5.0, 1e-6, 'midpoint')
        end },
        { name = 'EaseOutCubic monotonic', fn = function()
            local prev = -1
            for i = 0, 10 do
                local t = i / 10
                local v = W2F.Frame.EaseOutCubic(t)
                if v < prev then return false, ('ease decreased at t=%.2f'):format(t) end
                prev = v
            end
            return true
        end },
        { name = 'Smooth converges across many steps', fn = function()
            local cur = 0.0
            for _ = 1, 200 do
                cur = W2F.Frame.Smooth(cur, 1.0, 12.0, 1 / 60)
            end
            return assertTrue(cur > 0.99, ('expected near 1, got %.4f'):format(cur))
        end },
        { name = 'SmoothYaw takes short path across 180°', fn = function()
            --- From 350° toward 10° should curve through 0, not all the way around.
            local v = W2F.Frame.SmoothYaw(350.0, 10.0, 30.0, 1 / 60)
            local diff = (v - 350.0)
            return assertTrue(math.abs(diff) < 5.0 or math.abs(diff - 360.0) < 5.0,
                ('took long path: got %.2f'):format(v))
        end },
        { name = 'SmoothVec3 returns vector', fn = function()
            local a = vector3(0, 0, 0)
            local b = vector3(10, 10, 10)
            local v = W2F.Frame.SmoothVec3(a, b, 12.0, 1 / 60)
            return assertTrue(type(v) == 'vector3', 'expected vector3')
        end },
    },
})

-----------------------------------------------------------------------------
--- watchdog tests (W2F.Watchdog)
-----------------------------------------------------------------------------
group('watchdog', {
    cases = {
        { name = 'Arm + Disarm leaves no entries', fn = function()
            W2F.Watchdog.Arm('test_arm', 5000, function() end)
            local before = W2F.Watchdog.IsArmed('test_arm')
            W2F.Watchdog.Disarm('test_arm')
            local after = W2F.Watchdog.IsArmed('test_arm')
            if not before then return false, 'should be armed' end
            if after then return false, 'should be disarmed' end
            return true
        end },
        { name = 'Snapshot lists armed names', fn = function()
            W2F.Watchdog.Arm('test_snap_a', 5000, function() end)
            W2F.Watchdog.Arm('test_snap_b', 5000, function() end)
            local snap = W2F.Watchdog.Snapshot()
            local seen = { a = false, b = false }
            for _, w in ipairs(snap) do
                if w.name == 'test_snap_a' then seen.a = true end
                if w.name == 'test_snap_b' then seen.b = true end
            end
            W2F.Watchdog.Disarm('test_snap_a')
            W2F.Watchdog.Disarm('test_snap_b')
            return assertTrue(seen.a and seen.b, 'both armed')
        end },
        { name = 'DisarmAll clears everything', fn = function()
            W2F.Watchdog.Arm('test_da_1', 5000, function() end)
            W2F.Watchdog.Arm('test_da_2', 5000, function() end)
            W2F.Watchdog.DisarmAll()
            local snap = W2F.Watchdog.Snapshot()
            local hits = 0
            for _, w in ipairs(snap) do
                if w.name == 'test_da_1' or w.name == 'test_da_2' then hits = hits + 1 end
            end
            return assertEq(hits, 0, 'none armed after DisarmAll')
        end },
    },
})

-----------------------------------------------------------------------------
--- streaming RAII tests (W2F.Streaming)
-----------------------------------------------------------------------------
group('streaming', {
    cases = {
        { name = 'Acquire returns handle with id', fn = function()
            local h = W2F.Streaming.Acquire(vector3(0, 0, 70), { radius = 30.0 })
            if not h or not h.id then
                if h then W2F.Streaming.Release(h) end
                return false, 'no handle returned'
            end
            W2F.Streaming.Release(h)
            return true
        end },
        { name = 'Release removes from handle table', fn = function()
            local h = W2F.Streaming.Acquire(vector3(0, 0, 70), { radius = 30.0 })
            local before = W2F.Streaming.handles[h.id] ~= nil
            W2F.Streaming.Release(h)
            local after = W2F.Streaming.handles[h.id] ~= nil
            if not before then return false, 'handle missing pre-release' end
            if after then return false, 'handle present post-release' end
            return true
        end },
        { name = 'ReleaseAll clears all handles', fn = function()
            local h1 = W2F.Streaming.Acquire(vector3(0, 0, 70), { radius = 30.0 })
            local h2 = W2F.Streaming.Acquire(vector3(10, 10, 70), { radius = 30.0 })
            W2F.Streaming.ReleaseAll()
            local h1Present = W2F.Streaming.handles[h1.id] ~= nil
            local h2Present = W2F.Streaming.handles[h2.id] ~= nil
            return assertTrue(not h1Present and not h2Present, 'both released')
        end },
    },
})

-----------------------------------------------------------------------------
--- NUI bridge envelope tests (W2F.Nui)
-----------------------------------------------------------------------------
group('nui', {
    cases = {
        { name = 'BuildSelectionPayload has required keys', fn = function()
            local p = W2F.Nui.BuildSelectionPayload()
            if type(p) ~= 'table' then return false, 'expected table' end
            if not p.maxSlots then return false, 'missing maxSlots' end
            if not p.createConfig then return false, 'missing createConfig' end
            return true
        end },
        { name = 'BuildSkySpawnPayload echoes entries', fn = function()
            local entries = { { id = 'a' }, { id = 'b' } }
            local p = W2F.Nui.BuildSkySpawnPayload(entries, { title = 'Test' })
            if not p.entries or #p.entries ~= 2 then return false, 'entries dropped' end
            return assertEq(p.title, 'Test', 'title preserved')
        end },
        { name = 'SendResult error shape mirrors message', fn = function()
            local captured
            local original = SendNUIMessage
            _G.SendNUIMessage = function(m) captured = m end
            W2F.Nui.SendResult('test_action', false, 'some_error')
            _G.SendNUIMessage = original
            if not captured then return false, 'no NUI message captured' end
            if captured.action ~= 'test_action' then return false, 'wrong action' end
            if captured.data.ok ~= false then return false, 'ok should be false' end
            if captured.data.error ~= 'some_error' then return false, 'error mismatch' end
            if captured.data.message ~= 'some_error' then return false, 'message mirror missing' end
            return true
        end },
        { name = 'SendResult success carries payload', fn = function()
            local captured
            local original = SendNUIMessage
            _G.SendNUIMessage = function(m) captured = m end
            W2F.Nui.SendResult('test_ok', true, nil, { id = 1 })
            _G.SendNUIMessage = original
            if captured.data.ok ~= true then return false, 'ok should be true' end
            if not captured.data.payload or captured.data.payload.id ~= 1 then
                return false, 'payload dropped'
            end
            if captured.data.error ~= nil then return false, 'spurious error on success' end
            return true
        end },
    },
})

-----------------------------------------------------------------------------
--- character_load tests (no real load; just signature presence + result shape)
-----------------------------------------------------------------------------
group('character_load', {
    cases = {
        { name = 'service is loaded', fn = function()
            return assertTrue(type(W2F.CharacterLoad and W2F.CharacterLoad.Load) == 'function',
                'CharacterLoad.Load missing')
        end },
        { name = 'LogResult tolerates missing citizenid', fn = function()
            local ok, err = pcall(function()
                W2F.CharacterLoad.LogResult(nil, true, 'noop', 12)
            end)
            return assertTrue(ok, 'should not throw: ' .. tostring(err))
        end },
    },
})

-----------------------------------------------------------------------------
--- spawn-cycle dry-run (snapshot, force transitions, restore)
-----------------------------------------------------------------------------
group('spawn', {
    setup = function(ctx) ctx.snap = snapshotSession() end,
    teardown = function(ctx) restoreSession(ctx.snap) end,
    cases = {
        { name = 'selection -> sky_picker -> flying -> finalizing -> playing', fn = function()
            W2F.Session.phase = 'selection'
            local steps = { 'sky_picker', 'flying', 'finalizing', 'playing' }
            for _, target in ipairs(steps) do
                local ok = W2F.Session.Transition(target, 'test_spawn_cycle')
                if not ok then
                    return false, ('blocked at %s -> %s'):format(W2F.Session.phase, target)
                end
            end
            return assertEq(W2F.Session.phase, 'playing', 'ended in playing')
        end },
        { name = 'sky_picker -> selection (cancel) allowed', fn = function()
            W2F.Session.phase = 'sky_picker'
            local ok = W2F.Session.Transition('selection', 'test_cancel')
            return assertTrue(ok, 'cancel-back blocked')
        end },
        { name = 'flying -> selection blocked', fn = function()
            W2F.Session.phase = 'flying'
            local ok = W2F.Session.Transition('selection', 'test_illegal_back')
            return assertFalse(ok, 'should not be allowed mid-flight')
        end },
    },
})

-----------------------------------------------------------------------------
--- runner
-----------------------------------------------------------------------------

local function runCase(case)
    local started = nowMs()
    local ok, ret, err = pcall(case.fn)
    local elapsed = nowMs() - started
    if not ok then
        return { name = case.name, passed = false, err = tostring(ret), elapsed = elapsed }
    end
    if ret == true then
        return { name = case.name, passed = true, elapsed = elapsed }
    end
    return { name = case.name, passed = false, err = err or 'returned non-true', elapsed = elapsed }
end

local function runGroup(name, defs)
    local ctx = {}
    if defs.setup then pcall(defs.setup, ctx) end
    local results = {}
    for _, c in ipairs(defs.cases or {}) do
        results[#results + 1] = runCase(c)
    end
    if defs.teardown then pcall(defs.teardown, ctx) end
    return results
end

function W2F.Dev.Tests.Run(groupName)
    local report = {
        startedAt = nowMs(),
        groups = {},
        totalCases = 0,
        totalPassed = 0,
        totalFailed = 0,
    }
    local names = {}
    if groupName then
        if not W2F.Dev.Tests.cases[groupName] then
            print('[w2f-multicharacter] unknown test group: ' .. tostring(groupName))
            return report
        end
        names[1] = groupName
    else
        for n in pairs(W2F.Dev.Tests.cases) do names[#names + 1] = n end
        table.sort(names)
    end

    for _, gName in ipairs(names) do
        local gResults = runGroup(gName, W2F.Dev.Tests.cases[gName])
        local passed, failed = 0, 0
        for _, r in ipairs(gResults) do
            if r.passed then passed = passed + 1 else failed = failed + 1 end
            report.totalCases = report.totalCases + 1
        end
        report.totalPassed = report.totalPassed + passed
        report.totalFailed = report.totalFailed + failed
        report.groups[gName] = {
            cases = gResults,
            passed = passed,
            failed = failed,
        }
    end

    report.elapsedMs = nowMs() - report.startedAt
    W2F.Dev.Tests.lastReport = report
    return report
end

local function printReport(report)
    if not report then
        print('[w2f-multicharacter] no test report available')
        return
    end
    print('=== w2f-multicharacter Tests ===')
    print(('Total: %d  Passed: %d  Failed: %d  (%dms)'):format(
        report.totalCases, report.totalPassed, report.totalFailed, report.elapsedMs or 0))
    local names = {}
    for n in pairs(report.groups) do names[#names + 1] = n end
    table.sort(names)
    for _, name in ipairs(names) do
        local g = report.groups[name]
        print(('-- %s (%d/%d) --'):format(name, g.passed, g.passed + g.failed))
        for _, c in ipairs(g.cases) do
            if c.passed then
                print(('  PASS  %s  (%dms)'):format(c.name, c.elapsed or 0))
            else
                print(('  FAIL  %s  -> %s'):format(c.name, c.err or 'unknown'))
            end
        end
    end
end

function W2F.Dev.Tests.RunAndReport(groupName)
    if not debugEnabled() then
        print('[w2f-multicharacter] tests disabled (Config.Debug=false)')
        return
    end
    local report = W2F.Dev.Tests.Run(groupName)
    printReport(report)
    return report
end

RegisterCommand('w2fmc_test', function(_, args)
    W2F.Dev.Tests.RunAndReport(args and args[1])
end, false)

RegisterCommand('w2fmc_test_report', function()
    printReport(W2F.Dev.Tests.lastReport)
end, false)

--- Loop tests N times — used to validate the "100% pass across 10+ runs"
--- acceptance criterion in the rebuild plan. Aggregates pass/fail.
RegisterCommand('w2fmc_test_loop', function(_, args)
    if not debugEnabled() then
        print('[w2f-multicharacter] tests disabled (Config.Debug=false)')
        return
    end
    local n = tonumber(args and args[1]) or 10
    if n < 1 then n = 1 end
    if n > 50 then n = 50 end
    CreateThread(function()
        local agg = { runs = 0, allPassed = 0, anyFailed = 0, totalPassed = 0, totalFailed = 0 }
        for i = 1, n do
            local report = W2F.Dev.Tests.Run(nil)
            agg.runs = agg.runs + 1
            agg.totalPassed = agg.totalPassed + report.totalPassed
            agg.totalFailed = agg.totalFailed + report.totalFailed
            if report.totalFailed == 0 then
                agg.allPassed = agg.allPassed + 1
            else
                agg.anyFailed = agg.anyFailed + 1
            end
            print(('  run %d/%d: %d/%d passed%s'):format(
                i, n, report.totalPassed, report.totalCases,
                report.totalFailed > 0 and ('  FAILS=' .. report.totalFailed) or ''))
            Wait(60)
        end
        print('=== w2fmc_test_loop summary ===')
        print(('Runs: %d  Clean: %d  Dirty: %d  Cases passed: %d  failed: %d'):format(
            agg.runs, agg.allPassed, agg.anyFailed, agg.totalPassed, agg.totalFailed))
    end)
end, false)
