package main

import vma "../vendor/odin-vma"
import compiler "utils"
import mu "vendor:microui"
import vk "vendor:vulkan"

vulkan_init_ui :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
	ui.vertex_buffer = vulkan_create_buffer(
		r,
		size_of(ui.vert_buf),
		{.VERTEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.tex_buffer = vulkan_create_buffer(
		r,
		size_of(ui.tex_buf),
		{.VERTEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.color_buffer = vulkan_create_buffer(
		r,
		size_of(ui.color_buf),
		{.VERTEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.index_buffer = vulkan_create_buffer(
		r,
		size_of(ui.index_buf),
		{.INDEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	ui.const_buffer = vulkan_create_buffer(
		r,
		size_of(matrix[4, 4]f32),
		{.UNIFORM_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	vulkan_create_ui_texture(r)
	vulkan_create_ui_descriptors(r)
}

vulkan_create_ui_texture :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
	staging := vulkan_create_buffer(
		r,
		len(mu.default_atlas_alpha),
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer vulkan_destroy_buffer(r, &staging)
	vulkan_write_buffer(
		r,
		&staging,
		raw_data(mu.default_atlas_alpha[:]),
		len(mu.default_atlas_alpha),
	)
	ui.texture_image, ui.texture_allocation = vulkan_create_image(
		r,
		mu.DEFAULT_ATLAS_WIDTH,
		mu.DEFAULT_ATLAS_HEIGHT,
		.R8_UNORM,
		{.TRANSFER_DST, .SAMPLED},
		{.DEVICE_LOCAL},
	)
	vulkan_transition_image_layout(r, ui.texture_image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
	vulkan_copy_buffer_to_image(
		r,
		staging.buffer,
		ui.texture_image,
		mu.DEFAULT_ATLAS_WIDTH,
		mu.DEFAULT_ATLAS_HEIGHT,
	)
	vulkan_transition_image_layout(
		r,
		ui.texture_image,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
	)
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = ui.texture_image,
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
	VK_CHECK(
		vk.CreateImageView(r.device, &view_info, nil, &ui.texture_view),
		"vkCreateImageView(ui)",
	)
	samper_info := vk.SamplerCreateInfo {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = .NEAREST,
		minFilter     = .NEAREST,
		mipmapMode    = .NEAREST,
		addressModeU  = .CLAMP_TO_EDGE,
		addressModeV  = .CLAMP_TO_EDGE,
		addressModeW  = .CLAMP_TO_EDGE,
		maxAnisotropy = 1,
		maxLod        = 1,
	}
	VK_CHECK(vk.CreateSampler(r.device, &samper_info, nil, &ui.sampler), "vkCreateSampler(ui)")
}

vulkan_create_ui_descriptors :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
	bindings := [3]vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		{
			binding = 1,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 2,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX},
		},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 3,
		pBindings    = &bindings[0],
	}
	VK_CHECK(
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
		poolSizeCount = 3,
		pPoolSizes    = &pool_sizes[0],
	}
	VK_CHECK(
		vk.CreateDescriptorPool(r.device, &pool_info, nil, &ui.descriptor_pool),
		"vkCreateDescriptorPool(ui)",
	)
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = ui.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &ui.descriptor_layout,
	}
	VK_CHECK(
		vk.AllocateDescriptorSets(r.device, &alloc_info, &ui.descriptor_set),
		"vkAllocateDescriptorSets(ui)",
	)
	image_info := vk.DescriptorImageInfo {
		sampler     = ui.sampler,
		imageView   = ui.texture_view,
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
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLER,
			pImageInfo = &image_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = ui.descriptor_set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &image_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = ui.descriptor_set,
			dstBinding = 2,
			descriptorCount = 1,
			descriptorType = .UNIFORM_BUFFER,
			pBufferInfo = &buffer_info,
		},
	}
	vk.UpdateDescriptorSets(r.device, 3, &writes[0], 0, nil)
}

vulkan_create_ui_swapchain_objects :: proc(r: ^vulkan_renderer) {
	vulkan_create_ui_render_pass(r)
	vulkan_create_ui_framebuffers(r)
}

vulkan_create_ui_render_pass :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
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
	VK_CHECK(
		vk.CreateRenderPass(r.device, &create_info, nil, &ui.render_pass),
		"vkCreateRenderPass(ui)",
	)
}

vulkan_create_ui_framebuffers :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
	ui.framebuffers = make([]vk.Framebuffer, len(r.swapchain_views), context.allocator)
	for view, i in r.swapchain_views {
		attachments := [1]vk.ImageView{view}
		create_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = ui.render_pass,
			attachmentCount = 1,
			pAttachments    = &attachments[0],
			width           = r.extent.width,
			height          = r.extent.height,
			layers          = 1,
		}
		VK_CHECK(
			vk.CreateFramebuffer(r.device, &create_info, nil, &ui.framebuffers[i]),
			"vkCreateFramebuffer(ui)",
		)
	}
}

vulkan_rebuild_ui_pipeline :: proc(r: ^vulkan_renderer, rebuild_shader_module := true) {
	ui := &r.ui
	if ui.pipeline != {} {
		vk.DestroyPipeline(r.device, ui.pipeline, nil)
		ui.pipeline = {}
	}
	if ui.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, ui.pipeline_layout, nil)
		ui.pipeline_layout = {}
	}
	if rebuild_shader_module && ui.shader_module != {} {
		vk.DestroyShaderModule(r.device, ui.shader_module, nil)
		ui.shader_module = {}
	}
	if rebuild_shader_module {
		ui_code := compiler.load_shader_bytes("ui_shader.spirv")
		defer delete(ui_code)
		ui.shader_module = vulkan_create_shader_module(ui_code)
	}
	vulkan_create_ui_pipeline(r)
}

vulkan_create_ui_pipeline :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
	vert_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = ui.shader_module,
		pName  = cstring("vs_main"),
	}
	frag_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = ui.shader_module,
		pName  = cstring("fs_main"),
	}
	shader_stages := [2]vk.PipelineShaderStageCreateInfo{vert_stage, frag_stage}
	bindings := [3]vk.VertexInputBindingDescription {
		{binding = 0, stride = 8, inputRate = .VERTEX},
		{binding = 1, stride = 8, inputRate = .VERTEX},
		{binding = 2, stride = 4, inputRate = .VERTEX},
	}
	attributes := [3]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = 0},
		{location = 1, binding = 1, format = .R32G32_SFLOAT, offset = 0},
		{location = 2, binding = 2, format = .R32_UINT, offset = 0},
	}
	dynamic_states := [1]vk.DynamicState{.SCISSOR}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 3,
		pVertexBindingDescriptions      = &bindings[0],
		vertexAttributeDescriptionCount = 3,
		pVertexAttributeDescriptions    = &attributes[0],
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
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
		dynamicStateCount = 1,
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
	VK_CHECK(
		vk.CreatePipelineLayout(r.device, &layout_info, nil, &ui.pipeline_layout),
		"vkCreatePipelineLayout(ui)",
	)
	create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
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
	VK_CHECK(
		vk.CreateGraphicsPipelines(r.device, {}, 1, &create_info, nil, &ui.pipeline),
		"vkCreateGraphicsPipelines(ui)",
	)
	r_write_consts()
}

vulkan_destroy_ui_swapchain_objects :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
	for framebuffer in ui.framebuffers {
		if framebuffer != {} {
			vk.DestroyFramebuffer(r.device, framebuffer, nil)
		}
	}
	delete(ui.framebuffers)
	ui.framebuffers = nil
	if ui.pipeline != {} {
		vk.DestroyPipeline(r.device, ui.pipeline, nil)
		ui.pipeline = {}
	}
	if ui.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, ui.pipeline_layout, nil)
		ui.pipeline_layout = {}
	}
	if ui.render_pass != {} {
		vk.DestroyRenderPass(r.device, ui.render_pass, nil)
		ui.render_pass = {}
	}
}

vulkan_shutdown_ui :: proc(r: ^vulkan_renderer) {
	ui := &r.ui
	vulkan_destroy_ui_swapchain_objects(r)
	if ui.shader_module != {} {
		vk.DestroyShaderModule(r.device, ui.shader_module, nil)
	}
	if ui.descriptor_pool != {} {
		vk.DestroyDescriptorPool(r.device, ui.descriptor_pool, nil)
	}
	if ui.descriptor_layout != {} {
		vk.DestroyDescriptorSetLayout(r.device, ui.descriptor_layout, nil)
	}
	if ui.sampler != {} {
		vk.DestroySampler(r.device, ui.sampler, nil)
	}
	if ui.texture_view != {} {
		vk.DestroyImageView(r.device, ui.texture_view, nil)
	}
	if ui.texture_image != {} {
		vma.DestroyImage(r.allocator_vma, ui.texture_image, ui.texture_allocation)
	}
	vulkan_destroy_buffer(r, &ui.vertex_buffer)
	vulkan_destroy_buffer(r, &ui.tex_buffer)
	vulkan_destroy_buffer(r, &ui.color_buffer)
	vulkan_destroy_buffer(r, &ui.index_buffer)
	vulkan_destroy_buffer(r, &ui.const_buffer)
	vma.DestroyAllocator(r.allocator_vma)
}
