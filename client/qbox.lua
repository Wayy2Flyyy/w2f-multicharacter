W2F.Qbox = {}

function W2F.Qbox.IsActive()
    return Config.UseQbox and GetResourceState('qbx_core') == 'started'
end

---@return table[] characters indexed by slot (cid)
function W2F.Qbox.FetchCharacters()
    if not W2F.Qbox.IsActive() then
        return lib.callback.await('w2f-multicharacter:server:getCharacters', false) or {}
    end

    local characters, amount = lib.callback.await('qbx_core:server:getCharacters', false)
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

    return lib.callback.await('w2f-multicharacter:server:getCharacters', false) or {}
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
        appearance = json.decode(clothing)
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

---@param citizenid string
---@param coords vector4
---@return boolean
function W2F.Qbox.LoadCharacterAt(citizenid, coords)
    if not W2F.Qbox.IsActive() then
        return false
    end

    local success = lib.callback.await('qbx_core:server:loadCharacter', false, citizenid)
    if not success then
        return false
    end

    local timeout = GetGameTimer() + 10000
    while GetGameTimer() < timeout do
        local playerData = QBX and QBX.PlayerData
        if not playerData and exports.qbx_core and exports.qbx_core.GetPlayerData then
            playerData = exports.qbx_core:GetPlayerData()
        end
        if playerData and playerData.citizenid == citizenid then
            break
        end
        Wait(50)
    end

    local ped = cache.ped or PlayerPedId()
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)

    local collisionTimeout = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < collisionTimeout do
        Wait(0)
    end

    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, coords.w)
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)

    return true
end
