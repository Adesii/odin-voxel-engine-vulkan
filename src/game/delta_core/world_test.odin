package delta_core
import terrain_renderer "../../engine/render/terrain"

import sparse "../../engine/terrain/sparse"
import voxel_terrain "../../engine/terrain/voxel"
import "core:math"
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

@(test)
coherent_ore_vein_reconstructs_from_world_seed :: proc(t: ^testing.T) {
	config := default_world_config(.SMALL, 0x1234_5678)
	plan, generated := generate_world_plan(config)
	if !testing.expect(t, generated) {
		return
	}
	terrain := Natural_Terrain {
		config = config,
		plan   = plan,
	}
	defer destroy_world_plan(&terrain.plan)
	initialize_voxel_geology(&terrain)
	start := terrain.ore_vein_start
	end := terrain.ore_vein_end
	iron_samples := 0
	underground_samples := 0
	for index in 1 ..= 20 {
		amount := f32(index) / 20
		position := start + (end - start) * amount
		column := voxel_column_sample(&terrain, position.x, position.z)
		position.y = min(position.y, column.surface_height - 0.25)
		first := voxel_natural_sample(&terrain, {}, position, column)
		second := voxel_natural_sample(&terrain, {}, position, column)
		testing.expect_value(t, first, second)
		if first == material_id(.IRON_ORE) {
			iron_samples += 1
			if column.surface_height - position.y > 8 {
				underground_samples += 1
			}
		}
	}
	testing.expect(t, iron_samples >= 16, "guaranteed vein was not spatially coherent")
	testing.expect(t, underground_samples >= 6, "guaranteed vein did not extend underground")

	exposure_position := start
	exposure_column := voxel_column_sample(&terrain, exposure_position.x, exposure_position.z)
	exposure_position.y = exposure_column.surface_height - 0.125
	testing.expect_value(
		t,
		voxel_natural_sample(&terrain, {}, exposure_position, exposure_column),
		material_id(.IRON_ORE),
	)
}

@(test)
mined_ore_depletion_survives_save_and_regeneration :: proc(t: ^testing.T) {
	if !os.is_dir("saves") {
		testing.expect(t, os.make_directory_all("saves") == nil)
	}
	path := "saves/delta_core_depletion_test.world"
	defer os.remove(path)
	config := default_world_config(.SMALL, 0x1234_5678)
	plan, generated := generate_world_plan(config)
	if !testing.expect(t, generated) {
		return
	}
	terrain := Natural_Terrain {
		config = config,
		plan   = plan,
	}
	initialize_voxel_geology(&terrain)
	modifications: sparse.World
	testing.expect(t, sparse.init(&modifications, config.base_voxel_size))

	position := terrain.ore_vein_start
	column := voxel_column_sample(&terrain, position.x, position.z)
	position.y = column.surface_height - 0.125
	voxel := [3]i32 {
		i32(math.floor(position.x / config.base_voxel_size)),
		i32(math.floor(position.y / config.base_voxel_size)),
		i32(math.floor(position.z / config.base_voxel_size)),
	}
	testing.expect_value(
		t,
		voxel_natural_sample(&terrain, voxel, position, column),
		material_id(.IRON_ORE),
	)
	sparse.set(&modifications, voxel, .FORCE_EMPTY)
	testing.expect(t, save_world_data(path, &terrain, &modifications))
	sparse.destroy(&modifications)
	destroy_world_plan(&terrain.plan)

	loaded_terrain, loaded_modifications, loaded := load_world_data(path)
	if !testing.expect(t, loaded) {
		return
	}
	defer destroy_world_plan(&loaded_terrain.plan)
	defer sparse.destroy(&loaded_modifications)
	initialize_voxel_geology(&loaded_terrain)
	resident: voxel_terrain.World
	resident_config := voxel_config(loaded_terrain.config)
	resident_config.residency_radius = 12
	resident_config.render_radius = 8
	resident_config.transition_width = 2
	resident_config.generation_depth = 8
	resident_config.generation_height_above_surface = 4
	resident_config.max_chunks_per_update = 1_000
	testing.expect(t, voxel_terrain.init(&resident, resident_config))
	defer voxel_terrain.destroy(&resident)
	voxel_terrain.update(&resident, position, voxel_source(&loaded_terrain), &loaded_modifications)
	testing.expect_value(t, voxel_terrain.material_at(&resident, voxel), voxel_terrain.AIR)
	testing.expect_value(t, loaded_modifications.modified_count, 1)
}

@(test)
terrain_render_presets_are_world_aligned :: proc(t: ^testing.T) {
	sizes := [?]World_Size{World_Size.SMALL, World_Size.MEDIUM, World_Size.LARGE}
	for size in sizes {
		world := default_world_config(size)
		render := default_terrain_render_config(world)
		testing.expect(t, terrain_renderer.valid_config(render))
		testing.expect_value(t, render.near_voxel_distance, world.voxel_render_radius)
		testing.expect_value(t, render.virtual_voxel_size, world.cache_lod_spacing)
		testing.expect_value(t, render.vertical_quantization, world.cache_lod_spacing)
		for index in 0 ..< len(render.virtual_voxel_size) {
			ratio := render.virtual_voxel_size[index] / world.cache_lod_spacing[index]
			testing.expect(t, math.abs(ratio - math.round(ratio)) < 0.0001)
		}
	}
}
