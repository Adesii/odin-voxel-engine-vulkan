package terrain_renderer

import bindings "../../../shaders/terrain_shader"
import heightfield "../../terrain/heightfield"
import sparse "../../terrain/sparse"
import view "../../view"
import shader_assets "../shader_assets"
import vulkan "../vulkan"
import "core:mem"
import vk "vendor:vulkan"

MAX_RENDERED_OVERRIDES :: 4_096
MAX_OVERRIDE_TABLE_SLOTS :: 16_384
MAX_GPU_SAMPLES :: heightfield.MAX_LOD_LEVELS * 257 * 257

Debug_Mode :: enum u32 {
	NORMAL,
	LOD,
	MATERIAL,
	MOUNTAIN_INFLUENCE,
	TILE_GRID,
	DEBUG_RING,
	MODIFICATIONS,
}

Frame_Uniforms :: struct #align (16) {
	camera:   bindings.CameraUniforms,
	settings: bindings.TerrainSettings,
}

#assert(size_of(Frame_Uniforms) == bindings.TERRAIN_UNIFORM_BUFFER_SIZE)
#assert(size_of(heightfield.Sample) == size_of(bindings.TerrainSample))

Context :: struct {
	uniform_buffers:   [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	level_buffers:     [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	sample_buffers:    [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	override_buffers:  [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	descriptor_sets:   [vulkan.MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	descriptor_layout: vk.DescriptorSetLayout,
	pipeline_layout:   vk.PipelineLayout,
	pipeline:          vk.Pipeline,
	shader_module:     vk.ShaderModule,
	output:            vulkan.Image,
	output_layout:     vk.ImageLayout,
	override_table:    []bindings.SparseVoxel,
}

Frame_Input :: struct {
	renderer:          ^Context,
	camera:            view.Camera,
	cache:             ^heightfield.Cache,
	overrides:         ^sparse.World,
	world_radius:      f32,
	max_distance:      f32,
	debug_mode:        Debug_Mode,
	debug_ring_radius: f32,
}

init :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ctx^ = {}
	bindings_desc := [?]vulkan.Descriptor_Binding {
		{binding = bindings.TERRAIN_BINDING_G_CAMERA, type = .UNIFORM_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_LEVELS, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_SAMPLES, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_OVERRIDES, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_OUTPUTFRAMEBUFFER, type = .STORAGE_IMAGE},
	}
	ctx.descriptor_layout = vulkan.create_descriptor_set_layout(r, {.COMPUTE}, bindings_desc[:])
	ctx.pipeline_layout = vulkan.create_pipeline_layout(r, ctx.descriptor_layout)
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		ctx.uniform_buffers[index] = vulkan.create_buffer(
			r,
			size_of(Frame_Uniforms),
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.level_buffers[index] = vulkan.create_buffer(
			r,
			heightfield.MAX_LOD_LEVELS * size_of(bindings.TerrainLevel),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.sample_buffers[index] = vulkan.create_buffer(
			r,
			MAX_GPU_SAMPLES * size_of(bindings.TerrainSample),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.override_buffers[index] = vulkan.create_buffer(
			r,
			MAX_OVERRIDE_TABLE_SLOTS * size_of(bindings.SparseVoxel),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.descriptor_sets[index] = vulkan.allocate_descriptor_set(r, ctx.descriptor_layout)
	}
	ctx.override_table = make([]bindings.SparseVoxel, MAX_OVERRIDE_TABLE_SLOTS)
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
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
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
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	image_view: vk.ImageView
	vulkan.VK_CHECK(
		vk.CreateImageView(r.device, &view_info, nil, &image_view),
		"vkCreateImageView(terrain)",
	)
	ctx.output = {
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
	shader_code := shader_assets.load_bytes("terrain.spirv")
	defer delete(shader_code)
	ctx.shader_module = vulkan.create_shader_module(r, shader_code)
	ctx.pipeline = vulkan.create_compute_pipeline(
		r,
		ctx.shader_module,
		bindings.TERRAIN_MAIN_ENTRY_POINT,
		ctx.pipeline_layout,
	)
}

update_descriptors :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		uniform_info := vk.DescriptorBufferInfo {
			buffer = ctx.uniform_buffers[index].buffer,
			range  = size_of(Frame_Uniforms),
		}
		level_info := vk.DescriptorBufferInfo {
			buffer = ctx.level_buffers[index].buffer,
			range  = heightfield.MAX_LOD_LEVELS * size_of(bindings.TerrainLevel),
		}
		sample_info := vk.DescriptorBufferInfo {
			buffer = ctx.sample_buffers[index].buffer,
			range  = MAX_GPU_SAMPLES * size_of(bindings.TerrainSample),
		}
		override_info := vk.DescriptorBufferInfo {
			buffer = ctx.override_buffers[index].buffer,
			range  = MAX_OVERRIDE_TABLE_SLOTS * size_of(bindings.SparseVoxel),
		}
		image_info := vk.DescriptorImageInfo {
			imageView   = ctx.output.view,
			imageLayout = .GENERAL,
		}
		writes := [5]vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_CAMERA,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &uniform_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_LEVELS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &level_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_SAMPLES,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &sample_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_OVERRIDES,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &override_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_OUTPUTFRAMEBUFFER,
				descriptorCount = 1,
				descriptorType = .STORAGE_IMAGE,
				pImageInfo = &image_info,
			},
		}
		vk.UpdateDescriptorSets(r.device, len(writes), &writes[0], 0, nil)
	}
}

next_power_of_two :: proc(value: u32) -> u32 {
	result: u32 = 1
	for result < value {
		result <<= 1
	}
	return result
}

hash_voxel :: proc(voxel: [3]i32) -> u32 {
	x := u64(u32(voxel.x)) * 73_856_093
	y := u64(u32(voxel.y)) * 19_349_663
	z := u64(u32(voxel.z)) * 83_492_791
	return u32((x ~ y ~ z) & 0xFFFF_FFFF)
}

build_override_table :: proc(
	ctx: ^Context,
	overrides: ^sparse.World,
) -> (
	mask: u32,
	bounds_min, bounds_max: [3]f32,
) {
	records := sparse.collect_records(overrides, context.temp_allocator)
	if len(records) == 0 {
		mem.zero(
			raw_data(ctx.override_table),
			len(ctx.override_table) * size_of(bindings.SparseVoxel),
		)
		return 0, {}, {}
	}
	assert(len(records) <= MAX_RENDERED_OVERRIDES, "Terrain override GPU table capacity exceeded")
	capacity := next_power_of_two(u32(len(records) * 4))
	capacity = min(capacity, MAX_OVERRIDE_TABLE_SLOTS)
	mask = capacity - 1
	mem.zero(raw_data(ctx.override_table), int(capacity) * size_of(bindings.SparseVoxel))
	bounds_min = {1e30, 1e30, 1e30}
	bounds_max = {-1e30, -1e30, -1e30}
	for record in records {
		slot := hash_voxel(record.voxel) & mask
		inserted := false
		for probe: u32 = 0; probe < 32; probe += 1 {
			if ctx.override_table[slot].state == 0 {
				ctx.override_table[slot] = {
					voxel    = record.voxel,
					state    = u32(record.state),
					material = record.material,
				}
				inserted = true
				break
			}
			slot = (slot + 1) & mask
		}
		assert(inserted, "Terrain override hash probe limit exceeded")
		minimum := [3]f32 {
			f32(record.voxel.x) * overrides.voxel_size,
			f32(record.voxel.y) * overrides.voxel_size,
			f32(record.voxel.z) * overrides.voxel_size,
		}
		maximum := minimum + overrides.voxel_size
		for axis in 0 ..< 3 {
			bounds_min[axis] = min(bounds_min[axis], minimum[axis])
			bounds_max[axis] = max(bounds_max[axis], maximum[axis])
		}
	}
	return
}

update_frame_data :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	input: ^Frame_Input,
	frame_index: int,
) {
	assert(len(input.cache.samples) <= MAX_GPU_SAMPLES)
	mask, bounds_min, bounds_max := build_override_table(ctx, input.overrides)
	level_count := int(input.cache.config.level_count)
	lod_distances := [4]f32 {
		input.max_distance,
		input.max_distance,
		input.max_distance,
		input.max_distance,
	}
	levels: [heightfield.MAX_LOD_LEVELS]bindings.TerrainLevel
	for index in 0 ..< level_count {
		source := input.cache.levels[index]
		levels[index] = {
			origin       = source.origin,
			spacing      = source.spacing,
			sampleCount  = source.sample_count,
			sampleOffset = source.sample_offset,
			extent       = source.extent,
			lod          = source.lod,
		}
		lod_distances[index] = source.extent * 0.4
	}
	uniforms := Frame_Uniforms {
		camera = {
			viewProj = input.camera.view_proj,
			invViewProj = input.camera.inv_view_proj,
			position = input.camera.position,
		},
		settings = {
			worldRadius = input.world_radius,
			maxDistance = input.max_distance,
			modificationVoxelSize = input.overrides.voxel_size,
			levelCount = input.cache.config.level_count,
			overrideTableMask = mask,
			debugMode = u32(input.debug_mode),
			debugRingRadius = input.debug_ring_radius,
			lodDistances = lod_distances,
			overrideBoundsMin = bounds_min,
			overrideBoundsMax = bounds_max,
		},
	}
	vulkan.write_buffer(r, &ctx.uniform_buffers[frame_index], &uniforms, size_of(uniforms))
	vulkan.write_buffer(r, &ctx.level_buffers[frame_index], &levels, size_of(levels))
	vulkan.write_buffer(
		r,
		&ctx.sample_buffers[frame_index],
		raw_data(input.cache.samples),
		len(input.cache.samples) * size_of(heightfield.Sample),
	)
	if mask > 0 {
		vulkan.write_buffer(
			r,
			&ctx.override_buffers[frame_index],
			raw_data(ctx.override_table),
			int(mask + 1) * size_of(bindings.SparseVoxel),
		)
	}
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
	update_frame_data(ctx, r, input, frame_index)
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
	group_x := (r.extent.width + bindings.TERRAIN_THREAD_X - 1) / bindings.TERRAIN_THREAD_X
	group_y := (r.extent.height + bindings.TERRAIN_THREAD_Y - 1) / bindings.TERRAIN_THREAD_Y
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
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		vulkan.destroy_buffer(r, &ctx.uniform_buffers[index])
		vulkan.destroy_buffer(r, &ctx.level_buffers[index])
		vulkan.destroy_buffer(r, &ctx.sample_buffers[index])
		vulkan.destroy_buffer(r, &ctx.override_buffers[index])
	}
	delete(ctx.override_table)
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
