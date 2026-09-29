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
| [**OSRSMinimap**](OSRSMinimap/README.md) | HUD & Navigation | `[F6]`, `[F9]` | Classic Old School RuneScape minimap with rotating player compass, camera frustum, and real-time resource tracking (ores, trees, essence, fishing). |
| [**QuickStack**](QuickStack/README.md) | Quality of Life | `[G]`, `[Ctrl+G]`, `[Shift+G]` | Smart base inventory sorting into dedicated category chests, 48-slot chest auto-upgrades, 40m wild resource gathering & ground vacuum, and 150m Base Relocation Crate. |
| [**EnhancedReticle**](EnhancedReticle/README.md) | Aiming & HUD | `[F4]`, `[F1]`, `[F2]` | High-contrast, scalable crosshair with 7 vibrant colors and 5 dynamic sizes across roaming, spellcasting, bows, and stealth. |
| [**TelekineticWoodcraft**](TelekineticWoodcraft/README.md) | Gathering & Magic | `[E]`/`[V]`, `[Z]`, `[Shift+F6]` | Telekinetic log physics: pick up and carry logs (`E`/`V`), vacuum nearby logs into a tight flat woodpile (`Z` Log Magnet), and scale Splinter spell radius (`Shift+F6`). |
| [**ModMenu**](ModMenu/README.md) | Dashboard & UI | `[Ctrl+F8]`, `[ESC]` Pause | In-game mod status overlay and hotkey reference card. Displays automatically on the ESC Pause screen or toggle anytime via `[Ctrl+F8]`. |
| [**AutoRun**](AutoRun/README.md) | Quality of Life | `[Num Lock]` | Camera-oriented continuous autorun with seamless natural input cancellation (WASD, menus, jumping). |
| [**BulkOpen**](BulkOpen/README.md) | Quality of Life | `[Shift+F11]` | Opens every bag and pack in your backpack with one key press. |
| [**HomeRecall**](HomeRecall/README.md) | Travel | `[Ctrl+F11]`, `[Alt+F11]` | Teleports you home (saved spot or bed) after a 3-second channel, with a cooldown. |
| [**HotbarScroll**](HotbarScroll/README.md) | Controls | Mouse wheel | Mouse wheel cycles your hotbar slots. |
| [**RaidWarning**](RaidWarning/README.md) | Base | Automatic | On-screen warning when enemies gather at your base. |
| [**RecipeLookup**](RecipeLookup/README.md) | Crafting | `[Alt+F12]` | Lists recipes (for the open station) and which ones you can craft with what's in your bag and nearby chests. |
| [**ToolkitProbe**](ToolkitProbe/README.md) | Developer | `[Ctrl+F12]` | Dumps game object details to a file so features that need game-internal names can be finished. |

> **New in this release (untested in game):** BulkOpen, HomeRecall, HotbarScroll, RaidWarning, RecipeLookup and ToolkitProbe, plus QuickStack Station Fetch, chest labels and station output auto-store, and minimap death and teammate markers. Each logs `[DISCOVERY]` lines to `UE4SS.log` when a guess about the game's internals doesn't match.

---

## Master Controls Cheat-Sheet

| Keybind | Tool | Action |
| :--- | :--- | :--- |
| **`[ESC]`** | **Pause Menu** | Pausing automatically displays the active Toolkit Mod Dashboard |
| **`[Ctrl+F8]`** | **Toolkit Mod Menu** | Open / close the in-game mod dashboard overlay anytime |
| **`[Num Lock]`** | **AutoRun** | Toggle continuous camera-forward autorun on / off |
| **`[G]` (Tap)** | **Quick Stack** | **At Base:** Auto-sort items into dedicated category chests & upgrade to 48 slots<br>**In Wild:** Instant harvest & ground magnetism for nearby plants/loot |
| **`[G]` (Hold)** | **Quick Stack** | **Continuous Vacuum:** Harvest and pull all wild flora & ground items within 40m<br>**Hovering Item:** Quick-pull all matching stacks from nearby chests |
| **`[Ctrl + G]`** | **Quick Stack** | **Pack Base:** Vacuum all ground items within 150m into virtual Relocation Crate |
| **`[Shift + G]`** | **Quick Stack** | **Unpack Base:** Deposit all Relocation Crate items categorized into nearby chests |
| **`[Alt + G]`** | **Quick Stack** | **Station Fetch:** At an open crafting station, pull its ingredients from nearby chests. Hovering an item pulls that item instead |
| **`[Shift + F12]`** | **Quick Stack** | Toggle floating category labels above nearby chests |
| **`[Ctrl + F6]`** | **OSRS Minimap** | Clear the death marker |
| **`[Shift + F11]`** | **Bulk Open** | Open every bag/pack in your backpack |
| **`[Ctrl + F11]`** | **Home Recall** | Recall home (3s channel, moving cancels) |
| **`[Alt + F11]`** | **Home Recall** | Save the current spot as home |
| **Mouse wheel** | **Hotbar Scroll** | Cycle hotbar slots |
| **`[Alt + F12]`** | **Recipe Lookup** | Show recipes / next page (`Esc` closes) |
| **`[Ctrl + F12]`** | **Toolkit Probe** | Write a probe file for the toolkit author |
| **`[F6]`** | **OSRS Minimap** | Toggle OSRS minimap display on / off |
| **`[F9]`** | **OSRS Minimap** | Toggle live resource tracking icons on / off |
| **`[F4]`** | **Enhanced Reticle** | Toggle high-visibility crosshair on / off |
| **`[F1]`** | **Enhanced Reticle** | Cycle reticle color (Neon Green, Gold, Cyan, Red, Pink, Orange, White) |
| **`[F2]`** | **Enhanced Reticle** | Cycle reticle size (1.0x, 1.5x, 2.0x, 2.5x, 3.2x) |
| **`[E]`** or **`[V]`** | **Telekinetic Woodcraft** | Telekinetically grab, carry, or drop targeted log / trunk |
| **`[Z]`** | **Telekinetic Woodcraft** | [Log Magnet] Mass-gather all logs within 150m into a neat pile |
| **`[Shift + F6]`** | **Telekinetic Woodcraft** | Cycle Splinter spell AoE radius multiplier (1x, 2.5x, 5.0x) |
| **`[Ctrl + R]`** | **UE4SS Engine** | Live hot-reload all Lua mods without restarting the game (can close the game while mods with background loops unload; restarting is safer) |

The new mods use F11/F12 chords because the game ignores Ctrl/Alt, so a Ctrl+letter chord also fires the game's own binding for that letter, and UE4SS already owns Ctrl+O (debug console), Ctrl+J (object dump), Ctrl+H (header dump) and Ctrl+Num5–9 (other dumpers). Numpad keys were ruled out because AutoRun's Num Lock toggle turns them into End/arrow keys. F12 on its own is Steam's default screenshot key, so these chords may also save a Steam screenshot unless that key is changed in Steam.

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
   The script defaults to `F:\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64\ue4ss\Mods`. If your game is installed elsewhere, pass your own path: `.\deploy.ps1 -GamePath "<GameRoot>\RSDragonwilds\Binaries\Win64\ue4ss\Mods"`.
3. To deploy a specific tool only:
   ```powershell
   .\deploy.ps1 -Tool QuickStack
   .\deploy.ps1 -Tool OSRSMinimap
   .\deploy.ps1 -Tool EnhancedReticle
   .\deploy.ps1 -Tool TelekineticWoodcraft
   .\deploy.ps1 -Tool ModMenu
   .\deploy.ps1 -Tool AutoRun
   .\deploy.ps1 -Tool BulkOpen
   ```
4. The script copies files to your game directory and automatically updates `mods.txt`.

---

### Option B: Manual Installation

1. Copy the desired mod folders (`OSRSMinimap`, `QuickStack`, `EnhancedReticle`, `TelekineticWoodcraft`, `ModMenu`, `AutoRun`, `BulkOpen`, `HomeRecall`, `HotbarScroll`, `RaidWarning`, `RecipeLookup`, `ToolkitProbe`) into:
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
   BulkOpen : 1
   HomeRecall : 1
   HotbarScroll : 1
   RaidWarning : 1
   RecipeLookup : 1
   ToolkitProbe : 0
   ```
4. Launch the game through Steam normally!

---

## Mod Highlights & Features

### 1. Toolkit Mod Menu (`ModMenu`)
- **Pause Menu Integration**: Injects a custom **"TOOLKIT MODS"** button into the native ESC Game Paused screen.
- **In-Game Overlay (`Ctrl+F8`)**: Instantly shows an Old School RuneScape style Slate card with live status badges (`[ON]` / `[OFF]`) and keybind reminders.
- **Real-Time Detection**: Automatically re-scans `mods.txt` whenever toggled, immediately showing changes without restarting.
- **Zero Performance Impact**: Widget remains collapsed and uses 0 CPU cycles during normal gameplay.

### 2. QuickStack (`QuickStack`)
- **In-Memory Category Consolidation**: Pulls items from nearby chests into an in-memory buffer, merges duplicate/split stacks, and redistributes them strictly into dedicated category chests (**FOOD**, **WOOD**, **MINING**, **FARMING**, **EQUIPMENT**, **MAGIC**, **MISC**).
- **48-Slot Highest Tier Upgrade**: Dynamically upgrades all detected chests and crates to 48 slots (`MaxSlotCount = 48`) with high-tier static meshes in-place.
- **Wild Gathering & Ground Magnetism (`Hold G`)**: Sweeps a 40m radius while sprinting, auto-harvesting wild crops (dwellberries, onions, flax, herbs, fallen wood, stones) directly into your backpack.
- **Base Relocation Virtual Crate (`Ctrl+G` / `Shift+G`)**: Pack all ground items within 150m into a persistent virtual crate, then unpack them organized into nearby chests with one keypress.
- **Targeted QuickPull**: Hover any item in your inventory or chest and hold `G` (or press `Alt+G`) to pull all matching stacks from all nearby chests directly into your inventory.
- **Station Fetch (`Alt+G`)**: With a furnace, anvil or other station open, pulls one stack of each ingredient it accepts from nearby chests into your backpack.
- **Chest Labels (`Shift+F12`)**: Floating category labels above chests within 30m.
- **Station Output Auto-Store**: Products a crafting station drops on the ground go straight into the matching category chest.
- **Strict Safe Guards**: Zero-tolerance blacklist prevents any crafting stations, blast furnaces, smelters, kilns, or campfires from being touched. Hotbar, combat ammunition, and runes are 100% protected.

### 3. OSRS Minimap (`OSRSMinimap`)
- **Compass Rotation**: Player icon remains locked pointing UP while the world map rotates and pans under you, matching traditional OSRS navigation.
- **Resource Pin Tracking (`F9`)**: Real-time map pins for nearby high-tier ores (Runite, Adamant, Mithril, Coal, Blurite), trees (Yew, Maple, Willow, Oak), fishing spots, and elemental anima vents.
- **Main Map Isolation**: Operates on an independent map layer—opening your full-screen World Map (`M`) is 100% unaffected.
- **Death Marker**: Marks where you died on both maps; clears when you get back there or with `Ctrl+F6`.
- **Teammate Markers**: Other players in your world appear on both maps, tinted by health.

### 4. Enhanced Reticle (`EnhancedReticle`)
- **High-Contrast Aiming**: Replaces the faint default reticle with bright, crisp crosshairs for precise spellcasting and archery.
- **7 Color Presets (`F1`)**: Neon Green, OSRS Gold, Cyan, Crimson Red, Hot Pink, Amber Orange, Pure White.
- **5 Scale Levels (`F2`)**: 1.0x (Vanilla), 1.5x, 2.0x, 2.5x, 3.2x (High-visibility).
- **Universal State Coverage**: Seamlessly adapts across combat spells, utility magic, bow ADS, and stealth.

### 5. Telekinetic Woodcraft (`TelekineticWoodcraft`)
- **Single Log Drag (`E` or `V`)**: Aim at any felled tree or cut log to telekinetically carry it in front of you. Press again to settle it flat on the ground.
- **Log Magnet Mass Gathering (`Z`)**: Pulls all logs within 150 meters into a compact, flat pyramid woodpile directly in front of you.
- **Splinter Spell Multiplier (`Shift+F6`)**: Boosts the Splinter spell explosion radius (1.0x, 2.5x, 5.0x) to harvest an entire woodpile in a single cast.

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
UE4SS reserves <code>F10</code> by default for the built-in developer console (ConsoleEnablerMod). The Toolkit Mod Menu uses <b><code>[Ctrl+F8]</code></b> and the ESC <b>Pause Menu</b> button to prevent any keybind conflicts.
</details>

---

## License

This project is released under the **MIT License** (see [LICENSE](LICENSE)). Free to use, modify, and distribute for the *RuneScape: Dragonwilds* community.
