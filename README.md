# RS-Dragonwilds Tools

A suite of modding tools and HUD replacements for RS-Dragonwilds.

## OSRS Minimap Mod
This mod replaces the native HUD minimap with an Old School RuneScape style minimap. 

### Core Features & Spec
1. **OSRS Compass Style:** The map texture translates and rotates around the player. The player is always locked to the center, and the player icon always points UP (Rotation 0.0), acting as a true compass.
2. **Square Masking:** The minimap is shaped in a classic square instead of a circle.
3. **No Main Map Interference:** The minimap operates completely independently of the Main Map (M). Opening the main map will hide the minimap, and the main map will function normally without any stolen widgets or broken zoom limits.
4. **Delayed Loading:** The minimap waits until the player spawns into the world before attempting to load or track locations, preventing startup crashes.
5. **Local Resource Tracking (Planned):** Will display pins for nearby harvestable resources.

### The Mathematics & Architecture (CRITICAL DEVELOPER NOTES)

To avoid breaking the Main Map or losing tracking accuracy, the following architectural rules **MUST** be adhered to:

#### 1. The MapTrackerComp Stealing Bug
The native widget WBP_DominionMinimap_C utilizes a component called MapTrackerComp which pools the background map images. If you call MinimapWidget:InitFillBackground() while the tracker is attached, it will physically steal the image widgets from the Main Map, leaving the Main Map blank.
**The Fix:** We swap the backgrounds back and forth! When the user opens the Main Map, we call Official:InitFillBackground() to return the images to the Official map. When they close it, we call MinimapWidget:InitFillBackground() to pull them back to the minimap.

#### 2. The MapViewComponent & GPS Math
Never manually calculate PlayerU and PlayerV using static World Bounds. The world bounds might change or be inaccurate, resulting in the player appearing to stand in the water.
Furthermore, never call MinimapWidget:AutoFindMapView() on our standalone minimap, as it will steal the native MapViewComponent from the Official map, breaking its zoom limits.
**The Fix:** The Official Map natively calculates flawless GPS translation into a property called MapOffset. We simply read Official.MapOffset continuously in our tick loop, scale it by our Minimap Zoom Factor (e.g., 8.0x), and apply it directly to MinimapWidget.Canvas_Backgrounds:SetRenderTranslation.

#### 3. Forcing Background Tracking
Because we rely on the Official Map's MapOffset, we must force the Official Map to continue tracking the player even when it is closed.
**The Fix:** Inside the tick loop, whenever the Official Map is hidden (closed), we set Official.AutoLocateMapView = 2 (Always Follow Player). This ensures the GPS coordinates continue to update flawlessly in the background for our minimap to read.

### Keybinds
- **F6:** Toggle Minimap On/Off
- **F7:** Force Reload Minimap Widget
- **PageUp / PageDown:** Adjust Zoom Level
- **[ / ]:** Adjust Minimap Canvas Scale
