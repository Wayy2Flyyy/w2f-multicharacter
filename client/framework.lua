W2F = W2F or {}
W2F.Framework = W2F.Framework or {}

local function qbObject()
    return exports['qb-core'] and exports['qb-core']:GetCoreObject() or nil
end

local function esxObject()
    return exports['es_extended'] and exports['es_extended']:getSharedObject() or nil
end

function W2F.Framework.GetPlayerData()
    local fw = W2F.Framework.GetName()
    if fw == 'qbox' and exports.qbx_core and exports.qbx_core.GetPlayerData then
        return exports.qbx_core:GetPlayerData()
    elseif fw == 'qbcore' then
        local qb = qbObject()
        return qb and qb.Functions.GetPlayerData() or nil
    elseif fw == 'esx' then
        local esx = esxObject()
        return esx and esx.GetPlayerData() or nil
    end
    return nil
end

function W2F.Framework.GetIdentifier()
    local fw, data = W2F.Framework.GetName(), W2F.Framework.GetPlayerData()
    if fw == 'esx' then return data and data.identifier or nil end
    return data and (data.citizenid or data.license) or nil
end
