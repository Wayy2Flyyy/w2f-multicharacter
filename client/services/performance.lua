--- W2F.Performance — hardware-agnostic preset + adaptive frame governor.
---
--- Resolves a single effective tuning table at selection entry so weak GPUs,
--- low-end CPUs, and 144 Hz monitors all get appropriate native call rates
--- without server owners hand-tuning a dozen config keys.

W2F = W2F or {}
W2F.Performance = W2F.Performance or {
    active = false,
    preset = 'universal',
    adaptive = true,
    effective = nil,
    --- Runtime-adjusted values (adaptive governor may bump these up).
    _loopMs = 20,
    _hoverMs = 20,
    _frameEma = 1 / 60,
}

local PRESETS = {
    --- Maximum compatibility: lowest native volume, still responsive UI.
    universal = {
        streamKeepaliveMs = 750,
        streamFocusRefreshMs = 4000,
        selectionLoopMs = 20,
        hoverIntervalMs = 20,
        integrityCheckMs = 8000,
        hudUpdateMs = 33,
        cameraIdleDrift = false,
        pedSampleHeights = { 0.68, 1.05 },
        useAlphaHighlightFallback = true,
    },
    balanced = {
        streamKeepaliveMs = 500,
        streamFocusRefreshMs = 2500,
        selectionLoopMs = 16,
        hoverIntervalMs = 16,
        integrityCheckMs = 5000,
        hudUpdateMs = 16,
        cameraIdleDrift = false,
        pedSampleHeights = { 0.35, 0.68, 1.05 },
        useAlphaHighlightFallback = false,
    },
    high = {
        streamKeepaliveMs = 250,
        streamFocusRefreshMs = 1500,
        selectionLoopMs = 8,
        hoverIntervalMs = 8,
        integrityCheckMs = 4000,
        hudUpdateMs = 8,
        cameraIdleDrift = true,
        pedSampleHeights = { 0.35, 0.68, 1.05 },
        useAlphaHighlightFallback = false,
    },
}

local function baseCfg()
    return Config.Performance or {}
end

local function resolvePresetName()
    local name = baseCfg().preset or 'universal'
    if name == 'auto' then
        --- Start conservative; adaptive governor loosens if headroom exists.
        return 'universal'
    end
    if not PRESETS[name] then
        return 'universal'
    end
    return name
end

local function mergeEffective(presetName)
    local preset = PRESETS[presetName] or PRESETS.universal
    local cfg = baseCfg()
    local out = {}

    for k, v in pairs(preset) do
        out[k] = v
    end

    --- Explicit Config.Performance overrides win over preset defaults.
    if cfg.streamKeepaliveMs then out.streamKeepaliveMs = cfg.streamKeepaliveMs end
    if cfg.streamFocusRefreshMs then out.streamFocusRefreshMs = cfg.streamFocusRefreshMs end
    if cfg.selectionLoopMs then out.selectionLoopMs = cfg.selectionLoopMs end
    if cfg.hoverIntervalMs then out.hoverIntervalMs = cfg.hoverIntervalMs end
    if cfg.integrityCheckMs then out.integrityCheckMs = cfg.integrityCheckMs end
    if cfg.hudUpdateMs then out.hudUpdateMs = cfg.hudUpdateMs end
    if cfg.cameraIdleDrift ~= nil then out.cameraIdleDrift = cfg.cameraIdleDrift end
    if cfg.pedSampleHeights then out.pedSampleHeights = cfg.pedSampleHeights end
    if cfg.useAlphaHighlightFallback ~= nil then out.useAlphaHighlightFallback = cfg.useAlphaHighlightFallback end

    --- Default false: MLO lineups require keepSceneSphere (see interior config).
    out.relaxStreamAfterLoad = cfg.relaxStreamAfterLoad == true
    out.adaptive = cfg.adaptive ~= false
    out.preset = presetName

    return out
end

--- Call once when entering character selection.
function W2F.Performance.Activate()
    local presetName = resolvePresetName()
    W2F.Performance.preset = presetName
    W2F.Performance.effective = mergeEffective(presetName)
    W2F.Performance.active = true

    local e = W2F.Performance.effective
    W2F.Performance._loopMs = e.selectionLoopMs or 20
    W2F.Performance._hoverMs = e.hoverIntervalMs or 20
    W2F.Performance._frameEma = 1 / 60

    if e.useAlphaHighlightFallback and Config.Highlight then
        W2F.Performance._savedHighlightEnabled = Config.Highlight.enabled
        Config.Highlight.enabled = false
    end

    if W2F.Debug then
        W2F.Debug('Performance.Activate preset=%s loop=%dms hover=%dms',
            presetName, W2F.Performance._loopMs, W2F.Performance._hoverMs)
    end
end

function W2F.Performance.Deactivate()
    if W2F.Performance._savedHighlightEnabled ~= nil and Config.Highlight then
        Config.Highlight.enabled = W2F.Performance._savedHighlightEnabled
        W2F.Performance._savedHighlightEnabled = nil
    end
    W2F.Performance.active = false
    W2F.Performance.effective = nil
end

--- Returns resolved tuning value (preset + overrides + adaptive runtime).
function W2F.Performance.Get(key)
    if W2F.Performance.active and W2F.Performance.effective then
        if key == 'selectionLoopMs' then
            return W2F.Performance._loopMs
        end
        if key == 'hoverIntervalMs' then
            return W2F.Performance._hoverMs
        end
        local v = W2F.Performance.effective[key]
        if v ~= nil then return v end
    end
    local cfg = baseCfg()
    if cfg[key] ~= nil then return cfg[key] end
    local fallback = PRESETS.universal[key]
    if fallback ~= nil then return fallback end
    return nil
end

--- Feed once per interaction tick; backs off intervals when FPS dips.
function W2F.Performance.SampleFrame()
    if not W2F.Performance.active then return end
    if W2F.Performance.effective and W2F.Performance.effective.adaptive == false then return end
    if baseCfg().adaptive == false then return end

    local dt = GetFrameTime()
    if not dt or dt <= 0 then return end

    local ema = W2F.Performance._frameEma
    ema = ema + (dt - ema) * 0.08
    W2F.Performance._frameEma = ema

    --- Below ~45 FPS: widen tick intervals (cap so UI stays usable).
    if ema > 0.022 then
        W2F.Performance._loopMs = math.min(33, W2F.Performance._loopMs + 1)
        W2F.Performance._hoverMs = math.min(50, W2F.Performance._hoverMs + 2)
    elseif ema < 0.014 and W2F.Performance.preset == 'high' then
        --- High preset only: recover toward configured targets when headroom exists.
        local e = W2F.Performance.effective
        local targetLoop = e and e.selectionLoopMs or 8
        local targetHover = e and e.hoverIntervalMs or 8
        if W2F.Performance._loopMs > targetLoop then
            W2F.Performance._loopMs = W2F.Performance._loopMs - 1
        end
        if W2F.Performance._hoverMs > targetHover then
            W2F.Performance._hoverMs = W2F.Performance._hoverMs - 1
        end
    end
end

--- Convenience for streaming.lua / render.lua (same effective table).
function W2F.Performance.StreamKeepaliveMs()
    return W2F.Performance.Get('streamKeepaliveMs') or 750
end

function W2F.Performance.StreamFocusRefreshMs()
    return W2F.Performance.Get('streamFocusRefreshMs') or 4000
end

function W2F.Performance.IntegrityCheckMs()
    local v = W2F.Performance.Get('integrityCheckMs')
    if v ~= nil then return v end
    return (Config.Rendering and Config.Rendering.integrityCheckMs) or 8000
end

function W2F.Performance.CameraIdleDrift()
    local v = W2F.Performance.Get('cameraIdleDrift')
    if v ~= nil then return v == true end
    local cam = Config.Camera
    return cam and cam.idleDrift == true
end

function W2F.Performance.PedSampleHeights()
    local heights = W2F.Performance.Get('pedSampleHeights')
    if heights then return heights end
    local interaction = Config.Interaction or {}
    return interaction.pedSampleHeights or { 0.68, 1.05 }
end

if W2F.Session and W2F.Session.OnEnter then
    W2F.Session.OnEnter('idle', function() W2F.Performance.Deactivate() end)
    W2F.Session.OnEnter('recovering', function() W2F.Performance.Deactivate() end)
    W2F.Session.OnEnter('playing', function() W2F.Performance.Deactivate() end)
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        W2F.Performance.Deactivate()
    end
end)
