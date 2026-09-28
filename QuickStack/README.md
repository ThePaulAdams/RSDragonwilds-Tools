# QuickStack Mod for RuneScape: Dragonwilds (v2.1)

[![Framework](https://img.shields.io/badge/Framework-UE4SS%20v3.0%2B-green?style=for-the-badge)](https://github.com/UE4SS-RE/RE-UE4SS)
[![Engine](https://img.shields.io/badge/Engine-Unreal%20Engine%205-blue?style=for-the-badge)]()
[![Status](https://img.shields.io/badge/Status-Fully%20Stable-brightgreen?style=for-the-badge)]()

**QuickStack** is an advanced, high-performance survival-crafting storage automation and field-gathering engine for ***RuneScape: Dragonwilds***. 

With a single hotkey, QuickStack upgrades nearby storage chests to maximum 48-slot tier, consolidates fragmented stacks into an in-memory buffer, cleanly empties containers, and redistributes all items into dedicated category chests (Food, Wood, Mining, Farming, Equipment, Magic, Misc). In the field, it functions as an instant AoE harvester and continuous vacuum magnet for ground loot and wild flora.

---

## Key Features

### 1. In-Memory Chest Consolidation & Sorting (`[G]` Tap at Base)
- **Stack Aggregation**: Merges split stacks and fragmented items by unique `ItemData` asset and durability.
- **Dedicated Category Distribution**: Redistributes items strictly into dedicated category chests:
  - 🍎 **FOOD**: Raw and cooked meats, burnt food, fish, bread, berries, dwellberries, drinks, rations, consumables.
  - 🪵 **WOOD**: Regular logs, oak, willow, maple, yew, planks, bark, timber, splinters, charcoal.
  - ⛏️ **MINING**: Ores (copper, tin, iron, blurite, silver, coal, gold, mithril, adamant, runite), ingots/bars, stone, clay, gems.
  - 🌾 **FARMING**: Wild crops, onions, flax, seeds, herbs, fibers, textiles, leather, cloth, crafting parts.
  - 🛡️ **ARMOUR**: Helms, bodies, legs, boots, gloves, capes and other worn pieces. Placed on armour stands/racks when you have them, otherwise in their own chest.
  - ⚔️ **EQUIPMENT**: Weapons, bows, staves, shields, tools, jewellery.
  - ✨ **MAGIC**: Runes, essences, staves, wands, talismans, enchanted materials.
  - 📦 **MISC**: Gold coins, quest items, utility components, keys, unclassified valuables.
- **Safe Stack-Chunking**: Splits aggregated quantities cleanly according to each item's native `GetMaxStackSize()`.
- **Sticky Chests**: Each chest keeps the category it already holds most of, so your food chest stays your food chest every time you press `[G]`.
- **Nothing Is Dropped**: Sorting carries whole stacks chest -> backpack slot -> chest using the same moves as a normal deposit, checking each step. A chest never gets emptied, and a refused move puts the stack back where it was. Needs one free backpack slot.
- **Ground Items Stored Too**: Loose items on the ground near you are picked up and put into their category chests (only when your backpack has room). Turn off with `StoreGroundItemsAtBase = false`.
- **Not Enough Chests?** Categories without their own chest share leftover space, and the UE4SS log says how many more chests to build.

### 2. Automatic 48-Slot Highest Tier Chest Upgrade
- Automatically inspects every detected chest or crate.
- If a chest has fewer than 48 slots (e.g. small 16-slot chests or standard crates), it dynamically upgrades its internal capacity to **48 slots** (`MaxSlotCount = 48`).
- Updates the static mesh in-place to `SM_Storage_Chest_01v2` (Highest Tier Large Storage Chest) without breaking world references, transform, or save state.

### 3. Open Chest Instant Detection (`WorldActorInventoryUIAPI`)
- QuickStack directly integrates with the active UI API: opening any chest and tapping `[G]` guarantees 100% immediate detection and sorting regardless of distance or room occlusion.

### 4. Wild Resource Gathering & Ground Magnetism (`[G]` Hold)
- **Instant Tap in the Wild**: Tapping `[G]` outside your base instantly harvests nearby resource nodes (onions, dwellberries, flax, pumpkins, branches, herbs) and vacuums ground items directly into your inventory.
- **Continuous Vacuum Sprint (`Hold G`)**: Continuously sweeps a **40-meter radius** around the player, vacuuming all dropped items and harvesting flora as you run.

### 5. Targeted Quick-Pull (Hover + `[Hold G]`)
- Hover your mouse cursor over any item in your inventory or an open container and hold `[G]`.
- The mod scans all nearby chests within 100m and retrieves every matching stack directly into your backpack, stopping when your backpack is full.
- While hovering an item, nothing is sorted or moved until QuickStack knows whether you tapped (sort) or held (pull).

### 6. Base Relocation Virtual Crate (`[Ctrl + G]` / `[Shift + G]`)
- **Pack Base (`Ctrl + G`)**: Automatically sweeps all loose items on the ground within **150 meters** and packs them safely into a persistent virtual relocation crate.
- **Unpack Base (`Shift + G`)**: Unpacks the virtual crate directly into nearby chests, auto-sorted by category.

### 7. Strict Safety Safeguards & Furnace Protection
- **Furnace & Crafting Station Blacklist**: Zero-tolerance filtering prevents blast furnaces, smelters, kilns, campfires, cooking ranges, anvils, and crafting benches from ever being identified as storage containers. Equipment (such as a Dragon Cursed Shield) is never deposited as fuel.
- **Ammunition Protection**: Combat arrows, bolts, quivers, and ammunition are protected and kept in your backpack.
- **Runes Protection**: Magic runes, rune pouches, and essence are protected from accidental depositing.
- **Hotbar Protection**: Quick-action hotbar slots are preserved.

---

## Controls Cheat-Sheet

| Keybind | Context | Action |
| :--- | :--- | :--- |
| **`[G]` (Tap)** | Near Base / Chests | **Quick Stack & Category Sort**: Upgrades chests to 48 slots and organizes all items into dedicated category chests. |
| **`[G]` (Tap)** | In the Wild | **Instant Harvest**: One-touch AoE harvest and ground loot collection. |
| **`[G]` (Hold)** | Field / Roaming | **Continuous Ground Vacuum**: 40m continuous magnetism while sprinting. |
| **`[G]` (Hold)** | Hovering Item | **Quick Pull**: Pulls all matching stacks from nearby chests into your backpack. |
| **`[Ctrl + G]`** | Base Relocation | **Pack Base**: Vacuums all ground items within 150m into virtual Relocation Crate. |
| **`[Shift + G]`** | Base Relocation | **Unpack Base**: Unpacks Relocation Crate items categorized into nearby chests. |

---

## Configuration

Settings can be customized at the top of `QuickStack/scripts/main.lua`:

```lua
local Config = {
    Key = Key.G,                  -- Primary keybind (G)
    Modifier = nil,               -- Optional modifier key (e.g. ModifierKey.CONTROL)
    SearchRadius = 10000.0,       -- Chest search distance in Unreal Units (10000 uu = 100m)
    GroundMagnetRadius = 4000.0,  -- Ground item magnetism radius (40m)
    RelocationPackRadius = 15000.0,-- Relocation crate pack radius (150m)
    ProtectHotbar = true,         -- Protect active hotbar slots
    ProtectAmmo = true,           -- Protect arrows, bolts, ammo from being deposited
    ProtectRunes = true,          -- Protect magic runes and essence
    SortSimilarIntoChests = true, -- Categorize items into dedicated chests
    OrganizeNearbyChests = true,  -- Consolidate and reorganize inter-chest items
    OverflowWhenCategoryFull = false, -- Prevent contaminating dedicated chests
    HoldDuration = 0.25,          -- Seconds to distinguish Hold from Tap
    DebugLog = true               -- Detailed UE4SS logging
}
```

---

## Engineering Challenges & Technical Solutions

During the development and testing of QuickStack in the live Unreal Engine 5 environment of *RuneScape: Dragonwilds*, several subtle engine-level challenges had to be diagnosed and overcome:

### 1. UE4SS Lua `TrivialObject` `:GetName()` Limitation
- **The Issue**: In RE-UE4SS, `UClass` (returned by `:GetClass()`) and `UActorComponent` instances wrapped in Lua tables/userdata are classified as `TrivialObject` metatables that **do not have a `:GetName()` method**. Calling `:GetName()` on them throws a runtime Lua error: `attempt to call a TrivialObject value (method 'GetName')`. Because these calls were wrapped in `pcall()`, the errors failed silently and returned empty strings (`""`).
- **The Impact**: In chest candidate validation (`IsChestActor`), the class name and actor name both evaluated to `""`. Consequently, `IsChestActor` returned `false` for 100% of chests in the game, reporting "No chests found within range" even when standing next to chests or with a chest open.
- **The Fix**: Implemented robust `GetSafeName(obj)` and `GetSafeClassName(obj)` helpers that query `obj:GetFName():ToString()` and `obj:GetFullName()`, completely bypassing the missing `:GetName()` method.

### 2. Multi-Class Building Actors & Distance Culling
- **The Issue**: Base storage in *RuneScape: Dragonwilds* is divided across multiple distinct blueprint classes (`BP_BaseBuilding_Chest_C`, `BP_BaseBuilding_Chest_Small_C`, `BP_BaseBuilding_Crate_C`, `BP_BaseBuilding_LumberStorage_C`). Furthermore, in multi-story houses or large bases, player chests are often situated 40m–50m away from the central living area. Initial search radii of 25m or 40m culled these chests. Additionally, `IsValidWorldActor` previously checked `actor:GetWorld()`, which in UE4SS can return `nil` for valid placed base actors.
- **The Fix**: Expanded the default base search radius to **100 meters** (`10000.0` uu), implemented multi-method scanning (explicit class queries, `BP_Components_WorldItemInventory_C` owner queries, and open `WorldActorInventoryUIAPI` queries), and replaced `GetWorld()` checks with safe UObject flag validation (`RF_ClassDefaultObject | RF_ArchetypeObject`).

### 3. Crafting Station & Blast Furnace Collision Filtering
- **The Issue**: In *RuneScape: Dragonwilds*, processors and crafting stations (blast furnaces, smelters, kilns, campfires, anvils, cauldrons) also implement `InventoryComponent` to accept fuel, ores, and crafting ingredients. Broad inventory component scans caused quick-stacking to recognize a blast furnace as a valid storage container, resulting in valuable equipment (such as a Dragon Cursed Shield) being deposited as fuel.
- **The Fix**: Engineered an explicit zero-tolerance blacklist in `IsChestActor()` rejecting any actor whose class name or actor name contains furnace, smelter, kiln, campfire, station, bench, anvil, wheel, cauldron, or cooking keywords.

### 4. Inter-Chest Item Movement & Engine Transfer Limitations
- **The Issue**: Unreal Engine 5's native inventory operations in Dominion restrict container-to-container transfers (`MoveItem` between two world containers often fails or is limited to UI drag operations). Early attempts to bounce items through player inventory risked overflowing backpack slots and dropping items onto the floor.
- **The Fix**: Developed the **In-Memory Consolidation Architecture**:
  1. All items across all nearby chests are extracted into a Lua memory table.
  2. Containers are safely emptied using native `ClearInventory()`.
  3. Chest slot capacities are dynamically updated to 48 (`MaxSlotCount = 48`).
  4. Items are aggregated and redistributed strictly into designated category chests, chunked cleanly by native `MaxStackSize`.

---

## Installation

### Automatic Deployment (PowerShell)
```powershell
.\deploy.ps1 -Tool QuickStack
```

### Manual Installation
1. Copy the `QuickStack` directory to:
   ```
   <GameRoot>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\QuickStack
   ```
2. In `<GameRoot>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\mods.txt`, add:
   ```ini
   QuickStack : 1
   ```
3. In-game, press `Ctrl + R` to hot-reload without restarting.
