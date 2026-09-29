# BulkOpen

Opens every bag and pack in your backpack (Goblin Packs and similar) with one key press.

## Controls
| Action | Keybind |
| :--- | :--- |
| Open every bag, one after another | `[Ctrl + O]` |
| Stop early | `[Ctrl + O]` again |

## How it works
- Finds items whose asset path contains `item_pack` / `item_bag`, or whose name ends in "pack", "bag", "sack" or "pouch". Backpacks, rune pouches, seeds, tea bags and quivers are never opened.
- Opens one bag every 250ms using the game's own "use item" call. It tries a short list of likely functions and keeps the first one that actually shrinks the pack stack.
- If none of them work, it logs a `[DISCOVERY]` line listing the real use/open functions on your inventory, so the right one can be added.

## Status
Untested in game. The bag detection is solid; which "use item" function the game accepts is the part to confirm on first run (check `UE4SS.log` for `Using ...` or `[DISCOVERY]`).
