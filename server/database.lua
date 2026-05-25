W2F = W2F or {}
W2F.Database = {}

local REQUIRED_TABLES = {
    'users',
    'players',
    'playerskins',
    'player_outfits',
}

function W2F.Database.Verify()
    local missing = {}
    for i = 1, #REQUIRED_TABLES do
        local name = REQUIRED_TABLES[i]
        local row = MySQL.single.await(
            'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1',
            { name }
        )
        if not row then
            missing[#missing + 1] = name
        end
    end

    if #missing > 0 then
        print(('[w2f-multicharacter] ^1Missing database tables: %s^7'):format(table.concat(missing, ', ')))
        print('[w2f-multicharacter] ^3Run sql/install.sql on your server database, then restart.^7')
        return false
    end

    if Config.Debug then
        print('[w2f-multicharacter] Database tables verified.')
    end
    return true
end

function W2F.Database.Log(license, citizenid, action, detail)
    if not Config.CharacterCreation or Config.CharacterCreation.auditLog ~= true then
        return
    end
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO w2f_multicharacter_log (license, citizenid, action, detail) VALUES (?, ?, ?, ?)',
            { license, citizenid, action, detail and json.encode(detail) or nil }
        )
    end)
end

CreateThread(function()
    MySQL.ready.await()
    W2F.Database.Verify()
end)
