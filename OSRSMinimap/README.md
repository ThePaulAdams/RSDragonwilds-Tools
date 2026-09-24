# OSRS Minimap Mod for RuneScape: Dragonwilds

**OSRSMinimap** transforms the native *Dragonwilds* circular HUD minimap into an authentic, responsive Old School RuneScape style square minimap.

---

## Features

1. **OSRS Compass Heading & World Rotation:**
   - The map rotates and shifts smoothly beneath the player while the player icon remains locked to the center and points straight UP ($0.0^\circ$).
2. **Zero Official Map Interference:**
   - Completely independent from the native fullscreen World Map (`M`). Opening the world map gracefully hides the minimap without causing missing panels, orphaned widgets, or broken zoom clamps.
3. **High-Value Resource Pin Tracking:**
   - Dynamically tracks high-value resources on both the minimap and fullscreen map:
     - **Trees:** Oak, Willow, Maple, Yew
     - **Mining Rocks:** Coal, Clay, Blurite, Adamant, Mithril, Runite, Rune Essence
     - **Elemental Anima Vents:** Fire, Water, Earth, Air, Nature, Astral
     - **Fishing Spots:** Catchable fish and fishing nodes
4. **Extreme Performance Optimization:**
   - Dynamic distance-based culling prevents lag spikes.
   - Active map widgets are culled from 6,000+ down to ~150–220, maintaining locked 60+ FPS.

---

## Keybinds

- `F6`: Toggle minimap visibility on / off.
- `F7`: Force reload / reinitialize minimap.

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
