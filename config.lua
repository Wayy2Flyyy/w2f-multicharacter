Config = {}

Config.Framework = Config.Framework or 'auto'
-- valid values: 'auto', 'qbox', 'qbcore', 'esx'

Config.General = {
    Debug = false,
    --- Should match the number of scene ped slots (visual lineup positions).
    MaxCharacters = 3,
    DefaultSlots = 3,
    --- MLO lineup interiors stream in bucket 0. Isolated per-player buckets
    --- leave the selector in an empty world shell (void rendering).
    UseRoutingBuckets = false,
}

--- New character registration + clothing (illenium-appearance).
Config.CharacterCreation = {
    enabled = true,
    auditLog = true,
    nameMinLength = 2,
    nameMaxLength = 24,
    birthdateMin = '1940-01-01',
    birthdateMax = '2006-12-31',
    defaultNationality = 'American',
    nationalities = {
        'American', 'British', 'Canadian', 'Mexican', 'German',
        'French', 'Italian', 'Spanish', 'Russian', 'Chinese',
        'Japanese', 'Korean', 'Australian', 'Brazilian', 'Other',
    },
    --- Uses illenium-appearance when started; falls back to qb-clothes event.
    preferIllenium = true,
    --- World coords used during the LEGACY appearance editor (only used when
    --- `directToApartment` is false). The lineup interior is a tight space
    --- and customization cameras tend to clip walls there, so the legacy
    --- editor handed off to a clean outdoor location (LSIA south apron).
    appearanceLocation = vec4(-1042.50, -2745.40, 21.36, 320.0),
    --- Radius streamed in around the appearance location before the editor
    --- starts so the world has loaded by the time we fade in.
    appearanceStreamRadius = 75.0,
    --- After creation finishes, skip the character selector and drop the
    --- player straight into the spawn picker (default locations + the
    --- starter apartment options). Set false to keep the legacy lineup flow.
    --- This is now legacy: `directToApartment` (below) takes precedence and
    --- skips the spawn picker entirely.
    directToSpawnPicker = true,
    --- NEW FLOW (preferred): right after the create form is submitted, log
    --- the player in as the new character and drop them DIRECTLY into the
    --- starter apartment. qbx_properties' apartmentSelect handler then
    --- triggers `qb-clothes:client:CreateFirstCharacter` so the clothing
    --- editor opens INSIDE the apartment — no spawn picker, no LSIA hop.
    ---
    --- Set false to fall back to the legacy LSIA-appearance-then-spawn-picker
    --- pipeline (which still works for servers that don't use qbx_properties).
    directToApartment = true,
    --- Which qbx_properties apartment index to use as the starter when
    --- `directToApartment` is true. See `qbx_properties/config/shared.lua`
    --- (`apartmentOptions`) — 1 = Del Perro Heights Apt by default.
    starterApartmentIndex = 1,
}

Config.Debug = Config.General.Debug

-----------------------------------------------------------------------------
--- Debug / diagnostic toggles (W2F.Diag).
---
--- These are STRICTLY OPT-IN. With every flag below set to `false` (the
--- defaults), the resource MUST behave identically to the un-instrumented
--- legacy build — no log spam, no behaviour changes, no extra natives.
---
--- Toggles can also be flipped at runtime via the `/w2fmc_safemode` command
--- (which writes into `W2F.Diag.runtime` without mutating these defaults).
---
---   DebugStreaming           Verbose logs around every streaming Acquire/Release
---                            (focus, scene sphere, collision, follow-camera).
---   DebugSceneSafeMode       Reduced streaming pressure: smaller sphere radius,
---                            slower per-frame collision tick, no follow-camera.
---                            Use to rule out streaming overload as the crash cause.
---   DebugDisableBuckets      Skip the per-source routing bucket on EnterSelection.
---                            Use to rule out bucket-induced MLO load failures.
---   DebugDisablePreviewEmotes Skip emote scenarios / anims / world props / attached
---                             props on preview peds. Falls back to a still ped.
---                             Use to rule out asset/scenario load races.
---   DebugExteriorScene       Replace the lineup interior coords with the exterior
---                            LSIA fallback (`Config.DebugExteriorSceneCoords`).
---                            Use to confirm the crash is interior/MLO-specific.
---   DebugCollisionLogs       Log collision/focus/scene status every ~250ms while
---                            a streaming handle is live. Pair with DebugStreaming
---                            for the most verbose trail.
---
--- All diag log lines are prefixed `[w2f-multicharacter][stream-debug]`.
-----------------------------------------------------------------------------
Config.DebugStreaming = false
Config.DebugSceneSafeMode = false
Config.DebugDisableBuckets = false
Config.DebugDisablePreviewEmotes = false
Config.DebugExteriorScene = false
Config.DebugCollisionLogs = false
--- When true, prints a `/w2fmc_diag`-style snapshot automatically ~2s after
--- the character selector fades in (F8 console). Also runs when DebugStreaming
--- is true.
Config.DebugAutoDiagOnSelection = false

--- Exterior fallback scene used when `DebugExteriorScene` (or `/w2fmc_exteriortest`)
--- is active. Picked to be a wide, low-traffic outdoor area (LSIA south apron)
--- so we can verify the selector + camera + preview peds work correctly with
--- zero MLO/IPL dependencies.
Config.DebugExteriorSceneCoords = {
    pedSlots = {
        vec4(-1042.50, -2745.40, 21.36, 320.0),
        vec4(-1044.30, -2746.90, 21.36, 320.0),
        vec4(-1046.10, -2748.40, 21.36, 320.0),
    },
    overviewCamera = vec4(-1043.30, -2740.40, 23.20, 145.0),
}

--- Set true only when qbx_core/config/client.lua has characters.useExternalCharacters = true
Config.UseExternalCharacters = true

--- Opens selection on session start (requires UseExternalCharacters)
Config.AutoOpen = true

--- Startup / reconnect reliability (server restart, slow MySQL, late NUI).
Config.Startup = {
    maxAttempts = 6,
    attemptDelayMs = 1500,
    dependencyTimeoutMs = 45000,
    nuiReadyTimeoutMs = 10000,
    --- World streaming for the selection interior on cold boot. Without focus +
    --- a persistent scene sphere the overview camera often frames empty space
    --- until the resource is restarted.
    sceneStreamRadius = 90.0,
    sceneCollisionTimeoutMs = 15000,
}

-- Character selection scene (ped lineup)
--
-- Each ped slot can be either:
--   * vec4(x, y, z, heading)                            (no emote)
--   * { coords = vec4(...), emote = 'emoteName' }      (uses Config.Emotes)
--
-- When `emote` is set, the slot's heading is honored verbatim (auto-facing is
-- skipped for that slot) so the staged pose is preserved.
Config.Scene = {
    --- All slots share the same interior as overviewCamera so the locked
    --- camera can frame them. Per-slot heading is honored verbatim.
    pedSlots = {
        { coords = vec4(916.7150, 40.9866, 111.7013, 63.8547), emote = 'sitchair4' },
        { coords = vec4(914.9835, 39.3125, 111.7013, 337.9402), emote = 'smoke' },
        { coords = vec4(912.2994, 40.3135, 111.7012, 295.9295), emote = 'leanbar' },
    },
    --- Fixed overview camera position (x, y, z). vec4.w is optional legacy
    --- metadata only — rotation is computed from this position toward the
    --- ped-lineup focal point so the camera always faces the characters.
    overviewCamera = vec4(916.2162, 47.8691, 111.6620, 175.3658),
    introDurationMs = 2800,
    introStartHeight = 12.0,
    --- When true, first session connect skips the intro fly-in and snaps
    --- straight to overviewCamera (same as the default session boot path).
    skipIntroOnBoot = true,
    --- Focal point is the ped-center lifted by this amount (chest/face height).
    focalHeightOffset = 1.0,
    --- Auto-orient preview peds toward the overview camera. Off here because
    --- the staged emotes look correct only at the headings provided.
    autoFacePedsToCamera = false,
    --- Emote pool for the most recently played character (highest lastLoggedOut).
    --- One entry is picked deterministically per citizenid when the lineup loads.
    lastLocationEmotes = {
        'smoke',
        'wait', 'wait2', 'wait3', 'wait4', 'wait5', 'wait6', 'wait7',
        'stretch', 'stretch2', 'stretch3', 'stretch4',
        'shakeoff',
    },
    --- Interior/MLO streaming for the lineup location. Auto-detects via
    --- GetInteriorAtCoords at the scene focal; fill `ipls` if your map uses IPLs.
    interior = {
        ipls = {},
        pinInterior = true,
        --- Ymap MLOs at the lineup coords may not register with GetInteriorAtCoords
        --- until after the scene sphere loads — force the interior streaming path.
        forceMloScene = true,
        --- Safemode uses 40m; 90m can fail to load tight MLO lineups on cold boot.
        streamRadius = 40.0,
        streamKeepaliveMs = 100,
        streamFocusRefreshMs = 500,
        --- Keep NewLoadSceneStartSphere active for the whole selection session.
        keepSceneSphere = true,
        --- Hide the local ped at focal Z instead of 50m underground (required
        --- for the engine to keep streaming the interior shell).
        keepPlayerInside = true,
    },
}

--- Emote registry used by curated scene slots. Each entry can specify any of:
---   scenario   = GTA ped scenario name (TaskStartScenarioInPlace / AtPosition)
---   anim       = { dict, clip }    plays a looped animation (LOOP flag = 1)
---   prop       = { model, offsetZ } spawns a world prop at the slot (kept
---                with the slot lifetime). When provided alongside `scenario`,
---                the scenario is started at the prop's position so the ped
---                snaps onto it (e.g. sitting in a chair).
---   attachProp = { model, bone, offset, rot } attaches a prop to a ped bone
---                (bone defaults to 60309 = SKEL_R_Hand). Useful for cups etc.
Config.Emotes = {
    --- scully_emotemenu: /smoke
    smoke = {
        scenario = 'WORLD_HUMAN_SMOKING',
    },
    --- scully_emotemenu: /wait through /wait7
    wait = {
        anim = { dict = 'random@shop_tattoo', clip = '_idle_a' },
    },
    wait2 = {
        anim = { dict = 'missbigscore2aig_3', clip = 'wait_for_van_c' },
    },
    wait3 = {
        anim = { dict = 'amb@world_human_hang_out_street@female_hold_arm@idle_a', clip = 'idle_a' },
    },
    wait4 = {
        anim = { dict = 'amb@world_human_hang_out_street@Female_arm_side@idle_a', clip = 'idle_a' },
    },
    wait5 = {
        anim = { dict = 'missclothing', clip = 'idle_storeclerk' },
    },
    wait6 = {
        anim = { dict = 'timetable@amanda@ig_2', clip = 'ig_2_base_amanda' },
    },
    wait7 = {
        anim = { dict = 'rcmnigel1cnmt_1c', clip = 'base' },
    },
    --- scully_emotemenu: /stretch through /stretch4
    stretch = {
        anim = { dict = 'mini@triathlon', clip = 'idle_e' },
    },
    stretch2 = {
        anim = { dict = 'mini@triathlon', clip = 'idle_f' },
    },
    stretch3 = {
        anim = { dict = 'mini@triathlon', clip = 'idle_d' },
    },
    stretch4 = {
        anim = { dict = 'rcmfanatic1maryann_stretchidle_b', clip = 'idle_e' },
    },
    --- scully_emotemenu: /shakeoff
    shakeoff = {
        anim = { dict = 'move_m@_idles@shake_off', clip = 'shakeoff_1' },
    },
    --- Legacy slot emotes (kept for reference / custom slot configs).
    sitchair = {
        anim = { dict = 'timetable@ron@ig_3_couch', clip = 'base' },
    },
    whiskey = {
        scenario = 'WORLD_HUMAN_DRINKING',
    },
    lean = {
        scenario = 'WORLD_HUMAN_LEANING',
    },
    --- scully_emotemenu: /sitchair4
    sitchair4 = {
        anim = { dict = 'timetable@jimmy@mics3_ig_15@', clip = 'mics3_15_base_tracy' },
    },
    --- scully_emotemenu: /leanbar
    ---
    --- WAS: scenario = 'PROP_HUMAN_BUM_SHOPPING_CART'. That scenario's
    --- controller asynchronously creates a shopping-cart prop and queries
    --- the floor physics under the ped — if the MLO floor isn't fully
    --- dispatched yet (which happens in the lineup interior on cold boot
    --- and after routing-bucket swap), the engine crashes inside the entity
    --- render path with the `floor-item-batman` signature ~1s after the ped
    --- spawns.
    ---
    --- Replaced with the equivalent loop anim from `amb@world_human_leaning`
    --- which renders the same "leaning against a wall" pose but does not
    --- spawn any engine-side world props, so it can't trigger the race.
    leanbar = {
        anim = { dict = 'amb@world_human_leaning@male@wall@back@hands_together@idle_a', clip = 'idle_a' },
    },
    sitchair2 = {
        anim = { dict = 'timetable@reunited@ig_10', clip = 'base_amanda' },
    },
}

Config.SceneProfiles = {
    neutral = {
        lighting = 'clean',
        animation = 'WORLD_HUMAN_STAND_IMPATIENT',
        props = {},
    },
    police = {
        lighting = 'emergency',
        animation = 'WORLD_HUMAN_COP_IDLES',
        props = {},
    },
    medical = {
        lighting = 'medical',
        animation = 'WORLD_HUMAN_CLIPBOARD',
        props = {},
    },
    garage = {
        lighting = 'garage',
        animation = 'WORLD_HUMAN_HAMMERING',
        props = {},
    },
    street = {
        lighting = 'dark',
        animation = 'WORLD_HUMAN_SMOKING',
        props = {},
    },
    executive = {
        lighting = 'clean',
        animation = 'WORLD_HUMAN_STAND_MOBILE',
        props = {},
    },
}

Config.SceneJobMap = {
    police = 'police',
    sheriff = 'police',
    state = 'police',
    ambulance = 'medical',
    ems = 'medical',
    doctor = 'medical',
    mechanic = 'garage',
    tuner = 'garage',
    gang = 'street',
    ballas = 'street',
    vagos = 'street',
    families = 'street',
    cartel = 'street',
    unemployed = 'neutral',
    realestate = 'executive',
    lawyer = 'executive',
    judge = 'executive',
    casino = 'executive',
}

Config.CameraControl = {
    --- Camera drag is fully disabled — the overview stays locked at the
    --- configured overviewCamera position at all times.
    enabled = false,
    holdButton = 'LEFT_CLICK',
    sensitivityX = 0.06,
    sensitivityY = 0.03,
    smoothing = 0.07,
    --- Drag clamps are relative to the base overview orbit (degrees).
    minYaw = -25.0,
    maxYaw = 25.0,
    minPitch = -10.0,
    maxPitch = 10.0,
    minDistance = 6.0,
    maxDistance = 16.0,
    defaultDistance = 9.0,
    defaultYaw = 0.0,
    defaultPitch = 0.0,
    --- Settle = how fast the camera returns to base orbit after drag release.
    settleSpeed = 0.045,
    dragThreshold = 8,
    fov = 42.0,
    collisionProbe = false,
}

Config.Camera = {
    overview = {
        --- Used only as fallback when Config.Scene.overviewCamera is nil.
        distance = 11.0,
        height = 0.0,
        fov = 42.0,
        yaw = 0.0,
        pitch = 0.0,
    },
    focus = {
        distance = 5.5,
        height = 1.4,
        fov = 35.0,
    },
    sky = {
        height = 420.0,
        fov = 50.0,
    },
    descent = {
        endHeight = 28.0,
        fovStart = 48.0,
        fovEnd = 42.0,
        rotationOffset = 15.0,
    },
    smoothing = 0.055,
    idleDrift = true,
    idleDriftStrength = 0.018,
    resetSpeed = 0.04,
    fov = {
        overview = 42.0,
        focus = 35.0,
        sky = 50.0,
        descent = 48.0,
        ground = 42.0,
    },
}

Config.Highlight = {
    --- Master toggle for SetEntityDrawOutline / *Color / *Shader natives.
    --- A handful of FiveM client builds (and certain GPU + driver combos)
    --- crash inside the entity outline shader when these natives are called
    --- on a streamed-in ped. Set to `false` on those servers to fall back
    --- to an alpha-only highlight (full alpha = hovered/selected, dim = idle).
    --- Hover detection, selection, and NUI details all keep working.
    enabled = true,
    --- Stock mp_m/mp_f freemode peds crash inside the outline shader on hover
    --- for many FiveM client builds; addon/custom ped models are usually fine.
    --- When true (default), freemode slots use alpha highlight only while
    --- custom ped models still get the full outline when enabled = true.
    alphaForFreemode = true,
    outlineColor = { r = 106, g = 217, b = 255 },
    selectedColor = { r = 120, g = 200, b = 255 },
    emptyHoverColor = { r = 160, g = 220, b = 255 },
    --- Outline shader index (FiveM SetEntityDrawOutlineShader):
    --- 0 = thin/neutral, 1 = thick/sharper, 2 = pulse. Defaults to 1
    --- which matches the legacy look.
    outlineShader = 1,
    --- Alpha values used when `enabled = false`. The hover/selected ped is
    --- rendered fully opaque while idle peds dim slightly so the active
    --- target reads clearly without touching the outline natives.
    fallbackIdleAlpha = 200,
    fallbackHoverAlpha = 255,
    fallbackSelectedAlpha = 255,
    --- Empty-slot ghost peds stay translucent regardless of mode.
    fallbackEmptyAlpha = 140,
    fallbackEmptyHoverAlpha = 200,
}

--- Optional secondary fallback for environments where the hover frontend
--- sound also misbehaves (rare but reported alongside the outline crash on
--- the same boxes). Setting `disableHoverSound = true` silences the per-hover
--- audio cue while keeping every other selector sound (select/details/etc).
Config.Hover = Config.Hover or {}
Config.Hover.disableHoverSound = false

--- Performance tuning for the character selection phase.
---
--- preset:
---   high       — default; outline on addon peds, 120+ Hz loops, camera drift
---   balanced   — middle ground for mid-range PCs
---   universal  — low-end / compatibility fallback
---   auto       — starts universal; adaptive governor adjusts at runtime
---
--- Interior/MLO streaming (keepSceneSphere, streamRadius, etc.) is unchanged
--- by preset — those settings live under Config.Scene.interior.
Config.Performance = {
    preset = 'high',
    adaptive = true,
    streamKeepaliveMs = nil,
    streamFocusRefreshMs = nil,
    selectionLoopMs = nil,
    hoverIntervalMs = nil,
    integrityCheckMs = nil,
    hudUpdateMs = nil,
    cameraIdleDrift = true,
    pedSampleHeights = nil,
    useAlphaHighlightFallback = false,
    --- Must stay false for MLO lineups — see Config.Scene.interior.keepSceneSphere.
    relaxStreamAfterLoad = false,
}

--- Visual quality and world-state control during character selection.
Config.Rendering = {
    --- Consistent interior lighting (hour/minute). nil = don't override clock.
    freezeTime = { hour = 22, minute = 0 },
    --- Stop qb-weathersync from fighting the staged timecycle while selecting.
    suppressWeatherSync = true,
    --- Hide ambient peds/vehicles so the lineup isn't cluttered or streamed over.
    suppressWorldPopulation = true,
    --- Interior MLOs often need artificial lights forced on for correct look.
    artificialLights = true,
    --- Default lineup timecycle (profile overrides below).
    timecycle = 'MP_corona_heist_blend',
    timecycleStrength = 0.22,
    timecycleEmergency = 'MP_corona_heist_blend',
    timecycleStrengthEmergency = 0.30,
    timecycleMedical = 'int_hospital2_dm',
    timecycleStrengthMedical = 0.24,
    timecycleGarage = 'int_carrier_hanger',
    timecycleStrengthGarage = 0.20,
    timecycleDark = 'V_FIB_IT3',
    timecycleStrengthDark = 0.32,
    --- How far below focal the local player is hidden after the lineup loads.
    playerHideOffset = 50.0,
    --- Periodic collision prime while in selection (ms). 0 = disabled.
    integrityCheckMs = 4000,
}

Config.Interaction = {
    clickDebounceMs = 150,
    --- Max ray length used when picking a ped (meters) — fallback only.
    rayMaxDistance = 120.0,
    --- Tube radius around a ped used to register hover/click (meters).
    pedSelectRadius = 4.5,
    --- Cursor distance to the ped's projected screen-space position, in pixels,
    --- that still counts as a hover. Larger = more forgiving.
    pedSelectScreenRadius = 240,
    --- Empty-slot ghost peds get a slightly larger hit area.
    pedSelectScreenRadiusEmpty = 280,
    --- World heights (meters above ped root) sampled for screen hit-testing.
    --- Covers seated + standing poses in the lineup.
    pedSampleHeights = { 0.35, 0.68, 1.05 },
    --- Score multiplier for the ped already hovered (< 1 keeps hover sticky).
    hoverStickiness = 0.68,
    --- Hover ray pick interval (ms). nil = use Config.Performance preset.
    hoverIntervalMs = nil,
    dragThreshold = 8.0,
    hoverEnabled = true,
    selectionEnabled = true,
    hoverDistance = 80.0,
    hoverEffectStrength = 0.7,
    pedAimHeight = 0.95,
    --- Select on mouse-down when camera drag is off (snappier than release).
    selectOnMouseDown = true,
}

Config.UI = {
    hologramEnabled = true,
    animationSpeed = 0.35,
    detailsPosition = 'right',
    showControlHints = true,
}

Config.SpawnCinematic = {
    enabled = true,
    skyHeight = 380.0,
    skyRiseDurationMs = 2600,
    flyDurationMs = 5200,
    flyHeight = 320.0,
    hoverDurationMs = 1600,
    descendDurationMs = 4200,
    descendEndHeight = 28.0,
    fovSky = 52.0,
    fovDescend = 46.0,
    fovGround = 40.0,
    fadeOutMs = 800,
    fadeInMs = 950,
    travelFadeDistance = 2200.0,
    travelFadeOutMs = 320,
    travelFadeInMs = 420,
    soundHooks = true,
    --- Per-frame damping (0..1) applied to cinematic camera position / rotation /
    --- FOV so spline samples glide instead of snapping each tick.
    cameraSmoothFactor = 0.12,
    --- Additional smoothing for look-at target while tracking the ped.
    cameraLookAtSmoothFactor = 0.16,
    --- World height above ped feet the fly camera locks onto.
    pedFocusHeight = 0.95,
    --- Radius passed to NewLoadSceneStartSphere at the destination so map
    --- geometry streams in while the camera is still in transit.
    streamingRadius = 120.0,
}

Config.Spawns = {
    {
        id = 'last',
        label = 'Last Location',
        type = 'last',
        fallback = 'public',
        description = 'Return to your saved position.',
    },
    {
        id = 'police',
        label = 'Police Station',
        coords = vec4(441.23, -981.89, 30.69, 90.0),
        description = 'Spawn near the main police station.',
    },
    {
        id = 'public',
        label = 'Public Centre',
        coords = vec4(215.76, -810.12, 30.73, 160.0),
        description = 'Spawn in the central public area.',
    },
    {
        id = 'hospital',
        label = 'Hospital',
        coords = vec4(298.54, -584.41, 43.26, 70.0),
        description = 'Spawn near medical services.',
    },
}

Config.UseQbox = (Config.Framework == "auto" or Config.Framework == "qbox")
Config.MaxCharacters = Config.General.MaxCharacters

Config.Spawn = {
    skySpawnEnabled = true,
    allowedSpawnPoints = { 'last', 'police', 'public', 'hospital' },
    lastLocationFallback = 'public',
    flyTimeMs = Config.SpawnCinematic.flyDurationMs,
    freezeTimeMs = Config.SpawnCinematic.hoverDurationMs,
    descentTimeMs = Config.SpawnCinematic.descendDurationMs,
}

Config.Audio = {
    enabled = true,
    hover = 'ui_hover',
    select = 'ui_select',
    detailsOpen = 'ui_details_open',
    spawnPress = 'ui_spawn_press',
    skyLaunch = 'sky_launch',
    locationSelect = 'location_select',
    descentPulse = 'descent_pulse',
    finalSpawn = 'final_spawn',
}

--- New-character apartment integration. When enabled and `qbx_properties`
--- is running, brand-new characters get a "Starter Apartment" panel after
--- finishing creation, alongside the usual spawn points.
Config.Apartments = {
    enabled = true,
    --- Show the picker on the very first spawn of a new character only.
    onlyFirstSpawn = true,
    --- Optional extra description appended to each apartment card.
    cardSuffix = 'Free starter apartment',
}

Config.SpawnPreview = {
    enabled = true,
    --- How far (0..1) the smoothed goal glides toward the raw hovered target.
    --- This is the first stage; the camera then follows the smoothed goal.
    hoverGoalSpeed = 0.10,
    --- How far (0..1) the look-at smooths toward the goal each frame.
    hoverPreviewSpeed = 0.016,
    --- How far (0..1) the camera position smooths toward its goal each frame.
    hoverCameraDriftSpeed = 0.014,
    --- Max world-space fraction the look-at shifts toward the hovered location.
    hoverPreviewStrength = 0.55,
    --- Max world-space fraction the camera drifts toward the hovered location.
    hoverCameraDriftStrength = 0.25,
}

Config.Scenes = {
    jobMappings = Config.SceneJobMap,
    fallbackScene = 'neutral',
    lightingProfiles = Config.SceneProfiles,
    animationProfiles = Config.SceneProfiles,
    propLimits = 0,
}

--- Returns the vec4 coords from a slot regardless of whether it's stored as
--- a bare vec4 or as the table form `{ coords = vec4, emote = ... }`.
function Config.GetSlotCoords(slot)
    if not slot then return nil end
    if slot.coords then return slot.coords end
    return slot
end

function Config.GetSlotEmote(slot)
    if not slot then return nil end
    return slot.emote
end

--- Computes the camera look-at focal point from ped slot positions.
function Config.GetSceneFocal()
    local slots = Config.Scene.pedSlots
    if not slots or #slots == 0 then
        return vec3(0.0, 0.0, 0.0)
    end

    local sumX, sumY, sumZ = 0.0, 0.0, 0.0
    for i = 1, #slots do
        local c = Config.GetSlotCoords(slots[i])
        sumX = sumX + c.x
        sumY = sumY + c.y
        sumZ = sumZ + c.z
    end

    local count = #slots
    return vec3(
        sumX / count,
        sumY / count,
        (sumZ / count) + (Config.Scene.focalHeightOffset or 0.0)
    )
end

--- Distance from focal point based on ped lineup span (keeps all peds in frame).
--- Uses the bounding-box diagonal of all slots, not just first/last, so it
--- works with curated non-linear arrangements too.
function Config.GetRecommendedCameraDistance()
    local slots = Config.Scene.pedSlots
    local c = Config.CameraControl
    if not slots or #slots < 2 then
        return c.defaultDistance
    end

    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    for i = 1, #slots do
        local sc = Config.GetSlotCoords(slots[i])
        if sc.x < minX then minX = sc.x end
        if sc.x > maxX then maxX = sc.x end
        if sc.y < minY then minY = sc.y end
        if sc.y > maxY then maxY = sc.y end
    end

    local dx, dy = maxX - minX, maxY - minY
    local span = math.sqrt(dx * dx + dy * dy)
    local distance = span * 1.25 + 5.5
    if distance < c.minDistance then return c.minDistance end
    if distance > c.maxDistance then return c.maxDistance end
    return distance
end

---@param opts? table { newCharacter = boolean }
function Config.GetSpawnOptionsForNui(opts)
    local newOnly = type(opts) == 'table' and opts.newCharacter == true
    local options = {}
    for i = 1, #Config.Spawns do
        local spawn = Config.Spawns[i]
        --- Brand-new characters have no "last location" to return to yet, so
        --- hide the card to keep the first-spawn picker focused on real
        --- starter choices (default locations + apartments).
        local skip = false
        if newOnly and (spawn.type == 'last' or spawn.id == 'last') then
            skip = true
        end
        if not skip then
            options[#options + 1] = {
                id = spawn.id,
                label = spawn.label,
                description = spawn.description,
            }
        end
    end
    return options
end
