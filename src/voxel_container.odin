package main
import vox "../vendor/odin-vox"
import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import vk "vendor:vulkan"
import "vulkan"


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

VoxelVolumeCPU :: struct {
	origin:       [3]f32,
	size:         [3]u32,
	rotation:     matrix[3, 3]f32,
	data:         []Voxel, // CPU-side array of voxels
	voxel_buffer: vulkan.vulkan_buffer,
}

voxel_generate_test_sphere :: proc(size: [3]u32) -> []Voxel {
	total_voxels := size.x * size.y * size.z
	voxels := make([]Voxel, total_voxels, context.allocator)

	center := [3]f32{f32(size.x) / 2, f32(size.y) / 2, f32(size.z) / 2}
	radius := f32(size.x) * 0.4

	for z in 0 ..< size.z {
		for y in 0 ..< size.y {
			for x in 0 ..< size.x {
				idx := x + (y * size.x) + (z * size.x * size.y)

				dx := f32(x) - center.x
				dy := f32(y) - center.y
				dz := f32(z) - center.z
				dist := dx * dx + dy * dy + dz * dz

				if dist < radius * radius {
					random_color := pack_color(
						(u8(rand.float32_range(0, 1) * 255)),
						(u8(rand.float32_range(0, 1) * 255)),
						(u8(rand.float32_range(0, 1) * 255)),
						0xFF, // Opaque alpha
					)
					voxels[idx].color = random_color // Opaque with random RGB
				} else {
					voxels[idx].color = 0x00000000 // Empty space voxel
				}
			}
		}
	}

	return voxels
}

vulkan_upload_test_voxels :: proc(r: ^vulkan.vulkan_renderer, volume: VoxelVolumeCPU) {
	total_voxels := volume.size.x * volume.size.y * volume.size.z
	// fmt.printfln("Uploading %d voxels to GPU", total_voxels)
	voxel_buffer_size := int(total_voxels * size_of(Voxel))
	staging_buffer := vulkan.create_buffer(
		r,
		voxel_buffer_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	vulkan.write_buffer(r, &staging_buffer, raw_data(volume.data), voxel_buffer_size)

	cmd := vulkan.begin_single_use_commands(r)
	copy_region := vk.BufferCopy {
		srcOffset = 0,
		dstOffset = 0,
		size      = vk.DeviceSize(voxel_buffer_size),
	}
	vk.CmdCopyBuffer(cmd, staging_buffer.buffer, volume.voxel_buffer.buffer, 1, &copy_region)
	vulkan.end_single_use_commands(r, cmd)

	vulkan.destroy_buffer(r, &staging_buffer)
}


voxel_create_new_volume :: proc(
	r: ^vulkan.vulkan_renderer,
	origin: [3]f32,
	size: [3]u32,
	rotation: matrix[3, 3]f32 = linalg.Matrix3x3f32{},
) -> VoxelVolumeCPU {
	volume := VoxelVolumeCPU {
		origin   = origin,
		size     = size,
		rotation = rotation,
		data     = make([]Voxel, size.x * size.y * size.z, context.allocator),
	}

	voxel_buffer_size := int(size.x * size.y * size.z * size_of(Voxel))

	// Ensure it is 16-byte aligned out of abundance of caution for the driver
	if voxel_buffer_size % 16 != 0 {
		voxel_buffer_size += 16 - (voxel_buffer_size % 16)
	}
	volume.voxel_buffer = vulkan.create_buffer(
		r,
		voxel_buffer_size,
		{
			.TRANSFER_DST,
			.STORAGE_BUFFER,
			.SHADER_DEVICE_ADDRESS,
			.SHADER_DEVICE_ADDRESS_EXT,
			.SHADER_DEVICE_ADDRESS_KHR,
		},
		{.DEVICE_LOCAL},
	)

	return volume
}


voxel_from_vox_file :: proc(r: ^vulkan.vulkan_renderer, file_path: string) -> []VoxelVolumeCPU {
	vox_data, ok := vox.load_from_file(file_path)
	if !ok {
		fmt.printfln("Failed to load .vox file: %s", file_path)
		return nil
	}

	vox.debug_print_vox(vox_data)
	instance_draw: bool = len(vox_data.instances) > 0 ? true : false
	count := instance_draw ? len(vox_data.instances) : len(vox_data.models)

	volumes := make([]VoxelVolumeCPU, count, context.allocator)
	defer delete(volumes)
	// for instance, i in vox_data.instances {
	for i in 0 ..< count {
		instance: vox.Vox_Instance
		if instance_draw {
			instance = vox_data.instances[i]
		} else {
			instance = vox.Vox_Instance {
				translation = [3]f32{0, 0, 0},
				rotation    = linalg.Matrix3x3f32{1, 0, 0, 0, 0, -1, 0, 1, 0},
			}


		}
		if instance.model_index >= len(vox_data.models) {
			fmt.printfln("Invalid model index %d for instance %d", instance.model_index, i)
			continue
		}
		model: vox.Model
		if instance_draw {
			model = vox_data.models[instance.model_index]
		} else {
			model = vox_data.models[i]
		}
		if model.size.x == 0 || model.size.y == 0 || model.size.z == 0 || len(model.voxels) == 0 {
			fmt.printfln("Skipping empty model %d with size %v", instance.model_index, model.size)
			continue
		}
		origin := instance.translation
		size := cast([3]u32)(model.size)
		rotation := instance.rotation
		volume := voxel_create_new_volume(r, origin, size, rotation)

		for voxel in model.voxels {
			idx :=
				int(voxel.pos.x) +
				(int(voxel.pos.y) * int(size.x)) +
				(int(voxel.pos.z) * int(size.x) * int(size.y))

			if idx < len(volume.data) {
				palette_color := vox_data.palette[voxel.color_index]
				color := pack_color(palette_color)

				volume.data[idx].color = color // Opaque with palette RGB
			}
		}
		// fmt.printfln("Loaded model %d with %d voxels", i, len(model.voxels))

		vulkan_upload_test_voxels(r, volume)
		volumes[i] = volume
	}
	//prune volumes with no voxels
	valid_volumes := make([dynamic]VoxelVolumeCPU, 0, context.allocator)
	defer delete(valid_volumes)
	for volume in volumes {
		if len(volume.data) > 0 {
			append(&valid_volumes, volume)
		}
	}
	result_volumes := make([]VoxelVolumeCPU, len(valid_volumes), context.allocator)
	copy(result_volumes, valid_volumes[:])

	return result_volumes
}
