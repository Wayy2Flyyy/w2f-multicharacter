# w2f-multicharacter — ESX Legacy Install

Exact steps for a stock ESX Legacy (txAdmin recipe) server, verified on es_extended 1.13.5. Paths are relative to your `txData/<deployment>/` folder.

## 1. Install ox_lib (not in the ESX Legacy recipe)

Download: <https://github.com/communityox/ox_lib/releases/latest/download/ox_lib.zip>

Extract so you have:

```text
resources/[standalone]/ox_lib/fxmanifest.lua
```

Use the release zip, not the source code zip — source has no built web UI.

## 2. Install illenium-appearance (not in the ESX Legacy recipe)

Download: <https://github.com/iLLeniumStudios/illenium-appearance/releases/latest/download/illenium-appearance.zip>

Extract so you have:

```text
resources/[standalone]/illenium-appearance/fxmanifest.lua
```

## 3. Make illenium-appearance provide esx_skin

Four stock addons (`esx_clotheshop`, `esx_barbershop`, `esx_accessories`, `esx_ambulancejob`) declare `esx_skin` in their fxmanifest `dependencies` and will not start without it.

Edit `resources/[standalone]/illenium-appearance/fxmanifest.lua`, after the `lua54 "yes"` line add:

```lua
provide "esx_skin"
provide "skinchanger"
```

## 4. Disable esx_skin, skinchanger, esx_multicharacter

`ensure [core]` starts every resource in `resources/[core]` — renaming a folder does NOT disable it. Rename the manifests:

```text
resources/[core]/esx_skin/fxmanifest.lua            -> fxmanifest.lua.disabled
resources/[core]/skinchanger/fxmanifest.lua         -> fxmanifest.lua.disabled
resources/[core]/esx_multicharacter/fxmanifest.lua  -> fxmanifest.lua.disabled
```

Also rename the multicharacter folder so step 5's stub can take its name:

```text
resources/[core]/esx_multicharacter -> esx_multicharacter_disabled
```

Keep `esx_identity` — w2f passes identity through `esx:onPlayerJoined` itself.

## 5. Stub esx_multicharacter (required on es_extended 1.13+)

es_extended 1.13+ ignores the `esx:multichar` convar. Multichar mode is enabled by resource detection only (`es_extended/shared/config/main.lua` line 61):

```lua
Config.Multichar = GetResourceState("esx_multicharacter") ~= "missing"
```

With no resource named `esx_multicharacter`, es_extended runs in single-character mode: it auto-logs every player in with a bare identifier on connect, the multichar `esx:onPlayerJoined` handler is never registered, and w2f character creation fails instantly with "Already logged into a character" — with nothing in the server console.

Create `resources/[core]/esx_multicharacter/fxmanifest.lua` containing only:

```lua
fx_version 'cerulean'
game 'gta5'

name 'esx_multicharacter'
version '1.0.0'
description 'Stub that switches es_extended into multichar mode for w2f-multicharacter'
```

No scripts, no code. The folder name must be exactly `esx_multicharacter` — the renamed `esx_multicharacter_disabled` folder from step 4 does not count.

## 6. Database

Run against your server database (`set mysql_connection_string` in server.cfg names it):

```text
resources/[standalone]/illenium-appearance/sql/player_outfits.sql
resources/[standalone]/illenium-appearance/sql/player_outfit_codes.sql
resources/[standalone]/illenium-appearance/sql/management_outfits.sql
resources/[standalone]/illenium-appearance/sql/playerskins.sql
```

Do NOT run this resource's full `sql/install.sql` on ESX. Optional — only the audit-log table from it:

```sql
CREATE TABLE IF NOT EXISTS `w2f_multicharacter_log` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `license` varchar(255) NOT NULL,
  `citizenid` varchar(50) DEFAULT NULL,
  `action` varchar(64) NOT NULL,
  `detail` text DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `license` (`license`),
  KEY `citizenid` (`citizenid`),
  KEY `action` (`action`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

If skipped, the audit log disables itself at startup with no errors. If you keep it, it records every create / select / spawn request / cancel with timestamps — the single most useful debugging tool for this resource.

Existing `esx_multicharacter` characters keep working: w2f uses the same `char<slot>:<license>` identifier scheme in `users`.

## 7. Place this resource

```text
resources/[w2f]/w2f-multicharacter/fxmanifest.lua
```

## 8. config.lua

`resources/[w2f]/w2f-multicharacter/config.lua` line 3:

```lua
Config.Framework = 'esx'
```

## 9. server.cfg

```cfg
ensure ox_lib
ensure oxmysql

ensure [core]
ensure illenium-appearance
ensure [w2f]
ensure w2f-multicharacter
```

`setr esx:multichar true` is not needed on es_extended 1.13+ (the convar is ignored — step 5 is what enables multichar mode); it is harmless to keep for older versions or third-party scripts that read it. `ensure illenium-appearance` works from inside `[standalone]` — an explicit ensure starts it at that line.

## 10. Restart and verify

Full restart via txAdmin (renamed manifests and the new stub only register on restart). On connect the character selector opens over the lineup scene. Create a character: form → illenium appearance editor → sky spawn picker → spawn.

Quick health checks after boot:

- Server console shows `[w2f-multicharacter][server] MySQL ready` and no red lines from `illenium-appearance` or `w2f-multicharacter`.
- `users` table gets `char<slot>:<license>` rows only — a row with a bare license hex and NULL firstname means es_extended is still in single-character mode (step 5 missing or stub misnamed).

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Could not find dependency ox_lib` / w2f won't start | Step 1 missing, or wrong folder depth (fxmanifest.lua must be one level inside ox_lib/) |
| `attempt to index a nil value (global 'lib')` spam from illenium-appearance | Same: ox_lib missing or started after it |
| Script errors from `esx_multicharacter` paths | Step 4 manifest rename missed, or server not fully restarted |
| Create fails instantly, nothing in server console; selector works otherwise | Step 5 stub missing — es_extended in single-character mode, player already logged in behind the selector |
| `esx_clotheshop` / `esx_barbershop` / `esx_accessories` / `esx_ambulancejob` won't start | Step 3 `provide` lines missing |
| Missing-table warnings from `server/database.lua` | Step 6 not run |
| Selector never opens, player spawns normally instead | es_extended logged the player in itself — step 5 again, or another resource calls `esx:onPlayerJoined` |

When the audit-log table is installed, `SELECT * FROM w2f_multicharacter_log ORDER BY id DESC LIMIT 20;` shows exactly how far each attempt got (`create`, `select`, `request_spawn`, `cancel_appearance`, `rate_limited`). For client-side detail, set `Config.General.Debug = true` in config.lua and read the F8 console / `%LOCALAPPDATA%\FiveM\FiveM.app\logs`.
