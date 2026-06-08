W2F.Qbox = {}

function W2F.Qbox.IsActive()
    return Config.UseQbox and GetResourceState('qbx_core') == 'started'
end

---@return table[] characters indexed by slot (cid)
function W2F.Qbox.FetchCharacters()
    local function safeAwait(name, ...)
        local ok, result = pcall(lib.callback.await, name, false, ...)
        if not ok then
            W2F.Debug('FetchCharacters callback failed: %s', tostring(result))
            return nil
        end
        return result
    end

    if not W2F.Qbox.IsActive() then
        return safeAwait('w2f-multicharacter:server:getCharacters') or {}
    end

    local characters, amount = safeAwait('qbx_core:server:getCharacters')
    local list = {}

    if characters then
        local maxSlots = amount or Config.MaxCharacters or #Config.Scene.pedSlots
        for i = 1, maxSlots do
            if characters[i] then
                list[i] = characters[i]
            end
        end
    end

    if next(list) then
        return list
    end

    return safeAwait('w2f-multicharacter:server:getCharacters') or {}
end

---@return number? modelHash
---@return table? appearance
function W2F.Qbox.GetPreviewPedData(citizenid)
    if not citizenid or not W2F.Qbox.IsActive() then
        return nil, nil
    end

    local clothing, model = lib.callback.await('qbx_core:server:getPreviewPedData', false, citizenid)
    if not model then
        return nil, nil
    end

    local appearance = clothing
    if type(clothing) == 'string' then
        --- A corrupt/truncated playerskins.skin row would throw here and abort
        --- the whole BuildLineup loop, locking the account out of selection.
        --- Degrade to nil so ApplyAppearanceToPed falls back to the default ped.
        local ok, decoded = pcall(json.decode, clothing)
        appearance = ok and decoded or nil
    end

    return model, appearance
end

---@param ped number
---@param model number
---@param appearance table?
function W2F.Qbox.ApplyAppearanceToPed(ped, model, appearance)
    if not ped or not DoesEntityExist(ped) or not model then
        return
    end

    if GetEntityModel(ped) ~= model then
        return
    end

    if appearance and GetResourceState('illenium-appearance') == 'started' then
        exports['illenium-appearance']:setPedAppearance(ped, appearance)
    end
end

--- `W2F.Qbox.LoadCharacterAt` was removed in Phase 7. Use
--- `W2F.CharacterLoad.Load(opts)` instead (`client/services/character_load.lua`).
--- The new service returns explicit `(ok, reason)` instead of a boolean that
--- silently swallowed partial failures.
