package delta_core

import "core:math"

Feature_Requirement :: struct {
	kind:               World_Feature_Kind,
	count:              u32,
	minimum_from_spawn: f32,
	wall_clearance:     f32,
	minimum_spacing:    f32,
	allowed_biomes:     [5]bool,
}

required_feature_requirements :: proc() -> [3]Feature_Requirement {
	return {
		{
			kind = .CORE_RELAY,
			count = 1,
			minimum_from_spawn = 900,
			wall_clearance = 1_400,
			minimum_spacing = 1_200,
			allowed_biomes = {true, true, false, false, false},
		},
		{
			kind = .ANCIENT_REACTOR,
			count = 1,
			minimum_from_spawn = 1_800,
			wall_clearance = 1_000,
			minimum_spacing = 1_800,
			allowed_biomes = {true, true, true, false, false},
		},
		{
			kind = .ORBITAL_OBSERVATORY,
			count = 1,
			minimum_from_spawn = 2_400,
			wall_clearance = 800,
			minimum_spacing = 2_000,
			allowed_biomes = {false, true, false, true, true},
		},
	}
}

feature_constraints_pass :: proc(
	position: [2]f32,
	requirement: Feature_Requirement,
	placed: []World_Feature,
	plan: ^World_Plan,
	config: World_Config,
	ignore_id: u64 = 0,
) -> bool {
	from_spawn := position - plan.spawn
	spawn_distance := math.sqrt(from_spawn.x * from_spawn.x + from_spawn.y * from_spawn.y)
	if spawn_distance < requirement.minimum_from_spawn ||
	   spawn_distance > config.crater_radius - requirement.wall_clearance {
		return false
	}
	field := sample_plan_field(plan, config, position.x, position.y)
	if !requirement.allowed_biomes[int(field.biome)] {
		return false
	}
	for feature in placed {
		if ignore_id != 0 && feature.id == ignore_id {
			continue
		}
		delta := position - feature.position
		if delta.x * delta.x + delta.y * delta.y <
		   requirement.minimum_spacing * requirement.minimum_spacing {
			return false
		}
	}
	return true
}

try_place_requirement :: proc(
	features: ^[dynamic]World_Feature,
	requirement: Feature_Requirement,
	plan: ^World_Plan,
	config: World_Config,
	seed: u64,
) -> bool {
	for instance: u32 = 0; instance < requirement.count; instance += 1 {
		placed := false
		for candidate: u64 = 0; candidate < 512; candidate += 1 {
			stream := candidate + u64(instance) * 512 + u64(requirement.kind) * 4_096
			angle := random_01(seed, stream * 3) * math.TAU
			minimum_radius := requirement.minimum_from_spawn
			maximum_radius := config.crater_radius - requirement.wall_clearance
			radius := lerp_f32(
				minimum_radius,
				maximum_radius,
				math.sqrt(random_01(seed, stream * 3 + 1)),
			)
			position := [2]f32{math.cos(angle) * radius, math.sin(angle) * radius}
			if !feature_constraints_pass(position, requirement, features[:], plan, config) {
				continue
			}
			append(
				features,
				World_Feature {
					id = mix_u64(plan.generation_seed ~ stream ~ u64(requirement.kind)),
					kind = requirement.kind,
					position = position,
				},
			)
			placed = true
			break
		}
		if !placed {
			return false
		}
	}
	return true
}

place_optional_ruins :: proc(
	features: ^[dynamic]World_Feature,
	plan: ^World_Plan,
	config: World_Config,
) {
	requirement := Feature_Requirement {
		kind               = .RUIN,
		minimum_from_spawn = 500,
		wall_clearance     = 700,
		minimum_spacing    = 650,
		allowed_biomes     = {true, true, true, true, false},
	}
	seed := derive_seed(plan.generation_seed, 0x0F71_0A1)
	for index: u64 = 0; index < 12; index += 1 {
		angle := random_01(seed, index * 3) * math.TAU
		radius := lerp_f32(
			500,
			config.crater_radius - 700,
			math.sqrt(random_01(seed, index * 3 + 1)),
		)
		position := [2]f32{math.cos(angle) * radius, math.sin(angle) * radius}
		if feature_constraints_pass(position, requirement, features[:], plan, config) {
			append(
				features,
				World_Feature{id = mix_u64(seed ~ index), kind = .RUIN, position = position},
			)
		}
	}
}

place_world_features :: proc(plan: ^World_Plan, config: World_Config) -> bool {
	features := make([dynamic]World_Feature, context.allocator)
	defer delete(features)
	for requirement in required_feature_requirements() {
		if !try_place_requirement(&features, requirement, plan, config, plan.generation_seed) {
			return false
		}
	}
	place_optional_ruins(&features, plan, config)
	plan.world_features = make([]World_Feature, len(features))
	copy(plan.world_features, features[:])
	return true
}

validate_world_plan :: proc(plan: ^World_Plan, config: World_Config) -> bool {
	if plan.world_seed != config.seed ||
	   plan.resolution != config.plan_resolution ||
	   len(plan.cells) != int(plan.resolution * plan.resolution) ||
	   len(plan.ridges) == 0 ||
	   len(plan.terrain_features) == 0 {
		return false
	}
	requirements := required_feature_requirements()
	for requirement in requirements {
		count: u32
		for feature in plan.world_features {
			if feature.kind != requirement.kind {
				continue
			}
			count += 1
			if !feature_constraints_pass(
				feature.position,
				requirement,
				plan.world_features,
				plan,
				config,
				feature.id,
			) {
				return false
			}
		}
		if count < requirement.count {
			return false
		}
	}
	for index in 0 ..< len(plan.world_features) {
		for other in index + 1 ..< len(plan.world_features) {
			if plan.world_features[index].id == plan.world_features[other].id {
				return false
			}
		}
	}
	return true
}
