extends Resource
class_name TrapData

## Defines a placeable ground trap that affects mobs walking over it.

enum TrapType {
	MUD,         # slows mobs passing over
	SPIKE_PIT,   # burst damage on entry
	TAR_PIT,     # heavy slow, no damage
	LAVA,        # damage per second while on tile
	POISON_BOG,  # DoT + reduces healing received
	AMPLIFIER,   # mobs on tile take increased damage from towers
	GOLD_MINE,   # passive income each round, no combat effect
}

@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var trap_type: TrapType = TrapType.MUD
@export var cost: int = 25
@export var sell_value: int = 12

# Effect stats
@export var slow_amount: float = 0.0          # fraction speed reduction (0-1), for MUD/TAR_PIT
@export var damage_per_second: float = 0.0    # DoT while mob is on tile (LAVA, POISON_BOG)
@export var burst_damage: float = 0.0         # one-time damage on entry (SPIKE_PIT)
@export var damage_amplify: float = 0.0       # extra damage multiplier from towers (AMPLIFIER)
@export var heal_reduction: float = 0.0       # fraction reduction to incoming heals (POISON_BOG)
@export var income_per_round: int = 0         # passive coins per round (GOLD_MINE)

# Durability: 0 = permanent, >0 = breaks after N mob activations
@export var max_charges: int = 0

# Visual
@export var icon_color: Color = Color(0.5, 0.5, 0.5)
@export var model_path: String = ""
@export var model_scale: float = 1.0
@export var texture_path: String = ""  # 2D sprite texture (flat on ground), used instead of model_path if set
