# w2f-multicharacter

Cinematic multicharacter selection for **Qbox** with overview camera orbit, cursor ped picking, and sky spawn cinematics.

## Qbox setup (required)

In `qbx_core/config/client.lua` set:

```lua
characters = {
    useExternalCharacters = true,
    -- ...
}
```

Then in this resource `config.lua`:

```lua
Config.UseExternalCharacters = true
Config.AutoOpen = true
```

Without `useExternalCharacters`, **both** this resource and qbx_core will fight over character selection on join.

## Features

- Cinematic intro into a fixed overview of all preview peds
- Hold **LMB** + move mouse: clamped, smoothed orbit camera
- Click peds to select; details panel only after click
- **Spawn** → sky rise → 4 spawn cards → fly-down cinematic → `qbx_core:server:loadCharacter`

## Dependencies

- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql) (fallback character/appearance queries)
- [qbx_core](https://github.com/Qbox-project/qbx_core)
- Optional: [illenium-appearance](https://github.com/iLLeniumStudios/illenium-appearance)

## Configuration

| Key | Purpose |
|-----|---------|
| `Config.Scene.pedSlots` | Preview ped positions (vec4) |
| `Config.GetSceneFocal()` | Auto center look-at from slots |
| `Config.CameraControl` | Orbit limits, sensitivity, smoothing |
| `Config.Spawns` | Sky spawn locations + last-location fallback |

## Architecture

| File | Role |
|------|------|
| `client/camera.lua` | Overview orbit, intro, cinematics |
| `client/interaction.lua` | LMB drag, ray pick, debounced clicks |
| `client/characters.lua` | Preview peds, highlights, details payload |
| `client/spawner.lua` | Sky spawn flow and finalize |
| `client/qbox.lua` | Qbox callbacks (characters, preview, load) |
| `server/main.lua` | MySQL fallback only when Qbox data unavailable |
