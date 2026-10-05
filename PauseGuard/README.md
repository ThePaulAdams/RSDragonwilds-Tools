# PauseGuard for RuneScape: Dragonwilds

**PauseGuard** is an anti-freeze, performance optimization mod for *RuneScape: Dragonwilds*.

## The Problem Solved
In vanilla *RuneScape: Dragonwilds*, when the player pauses the game for an extended period of time (e.g. going AFK, eating lunch, or leaving the game overnight), the game's internal **SPUD (Steve's Persistent Unreal Data)** persistence engine continues attempting background state saves every 5 minutes (`dom.StateSaveFrequencyMins`).

Because the world is paused, these repeated saves generate a massive backlog of incremental world-partition cell caches (`SpudCache/*.lvl`) and bloat memory up to 10+ GB. When the player finally unpauses, the game engine freezes for **5 to 15+ minutes** (or indefinitely) on a single CPU core while the persistence engine struggles to compact and prune deprecated level data, displaying a stuck "Saving..." indicator.

## What PauseGuard Does
1. **Intelligent Auto-Save Throttling**:
   - When you pause, PauseGuard lets the initial clean save commit safely.
   - It then automatically sets `dom.StateSaveFrequencyMins 0`, suspending redundant background saves while you are in menus.
   - When you unpause, it instantly restores `dom.StateSaveFrequencyMins 5`, resuming normal active auto-saves without any backlog!
2. **Global Mod Hibernation Coordination**:
   - Publishes `_G.PauseGuard_IsPaused` so other mods (OSRSMinimap, AutoHarvest, CustomBuilds) sleep their background timers and do not spam hundreds of thousands of game-thread closures.
3. **On-Demand Manual Save**:
   - Press **Shift + F10** at any time to execute an immediate, safe manual save.

## Installation
Deploy into your UE4SS `Mods/` directory:
```
RSDragonwilds\Binaries\Win64\ue4ss\Mods\PauseGuard
```
Enable in `mods.txt`:
```
PauseGuard : 1
```
