W2F.Characters = {}
W2F.Characters.activeSceneProfile = 'neutral'
W2F.Characters.lastPlayedCitizenid = nil
W2F.Characters.sceneStreamHandle = nil
W2F.Characters._highlightState = {}
W2F.Characters._outlineUnsafe = {}
local fallbackScenarios = {
    'WORLD_HUMAN_STAND_IMPATIENT',
    'WORLD_HUMAN_STAND_MOBILE',
    'WORLD_HUMAN_HANG_OUT_STREET',
    'WORLD_HUMAN_LEANING',
}

local FREEMODE_MALE = `mp_m_freemode_01`
local FREEMODE_FEMALE = `mp_f_freemode_01`

local function isFreemodePedModel(model)
    return model == FREEMODE_MALE or model == FREEMODE_FEMALE
end

--- Outline shader crashes on hover for stock freemode on many FiveM builds;
--- addon/custom ped models are usually safe. Returns true to skip outline natives.
local function shouldUseAlphaHighlightOnly(ped)
    local hl = Config.Highlight or {}

    if hl.enabled == false then
        return true
    end

    if W2F.Performance and W2F.Performance.active and W2F.Performance.effective then
        if W2F.Performance.effective.useAlphaHighlightFallback then
            return true
        end
    end

    if hl.alphaForFreemode ~= false and isFreemodePedModel(GetEntityModel(ped)) then
        return true
    end

    local unsafe = W2F.Characters._outlineUnsafe
    return unsafe and unsafe[ped] == true or false
end

local function getProfileForCharacter(character)
    local defaultProfile = 'neutral'
    if not character then return defaultProfile end
    local job = character.job or {}
    local jobName = string.lower(tostring(job.name or job.type or 'unemployed'))
    local mapped = Config.SceneJobMap and Config.SceneJobMap[jobName]
    if mapped and Config.SceneProfiles and Config.SceneProfiles[mapped] then
        return mapped
    end
    return defaultProfile
end

local function applySceneLighting(profileName)
    if W2F.Render and W2F.Render.ApplyTimecycle then
        W2F.Render.ApplyTimecycle(profileName)
    else
        SetTimecycleModifier('MP_corona_heist_blend')
        SetTimecycleModifierStrength(0.22)
    end
    W2F.Characters.activeSceneProfile = profileName or 'neutral'
end

local function loadModel(model)
    local hash = type(model) == 'string' and joaat(model) or model
    if not IsModelInCdimage(hash) then
        hash = `mp_m_freemode_01`
    end
    lib.requestModel(hash, 10000)
    return hash
end

local function resolveModel(character)
    local model = `mp_m_freemode_01`
    if character and character.charinfo and character.charinfo.gender == 1 then
        model = `mp_f_freemode_01`
    end

    local appearance
    local cid = character and character.citizenid or nil
    if cid and W2F.State.modelCache[cid] then
        return W2F.State.modelCache[cid], W2F.State.appearanceCache[cid]
    end

    if character and character.citizenid and W2F.Qbox.IsActive() then
        local qbxModel, qbxAppearance = W2F.Qbox.GetPreviewPedData(character.citizenid)
        if qbxModel then
            model = qbxModel
            appearance = qbxAppearance
        end
    elseif character and character.citizenid then
        local skin = lib.callback.await('w2f-multicharacter:server:getAppearance', false, character.citizenid)
        if skin then
            appearance = skin
        end
    end

    if cid then
        W2F.State.modelCache[cid] = model
        W2F.State.appearanceCache[cid] = appearance
    end

    return model, appearance
end

function W2F.Characters.ClearPreviewPeds()
    --- Release any anim dicts that `applyEmote` decided to keep loaded.
    local heldDicts = W2F.Characters._heldAnimDicts or {}
    local outlinesEnabled = (Config.Highlight and Config.Highlight.enabled) ~= false
    for _, entry in pairs(W2F.State.previewPeds) do
        if entry.ped and DoesEntityExist(entry.ped) then
            if outlinesEnabled then
                pcall(SetEntityDrawOutline, entry.ped, false)
            end
            local dict = heldDicts[entry.ped]
            if dict then
                pcall(function() RemoveAnimDict(dict) end)
                heldDicts[entry.ped] = nil
            end
            DeleteEntity(entry.ped)
        end
        if entry.props then
            for i = 1, #entry.props do
                local prop = entry.props[i]
                if prop and DoesEntityExist(prop) then
                    DeleteEntity(prop)
                end
            end
        end
    end
    --- Anything in the held dict map for peds we no longer track is leaked
    --- by definition; release everything as a final safety net.
    for ped, dict in pairs(heldDicts) do
        pcall(function() RemoveAnimDict(dict) end)
        heldDicts[ped] = nil
    end
    W2F.Characters._heldAnimDicts = heldDicts
    W2F.Characters._highlightState = {}
    W2F.Characters._outlineUnsafe = {}
    W2F.State.previewPeds = {}
    W2F.State.hoveredPed = nil
    W2F.State.selectedPed = nil
end

--- Alpha-only fallback used when `Config.Highlight.enabled = false`.
--- Some FiveM client builds crash inside the entity outline shader when
--- SetEntityDrawOutline* is called on a streamed-in ped, so we expose this
--- branch as the safe path: hover/selected = full alpha, idle = dim.
local function applyHighlightAlphaOnly(ped, mode, isEmpty)
    local hl = Config.Highlight
    --- Make absolutely sure no prior outline state is left active before
    --- we switch to the alpha-only path (e.g. config flipped at runtime).
    pcall(SetEntityDrawOutline, ped, false)

    local idleAlpha = hl.fallbackIdleAlpha or 200
    local hoverAlpha = hl.fallbackHoverAlpha or 255
    local selectedAlpha = hl.fallbackSelectedAlpha or 255
    local emptyAlpha = hl.fallbackEmptyAlpha or 140
    local emptyHoverAlpha = hl.fallbackEmptyHoverAlpha or 200

    if isEmpty then
        if mode == 'hover' then
            SetEntityAlpha(ped, emptyHoverAlpha, false)
        else
            SetEntityAlpha(ped, emptyAlpha, false)
        end
        return
    end

    if mode == 'selected' then
        SetEntityAlpha(ped, selectedAlpha, false)
    elseif mode == 'hover' then
        SetEntityAlpha(ped, hoverAlpha, false)
    else
        SetEntityAlpha(ped, idleAlpha, false)
    end
end

function W2F.Characters.ApplyHighlight(ped, mode, isEmpty)
    if not ped or not DoesEntityExist(ped) then return end

    --- Skip redundant native calls when RefreshHighlights re-runs with the
    --- same mode (common during static hover at 60 Hz pick rate).
    local cache = W2F.Characters._highlightState
    local prev = cache[ped]
    if prev and prev.mode == mode and prev.isEmpty == isEmpty then
        return
    end
    cache[ped] = { mode = mode, isEmpty = isEmpty }

    local hl = Config.Highlight

    --- Safe fallback path: skip every outline native and use alpha only.
    --- Hover detection / selection / NUI details continue to function — only
    --- the visual outline rendering is short-circuited.
    if shouldUseAlphaHighlightOnly(ped) then
        applyHighlightAlphaOnly(ped, mode, isEmpty)
        return
    end

    --- Outline shader index is configurable; 0 = thin/neutral, 1 = thick/sharper,
    --- 2 = pulse. Defaults to 1 to match the legacy look but designers can
    --- swap it without touching code.
    local shader = hl.outlineShader or 1

    local function applyOutline(color)
        pcall(SetEntityDrawOutline, ped, true)
        pcall(SetEntityDrawOutlineColor, color.r, color.g, color.b, 255)
        pcall(SetEntityDrawOutlineShader, shader)
        ResetEntityAlpha(ped)
    end

    if isEmpty and mode == 'hover' then
        local c = hl.emptyHoverColor or hl.outlineColor
        applyOutline(c)
        return
    end

    if isEmpty then
        pcall(SetEntityDrawOutline, ped, false)
        SetEntityAlpha(ped, 140, false)
        return
    end

    if mode == 'selected' then
        applyOutline(hl.selectedColor)
    elseif mode == 'hover' then
        applyOutline(hl.outlineColor)
    else
        pcall(SetEntityDrawOutline, ped, false)
        ResetEntityAlpha(ped)
    end
end

function W2F.Characters.RefreshHighlights()
    for _, entry in pairs(W2F.State.previewPeds) do
        local ped = entry.ped
        if ped and DoesEntityExist(ped) then
            local isEmpty = entry.isEmpty == true
            if W2F.State.selectedPed == ped then
                W2F.Characters.ApplyHighlight(ped, 'selected', isEmpty)
            elseif W2F.State.hoveredPed == ped then
                W2F.Characters.ApplyHighlight(ped, 'hover', isEmpty)
            else
                W2F.Characters.ApplyHighlight(ped, 'none', isEmpty)
            end
        end
    end
end

local function computeHeadingToward(fromX, fromY, toX, toY)
    local dx = toX - fromX
    local dy = toY - fromY
    if dx == 0 and dy == 0 then return 0.0 end
    local heading = math.deg(math.atan2(-dx, dy)) % 360.0
    if heading < 0 then heading = heading + 360.0 end
    return heading
end

--- Returns the citizenid of the most recently played character (highest
--- lastLoggedOut timestamp). Used to pick a "last location" idle emote.
local function getLastPlayedCitizenid(characters)
    local bestCid, bestTs = nil, -1
    for _, character in pairs(characters or {}) do
        if character and character.citizenid then
            local ts = tonumber(character.lastLoggedOut) or 0
            if ts > bestTs then
                bestTs = ts
                bestCid = character.citizenid
            end
        end
    end
    if bestTs > 0 then
        return bestCid
    end
    --- Fallback: character with a saved world position (can use Last Location).
    for _, character in pairs(characters or {}) do
        local pos = character and character.position
        if character and character.citizenid and pos and pos.x and pos.y and pos.z then
            return character.citizenid
        end
    end
    return bestCid
end

--- Deterministic emote pick from Config.Scene.lastLocationEmotes so the
--- same character keeps the same pose across lineup refreshes.
local function pickLastLocationEmote(citizenid)
    local pool = Config.Scene and Config.Scene.lastLocationEmotes
    if not pool or #pool == 0 or not citizenid then return nil end
    local hash = 0
    for i = 1, #citizenid do
        hash = (hash + (string.byte(citizenid, i) * i)) % 2147483647
    end
    return pool[(hash % #pool) + 1]
end

--- Resolves which emote a preview ped should play. The most recently played
--- character (last location / continue character) gets a curated idle from
--- the lastLocationEmotes pool; everyone else uses the slot default.
local function resolvePreviewEmote(character, slot)
    if character and character.citizenid
        and W2F.Characters.lastPlayedCitizenid
        and character.citizenid == W2F.Characters.lastPlayedCitizenid
    then
        return pickLastLocationEmote(character.citizenid)
    end
    return Config.GetSlotEmote(slot)
end

--- Resolves the heading to spawn a slot's ped at. Honors the explicit heading
--- baked into the slot when an emote is configured (staged poses depend on it)
--- or when autoFacePedsToCamera is disabled.
local function resolveSlotHeading(slotCoords, slotEmote)
    if not slotEmote and Config.Scene and Config.Scene.autoFacePedsToCamera then
        local cam = Config.Scene.overviewCamera
        if cam then
            return computeHeadingToward(slotCoords.x, slotCoords.y, cam.x, cam.y)
        end
    end
    return slotCoords.w or 0.0
end

--- Waits (bounded) until collision physics is loaded around `ped`, requesting
--- collision at the slot every iteration so the streaming dispatcher knows
--- where to focus. Used as a guard before starting scenarios/anims that the
--- engine's scenario controller spawns props for — those queries crash
--- (`floor-item-batman`) when the MLO floor hasn't been dispatched yet.
local function waitForPedCollision(ped, slotCoords, timeoutMs)
    if not ped or not DoesEntityExist(ped) then return false end
    local deadline = GetGameTimer() + (timeoutMs or 2500)
    while GetGameTimer() < deadline do
        if slotCoords then
            RequestCollisionAtCoord(slotCoords.x, slotCoords.y, slotCoords.z)
        end
        if HasCollisionLoadedAroundEntity(ped) then
            return true
        end
        Wait(50)
    end
    return false
end

--- Applies a named emote to a freshly-spawned preview ped. Returns the list
--- of helper entities (props) created so they can be cleaned up alongside the
--- ped. Falls back to the scene profile scenario when no emote is configured.
---
--- Scenario / anim start is DEFERRED into a CreateThread that waits for
--- `HasCollisionLoadedAroundEntity` first. This prevents the engine's
--- scenario controller from spawning its own world props (smoke, lighter,
--- bottles, etc.) on a floor that's still streaming in.
local function applyEmote(ped, emoteName, slotCoords, heading, slotIndex, character)
    local props = {}
    --- Diagnostic: skip every emote/scenario/prop branch entirely when
    --- DisablePreviewEmotes is on. This rules out scenario task scheduling,
    --- attached prop streaming, and anim dict races as crash sources without
    --- altering the rest of the lineup flow.
    if W2F.Diag and W2F.Diag.Flag and W2F.Diag.Flag('DisablePreviewEmotes') then
        W2F.Diag.Log('Streaming', 'applyEmote skipped (DisablePreviewEmotes) slot=%d', slotIndex or -1)
        return props, nil
    end
    local def = emoteName and Config.Emotes and Config.Emotes[emoteName] or nil

    if def then
        --- World prop spawned at the slot (e.g. chair the ped sits on).
        if def.prop and def.prop.model then
            local propHash = type(def.prop.model) == 'string' and joaat(def.prop.model) or def.prop.model
            if IsModelInCdimage(propHash) then
                lib.requestModel(propHash, 5000)
                local propZ = slotCoords.z + (def.prop.offsetZ or 0.0)
                local prop = CreateObject(propHash, slotCoords.x, slotCoords.y, propZ, false, true, false)
                if prop and prop ~= 0 then
                    SetEntityHeading(prop, heading)
                    if def.prop.placeOnGround ~= false then
                        PlaceObjectOnGroundProperly(prop)
                    end
                    FreezeEntityPosition(prop, true)
                    SetEntityCollision(prop, true, true)
                    props[#props + 1] = prop
                end
                SetModelAsNoLongerNeeded(propHash)
            end
        end

        --- Scenario takes priority. When a prop is also configured, start it
        --- *at the prop's position* so PROP_HUMAN_SEAT_CHAIR-style scenarios
        --- snap the ped onto the prop. Without a prop, run in-place.
        ---
        --- Deferred behind a collision wait — see comment on `applyEmote`.
        if def.scenario then
            local hasOurProp = #props > 0
            local scenarioName = def.scenario
            local sx, sy, sz = slotCoords.x, slotCoords.y, slotCoords.z
            CreateThread(function()
                waitForPedCollision(ped, slotCoords, 2500)
                if not DoesEntityExist(ped) then return end
                if hasOurProp then
                    TaskStartScenarioAtPosition(ped, scenarioName, sx, sy, sz, heading, 0, true, false)
                else
                    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
                end
                if W2F.Diag and W2F.Diag.Log then
                    W2F.Diag.Log('Streaming', 'scenario started slot=%s name=%s (after collision wait)',
                        tostring(slotIndex), tostring(scenarioName))
                end
            end)
        elseif def.anim and def.anim.dict and def.anim.clip then
            pcall(function() lib.requestAnimDict(def.anim.dict, 5000) end)
            if HasAnimDictLoaded(def.anim.dict) then
                --- Anim dict is loaded — record now so cleanup can release
                --- it even if the ped is removed before the deferred play
                --- block fires.
                W2F.Characters._heldAnimDicts = W2F.Characters._heldAnimDicts or {}
                W2F.Characters._heldAnimDicts[ped] = def.anim.dict

                local dict, clip = def.anim.dict, def.anim.clip
                CreateThread(function()
                    waitForPedCollision(ped, slotCoords, 2500)
                    if not DoesEntityExist(ped) then return end
                    TaskPlayAnim(ped, dict, clip, 8.0, -8.0, -1, 1, 0, false, false, false)
                end)
            end
        end

        --- Optional prop attached to a bone (e.g. whiskey glass in the hand).
        if def.attachProp and def.attachProp.model then
            local apHash = type(def.attachProp.model) == 'string' and joaat(def.attachProp.model) or def.attachProp.model
            if IsModelInCdimage(apHash) then
                lib.requestModel(apHash, 5000)
                local pc = GetEntityCoords(ped)
                local attach = CreateObject(apHash, pc.x, pc.y, pc.z, false, true, false)
                if attach and attach ~= 0 then
                    SetEntityCollision(attach, false, false)
                    local boneIdx = GetPedBoneIndex(ped, def.attachProp.bone or 60309)
                    local ox = def.attachProp.offset and def.attachProp.offset.x or 0.0
                    local oy = def.attachProp.offset and def.attachProp.offset.y or 0.0
                    local oz = def.attachProp.offset and def.attachProp.offset.z or 0.0
                    local rx = def.attachProp.rot and def.attachProp.rot.x or 0.0
                    local ry = def.attachProp.rot and def.attachProp.rot.y or 0.0
                    local rz = def.attachProp.rot and def.attachProp.rot.z or 0.0
                    AttachEntityToEntity(attach, ped, boneIdx, ox, oy, oz, rx, ry, rz, true, true, false, true, 1, true)
                    props[#props + 1] = attach
                end
                SetModelAsNoLongerNeeded(apHash)
            end
        end
    else
        --- No emote → use the scene profile scenario (legacy behavior),
        --- deferred behind the same collision wait as the curated path.
        local profileName = getProfileForCharacter(character)
        local profile = Config.SceneProfiles and Config.SceneProfiles[profileName]
        local scenario = (profile and profile.animation) or fallbackScenarios[((slotIndex - 1) % #fallbackScenarios) + 1]
        CreateThread(function()
            waitForPedCollision(ped, slotCoords, 2500)
            if not DoesEntityExist(ped) then return end
            TaskStartScenarioInPlace(ped, scenario, 0, true)
        end)
    end

    return props, def
end

--- Keeps a preview ped locked to its configured slot (scenarios can nudge them).
local function anchorPedToSlot(ped, slotCoords, heading)
    if not ped or not DoesEntityExist(ped) or not slotCoords then return end
    SetEntityCoordsNoOffset(ped, slotCoords.x, slotCoords.y, slotCoords.z, false, false, false)
    SetEntityHeading(ped, heading)
end

--- Placeholder ped for an unused visual slot (click to create a character).
function W2F.Characters.SpawnEmptySlotPed(slotIndex)
    local slot = Config.Scene.pedSlots[slotIndex]
    if not slot then return nil end

    local slotCoords = Config.GetSlotCoords(slot)
    local slotEmote = Config.GetSlotEmote(slot)
    if not slotCoords then return nil end

    RequestCollisionAtCoord(slotCoords.x, slotCoords.y, slotCoords.z)

    local hash = loadModel(`mp_m_freemode_01`)
    local heading = resolveSlotHeading(slotCoords, slotEmote)
    local ped = CreatePed(4, hash, slotCoords.x, slotCoords.y, slotCoords.z, heading, false, true)

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityCollision(ped, true, true)
    SetEntityHeading(ped, heading)
    SetEntityAlpha(ped, 140, false)

    local props = applyEmote(ped, slotEmote, slotCoords, heading, slotIndex, nil)
    anchorPedToSlot(ped, slotCoords, heading)
    FreezeEntityPosition(ped, true)

    W2F.State.previewPeds[slotIndex] = {
        ped = ped,
        character = nil,
        slot = slotIndex,
        props = props,
        emote = slotEmote,
        isEmpty = true,
    }

    SetModelAsNoLongerNeeded(hash)
    W2F.Characters.ApplyHighlight(ped, 'none', true)
    return ped
end

function W2F.Characters.GetNextAvailableVisualSlot()
    for i = 1, #Config.Scene.pedSlots do
        local entry = W2F.State.previewPeds[i]
        if entry and entry.isEmpty then
            return i
        end
    end
    return nil
end

function W2F.Characters.SpawnPreviewPed(slotIndex, character)
    local slot = Config.Scene.pedSlots[slotIndex]
    if not slot or not character then return nil end

    local slotCoords = Config.GetSlotCoords(slot)
    local slotEmote = resolvePreviewEmote(character, slot)
    if not slotCoords then return nil end

    RequestCollisionAtCoord(slotCoords.x, slotCoords.y, slotCoords.z)

    local model, appearance = resolveModel(character)
    local hash = loadModel(model)
    local heading = resolveSlotHeading(slotCoords, slotEmote)
    local ped = CreatePed(4, hash, slotCoords.x, slotCoords.y, slotCoords.z, heading, false, true)

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityCollision(ped, true, true)
    SetEntityHeading(ped, heading)

    W2F.Qbox.ApplyAppearanceToPed(ped, hash, appearance)

    local props, emoteDef = applyEmote(ped, slotEmote, slotCoords, heading, slotIndex, character)

    --- Re-anchor after emote starts (scenarios / seat snaps can drift the ped).
    anchorPedToSlot(ped, slotCoords, heading)
    if emoteDef and (emoteDef.prop or emoteDef.scenario) then
        CreateThread(function()
            Wait(400)
            if DoesEntityExist(ped) then
                anchorPedToSlot(ped, slotCoords, heading)
                FreezeEntityPosition(ped, true)
            end
        end)
    else
        FreezeEntityPosition(ped, true)
    end

    W2F.State.previewPeds[slotIndex] = {
        ped = ped,
        character = character,
        slot = slotIndex,
        props = props,
        emote = slotEmote,
    }

    SetModelAsNoLongerNeeded(hash)
    return ped
end

--- Stream collision / interior at every ped slot (ped 2/3 are far from slot 1).
--- Keeps a persistent streaming handle (focus + scene sphere + per-frame
--- collision) for the whole selection session so cold boot loads the MLO
--- before the overview camera is activated.
function W2F.Characters.ReleaseSceneStream()
    if W2F.Characters.sceneStreamHandle and W2F.Streaming and W2F.Streaming.Release then
        W2F.Streaming.Release(W2F.Characters.sceneStreamHandle)
    end
    W2F.Characters.sceneStreamHandle = nil
end

local function waitForSelectionSceneReady(ped, focal, slots, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 15000)
    --- When Streaming.Acquire already owns focus/collision, don't duplicate
    --- SetFocusPosAndVel every 50 ms — that was doubling dispatcher load.
    local streamActive = W2F.Characters.sceneStreamHandle
        and not W2F.Characters.sceneStreamHandle.released

    while GetGameTimer() < deadline do
        if W2F.Render and W2F.Render.EnforcePedAnchor then
            W2F.Render.EnforcePedAnchor()
        end
        ped = PlayerPedId()

        --- Always prime every anchor (focal, camera, slots). The streaming
        --- handle only re-requests collision at focal — without this the
        --- overview camera and outer slot peds render into unloaded void.
        if W2F.Render and W2F.Render.PrimeScenePoints then
            W2F.Render.PrimeScenePoints()
        end

        if W2F.Interior and W2F.Interior.TryPinAt then
            W2F.Interior.TryPinAt(focal)
        end

        if not streamActive and focal and SetFocusPosAndVel then
            SetFocusPosAndVel(focal.x, focal.y, focal.z, 0.0, 0.0, 0.0)
        end

        local collisionReady = HasCollisionLoadedAroundEntity(ped)
        local anchored = false
        if W2F.Render and W2F.Render.GetPedAnchorCoords then
            local anchor = W2F.Render.GetPedAnchorCoords(focal)
            if anchor then
                local c = GetEntityCoords(ped)
                local dx = c.x - anchor.x
                local dy = c.y - anchor.y
                local dz = c.z - anchor.z
                anchored = (dx * dx + dy * dy + dz * dz) <= 4.0
            end
        end
        if not anchored then
            collisionReady = false
        end

        local sceneReady = true
        if IsNewLoadSceneActive and IsNewLoadSceneActive() then
            sceneReady = IsNewLoadSceneLoaded and IsNewLoadSceneLoaded() or false
        end

        local interiorReady = true
        if W2F.Interior and W2F.Interior.IsValidInterior and W2F.Interior.IsReady then
            local interiorId = W2F.Interior.interiorId
            if W2F.Interior.IsValidInterior(interiorId) then
                interiorReady = W2F.Interior.IsReady()
            end
        end

        if collisionReady and sceneReady and interiorReady then
            return true
        end
        Wait(50)
    end

    --- Timed out — still enforce anchor so the camera doesn't frame void.
    if W2F.Render and W2F.Render.EnforcePedAnchor then
        W2F.Render.EnforcePedAnchor()
    end

    return false
end

--- After the MLO is loaded, swap the heavy load-scene handle for a lightweight
--- focus-only keepalive so we don't keep NewLoadSceneStartSphere + per-frame
--- collision pressure active for the entire selection session.
function W2F.Characters.RelaxSceneStream()
    local forceRelax = W2F.Diag and W2F.Diag.Flag and W2F.Diag.Flag('ForceRelaxScene')
    if not forceRelax and W2F.Interior and W2F.Interior.ShouldKeepSceneSphere and W2F.Interior.ShouldKeepSceneSphere() then
        if W2F.Diag and W2F.Diag.Log then
            W2F.Diag.Log('Streaming', 'RelaxSceneStream: skipped (interior keepSceneSphere)')
        end
        return
    end
    local perf = Config.Performance or {}
    if perf.relaxStreamAfterLoad == false then return end
    if not (W2F.Streaming and W2F.Streaming.Acquire) then return end

    local focal = Config.GetSceneFocal()
    W2F.Characters.ReleaseSceneStream()

    W2F.Characters.sceneStreamHandle = W2F.Streaming.Acquire(focal, {
        radius = (Config.Startup and Config.Startup.sceneStreamRadius) or 90.0,
        keepThread = true,
        keepThreadIntervalMs = (W2F.Performance and W2F.Performance.StreamKeepaliveMs and W2F.Performance.StreamKeepaliveMs()) or 750,
        focusRefreshMs = (W2F.Performance and W2F.Performance.StreamFocusRefreshMs and W2F.Performance.StreamFocusRefreshMs()) or 4000,
        followCamera = false,
        focus = true,
        scene = false,
    })

    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'RelaxSceneStream: switched to focus-only keepalive')
    end
end

function W2F.Characters.PrepareScene()
    local slots = Config.Scene.pedSlots
    if not slots or #slots == 0 then return end

    W2F.Characters.ReleaseSceneStream()

    local ped = PlayerPedId()
    local focal = Config.GetSceneFocal()
    local startup = Config.Startup or {}
    local radius = startup.sceneStreamRadius or 90.0
    if W2F.Interior and W2F.Interior.ResolveStreamRadius then
        radius = W2F.Interior.ResolveStreamRadius(radius)
    elseif W2F.Diag and W2F.Diag.ResolveStreamRadius then
        radius = W2F.Diag.ResolveStreamRadius(radius)
    end
    local timeoutMs = startup.sceneCollisionTimeoutMs or 15000

    if W2F.Diag and W2F.Diag.Log then
        W2F.Diag.Log('Streaming', 'PrepareScene focal=(%.1f,%.1f,%.1f) radius=%.1f slots=%d',
            focal.x, focal.y, focal.z, radius, #slots)
    end

    if W2F.Render and W2F.Render.PlacePlayerForStreaming then
        W2F.Render.PlacePlayerForStreaming(focal)
    else
        SetEntityCoords(ped, focal.x, focal.y, focal.z, false, false, false, false)
    end

    if W2F.Streaming and W2F.Streaming.Acquire then
        local keepaliveMs = (W2F.Interior and W2F.Interior.StreamKeepaliveMs and W2F.Interior.StreamKeepaliveMs()) or 100
        local focusRefresh = (W2F.Interior and W2F.Interior.StreamFocusRefreshMs and W2F.Interior.StreamFocusRefreshMs()) or 500
        W2F.Characters.sceneStreamHandle = W2F.Streaming.Acquire(focal, {
            radius = radius,
            keepThread = true,
            keepThreadIntervalMs = keepaliveMs,
            focusRefreshMs = focusRefresh,
            --- Overview camera is fixed — followCamera only adds collision load.
            followCamera = false,
            focus = true,
            scene = true,
        })
    else
        for i = 1, #slots do
            local c = Config.GetSlotCoords(slots[i])
            if c then
                RequestCollisionAtCoord(c.x, c.y, c.z)
                NewLoadSceneStartSphere(c.x, c.y, c.z, radius, 0)
            end
        end
        if SetFocusPosAndVel then
            SetFocusPosAndVel(focal.x, focal.y, focal.z, 0.0, 0.0, 0.0)
        end
    end

    if W2F.Interior and W2F.Interior.Acquire then
        W2F.Interior.Acquire(focal, timeoutMs)
    end

    local ready = waitForSelectionSceneReady(ped, focal, slots, timeoutMs)
    if not ready and W2F.Debug then
        W2F.Debug('PrepareScene: scene/collision wait timed out after %dms', timeoutMs)
    end

    --- Drop NewLoadSceneStartSphere once loaded — keeping it active for the
    --- whole session forces the engine to re-evaluate streaming every tick.
    if ready and W2F.Characters.RelaxSceneStream then
        W2F.Characters.RelaxSceneStream()
    end

    --- Player stays at focal until BuildLineup finishes (see main.lua).
    --- Hiding underground before preview peds spawn caused void rendering.
end

--- Called after preview peds exist so streaming probes stay valid during spawn.
function W2F.Characters.FinalizeScenePresentation()
    local focal = Config.GetSceneFocal()
    if W2F.Render and W2F.Render.HideLocalPlayer then
        W2F.Render.HideLocalPlayer(focal)
    else
        local ped = cache.ped or PlayerPedId()
        local sceneInterior = Config.Scene and Config.Scene.interior or {}
        local keepUnderground = W2F.Diag and W2F.Diag.Flag and W2F.Diag.Flag('KeepPlayerUnderground')
        local keepInside = not keepUnderground and sceneInterior.keepPlayerInside ~= false
        local hideZ = keepInside and focal.z or (focal.z - 50.0)
        SetEntityCoords(ped, focal.x, focal.y, hideZ, false, false, false, false)
    end
    if W2F.Render and W2F.Render.PrimeScenePoints then
        W2F.Render.PrimeScenePoints()
    end
end

--- Assigns each character to a visual ped slot. After creation, the new
--- character is forced into `pendingVisualSlot` (the slot the player clicked).
local function buildVisualAssignments(characters)
    local maxVisual = #Config.Scene.pedSlots
    local assignments = {}
    for i = 1, maxVisual do
        assignments[i] = nil
    end

    local ordered = {}
    for slot, character in pairs(characters) do
        if type(slot) == 'number' and character then
            ordered[#ordered + 1] = { cid = slot, character = character }
        end
    end
    table.sort(ordered, function(a, b) return a.cid < b.cid end)

    local pendingCid = W2F.State.pendingNewCitizenid
    local pendingSlot = W2F.State.pendingVisualSlot
    local newChar, others = nil, {}

    if pendingCid then
        for i = 1, #ordered do
            local entry = ordered[i]
            if entry.character.citizenid == pendingCid then
                newChar = entry.character
            else
                others[#others + 1] = entry.character
            end
        end
    end

    if newChar and pendingSlot and pendingSlot >= 1 and pendingSlot <= maxVisual then
        assignments[pendingSlot] = newChar
        local vi = 1
        for i = 1, #others do
            while vi <= maxVisual and assignments[vi] do
                vi = vi + 1
            end
            if vi <= maxVisual then
                assignments[vi] = others[i]
            end
        end
    else
        for i = 1, maxVisual do
            if ordered[i] then
                assignments[i] = ordered[i].character
            end
        end
    end

    return assignments
end

--- Tears down an existing entry (ped + props + outline + anim dict) so we
--- don't leak entities when respawning a ped at the same slot.
local function teardownSlot(slot)
    local entry = W2F.State.previewPeds[slot]
    if not entry then return end
    local heldDicts = W2F.Characters._heldAnimDicts or {}
    local outlinesEnabled = (Config.Highlight and Config.Highlight.enabled) ~= false
    if entry.ped and DoesEntityExist(entry.ped) then
        if outlinesEnabled then
            pcall(SetEntityDrawOutline, entry.ped, false)
        end
        local dict = heldDicts[entry.ped]
        if dict then
            pcall(function() RemoveAnimDict(dict) end)
            heldDicts[entry.ped] = nil
        end
        DeleteEntity(entry.ped)
    end
    if entry.props then
        for i = 1, #entry.props do
            local prop = entry.props[i]
            if prop and DoesEntityExist(prop) then DeleteEntity(prop) end
        end
    end
    W2F.Characters._heldAnimDicts = heldDicts
    W2F.State.previewPeds[slot] = nil
end

function W2F.Characters.RefreshPedAppearance(citizenid)
    if not citizenid then return false end
    W2F.State.modelCache[citizenid] = nil
    W2F.State.appearanceCache[citizenid] = nil

    for slot, entry in pairs(W2F.State.previewPeds) do
        if entry and entry.character and entry.character.citizenid == citizenid then
            local ped = entry.ped
            if ped and DoesEntityExist(ped) then
                local model = (resolveModel(entry.character))
                local hash = loadModel(model)
                if GetEntityModel(ped) ~= hash then
                    --- Model changed: full teardown + respawn so the old ped
                    --- + props don't leak (the legacy SpawnPreviewPed only
                    --- replaced the table entry without deleting the ped).
                    teardownSlot(slot)
                    W2F.Characters.SpawnPreviewPed(slot, entry.character)
                else
                    local _, appearance = resolveModel(entry.character)
                    W2F.Qbox.ApplyAppearanceToPed(ped, hash, appearance)
                    W2F.Characters.RefreshHighlights()
                end
                return true
            end
            --- Entity vanished — just respawn into the slot.
            teardownSlot(slot)
            W2F.Characters.SpawnPreviewPed(slot, entry.character)
            return true
        end
    end
    return false
end

function W2F.Characters.BuildLineup(characters)
    W2F.Characters.ClearPreviewPeds()
    W2F.State.characters = characters or {}
    W2F.Characters.lastPlayedCitizenid = getLastPlayedCitizenid(characters)
    applySceneLighting('neutral')

    local assignments = buildVisualAssignments(characters)
    local maxVisual = #Config.Scene.pedSlots
    for i = 1, maxVisual do
        if assignments[i] then
            W2F.Characters.SpawnPreviewPed(i, assignments[i])
        else
            W2F.Characters.SpawnEmptySlotPed(i)
        end
    end

    W2F.Characters.RefreshHighlights()
end

--- Selects the lineup ped matching the given citizenid. Used by the
--- post-creation flow so the new character is auto-focused.
function W2F.Characters.AutoSelectByCitizenid(citizenid)
    if not citizenid then return false end
    for slot, entry in pairs(W2F.State.previewPeds) do
        if entry and entry.character and entry.character.citizenid == citizenid then
            W2F.Characters.SelectSlot(slot, entry)
            return true
        end
    end
    return false
end

function W2F.Characters.OpenCreateForSlot(visualSlot)
    if W2F.Creator and W2F.Creator.OpenRegistration then
        W2F.Creator.OpenRegistration(visualSlot)
    end
end

--- Delete the currently selected character (after NUI confirmation).
function W2F.Characters.DeleteSelected()
    local character = W2F.State.selectedCharacter
    if not character or not character.citizenid then
        return
    end

    local citizenid = character.citizenid
    local ok, err = lib.callback.await('w2f-multicharacter:server:deleteCharacter', false, citizenid)
    if not ok then
        local message = type(err) == 'string' and err or 'Failed to delete character.'

        lib.notify({
            title = 'Delete Character',
            description = message,
            type = 'error',
        })

        if W2F.Nui and W2F.Nui.Send then
            W2F.Nui.Send('characterDeleteFailed', { error = message })
        elseif W2F.SendNui then
            W2F.SendNui('characterDeleteFailed', { error = message })
        else
            SendNUIMessage({
                action = 'characterDeleteFailed',
                data = { error = message },
            })
        end

        return
    end

    --- Wipe local caches for this character so a refresh doesn't re-spawn it.
    W2F.State.modelCache[citizenid] = nil
    W2F.State.appearanceCache[citizenid] = nil

    W2F.Characters.ClearSelection()
    W2F.SendNui('characterDeleted', { citizenid = citizenid })

    --- Rebuild the lineup with the updated character list.
    W2F.Characters.ClearPreviewPeds()
    local characters = W2F.Qbox.FetchCharacters()
    W2F.Characters.BuildLineup(characters)

    lib.notify({
        title = 'Character Deleted',
        description = ('%s %s'):format(
            character.charinfo and character.charinfo.firstname or 'Character',
            character.charinfo and character.charinfo.lastname or ''
        ),
        type = 'success',
    })
end

--- Picks the best ped under the cursor using screen-space distance to several
--- body sample points (head / chest / torso). Sticky hover prevents flicker
--- when moving between adjacent lineup peds.
function W2F.Characters.FindPedAtCursor()
    local interaction = Config.Interaction
    local cursorX, cursorY = GetNuiCursorPosition()
    local resX, resY = GetActiveScreenResolution()
    if not resX or resX == 0 then resX, resY = 1920, 1080 end
    --- Cursor coords of 0 are LEGITIMATE (top-left of the screen). Treat
    --- only nil as missing — the old `<= 0` check would silently snap the
    --- cursor to the center whenever the player picked the upper-left ped.
    if cursorX == nil then cursorX = resX * 0.5 end
    if cursorY == nil then cursorY = resY * 0.5 end

    local heights = (W2F.Performance and W2F.Performance.PedSampleHeights and W2F.Performance.PedSampleHeights())
        or interaction.pedSampleHeights or { 0.68, 1.05 }
    local stickiness = interaction.hoverStickiness or 0.68
    local currentHovered = W2F.State.hoveredPed

    local bestSlot, bestEntry, bestScore = nil, nil, nil

    local function screenDistToPoint(worldPoint)
        local onScreen, sx, sy = W2F.World3DToScreen(worldPoint)
        if not onScreen then return nil end
        local px = sx * resX
        local py = sy * resY
        local dx = px - cursorX
        local dy = py - cursorY
        return math.sqrt(dx * dx + dy * dy)
    end

    for slot, entry in pairs(W2F.State.previewPeds) do
        local ped = entry.ped
        if ped and DoesEntityExist(ped) then
            local radius = entry.isEmpty
                and (interaction.pedSelectScreenRadiusEmpty or interaction.pedSelectScreenRadius or 240)
                or (interaction.pedSelectScreenRadius or 240)

            local pedCoords = GetEntityCoords(ped)
            local minDist = nil
            for i = 1, #heights do
                local point = vector3(pedCoords.x, pedCoords.y, pedCoords.z + heights[i])
                local dist = screenDistToPoint(point)
                if dist and (not minDist or dist < minDist) then
                    minDist = dist
                end
            end

            if minDist and minDist <= radius then
                local score = minDist
                if currentHovered == ped then
                    score = score * stickiness
                end
                if not bestScore or score < bestScore then
                    bestScore = score
                    bestSlot = slot
                    bestEntry = entry
                end
            end
        end
    end

    if bestSlot then
        return bestSlot, bestEntry
    end

    --- Fallback: 3D ray cylinder for peds partially off-screen.
    local origin, direction = W2F.ScreenToWorldRay()
    return W2F.Characters.FindPedNearRay(origin, direction)
end

--- Legacy ray-cylinder picker — used as fallback when screen-space misses.
--- The screen radius now matches the primary picker (`pedSelectScreenRadius`)
--- so hovering at the edge of a ped doesn't suddenly fall through to a
--- much smaller pick zone.
function W2F.Characters.FindPedNearRay(origin, direction)
    local bestSlot, bestEntry, bestScore = nil, nil, nil
    local interaction = Config.Interaction
    local maxDist = interaction.hoverDistance or interaction.rayMaxDistance or 120.0
    local selectRadius = interaction.pedSelectRadius or 3.0
    --- Use the same screenRadius the primary picker uses. The legacy default
    --- of 110 was tighter than the primary 240, which created a dead zone
    --- around peds where neither picker accepted the click.
    local screenRadius = interaction.pedSelectScreenRadiusFallback
        or interaction.pedSelectScreenRadius or 240
    local aimHeight = interaction.pedAimHeight or 0.95

    local cursorX, cursorY = GetNuiCursorPosition()
    local resX, resY = GetActiveScreenResolution()
    if not resX or resX == 0 then resX, resY = 1920, 1080 end
    if cursorX == nil then cursorX = resX * 0.5 end
    if cursorY == nil then cursorY = resY * 0.5 end

    for slot, entry in pairs(W2F.State.previewPeds) do
        local ped = entry.ped
        if ped and DoesEntityExist(ped) then
            local pedCoords = GetEntityCoords(ped)
            local pedTarget = vector3(pedCoords.x, pedCoords.y, pedCoords.z + aimHeight)

            local onScreen, sx, sy = W2F.World3DToScreen(pedTarget)
            local screenDist
            if onScreen and sx >= 0 and sx <= 1 and sy >= 0 and sy <= 1 then
                local px = sx * resX
                local py = sy * resY
                local ddx = px - cursorX
                local ddy = py - cursorY
                screenDist = math.sqrt(ddx * ddx + ddy * ddy)
            end

            local oc = pedTarget - origin
            local proj = oc.x * direction.x + oc.y * direction.y + oc.z * direction.z
            local rayDist
            if proj > 0.0 and proj < maxDist then
                local closest = vector3(
                    origin.x + direction.x * proj,
                    origin.y + direction.y * proj,
                    origin.z + direction.z * proj
                )
                rayDist = #(pedTarget - closest)
            end

            local viaScreen = screenDist and screenDist <= screenRadius
            local viaRay = rayDist and rayDist <= selectRadius
            if viaScreen or viaRay then
                local score = screenDist or (rayDist * 100.0)
                if not bestScore or score < bestScore then
                    bestScore = score
                    bestSlot = slot
                    bestEntry = entry
                end
            end
        end
    end

    return bestSlot, bestEntry
end

function W2F.Characters.GetDetailsPayload(character)
    if not character then return nil end

    local charinfo = character.charinfo or {}
    local money = character.money or {}
    local metadata = character.metadata or {}
    local job = character.job or {}
    local jobLabel = job.label or job.name or 'Unemployed'

    local lastLabel = 'Unknown'
    local position = character.position or metadata.position or metadata.lastlocation
    if type(position) == 'table' then
        if position.label then
            lastLabel = position.label
        elseif position.x and position.y then
            lastLabel = ('%.0f, %.0f'):format(position.x, position.y)
        end
    end

    return {
        citizenid = character.citizenid,
        name = ('%s %s'):format(charinfo.firstname or 'Unknown', charinfo.lastname or ''),
        job = jobLabel,
        cash = W2F.FormatMoney(money.cash or 0),
        bank = W2F.FormatMoney(money.bank or 0),
        playtime = W2F.FormatPlaytime(metadata.playtime or metadata.timeplayed or 0),
        lastLocation = lastLabel,
        slot = character.cid or character.slot,
    }
end

function W2F.Characters.SelectSlot(slot, entry)
    if W2F.State.isCreatePanelOpen or W2F.State.isCreatingCharacter then
        return
    end
    if not entry or not entry.character then return end
    if W2F.State.selectedSlot == slot and W2F.State.selectedPed == entry.ped then
        return
    end
    --- Debounce at entry, not after server accept, so a fat-finger double-
    --- click doesn't fire two callbacks and inflate the rate-limit budget.
    if not W2F.CanClick() then return end
    W2F.MarkPedClick()

    local citizenid = entry.character.citizenid
    local payload = W2F.Characters.GetDetailsPayload(entry.character)

    --- Optimistic client feedback — don't wait on the server round-trip.
    W2F.PlayW2FSound(Config.Audio.select)
    W2F.SetSelected(slot, entry.ped, entry.character)
    applySceneLighting(getProfileForCharacter(entry.character))
    W2F.Camera.FocusOnPed(entry.ped)
    W2F.Characters.RefreshHighlights()
    if W2F.Hud and W2F.Hud.Show then
        W2F.Hud.Show(payload)
    end
    W2F.SendNui('showCharacterDetails', payload)
    W2F.SendNui('updateSelectedPed', { slot = slot })

    local accepted = lib.callback.await('w2f-multicharacter:server:selectCharacter', false, citizenid)
    if not accepted then
        W2F.PlayFrontendSound('ERROR')
        W2F.Characters.ClearSelection()
        return
    end

    W2F.PlayW2FSound(Config.Audio.detailsOpen)
end

function W2F.Characters.ClearSelection()
    W2F.SetSelected(nil, nil, nil)
    applySceneLighting('neutral')
    W2F.Camera.ReturnToOverview()
    W2F.Characters.RefreshHighlights()
    if W2F.Hud and W2F.Hud.Hide then
        W2F.Hud.Hide()
    end
    W2F.SendNui('hideCharacterDetails')
    W2F.SendNui('updateSelectedPed', { slot = nil })
end
