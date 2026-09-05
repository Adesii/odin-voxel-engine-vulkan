package terrain_renderer

import terrain_bindings "../../../shaders/terrain_shader"
import mesh_bindings "../../../shaders/voxel_mesh_shader"
import heightfield "../../terrain/heightfield"
import voxel_terrain "../../terrain/voxel"
import shader_assets "../shader_assets"
import vulkan "../vulkan"
import vk "vendor:vulkan"
import "core:math"

MESH_SHADER_THREADS :: 32
MESH_VOXELS_PER_WORKGROUP :: 10
MESH_WORKGROUPS_PER_BRICK :: 52
MESH_MAX_OUTPUT_VERTICES :: 240
MESH_HEIGHTFIELD_PATCH_CELLS :: 7
MESH_MAX_OUTPUT_PRIMITIVES :: 120
Mesh_Stats :: struct {
	candidate_bricks:     u32,
	visible_bricks:       u32,
	culled_bricks:        u32,
	mesh_workgroups:      u32,
	culled_workgroups:    u32,
	generated_faces:      u32,
	generated_primitives: u32,
	heightfield_cells:      u32,
	heightfield_primitives: u32,
}

Mesh_Context :: struct {
	available:           bool,
	uniform_buffers:     [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	brick_buffers:       [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	stats_buffers:       [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Buffer,
	descriptor_sets:     [vulkan.MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	descriptor_layout:   vk.DescriptorSetLayout,
	pipeline_layout:     vk.PipelineLayout,
	pipeline:            vk.Pipeline,
	shader_module:       vk.ShaderModule,
	render_pass:         vk.RenderPass,
	framebuffers:        [vulkan.MAX_FRAMES_IN_FLIGHT]vk.Framebuffer,
	depth_images:        [vulkan.MAX_FRAMES_IN_FLIGHT]vulkan.Image,
	depth_format:        vk.Format,
	bricks:              [dynamic]mesh_bindings.MeshBrick,
	uploaded_generation: [vulkan.MAX_FRAMES_IN_FLIGHT]u64,
	uploaded_edit_count: [vulkan.MAX_FRAMES_IN_FLIGHT]u64,
	stats_ready:         [vulkan.MAX_FRAMES_IN_FLIGHT]bool,
	stats:               Mesh_Stats,
}

#assert(size_of(mesh_bindings.MeshSettings) == mesh_bindings.VOXEL_MESH_UNIFORM_BUFFER_SIZE)
#assert(size_of(mesh_bindings.MeshBrick) == 16)
#assert(size_of(mesh_bindings.MeshStats) == 32)

#assert(size_of(mesh_bindings.VoxelChunk) == size_of(terrain_bindings.VoxelChunk))
#assert(size_of(mesh_bindings.VoxelBrick) == size_of(terrain_bindings.VoxelBrick))
#assert(size_of(mesh_bindings.VoxelChunkSlot) == size_of(terrain_bindings.VoxelChunkSlot))
#assert(size_of(mesh_bindings.MaterialRenderInfo) == size_of(Material_Render_Info))
#assert(size_of(mesh_bindings.TerrainLevel) == size_of(terrain_bindings.TerrainLevel))
#assert(size_of(mesh_bindings.TerrainSample) == size_of(terrain_bindings.TerrainSample))
mesh_backend_supported :: proc(ctx: ^Context) -> bool {
	return ctx.mesh.available
}

mesh_limits_sufficient :: proc(r: ^vulkan.Renderer) -> bool {
	limits := r.mesh_shader
	return(
		limits.supported &&
		limits.max_work_group_invocations >= MESH_SHADER_THREADS &&
		limits.max_work_group_size[0] >= MESH_SHADER_THREADS &&
		limits.max_output_vertices >= MESH_MAX_OUTPUT_VERTICES &&
		limits.max_output_primitives >= MESH_MAX_OUTPUT_PRIMITIVES \
	)
}

mesh_init :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	mesh.available = mesh_limits_sufficient(r)
	if !mesh.available {
		return
	}
	bindings_desc := [?]vulkan.Descriptor_Binding {
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_MESHSETTINGS, type = .UNIFORM_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELCHUNKS, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELBRICKS, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELMATERIALS, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELCHUNKTABLE, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_MATERIALS, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_MESHBRICKS, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_MESHSTATS, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_TERRAINLEVELS, type = .STORAGE_BUFFER},
		{binding = mesh_bindings.VOXEL_MESH_BINDING_G_TERRAINSAMPLES, type = .STORAGE_BUFFER},
	}
	mesh.descriptor_layout = vulkan.create_descriptor_set_layout(
		r,
		{.MESH_EXT, .FRAGMENT},
		bindings_desc[:],
	)
	mesh.pipeline_layout = vulkan.create_pipeline_layout(r, mesh.descriptor_layout)
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		mesh.uniform_buffers[index] = vulkan.create_buffer(
			r,
			mesh_bindings.VOXEL_MESH_UNIFORM_BUFFER_SIZE,
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		mesh.brick_buffers[index] = vulkan.create_buffer(
			r,
			MAX_GPU_BRICKS * size_of(mesh_bindings.MeshBrick),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		mesh.stats_buffers[index] = vulkan.create_buffer(
			r,
			size_of(mesh_bindings.MeshStats),
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		mesh.descriptor_sets[index] = vulkan.allocate_descriptor_set(r, mesh.descriptor_layout)
	}
	mesh.uploaded_generation = {~u64(0), ~u64(0)}
	mesh.uploaded_edit_count = {~u64(0), ~u64(0)}
}

mesh_depth_format :: proc(r: ^vulkan.Renderer) -> vk.Format {
	candidates := [?]vk.Format{.D32_SFLOAT, .D24_UNORM_S8_UINT, .D16_UNORM}
	for format in candidates {
		properties: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(r.physical_device, format, &properties)
		if .DEPTH_STENCIL_ATTACHMENT in properties.optimalTilingFeatures {
			return format
		}
	}
	return .UNDEFINED
}

mesh_create_render_pass :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	color_attachment := vk.AttachmentDescription {
		format         = r.surface_format.format,
		samples        = {._1},
		loadOp         = .LOAD,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .COLOR_ATTACHMENT_OPTIMAL,
		finalLayout    = .SHADER_READ_ONLY_OPTIMAL,
	}
	depth_attachment := vk.AttachmentDescription {
		format         = mesh.depth_format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	}
	attachments := [2]vk.AttachmentDescription{color_attachment, depth_attachment}
	color_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}
	depth_ref := vk.AttachmentReference {
		attachment = 1,
		layout     = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	}
	subpass := vk.SubpassDescription {
		pipelineBindPoint       = .GRAPHICS,
		colorAttachmentCount    = 1,
		pColorAttachments       = &color_ref,
		pDepthStencilAttachment = &depth_ref,
	}
	dependencies := [2]vk.SubpassDependency {
		{
			srcSubpass = vk.SUBPASS_EXTERNAL,
			dstSubpass = 0,
			srcStageMask = {.COMPUTE_SHADER},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
			srcAccessMask = {.SHADER_WRITE},
			dstAccessMask = {
				.COLOR_ATTACHMENT_READ,
				.COLOR_ATTACHMENT_WRITE,
				.DEPTH_STENCIL_ATTACHMENT_WRITE,
			},
		},
		{
			srcSubpass = 0,
			dstSubpass = vk.SUBPASS_EXTERNAL,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstStageMask = {.FRAGMENT_SHADER},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstAccessMask = {.SHADER_READ},
		},
	}
	create_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 2,
		pAttachments    = &attachments[0],
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 2,
		pDependencies   = &dependencies[0],
	}
	vulkan.VK_CHECK(
		vk.CreateRenderPass(r.device, &create_info, nil, &mesh.render_pass),
		"vkCreateRenderPass(terrain mesh)",
	)
}

mesh_create_pipeline :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	if !mesh.available || mesh.shader_module == {} || mesh.render_pass == {} {
		return
	}
	if mesh.pipeline != {} {
		vk.DestroyPipeline(r.device, mesh.pipeline, nil)
		mesh.pipeline = {}
	}
	mesh_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.MESH_EXT},
		module = mesh.shader_module,
		pName  = cstring(mesh_bindings.VOXEL_MESH_MESH_MAIN_ENTRY_POINT),
	}
	fragment_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = mesh.shader_module,
		pName  = cstring(mesh_bindings.VOXEL_MESH_FRAGMENT_MAIN_ENTRY_POINT),
	}
	stages := [2]vk.PipelineShaderStageCreateInfo{mesh_stage, fragment_stage}
	viewport := vk.Viewport {
		width    = f32(ctx.output_extent.x),
		height   = f32(ctx.output_extent.y),
		minDepth = 0,
		maxDepth = 1,
	}
	scissor := vk.Rect2D {
		extent = {ctx.output_extent.x, ctx.output_extent.y},
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissor,
	}
	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1,
	}
	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS,
	}
	color_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
	}
	create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = &stages[0],
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pDepthStencilState  = &depth_stencil,
		pColorBlendState    = &color_blending,
		layout              = mesh.pipeline_layout,
		renderPass          = mesh.render_pass,
		subpass             = 0,
	}
	vulkan.VK_CHECK(
		vk.CreateGraphicsPipelines(r.device, {}, 1, &create_info, nil, &mesh.pipeline),
		"vkCreateGraphicsPipelines(terrain mesh)",
	)
}

mesh_update_descriptors :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	if !mesh.available {
		return
	}
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		uniform_info := vk.DescriptorBufferInfo {
			buffer = mesh.uniform_buffers[index].buffer,
			range  = mesh_bindings.VOXEL_MESH_UNIFORM_BUFFER_SIZE,
		}
		chunk_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_chunk_buffers[index].buffer,
			range  = MAX_GPU_CHUNKS * size_of(mesh_bindings.VoxelChunk),
		}
		brick_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_brick_buffers[index].buffer,
			range  = MAX_GPU_BRICKS * size_of(mesh_bindings.VoxelBrick),
		}
		voxel_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_material_buffers[index].buffer,
			range  = MAX_GPU_VOXEL_WORDS * size_of(u32),
		}
		chunk_table_info := vk.DescriptorBufferInfo {
			buffer = ctx.voxel_chunk_table_buffers[index].buffer,
			range  = MAX_GPU_CHUNK_TABLE_SLOTS * size_of(mesh_bindings.VoxelChunkSlot),
		}
		material_info := vk.DescriptorBufferInfo {
			buffer = ctx.material_buffers[index].buffer,
			range  = MAX_GPU_MATERIALS * size_of(mesh_bindings.MaterialRenderInfo),
		}
		mesh_brick_info := vk.DescriptorBufferInfo {
			buffer = mesh.brick_buffers[index].buffer,
			range  = MAX_GPU_BRICKS * size_of(mesh_bindings.MeshBrick),
		}
		level_info := vk.DescriptorBufferInfo {
			buffer = ctx.level_buffers[index].buffer,
			range  = heightfield.MAX_LOD_LEVELS * size_of(mesh_bindings.TerrainLevel),
		}
		sample_info := vk.DescriptorBufferInfo {
			buffer = ctx.sample_buffers[index].buffer,
			range  = MAX_GPU_SAMPLES * size_of(mesh_bindings.TerrainSample),
		}
		stats_info := vk.DescriptorBufferInfo {
			buffer = mesh.stats_buffers[index].buffer,
			range  = size_of(mesh_bindings.MeshStats),
		}
		writes := [10]vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_MESHSETTINGS,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &uniform_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELCHUNKS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &chunk_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELBRICKS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &brick_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELMATERIALS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &voxel_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_VOXELCHUNKTABLE,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &chunk_table_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_MATERIALS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &material_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_MESHBRICKS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &mesh_brick_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_TERRAINLEVELS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &level_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_MESHSTATS,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &stats_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = mesh.descriptor_sets[index],
				dstBinding = mesh_bindings.VOXEL_MESH_BINDING_G_TERRAINSAMPLES,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &sample_info,
			},
		}
		vk.UpdateDescriptorSets(r.device, len(writes), &writes[0], 0, nil)
	}
}

mesh_create_output :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	if !mesh.available {
		return
	}
	mesh.depth_format = mesh_depth_format(r)
	assert(mesh.depth_format != .UNDEFINED, "No supported terrain mesh depth format")
	mesh_create_render_pass(ctx, r)
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		image, allocation := vulkan.create_image(
			r,
			ctx.output_extent.x,
			ctx.output_extent.y,
			mesh.depth_format,
			{.DEPTH_STENCIL_ATTACHMENT},
			{.DEVICE_LOCAL},
		)
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = mesh.depth_format,
			subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
		}
		view: vk.ImageView
		vulkan.VK_CHECK(
			vk.CreateImageView(r.device, &view_info, nil, &view),
			"vkCreateImageView(terrain mesh depth)",
		)
		mesh.depth_images[index] = {
			image      = image,
			view       = view,
			allocation = allocation,
		}
		attachments := [2]vk.ImageView{ctx.outputs[index].view, view}
		framebuffer_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = mesh.render_pass,
			attachmentCount = 2,
			pAttachments    = &attachments[0],
			width           = ctx.output_extent.x,
			height          = ctx.output_extent.y,
			layers          = 1,
		}
		vulkan.VK_CHECK(
			vk.CreateFramebuffer(r.device, &framebuffer_info, nil, &mesh.framebuffers[index]),
			"vkCreateFramebuffer(terrain mesh)",
		)
	}
	mesh_update_descriptors(ctx, r)
	mesh_create_pipeline(ctx, r)
}

mesh_destroy_output :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	if mesh.pipeline != {} {
		vk.DestroyPipeline(r.device, mesh.pipeline, nil)
		mesh.pipeline = {}
	}
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		if mesh.framebuffers[index] != {} {
			vk.DestroyFramebuffer(r.device, mesh.framebuffers[index], nil)
			mesh.framebuffers[index] = {}
		}
		vulkan.destroy_image(r, &mesh.depth_images[index])
	}
	if mesh.render_pass != {} {
		vk.DestroyRenderPass(r.device, mesh.render_pass, nil)
		mesh.render_pass = {}
	}
}

mesh_reload_shader :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	if !mesh.available {
		return
	}
	if mesh.pipeline != {} {
		vk.DestroyPipeline(r.device, mesh.pipeline, nil)
		mesh.pipeline = {}
	}
	if mesh.shader_module != {} {
		vk.DestroyShaderModule(r.device, mesh.shader_module, nil)
		mesh.shader_module = {}
	}
	shader_code := shader_assets.load_bytes("voxel_mesh.spirv")
	defer delete(shader_code)
	mesh.shader_module = vulkan.create_shader_module(r, shader_code)
	mesh_create_pipeline(ctx, r)
}

mesh_brick_kind_at :: proc(
	world: ^voxel_terrain.World,
	voxel_min: [3]i32,
) -> voxel_terrain.Brick_Kind {
	coord := voxel_terrain.voxel_to_chunk(voxel_min)
	chunk, resident := world.chunks[coord]
	if !resident {
		return .EMPTY
	}
	local := voxel_terrain.local_voxel(voxel_min, coord)
	return chunk.bricks[voxel_terrain.brick_index(local)].kind
}

mesh_brick_has_potential_surface :: proc(
	world: ^voxel_terrain.World,
	voxel_min: [3]i32,
	kind: voxel_terrain.Brick_Kind,
) -> bool {
	if kind == .EMPTY {
		return false
	}
	if kind == .MIXED {
		return true
	}
	offsets := [?][3]i32 {
		{-voxel_terrain.BRICK_SIZE, 0, 0},
		{voxel_terrain.BRICK_SIZE, 0, 0},
		{0, -voxel_terrain.BRICK_SIZE, 0},
		{0, voxel_terrain.BRICK_SIZE, 0},
		{0, 0, -voxel_terrain.BRICK_SIZE},
		{0, 0, voxel_terrain.BRICK_SIZE},
	}
	for offset in offsets {
		if mesh_brick_kind_at(world, voxel_min + offset) != .SOLID {
			return true
		}
	}
	return false
}

mesh_build_bricks :: proc(ctx: ^Context, world: ^voxel_terrain.World) {
	mesh := &ctx.mesh
	if !mesh.available {
		return
	}
	clear(&mesh.bricks)
	for coord in ctx.sorted_chunk_coords {
		chunk := world.chunks[coord]
		for z in 0 ..< voxel_terrain.BRICKS_PER_AXIS {
			for y in 0 ..< voxel_terrain.BRICKS_PER_AXIS {
				for x in 0 ..< voxel_terrain.BRICKS_PER_AXIS {
					local := [3]i32{i32(x), i32(y), i32(z)} * voxel_terrain.BRICK_SIZE
					kind := chunk.bricks[voxel_terrain.brick_index(local)].kind
					voxel_min :=
						[3]i32{coord.x, coord.y, coord.z} * voxel_terrain.CHUNK_SIZE + local
					if mesh_brick_has_potential_surface(world, voxel_min, kind) {
						append(&mesh.bricks, mesh_bindings.MeshBrick{voxelMin = voxel_min})
					}
				}
			}
		}
	}
	assert(len(mesh.bricks) <= MAX_GPU_BRICKS, "Terrain mesh brick capacity exceeded")
	mesh.stats.candidate_bricks = u32(len(mesh.bricks))
}

mesh_heightfield_grid_diameter :: proc(lod_end_distance, cell_size: f32) -> u32 {
	cell_radius := u32(math.ceil(lod_end_distance / cell_size)) + 2
	patch_radius :=
		(cell_radius + MESH_HEIGHTFIELD_PATCH_CELLS - 1) / MESH_HEIGHTFIELD_PATCH_CELLS
	return patch_radius * 2 + 1
}

mesh_update_frame_data :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	input: ^Frame_Input,
	frame_index: int,
) -> (
	u32,
	u32,
) {
	mesh := &ctx.mesh
	if mesh.stats_ready[frame_index] {
		raw: mesh_bindings.MeshStats
		vulkan.read_buffer(r, &mesh.stats_buffers[frame_index], &raw, size_of(raw))
		mesh.stats.visible_bricks = raw.visibleBricks
		mesh.stats.culled_bricks = raw.culledBricks
		mesh.stats.mesh_workgroups = raw.meshWorkgroups
		mesh.stats.culled_workgroups = raw.culledWorkgroups
		mesh.stats.generated_faces = raw.generatedFaces
		mesh.stats.generated_primitives = raw.generatedPrimitives
		mesh.stats.heightfield_cells = raw.heightfieldCells
		mesh.stats.heightfield_primitives = raw.heightfieldPrimitives
	}
	zero: mesh_bindings.MeshStats
	vulkan.write_buffer(r, &mesh.stats_buffers[frame_index], &zero, size_of(zero))
	mesh.stats_ready[frame_index] = true
	edit_count := u64(input.overrides.modified_count)
	if mesh.uploaded_generation[frame_index] != input.voxels.generation ||
	   mesh.uploaded_edit_count[frame_index] != edit_count {
		if len(mesh.bricks) > 0 {
			vulkan.write_buffer(
				r,
				&mesh.brick_buffers[frame_index],
				raw_data(mesh.bricks),
				len(mesh.bricks) * size_of(mesh_bindings.MeshBrick),
			)
		}
		mesh.uploaded_generation[frame_index] = input.voxels.generation
		mesh.uploaded_edit_count[frame_index] = edit_count
	}
	lod_grid_diameters: [heightfield.MAX_LOD_LEVELS]u32
	heightfield_workgroups: u64
	for index in 0 ..< int(input.config.heightfield_lod_count) {
		diameter :=
			mesh_heightfield_grid_diameter(
				input.config.heightfield_lod_end_distances[index],
				input.config.virtual_voxel_size[index],
			)
		lod_grid_diameters[index] = diameter
		heightfield_workgroups += u64(diameter) * u64(diameter)
	}
	voxel_workgroups := u64(len(mesh.bricks) * MESH_WORKGROUPS_PER_BRICK)
	total_workgroups := voxel_workgroups + heightfield_workgroups
	assert(total_workgroups <= u64(~u32(0)))
	dispatch_x := min(u32(total_workgroups), r.mesh_shader.max_work_group_count[0])
	if dispatch_x == 0 {
		dispatch_x = 1
	}
	dispatch_y := u32((total_workgroups + u64(dispatch_x) - 1) / u64(dispatch_x))
	assert(dispatch_y <= r.mesh_shader.max_work_group_count[1])
	uniforms := mesh_bindings.MeshSettings {
		viewProj = input.camera.view_proj,
		cameraPosition = input.camera.position,
		voxelSize = input.voxels.config.voxel_size,
		nearVoxelDistance = input.config.near_voxel_distance,
		meshBrickCount = u32(len(mesh.bricks)),
		meshDispatchX = dispatch_x,
		chunkTableMask = ctx.chunk_table_mask,
		materialCount = u32(len(input.materials)),
		visualSeedLo = u32(input.visual_seed),
		visualSeedHi = u32(input.visual_seed >> 32),
		debugMode = u32(input.debug_mode),
		heightfieldWorkgroupCount = u32(heightfield_workgroups),
		levelCount = input.config.heightfield_lod_count,
		terrainMaterialOffset = u32(len(input.materials)),
		terrainMaterialCount = u32(len(input.terrain_materials)),
		worldRadius = input.world_radius,
		maxDistance = input.config.far_distance,
		debugRingRadius = input.debug_ring_radius,
		heightfieldTransitionWidth = input.config.heightfield_lod_transition_width,
		lodDistances0 = {
			input.config.heightfield_lod_end_distances[0],
			input.config.heightfield_lod_end_distances[1],
			input.config.heightfield_lod_end_distances[2],
			input.config.heightfield_lod_end_distances[3],
		},
		lodDistances1 = {
			input.config.heightfield_lod_end_distances[4],
			input.config.heightfield_lod_end_distances[5],
			input.config.heightfield_lod_end_distances[6],
			input.config.heightfield_lod_end_distances[7],
		},
		lodDistances2 = {
			input.config.heightfield_lod_end_distances[8],
			input.config.far_distance,
			input.config.far_distance,
			input.config.far_distance,
		},
		virtualVoxelSizes0 = {
			input.config.virtual_voxel_size[0],
			input.config.virtual_voxel_size[1],
			input.config.virtual_voxel_size[2],
			input.config.virtual_voxel_size[3],
		},
		virtualVoxelSizes1 = {
			input.config.virtual_voxel_size[4],
			input.config.virtual_voxel_size[5],
			input.config.virtual_voxel_size[6],
			input.config.virtual_voxel_size[7],
		},
		virtualVoxelSizes2 = {
			input.config.virtual_voxel_size[8],
			input.config.virtual_voxel_size[8],
			input.config.virtual_voxel_size[8],
			input.config.virtual_voxel_size[8],
		},
		verticalSteps0 = {
			input.config.vertical_quantization[0],
			input.config.vertical_quantization[1],
			input.config.vertical_quantization[2],
			input.config.vertical_quantization[3],
		},
		verticalSteps1 = {
			input.config.vertical_quantization[4],
			input.config.vertical_quantization[5],
			input.config.vertical_quantization[6],
			input.config.vertical_quantization[7],
		},
		verticalSteps2 = {
			input.config.vertical_quantization[8],
			input.config.vertical_quantization[8],
			input.config.vertical_quantization[8],
			input.config.vertical_quantization[8],
		},
		lodGridDiameters0 = {
			lod_grid_diameters[0],
			lod_grid_diameters[1],
			lod_grid_diameters[2],
			lod_grid_diameters[3],
		},
		lodGridDiameters1 = {
			lod_grid_diameters[4],
			lod_grid_diameters[5],
			lod_grid_diameters[6],
			lod_grid_diameters[7],
		},
		lodGridDiameters2 = {
			lod_grid_diameters[8],
			0,
			0,
			0,
		},
		outputSize = {f32(ctx.output_extent.x), f32(ctx.output_extent.y)},
		voxelTransitionWidth = input.config.voxel_transition_width,
	}
	vulkan.write_buffer(
		r,
		&mesh.uniform_buffers[frame_index],
		&uniforms,
		mesh_bindings.VOXEL_MESH_UNIFORM_BUFFER_SIZE,
	)
	return dispatch_x, dispatch_y
}

mesh_record_frame :: proc(
	ctx: ^Context,
	r: ^vulkan.Renderer,
	input: ^Frame_Input,
	command_buffer: vk.CommandBuffer,
	frame_index: int,
) {
	mesh := &ctx.mesh
	dispatch_x, dispatch_y := mesh_update_frame_data(ctx, r, input, frame_index)
	clear_values := [2]vk.ClearValue {
		{color = {float32 = {0, 0, 0, 0}}},
		{depthStencil = {depth = 1, stencil = 0}},
	}
	pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = mesh.render_pass,
		framebuffer = mesh.framebuffers[frame_index],
		renderArea = {extent = {ctx.output_extent.x, ctx.output_extent.y}},
		clearValueCount = 2,
		pClearValues = &clear_values[0],
	}
	vk.CmdBeginRenderPass(command_buffer, &pass_info, .INLINE)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, mesh.pipeline)
	vk.CmdBindDescriptorSets(
		command_buffer,
		.GRAPHICS,
		mesh.pipeline_layout,
		0,
		1,
		&mesh.descriptor_sets[frame_index],
		0,
		nil,
	)
	vk.CmdDrawMeshTasksEXT(command_buffer, dispatch_x, dispatch_y, 1)
	vk.CmdEndRenderPass(command_buffer)
	ctx.output_layouts[frame_index] = .SHADER_READ_ONLY_OPTIMAL
}

mesh_destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	mesh := &ctx.mesh
	mesh_destroy_output(ctx, r)
	for index in 0 ..< vulkan.MAX_FRAMES_IN_FLIGHT {
		vulkan.destroy_buffer(r, &mesh.uniform_buffers[index])
		vulkan.destroy_buffer(r, &mesh.brick_buffers[index])
		vulkan.destroy_buffer(r, &mesh.stats_buffers[index])
	}
	delete(mesh.bricks)
	if mesh.shader_module != {} {
		vk.DestroyShaderModule(r.device, mesh.shader_module, nil)
	}
	if mesh.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, mesh.pipeline_layout, nil)
	}
	if mesh.descriptor_layout != {} {
		vk.DestroyDescriptorSetLayout(r.device, mesh.descriptor_layout, nil)
	}
	mesh^ = {}
}
