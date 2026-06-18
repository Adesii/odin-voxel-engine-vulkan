package main

import "core:fmt"
import v "shaders/voxel_shader"
import vk "vendor:vulkan"


Voxel :: struct {
	color: u32, // Packed RGBA8 format
}

Voxel_Buffer_Context :: struct {
	uniform_buffer: vulkan_buffer,
	voxel_buffer:   vulkan_buffer,
	descriptor_set: vk.DescriptorSet,
}


vulkan_init_voxel_buffers :: proc(r: ^vulkan_renderer, ctx: ^Voxel_Buffer_Context) {
	// Create uniform buffer
	ctx.uniform_buffer = vulkan_create_buffer(
		r,
		v.VOXEL_UNIFORM_BUFFER_SIZE,
		{.UNIFORM_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	// Create voxel buffer (initially empty, will be updated each frame)
	ctx.voxel_buffer = vulkan_create_buffer(r, 1024 * 1024, {.STORAGE_BUFFER}, {.DEVICE_LOCAL})

	// Allocate descriptor set for the voxel shader
	ctx.descriptor_set = vulkan_allocate_descriptor_set(
		r,
		"voxel_shader",
		{
			{binding = v.VOXEL_BINDING_DATA, type = .STORAGE_BUFFER},
			{binding = v.VOXEL_BINDING_G_VOLUME, type = .UNIFORM_BUFFER},
		},
	)
}
