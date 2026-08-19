package sparse

import "core:math"

BRICK_SIZE :: 8
BRICK_CELL_COUNT :: BRICK_SIZE * BRICK_SIZE * BRICK_SIZE

Override_State :: enum u32 {
	UNMODIFIED,
	FORCE_EMPTY,
	FORCE_SOLID,
}

Voxel_Override :: struct {
	state:    Override_State,
	material: u32,
}

Brick_Key :: struct {
	x, y, z: i32,
}

Brick :: struct {
	cells:          [BRICK_CELL_COUNT]Voxel_Override,
	modified_count: u32,
}

World :: struct {
	voxel_size:     f32,
	bricks:         map[Brick_Key]^Brick,
	modified_count: u32,
}

Override_Record :: struct {
	voxel:    [3]i32,
	state:    Override_State,
	material: u32,
	_padding: [3]u32,
}

init :: proc(world: ^World, voxel_size: f32) -> bool {
	if voxel_size <= 0 {
		return false
	}
	world^ = {}
	world.voxel_size = voxel_size
	world.bricks = make(map[Brick_Key]^Brick)
	return true
}

floor_div :: proc(value, divisor: i32) -> i32 {
	quotient := value / divisor
	if value % divisor < 0 {
		quotient -= 1
	}
	return quotient
}

split_coordinate :: proc(voxel: [3]i32) -> (Brick_Key, [3]i32) {
	key := Brick_Key {
		x = floor_div(voxel.x, BRICK_SIZE),
		y = floor_div(voxel.y, BRICK_SIZE),
		z = floor_div(voxel.z, BRICK_SIZE),
	}
	local := [3]i32 {
		voxel.x - key.x * BRICK_SIZE,
		voxel.y - key.y * BRICK_SIZE,
		voxel.z - key.z * BRICK_SIZE,
	}
	return key, local
}

cell_index :: proc(local: [3]i32) -> int {
	return int(local.z * BRICK_SIZE * BRICK_SIZE + local.y * BRICK_SIZE + local.x)
}

set :: proc(world: ^World, voxel: [3]i32, state: Override_State, material: u32 = 0) {
	key, local := split_coordinate(voxel)
	brick, found := world.bricks[key]
	if !found {
		if state == .UNMODIFIED {
			return
		}
		brick = new(Brick)
		world.bricks[key] = brick
	}
	index := cell_index(local)
	previous := brick.cells[index].state
	if previous == .UNMODIFIED && state != .UNMODIFIED {
		brick.modified_count += 1
		world.modified_count += 1
	} else if previous != .UNMODIFIED && state == .UNMODIFIED {
		brick.modified_count -= 1
		world.modified_count -= 1
	}
	brick.cells[index] = {
		state    = state,
		material = material,
	}
	if brick.modified_count == 0 {
		delete_key(&world.bricks, key)
		free(brick)
	}
}

get :: proc(world: ^World, voxel: [3]i32) -> Voxel_Override {
	key, local := split_coordinate(voxel)
	brick, found := world.bricks[key]
	if !found {
		return {}
	}
	return brick.cells[cell_index(local)]
}

world_to_voxel :: proc(world: ^World, position: [3]f32) -> [3]i32 {
	return {
		i32(math.floor(position.x / world.voxel_size)),
		i32(math.floor(position.y / world.voxel_size)),
		i32(math.floor(position.z / world.voxel_size)),
	}
}

set_world_position :: proc(
	world: ^World,
	position: [3]f32,
	state: Override_State,
	material: u32 = 0,
) {
	set(world, world_to_voxel(world, position), state, material)
}

collect_records :: proc(world: ^World, allocator := context.allocator) -> []Override_Record {
	records := make([]Override_Record, int(world.modified_count), allocator)
	record_index := 0
	for key, brick in world.bricks {
		for z in 0 ..< BRICK_SIZE {
			for y in 0 ..< BRICK_SIZE {
				for x in 0 ..< BRICK_SIZE {
					cell := brick.cells[z * BRICK_SIZE * BRICK_SIZE + y * BRICK_SIZE + x]
					if cell.state == .UNMODIFIED {
						continue
					}
					records[record_index] = {
						voxel    = {
							key.x * BRICK_SIZE + i32(x),
							key.y * BRICK_SIZE + i32(y),
							key.z * BRICK_SIZE + i32(z),
						},
						state    = cell.state,
						material = cell.material,
					}
					record_index += 1
				}
			}
		}
	}
	return records
}

apply_records :: proc(world: ^World, records: []Override_Record) {
	for record in records {
		set(world, record.voxel, record.state, record.material)
	}
}

brick_count :: proc(world: ^World) -> int {
	return len(world.bricks)
}

destroy :: proc(world: ^World) {
	for _, brick in world.bricks {
		free(brick)
	}
	delete(world.bricks)
	world^ = {}
}
