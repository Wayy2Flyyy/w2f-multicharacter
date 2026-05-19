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
}

client_scripts {
    'client/utils.lua',
    'client/qbox.lua',
    'client/camera.lua',
    'client/characters.lua',
    'client/interaction.lua',
    'client/spawner.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/app.js',
    'web/style.css',
}

dependencies {
    'ox_lib',
    'qbx_core',
}
