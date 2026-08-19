package voxel

import vox "../../../vendor/odin-vox"
import "core:fmt"
import "core:math/linalg"


Voxel :: struct {
	color: u32, // Packed RGBA8 format
}

pack_color :: proc {
	pack_color_u8,
	pack_color_c8,
	pack_color_c3,
}
pack_color_c8 :: proc(color: [4]u8) -> u32 {
	return (u32(color.r) << 24) | (u32(color.g) << 16) | (u32(color.b) << 8) | u32(color.a)
}
pack_color_c3 :: proc(color: [3]u8) -> u32 {
	return (u32(color.r) << 24) | (u32(color.g) << 16) | (u32(color.b) << 8) | 0xFF
}
pack_color_u8 :: proc(r: u8, g: u8, b: u8, a: u8) -> u32 {
	return (u32(r) << 24) | (u32(g) << 16) | (u32(b) << 8) | u32(a)
}

Volume :: struct {
	origin:   [3]f32,
	size:     [3]u32,
	rotation: matrix[3, 3]f32,
	data:     []Voxel,
}

create_volume :: proc(
	origin: [3]f32,
	size: [3]u32,
	rotation := linalg.Matrix3x3f32{1, 0, 0, 0, 1, 0, 0, 0, 1},
) -> Volume {
	return Volume {
		origin = origin,
		size = size,
		rotation = rotation,
		data = make([]Voxel, size.x * size.y * size.z, context.allocator),
	}
}

destroy_volume :: proc(volume: ^Volume) {
	delete(volume.data)
	volume^ = {}
}

destroy_volumes :: proc(volumes: []Volume) {
	for &volume in volumes {
		destroy_volume(&volume)
	}
	delete(volumes)
}

load_vox_file :: proc(file_path: string) -> []Volume {
	vox_data, ok := vox.load_from_file(file_path, context.temp_allocator)
	if !ok {
		fmt.eprintf("Failed to load .vox file: %s\n", file_path)
		return nil
	}

	has_instances := len(vox_data.instances) > 0
	count := has_instances ? len(vox_data.instances) : len(vox_data.models)
	volumes := make([dynamic]Volume, 0, count, context.allocator)

	for i in 0 ..< count {
		instance := vox.Vox_Instance {
			model_index = i,
			translation = {},
			rotation    = linalg.Matrix3x3f32{1, 0, 0, 0, 0, -1, 0, 1, 0},
		}
		if has_instances {
			instance = vox_data.instances[i]
		}
		if instance.model_index < 0 || instance.model_index >= len(vox_data.models) {
			fmt.eprintf("Invalid model index %d for instance %d\n", instance.model_index, i)
			continue
		}

		model := vox_data.models[instance.model_index]
		if model.size.x <= 0 || model.size.y <= 0 || model.size.z <= 0 || len(model.voxels) == 0 {
			continue
		}

		size := cast([3]u32)(model.size)
		volume := create_volume(instance.translation, size, instance.rotation)
		for source_voxel in model.voxels {
			index :=
				int(source_voxel.pos.x) +
				int(source_voxel.pos.y) * int(size.x) +
				int(source_voxel.pos.z) * int(size.x) * int(size.y)
			if index >= len(volume.data) {
				continue
			}
			volume.data[index].color = pack_color(vox_data.palette[source_voxel.color_index])
		}
		append(&volumes, volume)
	}

	result := make([]Volume, len(volumes), context.allocator)
	copy(result, volumes[:])
	delete(volumes)
	return result
}
