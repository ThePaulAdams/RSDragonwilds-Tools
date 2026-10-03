# OSRS Minimap Mod for RuneScape: Dragonwilds

**OSRSMinimap** transforms the HUD minimap into an authentic, ornate Old School RuneScape style minimap with dual-ring gold borders, live Day/Night sundial clock integration, monster radar, and high-value resource tracking.

---

## Features

1. **Ornate RuneScape Dual-Ring Gold Frame:**
   - Vector-rendered dual-ring border with antique bronze outer bevel, brilliant RuneScape gold stroke, and inner highlight.
   - Adapts dynamically to any screen resolution and DPI scaling.

2. **Circular Compass & Rectangular Tablet Modes:**
   - Toggle instantly between classic circular compass mode and framed tablet mode with `F8`.

3. **Integrated Live Day/Night Sundial Clock:**
   - Overlays the game's official Day/Night sundial clock directly onto the top-left bezel of the minimap, ticking in real time with the sun and moon.

4. **OSRS Compass Heading & North Marker:**
   - Crisp red North indicator ("N") at the 12 o'clock position.
   - The white player arrow points in the character's facing direction, and the camera frustum cone sweeps smoothly with mouse view.

5. **Classic RuneScape AI & Monster Radar Dots:**
   - 🔴 **Red dots:** Hostile monsters and aggressive threats nearby.
   - 🟡 **Yellow dots:** Neutral NPCs, villagers, and peaceful wildlife (sheep, cows, deer, rabbits).

6. **High-Value Resource Pin Tracking:**
   - Dynamically tracks high-value resources on both the minimap and fullscreen map with custom RS icons:
     - **Trees:** Oak, Willow, Maple, Yew
     - **Mining Rocks:** Coal, Clay, Blurite, Adamant, Mithril, Runite, Rune Essence
     - **Elemental Anima Vents:** Fire, Water, Earth, Air, Nature, Astral
     - **Fishing Spots:** Catchable fish and fishing nodes

7. **Zero Official Map Interference:**
   - Completely independent from the native fullscreen World Map (`M`). Opening the world map gracefully hides the minimap without causing missing panels or broken zoom clamps.

8. **Extreme Performance Optimization:**
   - Dynamic distance-based culling prevents lag spikes.
   - Active map widgets are culled from 6,000+ down to ~150–220, maintaining locked 60+ FPS.

---

## Controls & Keybinds

- `F6`: Toggle minimap visibility on / off.
- `F7`: Force reload / reinitialize minimap.
- `F8`: Toggle shape (Circular Compass Mode <-> Rectangular Tablet Mode).
- `F9`: Toggle Resource Icons & AI Radar Dots on / off.
- `PageUp` / `+`: Zoom in.
- `PageDown` / `-`: Zoom out.
- `[` / `]`: Scale minimap size smaller / larger.

---

## Installation

### Method 1: Using the Suite Deployer Script
```powershell
.\deploy.ps1 -Tool OSRSMinimap
```

### Method 2: Manual Installation
1. Copy `OSRSMinimap` to:
   ```
   <GameRoot>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\OSRSMinimap
   ```
2. Enable in `mods.txt`:
   ```ini
   OSRSMinimap : 1
   ```
