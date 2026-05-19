local function getPlayerLicense(source)
    return GetPlayerIdentifierByType(source, 'license2') or GetPlayerIdentifierByType(source, 'license')
end

local session = {}
local SELECT_COOLDOWN_MS = 250
local SPAWN_COOLDOWN_MS = 600

local function decodeField(value)
    if type(value) == 'string' then
        local ok, decoded = pcall(json.decode, value)
        if ok then return decoded end
    end
    return value
end

local function mapRow(row, index)
    return {
        citizenid = row.citizenid,
        cid = row.cid or index,
        charinfo = decodeField(row.charinfo) or {},
        money = decodeField(row.money) or {},
        job = decodeField(row.job) or {},
        metadata = decodeField(row.metadata) or {},
        position = decodeField(row.position),
        gang = decodeField(row.gang),
    }
end

local function getSpawnById(id)
    for i = 1, #Config.Spawns do
        local spawn = Config.Spawns[i]
        if spawn.id == id then
            return spawn
        end
    end
end

local function ensureSession(src)
    if not session[src] then
        session[src] = {
            selectedCitizenid = nil,
            lastSelectAt = 0,
            lastSpawnAt = 0,
        }
    end
    return session[src]
end

local function fetchCharactersByLicense(license)
    local rows = MySQL.query.await(
        'SELECT citizenid, cid, charinfo, money, job, metadata, position, gang FROM players WHERE license = ? ORDER BY cid ASC',
        { license }
    )
    if not rows or #rows == 0 then
        return {}
    end
    local list = {}
    for i = 1, #rows do
        local slot = rows[i].cid or i
        list[slot] = mapRow(rows[i], slot)
    end
    return list
end

local function ownsCitizenid(src, citizenid)
    if not citizenid or citizenid == '' then return false end
    local license = getPlayerLicense(src)
    if not license then return false end
    local row = MySQL.single.await('SELECT citizenid FROM players WHERE license = ? AND citizenid = ? LIMIT 1', { license, citizenid })
    return row and row.citizenid ~= nil
end

lib.callback.register('w2f-multicharacter:server:getCharacters', function(source)
    local license = getPlayerLicense(source)
    if not license then return {} end
    return fetchCharactersByLicense(license)
end)

lib.callback.register('w2f-multicharacter:server:getAppearance', function(_, citizenid)
    if not citizenid then return nil end
    local row = MySQL.single.await('SELECT skin FROM playerskins WHERE citizenid = ? AND active = 1', { citizenid })
    if row and row.skin then
        return decodeField(row.skin)
    end
    return nil
end)

lib.callback.register('w2f-multicharacter:server:getLastLocation', function(_, character)
    if not character then return nil end

    local pos = character.position
    if type(pos) == 'string' then
        pos = decodeField(pos)
    end
    if pos and pos.x then
        return { x = pos.x, y = pos.y, z = pos.z, w = pos.w or pos.heading or 0.0 }
    end

    if character.citizenid then
        local row = MySQL.single.await('SELECT position FROM players WHERE citizenid = ?', { character.citizenid })
        if row and row.position then
            local decoded = decodeField(row.position)
            if decoded and decoded.x then
                return { x = decoded.x, y = decoded.y, z = decoded.z, w = decoded.w or decoded.heading or 0.0 }
            end
        end
    end

    return nil
end)

local function resolveSpawnById(spawnId, citizenid)
    if type(spawnId) ~= 'string' or spawnId == '' then
        if Config.Debug then print('[w2f-multicharacter] resolveSpawnById invalid spawn id') end
        return nil
    end

    local spawn = getSpawnById(spawnId)
    if not spawn then
        if Config.Debug then print(('[w2f-multicharacter] resolveSpawnById unknown spawn id=%s'):format(tostring(spawnId))) end
        return nil
    end

    if spawn.type == 'last' then
        if citizenid and citizenid ~= '' then
            local row = MySQL.single.await('SELECT position FROM players WHERE citizenid = ?', { citizenid })
            if row and row.position then
                local decoded = decodeField(row.position)
                if decoded and decoded.x then
                    return { x = decoded.x, y = decoded.y, z = decoded.z, w = decoded.w or decoded.heading or 0.0 }
                end
            end
        end

        local fallback = getSpawnById(spawn.fallback or 'public')
        if fallback and fallback.coords then
            return { x = fallback.coords.x, y = fallback.coords.y, z = fallback.coords.z, w = fallback.coords.w or 0.0 }
        end
        if Config.Debug then print('[w2f-multicharacter] resolveSpawnById last missing and fallback missing') end
        return nil
    end

    if spawn.coords then
        return { x = spawn.coords.x, y = spawn.coords.y, z = spawn.coords.z, w = spawn.coords.w or 0.0 }
    end

    return nil
end

lib.callback.register('w2f-multicharacter:server:resolveSpawnById', function(_, spawnId, citizenid)
    return resolveSpawnById(spawnId, citizenid)
end)

lib.callback.register('w2f-multicharacter:server:selectCharacter', function(source, citizenid)
    local s = ensureSession(source)
    local now = GetGameTimer()
    if now - s.lastSelectAt < SELECT_COOLDOWN_MS then
        if Config.Debug then print(('[w2f-multicharacter] selectCharacter cooldown src=%s'):format(source)) end
        return false
    end
    s.lastSelectAt = now

    if not ownsCitizenid(source, citizenid) then
        if Config.Debug then print(('[w2f-multicharacter] selectCharacter denied src=%s citizenid=%s'):format(source, tostring(citizenid))) end
        return false
    end

    s.selectedCitizenid = citizenid
    return true
end)

lib.callback.register('w2f-multicharacter:server:requestSpawn', function(source, spawnId, citizenid)
    local s = ensureSession(source)
    local now = GetGameTimer()
    if now - s.lastSpawnAt < SPAWN_COOLDOWN_MS then
        if Config.Debug then print(('[w2f-multicharacter] requestSpawn cooldown src=%s'):format(source)) end
        return nil
    end
    s.lastSpawnAt = now

    if not ownsCitizenid(source, citizenid) then
        if Config.Debug then print(('[w2f-multicharacter] requestSpawn denied ownership src=%s citizenid=%s'):format(source, tostring(citizenid))) end
        return nil
    end

    if s.selectedCitizenid ~= citizenid then
        if Config.Debug then print(('[w2f-multicharacter] requestSpawn denied selected mismatch src=%s'):format(source)) end
        return nil
    end

    return resolveSpawnById(spawnId, citizenid)
end)

RegisterNetEvent('w2f-multicharacter:server:loadCharacter', function(character, _spawnCoords)
    local src = source
    if not character or not character.citizenid then return end

    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        exports.qbx_core:Login(src, character.citizenid)
    end
end)

RegisterNetEvent('w2f-multicharacter:server:setSelectionBucket', function()
    local src = source
    SetPlayerRoutingBucket(src, src)
end)

RegisterNetEvent('w2f-multicharacter:server:resetSelectionBucket', function()
    local src = source
    SetPlayerRoutingBucket(src, 0)
end)

AddEventHandler('playerDropped', function()
    session[source] = nil
end)
