# RuneScape: Dragonwilds - Community Tools & Quality of Life Suite

[![RSDragonwilds](https://img.shields.io/badge/Game-RuneScape%3A%20Dragonwilds-gold?style=for-the-badge)](https://store.steampowered.com)
[![Platform](https://img.shields.io/badge/Platform-PC%20%7C%20Steam-blue?style=for-the-badge)](https://store.steampowered.com)
[![Framework](https://img.shields.io/badge/Framework-UE4SS%20v3.0%2B-green?style=for-the-badge)](https://github.com/UE4SS-RE/RE-UE4SS)
[![Status](https://img.shields.io/badge/Status-Fully%20Stable-brightgreen?style=for-the-badge)]()

A modular, crash-safe suite of essential quality-of-life improvements, navigation tools, aiming enhancements, and in-game controls for **RuneScape: Dragonwilds**.

Each mod is completely standalone and can be enabled, disabled, or shared individually, or installed together as an all-in-one quality-of-life mod pack.

---

## Included Mods

| Tool | Category | Hotkeys | Description |
| :--- | :--- | :--- | :--- |
| [**OSRSMinimap**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/OSRSMinimap/README.md) | HUD & Navigation | `[F6]`, `[F9]` | Classic Old School RuneScape minimap with rotating player compass, camera frustum, and real-time resource tracking (ores, trees, essence, fishing). |
| [**QuickStack**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/QuickStack/README.md) | Quality of Life | `[G]`, `[Ctrl+G]`, `[Shift+G]` | Smart base inventory sorting into dedicated category chests, 48-slot chest auto-upgrades, 40m wild resource gathering & ground vacuum, and 150m Base Relocation Crate. |
| [**EnhancedReticle**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/EnhancedReticle/README.md) | Aiming & HUD | `[F4]`, `[F1]`, `[F2]` | High-contrast, scalable crosshair with 7 vibrant colors and 5 dynamic sizes across roaming, spellcasting, bows, and stealth. |
| [**TelekineticWoodcraft**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/TelekineticWoodcraft/README.md) | Gathering & Magic | `[E]`/`[V]`, `[Z]`, `[F6]` | Telekinetic log physics: pick up and carry logs (`E`/`V`), vacuum nearby logs into a tight flat woodpile (`Z` Log Magnet), and scale Splinter spell radius (`F6`). |
| [**ModMenu**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/ModMenu/README.md) | Dashboard & UI | `[F8]`, `[ESC]` Pause | In-game mod status overlay and hotkey reference card. Displays automatically on the ESC Pause screen or toggle anytime via `[F8]`. |
| [**AutoRun**](file:///C:/Users/admin/Documents/antigravity/RSDragonwilds-Tools/AutoRun/README.md) | Quality of Life | `[Num Lock]` | Camera-oriented continuous autorun with seamless natural input cancellation (WASD, menus, jumping). |

---

## Master Controls Cheat-Sheet

| Keybind | Tool | Action |
| :--- | :--- | :--- |
| **`[ESC]`** | **Pause Menu** | Pausing automatically displays the active Toolkit Mod Dashboard |
| **`[F8]`** | **Toolkit Mod Menu** | Open / close the in-game mod dashboard overlay anytime |
| **`[Num Lock]`** | **AutoRun** | Toggle continuous camera-forward autorun on / off |
| **`[G]` (Tap)** | **Quick Stack** | **At Base:** Auto-sort items into dedicated category chests & upgrade to 48 slots<br>**In Wild:** Instant harvest & ground magnetism for nearby plants/loot |
| **`[G]` (Hold)** | **Quick Stack** | **Continuous Vacuum:** Harvest and pull all wild flora & ground items within 40m<br>**Hovering Item:** Quick-pull all matching stacks from nearby chests |
| **`[Ctrl + G]`** | **Quick Stack** | **Pack Base:** Vacuum all ground items within 150m into virtual Relocation Crate |
| **`[Shift + G]`** | **Quick Stack** | **Unpack Base:** Deposit all Relocation Crate items categorized into nearby chests |
| **`[F6]`** | **OSRS Minimap** | Toggle OSRS minimap display on / off |
| **`[F9]`** | **OSRS Minimap** | Toggle live resource tracking icons on / off |
| **`[F4]`** | **Enhanced Reticle** | Toggle high-visibility crosshair on / off |
| **`[F1]`** | **Enhanced Reticle** | Cycle reticle color (Neon Green, Gold, Cyan, Red, Pink, Orange, White) |
| **`[F2]`** | **Enhanced Reticle** | Cycle reticle size (1.0x, 1.5x, 2.0x, 2.5x, 3.2x) |
| **`[E]`** or **`[V]`** | **Telekinetic Woodcraft** | Telekinetically grab, carry, or drop targeted log / trunk |
| **`[Z]`** | **Telekinetic Woodcraft** | [Log Magnet] Mass-gather all logs within 150m into a neat pile |
| **`[F6]`** | **Telekinetic Woodcraft** | Cycle Splinter spell AoE radius multiplier (1x, 2.5x, 5.0x) |
| **`[Ctrl + R]`** | **UE4SS Engine** | Live hot-reload all Lua mods without restarting the game |

---

## Installation Guide

### Prerequisites: UE4SS Setup

This mod suite runs via **UE4SS** (Unreal Engine 4/5 Scripting System).

1. Download the latest **UE4SS** release (`UE4SS_vX.X.X.zip`) from [UE4SS GitHub Releases](https://github.com/UE4SS-RE/RE-UE4SS/releases).
2. Locate your game installation directory:
   ```
   Steam/steamapps/common/RSDragonwilds/RSDragonwilds/Binaries/Win64/
   ```
3. Extract the contents of the UE4SS zip file so that `dwmapi.dll` and the `ue4ss/` folder sit alongside `RSDragonwilds-Win64-Shipping.exe`.

---

### Option A: Automated PowerShell Deployment (Recommended)

If you cloned or downloaded this repository:

1. Open PowerShell in the `RSDragonwilds-Tools` root folder.
2. Run the deployment script:
   ```powershell
   # Deploy all tools automatically
   .\deploy.ps1
   ```
3. To deploy a specific tool only:
   ```powershell
   .\deploy.ps1 -Tool QuickStack
   .\deploy.ps1 -Tool OSRSMinimap
   .\deploy.ps1 -Tool EnhancedReticle
   .\deploy.ps1 -Tool TelekineticWoodcraft
   .\deploy.ps1 -Tool ModMenu
   .\deploy.ps1 -Tool AutoRun
   ```
4. The script copies files to your game directory and automatically updates `mods.txt`.

---

### Option B: Manual Installation

1. Copy the desired mod folders (`OSRSMinimap`, `QuickStack`, `EnhancedReticle`, `TelekineticWoodcraft`, `ModMenu`, `AutoRun`) into:
   ```
   <GameRoot>/RSDragonwilds/Binaries/Win64/ue4ss/Mods/
   ```
2. Open `<GameRoot>/RSDragonwilds/Binaries/Win64/ue4ss/Mods/mods.txt` in a text editor.
3. Ensure each mod you want to run has `: 1` appended:
   ```ini
   OSRSMinimap : 1
   QuickStack : 1
   EnhancedReticle : 1
   TelekineticWoodcraft : 1
   ModMenu : 1
   AutoRun : 1
   ```
4. Launch the game through Steam normally!

---

## Mod Highlights & Features

### 1. Toolkit Mod Menu (`ModMenu`)
- **Pause Menu Integration**: Injects a custom **"TOOLKIT MODS"** button into the native ESC Game Paused screen.
- **In-Game Overlay (`F7`)**: Instantly shows an Old School RuneScape style Slate card with live status badges (`[ON]` / `[OFF]`) and keybind reminders.
- **Real-Time Detection**: Automatically re-scans `mods.txt` whenever toggled, immediately showing changes without restarting.
- **Zero Performance Impact**: Widget remains collapsed and uses 0 CPU cycles during normal gameplay.

### 2. QuickStack (`QuickStack`)
- **In-Memory Category Consolidation**: Pulls items from nearby chests into an in-memory buffer, merges duplicate/split stacks, and redistributes them strictly into dedicated category chests (**FOOD**, **WOOD**, **MINING**, **FARMING**, **EQUIPMENT**, **MAGIC**, **MISC**).
- **48-Slot Highest Tier Upgrade**: Dynamically upgrades all detected chests and crates to 48 slots (`MaxSlotCount = 48`) with high-tier static meshes in-place.
- **Wild Gathering & Ground Magnetism (`Hold G`)**: Sweeps a 40m radius while sprinting, auto-harvesting wild crops (dwellberries, onions, flax, herbs, fallen wood, stones) directly into your backpack.
- **Base Relocation Virtual Crate (`Ctrl+G` / `Shift+G`)**: Pack all ground items within 150m into a persistent virtual crate, then unpack them organized into nearby chests with one keypress.
- **Targeted QuickPull**: Hover any item in your inventory or chest and hold `G` to pull all matching stacks from all nearby chests directly into your inventory.
- **Strict Safe Guards**: Zero-tolerance blacklist prevents any crafting stations, blast furnaces, smelters, kilns, or campfires from being touched. Hotbar, combat ammunition, and runes are 100% protected.

### 3. OSRS Minimap (`OSRSMinimap`)
- **Compass Rotation**: Player icon remains locked pointing UP while the world map rotates and pans under you, matching traditional OSRS navigation.
- **Resource Pin Tracking (`F9`)**: Real-time map pins for nearby high-tier ores (Runite, Adamant, Mithril, Coal, Blurite), trees (Yew, Maple, Willow, Oak), fishing spots, and elemental anima vents.
- **Main Map Isolation**: Operates on an independent map layer—opening your full-screen World Map (`M`) is 100% unaffected.

### 4. Enhanced Reticle (`EnhancedReticle`)
- **High-Contrast Aiming**: Replaces the faint default reticle with bright, crisp crosshairs for precise spellcasting and archery.
- **7 Color Presets (`F1`)**: Neon Green, OSRS Gold, Cyan, Crimson Red, Hot Pink, Amber Orange, Pure White.
- **5 Scale Levels (`F2`)**: 1.0x (Vanilla), 1.5x, 2.0x, 2.5x, 3.2x (High-visibility).
- **Universal State Coverage**: Seamlessly adapts across combat spells, utility magic, bow ADS, and stealth.

### 5. Telekinetic Woodcraft (`TelekineticWoodcraft`)
- **Single Log Drag (`E` or `V`)**: Aim at any felled tree or cut log to telekinetically carry it in front of you. Press again to settle it flat on the ground.
- **Log Magnet Mass Gathering (`Z`)**: Pulls all logs within 150 meters into a compact, flat pyramid woodpile directly in front of you.
- **Splinter Spell Multiplier (`F6`)**: Boosts the Splinter spell explosion radius (1.0x, 2.5x, 5.0x) to harvest an entire woodpile in a single cast.

### 6. AutoRun (`AutoRun`)
- **Hands-Free Traversal (`Num Lock`)**: Continuous camera-aligned movement without needing to hold W or Shift.
- **Natural Cancellation**: Seamlessly cancels on backward input (S), manual pause, or UI interaction.

---

## Technical Architecture & Crash Safety

All mods in this suite follow strict UE5 stability guidelines:
- **Zero CDO Touching**: Filters out Class Default Objects (`RF_ClassDefaultObject`) and Archetypes to prevent memory corruption.
- **Game Thread Dispatch**: UMG and Slate operations are strictly dispatched to the engine's main game thread.
- **Orphan Widget Pruning**: Persistent name-tracking cleans up orphaned widgets across reloads without leaving stale pointers in memory.
- **Defensive UObject Guards**: All native engine calls are guarded by `IsValid()`, null address checks, and Lua `pcall` wrappers.

---

## Frequently Asked Questions (FAQ)

<details>
<summary><b>How do I disable a specific mod?</b></summary>
Open <code>ue4ss/Mods/mods.txt</code>, locate the mod name, and change <code>: 1</code> to <code>: 0</code>. In-game, press <code>Ctrl + R</code> to apply the change immediately.
</details>

<details>
<summary><b>Do these mods work in multiplayer / co-op?</b></summary>
Yes. All mods in this suite operate as client-side quality-of-life enhancements and work smoothly in single-player and co-op worlds.
</details>

<details>
<summary><b>Why did pressing F10 open a console?</b></summary>
UE4SS reserves <code>F10</code> by default for the built-in developer console (ConsoleEnablerMod). The Toolkit Mod Menu uses <b><code>[F7]</code></b> and the ESC <b>Pause Menu</b> button to prevent any keybind conflicts.
</details>

---

## License

This project is released under the **MIT License**. Free to use, modify, and distribute for the *RuneScape: Dragonwilds* community.
