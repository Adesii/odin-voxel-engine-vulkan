package delta_core
import terrain_renderer "../../engine/render/terrain"
import heightfield "../../engine/terrain/heightfield"
import voxel_terrain "../../engine/terrain/voxel"
import "core:math"

World_Size :: enum u8 {
	SMALL,
	MEDIUM,
	LARGE,
}

World_Type :: enum u8 {
	DELTA_CORE,
	FLAT,
	NOISE,
	STRESS_TEST,
}

World_Config :: struct {
	size_preset:             World_Size,
	world_type:              World_Type,
	seed:                    u64,
	world_radius:            f32,
	crater_radius:           f32,
	crater_wall_width:       f32,
	crater_wall_height:      f32,
	base_elevation:          f32,
	mountain_height:         f32,
	rolling_terrain_height:  f32,
	base_voxel_size:         f32,
	modification_voxel_size: f32,
	ore_generation_depth:    f32,
	plan_resolution:         i32,
	max_generation_attempts: u32,
}

World_Representation_Config :: struct {
	heightfield_cache: heightfield.Cache_Config,
	voxels:            voxel_terrain.Config,
}

Render_Config :: struct {
	terrain:              terrain_renderer.Config,
	world_representation: World_Representation_Config,
}

default_world_config :: proc(
	size: World_Size = .LARGE,
	seed: u64 = 0xD317_A_C0DE,
	world_type: World_Type = .DELTA_CORE,
) -> World_Config {
	config := World_Config {
		size_preset             = size,
		world_type              = world_type,
		seed                    = seed,
		base_elevation          = 20,
		base_voxel_size         = 0.25,
		modification_voxel_size = 0.25,
		ore_generation_depth    = 4,
		max_generation_attempts = 8,
	}
	switch size {
	case .SMALL:
		config.world_radius = 8_192
		config.crater_radius = 7_000
		config.crater_wall_width = 1_100
		config.crater_wall_height = 1_600
		config.mountain_height = 1_200
		config.rolling_terrain_height = 90
		config.plan_resolution = 64
	case .MEDIUM:
		config.world_radius = 16_384
		config.crater_radius = 14_000
		config.crater_wall_width = 2_000
		config.crater_wall_height = 2_500
		config.mountain_height = 1_900
		config.rolling_terrain_height = 120
		config.plan_resolution = 96
	case .LARGE:
		config.world_radius = 32_768
		config.crater_radius = 28_000
		config.crater_wall_width = 3_500
		config.crater_wall_height = 4_000
		config.mountain_height = 3_000
		config.rolling_terrain_height = 170
		config.plan_resolution = 128
	}
	return config
}

// Each heightfield sample is drawn as an N x N block of virtual cells. Samples
// are spaced 1..256 m apart, so cells as wide as the spacing read as huge blocks
// at 5-10 pixels each; subdividing keeps every LOD's cells a pixel or two wide
// at the start of its band (LOD0 cells match the 0.25 m voxels it hands over
// from). The extra detail is interpolated, so no additional samples are needed.
HEIGHTFIELD_CELLS_PER_SAMPLE :: 4
// Heights snap to a finer step than the cells are wide, so slopes stay smooth
// and neighbouring LODs sit within a fraction of a cell of one another.
HEIGHTFIELD_VERTICAL_STEPS_PER_CELL :: 2
// The mesh backend places a vertex every N virtual cells (must divide
// HEIGHTFIELD_CELLS_PER_SAMPLE): smooth triangles need far fewer vertices than
// the raymarcher's blocky cells need cells, and the vertex count dominates its cost.
HEIGHTFIELD_MESH_CELL_STRIDE :: 4
// Half width of each LOD crossfade as a fraction of its boundary distance.
HEIGHTFIELD_LOD_TRANSITION_RATIO :: 0.05

default_render_config :: proc(
	world: World_Config,
	backend: terrain_renderer.Backend = .RAYMARCH,
) -> Render_Config {
	cache := heightfield.Cache_Config {
		level_count             = heightfield.MAX_LOD_LEVELS,
		sample_count            = 273,
		spacing                 = {1, 2, 4, 8, 16, 32, 64, 128, 256},
		recenter_interval_cells = 16,
		camera_centered_level_count = heightfield.MAX_LOD_LEVELS - 1,
	}
	sample_cells := f32(cache.sample_count - 1)
	heightfield_lod_end_distances: [heightfield.MAX_LOD_LEVELS]f32
	for index in 0 ..< heightfield.MAX_LOD_LEVELS {
		heightfield_lod_end_distances[index] = sample_cells * cache.spacing[index] * 0.4
	}
	virtual_voxel_size: [heightfield.MAX_LOD_LEVELS]f32
	vertical_quantization: [heightfield.MAX_LOD_LEVELS]f32
	for index in 0 ..< heightfield.MAX_LOD_LEVELS {
		virtual_voxel_size[index] = cache.spacing[index] / HEIGHTFIELD_CELLS_PER_SAMPLE
		vertical_quantization[index] = virtual_voxel_size[index] / HEIGHTFIELD_VERTICAL_STEPS_PER_CELL
	}
	far_distance :=
		max(
			world_diameter(world),
			heightfield_lod_end_distances[heightfield.MAX_LOD_LEVELS - 1],
		)
	heightfield_lod_end_distances[heightfield.MAX_LOD_LEVELS - 1] = far_distance
	return {
		terrain = {
			backend = backend,
			heightfield_lod_count = cache.level_count,
			near_voxel_distance = 18 * 4,
			voxel_transition_width = 4 * 4,
			heightfield_lod_end_distances = heightfield_lod_end_distances,
			far_distance = far_distance,
			virtual_voxel_size = virtual_voxel_size,
			vertical_quantization = vertical_quantization,
			heightfield_lod_transition_ratio = HEIGHTFIELD_LOD_TRANSITION_RATIO,
			mesh_heightfield_cell_stride = HEIGHTFIELD_MESH_CELL_STRIDE,
			stats_sample_stride = 16,
		},
		world_representation = {
			heightfield_cache = cache,
			voxels = {
				voxel_size = world.base_voxel_size,
				residency_radius = 24 * 4,
				generation_depth = 4,
				generation_height_above_surface = 8,
				column_sample_stride = 2 * 16,
				max_chunks_per_update = 4,
			},
		},
	}
}

world_diameter :: proc(config: World_Config) -> f32 {
	return config.world_radius * 2
}

validate_world_config :: proc(config: World_Config) -> bool {
	return(
		config.world_radius > 0 &&
		config.crater_radius > 0 &&
		config.crater_radius < config.world_radius &&
		config.crater_wall_width > 0 &&
		config.crater_wall_width < config.crater_radius &&
		config.crater_wall_height > 0 &&
		config.base_voxel_size > 0 &&
		config.modification_voxel_size == config.base_voxel_size &&
		config.ore_generation_depth > 0 &&
		config.plan_resolution >= 16 &&
		config.max_generation_attempts > 0 \
	)
}

validate_render_config :: proc(world: World_Config, config: Render_Config) -> bool {
	representation := config.world_representation
	terrain := config.terrain
	cache := representation.heightfield_cache
	if !terrain_renderer.valid_config(terrain) ||
	   !heightfield.valid_config(cache) ||
	   !voxel_terrain.valid_config(representation.voxels) ||
	   representation.voxels.voxel_size != world.base_voxel_size ||
	   representation.voxels.residency_radius <= terrain.near_voxel_distance ||
	   terrain.heightfield_lod_count != cache.level_count ||
	   terrain.far_distance < world_diameter(world) ||
	   u64(cache.sample_count) * u64(cache.sample_count) * u64(cache.level_count) >
	   u64(terrain_renderer.MAX_GPU_SAMPLES) {
		return false
	}
	safe_radius_cells :=
		(f32(cache.sample_count - 1) - f32(cache.recenter_interval_cells)) * 0.5
	for index in 0 ..< int(cache.level_count) {
		// Virtual cells must tile a sample exactly so cell centres land on samples.
		cells_per_sample := cache.spacing[index] / terrain.virtual_voxel_size[index]
		if cells_per_sample < 1 ||
		   abs(cells_per_sample - math.round(cells_per_sample)) > 1e-4 ||
		   u32(math.round(cells_per_sample)) % terrain.mesh_heightfield_cell_stride != 0 {
			return false
		}
		if index < int(cache.camera_centered_level_count) {
			required_radius :=
				terrain_renderer.mesh_heightfield_lod_reach(terrain, index) +
				f32(terrain_renderer.MESH_HEIGHTFIELD_PATCH_CELLS + 1) *
					terrain_renderer.mesh_heightfield_cell_size(terrain, index)
			if required_radius > safe_radius_cells * cache.spacing[index] {
				return false
			}
		} else {
			fixed_level_radius :=
				f32(cache.sample_count - 1) * cache.spacing[index] * 0.5
			required_radius :=
				world.world_radius +
				f32(terrain_renderer.MESH_HEIGHTFIELD_PATCH_CELLS + 1) *
					terrain_renderer.mesh_heightfield_cell_size(terrain, index)
			if fixed_level_radius < required_radius {
				return false
			}
		}
	}
	return true
}
