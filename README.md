# w2f-multicharacter

Cinematic multicharacter selection for **Qbox** — character create / select / delete / spawn, with illenium-appearance and optional starter apartments.

## Requirements

- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)
- [qbx_core](https://github.com/Qbox-project/qbx_core)
- [illenium-appearance](https://github.com/iLLeniumStudios/illenium-appearance) — required for new-character clothing
- [qbx_properties](https://github.com/Qbox-project/qbx_properties) — only if you use the default starter-apartment flow

## Install

### 1. Add the resource

Place the folder at:

```
resources/[w2f]/w2f-multicharacter/
```

### 2. Import the database (once)

Run this file against your server database (HeidiSQL, phpMyAdmin, etc.):

```
sql/install.sql
```

Skip this if you already have a working Qbox database with `players`, `users`, and illenium-appearance tables. The script is safe to re-run.

### 3. Enable external characters in Qbox

In `qbx_core/config/client.lua`:

```lua
characters = {
    useExternalCharacters = true,
    -- ...
}
```

If this stays `false`, qbx_core and w2f-multicharacter will both try to open character selection.

### 4. Configure this resource

In `config.lua`, confirm:

```lua
Config.UseExternalCharacters = true
Config.AutoOpen = true
```

**Starter apartment flow (default):** leave `Config.CharacterCreation.directToApartment = true` and ensure `qbx_properties` is running. Set `starterApartmentIndex` to match an entry in `qbx_properties/config/shared.lua` (`apartmentOptions`).

**No apartments:** set `directToApartment = false` and use the spawn-picker flow instead.

### 5. Update server.cfg

Stop the default Qbox spawn resource and start w2f-multicharacter **after** its dependencies:

```cfg
ensure ox_lib
ensure oxmysql
ensure qbx_core
ensure illenium-appearance
ensure qbx_properties   # only if using starter apartments

stop qbx_spawn          # required — conflicts with this spawn system

ensure [w2f]
ensure w2f-multicharacter
```

### 6. Restart and verify

1. Restart the server (or `ensure w2f-multicharacter`).
2. Connect — the cinematic character selector should open automatically.
3. Create a character, finish appearance, and spawn in.

If selection does not open, check the server console for missing-table warnings from `server/database.lua`.

## Optional config

| Setting | File | Purpose |
|---------|------|---------|
| `Config.General.MaxCharacters` | `config.lua` | Character slots per player (match `Config.Scene.pedSlots`) |
| `Config.Spawns` | `config.lua` | Spawn locations in the sky picker |
| `Config.CharacterCreation` | `config.lua` | Name/DOB limits, apartment vs spawn-picker flow |
| `Config.Debug` | `config.lua` | Dev commands (`/w2fmc_open`, `/w2fmc_state`, etc.) |

## License

MIT
