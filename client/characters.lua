W2F.Characters = {}

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

    return model, appearance
end

function W2F.Characters.ClearPreviewPeds()
    for _, entry in pairs(W2F.State.previewPeds) do
        if entry.ped and DoesEntityExist(entry.ped) then
            SetEntityDrawOutline(entry.ped, false)
            DeleteEntity(entry.ped)
        end
    end
    W2F.State.previewPeds = {}
end

function W2F.Characters.ApplyHighlight(ped, mode)
    if not ped or not DoesEntityExist(ped) then return end
    local hl = Config.Highlight

    if mode == 'selected' then
        SetEntityDrawOutline(ped, true)
        SetEntityDrawOutlineColor(hl.selectedColor.r, hl.selectedColor.g, hl.selectedColor.b, 255)
        ResetEntityAlpha(ped)
    elseif mode == 'hover' then
        SetEntityDrawOutline(ped, true)
        SetEntityDrawOutlineColor(hl.outlineColor.r, hl.outlineColor.g, hl.outlineColor.b, 180)
        ResetEntityAlpha(ped)
    else
        SetEntityDrawOutline(ped, false)
        SetEntityAlpha(ped, 210, false)
    end
end

function W2F.Characters.RefreshHighlights()
    for _, entry in pairs(W2F.State.previewPeds) do
        local ped = entry.ped
        if ped and DoesEntityExist(ped) then
            if W2F.State.selectedPed == ped then
                W2F.Characters.ApplyHighlight(ped, 'selected')
            elseif W2F.State.hoveredPed == ped then
                W2F.Characters.ApplyHighlight(ped, 'hover')
            else
                W2F.Characters.ApplyHighlight(ped, 'none')
            end
        end
    end
end

function W2F.Characters.SpawnPreviewPed(slotIndex, character)
    local slotCoords = Config.Scene.pedSlots[slotIndex]
    if not slotCoords or not character then return nil end

    local model, appearance = resolveModel(character)
    local hash = loadModel(model)
    local ped = CreatePed(4, hash, slotCoords.x, slotCoords.y, slotCoords.z, slotCoords.w, false, true)

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityCollision(ped, true, true)

    W2F.Qbox.ApplyAppearanceToPed(ped, hash, appearance)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)

    W2F.State.previewPeds[slotIndex] = {
        ped = ped,
        character = character,
        slot = slotIndex,
    }

    SetModelAsNoLongerNeeded(hash)
    return ped
end

function W2F.Characters.BuildLineup(characters)
    W2F.Characters.ClearPreviewPeds()
    W2F.State.characters = characters or {}

    for slot, character in pairs(characters) do
        if type(slot) == 'number' and character then
            W2F.Characters.SpawnPreviewPed(slot, character)
        end
    end
end

function W2F.Characters.FindPedNearRay(origin, direction)
    local bestSlot, bestEntry, bestDist = nil, nil, nil
    local maxDist = Config.Interaction.rayMaxDistance
    local selectRadius = Config.Interaction.pedSelectRadius

    for slot, entry in pairs(W2F.State.previewPeds) do
        local ped = entry.ped
        if ped and DoesEntityExist(ped) then
            local pedCoords = GetEntityCoords(ped)
            local oc = pedCoords - origin
            local proj = oc.x * direction.x + oc.y * direction.y + oc.z * direction.z
            if proj > 0.0 and proj < maxDist then
                local closest = vector3(
                    origin.x + direction.x * proj,
                    origin.y + direction.y * proj,
                    origin.z + direction.z * proj
                )
                local dist = #(pedCoords - closest)
                if dist <= selectRadius and (not bestDist or dist < bestDist) then
                    bestDist = dist
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
    if not entry or not entry.character then return end
    W2F.MarkClick()
    W2F.SetSelected(slot, entry.ped, entry.character)
    W2F.Characters.RefreshHighlights()
    W2F.SendNui('showCharacterDetails', W2F.Characters.GetDetailsPayload(entry.character))
    W2F.SendNui('updateSelectedPed', { slot = slot })
end

function W2F.Characters.ClearSelection()
    W2F.SetSelected(nil, nil, nil)
    W2F.Characters.RefreshHighlights()
    W2F.SendNui('hideCharacterDetails', {})
    W2F.SendNui('updateSelectedPed', { slot = nil })
end
