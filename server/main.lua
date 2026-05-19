local function getPlayerLicense(source)
    local license = GetPlayerIdentifierByType(source, 'license2') or GetPlayerIdentifierByType(source, 'license')
    return license
end

local function mapQboxCharacters(rows)
    local list = {}
    for i = 1, #rows do
        local row = rows[i]
        list[#list + 1] = {
            citizenid = row.citizenid,
            cid = row.cid or row.charinfo and row.charinfo.cid or i,
            charinfo = row.charinfo,
            money = row.money,
            job = row.job,
            metadata = row.metadata,
            lastlocation = row.position,
        }
    end
    return list
end

lib.callback.register('w2f-multicharacter:server:getCharacters', function(source)
    local license = getPlayerLicense(source)
    if not license then return {} end

    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        local ok, result = pcall(function()
            return exports.qbx_core:GetPlayerCharacters(license)
        end)
        if ok and result and #result > 0 then
            return mapQboxCharacters(result)
        end
    end

    local rows = MySQL.query.await(
        'SELECT citizenid, cid, charinfo, money, job, metadata, position FROM players WHERE license = ? ORDER BY cid ASC',
        { license }
    )
    if rows and #rows > 0 then
        return mapQboxCharacters(rows)
    end

    return {}
end)

lib.callback.register('w2f-multicharacter:server:getAppearance', function(_, citizenid)
    if not citizenid then return nil end
    local row = MySQL.single.await('SELECT skin FROM playerskins WHERE citizenid = ? AND active = 1', { citizenid })
    if row and row.skin then
        return json.decode(row.skin)
    end
    return nil
end)

lib.callback.register('w2f-multicharacter:server:getLastLocation', function(_, character)
    if not character then return nil end
    local pos = character.lastlocation or character.position
    if type(pos) == 'string' then
        pos = json.decode(pos)
    end
    if pos and pos.x then
        return { x = pos.x, y = pos.y, z = pos.z, w = pos.w or pos.heading or 0.0 }
    end

    if character.citizenid then
        local row = MySQL.single.await('SELECT position FROM players WHERE citizenid = ?', { character.citizenid })
        if row and row.position then
            local decoded = type(row.position) == 'string' and json.decode(row.position) or row.position
            if decoded and decoded.x then
                return { x = decoded.x, y = decoded.y, z = decoded.z, w = decoded.w or 0.0 }
            end
        end
    end

    return nil
end)

RegisterNetEvent('w2f-multicharacter:server:loadCharacter', function(character)
    local src = source
    if not character or not character.citizenid then return end

    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        exports.qbx_core:Login(src, character.citizenid)
        return
    end
end)
