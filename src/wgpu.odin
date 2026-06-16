package main
import "core:bytes"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8/utf8string"
import compiler "utils"
import "vendor:wgpu"


rebuild_shaders :: proc() {
	context = state.ctx

	fmt.printfln("Reloading shaders...")

	compiler.compile("shader_src/", "shaders/")

	shader := compiler.load_shader("default")
	defer delete(shader)


	state.module = wgpu.DeviceCreateShaderModule(
		state.device,
		&wgpu.ShaderModuleDescriptor {
			nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = shader},
		},
	)
	layouts := [?]wgpu.BindGroupLayout{}

	state.pipeline_layout = wgpu.DeviceCreatePipelineLayout(
		state.device,
		&{
			label = "pipeline layout",
			// bindGroupLayoutCount = 0,
			// bindGroupLayouts = raw_data(layouts[:]),
		},
	)

	state.pipeline = wgpu.DeviceCreateRenderPipeline(
		state.device,
		&{
			layout = state.pipeline_layout,
			vertex = {module = state.module, entryPoint = "vs_main"},
			fragment = &{
				module = state.module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = .BGRA8Unorm,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = 0xFFFFFFFF},
		},
	)
}
