package main
import "core:math/rand"
import vk "vendor:vulkan"
import "vulkan"


Voxel :: struct {
	color: u32, // Packed RGBA8 format
}

VoxelVolumeCPU :: struct {
	origin:       [3]u32,
	size:         [3]u32,
	data:         []Voxel, // CPU-side array of voxels
	voxel_buffer: vulkan.vulkan_buffer,
}


vulkan_upload_test_voxels :: proc(r: ^vulkan.vulkan_renderer, volume: VoxelVolumeCPU) {
	total_voxels := volume.size.x * volume.size.y * volume.size.z
	cpu_data := make([]Voxel, total_voxels, context.temp_allocator)

	// Fill data with a test sphere
	center := [3]f32{f32(volume.size.x) / 2, f32(volume.size.y) / 2, f32(volume.size.z) / 2}
	radius := f32(volume.size.x) * 0.4

	for z in 0 ..< volume.size.z {
		for y in 0 ..< volume.size.y {
			for x in 0 ..< volume.size.x {
				idx := x + (y * volume.size.x) + (z * volume.size.x * volume.size.y)

				dx := f32(x) - center.x
				dy := f32(y) - center.y
				dz := f32(z) - center.z
				dist := dx * dx + dy * dy + dz * dz

				if dist < radius * radius {
					random_color := u32(
						((u32(rand.float32_range(0, 1) * 255)) << 16) |
						((u32(rand.float32_range(0, 1) * 255)) << 8) |
						(u32(rand.float32_range(0, 1) * 255)),
					)
					cpu_data[idx].color = 0xFF000000 | random_color // Opaque with random RGB
				} else {
					// Empty space voxel
					cpu_data[idx].color = 0x00000000
				}
			}
		}
	}

	// Upload data to GPU

	voxel_buffer_size := int(total_voxels * size_of(Voxel))
	staging_buffer := vulkan.create_buffer(
		r,
		voxel_buffer_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	vulkan.write_buffer(r, &staging_buffer, raw_data(cpu_data), voxel_buffer_size)

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
	origin: [3]u32,
	size: [3]u32,
) -> VoxelVolumeCPU {
	volume := VoxelVolumeCPU {
		origin = origin,
		size   = size,
		data   = make([]Voxel, size.x * size.y * size.z, context.allocator),
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
