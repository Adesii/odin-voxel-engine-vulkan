package delta_core

import fn "../../../vendor/odin-fastnoise2"
import voxel "../../engine/voxel"
import "core:math/rand"

create_test_world :: proc() -> []voxel.Volume {
	node := fn.NewFromEncodedNodeTree("DQkdCRAJBgwDzcxMPwtmZpZABAMK1yM+Cw@AEAE")
	defer fn.DeleteNodeRef(node)

	array_size: i32 = 64
	noise := make([]f32, array_size * array_size * array_size, context.allocator)
	defer delete(noise)
	min_max := [2]f32{0, 1}
	fn.GenUniformGrid(
		node,
		noise,
		[3]f32{},
		[3]i32{array_size, array_size, array_size},
		[3]f32{8, 8, 8},
		1337,
		&min_max,
	)

	volumes := make([dynamic]voxel.Volume, context.allocator)
	chunk_size: i32 = 16
	chunk_count := array_size / chunk_size
	for chunk_x: i32 = 0; chunk_x < chunk_count; chunk_x += 1 {
		for chunk_y: i32 = 0; chunk_y < chunk_count; chunk_y += 1 {
			for chunk_z: i32 = 0; chunk_z < chunk_count; chunk_z += 1 {
				origin := [3]f32 {
					f32(chunk_x * chunk_size),
					f32(chunk_y * chunk_size),
					f32(chunk_z * chunk_size),
				}
				size := [3]u32{u32(chunk_size), u32(chunk_size), u32(chunk_size)}
				volume := voxel.create_volume(origin, size)
				for z in 0 ..< size.z {
					for y in 0 ..< size.y {
						for x in 0 ..< size.x {
							noise_index :=
								(u32(chunk_x * chunk_size) + x) +
								(u32(chunk_y * chunk_size) + y) * u32(array_size) +
								(u32(chunk_z * chunk_size) + z) * u32(array_size * array_size)
							if noise[noise_index] <= min_max.x + 0.4 {
								continue
							}
							index := z * size.x * size.y + y * size.x + x
							shade := u8(rand.uint32_range(0, 25))
							volume.data[index].color = voxel.pack_color(
								[3]u8{255 - shade, 255 - shade, 255 - shade},
							)
						}
					}
				}
				append(&volumes, volume)
			}
		}
	}

	model_volumes := voxel.load_vox_file("assets/models/vox/character/chr_cat.vox")
	for volume in model_volumes {
		append(&volumes, volume)
	}
	delete(model_volumes)

	result := make([]voxel.Volume, len(volumes), context.allocator)
	copy(result, volumes[:])
	delete(volumes)
	return result
}
