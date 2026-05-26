W2F = W2F or {}
W2F.Framework = W2F.Framework or {}

local valid = { auto = true, qbox = true, qbcore = true, esx = true }

local function resolveConfigured()
    local configured = Config and Config.Framework or 'auto'
    if type(configured) == 'string' then
        configured = configured:lower()
    end
    if not valid[configured] then configured = 'auto' end
    return configured
end

function W2F.Framework.Detect()
    local configured = resolveConfigured()
    if configured ~= 'auto' then return configured end
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    print('^1[w2f-multicharacter] No supported framework detected (qbx_core/qb-core/es_extended).^0')
    return 'unknown'
end

function W2F.Framework.GetName() return W2F.Framework.Detect() end
function W2F.Framework.IsQbox() return W2F.Framework.Detect() == 'qbox' end
function W2F.Framework.IsQBCore() return W2F.Framework.Detect() == 'qbcore' end
function W2F.Framework.IsESX() return W2F.Framework.Detect() == 'esx' end
function W2F.Framework.IsQBFamily()
    local name = W2F.Framework.Detect()
    return name == 'qbox' or name == 'qbcore'
end
