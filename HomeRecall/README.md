# HomeRecall

Teleports you home after a short channel, like a home teleport spell.

## Controls
| Action | Keybind |
| :--- | :--- |
| Recall home (3 second channel, moving cancels) | `[Ctrl + F7]` |
| Save the spot you're standing on as home | `[Alt + F7]` |

## Details
- Home is saved to `HomeRecall/scripts/home.txt`, so it survives restarts. There is one home per install, not per save.
- With no saved home, it looks for your bed (bed/bedroll base-building actors).
- 60 second cooldown by default (`CooldownSeconds`).
- Uses the engine's `K2_TeleportTo`. In co-op this works for the host; a client teleport may be corrected by the server.

## Status
Untested in game. The bed fallback uses the game's bedroll class (`BP_BaseBuilding_BedRoll_C` in the object dump); saving a home with `Alt+F7` is still the most reliable path.
