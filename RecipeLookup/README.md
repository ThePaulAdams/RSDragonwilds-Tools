# RecipeLookup

Lists recipes and shows which ones you can craft right now.

## Controls
| Action | Keybind |
| :--- | :--- |
| Show the list, or the next page | `[Alt + F12]` |
| Close | `[Esc]` |

## Details
- With a crafting station open, it lists that station's recipes; otherwise it lists every recipe.
- Ingredients are counted from your backpack plus chests within 12m, the game's own craft-from-chest range. Craftable recipes are listed first as `[READY]`.
- Recipe data is read from the game's `RecipeData` assets (`ItemsConsumed` / `ItemsCreated`, each an `ItemData` + `Count`). At an open station the list is that station's own recipe list (`ProcessingStationComponent.RecipesCache` or `CraftingStationComponent.ValidRecipes`).

## Status
Untested in game since the rewrite. The first version scanned every loaded object and crashed the game; that scan is gone. It used Ctrl+J, which is also the UE4SS object-dump key and the game's journal, hence Alt+F12 (numpad keys were tried and dropped because AutoRun toggles Num Lock).
