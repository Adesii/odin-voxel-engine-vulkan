package vkapi

import vma "../../../../vendor/odin-vma"
import "../../../shaders/default_shader"
import "core:fmt"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

create_shader_module :: proc(r: ^Renderer, bytes: []byte) -> vk.ShaderModule {
	if len(bytes) == 0 || len(bytes) % 4 != 0 {
		fmt.panicf("Invalid SPIR-V bytecode size: %d", len(bytes))
	}
	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(bytes),
		pCode    = cast(^u32)raw_data(bytes),
	}
	module: vk.ShaderModule
	VK_CHECK(vk.CreateShaderModule(r.device, &create_info, nil, &module), "vkCreateShaderModule")
	return module
}

reload_presentation_shader :: proc(r: ^Renderer, shader_code: []byte) {
	_ = vk.DeviceWaitIdle(r.device)

	if r.fullscreen.pipeline != {} {
		vk.DestroyPipeline(r.device, r.fullscreen.pipeline, nil)
		r.fullscreen.pipeline = {}
	}
	if r.fullscreen.vert_module != {} {
		vk.DestroyShaderModule(r.device, r.fullscreen.vert_module, nil)
		r.fullscreen.vert_module = {}
	}
	if r.fullscreen.frag_module != {} {
		vk.DestroyShaderModule(r.device, r.fullscreen.frag_module, nil)
		r.fullscreen.frag_module = {}
	}

	if r.fullscreen.descriptor_layout == {} {
		create_presentation_descriptors(r)
	}
	r.fullscreen.vert_module = create_shader_module(r, shader_code)
	r.fullscreen.frag_module = create_shader_module(r, shader_code)
	create_pipeline(r)
}

create_presentation_descriptors :: proc(r: ^Renderer) {
	binding := vk.DescriptorSetLayoutBinding {
		binding         = default_shader.DEFAULT_BINDING_G_TEXTURE,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &binding,
	}
	VK_CHECK(
		vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &r.fullscreen.descriptor_layout),
		"vkCreateDescriptorSetLayout(presentation)",
	)
	r.fullscreen.pipeline_layout = create_pipeline_layout(r, r.fullscreen.descriptor_layout)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		r.fullscreen.descriptor_sets[i] = allocate_descriptor_set(
			r,
			r.fullscreen.descriptor_layout,
		)
	}
}

create_pipeline :: proc(r: ^Renderer) {
	vert_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = r.fullscreen.vert_module,
		pName  = cstring(default_shader.DEFAULT_VS_MAIN_ENTRY_POINT),
	}
	frag_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = r.fullscreen.frag_module,
		pName  = cstring(default_shader.DEFAULT_FS_MAIN_ENTRY_POINT),
	}
	shader_stages := [2]vk.PipelineShaderStageCreateInfo{vert_stage, frag_stage}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
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
	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {.BACK},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1,
	}
	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

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
		layout              = r.fullscreen.pipeline_layout,
		renderPass          = r.fullscreen.render_pass,
		subpass             = 0,
	}
	VK_CHECK(
		vk.CreateGraphicsPipelines(r.device, {}, 1, &create_info, nil, &r.fullscreen.pipeline),
		"vkCreateGraphicsPipelines",
	)

}


bind_fullscreen_descriptors :: proc(r: ^Renderer, source: Image, frame_slot: int) {
	image_info := vk.DescriptorImageInfo {
		sampler     = source.sampler,
		imageView   = source.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write_descriptor := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.fullscreen.descriptor_sets[frame_slot],
		dstBinding      = default_shader.DEFAULT_BINDING_G_TEXTURE,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(r.device, 1, &write_descriptor, 0, nil)
}

record_command_buffer :: proc(
	r: ^Renderer,
	command_buffer: vk.CommandBuffer,
	image_index: u32,
	desc: Frame_Description,
) {
	frame_slot := r.frame_index % MAX_FRAMES_IN_FLIGHT
	VK_CHECK(vk.ResetCommandBuffer(command_buffer, {}), "vkResetCommandBuffer")
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	VK_CHECK(vk.BeginCommandBuffer(command_buffer, &begin_info), "vkBeginCommandBuffer")

	if desc.record_content != nil {
		desc.record_content(desc.content_data, r, command_buffer, image_index)
	}

	assert(desc.source_image.view != {}, "Frame source image view is invalid")
	assert(desc.source_image.sampler != {}, "Frame source image sampler is invalid")
	clear_value := vk.ClearValue {
		color = {float32 = [4]f32{0.1, 0.12, 0.16, 1}},
	}
	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = r.fullscreen.render_pass,
		framebuffer = r.framebuffers[image_index],
		renderArea = {extent = r.extent},
		clearValueCount = 1,
		pClearValues = &clear_value,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)
	bind_fullscreen_descriptors(r, desc.source_image, frame_slot)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, r.fullscreen.pipeline)
	vk.CmdBindDescriptorSets(
		command_buffer,
		.GRAPHICS,
		r.fullscreen.pipeline_layout,
		0,
		1,
		&r.fullscreen.descriptor_sets[frame_slot],
		0,
		nil,
	)
	vk.CmdDraw(command_buffer, 6, 1, 0, 0)
	vk.CmdEndRenderPass(command_buffer)

	if desc.record_overlay != nil {
		desc.record_overlay(desc.overlay_data, r, command_buffer, image_index)
	}

	VK_CHECK(vk.EndCommandBuffer(command_buffer), "vkEndCommandBuffer")
}

frame :: proc(r: ^Renderer, desc: Frame_Description) -> Frame_Result {
	frame_slot := r.frame_index % MAX_FRAMES_IN_FLIGHT
	VK_CHECK(
		vk.WaitForFences(r.device, 1, &r.in_flight[frame_slot], true, vk.WHOLE_SIZE),
		"vkWaitForFences",
	)

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		r.device,
		r.swapchain,
		vk.WHOLE_SIZE,
		r.image_available[frame_slot],
		{},
		&image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		if recreate_swapchain(r, desc.swapchain) {
			return .SWAPCHAIN_RECREATED
		}
		return .SKIPPED
	}
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.panicf("vkAcquireNextImageKHR failed: %v", acquire_result)
	}
	if r.images_in_flight[image_index] != {} {
		VK_CHECK(
			vk.WaitForFences(r.device, 1, &r.images_in_flight[image_index], true, vk.WHOLE_SIZE),
			"vkWaitForFences(image)",
		)
	}
	VK_CHECK(vk.ResetFences(r.device, 1, &r.in_flight[frame_slot]), "vkResetFences")
	r.images_in_flight[image_index] = r.in_flight[frame_slot]

	record_command_buffer(r, r.command_buffers[frame_slot], image_index, desc)
	render_finished := r.render_finished[image_index]
	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &r.image_available[frame_slot],
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &r.command_buffers[frame_slot],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &render_finished,
	}
	VK_CHECK(
		vk.QueueSubmit(r.graphics_queue, 1, &submit_info, r.in_flight[frame_slot]),
		"vkQueueSubmit",
	)
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &render_finished,
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain,
		pImageIndices      = &image_index,
	}
	present_result := vk.QueuePresentKHR(r.present_queue, &present_info)
	r.frame_index += 1
	if present_result == .ERROR_OUT_OF_DATE_KHR ||
	   present_result == .SUBOPTIMAL_KHR ||
	   r.framebuffer_resized {
		r.framebuffer_resized = false
		if recreate_swapchain(r, desc.swapchain) {
			return .SWAPCHAIN_RECREATED
		}
		return .SKIPPED
	}
	if present_result != .SUCCESS {
		fmt.panicf("vkQueuePresentKHR failed: %v", present_result)
	}
	return .RENDERED
}

finish :: proc(r: ^Renderer) {
	if r.device != {} {
		_ = vk.DeviceWaitIdle(r.device)
	}
	destroy_swapchain_objects(r)
	if r.fullscreen.vert_module != {} {
		vk.DestroyShaderModule(r.device, r.fullscreen.vert_module, nil)
	}
	if r.fullscreen.frag_module != {} {
		vk.DestroyShaderModule(r.device, r.fullscreen.frag_module, nil)
	}
	if r.fullscreen.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, r.fullscreen.pipeline_layout, nil)
	}
	if r.fullscreen.descriptor_layout != {} {
		vk.DestroyDescriptorSetLayout(r.device, r.fullscreen.descriptor_layout, nil)
	}
	for semaphore in r.image_available {
		if semaphore != {} {
			vk.DestroySemaphore(r.device, semaphore, nil)
		}
	}
	for fence in r.in_flight {
		if fence != {} {
			vk.DestroyFence(r.device, fence, nil)
		}
	}
	if r.command_pool != {} {
		vk.DestroyCommandPool(r.device, r.command_pool, nil)
	}
	if r.descriptor_pool != {} {
		vk.DestroyDescriptorPool(r.device, r.descriptor_pool, nil)
	}
	if r.allocator_vma != {} {
		vma.DestroyAllocator(r.allocator_vma)
	}
	if r.device != {} {
		vk.DestroyDevice(r.device, nil)
	}
	if r.debug_messenger != {} {
		vk.DestroyDebugUtilsMessengerEXT(r.instance, r.debug_messenger, nil)
	}
	if r.surface != {} {
		vk.DestroySurfaceKHR(r.instance, r.surface, nil)
	}
	if r.instance != {} {
		vk.DestroyInstance(r.instance, nil)
	}
	sdl.Vulkan_UnloadLibrary()
	r^ = {}
}
