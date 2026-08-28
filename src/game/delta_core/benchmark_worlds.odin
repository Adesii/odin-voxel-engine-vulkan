package delta_core

import heightfield "../../engine/terrain/heightfield"
import voxel_terrain "../../engine/terrain/voxel"

benchmark_world_plan :: proc(config: World_Config) -> (World_Plan, bool) {
	if !validate_world_config(config) || config.world_type == .DELTA_CORE {
		return {}, false
	}
	plan := World_Plan {
		world_seed         = config.seed,
		generation_seed    = derive_seed(config.seed, u64(config.world_type) + 1),
		generation_attempt = 0,
		resolution         = config.plan_resolution,
		spawn              = {0, 0},
	}
	plan.cells = make([]World_Plan_Cell, plan.resolution * plan.resolution)
	biome := Biome.BARREN_PLAINS
	roughness: f32
	switch config.world_type {
	case .FLAT:
	case .NOISE:
		biome = .ROLLING_WASTES
		roughness = 1
	case .STRESS_TEST:
		biome = .BADLANDS
		roughness = 1
	case .DELTA_CORE:
		return {}, false
	}
	for &cell in plan.cells {
		cell.biome = biome
		cell.roughness = roughness
	}
	return plan, true
}

sample_benchmark_terrain :: proc(
	terrain: ^Natural_Terrain,
	x, z: f32,
) -> heightfield.Sample {
	config := terrain.config
	height := config.base_elevation
	biome := Biome.BARREN_PLAINS
	switch config.world_type {
	case .FLAT:
	case .NOISE:
		broad := (fbm_2d(derive_seed(config.seed, 0xB301), x / 18, z / 18, 4) - 0.5) * 2
		fine := (value_noise_2d(derive_seed(config.seed, 0xB302), x / 1.5, z / 1.5) - 0.5) * 2
		height += broad * 10 + fine * 2.5
		biome = .ROLLING_WASTES
	case .STRESS_TEST:
		biome = .BADLANDS
	case .DELTA_CORE:
		return {}
	}
	return {
		height = height,
		material = u32(biome),
	}
}

sample_benchmark_voxel :: proc(
	terrain: ^Natural_Terrain,
	voxel: [3]i32,
	position: [3]f32,
	column: voxel_terrain.Column_Sample,
) -> voxel_terrain.Material_Id {
	if terrain.config.world_type == .STRESS_TEST {
		occupied := (u32(voxel.x) ~ u32(voxel.y) ~ u32(voxel.z)) & 1 == 0
		if !occupied {
			return voxel_terrain.AIR
		}
		if position.y >= column.surface_height - 1 {
			return material_id(.SURFACE_ROCK)
		}
		return material_id(.ROCK)
	}
	if position.y > column.surface_height {
		return voxel_terrain.AIR
	}
	if column.surface_height - position.y <= 0.75 {
		return column.surface_material
	}
	return column.subsurface_material
}
