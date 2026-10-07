# Custom Builds: In-Game Building, Companions & Quest Engine

[![RSDragonwilds](https://img.shields.io/badge/Game-RuneScape%3A%20Dragonwilds-gold?style=for-the-badge)](https://store.steampowered.com)
[![Framework](https://img.shields.io/badge/Framework-UE4SS%20v3.0%2B-green?style=for-the-badge)](https://github.com/UE4SS-RE/RE-UE4SS)
[![BaseBuilder](https://img.shields.io/badge/Ecosystem-Ashenfallen%20Base--Builder-orange?style=for-the-badge)](https://ashenfallen.com)

**Custom Builds** is the flagship creative and storytelling engine for *RuneScape: Dragonwilds*. It enables unrestricted placement of over 5,100+ game models, powers interactive companion NPCs, and executes full branching quest storyboards created in the **Ashenfallen Base-Builder**.

---

## 🏗️ Ashenfallen Base-Builder & Toolkit Ecosystem

Does the **Ashenfallen Base-Builder** need this modpack installed?
**YES!** 

- **Ashenfallen Base-Builder** ([ashenfallen.com](https://ashenfallen.com) / local viewer) is the **external 3D visual planner & quest storyboard tool**. It allows you to freely inspect models, layout full bases, place NPCs, write branching dialogue trees, configure item collection/slaying objectives, and assign real rewards.
- **Custom Builds (Modpack)** is the **in-game runtime executor**. Without this mod installed in your game, *RuneScape: Dragonwilds* has no native code to parse custom bases, spawn companion characters, trigger `E` key interactions, draw overhead `!` markers, track quest inventory, or award custom item deliveries.

### Data Flow
```
┌─────────────────────────────────┐
│   Ashenfallen Base-Builder      │  Visual 3D scene designer & Quest Storyboarder
│   (https://ashenfallen.com)     │  Exports: base.txt, placed.txt, quests.json
└────────────────┬────────────────┘
                 │ (Direct Folder Sync / File Download)
                 ▼
┌─────────────────────────────────┐
│     CustomBuilds Mod            │  UE4SS Lua Runtime Engine
│  (Dragonwilds Mod Directory)    │  • Materializes 5,100+ building pieces & decor
└────────────────┬────────────────┘  • Spawns interactive companions (Doric, Cook...)
                 │                   • Renders 3D overhead [ ! ] & [ ? ] markers
                 ▼                   • Connects pins to OSRS Minimap
┌─────────────────────────────────┐  • Manages dialogue trees (Press E, choices 1-4)
│    RuneScape: Dragonwilds       │  • Evaluates inventory objectives & hands out rewards
│      Live Game Session          │  • Automatically manages daily quest resets
└─────────────────────────────────┘
```

---

## ✨ Key Features

### 1. 5,100+ Model In-Game Browser & Placement (`[N]`)
- **Visual Thumbnail Catalog**: Press **`N`** to browse every model extracted from the game (castle walls, towers, temple ruins, statues, furniture, lanterns, flora).
- **Precise Transform Gizmos**: Rotate in 15° or 90° increments, tilt, roll, scale smoothly, or nudge by centimeters.
- **Magnetic Snapping**: Press **`End`** to toggle between **EDGES** (flush against neighboring pieces), **GRID** (aligned with your base foundation grid), or **FREE** placement.
- **Undo & Redo**: Press **`Backspace`** to undo recent placements, moves, or deletions.
- **Persistent World Persistence**: Placements are stored in `placed.txt` and re-instantiated seamlessly whenever you load your world.

### 2. Interactive Companion NPCs & Dialogue System (`[E]`)
- **Living Characters**: Place iconic RuneScape characters directly in your sanctuary or castles (Doric the Dwarf, Wise Old Man, Cook, Zanik, Vannaka, Postie Pete, pet chinchompas, and more).
- **Proximity Interaction**: Walk up to any placed companion and press **`E`** to initiate cinematic dialogue.
- **Branching Decision Trees**: Select dialogue choices using number keys **`1`**, **`2`**, **`3`**, **`4`**, or press **`Esc`** / **`Space`** to exit.
- **Duplicate Protection**: Automatically recognizes existing companion actors upon world restart, preventing duplicate spawns.

### 3. Full Quest Storyboard Engine
- **Overhead 3D Animated Markers**:
  - `[ ! ]` (Iconic RuneScape Gold): Floats and bobs over the NPC's head when a quest is available.
  - `[ ? ]` (Silver / Blue): Appears overhead while a quest is active.
  - `[ ? ]` (Pulsing Bright Gold): Flashes when quest requirements are met and ready for turn-in.
- **Minimap Integration**: Pinned quest star icons automatically display on the **OSRS Minimap** plugin with distance scaling.
- **Inventory Objective Evaluation**: Checks your inventory slots in real time for requested items (e.g. Iron Ore, logs, relics, herbs).
- **Real Reward Delivery**: Grants actual items directly to your backpack (e.g. Garou Packs, coins, consumables, or custom resources) with audible turn-in chimes.
- **Daily Repeatable Quests**: Supports `"repeatable": "daily"`. Quests reset automatically at midnight or upon calendar rollover, turning delivery quests into daily routines.

---

## 🎮 Master Controls

### Model Placing Mode (Activated from `[N]` Menu)
| Keybind | Action |
| :--- | :--- |
| **Left Click** | Place active model preview |
| **Right Click** or **`[Esc]`** | Cancel / exit placing mode |
| **`[←]` / `[→]`** | Turn 15° (Hold **`Shift`** for 90°) |
| **`[↑]` / `[↓]`** | Tilt 15° (Hold **`Shift`** for 90°) |
| **`[Ctrl]` + `[↑]` / `[↓]`** | Roll 90° |
| **`[+]` / `[-]`** | Scale model larger / smaller |
| **`[Alt]` + Arrows** | Nudge position horizontally |
| **`[Alt]` + `[+]` / `[-]`** | Nudge position vertically (up/down) |
| **`[End]`** | Cycle snap modes: **EDGES** / **GRID** / **FREE** |
| **`[Home]`** | Reset tilt, roll, and scale to defaults |

### General World Controls
| Keybind | Action |
| :--- | :--- |
| **`[N]`** | Open / close the in-game model catalog browser |
| **`[E]`** | Interact / talk to nearby NPC companions |
| **`[1]`, `[2]`, `[3]`, `[4]`** | Select dialogue response during NPC chat |
| **`[Delete]`** | Delete the custom model / NPC you are looking at |
| **`[Insert]`** | Pick up and move an already placed piece |
| **`[Backspace]`** | Undo last placement or deletion |

---

## 💻 Console Commands (`F10` / `~`)

Open the UE4SS developer console in-game to run advanced commands:

| Command | Description |
| :--- | :--- |
| `cb quest` | Displays current active quest, objectives, and progression state |
| `cb quest reset` | Wipes completed quest progress and reloads `quests.json` for recording/testing |
| `cb quest daily` | Triggers an immediate daily reset check on all repeatable quests |
| `cb quest reload` | Hot-reloads `quests.json` from disk without restarting the game |
| `cb quest step` | Advances active quest objective progress by +1 |
| `cb clean` | Scans and cleans up any duplicate companion actors near your base |
| `cb npc <name>` | Quickly spawns a test companion (`doric`, `wise`, `cook`, `zanik`, `vannaka`) |
| `cb find <text>` | Searches all 5,100+ models by keyword and creates a search category in the `N` browser |
| `cb base export` | Exports all native building pieces to `base.txt` for importing into Ashenfallen |

---

## 📁 File Structure

```
CustomBuilds/
├── enabled.txt          # Mod activation flag (delete or rename to disable)
├── quests.json          # Active quest definitions exported from Ashenfallen Base-Builder
├── save_quests.json     # Player quest completion states, progress, and daily timestamps
├── placed.txt           # Player's placed custom models and companion coordinates
├── models-all.txt       # Master list of all 5,100+ placeable mesh paths
├── models.txt           # Player favorites catalog
├── orient.txt           # Saved model tilt/rotation calibrations
├── scripts/
│   └── main.lua         # Core runtime engine script
├── thumbs/              # High-resolution thumbnail previews for the [N] menu
└── ui/
    └── panel.png        # RuneScape-themed Slate UI frame texture
```

---

## 🚀 Installation

1. Ensure **UE4SS** (experimental build with UE 5.6 support) is installed in:
   `Steam/steamapps/common/RSDragonwilds/RSDragonwilds/Binaries/Win64/`
2. Copy the `CustomBuilds` folder into:
   `...\Binaries\Win64\ue4ss\Mods\`
3. Launch *RuneScape: Dragonwilds*!
