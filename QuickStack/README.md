# QuickStack Mod for RuneScape: Dragonwilds

**QuickStack** brings the universally loved survival-crafting QoL feature into *RuneScape: Dragonwilds*. With a single keypress, it automatically deposits matching items from your inventory into nearby storage chests and containers.

---

## Features

1. **One-Touch Quick Stacking (`G`):**
   - Press `G` anywhere near your base, camp, or chests.
   - The mod detects all storage containers within range (default: 25 meters) and deposits matching items in milliseconds.
2. **Smart Type Matching:**
   - Items are only deposited into a chest if that chest **already contains** at least one stack of that item type. You will never have random items scattered into unrelated chests.
3. **Hotbar Protection:**
   - Your quick-action hotbar slots (weapons, pickaxes, hatchets, active potions, food) are protected and will never be deposited.
4. **Stack Prioritization & Overflow Control:**
   - Always fills existing incomplete stacks first.
   - Optional `OverflowToEmptySlots` setting allows starting a new stack in an empty slot if the chest is designated for that item.
5. **Multi-Container Support:**
   - Works with all player-crafted chests, small chests, iron chests, personal bank chests, and specialized storages (Ore Storage, Lumber Storage).
6. **Audio & Visual Feedback:**
   - Plays the native chest rattle sound effect upon successful deposit.
   - Displays a summary message detailing how many items and chests were updated.

---

## Configuration

You can customize the mod's behavior at the top of `QuickStack/scripts/main.lua`:

```lua
local Config = {
    Key = Key.G,                  -- Hotkey to trigger Quick Stack
    Modifier = nil,               -- Optional modifier: e.g. ModifierKey.CONTROL
    SearchRadius = 2500.0,        -- Search distance in Unreal units (2500 uu = 25m)
    ProtectHotbar = true,         -- Protect active hotbar slots (default: true)
    OverflowToEmptySlots = false, -- Allow starting new stacks in chest if type already exists
    PlaySound = true,             -- Audio feedback
    ShowNotification = true,      -- In-game notification feedback
    DebugLog = true               -- Output actions to UE4SS console log
}
```

---

## Installation

### Method 1: Using the Suite Deployer Script
Run PowerShell from the root repository directory:
```powershell
.\deploy.ps1 -Tool QuickStack
```

### Method 2: Manual Installation
1. Copy the `QuickStack` directory to your game's UE4SS mods folder:
   ```
   <GameRoot>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\QuickStack
   ```
2. Open `<GameRoot>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\mods.txt` and add:
   ```ini
   QuickStack : 1
   ```
3. Start or reload the game!
