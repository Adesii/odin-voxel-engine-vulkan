package delta_core
import terrain_renderer "../../engine/render/terrain"
import heightfield "../../engine/terrain/heightfield"
import voxel_terrain "../../engine/terrain/voxel"

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
			virtual_voxel_size = cache.spacing,
			vertical_quantization = cache.spacing,
			heightfield_lod_transition_width = cache.spacing[3],
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
		if terrain.virtual_voxel_size[index] != cache.spacing[index] {
			return false
		}
		if index < int(cache.camera_centered_level_count) {
			required_radius :=
				terrain.heightfield_lod_end_distances[index] +
				f32(terrain_renderer.MESH_HEIGHTFIELD_PATCH_CELLS + 1) *
					cache.spacing[index]
			if required_radius > safe_radius_cells * cache.spacing[index] {
				return false
			}
		} else {
			fixed_level_radius :=
				f32(cache.sample_count - 1) * cache.spacing[index] * 0.5
			required_radius :=
				world.world_radius +
				f32(terrain_renderer.MESH_HEIGHTFIELD_PATCH_CELLS + 1) *
					cache.spacing[index]
			if fixed_level_radius < required_radius {
				return false
			}
		}
	}
	return true
}
