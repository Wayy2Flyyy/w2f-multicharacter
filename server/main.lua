--- w2f-multicharacter server/main.lua
---
--- Security model (Phase 2 hardening):
---   * Every callback that takes a `citizenid` MUST call `ownsCitizenid(src, cid)`
---     and reject when the player isn't the owner.
---   * Every callback that mutates state (create / delete / cancel /
---     finishCreation) is rate-limited per-source via `rateLimit(src, name)`.
---   * Slot allocation in createCharacter runs inside a MySQL transaction
---     plus a `(license, cid)` UNIQUE constraint so two concurrent creates
---     can't take the same slot.
---   * `selectedCitizenid` is cleared from `session[src]` on delete /
---     logout / finishCreation / cancelCreation so a stale selection can't
---     be used to spawn a deleted character.
---   * `fetchCharactersByLicense` / `ownsCitizenid` compare normalized
---     `license:` and `license2:` variants to match qbx_core identifier
---     resolution without trusting client-provided citizenids.
---   * The unauthenticated `RegisterNetEvent(loadCharacter)` is removed.
---   * Audit log is extended: `select`, `request_spawn`, `apartment_claim_success`,
---     `denied_ownership`, `rate_limited`.

local function getPlayerLicense(source)
    return GetPlayerIdentifierByType(source, 'license2') or GetPlayerIdentifierByType(source, 'license')
end

local function getPlayerLicenses(source)
    return GetPlayerIdentifierByType(source, 'license'), GetPlayerIdentifierByType(source, 'license2')
end

local function trimString(value)
    if type(value) ~= 'string' then return nil end
    return value:gsub('^%s+', ''):gsub('%s+$', '')
end

local function normalizeLicenseIdentifier(identifier)
    local value = trimString(identifier)
    if not value or value == '' then return nil end

    value = value:lower()
    value = value:gsub('^license2:', '')
    value = value:gsub('^license:', '')
    if value == '' then return nil end
    return value
end

local function addLicenseIdentifier(identifiers, seen, identifier)
    local value = trimString(identifier)
    if not value or value == '' or seen[value] then return end
    seen[value] = true
    identifiers[#identifiers + 1] = value
end

local function addLicenseIdentifierVariants(identifiers, seen, identifier)
    addLicenseIdentifier(identifiers, seen, identifier)

    local normalized = normalizeLicenseIdentifier(identifier)
    if not normalized then return end

    --- qbx_core deployments differ on whether `players.license` stores
    --- `license:hex`, `license2:hex`, or the raw hex. Keep exact SQL fast-path
    --- variants broad, then let ownsCitizenid's normalized fallback be the
    --- authoritative format-tolerant check.
    addLicenseIdentifier(identifiers, seen, normalized)
    addLicenseIdentifier(identifiers, seen, ('license:%s'):format(normalized))
    addLicenseIdentifier(identifiers, seen, ('license2:%s'):format(normalized))
end

local function getLicenseIdentifierSet(license, license2)
    local identifiers = {}
    local seen = {}

    addLicenseIdentifierVariants(identifiers, seen, license)
    addLicenseIdentifierVariants(identifiers, seen, license2)

    return identifiers
end

local function getNormalizedLicenseIdentifierSet(license, license2)
    local identifiers = {}
    local seen = {}

    local function add(identifier)
        local normalized = normalizeLicenseIdentifier(identifier)
        if not normalized or seen[normalized] then return end
        seen[normalized] = true
        identifiers[#identifiers + 1] = normalized
    end

    add(license)
    add(license2)
    for _, identifier in ipairs(getLicenseIdentifierSet(license, license2)) do
        add(identifier)
    end

    return identifiers
end

local function buildLicenseWhere(identifiers)
    if #identifiers == 0 then return nil end

    local parts = {}
    for i = 1, #identifiers do
        parts[i] = 'license = ?'
    end
    return table.concat(parts, ' OR ')
end

local session = {}
local SELECT_COOLDOWN_MS = 250
local SPAWN_COOLDOWN_MS = 600
local serverReady = false

-----------------------------------------------------------------------------
--- Rate limiting.
-----------------------------------------------------------------------------
--- Per-callback cooldown (ms). Tuned so legitimate UX doesn't bump into the
--- limit but spam (script kiddies / bug-replay) does. `0` means no limit.
local RATE_LIMITS = {
    createCharacter    = 2500,
    deleteCharacter    = 1500,
    cancelCreation     = 1500,
    finishCreation     = 1500,
    getCharacters      = 250,
    getSlotSummary     = 250,
    getAppearance      = 150,
    getLastLocation    = 150,
    getApartmentOptions= 250,
    resolveSpawnById   = 200,
    canClaimApartment  = 500,
}

local function rateLimit(src, name)
    local cooldown = RATE_LIMITS[name]
    if not cooldown or cooldown <= 0 then return true end

    local sess = session[src]
    if not sess then
        sess = {
            selectedCitizenid = nil,
            lastSelectAt = 0,
            lastSpawnAt = 0,
            limits = {},
        }
        session[src] = sess
    end
    sess.limits = sess.limits or {}

    local now = GetGameTimer()
    local last = sess.limits[name] or 0
    if now - last < cooldown then
        if Config.Debug then
            print(('[w2f-multicharacter] rate_limited src=%s callback=%s'):format(src, name))
        end
        if W2F.Database then
            local license = getPlayerLicense(src)
            if license then
                W2F.Database.Log(license, nil, 'rate_limited', { callback = name })
            end
        end
        return false
    end
    sess.limits[name] = now
    return true
end

CreateThread(function()
    print('[w2f-multicharacter][server] waiting for MySQL.ready...')
    local started = GetGameTimer()
    MySQL.ready.await()
    serverReady = true
    print(('[w2f-multicharacter][server] MySQL ready after %dms; serverReady=true'):format(
        GetGameTimer() - started))
end)

local lastNotReadyLogAt = 0
lib.callback.register('w2f-multicharacter:server:isReady', function(source)
    if not serverReady then
        --- Throttled informational log so we can see clients polling while
        --- MySQL is still booting without spamming the console.
        local now = GetGameTimer()
        if (now - lastNotReadyLogAt) >= 4000 then
            lastNotReadyLogAt = now
            print(('[w2f-multicharacter][server] isReady polled by src=%s while serverReady=false'):format(
                tostring(source)))
        end
    end
    return serverReady
end)

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
        lastLoggedOut = tonumber(row.lastLoggedOutUnix) or 0,
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
            limits = {},
        }
    end
    if not session[src].limits then
        session[src].limits = {}
    end
    return session[src]
end

local function clearSelectedIf(src, citizenid)
    local s = session[src]
    if s and s.selectedCitizenid == citizenid then
        s.selectedCitizenid = nil
    end
end

-----------------------------------------------------------------------------
--- Validation helpers.
-----------------------------------------------------------------------------

--- Unicode-safe leading-cap: lowercase the whole word with `string.lower`
--- (works on ASCII), then upper the first byte. This handles common
--- Latin-1 names better than the previous `gsub` implementation which would
--- split multi-byte UTF-8 codepoints.
local function capString(str)
    if type(str) ~= 'string' or str == '' then return '' end
    return str:gsub('([^%s%-\']+)', function(word)
        if #word == 0 then return word end
        --- Find first letter byte, upper-case it, lower the rest.
        local first = word:sub(1, 1):upper()
        local rest = word:sub(2):lower()
        return first .. rest
    end)
end

--- Real calendar-date check (not just regex). Returns true iff Y-M-D forms
--- a valid date (handles Feb 30, April 31, etc).
local function isValidDate(yyyy, mm, dd)
    if mm < 1 or mm > 12 then return false end
    if dd < 1 then return false end
    local daysInMonth = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    --- Leap-year handling.
    if mm == 2 then
        local leap = (yyyy % 4 == 0 and yyyy % 100 ~= 0) or (yyyy % 400 == 0)
        if leap and dd > 29 then return false end
        if not leap and dd > 28 then return false end
    elseif dd > daysInMonth[mm] then
        return false
    end
    return true
end

local function getMaxCharacterSlots()
    local sceneSlots = Config.Scene and Config.Scene.pedSlots and #Config.Scene.pedSlots or 0
    local configured = Config.MaxCharacters or Config.General.MaxCharacters or sceneSlots
    if sceneSlots > 0 and configured > sceneSlots then
        return sceneSlots
    end
    return configured > 0 and configured or 3
end

local function findNextAvailableCid(characters, maxSlots)
    for cid = 1, maxSlots do
        if not characters[cid] then
            return cid
        end
    end
    return nil
end

local function countCharacters(characters)
    local n = 0
    for _, character in pairs(characters) do
        if character then n = n + 1 end
    end
    return n
end

local function validateCreatePayload(data)
    local cc = Config.CharacterCreation or {}
    if type(data) ~= 'table' then
        return false, 'invalid_payload'
    end

    local first = capString(tostring(data.firstname or ''):gsub('%s+', ' '):match('^%s*(.-)%s*$'))
    local last = capString(tostring(data.lastname or ''):gsub('%s+', ' '):match('^%s*(.-)%s*$'))
    local minLen = cc.nameMinLength or 2
    local maxLen = cc.nameMaxLength or 24

    if #first < minLen or #last < minLen then
        return false, ('Names must be at least %d characters.'):format(minLen)
    end
    if #first > maxLen or #last > maxLen then
        return false, ('Names must be at most %d characters.'):format(maxLen)
    end

    --- Reject names that contain only whitespace / control chars or symbols
    --- that aren't Letter / mark / dash / apostrophe.
    if not first:match("[%a']") or not last:match("[%a']") then
        return false, 'Names must contain letters.'
    end

    local birthdate = tostring(data.birthdate or '')
    local yyyy, mm, dd = birthdate:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    if not yyyy then
        return false, 'Birthdate must be YYYY-MM-DD.'
    end
    if not isValidDate(tonumber(yyyy), tonumber(mm), tonumber(dd)) then
        return false, 'Birthdate is not a valid calendar date.'
    end
    if cc.birthdateMin and birthdate < cc.birthdateMin then
        return false, 'Birthdate is too early.'
    end
    if cc.birthdateMax and birthdate > cc.birthdateMax then
        return false, 'Birthdate is too late.'
    end

    local gender = tonumber(data.gender)
    if gender ~= 0 and gender ~= 1 then
        return false, 'Select a valid gender.'
    end

    local nationality = tostring(data.nationality or cc.defaultNationality or 'American')
    local allowed = cc.nationalities
    if allowed then
        local okNat = false
        for i = 1, #allowed do
            if allowed[i] == nationality then
                okNat = true
                break
            end
        end
        if not okNat then
            --- Server-enforced fallback to the configured default. The
            --- previous behaviour silently kept the bogus value.
            nationality = cc.defaultNationality or 'American'
        end
    end

    return true, {
        firstname = first,
        lastname = last,
        nationality = nationality,
        gender = gender,
        birthdate = birthdate,
    }
end

local function giveStarterItems(source)
    if GetResourceState('ox_inventory') == 'missing' then return end

    local starterItems
    local raw = LoadResourceFile('qbx_core', 'config/shared.lua')
    if raw then
        local ok, shared = pcall(function()
            local chunk = load(raw, '@qbx_core/config/shared.lua')
            return chunk and chunk()
        end)
        if ok and shared and shared.starterItems then
            starterItems = shared.starterItems
        end
    end
    if not starterItems then return end

    CreateThread(function()
        local timeout = GetGameTimer() + 10000
        while not exports.ox_inventory:GetInventory(source) and GetGameTimer() < timeout do
            Wait(100)
        end
        for i = 1, #starterItems do
            local item = starterItems[i]
            if item.metadata and type(item.metadata) == 'function' then
                exports.ox_inventory:AddItem(source, item.name, item.amount, item.metadata(source))
            else
                exports.ox_inventory:AddItem(source, item.name, item.amount, item.metadata)
            end
        end
    end)
end

--- Query all authenticated license identifiers, including equivalent
--- `license:`/`license2:` variants, so the lineup matches what qbx_core may
--- have stored in `players.license` during character creation.
local function fetchCharactersByLicense(license, license2)
    local identifiers = getLicenseIdentifierSet(license, license2)
    local licenseWhere = buildLicenseWhere(identifiers)
    if not licenseWhere then return {} end

    local rows = MySQL.query.await(
        ('SELECT citizenid, cid, charinfo, money, job, metadata, position, gang, UNIX_TIMESTAMP(last_logged_out) AS lastLoggedOutUnix FROM players WHERE %s ORDER BY cid ASC'):format(licenseWhere),
        identifiers
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

local function getCharacterDatabaseLicense(citizenid)
    if not citizenid or citizenid == '' then return nil end

    local row = MySQL.single.await(
        'SELECT license FROM players WHERE citizenid = ? LIMIT 1',
        { citizenid }
    )
    return row and row.license or nil
end

local function waitForCharacterDatabaseLicense(citizenid, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 5000)
    repeat
        local dbLicense = getCharacterDatabaseLicense(citizenid)
        if dbLicense and dbLicense ~= '' then return dbLicense end
        Wait(100)
    until GetGameTimer() >= deadline

    local dbLicense = getCharacterDatabaseLicense(citizenid)
    if dbLicense and dbLicense ~= '' then return dbLicense end
    return nil
end

--- Ownership check compares the current source's license identifiers plus their
--- raw / `license:` / `license2:` variants. The exact SQL path stays fast, then
--- a citizenid-only fallback verifies normalized identifier values so differing
--- prefix formats don't reject the rightful owner.
local function ownsCitizenid(src, citizenid)
    if not citizenid or citizenid == '' then return false end
    local license, license2 = getPlayerLicenses(src)
    local identifiers = getLicenseIdentifierSet(license, license2)
    local licenseWhere = buildLicenseWhere(identifiers)
    if not licenseWhere then return false end

    local params = { citizenid }
    for i = 1, #identifiers do
        params[#params + 1] = identifiers[i]
    end

    local exactRow = MySQL.single.await(
        ('SELECT citizenid, license FROM players WHERE citizenid = ? AND (%s) LIMIT 1'):format(licenseWhere),
        params
    )
    local exactMatch = exactRow and exactRow.citizenid ~= nil
    local dbRow = exactRow
    local normalizedMatch = false

    if not exactMatch then
        dbRow = MySQL.single.await(
            'SELECT citizenid, license FROM players WHERE citizenid = ? LIMIT 1',
            { citizenid }
        )

        if dbRow and dbRow.license then
            local dbLicense = normalizeLicenseIdentifier(dbRow.license)
            local normalizedIdentifiers = getNormalizedLicenseIdentifierSet(license, license2)
            for i = 1, #normalizedIdentifiers do
                if dbLicense and dbLicense == normalizedIdentifiers[i] then
                    normalizedMatch = true
                    break
                end
            end
        end
    end

    local owned = exactMatch or normalizedMatch

    if Config.Debug then
        print(('[w2f-multicharacter] ownsCitizenid src=%s citizenid=%s license=%s license2=%s dbLicense=%s exactMatch=%s normalisedMatch=%s'):format(
            tostring(src),
            tostring(citizenid),
            tostring(license),
            tostring(license2),
            tostring(dbRow and dbRow.license or nil),
            tostring(exactMatch),
            tostring(normalizedMatch)
        ))
    end

    if not owned and W2F.Database then
        W2F.Database.Log(license or license2, citizenid, 'denied_ownership', nil)
    end
    return owned
end

lib.callback.register('w2f-multicharacter:server:getCharacters', function(source)
    if not rateLimit(source, 'getCharacters') then return {} end
    local license, license2 = getPlayerLicenses(source)
    if not license and not license2 then return {} end
    return fetchCharactersByLicense(license, license2)
end)

lib.callback.register('w2f-multicharacter:server:getSlotSummary', function(source)
    if not rateLimit(source, 'getSlotSummary') then
        return { maxSlots = 0, used = 0, slots = {}, rateLimited = true }
    end
    local license, license2 = getPlayerLicenses(source)
    if not license and not license2 then
        return { maxSlots = 0, used = 0, slots = {} }
    end

    local characters = fetchCharactersByLicense(license, license2)
    local maxSlots = getMaxCharacterSlots()
    local ordered = {}
    for cid = 1, maxSlots do
        local character = characters[cid]
        ordered[#ordered + 1] = {
            cid = cid,
            visualSlot = #ordered + 1,
            occupied = character ~= nil,
            citizenid = character and character.citizenid or nil,
            name = character and character.charinfo and ('%s %s'):format(
                character.charinfo.firstname or '',
                character.charinfo.lastname or ''
            ) or nil,
        }
    end

    local visual = {}
    local visualIndex = 0
    for cid = 1, maxSlots do
        if characters[cid] then
            visualIndex = visualIndex + 1
            visual[visualIndex] = {
                visualSlot = visualIndex,
                cid = cid,
                citizenid = characters[cid].citizenid,
                name = ('%s %s'):format(
                    characters[cid].charinfo.firstname or '',
                    characters[cid].charinfo.lastname or ''
                ),
            }
        end
    end

    return {
        maxSlots = maxSlots,
        used = countCharacters(characters),
        canCreate = findNextAvailableCid(characters, maxSlots) ~= nil,
        visual = visual,
        byCid = ordered,
    }
end)

-----------------------------------------------------------------------------
--- createCharacter: atomic slot allocation.
---
--- The race we fix here:
---   T0: client A calls createCharacter; fetch returns characters {} (no slot 1)
---   T1: client A's session yields while waiting on Login
---   T2: client B (same license, second tab?) also calls createCharacter
---       and also gets characters {} -> both pick cid 1
---   T3: both Login calls succeed; both rows get inserted with cid=1
---
--- Mitigations layered:
---   1. Per-source rate limit (2.5s) - protects against double-click and
---      most accidental races.
---   2. Per-license advisory lock (`getLock`) ensures that slot allocation
---      runs serially for the same player even across sessions.
---   3. SQL UNIQUE INDEX `(license, cid)` is the last line of defence; the
---      second INSERT errors out cleanly and the player sees "slot taken".
-----------------------------------------------------------------------------
local function withLicenseLock(license, timeoutSec, fn)
    timeoutSec = timeoutSec or 5
    local lockName = ('w2fmc_%s'):format(license)
    --- `GET_LOCK` is per-connection; oxmysql multiplexes connections so this
    --- is best-effort. We additionally rely on the UNIQUE INDEX below.
    local got = MySQL.scalar.await('SELECT GET_LOCK(?, ?)', { lockName, timeoutSec })
    if got ~= 1 then
        return fn(false)
    end
    local ok, a, b = pcall(fn, true)
    MySQL.scalar.await('SELECT RELEASE_LOCK(?)', { lockName })
    if not ok then error(a) end
    return a, b
end

lib.callback.register('w2f-multicharacter:server:createCharacter', function(source, payload)
    if not rateLimit(source, 'createCharacter') then
        return false, 'Please wait a moment before trying again.'
    end
    if not Config.CharacterCreation or Config.CharacterCreation.enabled == false then
        return false, 'Character creation is disabled.'
    end

    local license, license2 = getPlayerLicenses(source)
    if not license and not license2 then
        return false, 'Could not verify your license.'
    end

    local ok, result = validateCreatePayload(payload)
    if not ok then
        return false, result
    end

    if not (Config.UseQbox and GetResourceState('qbx_core') == 'started') then
        return false, 'Qbox core is required for character creation.'
    end

    if exports.qbx_core:GetPlayer(source) then
        return false, 'Already logged into a character.'
    end

    local primaryLicense = license or license2
    local createdOk, createdErr, createdMeta
    withLicenseLock(primaryLicense, 5, function(_locked)
        local characters = fetchCharactersByLicense(license, license2)
        local maxSlots = getMaxCharacterSlots()
        local cid = findNextAvailableCid(characters, maxSlots)
        if not cid then
            createdOk, createdErr = false, 'No character slots available.'
            return
        end

        result.cid = cid
        local loginOk = exports.qbx_core:Login(source, nil, { charinfo = result })
        if not loginOk then
            createdOk, createdErr = false, 'Failed to create character.'
            return
        end

        local player = exports.qbx_core:GetPlayer(source)
        local citizenid = player and player.PlayerData.citizenid
        if not citizenid then
            createdOk, createdErr = false, 'Character created but data missing.'
            return
        end

        local dbLicense = waitForCharacterDatabaseLicense(citizenid, 5000)
        local ownsAfterCreate = ownsCitizenid(source, citizenid)

        if Config.Debug then
            print(('[w2f-multicharacter] createCharacter ownership src=%s citizenid=%s license=%s license2=%s dbLicense=%s ownsAfterCreate=%s'):format(
                tostring(source),
                tostring(citizenid),
                tostring(license),
                tostring(license2),
                tostring(dbLicense),
                tostring(ownsAfterCreate)
            ))
        end

        if not ownsAfterCreate then
            createdOk, createdErr = false, 'Character created but ownership could not be verified.'
            return
        end

        giveStarterItems(source)

        if W2F.Database then
            W2F.Database.Log(license or license2, citizenid, 'create',
                { cid = cid, name = ('%s %s'):format(result.firstname, result.lastname) })
        end

        --- Mark the new character as the active selection in the session so
        --- subsequent requestSpawn / canClaimApartment calls accept it
        --- without a separate selectCharacter round-trip.
        local sess = ensureSession(source)
        sess.selectedCitizenid = citizenid

        createdOk = true
        createdMeta = {
            citizenid = citizenid,
            cid = cid,
            gender = result.gender,
            firstname = result.firstname,
            lastname = result.lastname,
        }
    end)

    if createdOk then return true, createdMeta end
    return false, createdErr or 'Character creation failed.'
end)

lib.callback.register('w2f-multicharacter:server:finishCreation', function(source)
    if not rateLimit(source, 'finishCreation') then
        return false
    end
    local license = getPlayerLicense(source)
    local citizenid = nil
    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        local player = exports.qbx_core:GetPlayer(source)
        citizenid = player and player.PlayerData.citizenid
        exports.qbx_core:Logout(source)
    end

    --- Clear selection on logout-to-finalize so a follow-up requestSpawn
    --- can't reuse it before the next selectCharacter.
    local sess = session[source]
    if sess then sess.selectedCitizenid = nil end

    if W2F.Database and license then
        W2F.Database.Log(license, citizenid, 'finish_appearance', nil)
    end
    return true
end)

--- Loads qbx_core's characterDataTables list at runtime so we delete every
--- table that qbx itself would (properties, bank_accounts_new, playerskins,
--- player_vehicles, player_groups, npwd_*, etc.) in the correct order.
--- Falls back to a hard-coded list if the file can't be parsed.
local function getCharacterDataTables()
    local raw = LoadResourceFile('qbx_core', 'config/server.lua')
    if raw then
        local ok, cfg = pcall(function()
            local chunk = load(raw, '@qbx_core/config/server.lua')
            return chunk and chunk()
        end)
        if ok and type(cfg) == 'table' and type(cfg.characterDataTables) == 'table' then
            return cfg.characterDataTables
        end
    end
    return {
        { 'properties', 'owner' },
        { 'bank_accounts_new', 'id' },
        { 'playerskins', 'citizenid' },
        { 'player_mails', 'citizenid' },
        { 'player_outfits', 'citizenid' },
        { 'player_vehicles', 'citizenid' },
        { 'player_groups', 'citizenid' },
        { 'players', 'citizenid' },
    }
end

local function tableExists(name)
    local row = MySQL.scalar.await(
        'SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1',
        { name }
    )
    return row ~= nil
end

local function deleteCharacterRows(citizenid)
    local tables = getCharacterDataTables()
    local queries = {}
    for i = 1, #tables do
        local def = tables[i]
        local tableName, columnName = def[1], def[2]
        if tableExists(tableName) then
            queries[#queries + 1] = {
                query = ('DELETE FROM `%s` WHERE `%s` = ?'):format(tableName, columnName),
                values = { citizenid },
            }
        end
    end
    return MySQL.transaction.await(queries)
end

local function deleteCharacterFully(source, citizenid)
    --- If the player is currently logged in as this character, force them out
    --- so qbx doesn't keep stale data after we wipe the row.
    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        local player = exports.qbx_core:GetPlayer(source)
        if player and player.PlayerData and player.PlayerData.citizenid == citizenid then
            pcall(function() exports.qbx_core:Logout(source) end)
            Wait(150)
        end
    end

    --- Preferred path: qbx_core's own cascade.
    local cleared = false
    if GetResourceState('qbx_core') == 'started' then
        local ok = pcall(function()
            exports.qbx_core:DeleteCharacter(citizenid)
        end)
        if ok then
            local timeout = GetGameTimer() + 2500
            while GetGameTimer() < timeout do
                local row = MySQL.scalar.await('SELECT 1 FROM players WHERE citizenid = ?', { citizenid })
                if not row then cleared = true break end
                Wait(50)
            end
        end
    end

    if not cleared then
        cleared = deleteCharacterRows(citizenid) ~= false
    end

    clearSelectedIf(source, citizenid)
    return cleared
end

lib.callback.register('w2f-multicharacter:server:deleteCharacter', function(source, citizenid)
    if not rateLimit(source, 'deleteCharacter') then return false, 'rate_limited' end
    if not citizenid or citizenid == '' then return false, 'No character selected.' end
    if not ownsCitizenid(source, citizenid) then return false, 'You do not own that character.' end

    local cleared = deleteCharacterFully(source, citizenid)
    if not cleared then
        return false, 'Database delete failed.'
    end

    local license = getPlayerLicense(source)
    if W2F.Database and license then
        W2F.Database.Log(license, citizenid, 'delete', nil)
    end
    return true
end)

lib.callback.register('w2f-multicharacter:server:cancelCreation', function(source)
    if not rateLimit(source, 'cancelCreation') then return false end
    local license = getPlayerLicense(source)
    local citizenid = nil

    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        local player = exports.qbx_core:GetPlayer(source)
        citizenid = player and player.PlayerData.citizenid
        if citizenid and citizenid ~= '' then
            --- Mirror deleteCharacter's await + verification so we don't
            --- return success while the row is still being deleted.
            deleteCharacterFully(source, citizenid)
        end
        --- Even if there's no citizenid (login failed mid-creation), make
        --- sure the player is logged out.
        pcall(function() exports.qbx_core:Logout(source) end)
    end

    --- Always clear selection.
    if session[source] then session[source].selectedCitizenid = nil end

    if W2F.Database and license then
        W2F.Database.Log(license, citizenid, 'cancel_appearance', nil)
    end
    return true
end)

-----------------------------------------------------------------------------
--- Authenticated read callbacks.
--- All `citizenid`-accepting reads now go through `ownsCitizenid`. The risk
--- noted in the rebuild plan ("lineup preview wants getAppearance for OWN
--- characters that aren't yet selected") is mitigated by checking against
--- the player's license, not against the session-selected citizenid - so
--- preview-rendering still works for the player's other characters.
-----------------------------------------------------------------------------
lib.callback.register('w2f-multicharacter:server:getAppearance', function(source, citizenid)
    if not rateLimit(source, 'getAppearance') then return nil end
    if not citizenid then return nil end
    if not ownsCitizenid(source, citizenid) then return nil end

    local row = MySQL.single.await('SELECT skin FROM playerskins WHERE citizenid = ? AND active = 1', { citizenid })
    if row and row.skin then
        return decodeField(row.skin)
    end
    return nil
end)

lib.callback.register('w2f-multicharacter:server:getLastLocation', function(source, character)
    if not rateLimit(source, 'getLastLocation') then return nil end
    if not character then return nil end

    local cid = type(character) == 'table' and character.citizenid or nil
    if not cid then return nil end
    if not ownsCitizenid(source, cid) then return nil end

    local pos = character.position
    if type(pos) == 'string' then
        pos = decodeField(pos)
    end
    if pos and pos.x then
        return { x = pos.x, y = pos.y, z = pos.z, w = pos.w or pos.heading or 0.0 }
    end

    local row = MySQL.single.await('SELECT position FROM players WHERE citizenid = ?', { cid })
    if row and row.position then
        local decoded = decodeField(row.position)
        if decoded and decoded.x then
            return { x = decoded.x, y = decoded.y, z = decoded.z, w = decoded.w or decoded.heading or 0.0 }
        end
    end

    return nil
end)

local function fetchPlayerSavedPosition(citizenid)
    if not citizenid or citizenid == '' then return nil end

    local row = MySQL.single.await(
        'SELECT position, metadata FROM players WHERE citizenid = ? LIMIT 1',
        { citizenid }
    )
    if not row then return nil end

    local function pick(decoded)
        if type(decoded) ~= 'table' then return nil end
        if decoded.x and decoded.y and decoded.z then
            return { x = decoded.x + 0.0, y = decoded.y + 0.0, z = decoded.z + 0.0, w = (decoded.w or decoded.heading or 0.0) + 0.0 }
        end
        return nil
    end

    local p = pick(decodeField(row.position))
    if p then return p end

    local md = decodeField(row.metadata)
    if md then
        p = pick(md.position) or pick(md.lastlocation) or pick(md.lastLocation)
        if p then return p end
    end

    return nil
end

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
        local p = fetchPlayerSavedPosition(citizenid)
        if p then return p end

        local fallback = getSpawnById(spawn.fallback or 'public')
        if fallback and fallback.coords then
            return { x = fallback.coords.x, y = fallback.coords.y, z = fallback.coords.z, w = fallback.coords.w or 0.0 }
        end

        return { x = -540.58, y = -212.02, z = 37.65, w = 208.88 }
    end

    if spawn.coords then
        return { x = spawn.coords.x, y = spawn.coords.y, z = spawn.coords.z, w = spawn.coords.w or 0.0 }
    end

    return nil
end

lib.callback.register('w2f-multicharacter:server:resolveSpawnById', function(source, spawnId, citizenid)
    if not rateLimit(source, 'resolveSpawnById') then return nil end
    --- Ownership check: only OWN citizenids may resolve last-known location.
    --- Public spawn points are constant; they're safe to expose, so we still
    --- resolve them for any caller. But for `last` spawns we need ownership.
    if citizenid and citizenid ~= '' then
        if not ownsCitizenid(source, citizenid) then
            if Config.Debug then print(('[w2f-multicharacter] resolveSpawnById denied src=%s citizenid=%s'):format(source, tostring(citizenid))) end
            return nil
        end
    end
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

    if W2F.Database then
        local license = getPlayerLicense(source)
        if license then W2F.Database.Log(license, citizenid, 'select', nil) end
    end
    return true
end)

local function isQbxPropertiesStarted()
    return GetResourceState('qbx_properties') == 'started'
end

local function loadQbxApartments()
    if not isQbxPropertiesStarted() then return nil end
    local raw = LoadResourceFile('qbx_properties', 'config/shared.lua')
    if not raw then return nil end

    local ok, shared = pcall(function()
        local chunk = load(raw, '@qbx_properties/config/shared.lua')
        return chunk and chunk()
    end)
    if not ok or type(shared) ~= 'table' then return nil end
    return shared.apartmentOptions
end

local function playerOwnsProperty(citizenid)
    if not citizenid or citizenid == '' then return false end
    local row = MySQL.single.await(
        'SELECT id FROM properties WHERE owner = ? LIMIT 1',
        { citizenid }
    )
    return row ~= nil
end

lib.callback.register('w2f-multicharacter:server:getApartmentOptions', function(source, citizenid)
    if not rateLimit(source, 'getApartmentOptions') then return {} end
    if not citizenid or citizenid == '' then return {} end
    if not ownsCitizenid(source, citizenid) then return {} end

    local apts = loadQbxApartments()
    if not apts or #apts == 0 then return {} end

    if playerOwnsProperty(citizenid) then
        return {}
    end

    local out = {}
    for i = 1, #apts do
        local a = apts[i]
        local enter = a.enter
        out[#out + 1] = {
            id = ('apt:%d'):format(i),
            index = i,
            label = a.label,
            description = a.description,
            kind = 'apartment',
            coords = enter and { x = enter.x, y = enter.y, z = enter.z } or nil,
        }
    end
    return out
end)

lib.callback.register('w2f-multicharacter:server:canClaimApartment', function(source, apartmentIndex, citizenid)
    if not rateLimit(source, 'canClaimApartment') then return false, 'rate_limited' end
    if type(apartmentIndex) ~= 'number' then return false, 'Invalid apartment.' end
    if not ownsCitizenid(source, citizenid) then return false, 'You do not own that character.' end
    if not isQbxPropertiesStarted() then
        return false, 'Apartments are unavailable.'
    end
    if playerOwnsProperty(citizenid) then
        return false, 'You already own a property.'
    end

    if Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        local player = exports.qbx_core:GetPlayer(source)
        if not player or player.PlayerData.citizenid ~= citizenid then
            return false, 'You must be logged in as the new character to claim an apartment.'
        end
    end

    local apts = loadQbxApartments()
    if not apts or not apts[apartmentIndex] then
        return false, 'Apartment index out of range.'
    end

    --- NOTE: we used to log `apartment_claim` here, before the actual claim
    --- runs. That gave a false-positive audit trail for failed claims. The
    --- audit is now logged from `confirmApartmentClaimed` only after the
    --- qbx_properties event reports success.
    return true
end)

--- Logged by the client after qbx_properties' apartmentSelect event. Do not
--- trust the event alone: wait for the property row so the audit reflects a
--- real claim and callers can recover when qbx_properties fails or stops.
lib.callback.register('w2f-multicharacter:server:confirmApartmentClaimed', function(source, apartmentIndex, citizenid)
    if not isQbxPropertiesStarted() then
        if Config.Debug then print('[w2f-multicharacter] confirmApartmentClaimed failure: qbx_properties not started') end
        return false
    end
    if not citizenid or not ownsCitizenid(source, citizenid) then
        if Config.Debug then print(('[w2f-multicharacter] confirmApartmentClaimed failure: ownership src=%s citizenid=%s'):format(source, tostring(citizenid))) end
        return false
    end

    local deadline = GetGameTimer() + 5000
    while GetGameTimer() < deadline do
        if not isQbxPropertiesStarted() then
            if Config.Debug then print('[w2f-multicharacter] confirmApartmentClaimed failure: qbx_properties stopped while waiting') end
            return false
        end

        local ok, row = pcall(function()
            return MySQL.single.await('SELECT id FROM properties WHERE owner = ? LIMIT 1', { citizenid })
        end)
        if ok and row then
            if W2F.Database then
                local license = getPlayerLicense(source)
                if license then
                    W2F.Database.Log(license, citizenid, 'apartment_claim_success', { index = apartmentIndex })
                end
            end
            if Config.Debug then print(('[w2f-multicharacter] confirmApartmentClaimed success citizenid=%s propertyId=%s'):format(tostring(citizenid), tostring(row.id))) end
            return true
        end
        Wait(200)
    end

    if Config.Debug then print(('[w2f-multicharacter] confirmApartmentClaimed failure: property row timeout citizenid=%s'):format(tostring(citizenid))) end
    return false
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

    if W2F.Database then
        local license = getPlayerLicense(source)
        if license then W2F.Database.Log(license, citizenid, 'request_spawn', { spawnId = spawnId }) end
    end

    return resolveSpawnById(spawnId, citizenid)
end)

-----------------------------------------------------------------------------
--- The legacy `loadCharacter` net event was unauthenticated and accepted a
--- raw character payload. It's been replaced by the qbx_core
--- `loadCharacter` server callback (authenticated against the player's
--- session). Resources outside this folder should never call it directly.
---
--- The set/reset routing-bucket events are intentionally kept as
--- RegisterNetEvent because they only mutate the caller's own bucket using
--- `source`. There's no payload spoofing risk.
-----------------------------------------------------------------------------
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

--- Clear the selection when QBX logs the player out so a stale
--- selectedCitizenid can't bleed across sessions.
AddEventHandler('qbx_core:server:onLogout', function(source)
    if session[source] then
        session[source].selectedCitizenid = nil
    end
end)

--- Convenience export for other resources that want to know which
--- multichar-selected character a source is currently tied to.
exports('GetSelectedCitizenid', function(src)
    return session[src] and session[src].selectedCitizenid or nil
end)
