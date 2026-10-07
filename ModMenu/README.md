# RSDragonwilds-Tools: Toolkit Mod Menu (`ModMenu`)

An in-game HUD status dashboard and hotkey reference overlay for **RuneScape: Dragonwilds**.

---

## Features

- **In-Game Mod Dashboard**: Displays a comprehensive status card on your screen showing all active toolkit mods and their current states (`[ENABLED]` / `[DISABLED]`).
- **Live Controls & Hotkey Guide**: Quick reference for every mod's keybinds and features while playing without having to alt-tab or check documentation.
- **Dynamic Config Detection**: Reads `mods.txt` in real-time each time the menu is toggled, instantly reflecting any changes.
- **Runescape-Themed Slate Styling**: Clean, high-contrast dark card with Old School RuneScape warm gold typography and subtle shadow for legibility.
- **Zero-Performance Impact**: Lightweight UMG Slate widget; completely dormant when collapsed.

---

## Controls

| Keybind | Action | Description |
| :--- | :--- | :--- |
| **`[ESC]`** | **Pause Game** | Pausing the game automatically presents the Toolkit Mod Dashboard on the right side of the screen. |
| **`[Ctrl+F8]`** | **Toggle Mod Menu** | Opens or closes the in-game toolkit dashboard overlay anytime during active gameplay. |

---

## Included Toolkit Mods Displayed

1. **Custom Builds** (`CustomBuilds`)
   - `[N]` Open 5,100+ Model Catalog Browser
   - `[E]` Talk / interact with companion NPCs (Doric, Cook, Wise Old Man, Domri...)
   - `[1-4]` Dialogue choice selections
2. **OSRS Minimap** (`OSRSMinimap`)
   - `[F6]` Toggle Minimap
   - `[F9]` Toggle Resource Icons & Monster Radar Dots
   - `[F8]` Toggle Shape (Circular Compass <-> Framed Tablet)
3. **Quick Stack** (`QuickStack`)
   - `[G]` (Tap at Base) Auto-sort chests into categories & 48-slot upgrade
   - `[G]` (Hold in Wild) 40m continuous AoE vacuum & crop harvesting
   - Hover + `[Hold G]` Targeted QuickPull from nearby chests
   - `[Ctrl+G]` / `[Shift+G]` 150m Base Relocation Virtual Crate Pack / Unpack
4. **Pause Guard** (`PauseGuard`)
   - Automatic SPUD auto-save freeze suppression during AFK / menus
   - `[Shift+F10]` Instant manual safe save
5. **Auto Harvest** (`AutoHarvest`)
   - `[F11]` Toggle hands-free crop/bush foraging
6. **Enhanced Reticle** (`EnhancedReticle`)
   - `[F4]` Toggle Reticle
   - `[F1]` Cycle Crosshair Color (7 presets)
   - `[F2]` Cycle Crosshair Size (5 levels)
7. **Telekinetic Woodcraft** (`TelekineticWoodcraft`)
   - `[E]` / `[V]` Grab & Carry Logs
   - `[Z]` Mass-gather logs within 50m into a neat woodpile
   - `[Shift+F6]` Cycle Splinter Spell AoE Radius (1x, 2.5x, 5.0x)
8. **Auto Run** (`AutoRun`)
   - `[Num Lock]` Toggle continuous camera-forward autorun
9. **Toolkit Mod Menu** (`ModMenu`)
   - `[Ctrl+F8]` Toggle Menu Overlay
   - In-game ESC Pause Menu "TOOLKIT MODS" dashboard button

---

## Installation

Deploy via `deploy.ps1`:
```powershell
.\deploy.ps1 -Tool ModMenu
```
Or deploy all tools:
```powershell
.\deploy.ps1 -Tool All
```
