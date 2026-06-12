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

function W2F.ESX.GetPlayerData()
    local esx = W2F.ESX.Core()
    if not esx then return nil end
    local ok, data = pcall(function() return esx.GetPlayerData() end)
    if not ok then return nil end
    return data
end
