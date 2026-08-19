package delta_core

import heightfield "../../engine/terrain/heightfield"
import sparse "../../engine/terrain/sparse"
import "core:fmt"
import "core:math"
import "core:os"

WORLD_SAVE_PATH :: "saves/delta_core_mvp.world"

World :: struct {
	terrain:          Natural_Terrain,
	cache:            heightfield.Cache,
	modifications:    sparse.World,
	loaded_from_disk: bool,
}

create_demo_modifications :: proc(world: ^World) {
	voxel_size := world.modifications.voxel_size
	// A carved shaft proves that procedural solidity can be overridden without
	// materializing the surrounding terrain.
	for x in -3 ..= 3 {
		for z in -3 ..= 3 {
			world_x := f32(x) * voxel_size + 30
			world_z := f32(z) * voxel_size
			surface := sample_natural_terrain(&world.terrain, world_x, world_z).height
			for y in -5 ..= 3 {
				position := [3]f32{world_x, surface + f32(y) * voxel_size, world_z}
				sparse.set_world_position(&world.modifications, position, .FORCE_EMPTY)
			}
		}
	}
	// A detached solid block proves the inverse override above the heightfield.
	block_center := [2]f32{55, 12}
	block_surface := sample_natural_terrain(&world.terrain, block_center.x, block_center.y).height
	for x in -2 ..= 2 {
		for y in 0 ..= 4 {
			for z in -2 ..= 2 {
				position := [3]f32 {
					block_center.x + f32(x) * voxel_size,
					block_surface + 8 + f32(y) * voxel_size,
					block_center.y + f32(z) * voxel_size,
				}
				sparse.set_world_position(&world.modifications, position, .FORCE_SOLID, 1)
			}
		}
	}
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

initialize_world :: proc(world: ^World, config: World_Config) -> bool {
	world^ = {}
	terrain, modifications, loaded := load_world_data(WORLD_SAVE_PATH)
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
		create_demo_modifications(world)
		if !os.is_dir("saves") && os.make_directory_all("saves") != nil {
			sparse.destroy(&world.modifications)
			destroy_world_plan(&world.terrain.plan)
			return false
		}
		if !save_world_data(WORLD_SAVE_PATH, &world.terrain, &world.modifications) {
			sparse.destroy(&world.modifications)
			destroy_world_plan(&world.terrain.plan)
			return false
		}
	}
	cache_config := heightfield.Cache_Config {
		level_count             = 3,
		sample_count            = world.terrain.config.cache_sample_count,
		spacing                 = world.terrain.config.cache_lod_spacing,
		recenter_interval_cells = 16,
	}
	if !heightfield.init(&world.cache, cache_config) {
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
	return heightfield.update(
		&world.cache,
		heightfield_source(&world.terrain),
		{camera_position.x, camera_position.z},
	)
}

save_world :: proc(world: ^World) -> bool {
	return save_world_data(WORLD_SAVE_PATH, &world.terrain, &world.modifications)
}

destroy_world :: proc(world: ^World) {
	heightfield.destroy(&world.cache)
	sparse.destroy(&world.modifications)
	destroy_world_plan(&world.terrain.plan)
	world^ = {}
}

spawn_camera_position :: proc(world: ^World) -> [3]f32 {
	spawn := world.terrain.plan.spawn
	height := sample_natural_terrain(&world.terrain, spawn.x, spawn.y).height
	return {spawn.x - 120, height + 65, spawn.y}
}

biome_at_camera :: proc(world: ^World, position: [3]f32) -> Biome {
	return(
		sample_plan_field(&world.terrain.plan, world.terrain.config, position.x, position.z).biome \
	)
}

radial_distance :: proc(position: [3]f32) -> f32 {
	return math.sqrt(position.x * position.x + position.z * position.z)
}
