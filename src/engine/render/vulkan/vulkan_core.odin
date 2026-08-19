package vkapi

import vma "../../../../vendor/odin-vma"
import intrinsics "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2
VALIDATION_LAYER :: "VK_LAYER_KHRONOS_validation"


Buffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
}
Image :: struct {
	image:      vk.Image,
	view:       vk.ImageView,
	sampler:    vk.Sampler,
	allocation: vma.Allocation,
}

Renderer_Config :: struct {
	application_name:    string,
	engine_name:         string,
	presentation_shader: []byte,
}

Swapchain_Proc :: proc(data: rawptr, r: ^Renderer)
Swapchain_Callbacks :: struct {
	data:           rawptr,
	before_destroy: Swapchain_Proc,
	after_create:   Swapchain_Proc,
}

Frame_Record_Proc :: proc(
	data: rawptr,
	r: ^Renderer,
	command_buffer: vk.CommandBuffer,
	image_index: u32,
)
Frame_Description :: struct {
	source_image:   Image,
	content_data:   rawptr,
	record_content: Frame_Record_Proc,
	overlay_data:   rawptr,
	record_overlay: Frame_Record_Proc,
	swapchain:      Swapchain_Callbacks,
}

Frame_Result :: enum {
	RENDERED,
	SWAPCHAIN_RECREATED,
	SKIPPED,
}

Descriptor_Binding :: struct {
	binding: u32,
	type:    vk.DescriptorType,
}

swapchain_support :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

fullscreen_object :: struct {
	pipeline_layout:   vk.PipelineLayout,
	pipeline:          vk.Pipeline,
	vert_module:       vk.ShaderModule,
	frag_module:       vk.ShaderModule,
	render_pass:       vk.RenderPass,
	descriptor_sets:   [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	descriptor_layout: vk.DescriptorSetLayout,
}
Renderer :: struct {
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
	descriptor_pool:      vk.DescriptorPool,
	surface_format:       vk.SurfaceFormatKHR,
	present_mode:         vk.PresentModeKHR,
	extent:               vk.Extent2D,
	swapchain:            vk.SwapchainKHR,
	swapchain_images:     []vk.Image,
	swapchain_views:      []vk.ImageView,
	images_in_flight:     []vk.Fence,
	fullscreen:           fullscreen_object,
	framebuffers:         []vk.Framebuffer,
	command_pool:         vk.CommandPool,
	command_buffers:      [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	image_available:      [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	render_finished:      []vk.Semaphore,
	in_flight:            [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	frame_index:          int,
	framebuffer_resized:  bool,
	window:               ^sdl.Window,
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

	if pCallbackData != nil {
		// 1. Authenticate the exact Debug Printf magic number hash
		if pCallbackData.messageIdNumber == 0x4fe1fef9 {
			raw_str := string(pCallbackData.pMessage)

			// Find where the message text starts after the boilerplate header
			// The validation layers append "DebugPrintf:\n" right before your text
			target_marker := "DebugPrintf:\n"
			if index := strings.index(raw_str, target_marker); index != -1 {
				clean_msg := raw_str[index + len(target_marker):]

				// Print just the beautiful, un-padded shader data
				fmt.printf("[Vulkan PRINT] %s", clean_msg)
				return false
			}
		}
	}

	// 2. Fallback logger for actual Vulkan warnings and errors
	message :=
		pCallbackData != nil && pCallbackData.pMessage != nil ? string(pCallbackData.pMessage) : "<null>"
	severity_str: string
	for flag in messageSeverity {
		switch flag {
		case .INFO:
			severity_str = "INFO"
		case .WARNING:
			severity_str = "WARNING"
		case .ERROR:
			severity_str = "ERROR"
		case .VERBOSE:
			severity_str = "VERBOSE"
		}
	}
	fmt.eprintf("[Vulkan %v] %s\n", severity_str, message)
	return false
}

get_window_size :: proc(r: ^Renderer) -> (w: i32, h: i32) {
	width, height: i32
	sdl.GetWindowSizeInPixels(r.window, &width, &height)
	return width, height
}
has_validation_layer :: proc() -> bool {
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

create_debug_messenger :: proc(r: ^Renderer) {
	if !validation_enabled() {
		return
	}
	create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.INFO, .WARNING, .ERROR},
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

find_memory_type :: proc(
	r: ^Renderer,
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

create_buffer :: proc(
	r: ^Renderer,
	size: int,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> Buffer {
	size := size
	if (size <= 0) {
		fmt.printfln("Attempted to create Vulkan buffer with non-positive size: %d", size)
		size = 16 // Default to a small size to avoid creating an invalid buffer
	}
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

	b: Buffer
	b.allocation = vma.Allocation{}
	b.buffer = vk.Buffer{}
	// fmt.println("Creating buffer of size %d", size)
	// fmt.println("Buffer usage: %v", usage)
	// fmt.println("Memory properties: %v", properties)
	// fmt.printfln("vma allocator: %p", r.allocator_vma)
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
create_sampler :: proc(
	r: ^Renderer,
	filter: vk.Filter,
	address_mode: vk.SamplerAddressMode,
) -> vk.Sampler {
	sampler_info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = filter,
		minFilter               = filter,
		addressModeU            = address_mode,
		addressModeV            = address_mode,
		addressModeW            = address_mode,
		maxAnisotropy           = 1.0,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		mipmapMode              = .LINEAR,
		mipLodBias              = 0.0,
		minLod                  = 0.0,
		maxLod                  = 0.0,
	}
	sampler: vk.Sampler
	VK_CHECK(
		vk.CreateSampler(r.device, &sampler_info, nil, &sampler),
		fmt.tprintf("vkCreateSampler(%v)", filter),
	)
	return sampler
}

create_descriptor_set_layout :: proc(
	r: ^Renderer,
	stage_flags: vk.ShaderStageFlags,
	bindings: []Descriptor_Binding,
) -> vk.DescriptorSetLayout {
	layout_bindings := make([]vk.DescriptorSetLayoutBinding, len(bindings), context.temp_allocator)
	for binding, i in bindings {
		layout_bindings[i] = vk.DescriptorSetLayoutBinding {
			binding         = binding.binding,
			descriptorType  = binding.type,
			descriptorCount = 1,
			stageFlags      = stage_flags,
		}
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(layout_bindings)),
		pBindings    = raw_data(layout_bindings),
	}
	layout: vk.DescriptorSetLayout
	VK_CHECK(
		vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &layout),
		"vkCreateDescriptorSetLayout",
	)
	return layout
}

create_pipeline_layout :: proc(
	r: ^Renderer,
	descriptor_layout: vk.DescriptorSetLayout,
) -> vk.PipelineLayout {
	layout := descriptor_layout
	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts    = &layout,
	}
	pipeline_layout: vk.PipelineLayout
	VK_CHECK(
		vk.CreatePipelineLayout(r.device, &pipeline_layout_info, nil, &pipeline_layout),
		"vkCreatePipelineLayout",
	)
	return pipeline_layout
}

create_compute_pipeline :: proc(
	r: ^Renderer,
	shader_module: vk.ShaderModule,
	entry_point: string,
	pipeline_layout: vk.PipelineLayout,
) -> vk.Pipeline {
	entry_point_c := strings.clone_to_cstring(entry_point)
	defer delete(entry_point_c)
	stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = shader_module,
		pName  = entry_point_c,
	}
	pipeline_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		stage  = stage,
		layout = pipeline_layout,
	}
	pipeline: vk.Pipeline
	VK_CHECK(
		vk.CreateComputePipelines(r.device, {}, 1, &pipeline_info, nil, &pipeline),
		"vkCreateComputePipelines",
	)
	return pipeline
}

destroy_buffer :: proc(r: ^Renderer, buffer: ^Buffer) {
	if buffer.buffer == {} {
		return
	}
	vma.DestroyBuffer(r.allocator_vma, buffer.buffer, buffer.allocation)
	buffer^ = {}
}

destroy_image :: proc(r: ^Renderer, image: ^Image) {
	if image.sampler != {} {
		vk.DestroySampler(r.device, image.sampler, nil)
	}
	if image.view != {} {
		vk.DestroyImageView(r.device, image.view, nil)
	}
	if image.image != {} {
		vma.DestroyImage(r.allocator_vma, image.image, image.allocation)
	}
	image^ = {}
}

write_buffer :: proc(r: ^Renderer, buffer: ^Buffer, data: rawptr, size: int) {
	if size <= 0 {
		return
	}
	mapped: rawptr
	VK_CHECK(vma.MapMemory(r.allocator_vma, buffer.allocation, &mapped), "vkMapMemory")
	intrinsics.mem_copy_non_overlapping(mapped, data, size)
	vma.UnmapMemory(r.allocator_vma, buffer.allocation)
}

get_gpu_address :: proc(device: vk.Device, buffer: vk.Buffer) -> vk.DeviceAddress {
	assert(buffer != 0, "Vulkan buffer handle is null!")
	address_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = buffer,
	}
	return vk.GetBufferDeviceAddress(device, &address_info)
}


allocate_descriptor_set :: proc(r: ^Renderer, layout: vk.DescriptorSetLayout) -> vk.DescriptorSet {
	layout_copy := layout
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = r.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &layout_copy,
	}
	set: vk.DescriptorSet
	VK_CHECK(vk.AllocateDescriptorSets(r.device, &alloc_info, &set), "vkAllocateDescriptorSets")
	return set
}

set_scissor :: proc(command_buffer: vk.CommandBuffer, x, y, w, h: u32) {
	scissor := vk.Rect2D {
		offset = {i32(x), i32(y)},
		extent = {w, h},
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

create_image :: proc(
	r: ^Renderer,
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

begin_single_use_commands :: proc(r: ^Renderer) -> vk.CommandBuffer {
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

end_single_use_commands :: proc(r: ^Renderer, command_buffer: vk.CommandBuffer) {
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

transition_image_layout :: proc(
	r: ^Renderer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
) {
	command_buffer := begin_single_use_commands(r)
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
	end_single_use_commands(r, command_buffer)
}

copy_buffer_to_image :: proc(
	r: ^Renderer,
	buffer: vk.Buffer,
	image: vk.Image,
	width, height: u32,
) {
	command_buffer := begin_single_use_commands(r)
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
	end_single_use_commands(r, command_buffer)
}
