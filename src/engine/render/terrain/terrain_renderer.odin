package terrain_renderer

import bindings "../../../shaders/terrain_shader"
import heightfield "../../terrain/heightfield"
import sparse "../../terrain/sparse"
import voxel_terrain "../../terrain/voxel"
import view "../../view"
import shader_assets "../shader_assets"
import vulkan "../vulkan"
import "core:mem"
import "core:math"
import "core:slice"
import vk "vendor:vulkan"

MAX_RENDERED_OVERRIDES :: 4_096
MAX_OVERRIDE_TABLE_SLOTS :: 16_384
MAX_GPU_SAMPLES :: heightfield.MAX_LOD_LEVELS * 257 * 257
MAX_GPU_CHUNKS :: 2_048
MAX_GPU_BRICKS :: MAX_GPU_CHUNKS * voxel_terrain.BRICKS_PER_CHUNK
MAX_GPU_VOXELS :: 16 * 1_024 * 1_024
MAX_GPU_CHUNK_TABLE_SLOTS :: 8_192
MAX_GPU_MATERIALS :: 64

Debug_Mode :: enum u32 {
	NORMAL,
	LOD,
	MATERIAL,
	MOUNTAIN_INFLUENCE,
	HEIGHTFIELD_GRID,
	VIRTUAL_VOXEL_CELLS,
	VIRTUAL_VOXEL_FACES,
	LOD_TRANSITIONS,
	HEIGHT_QUANTIZATION,
	DDA_TRAVERSAL,
	WORLD_RING,
	MODIFICATIONS,
	VOXEL_GRID,
	CHUNK_BOUNDS,
	BRICK_BOUNDS,
	BRICK_CLASSIFICATION,
	ORE,
	RESIDENCY,
	REPRESENTATION,
	HEIGHTFIELD_ONLY,
	VOXEL_ONLY,
}

Material_Render_Info :: struct {
	base_color:         u32,
	variation_strength: f32,
	flags:              u32,
	_padding:           u32,
}

Config :: struct {
	near_voxel_distance:              f32,
	voxel_transition_width:           f32,
	heightfield_lod_end_distances:    [3]f32,
	far_distance:                     f32,
	virtual_voxel_size:               [3]f32,
	vertical_quantization:            [3]f32,
	heightfield_lod_transition_width: f32,
	stats_sample_stride:              u32,
}

valid_config :: proc(config: Config) -> bool {
	return(
		config.near_voxel_distance > 0 &&
		config.voxel_transition_width >= 0 &&
		config.voxel_transition_width < config.near_voxel_distance &&
		config.heightfield_lod_end_distances[0] > config.near_voxel_distance &&
		config.heightfield_lod_end_distances[1] > config.heightfield_lod_end_distances[0] &&
		config.heightfield_lod_end_distances[2] > config.heightfield_lod_end_distances[1] &&
		config.far_distance == config.heightfield_lod_end_distances[2] &&
		config.virtual_voxel_size[0] > 0 &&
		config.virtual_voxel_size[1] > config.virtual_voxel_size[0] &&
		config.virtual_voxel_size[2] > config.virtual_voxel_size[1] &&
		config.vertical_quantization[0] > 0 &&
		config.vertical_quantization[1] >= config.vertical_quantization[0] &&
		config.vertical_quantization[2] >= config.vertical_quantization[1] &&
		config.heightfield_lod_transition_width >= 0 \
	)
}

Traversal_Stats :: struct {
	sampled_rays:                    u32,
	average_heightfield_cells:       f32,
	maximum_heightfield_cells:       u32,
	average_heightfield_hit_distance: f32,
	heightfield_hits:                u32,
	lod_hits:                        [3]u32,
	average_lod_cells:               [3]f32,
	voxel_only_hits:                 u32,
	heightfield_only_hits:           u32,
	blended_hits:                    u32,
	missed_rays:                     u32,
}

Frame_Uniforms :: struct #align (16) {
	camera:   bindings.CameraUniforms,
	settings: bindings.TerrainSettings,
}

#assert(size_of(Frame_Uniforms) == bindings.TERRAIN_UNIFORM_BUFFER_SIZE)
#assert(size_of(heightfield.Sample) == size_of(bindings.TerrainSample))
#assert(size_of(Material_Render_Info) == size_of(bindings.MaterialRenderInfo))
#assert(size_of(bindings.TerrainTraversalStats) % 16 == 0)

Context :: struct {
	uniform_buffers:           [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	level_buffers:             [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	sample_buffers:            [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	override_buffers:          [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	voxel_chunk_buffers:       [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	voxel_brick_buffers:       [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	voxel_material_buffers:    [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	voxel_chunk_table_buffers: [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	material_buffers:          [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	stats_buffers:             [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	descriptor_sets:           [vulkan.MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	descriptor_layout:         vk.DescriptorSetLayout,
	pipeline_layout:           vk.PipelineLayout,
	pipeline:                  vk.Pipeline,
	shader_module:             vk.ShaderModule,
	outputs:                   [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Image,
	output_layouts:            [vulkan.MAX_FRAMES_IN_FLIGHT]vk.ImageLayout,
	output_extent:             [2]u32,
	override_table:            []bindings.SparseVoxel,
	voxel_chunks:              [dynamic]bindings.VoxelChunk,
	voxel_bricks:              [dynamic]bindings.VoxelBrick,
	voxel_materials:           [dynamic]u32,
	sorted_chunk_coords:       [dynamic]voxel_terrain.Chunk_Coord,
	voxel_chunk_table:         []bindings.VoxelChunkSlot,
	uploaded_generation:       [vulkan.MAX_FRAMES_IN_FLIGHT]u64,
	uploaded_edit_count:       [vulkan.MAX_FRAMES_IN_FLIGHT]u64,
	stats_ready:               [vulkan.MAX_FRAMES_IN_FLIGHT]bool,
	stats:                     Traversal_Stats,
	chunk_table_mask:          u32,
}

Frame_Input :: struct {
	renderer:          ^Context,
	camera:            view.Camera,
	cache:             ^heightfield.Cache,
	overrides:         ^sparse.World,
	voxels:            ^voxel_terrain.World,
	materials:         []Material_Render_Info,
	terrain_materials: []Material_Render_Info,
	config:            Config,
	visual_seed:       u64,
	world_radius:      f32,
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
		{binding = bindings.TERRAIN_BINDING_G_VOXELCHUNKS, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_VOXELBRICKS, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_VOXELMATERIALS, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_VOXELCHUNKTABLE, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_MATERIALS, type = .STORAGE_BUFFER},
		{binding = bindings.TERRAIN_BINDING_G_OUTPUTFRAMEBUFFER, type = .STORAGE_IMAGE},
		{binding = bindings.TERRAIN_BINDING_G_TRAVERSALSTATS, type = .STORAGE_BUFFER},
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
		ctx.voxel_chunk_buffers[index] = vulkan.create_buffer(
			r,
			MAX_GPU_CHUNKS * size_of(bindings.VoxelChunk),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.voxel_brick_buffers[index] = vulkan.create_buffer(
			r,
			MAX_GPU_BRICKS * size_of(bindings.VoxelBrick),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.voxel_material_buffers[index] = vulkan.create_buffer(
			r,
			MAX_GPU_VOXELS * size_of(u32),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.voxel_chunk_table_buffers[index] = vulkan.create_buffer(
			r,
			MAX_GPU_CHUNK_TABLE_SLOTS * size_of(bindings.VoxelChunkSlot),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.material_buffers[index] = vulkan.create_buffer(
			r,
			MAX_GPU_MATERIALS * size_of(bindings.MaterialRenderInfo),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.stats_buffers[index] = vulkan.create_buffer(
			r,
			size_of(bindings.TerrainTraversalStats),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		ctx.descriptor_sets[index] = vulkan.allocate_descriptor_set(r, ctx.descriptor_layout)
	}
	ctx.override_table = make([]bindings.SparseVoxel, MAX_OVERRIDE_TABLE_SLOTS)
	ctx.voxel_chunk_table = make([]bindings.VoxelChunkSlot, MAX_GPU_CHUNK_TABLE_SLOTS)
	ctx.uploaded_generation = {~u64(0), ~u64(0)}
	ctx.uploaded_edit_count = {~u64(0), ~u64(0)}
	create_output(ctx, r)
	reload_shader(ctx, r)
}

create_output :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	width := max(r.extent.width, 1)
	height := max(r.extent.height, 1)
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		image, allocation := vulkan.create_image(
			r,
			width,
			height,
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
		ctx.outputs[index] = {
			image      = image,
			view       = image_view,
			sampler    = vulkan.create_sampler(r, .LINEAR, .CLAMP_TO_EDGE),
			allocation = allocation,
		}
		ctx.output_layouts[index] = .GENERAL
	}
	ctx.output_extent = {width, height}
	update_descriptors(ctx, r)
}

destroy_output :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		vulkan.destroy_image(r, &ctx.outputs[index])
		ctx.output_layouts[index] = .UNDEFINED
	}
	ctx.output_extent = {}
}

before_swapchain_destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {destroy_output(ctx, r)}
after_swapchain_create :: proc(ctx: ^Context, r: ^vulkan.Renderer) {create_output(ctx, r)}
output_image :: proc(ctx: ^Context, r: ^vulkan.Renderer) -> vulkan.Image {
	return ctx.outputs[r.frame_index % vulkan.MAX_FRAMES_IN_FLIGHT]
}

reload_shader :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	_ = vk.DeviceWaitIdle(r.device)
	if ctx.pipeline != {} {vk.DestroyPipeline(r.device, ctx.pipeline, nil); ctx.pipeline = {}}
	if ctx.shader_module !=
	   {} {vk.DestroyShaderModule(r.device, ctx.shader_module, nil); ctx.shader_module = {}}
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
		voxel_chunk_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_chunk_buffers[index].buffer,
			range  = MAX_GPU_CHUNKS * size_of(bindings.VoxelChunk),
		}
		voxel_brick_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_brick_buffers[index].buffer,
			range  = MAX_GPU_BRICKS * size_of(bindings.VoxelBrick),
		}
		voxel_material_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_material_buffers[index].buffer,
			range  = MAX_GPU_VOXELS * size_of(u32),
		}
		voxel_chunk_table_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_chunk_table_buffers[index].buffer,
			range  = MAX_GPU_CHUNK_TABLE_SLOTS * size_of(bindings.VoxelChunkSlot),
		}
		material_info := vk.DescriptorBufferInfo {
			buffer = ctx.material_buffers[index].buffer,
			range  = MAX_GPU_MATERIALS * size_of(bindings.MaterialRenderInfo),
		}
		stats_info := vk.DescriptorBufferInfo {
			buffer = ctx.stats_buffers[index].buffer,
			range  = size_of(bindings.TerrainTraversalStats),
		}
		image_info := vk.DescriptorImageInfo {
			imageView   = ctx.outputs[index].view,
			imageLayout = .GENERAL,
		}
		writes := [11]vk.WriteDescriptorSet {
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
				dstBinding = bindings.TERRAIN_BINDING_G_VOXELCHUNKS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &voxel_chunk_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_VOXELBRICKS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &voxel_brick_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_VOXELMATERIALS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &voxel_material_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_VOXELCHUNKTABLE,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &voxel_chunk_table_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_MATERIALS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &material_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_OUTPUTFRAMEBUFFER,
				descriptorCount = 1,
				descriptorType = .STORAGE_IMAGE,
				pImageInfo = &image_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = ctx.descriptor_sets[index],
				dstBinding = bindings.TERRAIN_BINDING_G_TRAVERSALSTATS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &stats_info,
			},
		}
		vk.UpdateDescriptorSets(r.device, len(writes), &writes[0], 0, nil)
	}
}

next_power_of_two :: proc(value: u32) -> u32 {
	result: u32 = 1
	for result < value {result <<= 1}
	return result
}

hash_uint :: proc(value: u32) -> u32 {
	result := value
	result ~= result >> 16
	result *= 0x7FEB352D
	result ~= result >> 15
	result *= 0x846CA68B
	result ~= result >> 16
	return result
}

hash_voxel :: proc(voxel: [3]i32) -> u32 {
	return hash_uint(
		u32(voxel.x) * 73_856_093 ~ u32(voxel.y) * 19_349_663 ~ u32(voxel.z) * 83_492_791,
	)
}

chunk_coord_less :: proc(a, b: voxel_terrain.Chunk_Coord) -> bool {
	if a.x != b.x {
		return a.x < b.x
	}
	if a.y != b.y {
		return a.y < b.y
	}
	return a.z < b.z
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
	capacity := min(next_power_of_two(u32(len(records) * 4)), MAX_OVERRIDE_TABLE_SLOTS)
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
		minimum :=
			[3]f32{f32(record.voxel.x), f32(record.voxel.y), f32(record.voxel.z)} *
			overrides.voxel_size
		maximum := minimum + overrides.voxel_size
		for axis in 0 ..< 3 {
			bounds_min[axis] = min(bounds_min[axis], minimum[axis])
			bounds_max[axis] = max(bounds_max[axis], maximum[axis])
		}
	}
	return
}

build_voxel_buffers :: proc(ctx: ^Context, world: ^voxel_terrain.World) {
	clear(&ctx.voxel_chunks)
	clear(&ctx.voxel_bricks)
	clear(&ctx.voxel_materials)
	clear(&ctx.sorted_chunk_coords)
	for coord, _ in world.chunks {
		append(&ctx.sorted_chunk_coords, coord)
	}
	slice.sort_by(ctx.sorted_chunk_coords[:], chunk_coord_less)
	mem.zero(
		raw_data(ctx.voxel_chunk_table),
		len(ctx.voxel_chunk_table) * size_of(bindings.VoxelChunkSlot),
	)
	assert(len(world.chunks) <= MAX_GPU_CHUNKS, "Resident voxel chunk GPU capacity exceeded")
	for coord in ctx.sorted_chunk_coords {
		chunk := world.chunks[coord]
		gpu_chunk := bindings.VoxelChunk {
			coord       = {coord.x, coord.y, coord.z},
			brickOffset = u32(len(ctx.voxel_bricks)),
		}
		append(&ctx.voxel_chunks, gpu_chunk)
		for brick in chunk.bricks {
			gpu_brick := bindings.VoxelBrick {
				kind     = u32(brick.kind),
				material = u32(brick.material),
			}
			if brick.kind == .MIXED {
				gpu_brick.voxelOffset = u32(len(ctx.voxel_materials))
				for index in 0 ..< voxel_terrain.VOXELS_PER_BRICK {
					append(
						&ctx.voxel_materials,
						u32(chunk.detailed_voxels[int(brick.voxel_offset) + index]),
					)
				}
			}
			append(&ctx.voxel_bricks, gpu_brick)
		}
	}
	assert(len(ctx.voxel_bricks) <= MAX_GPU_BRICKS, "Resident voxel brick GPU capacity exceeded")
	assert(len(ctx.voxel_materials) <= MAX_GPU_VOXELS, "Detailed voxel GPU capacity exceeded")
	if len(ctx.voxel_chunks) == 0 {
		ctx.chunk_table_mask = 0
		world.stats.gpu_bytes = 0
		return
	}
	capacity := min(next_power_of_two(u32(len(ctx.voxel_chunks) * 4)), MAX_GPU_CHUNK_TABLE_SLOTS)
	ctx.chunk_table_mask = capacity - 1
	for chunk, index in ctx.voxel_chunks {
		slot := hash_voxel(chunk.coord) & ctx.chunk_table_mask
		inserted := false
		for probe: u32 = 0; probe < 32; probe += 1 {
			if ctx.voxel_chunk_table[slot].chunkIndexPlusOne == 0 {
				ctx.voxel_chunk_table[slot] = {
					coord             = chunk.coord,
					chunkIndexPlusOne = u32(index + 1),
				}
				inserted = true
				break
			}
			slot = (slot + 1) & ctx.chunk_table_mask
		}
		assert(inserted, "Resident voxel chunk hash probe limit exceeded")
	}
	world.stats.gpu_bytes = u64(
		len(ctx.voxel_chunks) * size_of(bindings.VoxelChunk) +
		len(ctx.voxel_bricks) * size_of(bindings.VoxelBrick) +
		len(ctx.voxel_materials) * size_of(u32) +
		int(capacity) * size_of(bindings.VoxelChunkSlot),
	)
}

upload_voxel_buffers :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	input: ^Frame_Input,
	frame_index: int,
) {
	edit_count := u64(input.overrides.modified_count)
	if ctx.uploaded_generation[frame_index] == input.voxels.generation &&
	   ctx.uploaded_edit_count[frame_index] == edit_count {
		return
	}
	build_voxel_buffers(ctx, input.voxels)
	if len(ctx.voxel_chunks) > 0 {
		vulkan.write_buffer(
			r,
			&ctx.voxel_chunk_buffers[frame_index],
			raw_data(ctx.voxel_chunks),
			len(ctx.voxel_chunks) * size_of(bindings.VoxelChunk),
		)
		vulkan.write_buffer(
			r,
			&ctx.voxel_brick_buffers[frame_index],
			raw_data(ctx.voxel_bricks),
			len(ctx.voxel_bricks) * size_of(bindings.VoxelBrick),
		)
		vulkan.write_buffer(
			r,
			&ctx.voxel_chunk_table_buffers[frame_index],
			raw_data(ctx.voxel_chunk_table),
			int(ctx.chunk_table_mask + 1) * size_of(bindings.VoxelChunkSlot),
		)
	}
	if len(ctx.voxel_materials) > 0 {
		vulkan.write_buffer(
			r,
			&ctx.voxel_material_buffers[frame_index],
			raw_data(ctx.voxel_materials),
			len(ctx.voxel_materials) * size_of(u32),
		)
	}
	ctx.uploaded_generation[frame_index] = input.voxels.generation
	ctx.uploaded_edit_count[frame_index] = edit_count
}

update_traversal_stats :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	frame_index: int,
) {
	if ctx.stats_ready[frame_index] {
		raw: bindings.TerrainTraversalStats
		vulkan.read_buffer(r, &ctx.stats_buffers[frame_index], &raw, size_of(raw))
		average_cells: f32
		average_hit_distance: f32
		average_lod_cells: [3]f32
		if raw.sampledRays > 0 {
			average_cells = f32(raw.heightfieldCellVisits) / f32(raw.sampledRays)
		}
		if raw.heightfieldHits > 0 {
			average_hit_distance =
				f32(raw.heightfieldHitDistanceMeters) / f32(raw.heightfieldHits)
		}
		if raw.lod0TraversedRays > 0 {
			average_lod_cells[0] =
				f32(raw.lod0CellVisits) / f32(raw.lod0TraversedRays)
		}
		if raw.lod1TraversedRays > 0 {
			average_lod_cells[1] =
				f32(raw.lod1CellVisits) / f32(raw.lod1TraversedRays)
		}
		if raw.lod2TraversedRays > 0 {
			average_lod_cells[2] =
				f32(raw.lod2CellVisits) / f32(raw.lod2TraversedRays)
		}
		ctx.stats = {
			sampled_rays = raw.sampledRays,
			average_heightfield_cells = average_cells,
			maximum_heightfield_cells = raw.maxHeightfieldCellVisits,
			average_heightfield_hit_distance = average_hit_distance,
			heightfield_hits = raw.heightfieldHits,
			lod_hits = {raw.lod0Hits, raw.lod1Hits, raw.lod2Hits},
			average_lod_cells = average_lod_cells,
			voxel_only_hits = raw.voxelOnlyHits,
			heightfield_only_hits = raw.heightfieldOnlyHits,
			blended_hits = raw.blendedHits,
			missed_rays = raw.missedRays,
		}
	}
	zero: bindings.TerrainTraversalStats
	vulkan.write_buffer(r, &ctx.stats_buffers[frame_index], &zero, size_of(zero))
	ctx.stats_ready[frame_index] = true
}

update_frame_data :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	input: ^Frame_Input,
	frame_index: int,
) {
	assert(len(input.cache.samples) <= MAX_GPU_SAMPLES)
	assert(len(input.materials) > 0)
	assert(len(input.terrain_materials) > 0)
	assert(len(input.materials) + len(input.terrain_materials) <= MAX_GPU_MATERIALS)
	assert(valid_config(input.config))
	update_traversal_stats(ctx, r, frame_index)
	mask, bounds_min, bounds_max := build_override_table(ctx, input.overrides)
	upload_voxel_buffers(ctx, r, input, frame_index)
	level_count := int(input.cache.config.level_count)
	lod_distances := [4]f32 {
		input.config.heightfield_lod_end_distances[0],
		input.config.heightfield_lod_end_distances[1],
		input.config.heightfield_lod_end_distances[2],
		input.config.far_distance,
	}
	virtual_voxel_sizes := [4]f32 {
		input.config.virtual_voxel_size[0],
		input.config.virtual_voxel_size[1],
		input.config.virtual_voxel_size[2],
		input.config.virtual_voxel_size[2],
	}
	vertical_steps := [4]f32 {
		input.config.vertical_quantization[0],
		input.config.vertical_quantization[1],
		input.config.vertical_quantization[2],
		input.config.vertical_quantization[2],
	}
	levels: [heightfield.MAX_LOD_LEVELS]bindings.TerrainLevel
	for index in 0 ..< level_count {
		source := input.cache.levels[index]
		ratio := input.config.virtual_voxel_size[index] / source.spacing
		assert(math.abs(ratio - math.round(ratio)) < 0.0001)
		levels[index] = {
			origin       = source.origin,
			spacing      = source.spacing,
			sampleCount  = source.sample_count,
			sampleOffset = source.sample_offset,
			extent       = source.extent,
			lod          = source.lod,
		}
	}
	uniforms := Frame_Uniforms {
		camera = {
			viewProj = input.camera.view_proj,
			invViewProj = input.camera.inv_view_proj,
			position = input.camera.position,
		},
		settings = {
			worldRadius = input.world_radius,
			maxDistance = input.config.far_distance,
			modificationVoxelSize = input.overrides.voxel_size,
			levelCount = input.cache.config.level_count,
			overrideTableMask = mask,
			debugMode = u32(input.debug_mode),
			debugRingRadius = input.debug_ring_radius,
			voxelSize = input.voxels.config.voxel_size,
			voxelRenderRadius = input.config.near_voxel_distance,
			voxelTransitionWidth = input.config.voxel_transition_width,
			chunkWorldSize = voxel_terrain.chunk_world_size(input.voxels),
			chunkTableMask = ctx.chunk_table_mask,
			chunkCount = u32(len(input.voxels.chunks)),
			materialCount = u32(len(input.materials)),
			terrainMaterialOffset = u32(len(input.materials)),
			terrainMaterialCount = u32(len(input.terrain_materials)),
			visualSeedLo = u32(input.visual_seed),
			visualSeedHi = u32(input.visual_seed >> 32),
			lodDistances = lod_distances,
			virtualVoxelSizes = virtual_voxel_sizes,
			verticalSteps = vertical_steps,
			overrideBoundsMin = bounds_min,
			statsSampleStride = input.config.stats_sample_stride,
			overrideBoundsMax = bounds_max,
			heightfieldTransitionWidth = input.config.heightfield_lod_transition_width,
		},
	}
	render_materials: [MAX_GPU_MATERIALS]Material_Render_Info
	for material, index in input.materials {
		render_materials[index] = material
	}
	for material, index in input.terrain_materials {
		render_materials[len(input.materials) + index] = material
	}
	render_material_count := len(input.materials) + len(input.terrain_materials)

	vulkan.write_buffer(r, &ctx.uniform_buffers[frame_index], &uniforms, size_of(uniforms))
	vulkan.write_buffer(r, &ctx.level_buffers[frame_index], &levels, size_of(levels))
	vulkan.write_buffer(
		r,
		&ctx.sample_buffers[frame_index],
		raw_data(input.cache.samples),
		len(input.cache.samples) * size_of(heightfield.Sample),
	)
	vulkan.write_buffer(
		r,
		&ctx.material_buffers[frame_index],
		&render_materials[0],
		render_material_count * size_of(Material_Render_Info),
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
	output := &ctx.outputs[frame_index]
	output_layout := &ctx.output_layouts[frame_index]
	update_frame_data(ctx, r, input, frame_index)
	if output_layout^ == .SHADER_READ_ONLY_OPTIMAL {
		to_general := vk.ImageMemoryBarrier {
			sType = .IMAGE_MEMORY_BARRIER,
			oldLayout = .SHADER_READ_ONLY_OPTIMAL,
			newLayout = .GENERAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = output.image,
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
	group_x := (ctx.output_extent.x + bindings.TERRAIN_THREAD_X - 1) / bindings.TERRAIN_THREAD_X
	group_y := (ctx.output_extent.y + bindings.TERRAIN_THREAD_Y - 1) / bindings.TERRAIN_THREAD_Y
	vk.CmdDispatch(command_buffer, group_x, group_y, 1)
	to_sampled := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = .GENERAL,
		newLayout = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = output.image,
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
	output_layout^ = .SHADER_READ_ONLY_OPTIMAL
}

destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	_ = vk.DeviceWaitIdle(r.device)
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		vulkan.destroy_buffer(r, &ctx.uniform_buffers[index])
		vulkan.destroy_buffer(r, &ctx.level_buffers[index])
		vulkan.destroy_buffer(r, &ctx.sample_buffers[index])
		vulkan.destroy_buffer(r, &ctx.override_buffers[index])
		vulkan.destroy_buffer(r, &ctx.voxel_chunk_buffers[index])
		vulkan.destroy_buffer(r, &ctx.voxel_brick_buffers[index])
		vulkan.destroy_buffer(r, &ctx.voxel_material_buffers[index])
		vulkan.destroy_buffer(r, &ctx.voxel_chunk_table_buffers[index])
		vulkan.destroy_buffer(r, &ctx.material_buffers[index])
		vulkan.destroy_buffer(r, &ctx.stats_buffers[index])
	}
	delete(ctx.override_table)
	delete(ctx.voxel_chunks)
	delete(ctx.voxel_bricks)
	delete(ctx.voxel_materials)
	delete(ctx.sorted_chunk_coords)
	delete(ctx.voxel_chunk_table)
	destroy_output(ctx, r)
	if ctx.pipeline != {} {vk.DestroyPipeline(r.device, ctx.pipeline, nil)}
	if ctx.shader_module != {} {vk.DestroyShaderModule(r.device, ctx.shader_module, nil)}
	if ctx.pipeline_layout != {} {vk.DestroyPipelineLayout(r.device, ctx.pipeline_layout, nil)}
	if ctx.descriptor_layout !=
	   {} {vk.DestroyDescriptorSetLayout(r.device, ctx.descriptor_layout, nil)}
	ctx^ = {}
}
