package delta_core

import "core:math"

Biome :: enum u32 {
	BARREN_PLAINS,
	ROLLING_WASTES,
	OIL_BASIN,
	BADLANDS,
	MOUNTAIN,
}

Terrain_Feature_Kind :: enum u32 {
	CRATER,
	BASIN,
}

Terrain_Feature :: struct {
	kind:      Terrain_Feature_Kind,
	position:  [2]f32,
	radius:    f32,
	amplitude: f32,
}

Mountain_Ridge :: struct {
	start:    [2]f32,
	end:      [2]f32,
	width:    f32,
	strength: f32,
}

World_Plan_Cell :: struct {
	biome:              Biome,
	elevation_bias:     f32,
	roughness:          f32,
	mountain_influence: f32,
}

World_Feature_Kind :: enum u32 {
	CORE_RELAY,
	ANCIENT_REACTOR,
	ORBITAL_OBSERVATORY,
	RUIN,
}

World_Feature :: struct {
	id:       u64,
	kind:     World_Feature_Kind,
	position: [2]f32,
}

World_Plan :: struct {
	world_seed:         u64,
	generation_seed:    u64,
	generation_attempt: u32,
	resolution:         i32,
	spawn:              [2]f32,
	cells:              []World_Plan_Cell,
	ridges:             []Mountain_Ridge,
	terrain_features:   []Terrain_Feature,
	world_features:     []World_Feature,
}

Plan_Field :: struct {
	biome:              Biome,
	elevation_bias:     f32,
	roughness:          f32,
	mountain_influence: f32,
}

destroy_world_plan :: proc(plan: ^World_Plan) {
	delete(plan.cells)
	delete(plan.ridges)
	delete(plan.terrain_features)
	delete(plan.world_features)
	plan^ = {}
}

plan_cell_position :: proc(config: World_Config, resolution, x, z: i32) -> [2]f32 {
	denominator := f32(resolution - 1)
	return {
		lerp_f32(-config.world_radius, config.world_radius, f32(x) / denominator),
		lerp_f32(-config.world_radius, config.world_radius, f32(z) / denominator),
	}
}

distance_to_segment :: proc(point, start, end: [2]f32) -> f32 {
	segment := end - start
	length_squared := segment.x * segment.x + segment.y * segment.y
	if length_squared <= 0.0001 {
		delta := point - start
		return math.sqrt(delta.x * delta.x + delta.y * delta.y)
	}
	from_start := point - start
	amount := clamp(
		(from_start.x * segment.x + from_start.y * segment.y) / length_squared,
		f32(0),
		f32(1),
	)
	nearest := start + segment * amount
	delta := point - nearest
	return math.sqrt(delta.x * delta.x + delta.y * delta.y)
}

ridge_influence_at :: proc(ridges: []Mountain_Ridge, position: [2]f32) -> f32 {
	influence: f32
	for ridge in ridges {
		distance := distance_to_segment(position, ridge.start, ridge.end)
		profile := 1 - smoothstep_f32(0, ridge.width, distance)
		influence = max(influence, profile * ridge.strength)
	}
	return clamp(influence, f32(0), f32(1))
}

build_ridges :: proc(config: World_Config, seed: u64) -> []Mountain_Ridge {
	result := make([]Mountain_Ridge, 3)
	for index in 0 ..< len(result) {
		angle := random_01(seed, u64(index * 7 + 0)) * math.TAU
		center_angle := random_01(seed, u64(index * 7 + 1)) * math.TAU
		center_radius :=
			config.crater_radius * lerp_f32(0.15, 0.55, random_01(seed, u64(index * 7 + 2)))
		center := [2]f32{math.cos(center_angle), math.sin(center_angle)} * center_radius
		direction := [2]f32{math.cos(angle), math.sin(angle)}
		length := config.crater_radius * lerp_f32(0.55, 1.05, random_01(seed, u64(index * 7 + 3)))
		result[index] = {
			start    = center - direction * length * 0.5,
			end      = center + direction * length * 0.5,
			width    = config.crater_radius * lerp_f32(0.05, 0.11, random_01(seed, u64(index * 7 + 4))),
			strength = lerp_f32(0.55, 1, random_01(seed, u64(index * 7 + 5))),
		}
	}
	return result
}

choose_biome :: proc(
	seed: u64,
	position: [2]f32,
	mountain_influence: f32,
	config: World_Config,
) -> Biome {
	if mountain_influence > 0.48 {
		return .MOUNTAIN
	}
	radial_distance := math.sqrt(position.x * position.x + position.y * position.y)
	if radial_distance > config.crater_radius - config.crater_wall_width * 0.55 {
		return .BADLANDS
	}
	field := value_noise_2d(seed, position.x / 2_600, position.y / 2_600)
	if field < 0.19 {
		return .OIL_BASIN
	}
	if field < 0.56 {
		return .BARREN_PLAINS
	}
	if field < 0.83 {
		return .ROLLING_WASTES
	}
	return .BADLANDS
}

build_plan_cells :: proc(plan: ^World_Plan, config: World_Config) {
	count := plan.resolution * plan.resolution
	plan.cells = make([]World_Plan_Cell, count)
	field_seed := derive_seed(plan.generation_seed, 0xC311)
	for z in 0 ..< plan.resolution {
		for x in 0 ..< plan.resolution {
			position := plan_cell_position(config, plan.resolution, x, z)
			mountain := ridge_influence_at(plan.ridges, position)
			broad := fbm_2d(field_seed, position.x / 4_800, position.y / 4_800, 3)
			roughness := value_noise_2d(
				derive_seed(field_seed, 17),
				position.x / 2_000,
				position.y / 2_000,
			)
			biome := choose_biome(field_seed, position, mountain, config)
			plan.cells[z * plan.resolution + x] = {
				biome              = biome,
				elevation_bias     = (broad - 0.5) * 2,
				roughness          = lerp_f32(0.35, 1, roughness),
				mountain_influence = mountain,
			}
		}
	}
}

build_terrain_features :: proc(plan: ^World_Plan, config: World_Config) {
	feature_count := 10
	plan.terrain_features = make([]Terrain_Feature, feature_count)
	seed := derive_seed(plan.generation_seed, 0xFEA7)
	for index in 0 ..< feature_count {
		angle := random_01(seed, u64(index * 5)) * math.TAU
		radius_from_center :=
			config.crater_radius *
			lerp_f32(0.12, 0.72, math.sqrt(random_01(seed, u64(index * 5 + 1))))
		kind: Terrain_Feature_Kind = .CRATER
		amplitude := lerp_f32(55, 190, random_01(seed, u64(index * 5 + 3)))
		if index % 4 == 0 {
			kind = .BASIN
			amplitude = lerp_f32(30, 80, random_01(seed, u64(index * 5 + 3)))
		}
		plan.terrain_features[index] = {
			kind      = kind,
			position  = {
				math.cos(angle) * radius_from_center,
				math.sin(angle) * radius_from_center,
			},
			radius    = lerp_f32(180, 620, random_01(seed, u64(index * 5 + 2))),
			amplitude = amplitude,
		}
	}
}

generate_candidate_plan :: proc(config: World_Config, attempt: u32) -> World_Plan {
	generation_seed := derive_seed(config.seed, u64(attempt) + 1)
	plan := World_Plan {
		world_seed         = config.seed,
		generation_seed    = generation_seed,
		generation_attempt = attempt,
		resolution         = config.plan_resolution,
		spawn              = {0, 0},
	}
	plan.ridges = build_ridges(config, derive_seed(generation_seed, 0xA11CE))
	build_plan_cells(&plan, config)
	build_terrain_features(&plan, config)
	return plan
}

generate_world_plan :: proc(config: World_Config) -> (World_Plan, bool) {
	if !validate_world_config(config) {
		return {}, false
	}
	for attempt in 0 ..< config.max_generation_attempts {
		plan := generate_candidate_plan(config, attempt)
		if place_world_features(&plan, config) && validate_world_plan(&plan, config) {
			return plan, true
		}
		destroy_world_plan(&plan)
	}
	return {}, false
}

sample_plan_field :: proc(plan: ^World_Plan, config: World_Config, x, z: f32) -> Plan_Field {
	if len(plan.cells) == 0 || plan.resolution < 2 {
		return {}
	}
	u :=
		clamp((x + config.world_radius) / world_diameter(config), f32(0), f32(1)) *
		f32(plan.resolution - 1)
	v :=
		clamp((z + config.world_radius) / world_diameter(config), f32(0), f32(1)) *
		f32(plan.resolution - 1)
	x0 := clamp(i32(math.floor(u)), 0, plan.resolution - 1)
	z0 := clamp(i32(math.floor(v)), 0, plan.resolution - 1)
	x1 := min(x0 + 1, plan.resolution - 1)
	z1 := min(z0 + 1, plan.resolution - 1)
	tx := smooth_curve(u - f32(x0))
	tz := smooth_curve(v - f32(z0))
	c00 := plan.cells[z0 * plan.resolution + x0]
	c10 := plan.cells[z0 * plan.resolution + x1]
	c01 := plan.cells[z1 * plan.resolution + x0]
	c11 := plan.cells[z1 * plan.resolution + x1]
	return {
		biome = plan.cells[i32(math.round(v)) * plan.resolution + i32(math.round(u))].biome,
		elevation_bias = lerp_f32(
			lerp_f32(c00.elevation_bias, c10.elevation_bias, tx),
			lerp_f32(c01.elevation_bias, c11.elevation_bias, tx),
			tz,
		),
		roughness = lerp_f32(
			lerp_f32(c00.roughness, c10.roughness, tx),
			lerp_f32(c01.roughness, c11.roughness, tx),
			tz,
		),
		mountain_influence = lerp_f32(
			lerp_f32(c00.mountain_influence, c10.mountain_influence, tx),
			lerp_f32(c01.mountain_influence, c11.mountain_influence, tx),
			tz,
		),
	}
}
