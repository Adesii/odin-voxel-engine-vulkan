package voxel_renderer

import vma "../../../../vendor/odin-vma"
import bindings "../../../shaders/voxel_shader"
import view "../../view"
import voxel "../../voxel"
import shader_assets "../shader_assets"
import vulkan "../vulkan"
import "core:math/linalg"
import "core:mem"
import vk "vendor:vulkan"

MAX_VOLUMES :: 8096

Volume_Handle :: distinct u32

gpu_volume :: struct {
	origin:         [3]f32,
	size:           [3]u32,
	rotation:       matrix[3, 3]f32,
	buffer:         vulkan.Buffer,
	device_address: u64,
}

Context :: struct {
	uniform_buffers:   [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	volume_buffers:    [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	descriptor_sets:   [vulkan.MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	descriptor_layout: vk.DescriptorSetLayout,
	pipeline_layout:   vk.PipelineLayout,
	pipeline:          vk.Pipeline,
	shader_module:     vk.ShaderModule,
	output:            vulkan.Image,
	output_layout:     vk.ImageLayout,
	volumes:           [dynamic]gpu_volume,
	packed_volumes:    [MAX_VOLUMES]bindings.VoxelVolume,
}

Frame_Input :: struct {
	renderer: ^Context,
	camera:   view.Camera,
}

init :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ctx^ = {}
	bindings_desc := [?]vulkan.Descriptor_Binding {
		{binding = bindings.VOXEL_BINDING_G_CAMERA, type = .UNIFORM_BUFFER},
		{binding = bindings.VOXEL_BINDING_G_VOLUME, type = .STORAGE_BUFFER},
		{binding = bindings.VOXEL_BINDING_G_OUTPUTFRAMEBUFFER, type = .STORAGE_IMAGE},
	}
	ctx.descriptor_layout = vulkan.create_descriptor_set_layout(r, {.COMPUTE}, bindings_desc[:])
	ctx.pipeline_layout = vulkan.create_pipeline_layout(r, ctx.descriptor_layout)

	for i in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		ctx.uniform_buffers[i] = vulkan.create_buffer(
			r,
			size_of(bindings.CameraUniforms),
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.volume_buffers[i] = vulkan.create_buffer(
			r,
			MAX_VOLUMES * size_of(bindings.VoxelVolume),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.descriptor_sets[i] = vulkan.allocate_descriptor_set(r, ctx.descriptor_layout)
	}

	create_output(ctx, r)
	reload_shader(ctx, r)
}

create_output :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	image, allocation := vulkan.create_image(
		r,
		r.extent.width,
		r.extent.height,
		r.surface_format.format,
		{.STORAGE, .SAMPLED},
		{.DEVICE_LOCAL},
	)
	command_buffer := vulkan.begin_single_use_commands(r)
	barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = .UNDEFINED,
		newLayout = .GENERAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		srcAccessMask = {},
		dstAccessMask = {.SHADER_WRITE},
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.TOP_OF_PIPE},
		{.COMPUTE_SHADER},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&barrier,
	)
	vulkan.end_single_use_commands(r, command_buffer)

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
	image_view: vk.ImageView
	vulkan.VK_CHECK(
		vk.CreateImageView(r.device, &view_info, nil, &image_view),
		"vkCreateImageView",
	)
	ctx.output = vulkan.Image {
		image      = image,
		view       = image_view,
		sampler    = vulkan.create_sampler(r, .LINEAR, .CLAMP_TO_EDGE),
		allocation = allocation,
	}
	ctx.output_layout = .GENERAL
	update_descriptors(ctx, r)
}

destroy_output :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	vulkan.destroy_image(r, &ctx.output)
	ctx.output_layout = .UNDEFINED
}

before_swapchain_destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	destroy_output(ctx, r)
}

after_swapchain_create :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	create_output(ctx, r)
}

output_image :: proc(ctx: ^Context) -> vulkan.Image {
	return ctx.output
}

reload_shader :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	_ = vk.DeviceWaitIdle(r.device)
	if ctx.pipeline != {} {
		vk.DestroyPipeline(r.device, ctx.pipeline, nil)
		ctx.pipeline = {}
	}
	if ctx.shader_module != {} {
		vk.DestroyShaderModule(r.device, ctx.shader_module, nil)
		ctx.shader_module = {}
	}
	shader_code := shader_assets.load_bytes("voxel.spirv")
	defer delete(shader_code)
	ctx.shader_module = vulkan.create_shader_module(r, shader_code)
	ctx.pipeline = vulkan.create_compute_pipeline(
		r,
		ctx.shader_module,
		bindings.VOXEL_MAIN_ENTRY_POINT,
		ctx.pipeline_layout,
	)
}

update_descriptors :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	for i in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		uniform_info := vk.DescriptorBufferInfo {
			buffer = ctx.uniform_buffers[i].buffer,
			offset = 0,
			range  = size_of(bindings.CameraUniforms),
		}
		volume_info := vk.DescriptorBufferInfo {
			buffer = ctx.volume_buffers[i].buffer,
			offset = 0,
			range  = MAX_VOLUMES * size_of(bindings.VoxelVolume),
		}
		image_info := vk.DescriptorImageInfo {
			imageView   = ctx.output.view,
			imageLayout = .GENERAL,
		}
		writes := [3]vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[i],
				dstBinding = bindings.VOXEL_BINDING_G_CAMERA,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &uniform_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[i],
				dstBinding = bindings.VOXEL_BINDING_G_VOLUME,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &volume_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[i],
				dstBinding = bindings.VOXEL_BINDING_G_OUTPUTFRAMEBUFFER,
				descriptorCount = 1,
				descriptorType = .STORAGE_IMAGE,
				pImageInfo = &image_info,
			},
		}
		vk.UpdateDescriptorSets(r.device, len(writes), &writes[0], 0, nil)
	}
}

add_volume :: proc(ctx: ^Context, r: ^vulkan.Renderer, source: ^voxel.Volume) -> Volume_Handle {
	assert(len(ctx.volumes) < MAX_VOLUMES, "Exceeded maximum voxel volume count")
	assert(len(source.data) > 0, "Cannot upload an empty voxel volume")
	buffer_size := len(source.data) * size_of(voxel.Voxel)
	gpu_buffer := vulkan.create_buffer(
		r,
		buffer_size,
		{.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
		{.DEVICE_LOCAL},
	)
	staging := vulkan.create_buffer(
		r,
		buffer_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	vulkan.write_buffer(r, &staging, raw_data(source.data), buffer_size)
	command_buffer := vulkan.begin_single_use_commands(r)
	copy_region := vk.BufferCopy {
		size = vk.DeviceSize(buffer_size),
	}
	vk.CmdCopyBuffer(command_buffer, staging.buffer, gpu_buffer.buffer, 1, &copy_region)
	vulkan.end_single_use_commands(r, command_buffer)
	vulkan.destroy_buffer(r, &staging)

	handle := Volume_Handle(len(ctx.volumes))
	append(
		&ctx.volumes,
		gpu_volume {
			origin = source.origin,
			size = source.size,
			rotation = source.rotation,
			buffer = gpu_buffer,
			device_address = u64(vulkan.get_gpu_address(r.device, gpu_buffer.buffer)),
		},
	)
	return handle
}

update_frame_data :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	camera: view.Camera,
	frame_index: int,
) {
	runtime_camera := bindings.CameraUniforms {
		viewProj    = camera.view_proj,
		invViewProj = camera.inv_view_proj,
		position    = camera.position,
	}
	uniform_data: rawptr
	vulkan.VK_CHECK(
		vma.MapMemory(r.allocator_vma, ctx.uniform_buffers[frame_index].allocation, &uniform_data),
		"vkMapMemory(voxel camera)",
	)
	mem.copy(uniform_data, &runtime_camera, size_of(runtime_camera))
	vma.UnmapMemory(r.allocator_vma, ctx.uniform_buffers[frame_index].allocation)

	if len(ctx.volumes) == 0 {
		return
	}
	packed := ctx.packed_volumes[:len(ctx.volumes)]
	for &source, i in ctx.volumes {
		inverse_rotation := linalg.inverse(source.rotation)
		packed[i] = bindings.VoxelVolume {
			origin      = source.origin,
			size_x      = source.size.x,
			size_y      = source.size.y,
			size_z      = source.size.z,
			invRotation = {
				{inverse_rotation[0, 0], inverse_rotation[0, 1], inverse_rotation[0, 2], 0},
				{inverse_rotation[1, 0], inverse_rotation[1, 1], inverse_rotation[1, 2], 0},
				{inverse_rotation[2, 0], inverse_rotation[2, 1], inverse_rotation[2, 2], 0},
			},
			rotation    = {
				{source.rotation[0, 0], source.rotation[0, 1], source.rotation[0, 2], 0},
				{source.rotation[1, 0], source.rotation[1, 1], source.rotation[1, 2], 0},
				{source.rotation[2, 0], source.rotation[2, 1], source.rotation[2, 2], 0},
			},
			data        = source.device_address,
		}
	}
	volume_data: rawptr
	vulkan.VK_CHECK(
		vma.MapMemory(r.allocator_vma, ctx.volume_buffers[frame_index].allocation, &volume_data),
		"vkMapMemory(voxel volumes)",
	)
	mem.copy(volume_data, raw_data(packed), len(packed) * size_of(bindings.VoxelVolume))
	vma.UnmapMemory(r.allocator_vma, ctx.volume_buffers[frame_index].allocation)
}

record_frame :: proc(
	data: rawptr,
	r: ^vulkan.Renderer,
	command_buffer: vk.CommandBuffer,
	image_index: u32,
) {
	_ = image_index
	input := cast(^Frame_Input)data
	ctx := input.renderer
	frame_index := r.frame_index % vulkan.MAX_FRAMES_IN_FLIGHT
	update_frame_data(ctx, r, input.camera, frame_index)

	if ctx.output_layout == .SHADER_READ_ONLY_OPTIMAL {
		to_general := vk.ImageMemoryBarrier {
			sType = .IMAGE_MEMORY_BARRIER,
			oldLayout = .SHADER_READ_ONLY_OPTIMAL,
			newLayout = .GENERAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = ctx.output.image,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			srcAccessMask = {.SHADER_READ},
			dstAccessMask = {.SHADER_WRITE},
		}
		vk.CmdPipelineBarrier(
			command_buffer,
			{.FRAGMENT_SHADER},
			{.COMPUTE_SHADER},
			{},
			0,
			nil,
			0,
			nil,
			1,
			&to_general,
		)
	}

	vk.CmdBindPipeline(command_buffer, .COMPUTE, ctx.pipeline)
	vk.CmdBindDescriptorSets(
		command_buffer,
		.COMPUTE,
		ctx.pipeline_layout,
		0,
		1,
		&ctx.descriptor_sets[frame_index],
		0,
		nil,
	)
	group_x := (r.extent.width + bindings.VOXEL_THREAD_X - 1) / bindings.VOXEL_THREAD_X
	group_y := (r.extent.height + bindings.VOXEL_THREAD_Y - 1) / bindings.VOXEL_THREAD_Y
	vk.CmdDispatch(command_buffer, group_x, group_y, 1)

	to_sampled := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = .GENERAL,
		newLayout = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = ctx.output.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		srcAccessMask = {.SHADER_WRITE},
		dstAccessMask = {.SHADER_READ},
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.COMPUTE_SHADER},
		{.FRAGMENT_SHADER},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&to_sampled,
	)
	ctx.output_layout = .SHADER_READ_ONLY_OPTIMAL
}

destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	_ = vk.DeviceWaitIdle(r.device)
	for &volume in ctx.volumes {
		vulkan.destroy_buffer(r, &volume.buffer)
	}
	delete(ctx.volumes)
	for i in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		vulkan.destroy_buffer(r, &ctx.uniform_buffers[i])
		vulkan.destroy_buffer(r, &ctx.volume_buffers[i])
	}
	destroy_output(ctx, r)
	if ctx.pipeline != {} {
		vk.DestroyPipeline(r.device, ctx.pipeline, nil)
	}
	if ctx.shader_module != {} {
		vk.DestroyShaderModule(r.device, ctx.shader_module, nil)
	}
	if ctx.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, ctx.pipeline_layout, nil)
	}
	if ctx.descriptor_layout != {} {
		vk.DestroyDescriptorSetLayout(r.device, ctx.descriptor_layout, nil)
	}
	ctx^ = {}
}
