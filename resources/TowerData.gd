extends Resource
class_name TowerData

## Defines a placeable tower or wall type.

enum TowerType {
	WALL,       # blocker only, no attack
	ARROW,      # fast single-target ranged
	CANNON,     # slow AoE splash damage
	SLOW,       # reduces mob speed in range
	SNIPER,     # very long range, high single-target damage
	TESLA,      # chain lightning - hits primary + chains to nearby mobs
	MORTAR,     # ground-targeted AoE - fires at predicted position
	BUFF,       # support aura - boosts nearby towers' damage/attack speed
	POISON,     # DoT - low direct damage, armor-ignoring damage over time
	ANTI_AIR,   # bonus damage multiplier vs flying mobs
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

# Chain lightning stats (TESLA)
@export var chain_count: int = 0           # number of chain bounces
@export var chain_range: float = 3.0       # max distance between chain targets
@export var chain_damage_falloff: float = 0.7  # damage multiplier per bounce

# Damage-over-time stats (POISON)
@export var dot_damage: float = 0.0        # damage per second of DoT
@export var dot_duration: float = 0.0      # seconds DoT lasts

# Buff aura stats (BUFF)
@export var buff_damage_bonus: float = 0.0       # flat damage boost to nearby towers
@export var buff_attack_speed_bonus: float = 0.0 # attack speed multiplier bonus
@export var buff_radius: float = 0.0             # aura radius for tower buff

# Anti-air stats
@export var flying_damage_multiplier: float = 1.0  # bonus damage vs flying mobs

@export var max_health: float = 100.0     # walls can be destroyed by attacking mobs

# Upgrade chain: array of TowerData resource IDs that this tower can be upgraded to
@export var upgrade_ids: Array[StringName] = []

# Visual
@export var icon_color: Color = Color(0.5, 0.5, 0.5)
@export var model_path: String = ""       # path to GLB scene
@export var model_scale: float = 1.0
