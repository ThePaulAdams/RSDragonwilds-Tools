# RSDragonwilds-Tools
Modding scripts and tools for RS-Dragonwilds via UE4SS.

## OSRS Minimap Mod
Transforms the default HUD into an Old School RuneScape style interface.

### Project Goals & Features
We are aiming to create a highly functional, immersive minimap experience:

- **Square Minimap Design:** A square minimap that fits cleanly on the screen.
- **Resource Tracking:** (Planned) Display custom pins/icons for resource locations directly on the minimap.
- **Dynamic Tracking:** The minimap accurately shows your local area, remaining perfectly centered on the player.
- **Player-Centric Rotation:** The map texture translates and rotates underneath the player in real-time as your character turns, keeping the player icon pointing straight up (just like the OSRS compass).
- **Safe Initialization:** The minimap waits and only loads safely once you have fully spawned into a game, preventing crashes during loading screens.
- **Strict Main Map Protection:** We must **never** change or steal from the native Main Map component, as it already functions exactly as desired. The minimap operates completely independently to preserve the main map's integrity.
