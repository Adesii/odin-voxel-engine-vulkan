package voxel_terrain

import sparse "../sparse"
import "core:testing"

flat_column :: proc(data: rawptr, x, z: f32) -> Column_Sample {
	_ = data
	_ = x
	_ = z
	return {
		surface_height = 10,
		surface_material = Material_Id(1),
		subsurface_material = Material_Id(2),
	}
}

flat_voxel :: proc(
	data: rawptr,
	voxel: [3]i32,
	position: [3]f32,
	column: Column_Sample,
) -> Material_Id {
	_ = data
	_ = voxel
	if position.y > column.surface_height {
		return AIR
	}
	if column.surface_height - position.y < 1 {
		return column.surface_material
	}
	return column.subsurface_material
}

@(test)
resident_generation_edit_and_streaming :: proc(t: ^testing.T) {
	world: World
	config := Config {
		voxel_size                      = 1,
		residency_radius                = 17,
		render_radius                   = 12,
		transition_width                = 2,
		generation_depth                = 8,
		generation_height_above_surface = 4,
		column_sample_stride            = 1,
		max_chunks_per_update           = 1_000,
	}
	testing.expect(t, init(&world, config))
	defer destroy(&world)
	modifications: sparse.World
	testing.expect(t, sparse.init(&modifications, config.voxel_size))
	defer sparse.destroy(&modifications)
	source := Source {
		sample_column = flat_column,
		sample_voxel  = flat_voxel,
	}

	update(&world, {0.5, 15, 0.5}, source, &modifications)
	testing.expect(t, world.stats.resident_chunks > 0)
	testing.expect(t, world.stats.empty_bricks > 0)
	testing.expect(t, world.stats.solid_bricks > 0)
	testing.expect(t, world.stats.mixed_bricks > 0)
	testing.expect_value(t, material_at(&world, {0, 9, 0}), Material_Id(1))
	testing.expect_value(t, material_at(&world, {0, 8, 0}), Material_Id(2))
	testing.expect_value(t, material_at(&world, {0, 11, 0}), AIR)

	hit := raycast(&world, {0.5, 15, 0.5}, {0, -1, 0}, 20)
	testing.expect(t, hit.hit)
	testing.expect_value(t, hit.voxel, [3]i32{0, 9, 0})
	set_material(&world, &modifications, hit.voxel, AIR)
	second_hit := raycast(&world, {0.5, 15, 0.5}, {0, -1, 0}, 20)
	testing.expect(t, second_hit.hit)
	testing.expect_value(t, second_hit.voxel, [3]i32{0, 8, 0})

	for x in -2 ..= 2 {
		set_material(&world, &modifications, {i32(x), 8, 0}, AIR)
	}
	set_material(&world, &modifications, {0, 12, 0}, Material_Id(3))
	placed_hit := raycast(&world, {0.5, 15, 0.5}, {0, -1, 0}, 20)
	testing.expect(t, placed_hit.hit)
	testing.expect_value(t, placed_hit.voxel, [3]i32{0, 12, 0})
	for x in -2 ..= 2 {
		testing.expect_value(t, material_at(&world, {i32(x), 8, 0}), AIR)
	}

	update(&world, {100.5, 15, 0.5}, source, &modifications)
	testing.expect(t, world.stats.evicted_this_frame > 0)
	update(&world, {0.5, 15, 0.5}, source, &modifications)
	testing.expect_value(t, material_at(&world, {0, 9, 0}), AIR)
	for x in -2 ..= 2 {
		testing.expect_value(t, material_at(&world, {i32(x), 8, 0}), AIR)
	}
	testing.expect_value(t, material_at(&world, {0, 12, 0}), Material_Id(3))
	testing.expect_value(t, modifications.modified_count, 7)
}
