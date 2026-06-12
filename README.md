# w2f-multicharacter

Cinematic multicharacter selection for **Qbox**, **QBCore** and **ESX Legacy** — character create / select / delete / spawn, with illenium-appearance and optional starter apartments.

`Config.Framework = 'auto'` (default) detects the running core in this order: `qbx_core` → `qb-core` → `es_extended`.

# Preview 
<img width="1487" height="840" alt="image" src="https://github.com/user-attachments/assets/40fc47ad-b28e-4313-9f9e-b9a9e7847cfe" />
<img width="1487" height="840" alt="image" src="https://github.com/user-attachments/assets/f44accbd-7289-49e8-8535-6587d68758c4" />


## Requirements

- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)
- A framework core — one of:
  - [qbx_core](https://github.com/Qbox-project/qbx_core) (default, full feature set)
  - [qb-core](https://github.com/qbcore-framework/qb-core) (see [Using with QBCore](#using-with-qbcore))
  - [es_extended](https://github.com/esx-framework/esx_core) (ESX Legacy, multichar mode — see [Using with ESX](#using-with-esx))
- [illenium-appearance](https://github.com/iLLeniumStudios/illenium-appearance) — required for new-character clothing (on ESX, esx_skin works as a fallback)
- [qbx_properties](https://github.com/Qbox-project/qbx_properties) — only if you use the default starter-apartment flow (Qbox only)

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

**Apartments are fully optional.** The starter-apartment flow auto-detects whether an apartment system is running and degrades gracefully when one is not — no config change is required to run with or without apartments.

**Starter apartment flow (when available):** leave `Config.CharacterCreation.directToApartment = true` and ensure the apartment resource named by `Config.CharacterCreation.apartmentResource` (default `qbx_properties`) is running. Set `starterApartmentIndex` to match an entry in that resource's `config/shared.lua` (`apartmentOptions`). New characters are dropped directly into their starter apartment with the clothing editor opening inside.

**No apartments (standalone):** if the `apartmentResource` is not started (or you set `directToApartment = false`, or `apartmentResource = ''`), creation automatically uses the appearance-editor → spawn-picker flow. The spawn picker shows only the default `Config.Spawns` locations (no apartment cards), and no `properties` table is required.

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

## Using with QBCore

qb-core is supported with the same flow as Qbox. Characters live in the standard `players` table (one row per `citizenid`, slot in `charinfo.cid`) and skins in `playerskins`, so existing qb-multicharacter databases keep working.

### QBCore setup

1. Leave `Config.Framework = 'auto'` (qb-core is detected when qbx_core isn't running) or set `'qbcore'` explicitly.
2. **Do not run `qb-multicharacter` or `qb-spawn`** — this resource replaces both. Remove/disable them and any `qb-multicharacter` references in qb-core's config (`Config.Characters` is not used).
3. Start order: `ox_lib`, `oxmysql`, `qb-core`, `illenium-appearance`, then `w2f-multicharacter`.
4. Creation, login, logout and delete go through qb-core's own `Player.Login` / `Player.Logout` / `Player.DeleteCharacter`, so addon events (`QBCore:Server:OnPlayerLoaded`, delete cascades) fire as usual.
5. Starter apartments are Qbox-only (`qbx_properties`); qb-core uses the appearance-editor → spawn-picker pipeline automatically.

## Using with ESX

ESX Legacy is supported as an alternative framework. Characters are stored the same way `esx_multicharacter` stores them: one `users` row per character with a `char<slot>:<license>` identifier, so existing multichar databases keep working. A full step-by-step ESX Legacy guide (including the txAdmin recipe quirks) lives in [esx.md](esx.md).

### ESX setup

1. In `config.lua`, set the framework (or leave `'auto'` — es_extended is detected when no QB core is running):

   ```lua
   Config.Framework = 'esx'
   ```

2. Enable es_extended's multichar mode — **how depends on your ESX version**:
   - **ESX 1.13+** ignores the `esx:multichar` convar; multichar is on only when a resource named `esx_multicharacter` exists (`shared/config/main.lua`: `Config.Multichar = GetResourceState("esx_multicharacter") ~= "missing"`). Create a no-code stub resource with that exact name — see [esx.md](esx.md) for the 5-line fxmanifest.
   - **Older ESX** reads the convar: add `setr esx:multichar true` to server.cfg.

   Without multichar mode, es_extended silently logs players in behind the selector and creation fails with "Already logged into a character".

3. **Do not run the real `esx_multicharacter`** (or any other multicharacter/spawn-select resource) alongside this one — disable it by renaming its `fxmanifest.lua`, since `ensure [core]` starts every resource in the folder regardless of folder name.

4. Start order:

   ```cfg
   ensure ox_lib
   ensure oxmysql
   ensure es_extended
   ensure illenium-appearance   # preferred; or esx_skin + skinchanger
   ensure [w2f]
   ensure w2f-multicharacter
   ```

5. `sql/install.sql` is **not** required on ESX — es_extended's own `users` table is used for characters, skins (`users.skin`), and positions. The audit log (`Config.CharacterCreation.auditLog`, on by default) writes to the optional `w2f_multicharacter_log` table; if that table is absent the resource detects it at startup and silently disables the audit log (no errors). To keep the audit log, run just that one `CREATE TABLE` from `sql/install.sql`.

### ESX notes & limitations

- **Appearance**: illenium-appearance (ESX backend) gives the full experience including dressed lineup preview peds. With only esx_skin/skinchanger, creation and spawning work, but lineup preview peds fall back to default freemode models (skinchanger can only apply skins to the local player ped).
- **Starter apartments** (`directToApartment`) are Qbox-only (`qbx_properties`). On ESX, creation automatically uses the standalone appearance-editor → spawn-picker pipeline.
- **Starting money** comes from es_extended's `StartingAccountMoney` config; Qbox starter items are not given on ESX.
- **Deleting a character** wipes the tables listed in `Config.ESX.characterDataTables` (users, owned_vehicles, addon_account_data, datastore_data, billing by default) — extend that list to match your server's addons.
- New-character identity height defaults to `Config.ESX.defaultHeight` (the creation form doesn't collect height).

## Optional config

| Setting | File | Purpose |
|---------|------|---------|
| `Config.Framework` | `config.lua` | `'auto'`, `'qbox'`, `'qbcore'`, or `'esx'` |
| `Config.ESX` | `config.lua` | ESX-only options (default height, delete-cascade tables) |
| `Config.General.MaxCharacters` | `config.lua` | Character slots per player — the single limit (client + server). Set to `1` for one character. Capped by `#Config.Scene.pedSlots`; add ped slots to allow more than 3. On ESX this controls the count, **not** the `esx:multichar` convar. |
| `Config.Spawns` | `config.lua` | Spawn locations in the sky picker |
| `Config.CharacterCreation` | `config.lua` | Name/DOB limits, apartment vs spawn-picker flow |
| `Config.Debug` | `config.lua` | Dev commands (`/w2fmc_open`, `/w2fmc_state`, etc.) |

## License

MIT
