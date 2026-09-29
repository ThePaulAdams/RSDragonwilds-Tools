# HotbarScroll

The mouse wheel cycles your hotbar slots. It does nothing while a menu or the mouse cursor is up.

## Settings
- `Invert`: flip the scroll direction.
- `Wrap`: go from the last slot back to the first.

## Status
Untested in game. The wheel is read with the engine's `WasInputKeyJustPressed`. The function that selects a hotbar slot is picked from a list of likely names on first scroll. If none work, scrolling switches itself off and a `[DISCOVERY]` line in `UE4SS.log` lists the real hotbar functions.
