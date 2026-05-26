W2F = W2F or {}
W2F.Framework = W2F.Framework or {}

local function qbObject()
    return exports['qb-core'] and exports['qb-core']:GetCoreObject() or nil
end

local function esxObject()
    return exports['es_extended'] and exports['es_extended']:getSharedObject() or nil
end

function W2F.Framework.GetPlayer(source)
    local fw = W2F.Framework.GetName()
    if fw == 'qbox' then return exports.qbx_core:GetPlayer(source) end
    if fw == 'qbcore' then local qb = qbObject(); return qb and qb.Functions.GetPlayer(source) or nil end
    if fw == 'esx' then local esx = esxObject(); return esx and esx.GetPlayerFromId(source) or nil end
end

function W2F.Framework.GetIdentifier(source)
    local p, fw = W2F.Framework.GetPlayer(source), W2F.Framework.GetName()
    if not p then return GetPlayerIdentifierByType(source, 'license2') or GetPlayerIdentifierByType(source, 'license') end
    if fw == 'esx' then return p.identifier end
    return p.PlayerData and (p.PlayerData.citizenid or p.PlayerData.license) or nil
end

function W2F.Framework.GetCitizenId(source)
    local p = W2F.Framework.GetPlayer(source)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end
