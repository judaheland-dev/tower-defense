extends Resource
class_name TowerData

## Defines a placeable tower or wall type.

enum TowerType {
	WALL,       # blocker only, no attack
	ARROW,      # fast single-target ranged
	CANNON,     # slow AoE splash damage
	SLOW,       # reduces mob speed in range
	SNIPER,     # very long range, high single-target damage
}

@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var tower_type: TowerType = TowerType.WALL
@export var cost: int = 50
@export var sell_value: int = 25  # coins returned on sell

# Combat stats (ignored for WALL)
@export var range_units: float = 4.0      # detection radius in world units
@export var damage: float = 10.0
@export var attack_speed: float = 1.0     # attacks per second
@export var splash_radius: float = 0.0    # 0 = single target
@export var slow_amount: float = 0.0      # fraction speed reduction (0-1), for SLOW type

@export var max_health: float = 100.0     # walls can be destroyed by attacking mobs

# Upgrade chain: array of TowerData resource IDs that this tower can be upgraded to
@export var upgrade_ids: Array[StringName] = []

# Visual
@export var icon_color: Color = Color(0.5, 0.5, 0.5)
@export var model_path: String = ""       # path to GLB scene
@export var model_scale: float = 1.0
