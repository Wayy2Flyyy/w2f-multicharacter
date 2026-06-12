W2F = W2F or {}
W2F.Database = {}

local REQUIRED_TABLES = {
    'users',
    'players',
    'playerskins',
    'player_outfits',
}

--- ESX servers only need `users` (created by es_extended's own install;
--- skins live in users.skin). The QB-family list comes from sql/install.sql.
local ESX_REQUIRED_TABLES = {
    'users',
}

local function getRequiredTables()
    if W2F.Framework and W2F.Framework.IsESX and W2F.Framework.IsESX() then
        return ESX_REQUIRED_TABLES
    end
    return REQUIRED_TABLES
end

--- Tri-state availability of the optional `w2f_multicharacter_log` table:
---   nil   -> not yet probed (Verify hasn't run)
---   true  -> present, audit log writes
---   false -> absent, audit log silently skipped
--- On ESX servers sql/install.sql is optional, so this table frequently
--- doesn't exist. Without this guard every create/delete would make oxmysql
--- print a "table doesn't exist" error even though the insert is wrapped in
--- pcall (oxmysql logs the SQL error itself before rejecting the promise).
local logTableAvailable = nil

local function tableExists(name)
    local row = MySQL.single.await(
        'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1',
        { name }
    )
    return row ~= nil
end

function W2F.Database.Verify()
    local required = getRequiredTables()
    local missing = {}
    for i = 1, #required do
        local name = required[i]
        if not tableExists(name) then
            missing[#missing + 1] = name
        end
    end

    --- Probe the optional audit-log table once so Log() can skip cleanly.
    logTableAvailable = tableExists('w2f_multicharacter_log')

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
    --- Skip when the optional log table is known to be absent (common on ESX),
    --- so we don't trigger an oxmysql "table doesn't exist" error per create.
    --- When still unprobed (nil) we attempt the insert under pcall.
    if logTableAvailable == false then
        return
    end
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO w2f_multicharacter_log (license, citizenid, action, detail) VALUES (?, ?, ?, ?)',
            { license, citizenid, action, detail and json.encode(detail) or nil }
        )
    end)
    --- If the insert failed (e.g. table missing on an un-probed start), latch
    --- the flag off so we never retry and never spam further errors.
    if not ok then
        logTableAvailable = false
    end
end

CreateThread(function()
    MySQL.ready.await()
    --- With Config.Framework = 'auto', the framework core may start after this
    --- resource; give detection a moment so we verify the right table set.
    local deadline = GetGameTimer() + 10000
    while W2F.Framework and W2F.Framework.Detect
        and W2F.Framework.Detect() == 'unknown'
        and GetGameTimer() < deadline do
        Wait(500)
    end
    W2F.Database.Verify()
end)
