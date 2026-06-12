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

--- ESX runtime gate: Config.Framework resolves to 'esx' (explicitly or via
--- auto-detection) AND es_extended is actually started. Every framework
--- branch below funnels through this so the qbox flow is untouched on
--- QB-family servers.
local function isEsxMode()
    return W2F.ESX and W2F.ESX.IsActive and W2F.ESX.IsActive()
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
    saveNewAppearance  = 1500,
    getCharacters      = 250,
    getSlotSummary     = 250,
    getAppearance      = 150,
    getLastLocation    = 150,
    getApartmentOptions= 250,
    resolveSpawnById   = 200,
    loadCharacter      = 1000,
    getPreviewPedData  = 150,
    canClaimApartment  = 500,
    --- Dedicated key (not shared with canClaimApartment) so a confirm landing
    --- inside the canClaim window isn't falsely rejected. Bounds the ~25-query
    --- 5s poll loop against modded-client spam for an owned citizenid.
    confirmApartmentClaimed = 2000,
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
    --- Also clear the in-flight creation marker so a deleted/cancelled
    --- character can't be rolled back a second time on disconnect.
    if s and s.creatingCitizenid == citizenid then
        s.creatingCitizenid = nil
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

--- Single source of truth lives in config.lua (shared) so the client lineup
--- and this server-side enforcement can never disagree.
local function getMaxCharacterSlots()
    return Config.GetMaxCharacterSlots()
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
--- `source` is optional and only used by the ESX branch, where the lookup key
--- must come from es_extended's identifier config (license by default, but
--- steam on some servers) instead of assuming the FiveM license.
local function fetchCharactersByLicense(license, license2, source)
    if isEsxMode() then
        local hex = source and W2F.ESX.GetBareIdentifier(source) or nil
        return W2F.ESX.FetchCharacters(hex or license, license2)
    end

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

    if isEsxMode() then
        --- ESX 'citizenid' is the full prefixed identifier (char<slot>:<hex>);
        --- ownership is the license suffix matching the caller's license.
        local owned = W2F.ESX.OwnsIdentifier(src, citizenid)
        if Config.Debug then
            print(('[w2f-multicharacter] ownsCitizenid(esx) src=%s identifier=%s owned=%s'):format(
                tostring(src), tostring(citizenid), tostring(owned)))
        end
        if not owned and W2F.Database then
            local license = getPlayerLicense(src)
            if license then
                W2F.Database.Log(license, citizenid, 'denied_ownership', nil)
            end
        end
        return owned
    end

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
    return fetchCharactersByLicense(license, license2, source)
end)

lib.callback.register('w2f-multicharacter:server:getSlotSummary', function(source)
    if not rateLimit(source, 'getSlotSummary') then
        return { maxSlots = 0, used = 0, slots = {}, rateLimited = true }
    end
    local license, license2 = getPlayerLicenses(source)
    if not license and not license2 then
        return { maxSlots = 0, used = 0, slots = {} }
    end

    local characters = fetchCharactersByLicense(license, license2, source)
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
---   2. Process-local `creatingLicenses` set ensures that slot allocation runs
---      serially for the same player across concurrent sessions.
---   3. SQL UNIQUE INDEX `(license, cid)` is the last line of defence; the
---      second INSERT errors out cleanly and the player sees "slot taken".
---
--- NOTE: A MySQL `GET_LOCK`/`RELEASE_LOCK` advisory lock was previously used
--- here but has been removed. Those locks are per-connection (per-session),
--- and oxmysql multiplexes queries across a connection pool — so `RELEASE_LOCK`
--- frequently ran on a different pooled connection than the one `GET_LOCK`
--- acquired it on, leaking the lock. The next same-license create then blocked
--- for the full timeout, producing "took 5000ms to execute" slow-query
--- warnings (`SELECT GET_LOCK(?, ?)`). The process-local set + UNIQUE INDEX
--- below provide the same guarantees without the connection-pool footgun.
-----------------------------------------------------------------------------
--- Process-local set of licenses with an in-flight character creation. The
--- FXServer runs this resource in a single Lua state, so this reliably blocks
--- concurrent same-license creates. The UNIQUE INDEX remains as a last-line
--- DB-level safeguard.
local creatingLicenses = {}

local function withLicenseLock(license, timeoutSec, fn)
    --- Serialization is handled by the process-local `creatingLicenses` set
    --- (set by the caller before this runs) and the UNIQUE INDEX. No DB
    --- advisory lock is taken here — see the note above. `license`/`timeoutSec`
    --- are kept in the signature for call-site compatibility.
    return fn(true)
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

    local esxMode = isEsxMode()
    if not esxMode and not (Config.UseQbox and GetResourceState('qbx_core') == 'started') then
        return false, 'A supported framework core (qbx_core or es_extended) is required for character creation.'
    end

    if esxMode then
        if W2F.ESX.GetPlayer(source) then
            return false, 'Already logged into a character.'
        end
    elseif exports.qbx_core:GetPlayer(source) then
        return false, 'Already logged into a character.'
    end

    local primaryLicense = license or license2
    if creatingLicenses[primaryLicense] then
        return false, 'Character creation already in progress, please wait.'
    end
    creatingLicenses[primaryLicense] = true

    local createdOk, createdErr, createdMeta
    local runOk, runErr = pcall(withLicenseLock, primaryLicense, 5, function(_locked)
        local characters = fetchCharactersByLicense(license, license2, source)
        local maxSlots = getMaxCharacterSlots()
        local cid = findNextAvailableCid(characters, maxSlots)
        if not cid then
            createdOk, createdErr = false, 'No character slots available.'
            return
        end

        result.cid = cid

        if esxMode then
            --- ESX path: es_extended's createESXPlayer persists the users row
            --- itself when esx:onPlayerJoined arrives with identity data (the
            --- exact flow esx_multicharacter uses). Starting money comes from
            --- es_extended's StartingAccountMoney config, so no starter-item /
            --- license-repair handling is needed here.
            local identity = {
                firstname = result.firstname,
                lastname = result.lastname,
                dateofbirth = result.birthdate,
                sex = result.gender == 1 and 'f' or 'm',
                height = (Config.ESX and Config.ESX.defaultHeight) or 175,
            }
            local loginEsxOk, xPlayer = W2F.ESX.Login(source, cid, identity)
            if not loginEsxOk then
                --- `xPlayer` holds the failure reason string here, not a player.
                --- Surface it unconditionally — a silent "Failed to create
                --- character" with nothing in the console is impossible to
                --- diagnose, and ESX creation has several environmental failure
                --- modes (es_extended not in multichar mode, missing `users`
                --- columns, jobs not yet loaded) that all look identical client-side.
                local reason = tostring(xPlayer or 'unknown')
                print(('^1[w2f-multicharacter] ESX createCharacter failed src=%s cid=%s reason=%s^0'):format(
                    tostring(source), tostring(cid), reason))
                if reason == 'multichar_disabled' then
                    print('^3[w2f-multicharacter] es_extended is not in multichar mode. '
                        .. 'Add `setr esx:multichar true` to server.cfg and make sure esx_multicharacter is NOT running.^0')
                elseif reason == 'login_timeout' then
                    print('^3[w2f-multicharacter] es_extended did not create the character within the timeout. '
                        .. 'Check the console above for an oxmysql INSERT error and verify your `users` table '
                        .. 'matches your es_extended version.^0')
                end
                createdOk, createdErr = false, 'Failed to create character.'
                return
            end

            local citizenid = xPlayer and xPlayer.identifier
            if not citizenid or citizenid == '' then
                createdOk, createdErr = false, 'Character created but data missing.'
                return
            end

            if W2F.Database then
                W2F.Database.Log(license or license2, citizenid, 'create',
                    { cid = cid, name = ('%s %s'):format(result.firstname, result.lastname) })
            end

            local sess = ensureSession(source)
            sess.selectedCitizenid = citizenid
            sess.creatingCitizenid = citizenid

            createdOk = true
            createdMeta = {
                citizenid = citizenid,
                cid = cid,
                gender = result.gender,
                firstname = result.firstname,
                lastname = result.lastname,
            }
            return
        end

        local loginOk = exports.qbx_core:Login(source, nil, { charinfo = result })
        if not loginOk then
            createdOk, createdErr = false, 'Failed to create character.'
            return
        end

        local player = exports.qbx_core:GetPlayer(source)
        local playerData = player and player.PlayerData
        local qboxCitizenid = playerData and playerData.citizenid
        local citizenid = qboxCitizenid
        if not citizenid then
            createdOk, createdErr = false, 'Character created but data missing.'
            return
        end

        local dbLicense = waitForCharacterDatabaseLicense(citizenid, 5000)
        local ownsAfterCreate = ownsCitizenid(source, citizenid)
        local qboxOwnsAfterCreate = player ~= nil
            and playerData ~= nil
            and qboxCitizenid == citizenid
        local repairedLicense = false

        if qboxOwnsAfterCreate and (not dbLicense or dbLicense == '') then
            local repairLicense = license or license2
            if repairLicense and repairLicense ~= '' then
                local repairOk, affected = pcall(function()
                    return MySQL.update.await(
                        'UPDATE players SET license = ? WHERE citizenid = ? AND (license IS NULL OR license = "")',
                        { repairLicense, citizenid }
                    )
                end)
                repairedLicense = repairOk and (tonumber(affected) or 0) > 0
                if repairedLicense then
                    dbLicense = repairLicense
                    ownsAfterCreate = ownsCitizenid(source, citizenid)
                elseif Config.Debug and not repairOk then
                    print(('[w2f-multicharacter] createCharacter license repair failed src=%s citizenid=%s err=%s'):format(
                        tostring(source), tostring(citizenid), tostring(affected)))
                end
            end
        end

        if Config.Debug then
            print(('[w2f-multicharacter] createCharacter ownership src=%s citizenid=%s license=%s license2=%s dbLicense=%s ownsAfterCreate=%s qboxOwnsAfterCreate=%s qboxCitizenid=%s repairedLicense=%s playerLicense=%s'):format(
                tostring(source),
                tostring(citizenid),
                tostring(license),
                tostring(license2),
                tostring(dbLicense),
                tostring(ownsAfterCreate),
                tostring(qboxOwnsAfterCreate),
                tostring(qboxCitizenid),
                tostring(repairedLicense),
                tostring(playerData and playerData.license or nil)
            ))
        end

        --- Immediately after qbx_core:Login(source, nil, { charinfo = result }),
        --- qbx_core is the server-side authority that this source is logged in
        --- as the newly-created character. Keep ownsCitizenid for all normal
        --- paths, but allow this narrow post-create fallback so delayed or
        --- differently-formatted players.license rows don't reject valid creates.
        if not ownsAfterCreate and not qboxOwnsAfterCreate then
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
        --- In-flight creation marker: qbx_core:Login above already persisted the
        --- players row, but appearance/apartment aren't committed yet. If the
        --- player disconnects before a genuine completion point clears this, the
        --- playerDropped handler rolls the half-created character back so it
        --- doesn't orphan a slot. Cleared on appearance save / apartment claim /
        --- finishCreation / cancel.
        sess.creatingCitizenid = citizenid

        createdOk = true
        createdMeta = {
            citizenid = citizenid,
            cid = cid,
            gender = result.gender,
            firstname = result.firstname,
            lastname = result.lastname,
        }
    end)

    creatingLicenses[primaryLicense] = nil

    if not runOk then
        if W2F.Debug then W2F.Debug('createCharacter error: %s', tostring(runErr)) end
        return false, 'Character creation failed.'
    end
    if createdOk then return true, createdMeta end
    return false, createdErr or 'Character creation failed.'
end)

lib.callback.register('w2f-multicharacter:server:finishCreation', function(source)
    if not rateLimit(source, 'finishCreation') then
        return false
    end
    local license = getPlayerLicense(source)
    local citizenid = nil
    if isEsxMode() then
        local xPlayer = W2F.ESX.GetPlayer(source)
        citizenid = xPlayer and xPlayer.identifier
        W2F.ESX.Logout(source)
    elseif Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        local player = exports.qbx_core:GetPlayer(source)
        citizenid = player and player.PlayerData.citizenid
        exports.qbx_core:Logout(source)
    end

    --- Clear selection on logout-to-finalize so a follow-up requestSpawn
    --- can't reuse it before the next selectCharacter.
    local sess = session[source]
    if sess then
        sess.selectedCitizenid = nil
        --- Creation is genuinely complete (legacy flow) — stop the disconnect
        --- rollback from ever touching this committed character.
        sess.creatingCitizenid = nil
    end

    if W2F.Database and license then
        W2F.Database.Log(license, citizenid, 'finish_appearance', nil)
    end
    return true
end)

local function resolveAppearanceModel(appearance, playerData)
    local model = type(appearance) == 'table' and appearance.model or nil
    if type(model) == 'table' then
        if type(model.model) == 'string' and model.model ~= '' then
            return model.model
        end
        if model.hash then
            return tostring(model.hash)
        end
    elseif type(model) == 'number' then
        return tostring(model)
    elseif type(model) == 'string' and model ~= '' then
        return model
    end

    local charinfo = playerData and playerData.charinfo or {}
    local gender = tonumber(charinfo.gender) or tonumber(charinfo.sex) or 0
    return gender == 1 and 'mp_f_freemode_01' or 'mp_m_freemode_01'
end

local function verifyActivePlayerskin(citizenid, timeoutMs)
    local verifyDeadline = GetGameTimer() + (timeoutMs or 5000)
    repeat
        local verifyRow = MySQL.single.await(
            'SELECT skin FROM playerskins WHERE citizenid = ? AND active = 1 ORDER BY id DESC LIMIT 1',
            { citizenid }
        )
        if verifyRow and verifyRow.skin and verifyRow.skin ~= '' then
            return true, verifyRow
        end
        Wait(100)
    until GetGameTimer() >= verifyDeadline
    return false, nil
end

lib.callback.register('w2f-multicharacter:server:saveNewCharacterAppearance', function(source, appearance)
    if not rateLimit(source, 'saveNewAppearance') then
        return false, 'rate_limited'
    end

    if isEsxMode() then
        --- ESX path: skins persist in users.skin (esx_skin and
        --- illenium-appearance's ESX backend both write there). A nil payload
        --- runs the verify-only branch — used after esx_skin's own save.
        local xPlayer = W2F.ESX.GetPlayer(source)
        local esxCitizenid = xPlayer and xPlayer.identifier
        if not esxCitizenid or esxCitizenid == '' then
            return false, 'missing_player'
        end

        local esxVerifyOnly = appearance == nil
        if not esxVerifyOnly and type(appearance) ~= 'table' then
            return false, 'invalid_appearance'
        end
        if not esxVerifyOnly and not W2F.ESX.SaveAppearance(esxCitizenid, appearance) then
            return false, 'insert_failed'
        end
        if not W2F.ESX.HasSavedAppearance(esxCitizenid, 5000) then
            return false, 'verify_failed'
        end
        --- Appearance persisted — creation is committed; cancel the disconnect
        --- rollback for this character.
        if session[source] then session[source].creatingCitizenid = nil end
        return true
    end

    if not (Config.UseQbox and GetResourceState('qbx_core') == 'started') then
        return false, 'qbox_unavailable'
    end

    local player = exports.qbx_core:GetPlayer(source)
    local playerData = player and player.PlayerData
    local citizenid = playerData and playerData.citizenid
    if not citizenid or citizenid == '' then
        return false, 'missing_player'
    end

    local verifyOnly = appearance == nil
    if not verifyOnly and type(appearance) ~= 'table' then
        return false, 'invalid_appearance'
    end

    if Config.Debug then
        print(('[w2f-multicharacter] saveNewCharacterAppearance called src=%s citizenid=%s verifyOnly=%s'):format(
            tostring(source), tostring(citizenid), tostring(verifyOnly)))
    end

    if verifyOnly then
        local verified = verifyActivePlayerskin(citizenid, 5000)
        if Config.Debug then
            print(('[w2f-multicharacter] saveNewCharacterAppearance verifyOnly citizenid=%s verified=%s'):format(
                tostring(citizenid), tostring(verified)))
        end
        if not verified then
            return false, 'verify_failed'
        end
        --- Appearance is persisted — creation is committed; cancel the
        --- disconnect rollback for this character.
        if session[source] then session[source].creatingCitizenid = nil end
        return true
    end

    local model = resolveAppearanceModel(appearance, playerData)
    local encodedOk, encoded = pcall(json.encode, appearance)
    if not encodedOk or type(encoded) ~= 'string' or encoded == '' then
        return false, 'encode_failed'
    end

    if Config.Debug then
        print(('[w2f-multicharacter] saveNewCharacterAppearance saving src=%s citizenid=%s model=%s'):format(
            tostring(source), tostring(citizenid), tostring(model)))
    end

    local deactivateOk, deactivated = pcall(function()
        return MySQL.update.await('UPDATE playerskins SET active = 0 WHERE citizenid = ?', { citizenid })
    end)
    if not deactivateOk then
        if Config.Debug then
            print(('[w2f-multicharacter] saveNewCharacterAppearance deactivate failed citizenid=%s err=%s'):format(
                tostring(citizenid), tostring(deactivated)))
        end
        return false, 'deactivate_failed'
    end

    local saved = false
    local upsertOk, upsertResult = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO playerskins (citizenid, model, skin, active) VALUES (?, ?, ?, 1) ON DUPLICATE KEY UPDATE model = VALUES(model), skin = VALUES(skin), active = 1',
            { citizenid, model, encoded }
        )
    end)
    if upsertOk and upsertResult then
        saved = true
    else
        local insertOk, inserted = pcall(function()
            return MySQL.insert.await(
                'INSERT INTO playerskins (citizenid, model, skin, active) VALUES (?, ?, ?, 1)',
                { citizenid, model, encoded }
            )
        end)
        if insertOk and inserted then
            saved = true
            upsertResult = inserted
        elseif Config.Debug then
            print(('[w2f-multicharacter] saveNewCharacterAppearance insert failed citizenid=%s upsertErr=%s insertErr=%s'):format(
                tostring(citizenid), tostring(upsertResult), tostring(inserted)))
        end
    end

    if not saved then
        return false, 'insert_failed'
    end

    local verified = verifyActivePlayerskin(citizenid, 5000)

    if Config.Debug then
        print(('[w2f-multicharacter] saveNewCharacterAppearance result citizenid=%s model=%s deactivated=%s saved=%s verified=%s'):format(
            tostring(citizenid),
            tostring(model),
            tostring(deactivated),
            tostring(upsertResult),
            tostring(verified)
        ))
    end

    if not verified then
        return false, 'verify_failed'
    end
    --- Appearance is persisted — creation is committed; cancel the disconnect
    --- rollback for this character.
    if session[source] then session[source].creatingCitizenid = nil end
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
    if isEsxMode() then
        local xPlayer = W2F.ESX.GetPlayer(source)
        if xPlayer and xPlayer.identifier == citizenid then
            W2F.ESX.Logout(source)
        end

        local esxCleared = W2F.ESX.DeleteCharacter(citizenid)
        if esxCleared then
            --- Out-wait a late es_extended save racing the delete.
            local esxTimeout = GetGameTimer() + 2500
            while GetGameTimer() < esxTimeout do
                local row = MySQL.scalar.await('SELECT 1 FROM users WHERE identifier = ?', { citizenid })
                if not row then break end
                Wait(50)
            end
        end

        clearSelectedIf(source, citizenid)
        return esxCleared
    end

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

    if isEsxMode() then
        local xPlayer = W2F.ESX.GetPlayer(source)
        citizenid = xPlayer and xPlayer.identifier
        if citizenid and citizenid ~= '' then
            --- deleteCharacterFully's ESX branch logs out first, then deletes
            --- and verifies the row is gone.
            deleteCharacterFully(source, citizenid)
        else
            --- Login may have failed mid-creation; make sure they're out.
            pcall(function() W2F.ESX.Logout(source) end)
        end
    elseif Config.UseQbox and GetResourceState('qbx_core') == 'started' then
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

    --- Always clear selection + the in-flight creation marker (the character
    --- was just rolled back, so the disconnect handler must not re-delete).
    if session[source] then
        session[source].selectedCitizenid = nil
        session[source].creatingCitizenid = nil
    end

    if W2F.Database and license then
        W2F.Database.Log(license, citizenid, 'cancel_appearance', nil)
    end
    return true
end)

--- Recovery-only logout. The apartment-claim and regular fly paths call
--- qbx_core:Login (via CharacterLoad.Load without skipLogin) BEFORE the spawn
--- finishes; if the spawn then fails and the client recovers to the lineup,
--- the player is still logged in server-side, so the NEXT spawn's loadCharacter
--- trips qbx_core's "login twice" DropPlayer. RecoverFromFailedSpawn awaits this
--- to log them back out first.
---
--- CRITICAL: this must NEVER delete the character (do not reuse cancelCreation,
--- which calls deleteCharacterFully) — it runs for fully valid EXISTING
--- characters whose spawn merely failed. qbx_core:Logout is a safe no-op when
--- the source isn't logged in.
lib.callback.register('w2f-multicharacter:server:logoutForRecovery', function(source)
    if isEsxMode() then
        pcall(function() W2F.ESX.Logout(source) end)
    elseif Config.UseQbox and GetResourceState('qbx_core') == 'started' then
        pcall(function() exports.qbx_core:Logout(source) end)
    end
    if session[source] then
        session[source].selectedCitizenid = nil
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

    if isEsxMode() then
        return W2F.ESX.GetAppearance(citizenid)
    end

    local row = MySQL.single.await('SELECT skin FROM playerskins WHERE citizenid = ? AND active = 1', { citizenid })
    if row and row.skin then
        return decodeField(row.skin)
    end
    return nil
end)

--- Generic preview-ped data (saved model + appearance) for the lineup.
--- Mirrors qbx_core:server:getPreviewPedData's (clothing, model) return order
--- so the client adapter can treat both callbacks identically. Used when
--- qbx_core isn't running (ESX / qb-core).
lib.callback.register('w2f-multicharacter:server:getPreviewPedData', function(source, citizenid)
    if not rateLimit(source, 'getPreviewPedData') then return nil end
    if not citizenid or citizenid == '' then return nil end
    if not ownsCitizenid(source, citizenid) then return nil end

    if isEsxMode() then
        local model, skin = W2F.ESX.GetPreviewPedData(citizenid)
        return skin, model
    end

    local row = MySQL.single.await(
        'SELECT model, skin FROM playerskins WHERE citizenid = ? AND active = 1 ORDER BY id DESC LIMIT 1',
        { citizenid }
    )
    if not row then return nil end
    return decodeField(row.skin), row.model
end)

--- ESX login for an EXISTING character. QB-family clients use qbx_core's own
--- `qbx_core:server:loadCharacter` callback; ESX has no equivalent, so the
--- client CharacterLoad service calls this instead. Logs out any currently
--- active character first (safe relog), then logs into the requested slot.
lib.callback.register('w2f-multicharacter:server:loadCharacter', function(source, citizenid)
    if not rateLimit(source, 'loadCharacter') then return false end
    if not isEsxMode() then return false end
    if not ownsCitizenid(source, citizenid) then
        if Config.Debug then
            print(('[w2f-multicharacter] loadCharacter denied src=%s identifier=%s'):format(
                source, tostring(citizenid)))
        end
        return false
    end

    local slot = W2F.ESX.GetSlotFromIdentifier(citizenid)
    if not slot then return false end

    local xPlayer = W2F.ESX.GetPlayer(source)
    if xPlayer then
        if xPlayer.identifier == citizenid then
            --- Already logged in as this character (e.g. retry after a
            --- client-side timeout) — treat as success.
            return true
        end
        if not W2F.ESX.Logout(source) then return false end
    end

    local ok, reason = W2F.ESX.Login(source, slot, nil)
    if not ok then
        local why = tostring(reason or 'unknown')
        print(('^1[w2f-multicharacter] ESX loadCharacter failed src=%s identifier=%s reason=%s^0'):format(
            tostring(source), tostring(citizenid), why))
        if why == 'multichar_disabled' then
            print('^3[w2f-multicharacter] es_extended is not in multichar mode. '
                .. 'Add `setr esx:multichar true` to server.cfg and make sure esx_multicharacter is NOT running.^0')
        end
    end
    return ok == true
end)

local function fetchPlayerSavedPosition(citizenid)
    if not citizenid or citizenid == '' then return nil end

    if isEsxMode() then
        return W2F.ESX.GetSavedPosition(citizenid)
    end

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

    return fetchPlayerSavedPosition(cid)
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
    --- On servers without an apartment/property system the `properties` table
    --- may not exist; querying it would throw inside the callback. Guard so
    --- the no-apartment configuration degrades cleanly to "owns nothing".
    if not tableExists('properties') then return false end
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
    if not rateLimit(source, 'confirmApartmentClaimed') then
        return false
    end
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
            --- The property row exists — the direct-to-apartment character is
            --- committed (it now OWNS an apartment), so clear the in-flight
            --- creation marker. Without this the marker would never clear for
            --- direct-to-apartment characters (their appearance is saved later
            --- by illenium's own event, not saveNewCharacterAppearance), and a
            --- later disconnect would wrongly delete a valid, played-on,
            --- apartment-owning character.
            if session[source] then session[source].creatingCitizenid = nil end
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
    local src = source
    local sess = session[src]
    --- Capture the in-flight creation marker synchronously BEFORE clearing the
    --- session. If the player Alt-F4'd mid-creation (after qbx_core:Login
    --- persisted the players row, but before appearance/apartment committed),
    --- roll the half-created character back so it doesn't orphan a slot.
    --- Strictly gated on the explicit marker — never a heuristic like "no
    --- playerskins row" which would delete a valid mid-edit character.
    local pendingCid = sess and sess.creatingCitizenid or nil
    session[src] = nil
    if pendingCid then
        CreateThread(function()
            --- Let qbx_core's own playerDropped save settle first, then delete;
            --- deleteCharacterFully's 2.5s verify loop out-waits a late re-save.
            Wait(1000)
            pcall(deleteCharacterFully, src, pendingCid)
        end)
    end
end)

--- Clear the selection when QBX logs the player out so a stale
--- selectedCitizenid can't bleed across sessions.
AddEventHandler('qbx_core:server:onLogout', function(source)
    if session[source] then
        session[source].selectedCitizenid = nil
    end
end)

--- ESX equivalent: es_extended handles this same event for the actual
--- save + unload; this handler only clears our session selection.
AddEventHandler('esx:playerLogout', function(source)
    if session[source] then
        session[source].selectedCitizenid = nil
    end
end)

--- Convenience export for other resources that want to know which
--- multichar-selected character a source is currently tied to.
exports('GetSelectedCitizenid', function(src)
    return session[src] and session[src].selectedCitizenid or nil
end)
