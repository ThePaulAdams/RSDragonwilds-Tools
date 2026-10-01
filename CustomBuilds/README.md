# Custom Builds

Place any of the game's 3,600+ models in your world: temple and castle walls, statues, banners, trophies, rocks, props and more. Browse them with pictures, then place, turn, tilt, resize, snap and nudge them. Your placements are saved and come back every time you load.

## Requirements

- **UE4SS experimental build** (the "experimental-latest" release from the RE-UE4SS GitHub, with UE 5.6 support). The v3.0.1 stable release does not support this game.
- Single player.

## Install

1. Install UE4SS for RuneScape: Dragonwilds (into `RSDragonwilds\Binaries\Win64`).
2. Copy the `CustomBuilds` folder into `RSDragonwilds\Binaries\Win64\ue4ss\Mods\`.
3. Start the game. The mod is on because `CustomBuilds\enabled.txt` is there; delete that file to turn it off.

## How to use

1. Press **N** to open the model browser. Pick a category on the left, then click a picture tile on the right (hover a tile to see its name).
2. A see-through copy of the model follows your crosshair. Adjust it, then **left click** to place it. You can keep clicking to place more.
3. **Right click** stops placing.

Placed models are the mod's own objects: no building materials, no foundation rules. They have collision and stay visible at a distance.

## Keys

| While placing | |
|---|---|
| Left click | place |
| Right click / Esc | stop placing |
| Left / Right | turn 15° (hold Shift: 90°) |
| Up / Down | tilt 15° (hold Shift: 90°) |
| Ctrl + Up / Down | roll 90° |
| + / - | bigger / smaller |
| Alt + arrows | nudge away / towards you, left / right |
| Alt + + / - | nudge up / down |
| End | snap mode: EDGES (flush against your other models) / GRID (lined up with your base) / FREE |
| Home | reset turn, tilt, roll, size and nudge |

| Any time | |
|---|---|
| N | open / close the model browser |
| Delete | delete the custom model you're looking at |
| Insert | pick up the custom model you're looking at and move it (left click puts it down, right click puts it back) |
| Backspace | undo the last place, delete or move |

Tilt, roll and size are remembered per model. For example, a castle entrance only needs standing up once.

**Search:** open the console (F10 with the usual UE4SS console setup) and type `cb find statue`. The results appear as a category in the browser.

## Files

- `models.txt`: your favourites (the FAVOURITES category). Add lines as `Name | /Game/...mesh path`.
- `models-all.txt`: every model the browser lists.
- `thumbs\`: the tile pictures.
- `placed.txt`: your placed models, written by the mod (the previous version is kept as `placed.txt.bak`). Back it up if you care about your builds.
- `orient.txt`: the remembered tilt, roll and size for each model.

## Good to know

- Placed models are saved by the mod, not in the game's save. If you remove the mod, they disappear from the world; reinstall it and they come back.
- Left click also swings whatever you're holding, so put your tool or weapon away while placing.
- Esc also opens the game's pause menu. Use N or right click to close or stop.
- Don't update the mod while the game is running.
