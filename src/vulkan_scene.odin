package main

import "core:fmt"
import compiler "utils"
import "utils"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

vulkan_create_shader_module :: proc(bytes: []byte) -> vk.ShaderModule {
	if len(bytes) == 0 || len(bytes) % 4 != 0 {
		fmt.panicf("Invalid SPIR-V bytecode size: %d", len(bytes))
	}
	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(bytes),
		pCode    = cast(^u32)raw_data(bytes),
	}
	module: vk.ShaderModule
	VK_CHECK(
		vk.CreateShaderModule(state.renderer.device, &create_info, nil, &module),
		"vkCreateShaderModule",
	)
	return module
}

rebuild_shaders :: proc() {
	context = state.ctx
	r := &state.renderer
	fmt.printfln("Reloading shaders...")
	compiler.compile("shader_src/", "shaders/")

	shader_path := compiler.get_shader_path("default.slang")
	defer delete(shader_path)
	utils.add_file_watcher(shader_path, proc(filepath: string) {rebuild_shaders()})

	_ = vk.DeviceWaitIdle(r.device)

	if r.pipeline != {} {
		vk.DestroyPipeline(r.device, r.pipeline, nil)
		r.pipeline = {}
	}
	if r.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, r.pipeline_layout, nil)
		r.pipeline_layout = {}
	}
	if r.vert_module != {} {
		vk.DestroyShaderModule(r.device, r.vert_module, nil)
		r.vert_module = {}
	}
	if r.frag_module != {} {
		vk.DestroyShaderModule(r.device, r.frag_module, nil)
		r.frag_module = {}
	}

	vertex_code := compiler.load_shader_bytes("default.spirv")
	defer delete(vertex_code)
	fragment_code := compiler.load_shader_bytes("default.spirv")
	defer delete(fragment_code)

	r.vert_module = vulkan_create_shader_module(vertex_code)
	r.frag_module = vulkan_create_shader_module(fragment_code)
	vulkan_create_pipeline(r)
	vulkan_rebuild_ui_pipeline(r)
}

vulkan_create_pipeline :: proc(r: ^vulkan_renderer) {
	vert_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = r.vert_module,
		pName  = cstring("vs_main"),
	}
	frag_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = r.frag_module,
		pName  = cstring("fs_main"),
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
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	VK_CHECK(
		vk.CreatePipelineLayout(r.device, &layout_info, nil, &r.pipeline_layout),
		"vkCreatePipelineLayout",
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
		layout              = r.pipeline_layout,
		renderPass          = r.render_pass,
		subpass             = 0,
	}
	VK_CHECK(
		vk.CreateGraphicsPipelines(r.device, {}, 1, &create_info, nil, &r.pipeline),
		"vkCreateGraphicsPipelines",
	)
}

vulkan_record_command_buffer :: proc(
	r: ^vulkan_renderer,
	command_buffer: vk.CommandBuffer,
	image_index: u32,
) {
	VK_CHECK(vk.ResetCommandBuffer(command_buffer, {}), "vkResetCommandBuffer")
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	VK_CHECK(vk.BeginCommandBuffer(command_buffer, &begin_info), "vkBeginCommandBuffer")
	clear_value := vk.ClearValue {
		color = {float32 = [4]f32{0.1, 0.12, 0.16, 1}},
	}
	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = r.render_pass,
		framebuffer = r.framebuffers[image_index],
		renderArea = {extent = r.extent},
		clearValueCount = 1,
		pClearValues = &clear_value,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, r.pipeline)
	vk.CmdDraw(command_buffer, 3, 1, 0, 0)
	vk.CmdEndRenderPass(command_buffer)
	r_render(command_buffer, r.ui.framebuffers[image_index])
	VK_CHECK(vk.EndCommandBuffer(command_buffer), "vkEndCommandBuffer")
}

vulkan_frame :: proc() {
	context = state.ctx
	r := &state.renderer
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
		vulkan_recreate_swapchain(r)
		return
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

	vulkan_record_command_buffer(r, r.command_buffers[frame_slot], image_index)
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
	if present_result == .ERROR_OUT_OF_DATE_KHR ||
	   present_result == .SUBOPTIMAL_KHR ||
	   r.framebuffer_resized {
		r.framebuffer_resized = false
		vulkan_recreate_swapchain(r)
	} else if present_result != .SUCCESS {
		fmt.panicf("vkQueuePresentKHR failed: %v", present_result)
	}
	r.frame_index += 1
}

vulkan_finish :: proc() {
	r := &state.renderer
	if r.device != {} {
		_ = vk.DeviceWaitIdle(r.device)
	}
	vulkan_destroy_swapchain_objects(r)
	if r.vert_module != {} {
		vk.DestroyShaderModule(r.device, r.vert_module, nil)
	}
	if r.frag_module != {} {
		vk.DestroyShaderModule(r.device, r.frag_module, nil)
	}
	vulkan_shutdown_ui(r)
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
}
