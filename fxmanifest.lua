fx_version 'cerulean'
game 'gta5'

name 'w2f-multicharacter'
description 'W2F cinematic multicharacter selection'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/state.lua',
    'shared/framework.lua',
}

client_scripts {
    -- Core (load first; everything else can depend on them).
    'client/core/session.lua',
    'client/core/event.lua',
    'client/core/watchdog.lua',
    'client/core/telemetry.lua',
    -- Services (frame/streaming/character_load/nui_bridge).
    'client/services/frame.lua',
    'client/services/performance.lua',
    'client/services/diagnostics.lua',
    'client/services/interior.lua',
    'client/services/render.lua',
    'client/services/streaming.lua',
    'client/services/nui_bridge.lua',
    'client/services/character_load.lua',
    -- Flows / UI (the existing modules; migrated to use Core + Services).
    'client/utils.lua',
    'client/cleanup.lua',
    'client/bootstrap.lua',
    'client/framework.lua',
    'client/esx.lua',
    'client/qbox.lua',
    'client/camera.lua',
    'client/characters.lua',
    'client/creator.lua',
    'client/interaction.lua',
    'client/hud.lua',
    'client/spawner.lua',
    'client/main.lua',
    -- Dev / tests (gated by Config.Debug).
    'client/dev/tests.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/framework.lua',
    'server/esx.lua',
    'server/database.lua',
    'server/main.lua',
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/app.js',
    'web/style.css',
}

-- Runtime integration notes:
--   Framework: qbx_core (default), or es_extended with `setr esx:multichar true`
--   (set Config.Framework = 'esx' or leave 'auto'). qb-core is partially supported.
--   illenium-appearance is preferred for character customization on every
--   framework; esx_skin/skinchanger work as the ESX fallback.
--   qbx_properties is optional and Qbox-only; without it, creation uses the
--   standalone appearance flow.
dependencies {
    'ox_lib',
    'oxmysql',
}
