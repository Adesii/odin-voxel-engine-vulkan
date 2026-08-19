package microui_backend

import vma "../../../../vendor/odin-vma"
import bindings "../../../shaders/ui_shader_shader"
import shader_assets "../../render/shader_assets"
import vulkan "../../render/vulkan"
import mu "vendor:microui"
import vk "vendor:vulkan"

BUFFER_SIZE :: 16384

gpu_context :: struct {
	texture:             vulkan.Image,
	descriptor_layout:   vk.DescriptorSetLayout,
	descriptor_pool:     vk.DescriptorPool,
	descriptor_set:      vk.DescriptorSet,
	pipeline_layout:     vk.PipelineLayout,
	pipeline:            vk.Pipeline,
	render_pass:         vk.RenderPass,
	framebuffers:        []vk.Framebuffer,
	vertex_buffer:       vulkan.Buffer,
	tex_buffer:          vulkan.Buffer,
	color_buffer:        vulkan.Buffer,
	index_buffer:        vulkan.Buffer,
	const_buffer:        vulkan.Buffer,
	shader_module:       vk.ShaderModule,
	tex_buf:             [BUFFER_SIZE * 8]f32,
	vert_buf:            [BUFFER_SIZE * 8]f32,
	color_buf:           [BUFFER_SIZE * 16]u8,
	index_buf:           [BUFFER_SIZE * 6]u32,
	prev_buf_idx:        u32,
	buf_idx:             u32,
	current_command:     vk.CommandBuffer,
	current_framebuffer: vk.Framebuffer,
}

gpu_init :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ui := &ctx.gpu
	ui.vertex_buffer = vulkan.create_buffer(
		r,
		size_of(ui.vert_buf),
		{.VERTEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.tex_buffer = vulkan.create_buffer(
		r,
		size_of(ui.tex_buf),
		{.VERTEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.color_buffer = vulkan.create_buffer(
		r,
		size_of(ui.color_buf),
		{.VERTEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.index_buffer = vulkan.create_buffer(
		r,
		size_of(ui.index_buf),
		{.INDEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.const_buffer = vulkan.create_buffer(
		r,
		size_of(matrix[4, 4]f32),
		{.UNIFORM_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	create_texture(ctx, r)
	create_descriptors(ctx, r)
	create_swapchain_objects(ctx, r)
	reload_shader(ctx, r)
}

create_texture :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ui := &ctx.gpu
	staging := vulkan.create_buffer(
		r,
		len(mu.default_atlas_alpha),
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer vulkan.destroy_buffer(r, &staging)
	vulkan.write_buffer(
		r,
		&staging,
		raw_data(mu.default_atlas_alpha[:]),
		len(mu.default_atlas_alpha),
	)
	image, allocation := vulkan.create_image(
		r,
		mu.DEFAULT_ATLAS_WIDTH,
		mu.DEFAULT_ATLAS_HEIGHT,
		.R8_UNORM,
		{.TRANSFER_DST, .SAMPLED},
		{.DEVICE_LOCAL},
	)
	vulkan.transition_image_layout(r, image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
	vulkan.copy_buffer_to_image(
		r,
		staging.buffer,
		image,
		mu.DEFAULT_ATLAS_WIDTH,
		mu.DEFAULT_ATLAS_HEIGHT,
	)
	vulkan.transition_image_layout(r, image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = .D2,
		format = .R8_UNORM,
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
		"vkCreateImageView(ui)",
	)
	ui.texture = vulkan.Image {
		image      = image,
		view       = image_view,
		sampler    = vulkan.create_sampler(r, .NEAREST, .CLAMP_TO_EDGE),
		allocation = allocation,
	}
}

create_descriptors :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ui := &ctx.gpu
	layout_bindings := [3]vk.DescriptorSetLayoutBinding {
		{
			binding = bindings.UI_SHADER_BINDING_SAMP,
			descriptorType = .SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = bindings.UI_SHADER_BINDING_TEXT,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = bindings.UI_SHADER_BINDING_GLOBALS,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX},
		},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(layout_bindings),
		pBindings    = &layout_bindings[0],
	}
	vulkan.VK_CHECK(
		vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &ui.descriptor_layout),
		"vkCreateDescriptorSetLayout(ui)",
	)
	pool_sizes := [3]vk.DescriptorPoolSize {
		{type = .SAMPLER, descriptorCount = 1},
		{type = .SAMPLED_IMAGE, descriptorCount = 1},
		{type = .UNIFORM_BUFFER, descriptorCount = 1},
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = len(pool_sizes),
		pPoolSizes    = &pool_sizes[0],
	}
	vulkan.VK_CHECK(
		vk.CreateDescriptorPool(r.device, &pool_info, nil, &ui.descriptor_pool),
		"vkCreateDescriptorPool(ui)",
	)
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = ui.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &ui.descriptor_layout,
	}
	vulkan.VK_CHECK(
		vk.AllocateDescriptorSets(r.device, &alloc_info, &ui.descriptor_set),
		"vkAllocateDescriptorSets(ui)",
	)
	image_info := vk.DescriptorImageInfo {
		sampler     = ui.texture.sampler,
		imageView   = ui.texture.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	allocation_info: vma.AllocationInfo
	vma.GetAllocationInfo(r.allocator_vma, ui.const_buffer.allocation, &allocation_info)
	buffer_info := vk.DescriptorBufferInfo {
		buffer = ui.const_buffer.buffer,
		offset = 0,
		range  = allocation_info.size,
	}
	writes := [3]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = ui.descriptor_set,
			dstBinding = bindings.UI_SHADER_BINDING_SAMP,
			descriptorCount = 1,
			descriptorType = .SAMPLER,
			pImageInfo = &image_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = ui.descriptor_set,
			dstBinding = bindings.UI_SHADER_BINDING_TEXT,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &image_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = ui.descriptor_set,
			dstBinding = bindings.UI_SHADER_BINDING_GLOBALS,
			descriptorCount = 1,
			descriptorType = .UNIFORM_BUFFER,
			pBufferInfo = &buffer_info,
		},
	}
	vk.UpdateDescriptorSets(r.device, len(writes), &writes[0], 0, nil)
}

create_swapchain_objects :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	create_render_pass(ctx, r)
	create_framebuffers(ctx, r)
}

create_render_pass :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	attachment := vk.AttachmentDescription {
		format         = r.surface_format.format,
		samples        = {._1},
		loadOp         = .LOAD,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .COLOR_ATTACHMENT_OPTIMAL,
		finalLayout    = .PRESENT_SRC_KHR,
	}
	color_attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}
	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}
	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstAccessMask = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
	}
	create_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}
	vulkan.VK_CHECK(
		vk.CreateRenderPass(r.device, &create_info, nil, &ctx.gpu.render_pass),
		"vkCreateRenderPass(ui)",
	)
}

create_framebuffers :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ui := &ctx.gpu
	ui.framebuffers = make([]vk.Framebuffer, len(r.swapchain_views), context.allocator)
	for image_view, i in r.swapchain_views {
		attachments := [1]vk.ImageView{image_view}
		create_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = ui.render_pass,
			attachmentCount = 1,
			pAttachments    = &attachments[0],
			width           = r.extent.width,
			height          = r.extent.height,
			layers          = 1,
		}
		vulkan.VK_CHECK(
			vk.CreateFramebuffer(r.device, &create_info, nil, &ui.framebuffers[i]),
			"vkCreateFramebuffer(ui)",
		)
	}
}

reload_shader :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	_ = vk.DeviceWaitIdle(r.device)
	destroy_pipeline(ctx, r)
	if ctx.gpu.shader_module != {} {
		vk.DestroyShaderModule(r.device, ctx.gpu.shader_module, nil)
		ctx.gpu.shader_module = {}
	}
	shader_code := shader_assets.load_bytes("ui_shader.spirv")
	defer delete(shader_code)
	ctx.gpu.shader_module = vulkan.create_shader_module(r, shader_code)
	create_pipeline(ctx, r)
}

create_pipeline :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	ui := &ctx.gpu
	vert_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = ui.shader_module,
		pName  = cstring(bindings.UI_SHADER_VS_MAIN_ENTRY_POINT),
	}
	frag_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = ui.shader_module,
		pName  = cstring(bindings.UI_SHADER_FS_MAIN_ENTRY_POINT),
	}
	shader_stages := [2]vk.PipelineShaderStageCreateInfo{vert_stage, frag_stage}
	vertex_bindings := [3]vk.VertexInputBindingDescription {
		{binding = 0, stride = 8, inputRate = .VERTEX},
		{binding = 1, stride = 8, inputRate = .VERTEX},
		{binding = 2, stride = 4, inputRate = .VERTEX},
	}
	attributes := [3]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32_SFLOAT},
		{location = 1, binding = 1, format = .R32G32_SFLOAT},
		{location = 2, binding = 2, format = .R32_UINT},
	}
	dynamic_states := [1]vk.DynamicState{.SCISSOR}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = len(vertex_bindings),
		pVertexBindingDescriptions      = &vertex_bindings[0],
		vertexAttributeDescriptionCount = len(attributes),
		pVertexAttributeDescriptions    = &attributes[0],
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport := vk.Viewport {
		width    = f32(r.extent.width),
		height   = f32(r.extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	scissor := vk.Rect2D {
		extent = r.extent,
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissor,
	}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}
	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = vk.CullModeFlags_NONE,
		frontFace   = .CLOCKWISE,
		lineWidth   = 1,
	}
	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .SRC_ALPHA,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts    = &ui.descriptor_layout,
	}
	vulkan.VK_CHECK(
		vk.CreatePipelineLayout(r.device, &layout_info, nil, &ui.pipeline_layout),
		"vkCreatePipelineLayout(ui)",
	)
	create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(shader_stages),
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = ui.pipeline_layout,
		renderPass          = ui.render_pass,
		subpass             = 0,
	}
	vulkan.VK_CHECK(
		vk.CreateGraphicsPipelines(r.device, {}, 1, &create_info, nil, &ui.pipeline),
		"vkCreateGraphicsPipelines(ui)",
	)
	write_constants(ctx, r)
}

destroy_pipeline :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	if ctx.gpu.pipeline != {} {
		vk.DestroyPipeline(r.device, ctx.gpu.pipeline, nil)
		ctx.gpu.pipeline = {}
	}
	if ctx.gpu.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, ctx.gpu.pipeline_layout, nil)
		ctx.gpu.pipeline_layout = {}
	}
}

destroy_swapchain_objects :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	for framebuffer in ctx.gpu.framebuffers {
		if framebuffer != {} {
			vk.DestroyFramebuffer(r.device, framebuffer, nil)
		}
	}
	delete(ctx.gpu.framebuffers)
	ctx.gpu.framebuffers = nil
	destroy_pipeline(ctx, r)
	if ctx.gpu.render_pass != {} {
		vk.DestroyRenderPass(r.device, ctx.gpu.render_pass, nil)
		ctx.gpu.render_pass = {}
	}
}

gpu_destroy :: proc(ctx: ^Context, r: ^vulkan.Renderer) {
	destroy_swapchain_objects(ctx, r)
	if ctx.gpu.shader_module != {} {
		vk.DestroyShaderModule(r.device, ctx.gpu.shader_module, nil)
	}
	if ctx.gpu.descriptor_pool != {} {
		vk.DestroyDescriptorPool(r.device, ctx.gpu.descriptor_pool, nil)
	}
	if ctx.gpu.descriptor_layout != {} {
		vk.DestroyDescriptorSetLayout(r.device, ctx.gpu.descriptor_layout, nil)
	}
	vulkan.destroy_image(r, &ctx.gpu.texture)
	vulkan.destroy_buffer(r, &ctx.gpu.vertex_buffer)
	vulkan.destroy_buffer(r, &ctx.gpu.tex_buffer)
	vulkan.destroy_buffer(r, &ctx.gpu.color_buffer)
	vulkan.destroy_buffer(r, &ctx.gpu.index_buffer)
	vulkan.destroy_buffer(r, &ctx.gpu.const_buffer)
	ctx.gpu = {}
}
