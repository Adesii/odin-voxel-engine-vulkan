package delta_core

import sparse "../../engine/terrain/sparse"
import "core:os"
import "core:testing"

@(test)
deterministic_world_plan_and_terrain :: proc(t: ^testing.T) {
	config := default_world_config(.SMALL, 0x1234_5678)
	first, first_ok := generate_world_plan(config)
	if !testing.expect(t, first_ok, "first deterministic world generation failed") {
		return
	}
	defer destroy_world_plan(&first)
	second, second_ok := generate_world_plan(config)
	if !testing.expect(t, second_ok, "second deterministic world generation failed") {
		return
	}
	defer destroy_world_plan(&second)
	testing.expect_value(t, first.generation_attempt, second.generation_attempt)
	testing.expect_value(t, first.generation_seed, second.generation_seed)
	testing.expect_value(t, len(first.cells), len(second.cells))
	testing.expect_value(t, len(first.world_features), len(second.world_features))
	for index in 0 ..< len(first.cells) {
		testing.expect_value(t, first.cells[index], second.cells[index])
	}
	for index in 0 ..< len(first.world_features) {
		testing.expect_value(t, first.world_features[index], second.world_features[index])
	}
	first_terrain := Natural_Terrain {
		config = config,
		plan   = first,
	}
	second_terrain := Natural_Terrain {
		config = config,
		plan   = second,
	}
	positions := [?][2]f32{{0, 0}, {315.5, -712.25}, {6_400, 220}, {-2_100, 3_800}}
	for position in positions {
		first_sample := sample_natural_terrain(&first_terrain, position.x, position.y)
		second_sample := sample_natural_terrain(&second_terrain, position.x, position.y)
		testing.expect_value(t, first_sample, second_sample)
	}
	testing.expect(t, validate_world_plan(&first, config), "accepted plan failed validation")
}

@(test)
world_persistence_round_trip :: proc(t: ^testing.T) {
	if !os.is_dir("saves") {
		testing.expect(t, os.make_directory_all("saves") == nil)
	}
	path := "saves/delta_core_test.world"
	defer os.remove(path)
	config := default_world_config(.SMALL, 0xCAFE_BABE)
	plan, generated := generate_world_plan(config)
	if !testing.expect(t, generated) {
		return
	}
	terrain := Natural_Terrain {
		config = config,
		plan   = plan,
	}
	defer destroy_world_plan(&terrain.plan)
	modifications: sparse.World
	testing.expect(t, sparse.init(&modifications, config.modification_voxel_size))
	defer sparse.destroy(&modifications)
	sparse.set(&modifications, {-9, 4, 17}, .FORCE_EMPTY)
	sparse.set(&modifications, {22, 31, -5}, .FORCE_SOLID, 7)
	if !testing.expect(
		t,
		save_world_data(path, &terrain, &modifications),
		"failed to save round-trip world",
	) {
		return
	}
	loaded_terrain, loaded_modifications, loaded := load_world_data(path)
	if !testing.expect(t, loaded, "failed to load round-trip world") {
		return
	}
	defer destroy_world_plan(&loaded_terrain.plan)
	defer sparse.destroy(&loaded_modifications)
	testing.expect_value(t, loaded_terrain.config, config)
	testing.expect_value(t, loaded_terrain.plan.generation_seed, terrain.plan.generation_seed)
	testing.expect_value(
		t,
		loaded_terrain.plan.generation_attempt,
		terrain.plan.generation_attempt,
	)
	testing.expect_value(t, len(loaded_terrain.plan.cells), len(terrain.plan.cells))
	testing.expect_value(
		t,
		len(loaded_terrain.plan.world_features),
		len(terrain.plan.world_features),
	)
	testing.expect_value(t, loaded_modifications.modified_count, modifications.modified_count)
	testing.expect_value(
		t,
		sparse.get(&loaded_modifications, {-9, 4, 17}),
		sparse.Voxel_Override{state = .FORCE_EMPTY},
	)
	testing.expect_value(
		t,
		sparse.get(&loaded_modifications, {22, 31, -5}),
		sparse.Voxel_Override{state = .FORCE_SOLID, material = 7},
	)
}
