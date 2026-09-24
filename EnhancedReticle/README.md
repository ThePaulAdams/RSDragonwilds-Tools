# EnhancedReticle - High-Visibility Reticle & Cast Cursor

A modular HUD enhancement tool for ***RuneScape: Dragonwilds*** that transforms the faint, semi-transparent vanilla white dot reticle into a prominent, high-contrast, fully customizable crosshair and spell-cast cursor.

---

## The Problem
In vanilla *Dragonwilds*, the central crosshair and spell targeting cursor (`ReticleAimedUtilityMagic` / `ReticleDefault`) rely on `T_HUD_Reticle_Point`: a tiny, semi-transparent white dot. Against bright skies, snow, deserts, water, and bright spell animations, the dot easily washes out and disappears, making accurate spell casting and ranged aiming frustrating.

## The Solution
**EnhancedReticle** hooks directly into the game's native UMG reticle hierarchy (`WBP_HUD_ReticleWidget_C`), providing:
1. **High-Visibility Color Profiles:** Instant cycling between luminous, esports-grade high-contrast colors (Neon Green, OSRS Gold, Cyan, Crimson, Hot Pink, Amber, and Pure White).
2. **Dynamic Size Scaling:** Seamlessly scale the reticle up to 1.5x, 2.0x, 2.5x, or 3.2x with centered pivot alignment (preserving pixel-perfect aiming accuracy).
3. **100% Opacity Boost:** Eliminates the washed-out semi-transparency of the vanilla dot so it stays crisp against all backdrops.
4. **Universal State Support:** Automatically enhances:
   - Roaming 3rd-person dot (`ReticleDefault`)
   - Utility magic cast cursor (`ReticleAimedUtilityMagic`)
   - Combat magic aiming reticle (`ReticleMagic`)
   - Bow & crossbow aiming reticle (`ReticleRangedADS`)
   - Stealth / sneak mode reticle (`ReticleStealth`)
   - Building repair reticle (`ReticleRepair`)
5. **Native UI State Awareness:** Unlike third-party screen overlays, EnhancedReticle automatically hides when you open your map, inventory, menus, or enter cutscenes.
6. **Travel & Respawn Persistence:** A lightweight background heartbeat automatically re-applies your preferred styling whenever the HUD is re-instantiated after fast-travel, death, or dungeon transitions.

---

## Controls & Keybinds

| Key | Action | Description |
| :--- | :--- | :--- |
| **`F4`** | **Toggle Enhancement** | Switch between Enhanced Reticle and Vanilla Default |
| **`F11`** | **Cycle Color** | Cycle through high-contrast colors (Neon Green -> OSRS Gold -> Cyan -> Crimson -> Hot Pink -> Amber -> White) |
| **`F12`** | **Cycle Size** | Cycle reticle size (1.0x -> 1.5x -> 2.0x -> 2.5x -> 3.2x) |

---

## Color Profiles

1. **Neon Green (Default):** Maximum visibility against dark caves, night skies, and foliage.
2. **OSRS Gold:** Iconic classic RuneScape gold/yellow with strong contrast on grass and stone.
3. **Cyan / Sky Blue:** High-luminance blue that cuts sharply through dark dungeons and sand.
4. **Crimson Red:** High-contrast tactical combat reticle.
5. **Hot Pink / Magenta:** Distinctive visual pop in all lighting conditions.
6. **Amber Orange:** Warm, distinct color for visibility in snowy or foggy biomes.
7. **Pure White:** Fully opaque, bright white with centered scaling.

---

## Installation & Deployment

Deploy directly using the project deployment script:
```powershell
.\deploy.ps1 -Tool EnhancedReticle
```
Or deploy all tools:
```powershell
.\deploy.ps1 -Tool All
```

### Manual Installation
1. Copy the `EnhancedReticle` folder into your UE4SS mods directory:
   ```text
   <GameRoot>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\EnhancedReticle\
   ```
2. Enable it in `Mods\mods.txt`:
   ```text
   EnhancedReticle : 1
   ```

---

## Configuration

Default settings can be adjusted in `EnhancedReticle/scripts/main.lua`:
```lua
local Config = {
    Enabled = true,
    CurrentColorIndex = 1, -- 1: Neon Green, 2: OSRS Gold, 3: Cyan, ...
    CurrentSizeIndex = 3,  -- 1: 1.0x, 2: 1.5x, 3: 2.0x, 4: 2.5x, 5: 3.2x
}
```
