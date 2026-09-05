package heightfield

import "core:math"

MAX_LOD_LEVELS :: 9

Sample :: struct {
	height:             f32,
	mountain_influence: f32,
	material:           u32,
	_padding:           u32,
}

Sample_Proc :: proc(data: rawptr, x, z: f32) -> Sample

Source :: struct {
	data:   rawptr,
	sample: Sample_Proc,
}

Cache_Config :: struct {
	level_count:             u32,
	sample_count:            u32,
	spacing:                 [MAX_LOD_LEVELS]f32,
	recenter_interval_cells: u32,
	camera_centered_level_count: u32,
}

Level :: struct {
	origin:        [2]f32,
	spacing:       f32,
	sample_count:  u32,
	sample_offset: u32,
	extent:        f32,
	lod:           u32,
	_generation:   u64,
	_valid:        bool,
}

Cache :: struct {
	config:     Cache_Config,
	levels:     [MAX_LOD_LEVELS]Level,
	samples:    []Sample,
	generation: u64,
}

valid_config :: proc(config: Cache_Config) -> bool {
	if config.level_count == 0 ||
	   config.level_count > MAX_LOD_LEVELS ||
	   config.sample_count < 2 ||
	   config.recenter_interval_cells == 0 ||
	   config.recenter_interval_cells >= config.sample_count ||
	   config.camera_centered_level_count > config.level_count {
		return false
	}
	for index in 0 ..< int(config.level_count) {
		if config.spacing[index] <= 0 ||
		   (index > 0 && config.spacing[index] <= config.spacing[index - 1]) {
			return false
		}
	}
	return true
}

init :: proc(cache: ^Cache, config: Cache_Config) -> bool {
	if !valid_config(config) {
		return false
	}
	cache^ = {}
	cache.config = config
	level_sample_count := int(config.sample_count) * int(config.sample_count)
	cache.samples = make([]Sample, level_sample_count * int(config.level_count))
	for index in 0 ..< int(config.level_count) {
		cache.levels[index] = {
			spacing       = config.spacing[index],
			sample_count  = config.sample_count,
			sample_offset = u32(index * level_sample_count),
			extent        = f32(config.sample_count - 1) * config.spacing[index],
			lod           = u32(index),
		}
	}
	return true
}

level_origin_for_camera :: proc(level: Level, config: Cache_Config, camera: [2]f32) -> [2]f32 {
	if level.lod >= config.camera_centered_level_count {
		return {-level.extent * 0.5, -level.extent * 0.5}
	}
	snap := level.spacing * f32(config.recenter_interval_cells)
	center := [2]f32 {
		math.floor(camera.x / snap + 0.5) * snap,
		math.floor(camera.y / snap + 0.5) * snap,
	}
	return center - level.extent * 0.5
}

regenerate_level :: proc(cache: ^Cache, level_index: int, source: Source, origin: [2]f32) {
	level := &cache.levels[level_index]
	level.origin = origin
	for z: u32 = 0; z < level.sample_count; z += 1 {
		for x: u32 = 0; x < level.sample_count; x += 1 {
			world_x := origin.x + f32(x) * level.spacing
			world_z := origin.y + f32(z) * level.spacing
			index := level.sample_offset + z * level.sample_count + x
			cache.samples[index] = source.sample(source.data, world_x, world_z)
		}
	}
	level._generation += 1
	level._valid = true
}

update :: proc(cache: ^Cache, source: Source, camera: [2]f32) -> bool {
	if source.sample == nil || len(cache.samples) == 0 {
		return false
	}
	changed := false
	for index in 0 ..< int(cache.config.level_count) {
		level := &cache.levels[index]
		origin := level_origin_for_camera(level^, cache.config, camera)
		if !level._valid || origin != level.origin {
			regenerate_level(cache, index, source, origin)
			changed = true
		}
	}
	if changed {
		cache.generation += 1
	}
	return changed
}

sample_nearest :: proc(cache: ^Cache, level_index: int, world: [2]f32) -> (Sample, bool) {
	if level_index < 0 || level_index >= int(cache.config.level_count) {
		return {}, false
	}
	level := cache.levels[level_index]
	if !level._valid ||
	   world.x < level.origin.x ||
	   world.y < level.origin.y ||
	   world.x > level.origin.x + level.extent ||
	   world.y > level.origin.y + level.extent {
		return {}, false
	}
	x := u32(
		clamp(
			math.round((world.x - level.origin.x) / level.spacing),
			f32(0),
			f32(level.sample_count - 1),
		),
	)
	z := u32(
		clamp(
			math.round((world.y - level.origin.y) / level.spacing),
			f32(0),
			f32(level.sample_count - 1),
		),
	)
	return cache.samples[level.sample_offset + z * level.sample_count + x], true
}

destroy :: proc(cache: ^Cache) {
	delete(cache.samples)
	cache^ = {}
}
