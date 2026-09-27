# AutoRun

Camera-oriented persistent autorun for *RuneScape: Dragonwilds*.

## Features
- **Seamless Autorun**: Press `[Num Lock]` to continuously run in your camera-facing direction.
- **Natural Cancellation**: Moving manually (`W`, `A`, `S`, `D`, arrow keys), clicking mouse buttons, opening menus (`ESC`, `TAB`, `M`, `I`), or jumping naturally disengages autorun.
- **Pure Input Injection**: Directly feeds `AddMovementInput` frame-by-frame on the game thread without faking OS keyboard state.

## Controls
| Action | Keybind | Description |
| :--- | :--- | :--- |
| **Toggle Autorun** | `[Num Lock]` | Toggle continuous camera-forward running |
| **Cancel Autorun** | `[W]`, `[A]`, `[S]`, `[D]`, `[LMB]`, `[RMB]`, `[ESC]`, `[M]`, `[I]` | Any movement or menu input immediately cancels autorun |
