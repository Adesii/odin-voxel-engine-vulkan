package terrain_renderer

import voxel_terrain "../../terrain/voxel"
import vulkan "../vulkan"
import "core:testing"

set_test_brick_kind :: proc(
	chunk: ^voxel_terrain.Chunk,
	brick: [3]i32,
	kind: voxel_terrain.Brick_Kind,
) {
	local := brick * voxel_terrain.BRICK_SIZE
	chunk.bricks[voxel_terrain.brick_index(local)].kind = kind
}

@(test)
mesh_workgroup_budgets_are_device_bounded :: proc(t: ^testing.T) {
	renderer: vulkan.Renderer
	renderer.mesh_shader = {
		supported                  = true,
		max_work_group_invocations = MESH_SHADER_THREADS,
		max_work_group_size        = {MESH_SHADER_THREADS, 1, 1},
		max_output_vertices        = MESH_MAX_OUTPUT_VERTICES,
		max_output_primitives      = MESH_MAX_OUTPUT_PRIMITIVES,
	}
	testing.expect(t, mesh_limits_sufficient(&renderer))
	renderer.mesh_shader.max_output_primitives = MESH_MAX_OUTPUT_PRIMITIVES - 1
	testing.expect(t, !mesh_limits_sufficient(&renderer))
}

@(test)
terrain_lod_config_rejects_non_monotonic_progressions :: proc(t: ^testing.T) {
	config := Config {
		backend = .RAYMARCH,
		heightfield_lod_count = 3,
		near_voxel_distance = 32,
		voxel_transition_width = 8,
		heightfield_lod_end_distances = {64, 128, 256, 0, 0, 0, 0, 0, 0},
		far_distance = 256,
		virtual_voxel_size = {1, 2, 4, 0, 0, 0, 0, 0, 0},
		vertical_quantization = {1, 2, 4, 0, 0, 0, 0, 0, 0},
		heightfield_lod_transition_width = 2,
	}
	testing.expect(t, valid_config(config))

	invalid_distance := config
	invalid_distance.heightfield_lod_end_distances[1] =
		invalid_distance.heightfield_lod_end_distances[0]
	testing.expect(t, !valid_config(invalid_distance))

	invalid_cell_size := config
	invalid_cell_size.virtual_voxel_size[2] = invalid_cell_size.virtual_voxel_size[1]
	testing.expect(t, !valid_config(invalid_cell_size))

	invalid_vertical_step := config
	invalid_vertical_step.vertical_quantization[2] = 0.5
	testing.expect(t, !valid_config(invalid_vertical_step))
}

@(test)
heightfield_patch_grid_covers_requested_lod_radius :: proc(t: ^testing.T) {
	end_distance: f32 = 65_536
	cell_size: f32 = 256
	diameter := mesh_heightfield_grid_diameter(end_distance, cell_size)
	testing.expect(t, diameter % 2 == 1)
	covered_radius_cells := (diameter / 2) * MESH_HEIGHTFIELD_PATCH_CELLS
	required_radius_cells := u32(end_distance / cell_size)
	testing.expect(t, covered_radius_cells >= required_radius_cells)
}

@(test)
mesh_surface_candidates_cross_brick_and_chunk_boundaries :: proc(t: ^testing.T) {
	world: voxel_terrain.World
	world.chunks = make(map[voxel_terrain.Chunk_Coord]^voxel_terrain.Chunk)
	defer delete(world.chunks)

	center_coord := voxel_terrain.Chunk_Coord{0, 0, 0}
	center_chunk := new(voxel_terrain.Chunk)
	center_chunk.coord = center_coord
	world.chunks[center_coord] = center_chunk
	defer free(center_chunk)

	center_brick := [3]i32{1, 1, 1}
	set_test_brick_kind(center_chunk, center_brick, .SOLID)
	neighbor_offsets := [?][3]i32 {
		{-1, 0, 0},
		{1, 0, 0},
		{0, -1, 0},
		{0, 1, 0},
		{0, 0, -1},
		{0, 0, 1},
	}
	for offset in neighbor_offsets {
		set_test_brick_kind(center_chunk, center_brick + offset, .SOLID)
	}
	center_min := center_brick * voxel_terrain.BRICK_SIZE
	testing.expect(
		t,
		!mesh_brick_has_potential_surface(&world, center_min, .SOLID),
		"fully enclosed solid brick was submitted",
	)

	set_test_brick_kind(center_chunk, center_brick + [3]i32{1, 0, 0}, .MIXED)
	testing.expect(
		t,
		mesh_brick_has_potential_surface(&world, center_min, .SOLID),
		"mixed neighboring brick did not expose the shared boundary",
	)

	right_coord := voxel_terrain.Chunk_Coord{1, 0, 0}
	right_chunk := new(voxel_terrain.Chunk)
	right_chunk.coord = right_coord
	world.chunks[right_coord] = right_chunk
	defer free(right_chunk)
	set_test_brick_kind(right_chunk, {0, 1, 1}, .SOLID)
	right_min := [3]i32 {
		voxel_terrain.CHUNK_SIZE,
		voxel_terrain.BRICK_SIZE,
		voxel_terrain.BRICK_SIZE,
	}
	testing.expect_value(t, mesh_brick_kind_at(&world, right_min), voxel_terrain.Brick_Kind.SOLID)
}
