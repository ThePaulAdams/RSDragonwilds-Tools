# QuickStack v2.1 Technical Specification & Architecture

## 1. System Overview

QuickStack is a client-side Lua modification for ***RuneScape: Dragonwilds*** running on the **UE4SS (Unreal Engine 4/5 Scripting System)** framework. Its purpose is to automate inventory management, inter-chest reorganization, automatic chest capacity tier upgrading, field resource harvesting, and world loot magnetism.

```
                           +------------------------+
                           |     User Input (G)     |
                           +-----------+------------+
                                       |
                   +-------------------+-------------------+
                   |                                       |
           [Tap at Base]                            [Hold in Wild]
                   |                                       |
    +--------------v--------------+         +--------------v--------------+
    | Base Chest Detection Engine |         |  Continuous Field Harvester |
    | (100m Multi-Scan + Open UI) |         |  & 40m Ground Item Vacuum   |
    +--------------+--------------+         +-----------------------------+
                   |
    +--------------v--------------+
    | 48-Slot Chest Upgrade Engine|
    | (MaxSlotCount=48, SM Swap)  |
    +--------------+--------------+
                   |
    +--------------v--------------+
    | In-Memory Consolidation     |
    | (Extract -> Merge -> Clear) |
    +--------------+--------------+
                   |
    +--------------v--------------+
    | Categorized Chest Dispatch  |
    | (FOOD, WOOD, MINING, etc.)  |
    +-----------------------------+
```

---

## 2. Core Functional Specifications

### 2.1 Chest Discovery & Candidate Registration
- **Detection Radius**: `Config.SearchRadius = 10000.0` Unreal Units (100 meters).
- **Scanning Pipelines**:
  1. **Pipeline 0 (Active UI Context)**: Scans for active `WorldActorInventoryUIAPI` instances. Retrieves the open container's `InventoryComponent` and its owning `AActor`. Bypasses distance and line-of-sight checks to guarantee 100% recognition when interacting with any container.
  2. **Pipeline A (Explicit Storage Blueprints)**: Iterates instances of:
     - `BP_BaseBuilding_Chest_C` (Standard Chest)
     - `BP_BaseBuilding_Chest_Small_C` (Small Chest)
     - `BP_BaseBuilding_Crate_C` (Base Crate)
     - `BP_BaseBuilding_LumberStorage_C` (Lumber Storage)
  3. **Pipeline B (World Item Inventories)**: Queries all `BP_Components_WorldItemInventory_C` components and inspects their parent actor.
  4. **Pipeline C (Generic Inventory Components)**: Iterates `InventoryComponent` instances, filtering out player pawn and player controller.
- **Validation Criteria (`IsChestActor`)**:
  - Rejects Class Default Objects (`RF_ClassDefaultObject`) and Archetype Objects (`RF_ArchetypeObject`).
  - Strict zero-tolerance blacklist for processors and crafting stations (see Section 4).
  - Whitelist substring matching against actor name and class name (`chest`, `crate`, `storage`, `rack`, `stand`, `mannequin`, `wardrobe`, `coffer`, `trunk`).

### 2.2 Dynamic 48-Slot Capacity Upgrade
- For every valid chest actor detected within the search radius:
  - Queries `chestInv.MaxSlotCount`.
  - If `MaxSlotCount < 48`:
    - Assigns `chestInv.MaxSlotCount = 48`.
    - Updates StaticMeshComponent to `StaticMesh'/Game/Environment/BaseBuilding/Storage/Meshes/SM_Storage_Chest_01v2.SM_Storage_Chest_01v2'`.
    - Persists without altering actor transforms, world hierarchy, or save serialization.

### 2.3 In-Memory Consolidation & Categorization Engine
- **Memory Ingestion**: Iterates each slot of all nearby chests and reads:
  - `ItemData` UObject reference and AssetPath
  - `Durability` float
  - Current `StackCount`
  - Item display name and category classification
- **Deduplication & Stack Merging**:
  - Keyed by `AssetPath_Durability`.
  - Combines multiple fragmented stacks across disparate chests into a unified stack count.
- **Inventory Reset**:
  - Calls native `comp:ClearInventory()` on all involved containers to purge fragmented slots.
- **Category Taxonomies**:
  | Category | Included Items |
  | :--- | :--- |
  | **FOOD** | Raw/cooked meat, burnt food, fish, bread, berries, dwellberries, potions, drinks, stews |
  | **WOOD** | Normal/Oak/Willow/Maple/Yew logs, planks, bark, timber, splinters, charcoal |
  | **MINING** | Copper/Tin/Iron/Blurite/Silver/Coal/Gold/Mithril/Adamant/Runite ores, bars, stone, clay, gems |
  | **FARMING** | Flax, onions, wild crops, seeds, fibers, herbs, leather, cloth, crafting textiles |
  | **EQUIPMENT**| Swords, bows, shields, staves, armour (helm, chest, legs, boots, gloves, jewellery) |
  | **MAGIC** | Runes, rune pouches, essence, talismans, enchanted shards |
  | **MISC** | Coins, quest items, tools, utility components, keys |
- **Chunked Redistribution**:
  - Each item is retrieved by `ResolveItemData()`.
  - Stacks larger than native `ItemData:GetMaxStackSize()` are sliced into full stacks before calling `comp:AddItemByData()`.
  - Containers are assigned dedicated categories (e.g. Chest 1 = FOOD, Chest 2 = WOOD, Chest 3 = MINING) to eliminate mixed-category contamination.

### 2.4 Field Harvesting & Ground Magnetism
- **Field Tap (`G` in Wild)**:
  - Instant AoE harvest for `BP_Spawner_HarvestableBase_C`, `BP_WorldHarvestable_C`, `BP_Plant_C`.
  - Triggers native interaction / harvest delegates and collects ground loot within 40m.
- **Continuous Vacuum (`Hold G`)**:
  - Checks `PC:IsInputKeyDown(FName("G"))` every tick during hold state.
  - Queries `BP_WorldItem_C` and ground pickups within 40m (`4000.0` uu).
  - Teleports and deposits valid items into player inventory.

### 2.5 Base Relocation Virtual Crate
- **Pack (`Ctrl + G`)**:
  - Scans `BP_WorldItem_C` within 150m (`15000.0` uu).
  - Ingests items into persistent Lua `RelocationCrate` table.
  - Destroys world item actors via `K2_DestroyActor()`.
- **Unpack (`Shift + G`)**:
  - Iterates `RelocationCrate` and transfers items into nearby categorized base chests.

---

## 3. Detailed Engineering Challenges & Technical Solutions

### Challenge 1: The UE4SS Lua `TrivialObject` `:GetName()` Limitation
- **Root Cause**:
  In UE4SS, `UClass` (returned by `:GetClass()`) and `UActorComponent` objects are wrapped with the `TrivialObject` metatable. Unlike standard `UObject` wrappers, `TrivialObject` **does not define a `:GetName()` method**.
  Calling `:GetName()` throws:
  ```
  attempt to call a TrivialObject value (method 'GetName')
  ```
  Because all candidate detection logic was wrapped in `pcall(function() ... end)`, the exception was caught silently, leaving `className` and `actorName` as empty strings (`""`).
- **Symptom**:
  `IsChestActor(actor)` performed:
  ```lua
  if className:find("chest") or actorName:find("chest") then return true end
  ```
  Because both strings were empty, `IsChestActor` evaluated to `false` for **100% of chests in the game**. The mod continuously logged:
  `QuickStack: No chests found within 60.0 meters` even when the player was touching the chest.
- **Resolution**:
  Engineered safe reflection helpers:
  ```lua
  local function GetSafeName(obj)
      if not obj then return "" end
      local name = ""
      pcall(function()
          if obj.GetFName then
              name = obj:GetFName():ToString()
          elseif obj.GetFullName then
              name = obj:GetFullName()
          end
      end)
      return name or ""
  end

  local function GetSafeClassName(obj)
      if not obj then return "" end
      local clsName = ""
      pcall(function()
          local cls = obj:GetClass()
          if cls then
              if cls.GetFName then
                  clsName = cls:GetFName():ToString()
              elseif cls.GetFullName then
                  clsName = cls:GetFullName()
              end
          end
      end)
      return clsName or ""
  end
  ```
  These functions safely leverage `GetFName():ToString()` and `GetFullName()`, eliminating the `TrivialObject` runtime failure across all classes, actors, and components.

---

### Challenge 2: Multi-Room Base Geometry & Distance Culling
- **Root Cause**:
  In player-built bases, chests are often spread across separate rooms, upper lofts, or cellars. Measured distances from the main living area to chests were between **46.9m and 47.4m**. The original search radius of 25m (and later 40m) strictly culled these chests before candidate evaluation.
  Additionally, `IsValidWorldActor` previously checked `actor:GetWorld()`, which in UE4SS frequently returns `nil` on placed building actors that are not part of the persistent streaming level.
- **Resolution**:
  - Expanded `Config.SearchRadius` to **100 meters** (`10000.0` uu).
  - Replaced `actor:GetWorld()` with direct object flag bitwise evaluation:
    ```lua
    if actor:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject) then
        return false
    end
    ```
  - Added Pipeline 0: direct lookup via `WorldActorInventoryUIAPI` to bypass distance checks when interacting with an open chest.

---

### Challenge 3: Blast Furnace & Crafting Station Blacklisting
- **Root Cause**:
  In *RuneScape: Dragonwilds*, processors and crafting stations (such as `BP_BaseBuilding_BlastFurnace_C`, smelters, kilns, and campfires) inherit from base interactive actors and contain an `InventoryComponent` to accept fuel and raw materials.
  When quick-stacking scanned for generic `InventoryComponent` instances, the blast furnace was evaluated as a valid container. If a player had equipment or fuel in their inventory, the engine deposited items into the blast furnace (e.g. depositing a Dragon Cursed Shield as fuel).
- **Resolution**:
  Implemented an exhaustive zero-tolerance blacklist in `IsChestActor()`:
  ```lua
  local disallowedKeywords = {
      "furnace", "smelter", "kiln", "campfire", "fire", "range", "cook",
      "cauldron", "bench", "anvil", "wheel", "station", "crafting",
      "grinder", "sawmill", "loom", "stonecutter", "tanning", "brew",
      "pottery", "altar", "vent", "spawner", "pawn", "character", "npc",
      "enemy", "bedroll", "lodestone", "torch", "light"
  }
  ```
  Additionally added mandatory deposit protection for combat ammunition (`ProtectAmmo = true`) and magic runes (`ProtectRunes = true`).

---

### Challenge 4: Inter-Chest Item Movement Limitations in UE5
- **Root Cause**:
  In Dominion's inventory architecture, moving items between two world containers cannot be achieved through `MoveItem(sourceComp, targetComp, slot)` because native replication expects the player pawn inventory to be one of the transaction endpoints.
  Early attempts to bounce items through player inventory slots suffered from capacity bottlenecks: if the player had fewer free slots than the container being sorted, items could not be moved or were dropped onto the floor.
- **Resolution**:
  Designed the **In-Memory Consolidation Architecture**:
  1. The Lua state functions as a lossless virtual intermediate storage.
  2. All items across all nearby containers are extracted and merged into a memory table.
  3. Chests are emptied atomically with native `comp:ClearInventory()`.
  4. Chests are expanded to 48 slots (`MaxSlotCount = 48`).
  5. Clean, consolidated stacks are pushed directly into designated chests via native `comp:AddItemByData()`, safely chunked by `ItemData:GetMaxStackSize()`.

---

### Challenge 5: Stack Slicing & MaxStack Overflow
- **Root Cause**:
  When consolidating split stacks (e.g., 8 separate stacks of Dwellberries totalling 350 berries), calling `comp:AddItemByData(itemData, 350, ...)` fails or silently truncates if the item's `GetMaxStackSize()` is smaller than the total quantity (e.g., max stack of 50).
- **Resolution**:
  Implemented chunked deposit loops in `ReorganizeNearbyChests`:
  ```lua
  local remaining = itemEntry.Count
  local maxStack = 1
  pcall(function() maxStack = itemEntry.ItemData:GetMaxStackSize() end)
  if not maxStack or maxStack < 1 then maxStack = 999 end

  while remaining > 0 do
      local depositCount = math.min(remaining, maxStack)
      local added = targetComp:AddItemByData(itemEntry.ItemData, depositCount, itemEntry.Durability, false)
      remaining = remaining - added
      if added == 0 then break end
  end
  ```

---

## 4. Safeguards & Protections Summary

1. **Hotbar Preservation**: Slots 0 through 7 of the player's quick-access bar are never evaluated as deposit sources.
2. **Combat Ammunition Preservation**: Strict keyword and class checks prevent arrows, bolts, quivers, and ammo from being deposited.
3. **Magic Rune Preservation**: Strict keyword and path checks prevent elemental runes, essence, and rune pouches from being deposited.
4. **Machine / Furnace Preservation**: Disallowed keywords prevent non-storage actors from being modified or receiving deposits.
5. **Lossless Overflow Protection**: If total items exceed the combined capacity of all 48-slot chests, excess items are returned to player backpack; if backpack is full, items are spawned safely at the player's feet via `K2_DropItem`.
