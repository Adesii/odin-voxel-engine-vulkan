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
		level_count             = 3,
		sample_count            = 256,
		spacing                 = {1, 16, 512},
		recenter_interval_cells = 16,
	}
	sample_cells := f32(cache.sample_count - 1)
	return {
		terrain = {
			backend = backend,
			near_voxel_distance = 18 * 4,
			voxel_transition_width = 4 * 4,
			heightfield_lod_end_distances = {
				sample_cells * cache.spacing[0] * 0.4,
				sample_cells * cache.spacing[1] * 0.4,
				5_000_000,
			},
			far_distance = 5_000_000,
			virtual_voxel_size = {1, 16, 512},
			vertical_quantization = {1, 16, 512},
			heightfield_lod_transition_width = cache.spacing[1],
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
	return(
		terrain_renderer.valid_config(config.terrain) &&
		heightfield.valid_config(representation.heightfield_cache) &&
		voxel_terrain.valid_config(representation.voxels) &&
		representation.voxels.voxel_size == world.base_voxel_size &&
		representation.voxels.residency_radius > config.terrain.near_voxel_distance \
	)
}
