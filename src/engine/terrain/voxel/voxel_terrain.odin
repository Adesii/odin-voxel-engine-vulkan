package voxel_terrain

import sparse "../sparse"
import "core:math"
import "core:slice"
import "core:time"

CHUNK_SIZE :: 32
BRICK_SIZE :: 8
BRICKS_PER_AXIS :: CHUNK_SIZE / BRICK_SIZE
BRICKS_PER_CHUNK :: BRICKS_PER_AXIS * BRICKS_PER_AXIS * BRICKS_PER_AXIS
VOXELS_PER_BRICK :: BRICK_SIZE * BRICK_SIZE * BRICK_SIZE

Material_Id :: distinct u16
AIR :: Material_Id(0)

Brick_Kind :: enum u32 {
	EMPTY,
	SOLID,
	MIXED,
}

Chunk_Coord :: struct {
	x, y, z: i32,
}

Column_Coord :: struct {
	x, z: i32,
}

Brick :: struct {
	kind:         Brick_Kind,
	material:     Material_Id,
	voxel_offset: u32,
}

Chunk :: struct {
	coord:           Chunk_Coord,
	bricks:          [BRICKS_PER_CHUNK]Brick,
	detailed_voxels: [dynamic]Material_Id,
}

Column_Sample :: struct {
	surface_height:      f32,
	surface_material:    Material_Id,
	subsurface_material: Material_Id,
}

Column_Block :: struct {
	samples: [CHUNK_SIZE * CHUNK_SIZE]Column_Sample,
}

Column_Sample_Proc :: proc(data: rawptr, x, z: f32) -> Column_Sample
Voxel_Sample_Proc :: proc(
	data: rawptr,
	voxel: [3]i32,
	position: [3]f32,
	column: Column_Sample,
) -> Material_Id

Source :: struct {
	data:          rawptr,
	sample_column: Column_Sample_Proc,
	sample_voxel:  Voxel_Sample_Proc,
}

Config :: struct {
	voxel_size:                      f32,
	residency_radius:                f32,
	render_radius:                   f32,
	transition_width:                f32,
	generation_depth:                f32,
	generation_height_above_surface: f32,
	column_sample_stride:            u32,
	max_chunks_per_update:           u32,
}

Stats :: struct {
	resident_chunks:      u32,
	resident_bricks:      u32,
	empty_bricks:         u32,
	solid_bricks:         u32,
	mixed_bricks:         u32,
	detailed_voxels:      u64,
	resident_bytes:       u64,
	gpu_bytes:            u64,
	generated_this_frame: u32,
	evicted_this_frame:   u32,
	generation_ms:        f64,
	last_generation_ms:   f64,
	pending_chunks:       u32,
	persistent_edits:     u32,
	voxel_queries:        u64,
	brick_skips:          u64,
	material_counts:      [64]u64,
}

Pending_Chunk :: struct {
	coord:       Chunk_Coord,
	distance_sq: i64,
}

World :: struct {
	config:          Config,
	chunks:          map[Chunk_Coord]^Chunk,
	columns:         map[Column_Coord]^Column_Block,
	desired:         map[Chunk_Coord]bool,
	desired_columns: map[Column_Coord]bool,
	pending:         [dynamic]Pending_Chunk,
	pending_cursor:  int,
	center_chunk:    [2]i32,
	center_valid:    bool,
	generation:      u64,
	stats:           Stats,
}

Ray_Hit :: struct {
	hit:            bool,
	voxel:          [3]i32,
	previous_voxel: [3]i32,
	position:       [3]f32,
	normal:         [3]f32,
	material:       Material_Id,
	distance:       f32,
}

valid_config :: proc(config: Config) -> bool {
	return(
		config.voxel_size > 0 &&
		config.residency_radius > config.render_radius &&
		config.render_radius > config.transition_width &&
		config.transition_width >= 0 &&
		config.generation_depth > 0 &&
		config.generation_height_above_surface >= 0 &&
		config.column_sample_stride > 0 &&
		CHUNK_SIZE % int(config.column_sample_stride) == 0 &&
		config.max_chunks_per_update > 0 \
	)
}

floor_div :: proc(value, divisor: i32) -> i32 {
	quotient := value / divisor
	remainder := value % divisor
	if remainder != 0 && ((remainder < 0) != (divisor < 0)) {
		quotient -= 1
	}
	return quotient
}

world_to_voxel :: proc(world: ^World, position: [3]f32) -> [3]i32 {
	return {
		i32(math.floor(position.x / world.config.voxel_size)),
		i32(math.floor(position.y / world.config.voxel_size)),
		i32(math.floor(position.z / world.config.voxel_size)),
	}
}

voxel_to_world_min :: proc(world: ^World, voxel: [3]i32) -> [3]f32 {
	return {f32(voxel.x), f32(voxel.y), f32(voxel.z)} * world.config.voxel_size
}

voxel_to_chunk :: proc(voxel: [3]i32) -> Chunk_Coord {
	return {
		floor_div(voxel.x, CHUNK_SIZE),
		floor_div(voxel.y, CHUNK_SIZE),
		floor_div(voxel.z, CHUNK_SIZE),
	}
}

chunk_world_size :: proc(world: ^World) -> f32 {
	return f32(CHUNK_SIZE) * world.config.voxel_size
}

local_voxel :: proc(voxel: [3]i32, coord: Chunk_Coord) -> [3]i32 {
	return voxel - [3]i32{coord.x, coord.y, coord.z} * CHUNK_SIZE
}

brick_index :: proc(local: [3]i32) -> int {
	brick := local / BRICK_SIZE
	return int(brick.z * BRICKS_PER_AXIS * BRICKS_PER_AXIS + brick.y * BRICKS_PER_AXIS + brick.x)
}

brick_voxel_index :: proc(local: [3]i32) -> int {
	cell := local % BRICK_SIZE
	return int(cell.z * BRICK_SIZE * BRICK_SIZE + cell.y * BRICK_SIZE + cell.x)
}

init :: proc(world: ^World, config: Config) -> bool {
	if !valid_config(config) {
		return false
	}
	world^ = {}
	world.config = config
	world.chunks = make(map[Chunk_Coord]^Chunk)
	world.columns = make(map[Column_Coord]^Column_Block)
	world.desired = make(map[Chunk_Coord]bool)
	world.desired_columns = make(map[Column_Coord]bool)
	return true
}

apply_override :: proc(
	modifications: ^sparse.World,
	voxel: [3]i32,
	natural: Material_Id,
) -> Material_Id {
	if modifications == nil {
		return natural
	}
	override := sparse.get(modifications, voxel)
	switch override.state {
	case .FORCE_EMPTY:
		return AIR
	case .FORCE_SOLID:
		return Material_Id(override.material)
	case .UNMODIFIED:
		return natural
	}
	return natural
}

generate_chunk :: proc(
	world: ^World,
	coord: Chunk_Coord,
	source: Source,
	modifications: ^sparse.World,
) -> ^Chunk {
	started := time.tick_now()
	chunk := new(Chunk)
	chunk.coord = coord
	column_coord := Column_Coord{coord.x, coord.z}
	columns, cached := world.columns[column_coord]
	voxel_size := world.config.voxel_size
	base_voxel := [3]i32{coord.x, coord.y, coord.z} * CHUNK_SIZE
	if !cached {
		columns = new(Column_Block)
		stride := int(world.config.column_sample_stride)
		if stride == 1 {
			for z in 0 ..< CHUNK_SIZE {
				for x in 0 ..< CHUNK_SIZE {
					world_x := (f32(base_voxel.x) + f32(x) + 0.5) * voxel_size
					world_z := (f32(base_voxel.z) + f32(z) + 0.5) * voxel_size
					columns.samples[z * CHUNK_SIZE + x] = source.sample_column(
						source.data,
						world_x,
						world_z,
					)
				}
			}
		} else {
			anchor_count := CHUNK_SIZE / stride + 1
			anchors: [(CHUNK_SIZE + 1) * (CHUNK_SIZE + 1)]Column_Sample
			for anchor_z in 0 ..< anchor_count {
				for anchor_x in 0 ..< anchor_count {
					local_x := anchor_x * stride
					local_z := anchor_z * stride
					world_x := (f32(base_voxel.x) + f32(local_x) + 0.5) * voxel_size
					world_z := (f32(base_voxel.z) + f32(local_z) + 0.5) * voxel_size
					anchors[anchor_z * anchor_count + anchor_x] = source.sample_column(
						source.data,
						world_x,
						world_z,
					)
				}
			}
			for z in 0 ..< CHUNK_SIZE {
				for x in 0 ..< CHUNK_SIZE {
					anchor_x := x / stride
					anchor_z := z / stride
					amount_x := f32(x % stride) / f32(stride)
					amount_z := f32(z % stride) / f32(stride)
					s00 := anchors[anchor_z * anchor_count + anchor_x]
					s10 := anchors[anchor_z * anchor_count + anchor_x + 1]
					s01 := anchors[(anchor_z + 1) * anchor_count + anchor_x]
					s11 := anchors[(anchor_z + 1) * anchor_count + anchor_x + 1]
					height_0 :=
						s00.surface_height + (s10.surface_height - s00.surface_height) * amount_x
					height_1 :=
						s01.surface_height + (s11.surface_height - s01.surface_height) * amount_x
					material_anchor_x := amount_x < 0.5 ? anchor_x : anchor_x + 1
					material_anchor_z := amount_z < 0.5 ? anchor_z : anchor_z + 1
					material_sample :=
						anchors[material_anchor_z * anchor_count + material_anchor_x]
					columns.samples[z * CHUNK_SIZE + x] = {
						surface_height      = height_0 + (height_1 - height_0) * amount_z,
						surface_material    = material_sample.surface_material,
						subsurface_material = material_sample.subsurface_material,
					}
				}
			}
		}
		world.columns[column_coord] = columns
	}
	brick_materials: [VOXELS_PER_BRICK]Material_Id
	for brick_z in 0 ..< BRICKS_PER_AXIS {
		for brick_y in 0 ..< BRICKS_PER_AXIS {
			for brick_x in 0 ..< BRICKS_PER_AXIS {
				first := AIR
				uniform := true
				cell_index := 0
				for z in 0 ..< BRICK_SIZE {
					for y in 0 ..< BRICK_SIZE {
						for x in 0 ..< BRICK_SIZE {
							local := [3]i32 {
								i32(brick_x * BRICK_SIZE + x),
								i32(brick_y * BRICK_SIZE + y),
								i32(brick_z * BRICK_SIZE + z),
							}
							voxel := base_voxel + local
							position :=
								([3]f32{f32(voxel.x), f32(voxel.y), f32(voxel.z)} + 0.5) *
								voxel_size
							column := columns.samples[local.z * CHUNK_SIZE + local.x]
							material := source.sample_voxel(source.data, voxel, position, column)
							material = apply_override(modifications, voxel, material)
							brick_materials[cell_index] = material
							if cell_index == 0 {
								first = material
							} else if material != first {
								uniform = false
							}
							cell_index += 1
						}
					}
				}
				index :=
					brick_z * BRICKS_PER_AXIS * BRICKS_PER_AXIS +
					brick_y * BRICKS_PER_AXIS +
					brick_x
				if uniform {
					chunk.bricks[index].material = first
					chunk.bricks[index].kind = first == AIR ? .EMPTY : .SOLID
				} else {
					chunk.bricks[index].kind = .MIXED
					chunk.bricks[index].voxel_offset = u32(len(chunk.detailed_voxels))
					append(&chunk.detailed_voxels, ..brick_materials[:])
				}
			}
		}
	}
	elapsed := time.duration_milliseconds(time.tick_since(started))
	world.stats.generation_ms += elapsed
	world.stats.last_generation_ms = elapsed
	return chunk
}

destroy_chunk :: proc(chunk: ^Chunk) {
	delete(chunk.detailed_voxels)
	free(chunk)
}

pending_less :: proc(a, b: Pending_Chunk) -> bool {
	return a.distance_sq < b.distance_sq
}

rebuild_desired :: proc(world: ^World, camera: [3]f32, source: Source) {
	clear(&world.desired)
	clear(&world.desired_columns)
	clear(&world.pending)
	world.pending_cursor = 0
	chunk_size := chunk_world_size(world)
	center_x := i32(math.floor(camera.x / chunk_size))
	center_z := i32(math.floor(camera.z / chunk_size))
	world.center_chunk = {center_x, center_z}
	world.center_valid = true
	radius_chunks := i32(math.ceil(world.config.residency_radius / chunk_size))
	for z := center_z - radius_chunks; z <= center_z + radius_chunks; z += 1 {
		for x := center_x - radius_chunks; x <= center_x + radius_chunks; x += 1 {
			center_world := [2]f32{(f32(x) + 0.5) * chunk_size, (f32(z) + 0.5) * chunk_size}
			delta := center_world - [2]f32{camera.x, camera.z}
			radius := world.config.residency_radius + chunk_size * 0.75
			if delta.x * delta.x + delta.y * delta.y > radius * radius {
				continue
			}
			world.desired_columns[Column_Coord{x, z}] = true
			minimum_height: f32 = 1e30
			maximum_height: f32 = -1e30
			points := [5][2]f32 {
				center_world,
				{f32(x) * chunk_size, f32(z) * chunk_size},
				{f32(x + 1) * chunk_size, f32(z) * chunk_size},
				{f32(x) * chunk_size, f32(z + 1) * chunk_size},
				{f32(x + 1) * chunk_size, f32(z + 1) * chunk_size},
			}
			for point in points {
				height := source.sample_column(source.data, point.x, point.y).surface_height
				minimum_height = min(minimum_height, height)
				maximum_height = max(maximum_height, height)
			}
			y_min := i32(math.floor((minimum_height - world.config.generation_depth) / chunk_size))
			y_max := i32(
				math.floor(
					(maximum_height + world.config.generation_height_above_surface) / chunk_size,
				),
			)
			for y := y_min; y <= y_max; y += 1 {
				coord := Chunk_Coord{x, y, z}
				world.desired[coord] = true
				if _, resident := world.chunks[coord]; !resident {
					dy := i64(y - i32(math.floor(camera.y / chunk_size)))
					dx := i64(x - center_x)
					dz := i64(z - center_z)
					append(&world.pending, Pending_Chunk{coord, dx * dx + dy * dy + dz * dz})
				}
			}
		}
	}
	slice.sort_by(world.pending[:], pending_less)
	for coord, chunk in world.chunks {
		if !world.desired[coord] {
			destroy_chunk(chunk)
			delete_key(&world.chunks, coord)
			world.stats.evicted_this_frame += 1
		}
	}
	for coord, columns in world.columns {
		if !world.desired_columns[coord] {
			free(columns)
			delete_key(&world.columns, coord)
		}
	}
}

recalculate_stats :: proc(world: ^World, modifications: ^sparse.World) {
	generated := world.stats.generated_this_frame
	evicted := world.stats.evicted_this_frame
	generation_ms := world.stats.generation_ms
	last_generation_ms := world.stats.last_generation_ms
	queries := world.stats.voxel_queries
	skips := world.stats.brick_skips
	gpu_bytes := world.stats.gpu_bytes
	world.stats = {
		generated_this_frame = generated,
		evicted_this_frame   = evicted,
		generation_ms        = generation_ms,
		last_generation_ms   = last_generation_ms,
		voxel_queries        = queries,
		brick_skips          = skips,
		gpu_bytes            = gpu_bytes,
	}
	world.stats.resident_chunks = u32(len(world.chunks))
	world.stats.resident_bricks = world.stats.resident_chunks * BRICKS_PER_CHUNK
	world.stats.resident_bytes += u64(len(world.columns) * size_of(Column_Block))
	for _, chunk in world.chunks {
		world.stats.detailed_voxels += u64(len(chunk.detailed_voxels))
		world.stats.resident_bytes += u64(
			size_of(Chunk) + len(chunk.detailed_voxels) * size_of(Material_Id),
		)
		for brick in chunk.bricks {
			switch brick.kind {
			case .EMPTY:
				world.stats.empty_bricks += 1
			case .SOLID:
				world.stats.solid_bricks += 1
				if u16(brick.material) < u16(len(world.stats.material_counts)) {
					world.stats.material_counts[int(brick.material)] += VOXELS_PER_BRICK
				}
			case .MIXED:
				world.stats.mixed_bricks += 1
			}
		}
		for material in chunk.detailed_voxels {
			if u16(material) < u16(len(world.stats.material_counts)) {
				world.stats.material_counts[int(material)] += 1
			}
		}
	}
	world.stats.pending_chunks = u32(max(len(world.pending) - world.pending_cursor, 0))
	if modifications != nil {
		world.stats.persistent_edits = u32(modifications.modified_count)
	}
}

update :: proc(world: ^World, camera: [3]f32, source: Source, modifications: ^sparse.World) {
	world.stats.generated_this_frame = 0
	world.stats.evicted_this_frame = 0
	world.stats.generation_ms = 0
	chunk_size := chunk_world_size(world)
	center := [2]i32 {
		i32(math.floor(camera.x / chunk_size)),
		i32(math.floor(camera.z / chunk_size)),
	}
	if !world.center_valid || center != world.center_chunk {
		rebuild_desired(world, camera, source)
	}
	for world.pending_cursor < len(world.pending) &&
	    world.stats.generated_this_frame < world.config.max_chunks_per_update {
		pending := world.pending[world.pending_cursor]
		world.pending_cursor += 1
		if !world.desired[pending.coord] {
			continue
		}
		if _, resident := world.chunks[pending.coord]; resident {
			continue
		}
		world.chunks[pending.coord] = generate_chunk(world, pending.coord, source, modifications)
		world.stats.generated_this_frame += 1
	}
	if world.stats.generated_this_frame > 0 || world.stats.evicted_this_frame > 0 {
		world.generation += 1
		recalculate_stats(world, modifications)
	} else {
		world.stats.pending_chunks = u32(max(len(world.pending) - world.pending_cursor, 0))
		if modifications != nil {
			world.stats.persistent_edits = u32(modifications.modified_count)
		}
	}
}

material_at :: proc(world: ^World, voxel: [3]i32) -> Material_Id {
	world.stats.voxel_queries += 1
	coord := voxel_to_chunk(voxel)
	chunk, ok := world.chunks[coord]
	if !ok {
		return AIR
	}
	local := local_voxel(voxel, coord)
	brick := chunk.bricks[brick_index(local)]
	switch brick.kind {
	case .EMPTY:
		return AIR
	case .SOLID:
		return brick.material
	case .MIXED:
		return chunk.detailed_voxels[int(brick.voxel_offset) + brick_voxel_index(local)]
	}
	return AIR
}

set_material :: proc(
	world: ^World,
	modifications: ^sparse.World,
	voxel: [3]i32,
	material: Material_Id,
) {
	if material == AIR {
		sparse.set(modifications, voxel, .FORCE_EMPTY)
	} else {
		sparse.set(modifications, voxel, .FORCE_SOLID, u32(material))
	}
	world.generation += 1
	coord := voxel_to_chunk(voxel)
	chunk, resident := world.chunks[coord]
	if !resident {
		return
	}
	local := local_voxel(voxel, coord)
	brick_index_value := brick_index(local)
	brick := &chunk.bricks[brick_index_value]
	if brick.kind != .MIXED {
		original := brick.material
		if brick.kind == .EMPTY {
			original = AIR
		}
		brick.voxel_offset = u32(len(chunk.detailed_voxels))
		for _ in 0 ..< VOXELS_PER_BRICK {
			append(&chunk.detailed_voxels, original)
		}
		brick.kind = .MIXED
	}
	chunk.detailed_voxels[int(brick.voxel_offset) + brick_voxel_index(local)] = material
	recalculate_stats(world, modifications)
}

raycast :: proc(world: ^World, origin, direction: [3]f32, max_distance: f32) -> Ray_Hit {
	length := math.sqrt(
		direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
	)
	if length <= 1e-6 {
		return {}
	}
	dir := direction / length
	voxel := world_to_voxel(world, origin)
	step := [3]i32{dir.x < 0 ? -1 : 1, dir.y < 0 ? -1 : 1, dir.z < 0 ? -1 : 1}
	voxel_size := world.config.voxel_size
	delta := [3]f32 {
		dir.x == 0 ? 1e30 : abs(voxel_size / dir.x),
		dir.y == 0 ? 1e30 : abs(voxel_size / dir.y),
		dir.z == 0 ? 1e30 : abs(voxel_size / dir.z),
	}
	voxel_min := voxel_to_world_min(world, voxel)
	next_boundary := [3]f32 {
		step.x > 0 ? voxel_min.x + voxel_size : voxel_min.x,
		step.y > 0 ? voxel_min.y + voxel_size : voxel_min.y,
		step.z > 0 ? voxel_min.z + voxel_size : voxel_min.z,
	}
	maximum := [3]f32 {
		dir.x == 0 ? 1e30 : (next_boundary.x - origin.x) / dir.x,
		dir.y == 0 ? 1e30 : (next_boundary.y - origin.y) / dir.y,
		dir.z == 0 ? 1e30 : (next_boundary.z - origin.z) / dir.z,
	}
	previous := voxel
	distance: f32
	for distance <= max_distance {
		material := material_at(world, voxel)
		if material != AIR {
			normal: [3]f32
			delta_voxel := voxel - previous
			if delta_voxel.x != 0 {normal.x = -f32(delta_voxel.x)}
			if delta_voxel.y != 0 {normal.y = -f32(delta_voxel.y)}
			if delta_voxel.z != 0 {normal.z = -f32(delta_voxel.z)}
			return {
				hit = true,
				voxel = voxel,
				previous_voxel = previous,
				position = origin + dir * distance,
				normal = normal,
				material = material,
				distance = distance,
			}
		}
		previous = voxel
		if maximum.x <= maximum.y && maximum.x <= maximum.z {
			distance = maximum.x
			maximum.x += delta.x
			voxel.x += step.x
		} else if maximum.y <= maximum.z {
			distance = maximum.y
			maximum.y += delta.y
			voxel.y += step.y
		} else {
			distance = maximum.z
			maximum.z += delta.z
			voxel.z += step.z
		}
	}
	return {}
}

force_regenerate_chunk :: proc(
	world: ^World,
	coord: Chunk_Coord,
	source: Source,
	modifications: ^sparse.World,
) {
	if old, ok := world.chunks[coord]; ok {
		destroy_chunk(old)
		world.chunks[coord] = generate_chunk(world, coord, source, modifications)
		recalculate_stats(world, modifications)
	}
}

destroy :: proc(world: ^World) {
	for _, chunk in world.chunks {
		destroy_chunk(chunk)
	}
	for _, columns in world.columns {
		free(columns)
	}
	delete(world.chunks)
	delete(world.columns)
	delete(world.desired)
	delete(world.desired_columns)
	delete(world.pending)
	world^ = {}
}
