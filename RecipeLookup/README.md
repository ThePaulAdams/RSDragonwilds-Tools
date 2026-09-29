# RecipeLookup

Lists recipes and shows which ones you can craft right now.

## Controls
| Action | Keybind |
| :--- | :--- |
| Show the list, or the next page | `[Ctrl + J]` |
| Close | `[Esc]` |

## Details
- With a crafting station open, it lists that station's recipes; otherwise it lists every recipe.
- Ingredients are counted from your backpack plus chests within 12m, the game's own craft-from-chest range. Craftable recipes are listed first as `[READY]`.
- Recipe data is found by scanning loaded objects whose class name contains "recipe" (first use takes a moment), then reading their ingredient and output fields by name.

## Status
Untested in game and the most experimental mod here. If it says "Recipe data not found", or the list looks wrong, run ToolkitProbe (`Ctrl+F12`) at a station and send the `[DISCOVERY]` lines and probe file.
