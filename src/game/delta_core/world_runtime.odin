package delta_core

import heightfield "../../engine/terrain/heightfield"
import sparse "../../engine/terrain/sparse"
import voxel_terrain "../../engine/terrain/voxel"
import "core:fmt"
import "core:math"
import "core:os"

DELTA_CORE_SAVE_PATH :: "saves/delta_core_mvp.world"
FLAT_SAVE_PATH :: "saves/benchmark_flat.world"
NOISE_SAVE_PATH :: "saves/benchmark_noise.world"
STRESS_TEST_SAVE_PATH :: "saves/benchmark_stress.world"

world_save_path :: proc(world_type: World_Type) -> string {
	switch world_type {
	case .DELTA_CORE:
		return DELTA_CORE_SAVE_PATH
	case .FLAT:
		return FLAT_SAVE_PATH
	case .NOISE:
		return NOISE_SAVE_PATH
	case .STRESS_TEST:
		return STRESS_TEST_SAVE_PATH
	}
	return DELTA_CORE_SAVE_PATH
}

World :: struct {
	terrain:          Natural_Terrain,
	cache:            heightfield.Cache,
	modifications:    sparse.World,
	voxels:           voxel_terrain.World,
	loaded_from_disk: bool,
}


world_fingerprint :: proc(world: ^World) -> u64 {
	fingerprint := mix_u64(
		world.terrain.plan.generation_seed ~ u64(world.terrain.plan.generation_attempt),
	)
	for feature in world.terrain.plan.world_features {
		fingerprint ~= mix_u64(feature.id ~ u64(feature.kind))
	}
	for index in 0 ..< len(world.terrain.plan.cells) {
		cell := world.terrain.plan.cells[index]
		fingerprint ~= mix_u64(u64(index) ~ (u64(cell.biome) << 32))
	}
	fingerprint ~= u64(world.modifications.modified_count) << 17
	return fingerprint
}

initialize_world :: proc(
	world: ^World,
	config: World_Config,
	representation: World_Representation_Config,
) -> bool {
	world^ = {}
	save_path := world_save_path(config.world_type)
	terrain, modifications, loaded := load_world_data(save_path)
	if loaded && terrain.config != config {
		destroy_world_plan(&terrain.plan)
		sparse.destroy(&modifications)
		loaded = false
	}
	if loaded {
		world.terrain = terrain
		world.modifications = modifications
		world.loaded_from_disk = true
	} else {
		plan, generated := generate_world_plan(config)
		if !generated {
			return false
		}
		world.terrain = {
			config = config,
			plan   = plan,
		}
		if !sparse.init(&world.modifications, config.modification_voxel_size) {
			destroy_world_plan(&world.terrain.plan)
			return false
		}
		if !os.is_dir("saves") && os.make_directory_all("saves") != nil {
			sparse.destroy(&world.modifications)
			destroy_world_plan(&world.terrain.plan)
			return false
		}
		if !save_world_data(save_path, &world.terrain, &world.modifications) {
			sparse.destroy(&world.modifications)
			destroy_world_plan(&world.terrain.plan)
			return false
		}
	}
	initialize_voxel_geology(&world.terrain)
	if !heightfield.init(&world.cache, representation.heightfield_cache) {
		sparse.destroy(&world.modifications)
		destroy_world_plan(&world.terrain.plan)
		return false
	}
	if !voxel_terrain.init(&world.voxels, representation.voxels) {
		heightfield.destroy(&world.cache)
		sparse.destroy(&world.modifications)
		destroy_world_plan(&world.terrain.plan)
		return false
	}
	heightfield.update(&world.cache, heightfield_source(&world.terrain), world.terrain.plan.spawn)
	fmt.printf(
		"World %s: seed=%v attempt=%v fingerprint=%016X features=%v terrain-features=%v sparse-bricks=%v sparse-cells=%v\n",
		world.loaded_from_disk ? "loaded" : "generated",
		world.terrain.config.seed,
		world.terrain.plan.generation_attempt,
		world_fingerprint(world),
		len(world.terrain.plan.world_features),
		len(world.terrain.plan.terrain_features),
		sparse.brick_count(&world.modifications),
		world.modifications.modified_count,
	)
	return true
}

stream_world :: proc(world: ^World, camera_position: [3]f32) -> bool {
	cache_changed := heightfield.update(
		&world.cache,
		heightfield_source(&world.terrain),
		{camera_position.x, camera_position.z},
	)
	voxel_terrain.update(
		&world.voxels,
		camera_position,
		voxel_source(&world.terrain),
		&world.modifications,
	)
	return cache_changed
}

save_world :: proc(world: ^World) -> bool {
	return save_world_data(
		world_save_path(world.terrain.config.world_type),
		&world.terrain,
		&world.modifications,
	)
}

destroy_world :: proc(world: ^World) {
	voxel_terrain.destroy(&world.voxels)
	heightfield.destroy(&world.cache)
	sparse.destroy(&world.modifications)
	destroy_world_plan(&world.terrain.plan)
	world^ = {}
}

spawn_camera_position :: proc(world: ^World) -> [3]f32 {
	spawn := world.terrain.plan.spawn
	position := spawn + [2]f32{-10, 4}
	height := sample_natural_terrain(&world.terrain, position.x, position.y).height
	return {position.x, height + 8, position.y}
}

biome_at_camera :: proc(world: ^World, position: [3]f32) -> Biome {
	return(
		sample_plan_field(&world.terrain.plan, world.terrain.config, position.x, position.z).biome \
	)
}

radial_distance :: proc(position: [3]f32) -> f32 {
	return math.sqrt(position.x * position.x + position.z * position.z)
}
