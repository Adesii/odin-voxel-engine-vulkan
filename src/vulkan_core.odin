package main

import intrinsics "base:intrinsics"
import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2
VALIDATION_LAYER :: "VK_LAYER_KHRONOS_validation"

swapchain_support :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

vulkan_renderer :: struct {
	instance:             vk.Instance,
	debug_messenger:      vk.DebugUtilsMessengerEXT,
	surface:              vk.SurfaceKHR,
	physical_device:      vk.PhysicalDevice,
	device:               vk.Device,
	graphics_queue:       vk.Queue,
	present_queue:        vk.Queue,
	graphics_queue_index: u32,
	present_queue_index:  u32,
	surface_format:       vk.SurfaceFormatKHR,
	present_mode:         vk.PresentModeKHR,
	extent:               vk.Extent2D,
	swapchain:            vk.SwapchainKHR,
	swapchain_images:     []vk.Image,
	swapchain_views:      []vk.ImageView,
	images_in_flight:     []vk.Fence,
	render_pass:          vk.RenderPass,
	pipeline_layout:      vk.PipelineLayout,
	pipeline:             vk.Pipeline,
	vert_module:          vk.ShaderModule,
	frag_module:          vk.ShaderModule,
	framebuffers:         []vk.Framebuffer,
	ui:                   microui_ctx,
	command_pool:         vk.CommandPool,
	command_buffers:      [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	image_available:      [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	render_finished:      []vk.Semaphore,
	in_flight:            [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	frame_index:          int,
	framebuffer_resized:  bool,
}

validation_enabled :: proc() -> bool {
	when ODIN_DEBUG || (ODIN_OPTIMIZATION_MODE == .Minimal) {
		return true
	} else {
		return false
	}
}

debug_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = runtime.default_context()
	_ = messageTypes
	_ = pUserData
	message := "<null>"
	if pCallbackData != nil && pCallbackData.pMessage != nil {
		message = string(pCallbackData.pMessage)
	}
	fmt.eprintf("[vulkan %v] %s\n", messageSeverity, message)
	return false
}

vulkan_has_validation_layer :: proc() -> bool {
	count: u32
	VK_CHECK(
		vk.EnumerateInstanceLayerProperties(&count, nil),
		"vkEnumerateInstanceLayerProperties(count)",
	)
	if count == 0 {
		return false
	}
	layers := make([]vk.LayerProperties, int(count), context.allocator)
	defer delete(layers)
	VK_CHECK(
		vk.EnumerateInstanceLayerProperties(&count, raw_data(layers)),
		"vkEnumerateInstanceLayerProperties",
	)
	for i in 0 ..< len(layers) {
		layer := &layers[i]
		if string(cstring(raw_data(layer.layerName[:]))) == VALIDATION_LAYER {
			return true
		}
	}
	return false
}

vulkan_create_debug_messenger :: proc(r: ^vulkan_renderer) {
	if !validation_enabled() {
		return
	}
	create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
	}
	VK_CHECK(
		vk.CreateDebugUtilsMessengerEXT(r.instance, &create_info, nil, &r.debug_messenger),
		"vkCreateDebugUtilsMessengerEXT",
	)
}

VK_CHECK :: proc(result: vk.Result, what: string) {
	if result != .SUCCESS {
		fmt.panicf("%s failed: %v", what, result)
	}
}

vulkan_find_memory_type :: proc(
	r: ^vulkan_renderer,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> u32 {
	memory_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(r.physical_device, &memory_properties)
	for i in 0 ..< int(memory_properties.memoryTypeCount) {
		memory_type := memory_properties.memoryTypes[i]
		if (type_filter & (1 << u32(i))) != 0 && properties <= memory_type.propertyFlags {
			return u32(i)
		}
	}
	fmt.panicf("Failed to find compatible Vulkan memory type")
}

vulkan_create_buffer :: proc(
	r: ^vulkan_renderer,
	size: int,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> vulkan_buffer {
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	b: vulkan_buffer
	b.size = vk.DeviceSize(size)
	VK_CHECK(vk.CreateBuffer(r.device, &buffer_info, nil, &b.buffer), "vkCreateBuffer")
	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(r.device, b.buffer, &requirements)
	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = vulkan_find_memory_type(r, requirements.memoryTypeBits, properties),
	}
	VK_CHECK(vk.AllocateMemory(r.device, &alloc_info, nil, &b.memory), "vkAllocateMemory(buffer)")
	VK_CHECK(vk.BindBufferMemory(r.device, b.buffer, b.memory, 0), "vkBindBufferMemory")
	return b
}

vulkan_destroy_buffer :: proc(device: vk.Device, buffer: ^vulkan_buffer) {
	if buffer.buffer != {} {
		vk.DestroyBuffer(device, buffer.buffer, nil)
		buffer.buffer = {}
	}
	if buffer.memory != {} {
		vk.FreeMemory(device, buffer.memory, nil)
		buffer.memory = {}
	}
}

vulkan_write_buffer :: proc(buffer: ^vulkan_buffer, data: rawptr, size: int, offset: int) {
	if size <= 0 {
		return
	}
	mapped: rawptr
	VK_CHECK(
		vk.MapMemory(
			state.renderer.device,
			buffer.memory,
			vk.DeviceSize(offset),
			vk.DeviceSize(size),
			{},
			&mapped,
		),
		"vkMapMemory",
	)
	intrinsics.mem_copy_non_overlapping(mapped, data, size)
	vk.UnmapMemory(state.renderer.device, buffer.memory)
}

vulkan_set_scissor :: proc(command_buffer: vk.CommandBuffer, x, y, w, h: u32) {
	scissor := vk.Rect2D {
		offset = {i32(x), i32(y)},
		extent = {w, h},
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

vulkan_create_image :: proc(
	r: ^vulkan_renderer,
	width, height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (
	vk.Image,
	vk.DeviceMemory,
) {
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {width, height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	image: vk.Image
	memory: vk.DeviceMemory
	VK_CHECK(vk.CreateImage(r.device, &image_info, nil, &image), "vkCreateImage")
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, image, &requirements)
	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = vulkan_find_memory_type(r, requirements.memoryTypeBits, properties),
	}
	VK_CHECK(vk.AllocateMemory(r.device, &alloc_info, nil, &memory), "vkAllocateMemory(image)")
	VK_CHECK(vk.BindImageMemory(r.device, image, memory, 0), "vkBindImageMemory")
	return image, memory
}

vulkan_begin_single_use_commands :: proc(r: ^vulkan_renderer) -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	command_buffer: vk.CommandBuffer
	VK_CHECK(
		vk.AllocateCommandBuffers(r.device, &alloc_info, &command_buffer),
		"vkAllocateCommandBuffers(single-use)",
	)
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	VK_CHECK(
		vk.BeginCommandBuffer(command_buffer, &begin_info),
		"vkBeginCommandBuffer(single-use)",
	)
	return command_buffer
}

vulkan_end_single_use_commands :: proc(r: ^vulkan_renderer, command_buffer: vk.CommandBuffer) {
	VK_CHECK(vk.EndCommandBuffer(command_buffer), "vkEndCommandBuffer(single-use)")
	cmd := command_buffer
	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}
	VK_CHECK(vk.QueueSubmit(r.graphics_queue, 1, &submit_info, {}), "vkQueueSubmit(single-use)")
	_ = vk.QueueWaitIdle(r.graphics_queue)
	vk.FreeCommandBuffers(r.device, r.command_pool, 1, &cmd)
}

vulkan_transition_image_layout :: proc(
	r: ^vulkan_renderer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
) {
	command_buffer := vulkan_begin_single_use_commands(r)
	barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = old_layout,
		newLayout = new_layout,
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
	}
	src_stage := vk.PipelineStageFlags_NONE
	dst_stage := vk.PipelineStageFlags_NONE
	if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
		barrier.srcAccessMask = vk.AccessFlags_NONE
		barrier.dstAccessMask = {.TRANSFER_WRITE}
		src_stage = {.TOP_OF_PIPE}
		dst_stage = {.TRANSFER}
	} else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstAccessMask = {.SHADER_READ}
		src_stage = {.TRANSFER}
		dst_stage = {.FRAGMENT_SHADER}
	} else {
		fmt.panicf("Unsupported layout transition: %v -> %v", old_layout, new_layout)
	}
	vk.CmdPipelineBarrier(command_buffer, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)
	vulkan_end_single_use_commands(r, command_buffer)
}

vulkan_copy_buffer_to_image :: proc(
	r: ^vulkan_renderer,
	buffer: vk.Buffer,
	image: vk.Image,
	width, height: u32,
) {
	command_buffer := vulkan_begin_single_use_commands(r)
	region := vk.BufferImageCopy {
		imageSubresource = {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageExtent = {width, height, 1},
	}
	vk.CmdCopyBufferToImage(command_buffer, buffer, image, .TRANSFER_DST_OPTIMAL, 1, &region)
	vulkan_end_single_use_commands(r, command_buffer)
}
