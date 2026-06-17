package main

import vma "../vendor/odin-vma"
import intrinsics "base:intrinsics"
import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2
VALIDATION_LAYER :: "VK_LAYER_KHRONOS_validation"


vulkan_buffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
}

swapchain_support :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

vulkan_renderer :: struct {
	instance:             vk.Instance,
	debug_messenger:      vk.DebugUtilsMessengerEXT,
	allocator_vma:        vma.Allocator,
	vulkan_functions:     vma.VulkanFunctions,
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
	// 1. Properly set VMA allocation flags based on your passed properties
	alloc_flags: vma.AllocationCreateFlags = {}
	if .HOST_VISIBLE in properties {
		// Tells VMA to pick a CPU-visible memory type and maps it automatically
		alloc_flags += {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED}
	}

	// 2. Ensure ALL fields of the C-struct are zero-initialized or explicitly set
	alloc_info := vma.AllocationCreateInfo {
		flags         = alloc_flags,
		usage         = .AUTO,
		requiredFlags = properties, // Enforces the driver to use HOST_VISIBLE/HOST_COHERENT
	}

	b: vulkan_buffer
	b.allocation = vma.Allocation{}
	b.buffer = vk.Buffer{}
	// fmt.println("Creating buffer of size %d", size)
	// fmt.println("Buffer usage: %v", usage)
	// fmt.println("Memory properties: %v", properties)
	VK_CHECK(
		vma.CreateBuffer(
			r.allocator_vma,
			&buffer_info,
			&alloc_info,
			&b.buffer,
			&b.allocation,
			nil,
		),
		"vmaCreateBuffer",
	)
	return b
}

vulkan_destroy_buffer :: proc(r: ^vulkan_renderer, buffer: ^vulkan_buffer) {
	if buffer.buffer != {} {
		vk.DestroyBuffer(r.device, buffer.buffer, nil)
		buffer.buffer = {}
	}
	vma.DestroyBuffer(r.allocator_vma, buffer.buffer, buffer.allocation)
}

vulkan_write_buffer :: proc(
	r: ^vulkan_renderer,
	buffer: ^vulkan_buffer,
	data: rawptr,
	size: int,
) { 	//TODO: Figure out if this actually does anything
	if size <= 0 {
		return
	}
	mapped: rawptr
	VK_CHECK(vma.MapMemory(r.allocator_vma, buffer.allocation, &mapped), "vkMapMemory")
	intrinsics.mem_copy_non_overlapping(mapped, data, size)
	vma.UnmapMemory(r.allocator_vma, buffer.allocation)
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
	vma.Allocation,
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

	// 1. Properly set VMA allocation flags based on your passed properties
	alloc_flags: vma.AllocationCreateFlags = {}
	if .HOST_VISIBLE in properties {
		// Tells VMA to pick a CPU-visible memory type and maps it automatically
		alloc_flags += {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED}
	}

	// 2. Ensure ALL fields of the C-struct are zero-initialized or explicitly set
	alloc_info := vma.AllocationCreateInfo {
		flags         = alloc_flags,
		usage         = .AUTO,
		requiredFlags = properties, // Enforces the driver to use HOST_VISIBLE/HOST_COHERENT
	}
	vma_allocation: vma.Allocation
	VK_CHECK(
		vma.CreateImage(r.allocator_vma, &image_info, &alloc_info, &image, &vma_allocation, nil),
		"vmaCreateImage",
	)
	return image, vma_allocation
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
