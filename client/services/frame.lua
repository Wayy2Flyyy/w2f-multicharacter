--- W2F.Frame - frame-rate-independent smoothing primitives.
---
--- Everything in the resource that interpolates over time (camera orbit /
--- focal / FOV, HUD scale, spawn preview rise) goes through these helpers.
--- They use `GetFrameTime()` so a 30/60/144 FPS player gets the same visual
--- rate (cinematic durations stay within 5% across frame rates per the
--- acceptance criteria).
---
--- Rate semantics: `rate` is "how many e-folds per second" - the higher the
--- value, the faster the smoothing converges. `rate=8` is "snappy",
--- `rate=2` is "lazy", `rate=0.5` is "ambient drift".

W2F = W2F or {}
W2F.Frame = W2F.Frame or {}

local clamp = function(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Returns delta-time in seconds, capped to 0.1 so a stutter never produces
--- a giant smoothing step that would teleport the camera.
function W2F.Frame.Dt()
    local dt = GetFrameTime()
    if not dt or dt ~= dt then return 1 / 60 end
    return clamp(dt, 0, 0.1)
end

--- Frame-rate-independent exponential smoothing.
--- `current` and `target` are scalars; `rate` is e-folds/sec.
---
--- The classic "lerp(a, b, t)" is frame-rate dependent. We replace it with
--- `lerp(a, b, 1 - exp(-rate * dt))` so the effective smoothing per second
--- is identical regardless of FPS.
function W2F.Frame.Smooth(current, target, rate, dt)
    dt = dt or W2F.Frame.Dt()
    local t = 1 - math.exp(-(rate or 6) * dt)
    return current + (target - current) * t
end

--- Same as `Smooth` but takes vec3 components piecewise so callers don't have
--- to triple-write the math at every site.
function W2F.Frame.SmoothVec3(current, target, rate, dt)
    dt = dt or W2F.Frame.Dt()
    local t = 1 - math.exp(-(rate or 6) * dt)
    return vector3(
        current.x + (target.x - current.x) * t,
        current.y + (target.y - current.y) * t,
        current.z + (target.z - current.z) * t
    )
end

--- Smooth yaw with shortest-path wrap so 359° -> 1° goes the short way.
function W2F.Frame.SmoothYaw(current, target, rate, dt)
    dt = dt or W2F.Frame.Dt()
    local delta = ((target - current + 540) % 360) - 180
    local t = 1 - math.exp(-(rate or 6) * dt)
    return current + delta * t
end

--- Time-based linear interpolation. `t` in [0..1].
function W2F.Frame.Lerp(a, b, t)
    return a + (b - a) * clamp(t, 0, 1)
end

--- Smoothstep: C1-continuous ease in/out over [0..1].
function W2F.Frame.SmoothStep(t)
    t = clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

--- Smootherstep: C2-continuous ease in/out (Perlin's improved version).
function W2F.Frame.SmootherStep(t)
    t = clamp(t, 0, 1)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

--- Ease-out cubic. Good for fly-to-spawn descent (fast then slow).
function W2F.Frame.EaseOutCubic(t)
    t = clamp(t, 0, 1)
    local oneMinusT = 1 - t
    return 1 - oneMinusT * oneMinusT * oneMinusT
end

--- Ease-in-out cubic. Good for selection orbit when the player drags.
function W2F.Frame.EaseInOutCubic(t)
    t = clamp(t, 0, 1)
    if t < 0.5 then return 4 * t * t * t end
    local f = 2 * t - 2
    return 0.5 * f * f * f + 1
end

W2F.Frame.Clamp = clamp
