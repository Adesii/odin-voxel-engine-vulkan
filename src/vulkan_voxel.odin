package main

import vma "../vendor/odin-vma"
import "core:fmt"
import "core:mem"
import v "shaders/voxel_shader"
import vk "vendor:vulkan"
import "vulkan"

MAX_VOLUMES :: 256

Voxel_Buffer_Context :: struct {
	uniform_buffer:          vulkan.vulkan_buffer,
	descriptor_set:          vk.DescriptorSet,
	descriptor_set_layout:   vk.DescriptorSetLayout,
	compute_pipeline_layout: vk.PipelineLayout,
	compute_pipeline:        vk.Pipeline,
	blit_image:              vulkan.vulkan_image,
	volumes:                 [dynamic]VoxelVolumeCPU,
	volume_buffer:           vulkan.vulkan_buffer,
	uniform_buffer_size:     int,
}

Camera :: struct {
	position:       [3]f32,
	rotation:       quaternion128,
	rotation_thing: [2]f32,
	view_proj:      matrix[4, 4]f32,
	inv_view_proj:  matrix[4, 4]f32,
}

vulkan_init_voxel_buffers :: proc(r: ^vulkan.vulkan_renderer) {
	ctx := &state.voxel_ctx
	grid_size := state.grid_size
	ctx.uniform_buffer_size = size_of(v.CameraUniforms) + (MAX_VOLUMES * size_of(v.VoxelVolume))
	// Create uniform buffer
	ctx.uniform_buffer = vulkan.create_buffer(
		r,
		ctx.uniform_buffer_size,
		{.UNIFORM_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)


	// Allocate descriptor set for the voxel shader
	ctx.descriptor_set = vulkan.allocate_descriptor_set(
		r,
		"voxel_shader",
		{.COMPUTE},
		{
			{binding = v.VOXEL_BINDING_G_CAMERA, type = .UNIFORM_BUFFER},
			{binding = v.VOXEL_BINDING_G_VOLUME, type = .STORAGE_BUFFER},
			{binding = v.VOXEL_BINDING_G_OUTPUTFRAMEBUFFER, type = .STORAGE_IMAGE},
		},
	)

	image, alloc := vulkan.create_image(
		r,
		r.extent.width,
		r.extent.height,
		r.surface_format.format,
		{.STORAGE, .TRANSFER_SRC, .INPUT_ATTACHMENT, .SAMPLED},
		{.DEVICE_LOCAL},
	)
	// Run this ONCE right after allocating your output storage image
	cmd := vulkan.begin_single_use_commands(r)

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

	vulkan.end_single_use_commands(r, cmd)

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
	sampler := vulkan.create_sampler(r, .LINEAR, .CLAMP_TO_EDGE)
	view: vk.ImageView
	vulkan.VK_CHECK(vk.CreateImageView(r.device, &view_info, nil, &view), "vkCreateImageView")
	ctx.blit_image = vulkan.vulkan_image {
		image      = image,
		allocation = alloc,
		view       = view,
		sampler    = sampler,
	}

	vulkan.renderer.voxel.image_blit = ctx.blit_image
	//Test voxel entry point
	// volume1 := voxel_create_new_volume(r, [3]u32{0, 0, 0}, [3]u32{64, 64, 64})
	// append(&ctx.volumes, volume1)
	// volume2 := voxel_create_new_volume(r, [3]u32{16, 0, 0}, [3]u32{64, 64, 64})
	// append(&ctx.volumes, volume2)
	//
	// vulkan_upload_test_voxels(r, volume1)
	// vulkan_upload_test_voxels(r, volume2)

	add_new_volume(r, ctx, [3]u32{0, 0, 0}, [3]u32{64, 64, 64})
	add_new_volume(r, ctx, [3]u32{16, 0, 0}, [3]u32{64, 64, 64})
	add_new_volume(r, ctx, [3]u32{0, 96, 5}, [3]u32{64, 64, 64})

	amount := int(size_of(v.VoxelVolume) * u32(len(ctx.volumes)))

	ctx.volume_buffer = vulkan.create_buffer(
		r,
		amount,
		{.STORAGE_BUFFER, .TRANSFER_DST},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	vulkan_update_voxel_descriptor_set(r, ctx)
	vulkan_create_compute_pipeline_for_voxels(r, &state.voxel_ctx)
}

add_new_volume :: proc(
	r: ^vulkan.vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
	origin: [3]u32,
	size: [3]u32,
) {
	new_volume := voxel_create_new_volume(r, origin, size)
	append(&ctx.volumes, new_volume)
	vulkan_upload_test_voxels(r, new_volume)
	vulkan_update_voxel_descriptor_set(r, ctx) // Update descriptor set to account for new buffer data
}
vulkan_update_voxel_descriptor_set :: proc(
	r: ^vulkan.vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
) {
	// 1. Point to your Uniform Buffer (Camera + Grid Size data)
	uniform_buffer_info := vk.DescriptorBufferInfo {
		buffer = ctx.uniform_buffer.buffer,
		offset = 0,
		range  = vk.DeviceSize(ctx.uniform_buffer_size), // Handled by your reflection constant!
	}

	// 2. Point to your massive Voxel Storage Buffer
	voxel_buffer_info := vk.DescriptorBufferInfo {
		buffer = ctx.volume_buffer.buffer,
		offset = 0,
		range  = vk.DeviceSize(size_of(v.VoxelVolume) * u32(len(ctx.volumes))),
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


vulkan_update_voxel_uniforms :: proc(
	r: ^vulkan.vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
	camera: Camera,
	volumes: []VoxelVolumeCPU,
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

	assert(len(volumes) <= MAX_VOLUMES, "Exceeded maximum allowed voxel volumes!")
	packed_volumes := make([]v.VoxelVolume, len(volumes), context.temp_allocator)
	defer delete(packed_volumes)

	for idx := 0; idx < len(volumes); idx += 1 {
		// 2. Fetch via a strict pointer reference to prevent any structural value copy decay
		src_volume := &volumes[idx]
		assert(
			src_volume.voxel_buffer.buffer != 0,
			"CRITICAL: The target buffer handle itself is uninitialized (0)!",
		)
		gpu_ptr := vulkan.get_gpu_address(r.device, src_volume.voxel_buffer.buffer)

		packed_volumes[idx] = v.VoxelVolume {
			origin_x = src_volume.origin.x,
			origin_y = src_volume.origin.y,
			origin_z = src_volume.origin.z,
			size_x   = src_volume.size.x,
			size_y   = src_volume.size.y,
			size_z   = src_volume.size.z,
			data     = u64(gpu_ptr),
		}
	}

	volume_data: rawptr
	vma.MapMemory(r.allocator_vma, ctx.volume_buffer.allocation, &volume_data)
	mem.copy(volume_data, raw_data(packed_volumes), size_of(v.VoxelVolume) * len(packed_volumes))
	vma.UnmapMemory(r.allocator_vma, ctx.volume_buffer.allocation)

	vma.UnmapMemory(r.allocator_vma, ctx.uniform_buffer.allocation)
}

vulkan_create_compute_pipeline_for_voxels :: proc(
	r: ^vulkan.vulkan_renderer,
	ctx: ^Voxel_Buffer_Context,
) {
	ctx.compute_pipeline_layout = vulkan.create_pipeline_layout(
		r,
		"voxel",
		{.COMPUTE},
		{
			{binding = v.VOXEL_BINDING_G_CAMERA, type = .UNIFORM_BUFFER},
			{binding = v.VOXEL_BINDING_G_VOLUME, type = .STORAGE_BUFFER},
			{binding = v.VOXEL_BINDING_G_OUTPUTFRAMEBUFFER, type = .STORAGE_IMAGE},
		},
	)

	ctx.compute_pipeline = vulkan.create_compute_pipeline(
		r,
		v.VOXEL_MAIN_ENTRY_POINT,
		"voxel",
		ctx.compute_pipeline_layout,
	)
}

vulkan_run :: proc(r: ^vulkan.vulkan_renderer, cmd: vk.CommandBuffer) {
	ctx := &state.voxel_ctx
	camera := state.camera
	grid_size := state.grid_size
	vulkan_update_voxel_uniforms(r, ctx, camera, ctx.volumes[:])

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
