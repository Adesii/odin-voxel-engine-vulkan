package main

import vma "../vendor/odin-vma"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import v "shaders/voxel_shader"
import vk "vendor:vulkan"


Voxel :: struct {
	color: u32, // Packed RGBA8 format
}

Voxel_Buffer_Context :: struct {
	uniform_buffer:          vulkan_buffer,
	voxel_buffer:            vulkan_buffer,
	descriptor_set:          vk.DescriptorSet,
	descriptor_set_layout:   vk.DescriptorSetLayout,
	compute_pipeline_layout: vk.PipelineLayout,
	compute_pipeline:        vk.Pipeline,
	blit_image:              vulkan_image,
}

Camera :: struct {
	position:       [3]f32,
	rotation:       quaternion128,
	rotation_thing: [2]f32,
	view_proj:      matrix[4, 4]f32,
	inv_view_proj:  matrix[4, 4]f32,
}

vulkan_init_voxel_buffers :: proc(
	r: ^vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
	grid_size: [3]u32,
) {
	// Create uniform buffer
	ctx.uniform_buffer = vulkan_create_buffer(
		r,
		v.VOXEL_UNIFORM_BUFFER_SIZE,
		{.UNIFORM_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	// Create voxel buffer (initially empty, will be updated each frame)
	voxel_buffer_size := grid_size.x * grid_size.y * grid_size.z * size_of(Voxel)
	ctx.voxel_buffer = vulkan_create_buffer(
		r,
		int(voxel_buffer_size),
		{.STORAGE_BUFFER, .TRANSFER_DST},
		{.DEVICE_LOCAL},
	)

	// Allocate descriptor set for the voxel shader
	ctx.descriptor_set = vulkan_allocate_descriptor_set(
		r,
		"voxel_shader",
		{.COMPUTE},
		{
			{binding = v.VOXEL_BINDING_DATA, type = .UNIFORM_BUFFER},
			{binding = v.VOXEL_BINDING_G_VOLUME, type = .STORAGE_BUFFER},
			{binding = v.VOXEL_BINDING_G_OUTPUTFRAMEBUFFER, type = .STORAGE_IMAGE},
		},
	)

	image, alloc := vulkan_create_image(
		r,
		r.extent.width,
		r.extent.height,
		r.surface_format.format,
		{.STORAGE, .TRANSFER_SRC, .INPUT_ATTACHMENT, .SAMPLED},
		{.DEVICE_LOCAL},
	)
	// Run this ONCE right after allocating your output storage image
	cmd := vulkan_begin_single_use_commands(r)

	barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = .UNDEFINED,
		newLayout = .GENERAL, // The golden layout for compute storage textures
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		srcAccessMask = {},
		dstAccessMask = {.SHADER_WRITE, .SHADER_READ},
	}

	vk.CmdPipelineBarrier(
		cmd,
		{.TOP_OF_PIPE}, // source stage
		{.COMPUTE_SHADER}, // destination stage
		{},
		0,
		nil,
		0,
		nil,
		1,
		&barrier,
	)

	vulkan_end_single_use_commands(r, cmd)

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = .D2,
		format = r.surface_format.format,
		components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	sampler := vulkan_create_sampler(r, .LINEAR, .CLAMP_TO_EDGE)
	view: vk.ImageView
	VK_CHECK(vk.CreateImageView(r.device, &view_info, nil, &view), "vkCreateImageView")
	ctx.blit_image = vulkan_image {
		image      = image,
		allocation = alloc,
		view       = view,
		sampler    = sampler,
	}
	vulkan_update_voxel_descriptor_set(r, ctx)
}
vulkan_update_voxel_descriptor_set :: proc(r: ^vulkan_renderer, ctx: ^Voxel_Buffer_Context) {
	// 1. Point to your Uniform Buffer (Camera + Grid Size data)
	uniform_buffer_info := vk.DescriptorBufferInfo {
		buffer = ctx.uniform_buffer.buffer,
		offset = 0,
		range  = vk.DeviceSize(v.VOXEL_UNIFORM_BUFFER_SIZE), // Handled by your reflection constant!
	}

	// 2. Point to your massive Voxel Storage Buffer
	voxel_buffer_info := vk.DescriptorBufferInfo {
		buffer = ctx.voxel_buffer.buffer,
		offset = 0,
		range  = vk.DeviceSize(vk.WHOLE_SIZE), // Maps the entire array automatically
	}

	// 3. Create an array of writes (one per binding slot)
	descriptor_writes: [3]vk.WriteDescriptorSet

	// Write for Binding 0: Uniform Buffer
	descriptor_writes[0] = vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.descriptor_set,
		dstBinding      = 0, // Matches your layout slot 0
		descriptorCount = 1,
		descriptorType  = .UNIFORM_BUFFER,
		pBufferInfo     = &uniform_buffer_info,
	}

	// Write for Binding 1: Voxel Storage Buffer
	descriptor_writes[1] = vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.descriptor_set,
		dstBinding      = 1, // Matches your layout slot 1
		descriptorCount = 1,
		descriptorType  = .STORAGE_BUFFER,
		pBufferInfo     = &voxel_buffer_info,
	}

	description_image_info := vk.DescriptorImageInfo {
		imageView   = ctx.blit_image.view,
		imageLayout = .GENERAL, // Make sure this matches how you transition the image in your command buffer
		// sampler     = ctx.blit_image.sampler, // Not needed for storage images
	}
	// Write for Binding 2: Output Storage Image
	descriptor_writes[2] = vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.descriptor_set,
		dstBinding      = 2, // Matches your layout slot 2
		descriptorCount = 1,
		descriptorType  = .STORAGE_IMAGE,
		pImageInfo      = &description_image_info,
	}


	// 4. Send the data to Vulkan to wire up the internal pointers
	vk.UpdateDescriptorSets(r.device, u32(len(descriptor_writes)), &descriptor_writes[0], 0, nil)
}


vulkan_upload_test_voxels :: proc(
	r: ^vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
	grid_size: [3]u32,
) {
	total_voxels := grid_size.x * grid_size.y * grid_size.z
	cpu_data := make([]Voxel, total_voxels, context.temp_allocator)

	// Fill data with a test sphere
	center := [3]f32{f32(grid_size.x) / 2, f32(grid_size.y) / 2, f32(grid_size.z) / 2}
	radius := f32(grid_size.x) * 0.4

	for z in 0 ..< grid_size.z {
		for y in 0 ..< grid_size.y {
			for x in 0 ..< grid_size.x {
				idx := x + (y * grid_size.x) + (z * grid_size.x * grid_size.y)

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
	staging_buffer := vulkan_create_buffer(
		r,
		voxel_buffer_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	vulkan_write_buffer(r, &staging_buffer, raw_data(cpu_data), voxel_buffer_size)

	cmd := vulkan_begin_single_use_commands(r)
	copy_region := vk.BufferCopy {
		srcOffset = 0,
		dstOffset = 0,
		size      = vk.DeviceSize(voxel_buffer_size),
	}
	vk.CmdCopyBuffer(cmd, staging_buffer.buffer, ctx.voxel_buffer.buffer, 1, &copy_region)
	vulkan_end_single_use_commands(r, cmd)

	vulkan_destroy_buffer(r, &staging_buffer)

}


vulkan_update_voxel_uniforms :: proc(
	r: ^vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
	camera: Camera,
	grid_size: [3]u32,
) {
	// Create uniform data

	data: rawptr
	vma.MapMemory(r.allocator_vma, ctx.uniform_buffer.allocation, &data)

	runtime_camera := v.CameraUniforms {
		viewProj    = camera.view_proj,
		position    = camera.position,
		invViewProj = camera.inv_view_proj,
	}
	mem.copy(data, &runtime_camera, size_of(v.CameraUniforms))

	volume_data_ptr := mem.ptr_offset(transmute(^u8)data, int(v.VOXEL_UNIFORM_BUFFER_SIZE - 16))
	volume_data := v.VoxelVolume {
		size = grid_size,
	}
	mem.copy(volume_data_ptr, &volume_data, size_of(v.VoxelVolume))

	vma.UnmapMemory(r.allocator_vma, ctx.uniform_buffer.allocation)
}

vulkan_create_compute_pipeline_for_voxels :: proc(
	r: ^vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
) {
	ctx.compute_pipeline_layout = vulkan_create_pipeline_layout(
		r,
		"voxel",
		{.COMPUTE},
		{
			{binding = v.VOXEL_BINDING_DATA, type = .UNIFORM_BUFFER},
			{binding = v.VOXEL_BINDING_G_VOLUME, type = .STORAGE_BUFFER},
			{binding = v.VOXEL_BINDING_G_OUTPUTFRAMEBUFFER, type = .STORAGE_IMAGE},
		},
	)

	ctx.compute_pipeline = vulkan_create_compute_pipeline(
		r,
		v.VOXEL_MAIN_ENTRY_POINT,
		"voxel",
		ctx.compute_pipeline_layout,
	)
}

vulkan_run :: proc(
	r: ^vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
	camera: Camera,
	grid_size: [3]u32,
	cmd: vk.CommandBuffer,
) {
	vulkan_update_voxel_uniforms(r, ctx, camera, grid_size)

	// Record and submit compute command buffer
	vk.CmdBindPipeline(cmd, .COMPUTE, ctx.compute_pipeline)
	vk.CmdBindDescriptorSets(
		cmd,
		.COMPUTE,
		ctx.compute_pipeline_layout,
		0,
		1,
		&ctx.descriptor_set,
		0,
		nil,
	)

	group_x := u32((r.extent.width + 7) / 8)
	group_y := u32((r.extent.height + 7) / 8)

	vk.CmdDispatch(cmd, group_x, group_y, 1)

	compute_barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = .GENERAL,
		newLayout = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = ctx.blit_image.image,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		srcAccessMask = {.SHADER_WRITE},
		dstAccessMask = {.SHADER_READ},
	}
	vk.CmdPipelineBarrier(
		cmd,
		{.COMPUTE_SHADER},
		{.FRAGMENT_SHADER},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&compute_barrier,
	)

}
