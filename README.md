# RS-Dragonwilds Tools Suite

A modular suite of modding tools, quality-of-life improvements, and HUD replacements for *RuneScape: Dragonwilds*.

Each tool in this repository is designed as an independent, self-contained module that can be installed, configured, and shared individually or used together as a complete suite.

---

## Tools in this Repository

| Tool | Category | Status | Description |
| :--- | :--- | :--- | :--- |
| [**OSRSMinimap**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/OSRSMinimap/README.md) | HUD & Navigation | Stable | Old School RuneScape style square HUD minimap featuring player-centered compass rotation, high-value resource pin tracking, and dynamic proximity culling. |
| [**QuickStack**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/QuickStack/README.md) | Quality of Life | Stable | One-key (`G`) smart quick-stacking to nearby chests and storage containers with hotbar protection, audio feedback, and type matching. |
| [**EnhancedReticle**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/EnhancedReticle/README.md) | HUD & Aiming | Stable | High-visibility reticle and cast cursor enhancement with customizable high-contrast colors, dynamic scaling (1.0x to 3.2x), and universal state support. |

---

## Quick Deployment

You can deploy tools directly to your game installation with the included PowerShell deployer:

```powershell
# Deploy all tools
.\deploy.ps1

# Or deploy an individual tool
.\deploy.ps1 -Tool QuickStack
.\deploy.ps1 -Tool OSRSMinimap
```

---

## 1. QuickStack Mod

### Overview
Pressing `G` scans all storage containers within radius (default: 25m) and deposits matching items from your inventory into nearby chests in milliseconds.

### Core Principles
1. **Smart Matching:** Only deposits items into chests that **already hold** at least one stack of that item type.
2. **Hotbar Safe:** The player's active quick-action hotbar (weapons, tools, food) is never touched.
3. **Sound & Toast Feedback:** Plays native chest audio and shows an itemized deposit summary.

Detailed configuration and usage: [QuickStack README](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/QuickStack/README.md).

---

## 2. OSRS Minimap Mod

Replaces the native HUD minimap with an Old School RuneScape style minimap.

### Core Features & Spec
1. **OSRS Compass Style:** The map texture translates and rotates underneath the player. The player is always locked to the center, and the player icon always points UP (Rotation 0.0), acting as a true compass.
2. **Square Masking:** The minimap is shaped in a classic square instead of a circle.
3. **No Main Map Interference:** The minimap operates completely independently of the Main Map (`M`). Opening the main map hides the minimap, and the main map functions normally without any missing panels, broken widgets, or destroyed zoom limits.
4. **Delayed Loading:** The minimap waits until the player spawns into the world before attempting to load or track locations, preventing startup crashes.
5. **Local Resource Tracking:** Dynamically tracks high-value resources: Oak, Willow, Maple, Yew, Coal, Clay, Blurite, Adamant, Mithril, Runite, Rune Essence, Anima Vents, and Fishing spots.

---

## 3. EnhancedReticle Mod

Transforms the faint vanilla white dot reticle into a prominent, high-contrast, scalable crosshair and spell-casting cursor.

1. **Toggle On/Off:** Instant toggle (`F4`) between Enhanced Reticle and Vanilla Default.
2. **High-Contrast Colors:** Instant keybind cycling (`F1`) through 7 luminous colors: Neon Green, OSRS Gold, Cyan, Crimson Red, Hot Pink, Amber Orange, and Pure White.
3. **Centered Dynamic Scaling:** Instant keybind cycling (`F2`) through 5 size profiles (1.0x, 1.5x, 2.0x, 2.5x, 3.2x) with centered pivot alignment for pixel-perfect targeting accuracy.
4. **100% Opacity Boost:** Eliminates the semi-transparent washed-out look of the vanilla dot so it stays clear against all bright backgrounds (skies, snow, sand, spells).
5. **Universal State Coverage:** Automatically styles roaming crosshairs (`ReticleDefault`), utility magic aiming cursors (`ReticleAimedUtilityMagic`), combat spell reticles (`ReticleMagic`), bow aiming (`ReticleRangedADS`), stealth mode (`ReticleStealth`), and repair tools (`ReticleRepair`).
6. **Native UI State Respect:** Disappears automatically during menus, inventory, map, and dialogue.
7. **Respawn & World Persistence:** Spawning hooks ensure custom reticle styling persists seamlessly across fast travel, level changes, and deaths.

Detailed configuration and usage: [EnhancedReticle README](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/EnhancedReticle/README.md).

---

### The Mathematics & Architecture (CRITICAL DEVELOPER NOTES)

#### 1. Why the Main Map Went Missing (The "Orphan Cleanup" Pitfall)
The native Main Map UI is `WBP_TopNav_Map_C` (named `MapPanel` in the In-Game TopNav menu). Its inner map viewer is an instance of `WBP_DominionMinimap_C` owned directly by `BP_DominionGameInstance_C`.
- **The Historical Bug:** A previous cleanup routine searched `FindAllOf("WBP_DominionMinimap_C")` and removed any widget whose full name did not contain `"MapPanel"`. Because the native map instance is owned by `BP_DominionGameInstance_C` (and does NOT contain `"MapPanel"` in its object path), the cleanup script literally detached the Official Map from its Canvas and collapsed it (`Visibility = 2`) on every reload!
- **The True Fix:** 
  1. Never detach or collapse `BP_DominionGameInstance_C` minimap instances.
  2. Mod minimap widgets are owned by `BP_PlayerController_C`. The cleanup routine only cleans up orphaned `BP_PlayerController_C` instances.
  3. The mod actively re-anchors `topNav.Map` into `topNav.WidgetTree.CanvasPanel_0` if it is ever missing, guaranteeing the Main Map is always 100% functional.

#### 2. Native Background Populating (No Stealing Required)
- `WBP_DominionMinimap_C:InitFillBackground()` does not generate new backgrounds for secondary widgets.
- Calling `Widget:AddMapBackground(bg)` for each `bg` in `MapTrackerComponent.MapBackgrounds` creates brand new, independent `WBP_Dominion_MinimapInternal_Background_C` widgets inside `Canvas_Backgrounds` using native `CreateWidget` calls. This completely eliminates background "stealing" and allows both the Main Map and the HUD Minimap to own their own background layers simultaneously.

#### 3. GPS Coordinate Projection Math (`GetViewCoordinates`)
- Do not use `Official.MapOffset`. In this engine plugin, `MapOffset` is an internal mouse-drag pan accumulator; while the map is closed, `MapOffset` is permanently `(0.0, 0.0)`.
- Do not use hardcoded bounding box math, which easily results in inaccurate projections (e.g. appearing to stand in water).
- **The Engine-Native Solution:** The plugin C++ class `MapViewComponent` provides:
  ```lua
  local out = {}
  AreaMapView:GetViewCoordinates(PawnLocation, false, out, {})
  local u = out.U  -- Normalized horizontal coordinate [0.0, 1.0] (West to East)
  local v = out.V  -- Normalized vertical coordinate   [0.0, 1.0] (North to South)
  ```
  This is the exact mathematical projection function written into the game's C++ code, guaranteeing 100% pinpoint accuracy anywhere in the world.

#### 4. OSRS Compass Transformation Math
To make the map rotate around the player while keeping the player centered and pointing straight UP:
1. **Pivot Point:** We set the `RenderTransformPivot` of `Canvas_Backgrounds` and the icon layers directly to the player's normalized coordinates:
   $$\text{Pivot} = (u,\ v)$$
   Because the affine transform pivot is on the player, scaling and rotation occur strictly around the player.
2. **Translation:** Since the player coordinate is at $(u \times W,\ v \times H)$ on the map canvas, shifting the player to the center $(W/2,\ H/2)$ of the minimap window requires a translation of:
   $$\text{Translation.X} = (0.5 - u) \times W$$
   $$\text{Translation.Y} = (0.5 - v) \times H$$
3. **Rotation:** Set the canvas angle to $-\text{PlayerYaw}$ to counteract player heading.
4. **Player Icon:** Lock `Widget_Camera` rotation to $0.0^\circ$ and translation to $(0, 0)$.

#### 5. Main Map Aspect Ratio & Fog of War Alignment Mathematics
- **The Visual Disconnect:** When pressing 'M', players previously observed that the Fog of War appeared positioned in a crisp square, but the terrain landmass underneath it was stretched horizontally into a wide oval.
- **The Mathematical Cause:**
  - **World Bounds (`BP_MapBackground_C`):** Extent $X = 210,000$, Extent $Y = 210,000$. Total area = $420,000 \times 420,000$ Unreal units. The world aspect ratio is strictly $1:1$ (a perfect square).
  - **Fog of War:** The game's Fog of War projection natively renders as a $1:1$ square matching this $420,000 \times 420,000$ bounding box. On a widescreen monitor (e.g. $2580 \times 1080$), the fog covers an un-distorted $1080 \times 1080$ square centered horizontally between $X = 750$ and $X = 1830$.
  - **The Stretch Bug:** The Main Map widget (`WBP_DominionMinimap_C`) was anchored with `Anchors = (0, 0) to (1, 1)` and `Offsets = (0, 0, 0, 0)` across the full $2580 \times 1080$ viewport. This stretched the background canvas horizontally by $\frac{2580}{1080} \approx 2.388\times$ relative to its height, creating massive aspect distortion.
- **The Exact Geometric Solution:**
  1. Determine the square dimension based on the viewport:
     $$\text{mapSide} = \min(\text{ViewportWidth}, \text{ViewportHeight})$$
     On standard landscape/ultrawide displays ($W \ge H$), $\text{mapSide} = H$ (e.g. $1080.0$).
  2. Anchor `official.Slot` (`CanvasPanelSlot` inside `WBP_TopNav_Map_C`) to center horizontally while spanning full height:
     - `Anchors`: `Minimum = { X = 0.5, Y = 0.0 }`, `Maximum = { X = 0.5, Y = 1.0 }`
     - `Alignment`: `{ X = 0.5, Y = 0.0 }`
     - `Offsets`: `Left = 0.0`, `Top = 0.0`, `Right = mapSide`, `Bottom = 0.0`
     In UMG, when `Minimum.X == Maximum.X`, `Offsets.Right` sets the widget width. This constrains the widget to a precise $1080 \times 1080$ square centered from $X = \frac{W - H}{2}$ to $X = \frac{W + H}{2}$ ($750$ to $1830$).
  3. Set `official.InitialMapSize.X = official.InitialMapSize.Y` and invoke native `official:SetDesiredAspectRatio(1.0)` and `official:EnforceAspectRatio()`.
  4. With width equal to height, both the terrain texture and the Fog of War share the identical pixel-to-unit scale factor:
     $$\text{Scale}_X = \text{Scale}_Y = \frac{\text{mapSide}}{420,000} \text{ px/unit}$$
     The Main Map landmass and Fog of War now fit together in seamless, 1:1 pixel parity with zero stretching.

#### 6. Performance Architecture & Zero-Scan Rules
- **No Periodic `GUObjectArray` Scans:** Never call `FindAllOf` inside per-frame or high-frequency loops. Cache singleton pointers (`BP_DominionGameInstance_C`, `WBP_TopNav_Map_C`, `WBP_DominionMinimap_C`) and query `CachedOfficialTopNav:IsVisible()` in $O(1)$ time. Throttled fallback searches run at most once every 5 seconds.
- **Dynamic Distance Culling:** Icons beyond 35 meters are not instantiated in Slate, keeping active icon widgets under ~220 at all times.
- **Bypass RetainerBox Off-Screen Render Targets:** Calling `RetainerBox_Minimap:SetRetainRendering(false)` disables expensive GPU off-screen texture allocation and redraws on transformed layer hierarchies, relying instead on hardware GPU scissor clipping.
- **Idle Dirty Checking:** If the player location, rotation, and zoom have not changed, Slate render transforms are skipped entirely, resulting in 0% CPU consumption while stationary.
