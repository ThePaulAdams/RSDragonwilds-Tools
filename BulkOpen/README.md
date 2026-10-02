# BulkOpen

Opens every bag and pack in your backpack (Goblin Packs and similar) with one key press.

## Controls
| Action | Keybind |
| :--- | :--- |
| Open every bag, one after another | `[Ctrl + F9]` |
| Stop early | `[Ctrl + F9]` again |

## How it works
- Finds packs by their data class, `BP_Consumables_ItemEmitter_C` (Goblin Pack, Garou Pack, Zamorak Warrior Pack, plan packs...), or a display name ending in "pack", "bag", "sack" or "pouch". Backpacks, rune pouches, seeds, tea bags and quivers are never opened.
- Opens one bag every 250ms with the game's own `InventoryController:UseItemFromInventory(Inventory, SlotIndex)` (the same call the inventory's Use button makes), falling back to the item's `UseItem(PlayerController, Inventory, SlotIndex)`.
- If neither shrinks the pack stack, it logs a `[DISCOVERY]` line listing the use/open functions on your inventory.

## Status
Untested in game. The use-item call is taken from the game's object dump; confirm on first run (`UE4SS.log` shows `Using ...`). F7/F9/F12 chords are used because the game ignores modifiers (a Ctrl+letter chord also triggers the game's own letter binding, and Ctrl+O is the UE4SS debug window). Numpad keys were tried and dropped: AutoRun toggles Num Lock, which turns numpad digits into End/arrow keys every other press.
