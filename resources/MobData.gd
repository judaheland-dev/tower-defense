extends Resource
class_name MobData

## Defines a mob type that can be purchased and sent against an opponent.

@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var cost: int = 20

# Base stats
@export var max_health: float = 30.0
@export var move_speed: float = 3.0       # world units per second
@export var armor: float = 0.0            # flat damage reduction
@export var base_damage: float = 1.0      # HP damage dealt to opponent when reaching exit
@export var bounty: int = 5               # coins awarded to the defending player on kill

# Behavior flags
@export var attacks_defenses: bool = false       # stops at walls/towers in range and attacks them
@export var is_flying: bool = false              # ignores walls; navigates directly to exit
@export var heals_nearby_allies: bool = false    # emits heal aura to mobs within heal_radius
@export var heal_rate: float = 0.0               # HP/s healed to nearby allies
@export var heal_radius: float = 2.0
@export var buffs_nearby_allies: bool = false    # speed or armor buff aura
@export var buff_speed_bonus: float = 0.0        # added to ally move_speed
@export var buff_armor_bonus: float = 0.0        # added to ally armor
@export var buff_radius: float = 2.0
@export var debuffs_nearby_towers: bool = false  # slows attack rate of towers in range
@export var debuff_attack_slow: float = 0.5      # fraction reduction to tower attack_speed
@export var debuff_radius: float = 2.0

# Swarm
@export var spawn_count: int = 1                 # how many mob instances to spawn per purchase

# Visual
@export var icon_color: Color = Color(0.5, 0.5, 0.5)
@export var model_path: String = ""
@export var model_scale: float = 1.0
