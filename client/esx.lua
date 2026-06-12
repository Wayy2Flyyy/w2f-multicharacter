--- W2F.ESX - client-side ESX Legacy adapter.
---
--- Thin wrapper over es_extended's shared object so the rest of the client
--- (bootstrap, character_load, main) can ask framework questions without
--- caring which core is running.

W2F = W2F or {}
W2F.ESX = W2F.ESX or {}

local esxObject

function W2F.ESX.IsActive()
    return W2F.Framework.IsESX() and GetResourceState('es_extended') == 'started'
end

function W2F.ESX.Core()
    if esxObject then return esxObject end
    if GetResourceState('es_extended') ~= 'started' then return nil end
    local ok, esx = pcall(function() return exports['es_extended']:getSharedObject() end)
    if ok then esxObject = esx end
    return esxObject
end

function W2F.ESX.IsLoggedIn()
    local esx = W2F.ESX.Core()
    if not esx then return false end
    local ok, loaded = pcall(function() return esx.IsPlayerLoaded() end)
    return ok and loaded == true
end

--- The identifier of the character this client is logged in as, or nil.
---
--- Maintained from the login/logout events rather than read from
--- ESX.GetPlayerData() or ESX.IsPlayerLoaded(), because in multichar mode:
---   * IsPlayerLoaded() only turns true after a `playerSpawned` /
---     `esx:onPlayerSpawn` event that the multichar resource (us) fires
---     AFTER placement — gating the load loop on it deadlocks every spawn.
---   * es_extended does NOT clear ESX.PlayerData on esx:onPlayerLogout, so
---     reading PlayerData.identifier directly returns a stale identifier
---     after a logout (e.g. spawn recovery), which would wrongly skip the
---     next login.
local activeIdentifier = nil

RegisterNetEvent('esx:playerLoaded', function(xPlayer)
    activeIdentifier = type(xPlayer) == 'table' and xPlayer.identifier or nil
end)

RegisterNetEvent('esx:onPlayerLogout', function()
    activeIdentifier = nil
end)

function W2F.ESX.GetActiveIdentifier()
    return activeIdentifier
end

function W2F.ESX.GetPlayerData()
    local esx = W2F.ESX.Core()
    if not esx then return nil end
    local ok, data = pcall(function() return esx.GetPlayerData() end)
    if not ok then return nil end
    return data
end
