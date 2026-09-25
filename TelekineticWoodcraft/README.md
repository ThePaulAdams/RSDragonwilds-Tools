# Telekinetic Woodcraft

A quality-of-life magic & gathering mod for **RuneScape: Dragonwilds** that gives the player telekinetic control over fallen tree logs. Never chase scattered logs down a hill or miss with the **Splinter** spell again.

---

## Features

### 1. Telekinetic Log Drag & Carry (Single Log)
* Aim at any fallen tree trunk / log (`BP_SplittableLog_Ash_C`, `BP_Log_Ash_C`, Oak, Willow, Maple, Yew, Magic, etc.) within 8 meters.
* Press **`E`** (or dedicated **`V`**) to lift the log telekinetically.
* The log floats smoothly in front of your camera, tracking your view and movement without clipping or shoving your character.
* Walk to your designated chopping pile, press **`E`** or **`V`** again, and the log settles gently onto the ground.

### 2. Log Magnet: Mass Telekinetic Gathering
* Press **`Z`** to send out an arcane gathering pulse in a 50-meter radius.
* Automatically vacuums **all** fallen logs, splittable trunks, and felled trees across all species (Ash, Oak, Willow, Maple, Yew, Magic, etc.) directly in front of you.
* Arranges logs in a neat, non-overlapping parallel lumber yard stack (perpendicular to your line of sight) with safe ground clearance.
* Triggers the native `PlayPileThemUpFX` particle effects for authentic audio-visual feedback.
* Employs zero-momentum teleportation (`bTeleportPhysics = true`) and gentle rigid-body sleep to prevent Chaos physics collisions or logs launching into orbit.

### 3. Splinter AoE Radius Multiplier
* Press **`F6`** to cycle the **Splinter** utility spell's area-of-effect radius:
  * **1.0x**: Vanilla Radius
  * **2.5x**: Adept Radius (covers wide clearing)
  * **5.0x**: Archmage Giant Radius (shatters everything in sight)

---

## Controls Quick Reference

| Keybind | Action | Description |
|---|---|---|
| **`E`** | **Contextual Grab / Place** | Grabs targeted log if looking at one; places held log if carrying. If not looking at a log, normal game interaction (loot, talk, open) occurs uninterrupted. |
| **`V`** | **Dedicated Grab / Place** | Dedicated toggle key for grabbing or dropping logs. |
| **`Z`** | **Log Magnet (Mass Gather)** | Vacuums all fallen logs & trunks within 50m into a neat, flat stack in front of you. |
| **`F6`** | **Cycle Splinter Radius** | Multiplies the explosion radius of the Splinter spell (1x $\to$ 2.5x $\to$ 5x). |

---

## Architecture & Stability
* **Comprehensive Species Blueprint Indexing:** Explicitly scans every tree species class (`BP_SplittableLog_<Species>_C`, `BP_Log_<Species>_C`, `BP_FelledTree_<Species>_C`) overcoming UE4SS's exact string matching behavior.
* **Teleport Physics Safety:** Instant repositioning uses `bTeleport = true` with zeroed linear/angular velocity to eliminate physics slingshot effects and lag spikes.
* **Game Thread Safety:** All actor transforms and UObject interactions run strictly on the game thread via `ExecuteInGameThread` and `LoopInGameThreadWithDelay`.
* **Zero Polling Overhead:** The carry positioning loop idles and self-cancels immediately when not actively holding an object.
