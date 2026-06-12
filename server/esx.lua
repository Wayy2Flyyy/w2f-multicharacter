--- W2F.ESX - server-side ESX Legacy adapter.
---
--- Maps the ESX multichar model (users rows keyed by `char<slot>:<license>`
--- identifiers) onto the citizenid/cid shape the rest of the resource uses:
---   citizenid  -> the full prefixed identifier ('char2:abc123...')
---   cid        -> slot number parsed from the prefix
---
--- Requires es_extended running in multichar mode (`setr esx:multichar true`
--- in server.cfg — the same mode esx_multicharacter uses). In that mode
--- es_extended defers login entirely to a multicharacter resource via the
--- `esx:onPlayerJoined` event, which is what Login() below triggers.
--- esx_multicharacter itself must NOT be running alongside this resource.

W2F = W2F or {}
W2F.ESX = W2F.ESX or {}

local esxObject

local function core()
    if esxObject then return esxObject end
    if GetResourceState('es_extended') ~= 'started' then return nil end
    local ok, esx = pcall(function() return exports['es_extended']:getSharedObject() end)
    if ok then esxObject = esx end
    return esxObject
end

function W2F.ESX.IsActive()
    return W2F.Framework.IsESX() and GetResourceState('es_extended') == 'started'
end

local function decodeJson(value)
    if type(value) == 'string' and value ~= '' then
        local ok, decoded = pcall(json.decode, value)
        if ok then return decoded end
    elseif type(value) == 'table' then
        return value
    end
    return nil
end

--- es_extended's multichar switch differs by version: legacy versions read the
--- `esx:multichar` convar; 1.13+ ignores it and checks for a resource named
--- esx_multicharacter instead (`Config.Multichar = GetResourceState(...) ~=
--- "missing"` in shared/config/main.lua). Accept either signal — see esx.md
--- for the no-code stub that satisfies the 1.13+ check.
local function esxMultichar()
    if GetConvar('esx:multichar', 'false') == 'true' then return true end
    return GetResourceState('esx_multicharacter') ~= 'missing'
end

--- es_extended stores the bare identifier hex (no 'license:' prefix); with
--- multichar enabled it prepends 'char<slot>:' per character row.
local function normalizeHex(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return nil end
    local value = identifier:lower()
    value = value:gsub('^license2:', ''):gsub('^license:', '')
    if value == '' then return nil end
    return value
end

function W2F.ESX.GetBareIdentifier(source)
    local esx = core()
    if esx and esx.GetIdentifier then
        local ok, identifier = pcall(function() return esx.GetIdentifier(source) end)
        if ok and identifier and identifier ~= '' then
            --- Strip any char prefix in case the player is already logged in.
            return identifier:match('^char%d+:(.+)$') or identifier
        end
    end
    return normalizeHex(GetPlayerIdentifierByType(source, 'license'))
end

function W2F.ESX.GetSlotFromIdentifier(identifier)
    if type(identifier) ~= 'string' then return nil end
    return tonumber(identifier:match('^char(%d+):'))
end

function W2F.ESX.GetPlayer(source)
    local esx = core()
    return esx and esx.GetPlayerFromId(source) or nil
end

local function mapUserRow(row)
    local slot = W2F.ESX.GetSlotFromIdentifier(row.identifier) or 1
    local accounts = decodeJson(row.accounts) or {}
    local sex = row.sex
    local gender = (sex == 'f' or sex == 'F' or sex == 1 or sex == '1') and 1 or 0
    return {
        citizenid = row.identifier,
        cid = slot,
        charinfo = {
            firstname = row.firstname or '',
            lastname = row.lastname or '',
            birthdate = row.dateofbirth,
            gender = gender,
        },
        money = {
            cash = tonumber(accounts.money) or 0,
            bank = tonumber(accounts.bank) or 0,
        },
        job = { name = row.job, label = row.job, grade = tonumber(row.job_grade) or 0 },
        metadata = {},
        position = decodeJson(row.position),
        gang = nil,
        lastLoggedOut = 0,
    }
end

---@return table characters indexed by slot (cid)
function W2F.ESX.FetchCharacters(license, license2)
    local hex = normalizeHex(license) or normalizeHex(license2)
    if not hex then return {} end

    local rows = MySQL.query.await(
        'SELECT identifier, accounts, job, job_grade, firstname, lastname, dateofbirth, sex, position FROM users WHERE identifier LIKE ?',
        { 'char%:' .. hex }
    )

    local list = {}
    if rows then
        for i = 1, #rows do
            local mapped = mapUserRow(rows[i])
            list[mapped.cid] = mapped
        end
    end
    return list
end

--- Ownership = the identifier's license suffix matches the caller's license
--- AND the users row actually exists.
function W2F.ESX.OwnsIdentifier(source, identifier)
    if type(identifier) ~= 'string' or identifier == '' then return false end
    local hex = W2F.ESX.GetBareIdentifier(source)
    if not hex then return false end

    local suffix = identifier:match('^char%d+:(.+)$')
    if not suffix or suffix:lower() ~= hex:lower() then return false end

    local row = MySQL.scalar.await('SELECT 1 FROM users WHERE identifier = ? LIMIT 1', { identifier })
    return row ~= nil
end

--- Logs the player into `slot`. For a NEW character pass `identity`
--- ({ firstname, lastname, dateofbirth, sex = 'm'|'f', height }) so
--- es_extended's createESXPlayer can persist the users row; pass nil for an
--- existing character. Returns (true, xPlayer) or (false, reason).
function W2F.ESX.Login(source, slot, identity, timeoutMs)
    local esx = core()
    if not esx then return false, 'no_core' end
    if esx.GetPlayerFromId(source) then return false, 'already_logged_in' end

    --- es_extended only registers the `esx:onPlayerJoined` create/load handler
    --- when multichar mode is on. Without it our TriggerEvent below never logs
    --- the player in and we'd spin until `login_timeout`, so fail fast with a
    --- reason the caller can act on.
    if not esxMultichar() then
        return false, 'multichar_disabled'
    end

    TriggerEvent('esx:onPlayerJoined', source, ('char%d'):format(slot), identity)

    local deadline = GetGameTimer() + (timeoutMs or 10000)
    while GetGameTimer() < deadline do
        local xPlayer = esx.GetPlayerFromId(source)
        if xPlayer then return true, xPlayer end
        Wait(100)
    end
    return false, 'login_timeout'
end

--- Saves + unloads the active character. Safe no-op when not logged in.
function W2F.ESX.Logout(source, timeoutMs)
    local esx = core()
    if not esx then return false end
    if not esx.GetPlayerFromId(source) then return true end

    TriggerEvent('esx:playerLogout', source)

    local deadline = GetGameTimer() + (timeoutMs or 5000)
    while GetGameTimer() < deadline do
        if not esx.GetPlayerFromId(source) then return true end
        Wait(50)
    end
    return esx.GetPlayerFromId(source) == nil
end

--- ESX skins live in `users`.`skin` (used by esx_skin/skinchanger AND by
--- illenium-appearance's ESX backend — both persist their own JSON there).
function W2F.ESX.GetAppearance(identifier)
    if not identifier or identifier == '' then return nil end
    local row = MySQL.single.await('SELECT skin FROM users WHERE identifier = ? LIMIT 1', { identifier })
    if not row or not row.skin then return nil end
    return decodeJson(row.skin)
end

function W2F.ESX.SaveAppearance(identifier, appearance)
    if not identifier or identifier == '' or type(appearance) ~= 'table' then return false end
    local ok, encoded = pcall(json.encode, appearance)
    if not ok or type(encoded) ~= 'string' or encoded == '' then return false end
    local affected = MySQL.update.await('UPDATE users SET skin = ? WHERE identifier = ?', { encoded, identifier })
    return (tonumber(affected) or 0) > 0
end

--- Polls until users.skin holds a non-empty skin (esx_skin saves async after
--- its menu closes), mirroring the qbox playerskins verify loop.
function W2F.ESX.HasSavedAppearance(identifier, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 5000)
    repeat
        local skin = MySQL.scalar.await('SELECT skin FROM users WHERE identifier = ? LIMIT 1', { identifier })
        if type(skin) == 'string' and skin ~= '' and skin ~= '{}' and skin ~= 'null' then
            return true
        end
        Wait(100)
    until GetGameTimer() >= deadline
    return false
end

---@return string? model, table? appearance
function W2F.ESX.GetPreviewPedData(identifier)
    if not identifier or identifier == '' then return nil, nil end
    local row = MySQL.single.await('SELECT skin, sex FROM users WHERE identifier = ? LIMIT 1', { identifier })
    if not row then return nil, nil end

    local skin = decodeJson(row.skin)
    local model
    if type(skin) == 'table' then
        if type(skin.model) == 'string' and skin.model ~= '' then
            --- illenium-appearance (ESX backend) stores the ped model name.
            model = skin.model
        elseif skin.sex ~= nil then
            --- skinchanger/esx_skin format carries sex (0 = male, 1 = female).
            model = (tonumber(skin.sex) == 1) and 'mp_f_freemode_01' or 'mp_m_freemode_01'
        end
    end
    if not model then
        local sex = row.sex
        model = (sex == 'f' or sex == 'F' or sex == 1 or sex == '1')
            and 'mp_f_freemode_01' or 'mp_m_freemode_01'
    end
    return model, skin
end

function W2F.ESX.GetSavedPosition(identifier)
    if not identifier or identifier == '' then return nil end
    local pos = MySQL.scalar.await('SELECT position FROM users WHERE identifier = ? LIMIT 1', { identifier })
    local decoded = decodeJson(pos)
    if decoded and decoded.x and decoded.y and decoded.z then
        return {
            x = decoded.x + 0.0,
            y = decoded.y + 0.0,
            z = decoded.z + 0.0,
            w = (decoded.w or decoded.heading or 0.0) + 0.0,
        }
    end
    return nil
end

local function tableExists(name)
    local row = MySQL.scalar.await(
        'SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1',
        { name }
    )
    return row ~= nil
end

--- Startup sanity check: without multichar mode, es_extended logs players in
--- by itself on connect (bare identifier, behind the selector) and this
--- resource can never take over the selection flow — creates then fail with
--- "Already logged into a character" and nothing in the console.
CreateThread(function()
    Wait(2500)
    if not W2F.ESX.IsActive() then return end
    if not esxMultichar() then
        print('^1[w2f-multicharacter] ESX detected but es_extended is not in multichar mode.^0')
        print('^3[w2f-multicharacter] ESX 1.13+: add a no-code stub resource named esx_multicharacter (see esx.md). '
            .. 'Older ESX: add `setr esx:multichar true` to server.cfg. The real esx_multicharacter must stay disabled.^0')
    end
end)

--- Deletes the character row plus the related tables listed in
--- Config.ESX.characterDataTables (missing tables are skipped).
function W2F.ESX.DeleteCharacter(identifier)
    if not identifier or identifier == '' then return false end

    local tables = (Config.ESX and Config.ESX.characterDataTables) or { { 'users', 'identifier' } }
    local queries = {}
    for i = 1, #tables do
        local def = tables[i]
        local tableName, columnName = def[1], def[2]
        if tableExists(tableName) then
            queries[#queries + 1] = {
                query = ('DELETE FROM `%s` WHERE `%s` = ?'):format(tableName, columnName),
                values = { identifier },
            }
        end
    end
    if #queries == 0 then return false end
    return MySQL.transaction.await(queries) ~= false
end
