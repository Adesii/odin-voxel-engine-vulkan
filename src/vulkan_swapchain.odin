package main

import vk "vendor:vulkan"

vulkan_choose_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_UNORM && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}
	return formats[0]
}

vulkan_choose_present_mode :: proc(present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for mode in present_modes {
		if mode == .MAILBOX {
			return mode
		}
	}
	return .FIFO
}

vulkan_choose_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != ~u32(0) {
		return capabilities.currentExtent
	}
	width, height := get_window_size()
	extent := vk.Extent2D {
		width  = cast(u32)width,
		height = cast(u32)height,
	}
	if extent.width < capabilities.minImageExtent.width {
		extent.width = capabilities.minImageExtent.width
	}
	if extent.width > capabilities.maxImageExtent.width {
		extent.width = capabilities.maxImageExtent.width
	}
	if extent.height < capabilities.minImageExtent.height {
		extent.height = capabilities.minImageExtent.height
	}
	if extent.height > capabilities.maxImageExtent.height {
		extent.height = capabilities.maxImageExtent.height
	}
	return extent
}

vulkan_create_swapchain_objects :: proc(r: ^vulkan_renderer) {
	support := vulkan_query_swapchain_support(r, r.physical_device)
	defer {
		delete(support.formats)
		delete(support.present_modes)
	}
	r.surface_format = vulkan_choose_surface_format(support.formats)
	r.present_mode = vulkan_choose_present_mode(support.present_modes)
	r.extent = vulkan_choose_extent(support.capabilities)

	image_count := support.capabilities.minImageCount + 1
	if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
		image_count = support.capabilities.maxImageCount
	}
	queue_family_indices := [2]u32{r.graphics_queue_index, r.present_queue_index}
	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = r.surface,
		minImageCount    = image_count,
		imageFormat      = r.surface_format.format,
		imageColorSpace  = r.surface_format.colorSpace,
		imageExtent      = r.extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = r.present_mode,
		clipped          = true,
	}
	if r.graphics_queue_index != r.present_queue_index {
		create_info.imageSharingMode = .CONCURRENT
		create_info.queueFamilyIndexCount = 2
		create_info.pQueueFamilyIndices = &queue_family_indices[0]
	} else {
		create_info.imageSharingMode = .EXCLUSIVE
	}
	VK_CHECK(
		vk.CreateSwapchainKHR(r.device, &create_info, nil, &r.swapchain),
		"vkCreateSwapchainKHR",
	)

	image_count = 0
	VK_CHECK(
		vk.GetSwapchainImagesKHR(r.device, r.swapchain, &image_count, nil),
		"vkGetSwapchainImagesKHR(count)",
	)
	r.swapchain_images = make([]vk.Image, int(image_count), context.allocator)
	VK_CHECK(
		vk.GetSwapchainImagesKHR(
			r.device,
			r.swapchain,
			&image_count,
			raw_data(r.swapchain_images),
		),
		"vkGetSwapchainImagesKHR",
	)
	r.images_in_flight = make([]vk.Fence, len(r.swapchain_images), context.allocator)
	r.render_finished = make([]vk.Semaphore, len(r.swapchain_images), context.allocator)
	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for i in 0 ..< len(r.render_finished) {
		VK_CHECK(
			vk.CreateSemaphore(r.device, &sem_info, nil, &r.render_finished[i]),
			"vkCreateSemaphore(render_finished)",
		)
	}

	r.swapchain_views = make([]vk.ImageView, len(r.swapchain_images), context.allocator)
	for image, i in r.swapchain_images {
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
		VK_CHECK(
			vk.CreateImageView(r.device, &view_info, nil, &r.swapchain_views[i]),
			"vkCreateImageView",
		)
	}

	vulkan_create_render_pass(r)
	vulkan_create_framebuffers(r)
	vulkan_create_ui_swapchain_objects(r)
	if r.command_buffers[0] == {} {
		vulkan_allocate_command_buffers(r)
	}
}

vulkan_create_render_pass :: proc(r: ^vulkan_renderer) {
	attachment := vk.AttachmentDescription {
		format         = r.surface_format.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .COLOR_ATTACHMENT_OPTIMAL,
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
		srcAccessMask = vk.AccessFlags_NONE,
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
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
		vk.CreateRenderPass(r.device, &create_info, nil, &r.render_pass),
		"vkCreateRenderPass",
	)
}

vulkan_create_framebuffers :: proc(r: ^vulkan_renderer) {
	r.framebuffers = make([]vk.Framebuffer, len(r.swapchain_views), context.allocator)
	for view, i in r.swapchain_views {
		attachments := [1]vk.ImageView{view}
		create_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = r.render_pass,
			attachmentCount = 1,
			pAttachments    = &attachments[0],
			width           = r.extent.width,
			height          = r.extent.height,
			layers          = 1,
		}
		VK_CHECK(
			vk.CreateFramebuffer(r.device, &create_info, nil, &r.framebuffers[i]),
			"vkCreateFramebuffer",
		)
	}
}

vulkan_destroy_swapchain_objects :: proc(r: ^vulkan_renderer) {
	for framebuffer in r.framebuffers {
		if framebuffer != {} {
			vk.DestroyFramebuffer(r.device, framebuffer, nil)
		}
	}
	delete(r.framebuffers)
	r.framebuffers = nil
	vulkan_destroy_ui_swapchain_objects(r)

	if r.pipeline != {} {
		vk.DestroyPipeline(r.device, r.pipeline, nil)
		r.pipeline = {}
	}
	if r.pipeline_layout != {} {
		vk.DestroyPipelineLayout(r.device, r.pipeline_layout, nil)
		r.pipeline_layout = {}
	}
	if r.render_pass != {} {
		vk.DestroyRenderPass(r.device, r.render_pass, nil)
		r.render_pass = {}
	}
	for view in r.swapchain_views {
		if view != {} {
			vk.DestroyImageView(r.device, view, nil)
		}
	}
	delete(r.swapchain_views)
	r.swapchain_views = nil
	for semaphore in r.render_finished {
		if semaphore != {} {
			vk.DestroySemaphore(r.device, semaphore, nil)
		}
	}
	delete(r.render_finished)
	r.render_finished = nil
	delete(r.swapchain_images)
	r.swapchain_images = nil
	delete(r.images_in_flight)
	r.images_in_flight = nil
	if r.swapchain != {} {
		vk.DestroySwapchainKHR(r.device, r.swapchain, nil)
		r.swapchain = {}
	}
}

vulkan_recreate_swapchain :: proc(r: ^vulkan_renderer) {
	width, height := get_window_size()
	if width == 0 || height == 0 {
		return
	}
	VK_CHECK(vk.DeviceWaitIdle(r.device), "vkDeviceWaitIdle")
	vulkan_destroy_swapchain_objects(r)
	vulkan_create_swapchain_objects(r)
	vulkan_create_pipeline(r)
	vulkan_rebuild_ui_pipeline(r, false)
}

vulkan_resize :: proc() {
	context = state.ctx
	state.renderer.framebuffer_resized = true
}
