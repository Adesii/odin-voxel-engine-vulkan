package heightfield

import "core:testing"

cache_test_sampler :: proc(data: rawptr, x, z: f32) -> Sample {
	_ = data
	return {height = x * 2 + z, mountain_influence = x - z, material = 3}
}

@(test)
cache_streams_only_after_recenter :: proc(t: ^testing.T) {
	cache: Cache
	testing.expect(
		t,
		init(
			&cache,
			{
				level_count = MAX_LOD_LEVELS,
				sample_count = 17,
				spacing = {1, 2, 4, 8, 16, 32, 64, 128, 256},
				recenter_interval_cells = 4,
				camera_centered_level_count = MAX_LOD_LEVELS - 1,
			},
		),
	)
	defer destroy(&cache)
	source := Source {
		sample = cache_test_sampler,
	}
	testing.expect(t, update(&cache, source, {0, 0}))
	testing.expect_value(t, cache.generation, u64(1))
	center, found := sample_nearest(&cache, 0, {0, 0})
	testing.expect(t, found)
	testing.expect_value(t, center.height, f32(0))
	testing.expect(
		t,
		!update(&cache, source, {1.9, 0}),
		"cache regenerated before the camera crossed half its snap interval",
	)
	testing.expect_value(t, cache.generation, u64(1))
	testing.expect(
		t,
		update(&cache, source, {2.1, 0}),
		"cache did not recenter after the camera crossed half its snap interval",
	)
	testing.expect_value(t, cache.generation, u64(2))
	moved, moved_found := sample_nearest(&cache, 0, {4, 2})
	testing.expect(t, moved_found)
	testing.expect_value(t, moved.height, f32(10))
	testing.expect_value(
		t,
		cache.levels[MAX_LOD_LEVELS - 1]._generation,
		u64(1),
	)
}
