--- W2F.Diag - opt-in streaming/scene/collision diagnostics.
---
--- All log lines are prefixed `[w2f-multicharacter][stream-debug]` so they
--- can be grepped out of a console dump quickly.
---
--- Flag resolution: every flag is checked through `W2F.Diag.Flag(name)`,
--- which OR's the static `Config.DebugXXX` value with the runtime override
--- in `W2F.Diag.runtime.XXX`. The override is set by `/w2fmc_safemode` and
--- friends so a session can be retried under different conditions without
--- editing config.lua.
---
--- IMPORTANT: With every flag false (the default), this module must be
--- a no-op apart from carrying the `runtime` table. Do NOT add side effects
--- here that fire unconditionally.

W2F = W2F or {}
W2F.Diag = W2F.Diag or {
    runtime = {
        --- Mirrors of Config.DebugXXX. nil = inherit Config; true/false = override.
        Streaming = nil,
        SceneSafeMode = nil,
        DisableBuckets = nil,
        DisablePreviewEmotes = nil,
        ExteriorScene = nil,
        CollisionLogs = nil,
        --- Bisect helpers (/w2fmc_bisect).
        ForceRelaxScene = nil,
        KeepPlayerUnderground = nil,
    },
    --- Last printed snapshot timestamp (so collision-tick logs don't spam).
    lastTickLogAt = 0,
}

local LOG_PREFIX = '[w2f-multicharacter][stream-debug]'

--- True iff the named flag (e.g. 'Streaming') is enabled either via static
--- Config or via runtime override.
function W2F.Diag.Flag(name)
    local rt = W2F.Diag.runtime[name]
    if rt ~= nil then return rt == true end
    return Config and Config['Debug' .. name] == true
end

function W2F.Diag.AnyActive()
    for k, _ in pairs(W2F.Diag.runtime) do
        if W2F.Diag.Flag(k) then return true end
    end
    return false
end

--- Sets multiple runtime overrides at once. Pass `nil` to fall back to
--- Config defaults for that flag.
function W2F.Diag.SetRuntime(overrides)
    if type(overrides) ~= 'table' then return end
    for k, v in pairs(overrides) do
        W2F.Diag.runtime[k] = v
    end
end

function W2F.Diag.ClearRuntime()
    for k, _ in pairs(W2F.Diag.runtime) do
        W2F.Diag.runtime[k] = nil
    end
end

--- Always logs (used for command output). Prefer `W2F.Diag.Log` for gated logs.
function W2F.Diag.Print(fmt, ...)
    if select('#', ...) > 0 then
        print(('%s ' .. fmt):format(LOG_PREFIX, ...))
    else
        print(('%s %s'):format(LOG_PREFIX, tostring(fmt)))
    end
end

--- Gated by a named flag. e.g. `W2F.Diag.Log('Streaming', 'acquire #%d', id)`.
function W2F.Diag.Log(flag, fmt, ...)
    if not W2F.Diag.Flag(flag) then return end
    W2F.Diag.Print(fmt, ...)
end

--- Returns a coords-friendly vec3 representation as a string.
local function fmtVec(v)
    if not v then return 'nil' end
    return ('(%.2f, %.2f, %.2f)'):format(v.x or 0.0, v.y or 0.0, v.z or 0.0)
end

local function safeRoutingBucket()
    if not GetPlayerRoutingBucket then return 'n/a' end
    local ok, bucket = pcall(GetPlayerRoutingBucket, PlayerId())
    if not ok then return 'err' end
    return tostring(bucket)
end

local function countActiveStreamingHandles()
    if not (W2F.Streaming and W2F.Streaming.handles) then return 0, false end
    local n = 0
    for _, h in pairs(W2F.Streaming.handles) do
        if h and not h.released then n = n + 1 end
    end
    return n, W2F.Streaming.threadActive == true
end

local function previewPedSummary()
    local out, n = {}, 0
    for slot, entry in pairs(W2F.State and W2F.State.previewPeds or {}) do
        n = n + 1
        local ped = entry.ped
        local exists = ped and DoesEntityExist(ped) or false
        local coords = exists and GetEntityCoords(ped) or nil
        out[#out + 1] = ('  slot=%s ped=%s exists=%s isEmpty=%s emote=%s coords=%s'):format(
            tostring(slot), tostring(ped), tostring(exists),
            tostring(entry.isEmpty == true), tostring(entry.emote),
            fmtVec(coords))
    end
    if n == 0 then out[#out + 1] = '  (none)' end
    return out, n
end

--- Returns pass/warn/fail checklist for the character selector boot state.
function W2F.Diag.EvaluateSelectionHealth(snapshot)
    snapshot = snapshot or W2F.Diag.Snapshot()
    local checks = {}
    local function add(name, ok, detail)
        checks[#checks + 1] = { name = name, ok = ok, detail = detail }
    end

    add('phase_selection', snapshot.phase == 'selection',
        ('phase=%s'):format(tostring(snapshot.phase)))
    add('camera_live', snapshot.cameraActive == true,
        ('mode=%s active=%s'):format(tostring(snapshot.cameraMode), tostring(snapshot.cameraActive)))
    add('ped_at_lineup',
        (snapshot.pedDistFromFocal or 999) < 2.0,
        ('dist=%.1f'):format(snapshot.pedDistFromFocal or -1))
    add('ped_anchor_z',
        snapshot.pedAnchorZDelta ~= nil and math.abs(snapshot.pedAnchorZDelta) < 1.5,
        ('anchorZDelta=%.2f'):format(snapshot.pedAnchorZDelta or -999))
    add('scene_streaming', snapshot.sceneStreamScene == true and snapshot.sceneStreamReleased ~= true,
        ('handle=%s scene=%s'):format(tostring(snapshot.sceneStreamHandleId), tostring(snapshot.sceneStreamScene)))
    add('collision_loaded', snapshot.collisionLoaded == true, tostring(snapshot.collisionLoaded))
    add('load_scene_ready', snapshot.newLoadSceneLoaded == true, tostring(snapshot.newLoadSceneLoaded))
    add('interior_ready', snapshot.interiorReady == true, ('id=%s pinned=%s'):format(
        tostring(snapshot.interiorId), tostring(snapshot.interiorPinned)))
    add('preview_peds', (snapshot.previewPedCount or 0) > 0,
        ('count=%d'):format(snapshot.previewPedCount or 0))

    if snapshot.phase ~= 'selection' then
        add('world_override_clear', (snapshot.activeStreamingHandles or 0) == 0,
            ('handles=%d scene=%s'):format(snapshot.activeStreamingHandles or -1,
                tostring(snapshot.sceneStreamScene)))
    end

    local fail, warn = 0, 0
    for i = 1, #checks do
        if not checks[i].ok then
            if checks[i].name == 'ped_anchor_z' and snapshot.pedAnchorZDelta
                and math.abs(snapshot.pedAnchorZDelta) < 2.5 then
                warn = warn + 1
            else
                fail = fail + 1
            end
        end
    end

    local status = 'PASS'
    if fail > 0 then status = 'FAIL'
    elseif warn > 0 then status = 'WARN'
    end

    return { status = status, checks = checks, fail = fail, warn = warn }
end

--- Returns a structured snapshot table (not printed). Useful for tests and
--- for the `/w2fmc_diag` command which prints it.
function W2F.Diag.Snapshot()
    local ped = PlayerPedId()
    local pedCoords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    local camCoords = (W2F.Camera and W2F.Camera.GetCurrentCoord)
        and W2F.Camera.GetCurrentCoord() or nil

    local sceneFocal = (Config and Config.GetSceneFocal) and Config.GetSceneFocal() or nil
    local overviewCam = Config and Config.Scene and Config.Scene.overviewCamera or nil

    if W2F.Interior and W2F.Interior.TryPinAt and sceneFocal then
        W2F.Interior.TryPinAt(sceneFocal)
    end

    local sceneHandle = W2F.Characters and W2F.Characters.sceneStreamHandle or nil
    local activeHandles, threadActive = countActiveStreamingHandles()
    local _, previewCount = previewPedSummary()

    local interiorId = (W2F.Interior and W2F.Interior.interiorId) or 0
    local interiorReady = (W2F.Interior and W2F.Interior.IsReady) and W2F.Interior.IsReady() or nil
    local interiorPinned = W2F.Interior and W2F.Interior.pinned == true
    local pedZDelta = nil
    local pedDistFromFocal = nil
    local pedAnchorZDelta = nil
    local anchorCoords = (W2F.Render and W2F.Render.GetPedAnchorCoords)
        and W2F.Render.GetPedAnchorCoords(sceneFocal) or nil
    if pedCoords and sceneFocal then
        pedZDelta = (pedCoords.z or 0.0) - (sceneFocal.z or 0.0)
        local dx = (pedCoords.x or 0.0) - (sceneFocal.x or 0.0)
        local dy = (pedCoords.y or 0.0) - (sceneFocal.y or 0.0)
        pedDistFromFocal = math.sqrt(dx * dx + dy * dy)
    end
    if pedCoords and anchorCoords then
        pedAnchorZDelta = (pedCoords.z or 0.0) - (anchorCoords.z or 0.0)
    end

    return {
        phase = W2F.Session and W2F.Session.phase or 'idle',
        cameraMode = W2F.Camera and W2F.Camera.mode or 'nil',
        cameraActive = W2F.Camera and W2F.Camera.active == true,
        routingBucket = safeRoutingBucket(),
        ped = ped,
        pedCoords = pedCoords,
        cameraCoords = camCoords,
        sceneFocal = sceneFocal,
        overviewCamera = overviewCam,
        sceneStreamHandleId = sceneHandle and sceneHandle.id or nil,
        sceneStreamReleased = sceneHandle and sceneHandle.released == true,
        sceneStreamScene = sceneHandle and sceneHandle.scene == true,
        activeStreamingHandles = activeHandles,
        streamingThreadActive = threadActive,
        previewPedCount = previewCount,
        interiorId = interiorId,
        interiorReady = interiorReady,
        interiorPinned = interiorPinned,
        pedZDeltaFromFocal = pedZDelta,
        pedAnchorZDelta = pedAnchorZDelta,
        pedAnchorCoords = anchorCoords,
        pedDistFromFocal = pedDistFromFocal,
        sessionPhase = W2F.Session and W2F.Session.phase or 'idle',
        isSceneInterior = (W2F.Interior and W2F.Interior.IsSceneInterior) and W2F.Interior.IsSceneInterior() or nil,
        keepSceneSphere = (W2F.Interior and W2F.Interior.ShouldKeepSceneSphere) and W2F.Interior.ShouldKeepSceneSphere() or nil,
        collisionLoaded = (ped and ped ~= 0) and HasCollisionLoadedAroundEntity(ped) or false,
        newLoadSceneActive = (IsNewLoadSceneActive and IsNewLoadSceneActive()) or false,
        newLoadSceneLoaded = (IsNewLoadSceneLoaded and IsNewLoadSceneLoaded()) or false,
        flags = {
            Streaming = W2F.Diag.Flag('Streaming'),
            SceneSafeMode = W2F.Diag.Flag('SceneSafeMode'),
            DisableBuckets = W2F.Diag.Flag('DisableBuckets'),
            DisablePreviewEmotes = W2F.Diag.Flag('DisablePreviewEmotes'),
            ExteriorScene = W2F.Diag.Flag('ExteriorScene'),
            CollisionLogs = W2F.Diag.Flag('CollisionLogs'),
        },
    }
end

--- Pretty-prints the snapshot. Always logs (independent of flag state) — this
--- is the implementation behind `/w2fmc_diag`.
function W2F.Diag.PrintSnapshot()
    local s = W2F.Diag.Snapshot()
    W2F.Diag.Print('=== diagnostic snapshot ===')
    W2F.Diag.Print('phase=%s | cameraMode=%s active=%s | bucket=%s',
        tostring(s.phase), tostring(s.cameraMode), tostring(s.cameraActive),
        tostring(s.routingBucket))
    W2F.Diag.Print('ped=%s coords=%s', tostring(s.ped), fmtVec(s.pedCoords))
    W2F.Diag.Print('pedDistFromFocal=%s pedZDelta=%s anchorZDelta=%s',
        s.pedDistFromFocal and ('%.1f'):format(s.pedDistFromFocal) or 'nil',
        s.pedZDeltaFromFocal and ('%.2f'):format(s.pedZDeltaFromFocal) or 'nil',
        s.pedAnchorZDelta and ('%.2f'):format(s.pedAnchorZDelta) or 'nil')
    W2F.Diag.Print('pedAnchor=%s (want dist<2 anchorZDelta~0 during selection)',
        fmtVec(s.pedAnchorCoords))
    W2F.Diag.Print('cameraCoords=%s', fmtVec(s.cameraCoords))
    W2F.Diag.Print('sceneFocal=%s overviewCamera=%s', fmtVec(s.sceneFocal), fmtVec(s.overviewCamera))
    W2F.Diag.Print('sceneStreamHandle id=%s released=%s scene=%s | activeHandles=%d threadActive=%s',
        tostring(s.sceneStreamHandleId), tostring(s.sceneStreamReleased),
        tostring(s.sceneStreamScene), s.activeStreamingHandles, tostring(s.streamingThreadActive))
    W2F.Diag.Print('interior id=%s ready=%s pinned=%s isSceneInterior=%s keepSceneSphere=%s pedZDelta=%s',
        tostring(s.interiorId), tostring(s.interiorReady), tostring(s.interiorPinned),
        tostring(s.isSceneInterior), tostring(s.keepSceneSphere),
        s.pedZDeltaFromFocal and ('%.2f'):format(s.pedZDeltaFromFocal) or 'nil')
    W2F.Diag.Print('collisionLoaded=%s newLoadSceneActive=%s newLoadSceneLoaded=%s',
        tostring(s.collisionLoaded), tostring(s.newLoadSceneActive),
        tostring(s.newLoadSceneLoaded))
    W2F.Diag.Print('previewPeds count=%d', s.previewPedCount)
    local lines = (previewPedSummary())
    for i = 1, #lines do print(LOG_PREFIX .. ' ' .. lines[i]) end
    W2F.Diag.Print('flags Streaming=%s SafeMode=%s NoBuckets=%s NoEmotes=%s Exterior=%s CollLogs=%s',
        tostring(s.flags.Streaming), tostring(s.flags.SceneSafeMode),
        tostring(s.flags.DisableBuckets), tostring(s.flags.DisablePreviewEmotes),
        tostring(s.flags.ExteriorScene), tostring(s.flags.CollisionLogs))

    if s.phase == 'selection' then
        local health = W2F.Diag.EvaluateSelectionHealth(s)
        W2F.Diag.Print('--- character selector health: %s ---', health.status)
        for i = 1, #health.checks do
            local c = health.checks[i]
            W2F.Diag.Print('  [%s] %s — %s', c.ok and 'ok' or '!!', c.name, c.detail)
        end
    end

    W2F.Diag.Print('=== end snapshot ===')
end

--- Auto-print selector diag (see Config.DebugAutoDiagOnSelection).
function W2F.Diag.MaybeAutoPrintSelection()
    if not (Config.DebugAutoDiagOnSelection or Config.DebugStreaming) then return end
    if not (W2F.Session and W2F.Session.Is('selection')) then return end
    CreateThread(function()
        Wait(2000)
        if W2F.Session and W2F.Session.Is('selection') then
            W2F.Diag.Print('auto diag (character selector boot)')
            W2F.Diag.PrintSnapshot()
        end
    end)
end

--- Throttled tick log used by streaming.lua's per-frame thread when
--- DebugCollisionLogs is set. Logs at most once per ~250ms.
function W2F.Diag.LogCollisionTick(handle)
    if not W2F.Diag.Flag('CollisionLogs') then return end
    local now = GetGameTimer()
    if (now - (W2F.Diag.lastTickLogAt or 0)) < 250 then return end
    W2F.Diag.lastTickLogAt = now

    local ped = PlayerPedId()
    local hCoords = handle and handle.coords or nil
    W2F.Diag.Print('tick handle#%s coords=%s focus=%s scene=%s collisionLoaded=%s sceneActive=%s sceneLoaded=%s',
        tostring(handle and handle.id),
        fmtVec(hCoords),
        tostring(handle and handle.focus),
        tostring(handle and handle.scene),
        tostring((ped and ped ~= 0) and HasCollisionLoadedAroundEntity(ped) or false),
        tostring((IsNewLoadSceneActive and IsNewLoadSceneActive()) or false),
        tostring((IsNewLoadSceneLoaded and IsNewLoadSceneLoaded()) or false))
end

--- Snapshot of the original Config.Scene entries we override when
--- ExteriorScene is enabled. `ApplySceneOverride` populates this; `Restore`
--- restores from it. Stored separately from Config so a hot resource
--- restart can't lose them.
W2F.Diag._sceneBackup = W2F.Diag._sceneBackup or {}

--- Replaces Config.Scene.pedSlots / overviewCamera with the configured
--- exterior fallback (LSIA). Idempotent: a second call after the first
--- doesn't double-stash. Pair with `RestoreSceneOverride` on cleanup.
function W2F.Diag.ApplySceneOverride()
    if not W2F.Diag.Flag('ExteriorScene') then return false end
    local ext = Config and Config.DebugExteriorSceneCoords
    if not ext or not Config or not Config.Scene then return false end

    if not W2F.Diag._sceneBackup.applied then
        W2F.Diag._sceneBackup = {
            applied = true,
            pedSlots = Config.Scene.pedSlots,
            overviewCamera = Config.Scene.overviewCamera,
            autoFacePedsToCamera = Config.Scene.autoFacePedsToCamera,
            lastLocationEmotes = Config.Scene.lastLocationEmotes,
        }
    end
    Config.Scene.pedSlots = ext.pedSlots
    Config.Scene.overviewCamera = ext.overviewCamera
    Config.Scene.autoFacePedsToCamera = true
    Config.Scene.lastLocationEmotes = {}
    W2F.Diag.Print('exterior scene applied: %d slots overview=%s',
        #ext.pedSlots, fmtVec(ext.overviewCamera))
    return true
end

function W2F.Diag.RestoreSceneOverride()
    local b = W2F.Diag._sceneBackup
    if not b or not b.applied then return end
    if Config and Config.Scene then
        Config.Scene.pedSlots = b.pedSlots
        Config.Scene.overviewCamera = b.overviewCamera
        Config.Scene.autoFacePedsToCamera = b.autoFacePedsToCamera
        Config.Scene.lastLocationEmotes = b.lastLocationEmotes
    end
    W2F.Diag._sceneBackup = {}
    W2F.Diag.Print('exterior scene restored')
end

--- Resolves which scene the selector should use right now. Returns the same
--- shape as `Config.Scene` (pedSlots + overviewCamera). Falls back to the
--- normal Config.Scene whenever `ExteriorScene` is off.
function W2F.Diag.ResolveScene()
    if not W2F.Diag.Flag('ExteriorScene') then
        return Config.Scene
    end
    local ext = Config.DebugExteriorSceneCoords
    if not ext then return Config.Scene end
    --- Build a scene table that mirrors Config.Scene's fields so consumers
    --- (camera, characters) don't have to special-case it.
    return setmetatable({
        pedSlots = ext.pedSlots,
        overviewCamera = ext.overviewCamera,
        introDurationMs = Config.Scene.introDurationMs,
        introStartHeight = Config.Scene.introStartHeight,
        skipIntroOnBoot = Config.Scene.skipIntroOnBoot,
        focalHeightOffset = Config.Scene.focalHeightOffset,
        autoFacePedsToCamera = true,
        lastLocationEmotes = {}, -- exterior test = no emotes
    }, { __index = Config.Scene })
end

--- Resolves the streaming radius the safe-mode-aware code paths should use.
--- Defaults to whatever the caller passed in; SafeMode shrinks it to ~40m
--- so a single ASYNC dispatch is enough to populate the immediate area.
function W2F.Diag.ResolveStreamRadius(default)
    if W2F.Diag.Flag('SceneSafeMode') then
        return 40.0
    end
    return default
end
