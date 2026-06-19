package vkapi

import vma "../../vendor/odin-vma"
import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

init :: proc(window: ^sdl.Window) {
	// context = runtime.default_context()
	renderer.window = window
	if !sdl.Vulkan_LoadLibrary(nil) {
		fmt.panicf("Failed to load Vulkan loader: %v", sdl.GetError())
	}
	vk_proc := sdl.Vulkan_GetVkGetInstanceProcAddr()
	if vk_proc == nil {
		fmt.panicf("SDL_Vulkan_GetVkGetInstanceProcAddr failed: %v", sdl.GetError())
	}
	vk.load_proc_addresses_global(cast(rawptr)vk_proc)
	r := &renderer
	create_instance(r)
	create_debug_messenger(r)
	create_surface(r, window)
	pick_physical_device(r)
	create_device(r)
	create_descriptor_pool(r)
	create_command_pool(r)
	create_sync_objects(r)
	initialize_vma(r)
	init_ui(r)
	create_swapchain_objects(r)
	rebuild_shaders()
	for inits in r.init_proc {
		inits(r)
	}
}

initialize_vma :: proc(r: ^vulkan_renderer) {
	r.vulkan_functions = vma.create_vulkan_functions()

	create_info_vma := vma.AllocatorCreateInfo {
		vulkanApiVersion = vk.API_VERSION_1_4,
		physicalDevice   = r.physical_device,
		device           = r.device,
		instance         = r.instance,
		pVulkanFunctions = &r.vulkan_functions,
		flags            = {
			.EXTERNALLY_SYNCHRONIZED,
			.KHR_DEDICATED_ALLOCATION,
			.KHR_BIND_MEMORY2,
			.EXT_MEMORY_BUDGET,
			.BUFFER_DEVICE_ADDRESS,
		},
	}
	VK_CHECK(vma.CreateAllocator(&create_info_vma, &r.allocator_vma), "vmaCreateAllocator")
}

create_instance :: proc(r: ^vulkan_renderer) {
	ext_count: sdl.Uint32
	ext_ptr := sdl.Vulkan_GetInstanceExtensions(&ext_count)
	if ext_ptr == nil || ext_count == 0 {
		fmt.panicf("Failed to query Vulkan instance extensions: %v", sdl.GetError())
	}
	extensions := make([dynamic]cstring, int(ext_count), context.allocator)
	defer delete(extensions)
	for i in 0 ..< int(ext_count) {
		extensions[i] = cstring(ext_ptr[i])
	}
	if validation_enabled() {
		append(&extensions, cstring(vk.EXT_DEBUG_UTILS_EXTENSION_NAME))
		append(&extensions, cstring(vk.EXT_DEBUG_REPORT_EXTENSION_NAME))
	}

	enabled_layers: []cstring
	if validation_enabled() && has_validation_layer() {
		enabled_layers = []cstring{VALIDATION_LAYER}
	} else if validation_enabled() {
		fmt.eprintf(
			"Validation layer '%s' not available; continuing without it\n",
			VALIDATION_LAYER,
		)
	}

	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = cstring("odin-voxel"),
		applicationVersion = vk.MAKE_API_VERSION(0, 0, 1, 0),
		pEngineName        = cstring("none"),
		engineVersion      = vk.MAKE_API_VERSION(0, 0, 1, 0),
		apiVersion         = vk.API_VERSION_1_4,
	}
	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledLayerCount       = u32(len(enabled_layers)),
		ppEnabledLayerNames     = raw_data(enabled_layers),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}
	when ODIN_DEBUG {
		enabled_features := [1]vk.ValidationFeatureEnableEXT{.DEBUG_PRINTF}
		validation_features := vk.ValidationFeaturesEXT {
			sType                         = .VALIDATION_FEATURES_EXT,
			enabledValidationFeatureCount = 1,
			pEnabledValidationFeatures    = &enabled_features[0],
		}
		create_info.pNext = &validation_features

	}
	VK_CHECK(vk.CreateInstance(&create_info, nil, &r.instance), "vkCreateInstance")
	vk.load_proc_addresses_instance(r.instance)
}

create_surface :: proc(r: ^vulkan_renderer, window: ^sdl.Window) {
	if !sdl.Vulkan_CreateSurface(window, r.instance, nil, &r.surface) {
		fmt.panicf("Failed to create Vulkan surface: %v", sdl.GetError())
	}
}

pick_physical_device :: proc(r: ^vulkan_renderer) {
	device_count: u32
	VK_CHECK(
		vk.EnumeratePhysicalDevices(r.instance, &device_count, nil),
		"vkEnumeratePhysicalDevices(count)",
	)
	if device_count == 0 {
		fmt.panicf("No Vulkan physical devices available")
	}
	devices := make([]vk.PhysicalDevice, int(device_count), context.allocator)
	VK_CHECK(
		vk.EnumeratePhysicalDevices(r.instance, &device_count, raw_data(devices)),
		"vkEnumeratePhysicalDevices",
	)
	for device in devices {
		graphics_index, present_index, ok := find_queue_families(r, device)
		if ok {
			r.physical_device = device
			r.graphics_queue_index = graphics_index
			r.present_queue_index = present_index
			delete(devices)
			return
		}
	}
	delete(devices)
	fmt.panicf("Failed to find a suitable Vulkan physical device")
}

find_queue_families :: proc(r: ^vulkan_renderer, device: vk.PhysicalDevice) -> (u32, u32, bool) {
	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	if queue_family_count == 0 {
		return 0, 0, false
	}
	queue_families := make([]vk.QueueFamilyProperties, int(queue_family_count), context.allocator)
	defer delete(queue_families)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)

	graphics_index: u32
	present_index: u32
	has_graphics := false
	has_present := false

	for family, i in queue_families {
		if !has_graphics && .GRAPHICS in family.queueFlags {
			graphics_index = u32(i)
			has_graphics = true
		}
		if !has_present {
			supported: b32
			VK_CHECK(
				vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), r.surface, &supported),
				"vkGetPhysicalDeviceSurfaceSupportKHR",
			)
			if supported {
				present_index = u32(i)
				has_present = true
			}
		}
	}

	if !(has_graphics && has_present) {
		return 0, 0, false
	}

	support := query_swapchain_support(r, device)
	defer {
		delete(support.formats)
		delete(support.present_modes)
	}
	return graphics_index,
		present_index,
		len(support.formats) > 0 && len(support.present_modes) > 0
}

query_swapchain_support :: proc(
	r: ^vulkan_renderer,
	device: vk.PhysicalDevice,
) -> swapchain_support {
	support: swapchain_support
	VK_CHECK(
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, r.surface, &support.capabilities),
		"vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
	)
	format_count: u32
	VK_CHECK(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, r.surface, &format_count, nil),
		"vkGetPhysicalDeviceSurfaceFormatsKHR(count)",
	)
	if format_count > 0 {
		support.formats = make([]vk.SurfaceFormatKHR, int(format_count), context.allocator)
		VK_CHECK(
			vk.GetPhysicalDeviceSurfaceFormatsKHR(
				device,
				r.surface,
				&format_count,
				raw_data(support.formats),
			),
			"vkGetPhysicalDeviceSurfaceFormatsKHR",
		)
	}
	present_mode_count: u32
	VK_CHECK(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, r.surface, &present_mode_count, nil),
		"vkGetPhysicalDeviceSurfacePresentModesKHR(count)",
	)
	if present_mode_count > 0 {
		support.present_modes = make(
			[]vk.PresentModeKHR,
			int(present_mode_count),
			context.allocator,
		)
		VK_CHECK(
			vk.GetPhysicalDeviceSurfacePresentModesKHR(
				device,
				r.surface,
				&present_mode_count,
				raw_data(support.present_modes),
			),
			"vkGetPhysicalDeviceSurfacePresentModesKHR",
		)
	}
	return support
}

create_descriptor_pool :: proc(r: ^vulkan_renderer) {
	pool_sizes := [4]vk.DescriptorPoolSize {
		{
			type            = .UNIFORM_BUFFER,
			descriptorCount = 100, // Arbitrary large number for simplicity
		},
		{type = .STORAGE_BUFFER, descriptorCount = 100},
		{type = .STORAGE_IMAGE, descriptorCount = 100},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 100},
	}
	create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 100, // Arbitrary large number for simplicity
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = &pool_sizes[0],
	}
	VK_CHECK(
		vk.CreateDescriptorPool(r.device, &create_info, nil, &r.descriptor_pool),
		"vkCreateDescriptorPool",
	)
}
create_device :: proc(r: ^vulkan_renderer) {
	queue_priority := f32(1)
	queue_infos: [2]vk.DeviceQueueCreateInfo
	queue_info_count := 1
	queue_infos[0] = vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = r.graphics_queue_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}
	if r.present_queue_index != r.graphics_queue_index {
		queue_infos[1] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = r.present_queue_index,
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
		queue_info_count = 2
	}
	// 1. Core 1.2 Features Setup
	vulkan12_features := vk.PhysicalDeviceVulkan12Features {
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		bufferDeviceAddress = true,
		pNext               = nil, // This terminates the chain
	}

	// 2. Core 1.1 Features Setup
	vulkan11_features := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters = true,
		pNext                = &vulkan12_features, // Points forward to 1.2 features
	}

	// 3. Core 1.0 Features Container (Replaces old pEnabledFeatures pointer)
	features2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		features = {shaderInt64 = true},
		pNext = &vulkan11_features, // Points forward to 1.1 features
	}
	when ODIN_DEBUG {
		features2.features.vertexPipelineStoresAndAtomics = true
		features2.features.fragmentStoresAndAtomics = true
		features2.features.shaderInt16 = true
		features2.features.shaderInt64 = true
		// needed for compute raymarching output
		features2.features.shaderStorageImageReadWithoutFormat = true
		features2.features.shaderStorageImageWriteWithoutFormat = true
	}
	extensionArray := [3]cstring {
		cstring(vk.KHR_SWAPCHAIN_EXTENSION_NAME),
		cstring(vk.KHR_SHARED_PRESENTABLE_IMAGE_EXTENSION_NAME),
		cstring(vk.KHR_BUFFER_DEVICE_ADDRESS_EXTENSION_NAME),
	}

	// when ODIN_DEBUG {
	// 	append(&device_extensions, cstring(vk.EXT_DEBUG_MARKER_EXTENSION_NAME))
	// }

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features2,
		queueCreateInfoCount    = u32(queue_info_count),
		pQueueCreateInfos       = raw_data(&queue_infos),
		enabledExtensionCount   = u32(len(extensionArray)),
		ppEnabledExtensionNames = raw_data(&extensionArray),
		pEnabledFeatures        = nil,
	}
	VK_CHECK(vk.CreateDevice(r.physical_device, &create_info, nil, &r.device), "vkCreateDevice")
	vk.load_proc_addresses_device(r.device)

	vk.GetDeviceQueue(r.device, r.graphics_queue_index, 0, &r.graphics_queue)
	vk.GetDeviceQueue(r.device, r.present_queue_index, 0, &r.present_queue)
}

create_command_pool :: proc(r: ^vulkan_renderer) {
	create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.graphics_queue_index,
	}
	VK_CHECK(
		vk.CreateCommandPool(r.device, &create_info, nil, &r.command_pool),
		"vkCreateCommandPool",
	)
}

allocate_command_buffers :: proc(r: ^vulkan_renderer) {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		level              = .PRIMARY,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
	}
	VK_CHECK(
		vk.AllocateCommandBuffers(r.device, &alloc_info, &r.command_buffers[0]),
		"vkAllocateCommandBuffers",
	)
}

create_sync_objects :: proc(r: ^vulkan_renderer) {
	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		VK_CHECK(
			vk.CreateSemaphore(r.device, &sem_info, nil, &r.image_available[i]),
			"vkCreateSemaphore(image_available)",
		)
		VK_CHECK(vk.CreateFence(r.device, &fence_info, nil, &r.in_flight[i]), "vkCreateFence")
	}
}
