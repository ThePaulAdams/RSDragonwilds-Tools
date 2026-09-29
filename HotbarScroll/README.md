# HotbarScroll

The mouse wheel cycles your hotbar slots. It does nothing while a menu or the mouse cursor is up.

## Settings
- `Invert`: flip the scroll direction.
- `Wrap`: go from the last slot back to the first.

## Status
Untested in game. The wheel is read with the engine's `WasInputKeyJustPressed`. The game has no "selected slot" value: the hotbar is the first `NumberOfQuickActionSlots` backpack slots and the number keys *use* the item in a slot. So scrolling calls the hotbar widget's `UseItemInSlot(i)` (falling back to `InventoryController:UseItemFromInventory`), works out the current slot from the item in your right hand, and skips empty slots. If no call works, scrolling switches off and a `[DISCOVERY]` line lists the hotbar members.
