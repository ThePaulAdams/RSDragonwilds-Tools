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
| **`[F8]`** or **`[Insert]`** | **Toggle Mod Menu** | Opens or closes the in-game toolkit dashboard overlay anytime during gameplay. |
| **Pause Menu** | **"TOOLKIT MODS" button** | Custom button inside the ESC pause menu. Click it to display the overlay. |

---

## Included Toolkit Mods Displayed

1. **OSRS Minimap** (`OSRSMinimap`)
   - `[F6]` Toggle Minimap
   - `[F9]` Toggle Resource Icons
2. **Quick Stack** (`QuickStack`)
   - `[G]` Quick Stack items to nearby chests within 10m
3. **Enhanced Reticle** (`EnhancedReticle`)
   - `[F4]` Toggle Reticle
   - `[F1]` Cycle Crosshair Color
   - `[F2]` Cycle Crosshair Size
4. **Telekinetic Woodcraft** (`TelekineticWoodcraft`)
   - `[E]` / `[V]` Grab & Carry Logs
   - `[Z]` Mass-gather logs into a tight woodpile
   - `[F6]` Cycle Splinter Spell AoE Radius
5. **Toolkit Mod Menu** (`ModMenu`)
   - `[F7]` Toggle Menu Overlay
   - In-game Pause Menu "TOOLKIT MODS" button

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
