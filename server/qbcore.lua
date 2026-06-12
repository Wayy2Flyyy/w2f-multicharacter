--- W2F.QBCore - server-side qb-core adapter.
---
--- Mirrors the W2F.ESX adapter shape for qb-core servers. qb-core shares the
--- qbx `players` table schema (citizenid / license / charinfo / playerskins),
--- so all SQL-based reads in server/main.lua work unchanged; only the live
--- session operations (login / logout / delete) need the core object, which
--- qb-core exposes via GetCoreObject() rather than flat exports.

W2F = W2F or {}
W2F.QBCore = W2F.QBCore or {}

local coreObject

local function core()
    if coreObject then return coreObject end
    if GetResourceState('qb-core') ~= 'started' then return nil end
    local ok, qb = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok then coreObject = qb end
    return coreObject
end

function W2F.QBCore.IsActive()
    return W2F.Framework.IsQBCore() and GetResourceState('qb-core') == 'started'
end

function W2F.QBCore.GetPlayer(source)
    local qb = core()
    if not qb then return nil end
    local ok, player = pcall(function() return qb.Functions.GetPlayer(source) end)
    return ok and player or nil
end

--- Logs the player in. For a NEW character pass `charinfo` (the validated
--- create payload incl. cid) and nil citizenid — qb-core's Player.Login
--- creates the players row itself, exactly like qb-multicharacter does.
--- For an EXISTING character pass the citizenid. Returns true on success.
function W2F.QBCore.Login(source, citizenid, charinfo)
    local qb = core()
    if not qb or not qb.Player or not qb.Player.Login then return false end
    local ok, result = pcall(qb.Player.Login, source,
        citizenid or false,
        charinfo and { charinfo = charinfo } or nil)
    return ok and result == true
end

--- Safe no-op when the source isn't logged in.
function W2F.QBCore.Logout(source)
    local qb = core()
    if not qb or not qb.Player or not qb.Player.Logout then return false end
    pcall(qb.Player.Logout, source)
    return true
end

--- Prefers qb-core's own cascade (fires DeleteCharacter events for addons).
--- Returns false when the core path is unavailable or threw; the caller
--- (deleteCharacterFully) falls back to the generic table wipe.
function W2F.QBCore.DeleteCharacter(source, citizenid)
    local qb = core()
    if not qb or not qb.Player then return false end
    if qb.Player.DeleteCharacter then
        return pcall(qb.Player.DeleteCharacter, source, citizenid) == true
    end
    if qb.Player.ForceDeleteCharacter then
        return pcall(qb.Player.ForceDeleteCharacter, citizenid) == true
    end
    return false
end
