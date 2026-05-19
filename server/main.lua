local function getPlayerLicense(source)
    return GetPlayerIdentifierByType(source, 'license2') or GetPlayerIdentifierByType(source, 'license')
end

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

lib.callback.register('w2f-multicharacter:server:getCharacters', function(source)
    local license = getPlayerLicense(source)
    if not license then return {} end

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

RegisterNetEvent('w2f-multicharacter:server:loadCharacter', function(character, spawnCoords)
    local src = source
    if not character or not character.citizenid then return end

    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        exports.qbx_core:Login(src, character.citizenid)
        return
    end
end)
