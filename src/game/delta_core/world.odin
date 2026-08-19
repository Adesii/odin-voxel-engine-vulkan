package delta_core

import heightfield "../../engine/terrain/heightfield"
import "core:math"

Natural_Terrain :: struct {
	config:         World_Config,
	plan:           World_Plan,
	ore_vein_start: [3]f32,
	ore_vein_end:   [3]f32,
}

crater_wall_height :: proc(terrain: ^Natural_Terrain, x, z: f32) -> f32 {
	config := terrain.config
	radial_distance := math.sqrt(x * x + z * z)
	perimeter_noise :=
		(fbm_2d(derive_seed(config.seed, 0xCA47E2), x / 3_200, z / 3_200, 3) - 0.5) * 2
	local_radius := config.crater_radius + perimeter_noise * config.crater_wall_width * 0.22
	wall_start := local_radius - config.crater_wall_width
	wall_amount := smoothstep_f32(wall_start, local_radius, radial_distance)
	wall_shape := wall_amount * wall_amount
	wall_variation := lerp_f32(
		0.82,
		1.18,
		value_noise_2d(derive_seed(config.seed, 0xA11), x / 1_800, z / 1_800),
	)
	return wall_shape * config.crater_wall_height * wall_variation
}

terrain_feature_height :: proc(plan: ^World_Plan, x, z: f32) -> f32 {
	height: f32
	for feature in plan.terrain_features {
		delta_x := x - feature.position.x
		delta_z := z - feature.position.y
		distance := math.sqrt(delta_x * delta_x + delta_z * delta_z)
		if distance > feature.radius * 1.25 {
			continue
		}
		normalized := distance / feature.radius
		switch feature.kind {
		case .CRATER:
			if normalized < 1 {
				bowl := 1 - normalized * normalized
				height -= feature.amplitude * bowl
			} else {
				rim := 1 - smoothstep_f32(1, 1.25, normalized)
				height += feature.amplitude * 0.18 * rim
			}
		case .BASIN:
			height -= feature.amplitude * (1 - smoothstep_f32(0.35, 1, normalized))
		}
	}
	return height
}

pack_terrain_color :: proc(r, g, b: u8) -> u32 {
	return u32(r) | u32(g) << 8 | u32(b) << 16 | 0xFF << 24
}

terrain_biome_color :: proc(biome: Biome) -> u32 {
	switch biome {
	case .BARREN_PLAINS:
		return pack_terrain_color(126, 107, 73)
	case .ROLLING_WASTES:
		return pack_terrain_color(117, 82, 55)
	case .OIL_BASIN:
		return pack_terrain_color(40, 38, 31)
	case .BADLANDS:
		return pack_terrain_color(132, 56, 32)
	case .MOUNTAIN:
		return pack_terrain_color(108, 108, 112)
	}
	return pack_terrain_color(255, 0, 255)
}

sample_natural_terrain :: proc(terrain: ^Natural_Terrain, x, z: f32) -> heightfield.Sample {
	config := terrain.config
	field := sample_plan_field(&terrain.plan, config, x, z)
	rolling_noise := (fbm_2d(derive_seed(config.seed, 0x7011), x / 900, z / 900, 4) - 0.5) * 2
	local_noise := (value_noise_2d(derive_seed(config.seed, 0xDE7A11), x / 110, z / 110) - 0.5) * 2
	rolling_height :=
		rolling_noise * config.rolling_terrain_height * field.roughness +
		local_noise * config.rolling_terrain_height * 0.12
	broad_height := field.elevation_bias * config.rolling_terrain_height * 1.8
	ridge_detail := lerp_f32(
		0.58,
		1,
		ridged_noise_2d(derive_seed(config.seed, 0xA017), x / 680, z / 680),
	)
	mountain_height :=
		math.pow(field.mountain_influence, 1.45) * config.mountain_height * ridge_detail
	biome_offset: f32
	switch field.biome {
	case .OIL_BASIN:
		biome_offset = -65
	case .BADLANDS:
		biome_offset = rolling_noise * 55
	case .ROLLING_WASTES:
		biome_offset = rolling_noise * 35
	case .MOUNTAIN:
		biome_offset = 35
	case .BARREN_PLAINS:
	}
	height :=
		config.base_elevation + broad_height + rolling_height + mountain_height + biome_offset
	height += terrain_feature_height(&terrain.plan, x, z)
	height += crater_wall_height(terrain, x, z)
	return {
		height = height,
		mountain_influence = field.mountain_influence,
		material = u32(field.biome),
		packed_color = terrain_biome_color(field.biome),
	}
}

heightfield_sample_proc :: proc(data: rawptr, x, z: f32) -> heightfield.Sample {
	return sample_natural_terrain(cast(^Natural_Terrain)data, x, z)
}

heightfield_source :: proc(terrain: ^Natural_Terrain) -> heightfield.Source {
	return {data = terrain, sample = heightfield_sample_proc}
}
