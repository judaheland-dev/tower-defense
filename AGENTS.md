# Tower Defense PVP/PVE - Agent Instructions

This is a **Godot 4.6 / GDScript** project. Every scene node is built entirely in `_ready()` in code — there are no `.tscn` files to edit, and no Godot editor is required.

## Project Structure

```
autoloads/          GameManager, InputManager, AudioManager, EconomyManager
scenes/
  main_menu/        MainMenu.gd (root main_menu scene)
  game/             Game.gd (root game scene), PlayerWorld.gd
systems/            RoundManager.gd, PathfindingController.gd, SimpleAI.gd
resources/          Resource .gd class files + .tres instance data
  towers/           *.tres tower definitions
  mobs/             *.tres mob definitions
  upgrades/         *.tres upgrade definitions
assets/
  models/           GLB 3D models (Tower Defense Kit, Mini Dungeon)
  audio/            .ogg sound files
  fonts/            .ttf fonts
```

## Game Overview

Two-player PVP (or PVE vs AI) tower defense. Each round has two phases:
- **PREP phase** (~60s): both players simultaneously place walls/towers on their own grid and purchase mobs to send at the opponent.
- **PLAY phase** (~90s or until clear): purchased mobs spawn on the opponent's field and navigate the maze to the base exit. Towers auto-attack. Mobs that reach the exit deal HP damage to that player.

Round ends -> income is distributed -> next PREP phase. Player HP <= 0 = game over.

## Screen Layout

1920x1080 viewport split horizontally:
- Top 512px: P1 SubViewport + P1 HUD strip (CanvasLayer layer=1)
- Center 56px: shared status bar (CanvasLayer layer=10) - timer, phase, income
- Bottom 512px: P2 SubViewport + P2 HUD strip (CanvasLayer layer=2)

Each SubViewport has its own Camera3D (orthographic, isometric: position=(10,14,10), look_at origin, size=18).

## Grid & Coordinate System

- Each player's field: 18 columns x 14 rows of GridMap cells
- Grid origin is at world (0,0,0) — column 0-17 in X, row 0-13 in Z
- GridMap cell size: 2x1x2 (X, Y, Z) units — tiles are flat with 1-unit height slot
- Spawn point: column 9, row 0 (north edge center)
- Base exit: column 9, row 13 (south edge center)
- Walls/towers occupy cells; mobs navigate across the grid surface
- Navigation mesh is baked after every grid change; placement is rejected if it blocks ALL paths

## Critical GDScript Rules

- **Typed arrays are invariant.** `Array[MobNode]` cannot be passed where `Array[Node]` is expected. Build explicitly:
  ```gdscript
  var nodes: Array[Node] = []
  for m in _mobs:
      nodes.append(m)
  ```
- **`Array.all()` does not exist in GDScript.** Use a `for` loop instead.
- **Pause-safe UI nodes** must set `process_mode = Node.PROCESS_MODE_ALWAYS` in `_ready()`.  Set it on the CanvasLayer AND on individual Buttons.
- **`@onready` vars** only work when the node is in the scene tree. When building nodes in code, add children before calling `add_child(parent)`, or wire signals after `parent.add_child(node)`.
- **Em-dashes (`-`) in GDScript** cause parse errors. Always use a hyphen-minus (`-`).
- **Calling methods on a statically-typed CanvasLayer variable will fail** if the method is defined in a script attached at runtime. Use `.call("method_name", args)` instead.
- **`ColorRect` backgrounds block mouse events** (`MOUSE_FILTER_STOP`). Purely-visual backgrounds behind buttons must use `bg.mouse_filter = Control.MOUSE_FILTER_IGNORE`.
- **NavigationRegion3D baking is async.** Call `bake_navigation_mesh()` and await the `bake_finished` signal before querying paths.
- **SubViewport input.** Mouse/touch input is NOT forwarded to SubViewports by default. Use `SubViewportContainer` with `stretch=true` for correct input routing. Grid cursor is driven by keyboard/gamepad actions, not mouse.

## CanvasLayer Render Order

| CanvasLayer | layer value |
|---|---|
| P1 HUD | 1 |
| P2 HUD | 2 |
| Shared Status Bar | 10 |
| Shop UI (P1) | 15 |
| Shop UI (P2) | 16 |
| Pause overlay | 20 |
| Game Over UI | 25 |

## Collision Layers (3D)

| Layer | Who uses it |
|-------|-------------|
| 1 | Static terrain / walls / GridMap cells |
| 2 | Towers |
| 3 | Mobs (P1 field) |
| 4 | Mobs (P2 field) |
| 5 | Projectiles |

- Towers target mobs via Area3D: `collision_layer=0`, `collision_mask=3` (P1 tower) or `collision_mask=4` (P2 tower)
- Projectiles: `collision_layer=5`, `collision_mask` matches the mob layer for that field

## Input Actions (defined in project.godot)

| Action | P1 | P2 |
|--------|----|----|
| cursor move | WASD + gamepad-0 left stick/dpad | Arrow keys + gamepad-1 left stick/dpad |
| confirm/place | Space or E + gamepad-0 A | Enter + gamepad-1 A |
| cancel/deselect | Q + gamepad-0 B | Backspace + gamepad-1 B |
| open shop | Tab + gamepad-0 Y | F1 + gamepad-1 Y |
| sell selected | F + gamepad-0 X | End + gamepad-1 X |
| pause | Escape + any gamepad Start | (same) |

## Economy

- Round 1: 150 coins each player
- Base income per round: `100 + round_number * 10`
- Speed bonus pool: `50 + round_number * 5` — awarded proportional to time remaining when last mob on your side dies
- Coins are per-player and never shared
- Each player always gets 1 free basic mob auto-queued if they purchased none

## Asset Loading Pattern

Always use a fallback when loading 3D models or audio:
```gdscript
const MODEL_PATH := "res://assets/models/tower_basic.glb"

func _load_mesh() -> void:
    if ResourceLoader.exists(MODEL_PATH):
        var scene: PackedScene = load(MODEL_PATH)
        var inst := scene.instantiate()
        add_child(inst)
    else:
        # placeholder: colored box
        var mesh_inst := MeshInstance3D.new()
        mesh_inst.mesh = BoxMesh.new()
        add_child(mesh_inst)
```

## Pathfinding Pattern

Each PlayerWorld owns one NavigationRegion3D. After any grid change:
```gdscript
# PathfindingController.gd
func bake_and_validate() -> bool:
    _nav_region.bake_navigation_mesh()
    await _nav_region.bake_finished
    return _has_open_path()

func _has_open_path() -> bool:
    var map := _nav_region.get_navigation_map()
    var start := NavigationServer3D.map_get_closest_point(map, _spawn_world_pos)
    var end := NavigationServer3D.map_get_closest_point(map, _exit_world_pos)
    var path := NavigationServer3D.map_get_path(map, start, end, true)
    return path.size() >= 2
```

## GameManager States

```
MENU -> PREP -> PLAY -> ROUND_OVER -> PREP  (loop)
                                   -> GAME_OVER (any player HP <= 0)
```

## Audio

AudioManager is an autoload with 16-slot pooled SFX and a single music player (same pattern as reference game). Use `AudioManager.play_sfx(stream)` and `AudioManager.play_music(stream)`.

## Export

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --export-release "macOS"
```
Recipients on macOS must run: `xattr -rd com.apple.quarantine TowerDefense.app`
