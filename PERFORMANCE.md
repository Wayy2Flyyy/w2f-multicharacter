# w2f-multicharacter — Performance Audit & Remediation

**Date:** 2026-05-25  
**Symptom:** Severe in-game lag, frame drops, and degraded rendering during character selection.  
**Scope:** Client-side selection phase (not spawn cinematic unless noted).

---

## Executive summary

The character selector was running **multiple hot loops at 60–144 Hz** that hammered GTA's streaming dispatcher and the render thread. The heaviest offenders were:

1. Per-frame `SetFocusPosAndVel` + `RequestCollisionAtCoord` on an active streaming handle for the **entire** selection session.
2. `NewLoadSceneStartSphere` kept alive after the MLO had already loaded.
3. Interaction loop `Wait(0)` + `DisableAllControlActions` × 3 pads every tick.
4. Hover picking at `hoverIntervalMs = 0` → up to **9× `World3dToScreen2d`** per frame (3 peds × 3 sample heights).
5. Redundant `SetFocusPosAndVel` in `waitForSelectionSceneReady` while the streaming service already held focus.

These did not break functionality on all servers but caused catastrophic frame time on others — especially inside MLO interiors where the streaming engine is already under load.

---

## Root causes (ranked by impact)

### P0 — Streaming keepalive at frame rate

| Location | Issue | Calls/sec @ 60 FPS |
|---|---|---|
| `client/services/streaming.lua` | `Wait(0)` keepalive thread | 60 wakeups |
| same | `SetFocusPosAndVel` every wakeup | 60 |
| same | `RequestCollisionAtCoord` every wakeup | 60 |
| same | `followCamera` + collision at cam | +60 (120 total) |

**Effect:** Forces the engine to continuously re-evaluate world streaming around the lineup interior. Manifests as stutter, pop-in, and GPU/CPU spikes — often mistaken for "bad rendering."

**Fix applied:**
- Default keepalive interval → **500 ms** (`Config.Performance.streamKeepaliveMs`)
- Focus refresh throttled → **2500 ms** (`Config.Performance.streamFocusRefreshMs`)
- `followCamera = false` for selection (overview camera is fixed)

---

### P0 — Load scene sphere never released after boot

| Location | Issue |
|---|---|
| `client/characters.lua` `PrepareScene` | `NewLoadSceneStartSphere` acquired at session start and held until cleanup |

**Effect:** Active load-scene handle keeps the streaming pipeline in a high-pressure state for minutes while the player browses characters.

**Fix applied:**
- New `W2F.Characters.RelaxSceneStream()` — after collision + scene report ready, releases heavy handle and re-acquires **focus-only** (`scene = false`).

---

### P1 — Interaction loop at frame rate

| Location | Issue |
|---|---|
| `client/interaction.lua` | `Wait(0)` during `interactivePhase` (selection) |
| same | `DisableAllControlActions(0/1/2)` every tick |
| same | `W2F.Camera.Update()` every tick |

**Fix applied:**
- Selection tick → **16 ms** (~60 Hz) via `Config.Performance.selectionLoopMs`
- Still `Wait(0)` during intro, camera drag, and spawn cinematics

---

### P1 — Hover ray pick every frame

| Location | Issue |
|---|---|
| `config.lua` | `Config.Interaction.hoverIntervalMs = 0` |
| `client/characters.lua` `FindPedAtCursor` | 3 screen projections × N peds per pick |

**Fix applied:**
- Default `hoverIntervalMs` → **16 ms**
- Highlight cache skips redundant `SetEntityDrawOutline*` when mode unchanged

---

### P2 — Duplicate focus during scene wait

| Location | Issue |
|---|---|
| `waitForSelectionSceneReady` | Called `SetFocusPosAndVel` every 50 ms while streaming handle also held focus |

**Fix applied:**
- Skip manual focus/collision requests when `sceneStreamHandle` is active

---

### P2 — Entity outline shader cost

| Location | Issue |
|---|---|
| `ApplyHighlight` | `SetEntityDrawOutline*` on hover/selection |

Some client builds crash; all builds pay GPU cost for outline shader.

**Mitigation (existing):** `Config.Highlight.enabled = false` → alpha-only fallback.

---

## Vulnerabilities & residual risks

| Risk | Severity | Status |
|---|---|---|
| Streaming handle leak on failed `EnterSelection` | Medium | Mitigated by re-entry guard + `Cleanup.Full` belt-and-braces |
| Scenario props on unloaded floor (`floor-item-batman`) | High (crash) | Fixed: collision wait + leanbar anim swap |
| Outline native crash on hover | High (crash) | Mitigated: `Config.Highlight.enabled = false` |
| Per-frame streaming if `Config.Performance` disabled manually | Medium | Defaults now safe; set `streamKeepaliveMs = 0` only for debug |
| `DisableAllControlActions` × 3 still runs at 60 Hz | Low | Acceptable at 16 ms; further reduction would affect input snappiness |
| HUD hologram NUI at 60 Hz while character selected | Low | Already throttled to 16 ms in `hud.lua` |

---

## Configuration reference

```lua
--- Default: universal preset + adaptive governor (works on any hardware).
Config.Performance = {
    preset = 'universal',  -- universal | balanced | high | auto
    adaptive = true,         -- widen ticks automatically when FPS drops
}

--- High-end PC / 144 Hz monitor only:
Config.Performance = { preset = 'high' }

--- Per-key overrides (nil = use preset):
-- streamKeepaliveMs, streamFocusRefreshMs, selectionLoopMs, hoverIntervalMs,
-- integrityCheckMs, hudUpdateMs, cameraIdleDrift, pedSampleHeights,
-- useAlphaHighlightFallback
```

### Preset summary

| Preset | Loop | Hover pick | Stream keepalive | Outline shader |
|---|---|---|---|---|
| universal (default) | 20 ms | 20 ms | 750 ms | alpha fallback |
| balanced | 16 ms | 16 ms | 500 ms | enabled |
| high | 8 ms | 8 ms | 250 ms | enabled + camera drift |

```lua
Config.Interaction.hoverIntervalMs = nil  -- defers to preset

-- Legacy manual low-end tuning (usually unnecessary with universal preset):
Config.Highlight.enabled = false
Config.Performance.preset = 'universal'
Config.Performance.adaptive = true
```

---

## Verification checklist

1. Connect → character selector opens without visible stutter after fade-in.
2. `/w2fmc_diag` → `activeStreamingHandles=1`, `newLoadSceneActive=false` after ~2 s idle in selection.
3. Hover characters — responsive cursor pick, no crash, stable FPS.
4. Select character → details panel + hologram appear normally.
5. Spawn flow → sky cinematic still smooth (`Wait(0)` preserved for cinematics).

---

## Files changed in remediation

| File | Change |
|---|---|
| `config.lua` | Added `Config.Performance`, `Config.Rendering`; `hoverIntervalMs` 0 → 16 |
| `client/services/streaming.lua` | Throttled keepalive + focus refresh |
| `client/services/render.lua` | **New** — unified visual environment + scene priming |
| `client/characters.lua` | `RelaxSceneStream`, boot priming, deferred hide player, highlight cache |
| `client/interaction.lua` | Selection loop 16 ms; world population suppress |
| `client/main.lua` | Render pipeline integration, finalize after lineup |
| `client/cleanup.lua` | `Render.LeaveSelection` on visuals cleanup |

---

## Rendering overhaul (2026-05-25)

### Problems fixed

| Issue | Fix |
|---|---|
| Boot wait skipped collision at camera + slot coords when stream handle active | `W2F.Render.PrimeScenePoints()` primes all anchors every 50 ms during boot |
| Player hidden underground before preview peds spawned | `FinalizeScenePresentation()` runs after `BuildLineup` |
| Ambient peds/vehicles streaming into lineup | `SuppressWorldPopulation()` each selection tick |
| Inconsistent interior lighting | Frozen clock + artificial lights + unified timecycle |
| MLO silently unloading mid-session | Integrity monitor re-primes collision every 5 s |

### Boot sequence (correct order)

1. Fade out → `Render.EnterSelection()`
2. `PrepareScene()` — player at focal Z, `Interior.Acquire`, stream + wait (bucket 0)
3. Optional routing bucket (skipped for interior scenes / when `UseRoutingBuckets = false`)
4. `BuildLineup()` — spawn preview peds (collision primed per slot)
5. `FinalizeScenePresentation()` — hide player in-place + re-prime
6. Camera intro → `Render.FinalizeBeforeFadeIn()` → fade in

---

## Interior streaming vs performance (2026-05-25)

Performance throttling (keepalive intervals, interaction loop pacing, alpha highlights) **does not fix MLO void rendering**. Those changes reduce CPU/GPU load but the selector can still show an empty interior if:

| Cause | Symptom | Fix |
|---|---|---|
| Per-player routing bucket before MLO load | Void in isolated bucket; `/w2fmc_safemode` works | `UseRoutingBuckets = false`; defer bucket until after `PrepareScene` |
| Local ped at `focal.z - 50` during selection | Nothing renders until noclip moves ped up | `Config.Scene.interior.keepPlayerInside = true` |
| `RelaxSceneStream()` drops `NewLoadSceneStartSphere` | Interior shell unloads mid-session | `relaxStreamAfterLoad = false` + `keepSceneSphere = true` |
| No interior natives | False-positive collision ready, empty camera | `W2F.Interior.Acquire()` — IPLs, `PinInteriorInMemory`, `IsInteriorReady` |

**Rule:** Never trade interior streaming correctness for frame-time savings inside MLO lineups. Throttle interaction/HUD loops instead.

Use `/w2fmc_diag` to verify `routingBucket=0`, `interiorReady=true`, `sceneStreamScene=true`, and `pedZDeltaFromFocal≈0`. Use `/w2fmc_bisect` to isolate regressions.

### Post-spawn interior leak (2026-05-25)

**Symptom:** Pillbox / any interior pitch-black or broken after selecting a character; `stop w2f-multicharacter` instantly fixes it.

**Cause:** `W2F.Characters.sceneStreamHandle` (lineup `SetFocusPosAndVel` + `NewLoadSceneStartSphere`) was never released on spawn.finalize. Spawner only released its own cinematic handle. Engine kept streaming focus at the multichar coords (~914, 40, 112) while the player was at Pillbox.

**Fix:** `W2F.Cleanup.ReleaseSelectionWorldState()` — called on `session_exit_selection`, `session_enter_playing`, `finalize_spawn`, and `Cleanup.Full`.

Cold session connect still failed while `/w2fmc_safemode` worked because safemode **Cleanup + re-enter** resets streaming state the first boot never cleared. Additional fixes:

| Safemode behavior | Default path fix |
|---|---|
| `Cleanup.Full` before re-enter | `resetStreamingForSelection()` at every `EnterSelection` |
| `DisableBuckets` (bucket 0) | `EnsureRoutingBucketZero` always — `ResetRoutingBucket` no longer gated on `UseRoutingBuckets` |
| 40m scene sphere | `Config.Scene.interior.streamRadius = 40` |
| 100ms keepalive / 500ms focus | `streamKeepaliveMs` / `streamFocusRefreshMs` on interior config |
| MLO without `GetInteriorAtCoords` | `forceMloScene = true` + `TryPinAt` retry during boot wait |
| Player at focal Z | `primeSpawn` uses `keepPlayerInside` |
