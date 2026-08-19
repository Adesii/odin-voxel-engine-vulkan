package delta_core

import sparse "../../engine/terrain/sparse"
import intrinsics "base:intrinsics"
import "core:os"

WORLD_SAVE_MAGIC :: [8]u8{'D', 'C', 'W', 'O', 'R', 'L', 'D', 0}
WORLD_SAVE_VERSION :: u32(6)
MAX_PERSISTED_CELLS :: 257 * 257
MAX_PERSISTED_FEATURES :: 16_384
MAX_PERSISTED_OVERRIDES :: 1_048_576

World_Save_Header :: struct {
	magic:                 [8]u8,
	version:               u32,
	config:                World_Config,
	world_seed:            u64,
	generation_seed:       u64,
	generation_attempt:    u32,
	resolution:            i32,
	spawn:                 [2]f32,
	cell_count:            u32,
	ridge_count:           u32,
	terrain_feature_count: u32,
	world_feature_count:   u32,
	override_count:        u32,
}

append_raw :: proc(buffer: ^[dynamic]u8, source: rawptr, size: int) {
	if size <= 0 {
		return
	}
	offset := len(buffer^)
	resize(buffer, offset + size)
	intrinsics.mem_copy_non_overlapping(&buffer^[offset], source, size)
}

read_raw :: proc(data: []u8, offset: ^int, destination: rawptr, size: int) -> bool {
	if size < 0 || offset^ < 0 || offset^ + size > len(data) {
		return false
	}
	if size > 0 {
		intrinsics.mem_copy_non_overlapping(destination, &data[offset^], size)
	}
	offset^ += size
	return true
}

save_world_data :: proc(
	path: string,
	terrain: ^Natural_Terrain,
	modifications: ^sparse.World,
) -> bool {
	plan := &terrain.plan
	records := sparse.collect_records(modifications, context.temp_allocator)
	header := World_Save_Header {
		magic                 = WORLD_SAVE_MAGIC,
		version               = WORLD_SAVE_VERSION,
		config                = terrain.config,
		world_seed            = plan.world_seed,
		generation_seed       = plan.generation_seed,
		generation_attempt    = plan.generation_attempt,
		resolution            = plan.resolution,
		spawn                 = plan.spawn,
		cell_count            = u32(len(plan.cells)),
		ridge_count           = u32(len(plan.ridges)),
		terrain_feature_count = u32(len(plan.terrain_features)),
		world_feature_count   = u32(len(plan.world_features)),
		override_count        = u32(len(records)),
	}
	bytes := make([dynamic]u8, context.temp_allocator)
	append_raw(&bytes, &header, size_of(header))
	append_raw(&bytes, raw_data(plan.cells), len(plan.cells) * size_of(World_Plan_Cell))
	append_raw(&bytes, raw_data(plan.ridges), len(plan.ridges) * size_of(Mountain_Ridge))
	append_raw(
		&bytes,
		raw_data(plan.terrain_features),
		len(plan.terrain_features) * size_of(Terrain_Feature),
	)
	append_raw(
		&bytes,
		raw_data(plan.world_features),
		len(plan.world_features) * size_of(World_Feature),
	)
	append_raw(&bytes, raw_data(records), len(records) * size_of(sparse.Override_Record))
	return os.write_entire_file(path, data = bytes[:]) == nil
}

load_world_data :: proc(path: string) -> (Natural_Terrain, sparse.World, bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, {}, false
	}
	offset := 0
	header: World_Save_Header
	if !read_raw(data, &offset, &header, size_of(header)) ||
	   header.magic != WORLD_SAVE_MAGIC ||
	   header.version != WORLD_SAVE_VERSION ||
	   !validate_world_config(header.config) ||
	   header.cell_count == 0 ||
	   header.cell_count > MAX_PERSISTED_CELLS ||
	   header.ridge_count == 0 ||
	   header.ridge_count > MAX_PERSISTED_FEATURES ||
	   header.terrain_feature_count == 0 ||
	   header.terrain_feature_count > MAX_PERSISTED_FEATURES ||
	   header.world_feature_count > MAX_PERSISTED_FEATURES ||
	   header.override_count > MAX_PERSISTED_OVERRIDES {
		return {}, {}, false
	}
	terrain := Natural_Terrain {
		config = header.config,
		plan = {
			world_seed = header.world_seed,
			generation_seed = header.generation_seed,
			generation_attempt = header.generation_attempt,
			resolution = header.resolution,
			spawn = header.spawn,
		},
	}
	terrain.plan.cells = make([]World_Plan_Cell, int(header.cell_count))
	terrain.plan.ridges = make([]Mountain_Ridge, int(header.ridge_count))
	terrain.plan.terrain_features = make([]Terrain_Feature, int(header.terrain_feature_count))
	terrain.plan.world_features = make([]World_Feature, int(header.world_feature_count))
	loaded :=
		read_raw(
			data,
			&offset,
			raw_data(terrain.plan.cells),
			len(terrain.plan.cells) * size_of(World_Plan_Cell),
		) &&
		read_raw(
			data,
			&offset,
			raw_data(terrain.plan.ridges),
			len(terrain.plan.ridges) * size_of(Mountain_Ridge),
		) &&
		read_raw(
			data,
			&offset,
			raw_data(terrain.plan.terrain_features),
			len(terrain.plan.terrain_features) * size_of(Terrain_Feature),
		) &&
		read_raw(
			data,
			&offset,
			raw_data(terrain.plan.world_features),
			len(terrain.plan.world_features) * size_of(World_Feature),
		)
	if !loaded || !validate_world_plan(&terrain.plan, terrain.config) {
		destroy_world_plan(&terrain.plan)
		return {}, {}, false
	}
	modifications: sparse.World
	if !sparse.init(&modifications, terrain.config.modification_voxel_size) {
		destroy_world_plan(&terrain.plan)
		return {}, {}, false
	}
	if header.override_count > 0 {
		records := make(
			[]sparse.Override_Record,
			int(header.override_count),
			context.temp_allocator,
		)
		if !read_raw(
			   data,
			   &offset,
			   raw_data(records),
			   len(records) * size_of(sparse.Override_Record),
		   ) ||
		   offset != len(data) {
			sparse.destroy(&modifications)
			destroy_world_plan(&terrain.plan)
			return {}, {}, false
		}
		sparse.apply_records(&modifications, records)
	} else if offset != len(data) {
		sparse.destroy(&modifications)
		destroy_world_plan(&terrain.plan)
		return {}, {}, false
	}
	return terrain, modifications, true
}
