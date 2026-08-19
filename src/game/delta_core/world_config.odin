package delta_core
import terrain_renderer "../../engine/render/terrain"

World_Size :: enum u8 {
	SMALL,
	MEDIUM,
	LARGE,
}

World_Config :: struct {
	size_preset:                           World_Size,
	seed:                                  u64,
	world_radius:                          f32,
	crater_radius:                         f32,
	crater_wall_width:                     f32,
	crater_wall_height:                    f32,
	base_elevation:                        f32,
	mountain_height:                       f32,
	rolling_terrain_height:                f32,
	base_voxel_size:                       f32,
	modification_voxel_size:               f32,
	voxel_residency_radius:                f32,
	voxel_render_radius:                   f32,
	voxel_transition_width:                f32,
	voxel_generation_depth:                f32,
	voxel_generation_height_above_surface: f32,
	voxel_column_sample_stride:            u32,
	voxel_chunks_per_frame:                u32,
	plan_resolution:                       i32,
	max_generation_attempts:               u32,
	cache_sample_count:                    u32,
	cache_lod_spacing:                     [3]f32,
	render_distance:                       f32,
}

default_world_config :: proc(
	size: World_Size = .MEDIUM,
	seed: u64 = 0xD317_A_C0DE,
) -> World_Config {
	config := World_Config {
		size_preset                           = size,
		seed                                  = seed,
		base_elevation                        = 20,
		base_voxel_size                       = 0.25,
		modification_voxel_size               = 0.25,
		voxel_residency_radius                = 24 * 2,
		voxel_render_radius                   = 18 * 2, //TODO: this shouldn't matter for world generation. these are render settings.
		voxel_transition_width                = 6,
		voxel_generation_depth                = 12,
		voxel_generation_height_above_surface = 8,
		voxel_column_sample_stride            = 4,
		voxel_chunks_per_frame                = 2,
		max_generation_attempts               = 8,
		cache_sample_count                    = 200, //TODO: this shouldn't matter for world generation. these are render settings.
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
		// config.cache_lod_spacing = {4, 16, 128}//TODO: this shouldn't matter for world generation. these are render settings.
		config.render_distance = 24_000 //TODO: this shouldn't matter for world generation. these are render settings.
	case .MEDIUM:
		config.world_radius = 16_384
		config.crater_radius = 14_000
		config.crater_wall_width = 2_000
		config.crater_wall_height = 2_500
		config.mountain_height = 1_900
		config.rolling_terrain_height = 120
		config.plan_resolution = 96
		// config.cache_lod_spacing = {4, 32, 256}//TODO: this shouldn't matter for world generation. these are render settings.
		config.render_distance = 46_000 //TODO: this shouldn't matter for world generation. these are render settings.
	case .LARGE:
		config.world_radius = 32_768
		config.crater_radius = 28_000
		config.crater_wall_width = 3_500
		config.crater_wall_height = 4_000
		config.mountain_height = 3_000
		config.rolling_terrain_height = 170
		config.plan_resolution = 128
		config.render_distance = 90_000 //TODO: this shouldn't matter for world generation. these are render settings.
	}
	config.cache_lod_spacing = {4, 64, 512} //TODO: this shouldn't matter for world generation. these are render settings.
	return config
}

default_terrain_render_config :: proc(config: World_Config) -> terrain_renderer.Config {
	sample_cells := f32(config.cache_sample_count - 1)
	return {
		near_voxel_distance = config.voxel_render_radius,
		voxel_transition_width = config.voxel_transition_width,
		heightfield_lod_end_distances = {
			sample_cells * config.cache_lod_spacing[0] * 0.4,
			sample_cells * config.cache_lod_spacing[1] * 0.4,
			config.render_distance,
		},
		far_distance = config.render_distance,
		virtual_voxel_size = config.cache_lod_spacing,
		vertical_quantization = config.cache_lod_spacing,
		heightfield_lod_transition_width = max(config.cache_lod_spacing[1] * 2, 32),
		stats_sample_stride = 8,
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
		config.voxel_residency_radius > config.voxel_render_radius &&
		config.voxel_render_radius > config.voxel_transition_width &&
		config.voxel_transition_width >= 0 &&
		config.voxel_generation_depth > 0 &&
		config.voxel_generation_height_above_surface >= 0 &&
		config.voxel_column_sample_stride > 0 &&
		32 % int(config.voxel_column_sample_stride) == 0 &&
		config.voxel_chunks_per_frame > 0 &&
		config.plan_resolution >= 16 &&
		config.max_generation_attempts > 0 &&
		config.cache_sample_count >= 17 &&
		config.cache_sample_count <= 257 &&
		config.cache_lod_spacing[0] > 0 &&
		config.cache_lod_spacing[0] < config.cache_lod_spacing[1] &&
		config.cache_lod_spacing[1] < config.cache_lod_spacing[2] &&
		config.render_distance > config.crater_radius \
	)
}
