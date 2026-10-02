# ToolkitProbe

A developer helper, not a gameplay mod. `Ctrl+F12` writes `ToolkitProbe/scripts/probe_<time>.txt` with:
- the functions and properties of the open crafting station and its inventory, your inventory, inventory controller, pawn and any hovered item
- optionally (`ClassHistogram = true` in the script) a count of loaded classes whose names mention recipes, crafting, stations, queues, raids, beds, respawn, hotbar or health. Off by default: it walks every loaded object, which can crash the game.

Open a crafting station first for the most useful output. Send the file to the toolkit author to finish features that depend on game-internal names: the over-crafting fix for stations, and confirming BulkOpen, HotbarScroll and RecipeLookup.

Leave it disabled in `mods.txt` when you don't need it.
