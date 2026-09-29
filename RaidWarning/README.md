# RaidWarning

Shows an on-screen warning when enemies gather at your base, wherever you are on the map.

## Behaviour
- "Your base" is anywhere within 60m of one of your chests or crates.
- Two or more non-player characters whose class name contains goblin, warband, raider or bandit raise the alarm, once per 2 minutes.
- If you're already at the base it only logs, it doesn't pop up.
- Every non-player class seen near your base is logged once as `[DISCOVERY]`, so the hostile list can be tuned (`HostilePatterns`).

## Status
Untested in game. It uses only engine calls (`FindAllOf("Character")`, `IsPlayerControlled`). Goblins are `BP_AI_MeleeGoblin_Character_C` / `BP_AI_RuntGoblin_Character_C` in the object dump, which the "goblin" pattern matches. It can only see what the game has loaded: when you are far enough away that your base is unloaded, no warning can fire.
