# w2f-multicharacter

Cinematic multicharacter selection for **Qbox** (`qbx_core`). Premium overview camera, left-click orbit controls, cursor ped selection, and sky-based spawn cinematics.

## Features

- Fixed cinematic overview showing the full character lineup
- Hold **left click** + mouse to orbit (yaw/pitch/distance clamped, smoothed)
- Click peds to select; character details appear only after selection
- **Spawn** sends the camera to the sky, then four spawn locations (Last Location, Police Station, Public Centre, Hospital)
- Interpolated fly-to and float-down spawn sequence

## Dependencies

- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)
- [qbx_core](https://github.com/Qbox-project/qbx_core)
- Optional: `illenium-appearance` for preview ped skins

## Install

1. Place in your `resources` folder and add `ensure w2f-multicharacter` **after** `qbx_core`.
2. Disable or remove default `qbx` multicharacter UI overlap if another resource handles character select.
3. Tune `config.lua` — especially `Config.Scene.focal`, `Config.Scene.pedSlots`, and `Config.Spawns`.

## Configuration

| Section | Purpose |
|--------|---------|
| `Config.Scene` | Ped lineup positions and camera focal point |
| `Config.CameraControl` | Orbit sensitivity, limits, smoothing |
| `Config.Spawns` | Sky spawn locations and last-location fallback |
| `Config.SpawnCinematic` | Sky rise, fly, hover, and descend timings |

## Client files

- `client/camera.lua` — Overview + cinematic camera
- `client/interaction.lua` — LMB drag, ped ray pick, click debounce
- `client/characters.lua` — Preview peds and details payload
- `client/spawner.lua` — Sky spawn flow
- `web/` — Minimal details panel and sky spawn UI

## Server

Thin Qbox integration only: character list, appearance fetch, last location, and `Login` on spawn. No duplicate character database logic.
